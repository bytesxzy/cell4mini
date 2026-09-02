-- Seeded task generators. A task is a program-synthesis problem: train examples (shown to the solver),
-- test examples (kernel-only verification). Generation composes ops from the full catalogue,
-- including hidden ops the solver's DSL does not have, so the solver must genuinely compose.
local ops = require("rsi.kernel.ops")
local program = require("rsi.kernel.program")
local RNG = require("rsi.kernel.rng")
local M = {}

-- family definitions: in_type, allowed out types, depth range, whether hidden ops may appear, sizes
M.families = {
  list_d1     = { in_type = "L", outs = { "L", "I" }, depth = { 1, 1 }, hidden = false, maxlen = 7, maxval = 9 },
  list_d2     = { in_type = "L", outs = { "L", "I" }, depth = { 2, 2 }, hidden = false, maxlen = 7, maxval = 9 },
  list_d3     = { in_type = "L", outs = { "L", "I" }, depth = { 3, 3 }, hidden = false, maxlen = 6, maxval = 9 },
  list_hidden = { in_type = "L", outs = { "L", "I", "B" }, depth = { 1, 2 }, hidden = true, maxlen = 7, maxval = 9 },
  list_wide   = { in_type = "L", outs = { "L", "I" }, depth = { 2, 3 }, hidden = true, maxlen = 10, maxval = 30 },
  grid_d1     = { in_type = "G", outs = { "G", "I", "C" }, depth = { 1, 1 }, hidden = false, maxdim = 5 },
  grid_d2     = { in_type = "G", outs = { "G", "I", "L", "C" }, depth = { 2, 2 }, hidden = false, maxdim = 5 },
  grid_d3     = { in_type = "G", outs = { "G", "I", "L" }, depth = { 3, 3 }, hidden = false, maxdim = 4 },
  grid_hidden = { in_type = "G", outs = { "G", "L", "I" }, depth = { 1, 2 }, hidden = true, maxdim = 6 },
  grid_wide   = { in_type = "G", outs = { "G", "I", "L" }, depth = { 2, 3 }, hidden = true, maxdim = 8 },
}

M.family_order = { "list_d1", "list_d2", "list_d3", "list_hidden", "list_wide", "grid_d1", "grid_d2", "grid_d3", "grid_hidden", "grid_wide" }

local cat = ops.catalogue
local by_ret = {}
local names = {}
for name in pairs(cat) do names[#names + 1] = name end
table.sort(names)
for _, name in ipairs(names) do
  local o = cat[name]
  by_ret[o.r] = by_ret[o.r] or {}
  table.insert(by_ret[o.r], name)
end

-- Can type t be produced from in_type within `depth` op applications?
local reach_cache = {}
local function reachable(t, in_type, depth, allow_hidden)
  if t == in_type then return true end
  if depth <= 0 then return false end
  local key = t .. in_type .. depth .. tostring(allow_hidden)
  if reach_cache[key] ~= nil then return reach_cache[key] end
  local r = false
  for _, name in ipairs(by_ret[t] or {}) do
    local o = cat[name]
    if allow_hidden or not o.hidden then
      for _, at in ipairs(o.t) do
        if reachable(at, in_type, depth - 1, allow_hidden) then r = true break end
      end
    end
    if r then break end
  end
  reach_cache[key] = r
  return r
end

local function rand_const(rng, ty, fam)
  if ty == "C" then return program.const(rng:int(0, 9), "C") end
  return program.const(rng:int(fam.in_type == "G" and 1 or 0, 4), "I")
end

-- Build an expression of type `ty` that uses the input variable, with exactly `depth` ops on the var path.
local function gen_expr(rng, ty, depth, fam, allow_hidden)
  if depth == 0 then
    if ty == fam.in_type then return program.var() end
    return nil
  end
  local cands = {}
  for _, name in ipairs(by_ret[ty] or {}) do
    local o = cat[name]
    if allow_hidden or not o.hidden then
      for i, at in ipairs(o.t) do
        if reachable(at, fam.in_type, depth - 1, allow_hidden) then cands[#cands + 1] = { name, i } break end
      end
    end
  end
  if #cands == 0 then return nil end
  for _ = 1, 6 do
    local pick = rng:pick(cands)
    local name = pick[1]
    local o = cat[name]
    -- choose which arg carries the variable path (any arg whose type is reachable)
    local slots = {}
    for i, at in ipairs(o.t) do if reachable(at, fam.in_type, depth - 1, allow_hidden) then slots[#slots + 1] = i end end
    local vslot = rng:pick(slots)
    local args, ok = {}, true
    for i, at in ipairs(o.t) do
      if i == vslot then
        args[i] = gen_expr(rng, at, depth - 1, fam, allow_hidden)
        if not args[i] then ok = false break end
      elseif at == "I" or at == "C" then
        -- occasionally a derived scalar from the input, mostly a constant
        if rng:float() < 0.25 and reachable(at, fam.in_type, 1, allow_hidden) then
          args[i] = gen_expr(rng, at, 1, fam, allow_hidden) or rand_const(rng, at, fam)
        else
          args[i] = rand_const(rng, at, fam)
        end
      elseif at == fam.in_type then
        -- second structural argument: the input itself or a shallow transform of it
        if rng:float() < 0.5 then args[i] = program.var() else args[i] = gen_expr(rng, at, 1, fam, allow_hidden) or program.var() end
      else
        args[i] = gen_expr(rng, at, math.max(depth - 1, 1), fam, allow_hidden)
        if not args[i] then ok = false break end
      end
    end
    if ok then return program.node(name, args) end
  end
  return nil
end

local function rand_list(rng, fam)
  local n = rng:int(3, fam.maxlen or 7)
  local l = {}
  for i = 1, n do l[i] = rng:int(0, fam.maxval or 9) end
  return l
end

local function rand_grid(rng, fam)
  local maxd = fam.maxdim or 5
  local h, w = rng:int(2, maxd), rng:int(2, maxd)
  local palette = { rng:int(1, 9), rng:int(1, 9) }
  local density = 0.3 + 0.4 * rng:float()
  local g = ops.grid(h, w, 0)
  for r = 1, h do for c = 1, w do
    if rng:float() < density then g[r][c] = rng:pick(palette) end
  end end
  return g
end

local function output_ok(v, ty)
  if v == nil then return false end
  local t = ops.typeof(v)
  if ty == "C" then return t == "I" and v >= 0 and v <= 9 end
  if t ~= ty then return false end
  if t == "L" and (#v == 0 or #v > 40) then return false end
  if t == "G" and (v.h * v.w > 400) then return false end
  if t == "I" and math.abs(v) > 100000 then return false end
  return true
end

-- Deterministic generation: task = f(family, salt, index)
function M.generate(family_name, salt, index, n_train, n_test)
  local fam = M.families[family_name]
  if not fam then error("unknown family " .. tostring(family_name)) end
  n_train, n_test = n_train or 3, n_test or 1
  local rng = RNG.new(tostring(salt) .. ":" .. family_name .. ":" .. tostring(index))
  local prims = {}
  for name, o in pairs(cat) do prims[name] = o end
  for attempt = 1, 60 do
    local out_ty = rng:pick(fam.outs)
    local depth = rng:int(fam.depth[1], fam.depth[2])
    local expr = gen_expr(rng, out_ty, depth, fam, fam.hidden)
    if expr and program.uses_var(expr) and program.size(expr) >= depth + 1 then
      local ok, f = pcall(program.compile, expr, prims)
      if ok then
        local examples, good = {}, true
        local first_sig, all_same, any_identity = nil, true, 0
        for i = 1, n_train + n_test do
          local input = fam.in_type == "L" and rand_list(rng, fam) or rand_grid(rng, fam)
          local ok2, out = pcall(f, input)
          if not ok2 or not output_ok(out, out_ty) then good = false break end
          local s = ops.sig(out)
          if first_sig == nil then first_sig = s elseif s ~= first_sig then all_same = false end
          if ops.equal(out, input) then any_identity = any_identity + 1 end
          examples[i] = { input = input, output = out }
        end
        if good and not all_same and any_identity < 2 then
          local train, test = {}, {}
          for i = 1, n_train do train[i] = examples[i] end
          for i = 1, n_test do test[i] = examples[n_train + i] end
          return {
            id = family_name .. "#" .. index,
            family = family_name,
            in_type = fam.in_type,
            out_type = out_ty == "C" and "C" or out_ty,
            train = train, test = test,
            meta = { expr = program.to_string(expr), depth = depth, attempt = attempt },
          }
        end
      end
    end
  end
  return nil
end

-- Generate `count` tasks from a family, skipping indices that fail to produce a valid task.
function M.generate_set(family_name, salt, count, offset)
  local out, idx = {}, offset or 0
  local misses = 0
  while #out < count and misses < count * 10 do
    idx = idx + 1
    local t = M.generate(family_name, salt, idx)
    if t then out[#out + 1] = t else misses = misses + 1 end
  end
  return out, idx
end

-- The solver-facing view: no test examples, no generator metadata.
function M.solver_view(task)
  return { id = task.id, in_type = task.in_type, out_type = task.out_type, train = task.train }
end

return M
