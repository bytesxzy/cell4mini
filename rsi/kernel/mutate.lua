-- Candidate generation: operators that rewrite the genome from empirical evidence
-- (solutions and near-misses on the visible split) or by controlled perturbation.
-- Operator selection is adaptive: operators that produced accepted candidates get sampled more.
local program = require("rsi.kernel.program")
local genome = require("rsi.kernel.genome")
local M = {}

M.operators = {
  "library_learn", "near_miss_abstraction", "fit_priors", "reorder_ops", "prune_dsl_bulk",
  "perturb_hyper", "const_tune", "prune_library", "drop_op", "restore_op", "strategy_swap",
}

-- Evidence = the accumulated corpus of visible-split solutions (all generations), falling back to
-- this generation's results. Held-out programs are never part of it.
local function solved_programs(ctx)
  local out = {}
  if ctx.corpus and #ctx.corpus > 0 then
    for _, e in ipairs(ctx.corpus) do
      local ok, node = pcall(program.parse, e.expr)
      if ok then out[#out + 1] = { id = e.family .. ":" .. e.gen, node = node } end
    end
    return out
  end
  for _, r in ipairs(ctx.train_results.per_task) do
    if r.solved == 1 and r.program then out[#out + 1] = { id = r.id, node = program.parse(r.program) } end
  end
  return out
end

local function op_counts(progs)
  local cnt, total = {}, 0
  for _, p in ipairs(progs) do
    for _, op in ipairs(program.ops_used(p.node)) do cnt[op] = (cnt[op] or 0) + 1 total = total + 1 end
  end
  return cnt, total
end

local function lib_has(g, expr)
  for _, e in ipairs(g.lib) do if e.expr == expr then return true end end
  return false
end

local function next_lib_name(g)
  local n = 0
  for _, e in ipairs(g.lib) do local k = tonumber(e.name:match("lib_(%d+)")) if k and k > n then n = k end end
  return "lib_" .. (n + 1)
end

-- Count closed subtrees (containing $) across programs; score = compression gain (size-1)*(uses-1)
local function abstraction_candidates(g, progs, min_size)
  local seen_per_task, freq, info = {}, {}, {}
  for _, p in ipairs(progs) do
    local local_seen = {}
    for _, st in ipairs(program.subtrees(p.node)) do
      if program.size(st) >= (min_size or 3) and #program.ops_used(st) >= 2 then
        local s = program.to_string(st)
        if not local_seen[s] then
          local_seen[s] = true
          freq[s] = (freq[s] or 0) + 1
          info[s] = info[s] or { node = st, size = program.size(st) }
        end
      end
    end
  end
  local list = {}
  for s, f in pairs(freq) do
    if not lib_has(g, s) then list[#list + 1] = { expr = s, uses = f, size = info[s].size, node = info[s].node, gain = (info[s].size - 1) * math.max(f - 1, 0) + f } end
  end
  table.sort(list, function(a, b) if a.gain ~= b.gain then return a.gain > b.gain end return a.expr < b.expr end)
  return list
end

local function in_type_of(node)
  -- the variable's type is whatever the innermost op expects at the position of $
  local function walk(n, prims, expected)
    if n.var then return expected end
    if n.const ~= nil then return nil end
    local p = prims[n.op]
    if not p then return nil end
    for i, a in ipairs(n.args) do
      local r = walk(a, prims, p.t[i])
      if r then return r end
    end
    return nil
  end
  return walk
end

local function add_abstractions(g, cands, ctx, max_add, tag)
  local added = {}
  local walk = in_type_of()
  for _, c in ipairs(cands) do
    if #added >= max_add then break end
    local arg = walk(c.node, ctx.prims, nil)
    local ret = program.ret_type(c.node, ctx.prims, arg)
    if arg and ret and ret ~= "?" and (c.uses >= 2 or tag == "near_miss") then
      local name = next_lib_name(g)
      g.lib[#g.lib + 1] = { name = name, expr = c.expr, arg = arg, ret = ret, origin = tag, uses = c.uses }
      g.policy.cost[name] = math.max(1, (g.policy.default_cost or 2) - 1)
      added[#added + 1] = name .. "=" .. c.expr .. " (uses " .. c.uses .. ")"
    end
  end
  return added
end

local ops_impl = {}

function ops_impl.library_learn(g, ctx)
  local progs = solved_programs(ctx)
  if #progs < 2 then return nil end
  local cands = abstraction_candidates(g, progs, 3)
  local added = add_abstractions(g, cands, ctx, 4, "library")
  if #added == 0 then return nil end
  return "library learning: " .. table.concat(added, "; ")
end

function ops_impl.near_miss_abstraction(g, ctx)
  local progs = {}
  for _, e in ipairs(ctx.near_corpus or {}) do
    local ok, node = pcall(program.parse, e.expr)
    if ok then progs[#progs + 1] = { id = e.family .. ":" .. e.gen, node = node } end
  end
  for _, r in ipairs(ctx.adversarial_results and ctx.adversarial_results.per_task or {}) do
    if r.solved == 0 and r.partial >= 0.5 and r.partial_program then
      progs[#progs + 1] = { id = r.id, node = program.parse(r.partial_program) }
    end
  end
  if #progs < 2 then return nil end
  local cands = abstraction_candidates(g, progs, 3)
  local filtered = {}
  for _, c in ipairs(cands) do if c.uses >= 2 then filtered[#filtered + 1] = c end end
  local added = add_abstractions(g, filtered, ctx, 1, "near_miss")
  if #added == 0 then return nil end
  return "near-miss abstraction: " .. table.concat(added, "; ")
end

function ops_impl.fit_priors(g, ctx)
  local progs = solved_programs(ctx)
  if #progs < 3 then return nil end
  local cnt, total = op_counts(progs)
  local names = {}
  for _, name in ipairs(g.base.ops) do names[#names + 1] = name end
  for _, e in ipairs(g.lib) do names[#names + 1] = e.name end
  -- gentle prior fitting: frequently used ops get cost 1, ordinary ops keep the default,
  -- ops never seen in any solution move one step above the default (max 3). Costs only move by
  -- one unit per candidate so the harness can attribute effects.
  local sorted = {}
  for _, name in ipairs(names) do sorted[#sorted + 1] = name end
  table.sort(sorted, function(a, b) local ca, cb = cnt[a] or 0, cnt[b] or 0 if ca ~= cb then return ca > cb end return a < b end)
  local top = math.max(3, math.floor(#sorted * 0.2))
  local d = g.policy.default_cost or 2
  local changed = 0
  for i, name in ipairs(sorted) do
    local target
    if i <= top and (cnt[name] or 0) > 0 then target = 1
    elseif (cnt[name] or 0) == 0 then target = math.min(3, d + 1)
    else target = d end
    local cur = g.policy.cost[name] or d
    local new = cur + (target > cur and 1 or (target < cur and -1 or 0))
    if new ~= cur then changed = changed + 1 end
    g.policy.cost[name] = new
  end
  if changed == 0 then return nil end
  return string.format("fit priors from %d solutions: %d op costs moved one step", #progs, changed)
end

function ops_impl.prune_dsl_bulk(g, ctx)
  local progs = solved_programs(ctx)
  if #progs < 60 then return nil end
  local cnt = op_counts(progs)
  local keep, dropped = {}, {}
  for _, name in ipairs(g.base.ops) do
    if cnt[name] then keep[#keep + 1] = name else dropped[#dropped + 1] = name end
  end
  if #dropped < 3 or #keep < 25 then return nil end
  -- drop up to a third of the unused ops at once (deterministic subset)
  local n = math.max(3, math.floor(#dropped / 3))
  ctx.rng:shuffle(dropped)
  local removed = {}
  local set = {}
  for i = 1, n do set[dropped[i]] = true removed[#removed + 1] = dropped[i] end
  local ops = {}
  for _, name in ipairs(g.base.ops) do if not set[name] then ops[#ops + 1] = name end end
  g.base.ops = ops
  g.base.dropped = g.base.dropped or {}
  for _, name in ipairs(removed) do g.base.dropped[#g.base.dropped + 1] = name end
  table.sort(removed)
  return string.format("pruned %d ops unused across %d solutions: %s", #removed, #progs, table.concat(removed, " "))
end

function ops_impl.reorder_ops(g, ctx)
  local progs = solved_programs(ctx)
  if #progs < 3 then return nil end
  local cnt = op_counts(progs)
  local ops = g.base.ops
  local idx = {}
  for i, n in ipairs(ops) do idx[n] = i end
  table.sort(ops, function(a, b)
    local ca, cb = cnt[a] or 0, cnt[b] or 0
    if ca ~= cb then return ca > cb end
    return idx[a] < idx[b]
  end)
  return "reordered enumeration by solution usage"
end

function ops_impl.perturb_hyper(g, ctx)
  local rng = ctx.rng
  local p = g.policy
  local choice = rng:int(1, 7)
  if choice == 7 then
    p.coerce_ic = not p.coerce_ic
    return "coerce_ic (int<->colour bank sharing) -> " .. tostring(p.coerce_ic)
  elseif choice == 1 then
    local d = rng:pick({ -1, 1 })
    p.max_cost = math.max(5, math.min(14, p.max_cost + d))
    return "max_cost -> " .. p.max_cost
  elseif choice == 2 then
    local f = rng:pick({ 0.7, 1.4 })
    p.bank_cap = math.max(100, math.min(2000, math.floor(p.bank_cap * f)))
    return "bank_cap -> " .. p.bank_cap
  elseif choice == 3 then
    p.jit = not p.jit
    return "jit -> " .. tostring(p.jit)
  elseif choice == 4 then
    p.jit_rate = p.jit_rate == 1 and 2 or 1
    return "jit_rate -> " .. p.jit_rate
  elseif choice == 5 then
    p.jit_min_match = p.jit_min_match == 1 and 2 or 1
    return "jit_min_match -> " .. p.jit_min_match
  else
    p.default_cost = p.default_cost == 2 and 3 or 2
    return "default_cost -> " .. p.default_cost
  end
end

function ops_impl.const_tune(g, ctx)
  local rng = ctx.rng
  local ty = rng:pick({ "I", "C" })
  local pool = ty == "I" and { 4, 5, 6, 7, 8, 9, 10, -1 } or { 6, 7, 8, 9 }
  local list = g.policy.consts[ty]
  local have = {}
  for _, v in ipairs(list) do have[v] = true end
  if rng:float() < 0.6 then
    local opts = {}
    for _, v in ipairs(pool) do if not have[v] then opts[#opts + 1] = v end end
    if #opts == 0 then return nil end
    local v = rng:pick(opts)
    list[#list + 1] = v
    table.sort(list)
    return "add const " .. ty .. " " .. v
  else
    if #list <= 2 then return nil end
    local i = rng:int(#list)
    local v = table.remove(list, i)
    return "remove const " .. ty .. " " .. v
  end
end

function ops_impl.prune_library(g, ctx)
  if #g.lib == 0 then return nil end
  local progs = solved_programs(ctx)
  local cnt = op_counts(progs)
  local unused = {}
  for i, e in ipairs(g.lib) do if not cnt[e.name] then unused[#unused + 1] = i end end
  if #unused == 0 then return nil end
  local i = unused[ctx.rng:int(#unused)]
  local e = table.remove(g.lib, i)
  g.policy.cost[e.name] = nil
  return "pruned unused " .. e.name .. "=" .. e.expr
end

function ops_impl.drop_op(g, ctx)
  local progs = solved_programs(ctx)
  local cnt = op_counts(progs)
  local unused = {}
  for i, name in ipairs(g.base.ops) do if not cnt[name] then unused[#unused + 1] = i end end
  if #unused == 0 or #g.base.ops <= 20 then return nil end
  local i = unused[ctx.rng:int(#unused)]
  local name = table.remove(g.base.ops, i)
  g.base.dropped = g.base.dropped or {}
  g.base.dropped[#g.base.dropped + 1] = name
  return "dropped unused op " .. name
end

function ops_impl.restore_op(g, ctx)
  if not g.base.dropped or #g.base.dropped == 0 then return nil end
  local i = ctx.rng:int(#g.base.dropped)
  local name = table.remove(g.base.dropped, i)
  g.base.ops[#g.base.ops + 1] = name
  return "restored op " .. name
end

function ops_impl.strategy_swap(g, ctx)
  g.policy.strategy = g.policy.strategy == "probe" and "levelwise" or "probe"
  return "strategy -> " .. g.policy.strategy
end

-- meta: {tried={op=n}, accepted={op=n}}
function M.choose_operator(meta, rng, exclude)
  local weights, total = {}, 0
  for _, op in ipairs(M.operators) do
    if not exclude[op] then
      local t, a = (meta.tried[op] or 0), (meta.accepted[op] or 0)
      local w = (a + 1) / (t + 2) + 0.15 -- Laplace-smoothed success rate + exploration floor
      weights[#weights + 1] = { op, w }
      total = total + w
    end
  end
  if #weights == 0 then return nil end
  local x = rng:float() * total
  for _, e in ipairs(weights) do
    x = x - e[2]
    if x <= 0 then return e[1] end
  end
  return weights[#weights][1]
end

function M.make_candidate(champion, ctx, meta)
  local exclude = {}
  for _ = 1, #M.operators do
    local op = M.choose_operator(meta, ctx.rng, exclude)
    if not op then break end
    local g = genome.clone(champion)
    local ok, desc = pcall(ops_impl[op], g, ctx)
    if ok and desc then
      return g, op, desc
    end
    exclude[op] = true
    if not ok then io.stderr:write("operator " .. op .. " failed: " .. tostring(desc) .. "\n") end
  end
  return nil
end

M.impl = ops_impl
return M
