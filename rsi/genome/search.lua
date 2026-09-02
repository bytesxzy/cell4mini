-- search engine (mutable): bidirectional cost-guided enumeration with observational equivalence.
-- Mechanisms: bottom-up enumeration by integer cost with OE dedup (Udupa et al. / TRANSIT style),
-- Probe-style just-in-time cost learning from partially-correct programs (Barke et al. 2020),
-- learned library primitives enter as ordinary unary ops (DreamCoder-style reuse), and a backward
-- bank built by inverting the goal through invertible operators, met in the middle by the forward
-- enumeration (inverse semantics / witness functions, as in FlashFill-style deductive synthesis).
--
-- The backward bank is the reason this engine is not blind. Forward enumeration spends its budget on
-- breadth and asks "did anything I built happen to equal the target"; the backward bank asks "what
-- would the rest of the program have to produce for this operator to finish the job", which is a
-- deduction, not a guess. Backward entries are counted against the same node budget as forward ones,
-- so the two halves compete for one resource and the comparison against a purely forward search is
-- like for like.
local M = {}

function M.solve(task, ctx)
  local prims, order = ctx.dsl.prims, ctx.dsl.order
  local policy = ctx.policy
  local sig, equal, P = ctx.sig, ctx.equal, ctx.program
  local INV = ctx.inverses
  local train = task.train
  local n = #train
  local inputs, targets = {}, {}
  for i = 1, n do inputs[i] = train[i].input targets[i] = train[i].output end
  local in_type, out_type = task.in_type, task.out_type
  local total_budget, deadline = ctx.budget, ctx.deadline
  local clock = os.clock

  -- op costs: task-conditioned table (learned recognition prior) if one matches this task's features,
  -- otherwise the unconditional learned costs, otherwise the default
  local feat_bucket = ctx.features and ctx.features(task)
  local cond = policy.cond_cost and feat_bucket and policy.cond_cost[feat_bucket]
  local cost = {}
  for _, name in ipairs(order) do cost[name] = (cond and cond[name]) or policy.cost[name] or policy.default_cost end
  -- Branching factor, not depth, is what the node budget buys. A per-bucket whitelist of operators
  -- that have ever appeared in a solution of this task shape narrows every level of the enumeration.
  local narrow = policy.cond_ops and feat_bucket and policy.cond_ops[feat_bucket]

  -- Two-phase portfolio. Measured: a per-bucket operator whitelist saves ~23% of the nodes and wins
  -- 11 tasks the wide enumeration misses, but loses 22 by excluding operators it turns out to need.
  -- So run the narrow enumeration first on a slice of the budget, then fall back to the full operator
  -- set with what remains. The narrow phase keeps its wins; the fallback keeps the losses off.
  local nodes = 0
  local function enumerate(allow, budget)
  local bank, seen = {}, {}
  local function bucket(ty, c)
    local b = bank[ty]
    if not b then b = {} bank[ty] = b end
    local l = b[c]
    if not l then l = {} b[c] = l end
    return l
  end

  local best_matches, best_node = 0, nil
  local level_partials = {}

  -- ---------- backward bank ----------
  -- A backward entry maps a value-tuple the forward search might produce to a context that turns it
  -- into the target. Each step is verified by applying the operator forward to the candidate
  -- preimage, so reaching an entry is a solution by construction rather than a hypothesis.
  local back, back_n = {}, 0
  local function back_key(ty, vals)
    local parts = {}
    for i = 1, n do parts[i] = sig(vals[i]) end
    return ty .. "|" .. table.concat(parts, ";")
  end

  local function add_back(vals, ty, c, parent, name, kconst, nextf)
    local key = back_key(ty, vals)
    if back[key] then return end
    nodes = nodes + 1
    back_n = back_n + 1
    local pb = parent.build
    local build
    if kconst then
      build = function(node) return pb(P.node(name, { node, kconst })) end
    else
      build = function(node) return pb(P.node(name, { node })) end
    end
    local e = { vals = vals, ty = ty, cost = c, build = build }
    back[key] = e
    nextf[#nextf + 1] = e
  end

  -- Only a minority of operators are invertible. Scanning the whole DSL for every frontier entry was
  -- the dominant cost of the backward bank; indexing by return type cuts that loop by an order of
  -- magnitude, which matters because the wall-clock deadline, not the node budget, was the binding
  -- constraint when this was measured.
  local inv_by_ret = nil
  local function index_inverses(allow)
    local idx = {}
    for _, name in ipairs(order) do
      local p = prims[name]
      local has = (INV.inv1[name] and #p.t == 1) or (INV.inv2[name] and #p.t == 2)
      if has and not (p.bucket and p.bucket ~= feat_bucket) and not (allow and not allow[name]) then
        idx[p.r] = idx[p.r] or {}
        table.insert(idx[p.r], name)
      end
    end
    return idx
  end

  local function build_back(allow, budget)
    inv_by_ret = index_inverses(allow)
    local root = { vals = targets, ty = out_type, cost = 0, build = function(node) return node end }
    back[back_key(out_type, targets)] = root
    -- an integer-valued forward program can answer a colour-typed task and the other way round
    local alt = (out_type == "C" and "I") or (out_type == "I" and "C") or nil
    if alt then back[back_key(alt, targets)] = root end
    local frontier = { root }
    local maxc = policy.back_max_cost or 6
    local cap = policy.back_cap or 400
    for _ = 1, maxc do
      local nextf = {}
      for _, e in ipairs(frontier) do
        for _, name in ipairs(inv_by_ret[e.ty] or {}) do
          if nodes >= budget or back_n >= cap then return end
          local p = prims[name]
          do
            local nc = e.cost + cost[name]
            if nc <= maxc then
              local k1, k2 = INV.inv1[name], INV.inv2[name]
              if k1 and #p.t == 1 then
                local cand, ok = {}, true
                for i = 1, n do
                  local ok2, v = pcall(k1, e.vals[i])
                  if not ok2 or v == nil then ok = false break end
                  local ok3, chk = pcall(p.f, v)
                  if not ok3 or not equal(chk, e.vals[i]) then ok = false break end
                  cand[i] = v
                end
                if ok then add_back(cand, p.t[1], nc, e, name, nil, nextf) end
              elseif k2 and #p.t == 2 then
                for _, kv in ipairs(policy.consts[p.t[2]] or {}) do
                  local cand, ok = {}, true
                  for i = 1, n do
                    local ok2, v = pcall(k2, e.vals[i], kv)
                    if not ok2 or v == nil then ok = false break end
                    local ok3, chk = pcall(p.f, v, kv)
                    if not ok3 or not equal(chk, e.vals[i]) then ok = false break end
                    cand[i] = v
                  end
                  if ok then add_back(cand, p.t[1], nc, e, name, P.const(kv, p.t[2]), nextf) end
                end
              end
            end
          end
        end
      end
      frontier = nextf
      if #frontier == 0 then break end
    end
  end

  -- Values already in the forward bank were created before the backward bank existed, so they were
  -- never offered a meet. One sweep after the bank is built catches them.
  local function sweep_bank()
    for ty, byc in pairs(bank) do
      for _, list in pairs(byc) do
        for _, e in ipairs(list) do
          local hit = back[back_key(ty, e.outs)]
          if hit then return hit.build(e.node) end
        end
      end
    end
    return nil
  end

  -- The backward bank is built lazily. Measured: building it up front cost seven depth-1 list tasks,
  -- because a task solvable by a single operator was made to pay for machinery it never needed and
  -- ran out of wall-clock before the forward search started. Deferring it until the forward search
  -- has exhausted every depth-1 program (all of which have cost <= 3) makes the investment conditional
  -- on the task actually being hard.
  local back_built = false
  local function maybe_build_back(allow)
    if back_built or not (policy.bidirectional and INV) then return nil end
    back_built = true
    build_back(allow, math.min(budget, nodes + math.floor(total_budget * (policy.back_frac or 0.25))))
    return sweep_bank()
  end

  local function type_matches(ty)
    return ty == out_type or (out_type == "C" and ty == "I") or (out_type == "I" and ty == "C")
  end

  -- returns solution node if all train examples match
  local function consider(ty, c, node, outs)
    local parts = {}
    for i = 1, n do parts[i] = sig(outs[i]) end
    local key = ty .. "|" .. table.concat(parts, ";")
    if seen[key] then return nil end
    seen[key] = true
    nodes = nodes + 1
    -- meet in the middle: this value is one the backward chain knows how to finish
    local hit = back[key]
    if hit then return hit.build(node) end
    local l = bucket(ty, c)
    if #l < policy.bank_cap then
      local entry = { node = node, outs = outs }
      l[#l + 1] = entry
      -- optional int<->colour sharing: small non-negative ints may feed colour slots and vice versa
      if policy.coerce_ic and (ty == "I" or ty == "C") then
        local other = ty == "I" and "C" or "I"
        local fits = true
        if other == "C" then
          for i = 1, n do local v = outs[i] if v < 0 or v > 9 or v ~= math.floor(v) then fits = false break end end
        end
        if fits then
          local l2 = bucket(other, c)
          if #l2 < policy.bank_cap then l2[#l2 + 1] = entry end
        end
      end
    end
    if type_matches(ty) then
      local m = 0
      for i = 1, n do if equal(outs[i], targets[i]) then m = m + 1 end end
      if m == n then return node end
      if m > best_matches then best_matches, best_node = m, node end
      if m >= policy.jit_min_match then level_partials[#level_partials + 1] = node end
    end
    return nil
  end

  -- leaves
  do
    local outs = {}
    for i = 1, n do outs[i] = inputs[i] end
    consider(in_type, policy.leaf_cost, P.var(), outs)
    for ty, list in pairs(policy.consts) do
      for _, v in ipairs(list) do
        local o = {}
        for i = 1, n do o[i] = v end
        local s = consider(ty, policy.const_cost, P.const(v, ty), o)
        if s then return { program = s, nodes = nodes, partial = 1 } end
      end
    end
  end

  local function apply1(f, a)
    local outs = {}
    for i = 1, n do outs[i] = f(a.outs[i]) end
    return outs
  end
  local function apply2(f, a, b)
    local outs = {}
    for i = 1, n do outs[i] = f(a.outs[i], b.outs[i]) end
    return outs
  end
  local function apply3(f, a, b, c)
    local outs = {}
    for i = 1, n do outs[i] = f(a.outs[i], b.outs[i], c.outs[i]) end
    return outs
  end

  local function exhausted()
    if nodes >= budget then return true end
    if nodes % 64 == 0 and clock() > deadline then return true end
    return false
  end

  for C = 2, policy.max_cost do
    if C > (policy.back_after_cost or 3) then
      local s = maybe_build_back(allow)
      if s then return { program = s, nodes = nodes, partial = 1 } end
    end
    level_partials = {}
    for _, name in ipairs(order) do
      local p = prims[name]
      local w = cost[name]
      local R = C - w
      local k = #p.t
      -- a bucket-scoped abstraction only enters the enumeration for tasks of that shape, so learned
      -- ops cost nothing on the tasks they were not learned from
      if p.bucket and p.bucket ~= feat_bucket then R = -1 end
      if allow and not allow[name] then R = -1 end
      if R >= k then
        local f, t = p.f, p.t
        if k == 1 then
          local A = bank[t[1]] and bank[t[1]][R]
          if A then
            for ai = 1, #A do
              local a = A[ai]
              local ok, outs = pcall(apply1, f, a)
              if ok then
                local s = consider(p.r, C, P.node(name, { a.node }), outs)
                if s then return { program = s, nodes = nodes, partial = 1 } end
              end
              if exhausted() then return { program = nil, nodes = nodes, partial = best_matches / n, best_partial = best_node } end
            end
          end
        elseif k == 2 then
          for c1 = 1, R - 1 do
            local c2 = R - c1
            local A = bank[t[1]] and bank[t[1]][c1]
            local B = bank[t[2]] and bank[t[2]][c2]
            if A and B then
              for ai = 1, #A do
                local a = A[ai]
                for bi = 1, #B do
                  local b = B[bi]
                  local ok, outs = pcall(apply2, f, a, b)
                  if ok then
                    local s = consider(p.r, C, P.node(name, { a.node, b.node }), outs)
                    if s then return { program = s, nodes = nodes, partial = 1 } end
                  end
                  if exhausted() then return { program = nil, nodes = nodes, partial = best_matches / n, best_partial = best_node } end
                end
              end
            end
          end
        elseif k == 3 then
          for c1 = 1, R - 2 do
            for c2 = 1, R - 1 - c1 do
              local c3 = R - c1 - c2
              local A = bank[t[1]] and bank[t[1]][c1]
              local B = bank[t[2]] and bank[t[2]][c2]
              local Cc = bank[t[3]] and bank[t[3]][c3]
              if A and B and Cc then
                for ai = 1, #A do
                  for bi = 1, #B do
                    for ci = 1, #Cc do
                      local a, b, c = A[ai], B[bi], Cc[ci]
                      local ok, outs = pcall(apply3, f, a, b, c)
                      if ok then
                        local s = consider(p.r, C, P.node(name, { a.node, b.node, c.node }), outs)
                        if s then return { program = s, nodes = nodes, partial = 1 } end
                      end
                      if exhausted() then return { program = nil, nodes = nodes, partial = best_matches / n, best_partial = best_node } end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
    -- just-in-time learning: ops appearing in partially-correct programs become cheaper for later levels
    if policy.jit and policy.strategy == "probe" and #level_partials > 0 then
      local touched = {}
      for _, node in ipairs(level_partials) do
        for _, op in ipairs(P.ops_used(node)) do touched[op] = true end
      end
      for op in pairs(touched) do cost[op] = math.max(1, cost[op] - policy.jit_rate) end
    end
  end
  return { program = nil, nodes = nodes, partial = best_matches / n, best_partial = best_node }
  end

  if narrow and policy.two_phase then
    local first = enumerate(narrow, math.floor(total_budget * (policy.phase1_frac or 0.5)))
    if first.program then return first end
    local second = enumerate(nil, total_budget)
    if second.partial >= first.partial then return second end
    second.partial, second.best_partial = first.partial, first.best_partial
    return second
  end
  return enumerate(narrow, total_budget)
end

return M
