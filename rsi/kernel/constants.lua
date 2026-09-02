-- Constants derived from the task's own examples.
--
-- The policy carries a fixed global pool ({0,1,2,3} for integers, {0..5} for colours). Widening that
-- pool was measured and it LOSES: adding 4..9 cost 3.5pp on 300 tasks, because every extra leaf
-- multiplies through every level of the enumeration. The problem is not that the pool is small, it is
-- that it is task-independent -- a task about the colour 7 gains nothing from the search also
-- carrying 4, 5, 6, 8 and 9.
--
-- So instead of more constants, better ones: a handful read off the examples themselves. This is
-- standard practice in inductive synthesis (FlashFill and its descendants mine literals from the I/O
-- pairs before searching) and it costs almost nothing, because the derived set is small.
--
-- A constant is one value used for every example, so only example-INVARIANT quantities qualify. A
-- value present in one input but not another is not a constant the program can use; that is what
-- `len($)` and `height($)` are for. Hence every rule below intersects or agrees across all examples.
local M = {}

local function values_of(v, into)
  if type(v) == "number" then
    into[v] = true
  elseif type(v) == "table" then
    if v.h then
      for r = 1, v.h do
        for c = 1, v.w do into[v[r][c]] = true end
      end
    else
      for i = 1, #v do into[v[i]] = true end
    end
  end
end

local function intersect(sets)
  if #sets == 0 then return {} end
  local out = {}
  for k in pairs(sets[1]) do
    local all = true
    for i = 2, #sets do
      if not sets[i][k] then all = false break end
    end
    if all then out[#out + 1] = k end
  end
  table.sort(out)
  return out
end

-- All examples agree on this scalar, or nil.
local function agreed(examples, f)
  local first
  for i, ex in ipairs(examples) do
    local ok, v = pcall(f, ex)
    if not ok or v == nil then return nil end
    if i == 1 then first = v elseif v ~= first then return nil end
  end
  return first
end

-- Returns a list of { value = n, ty = "I" | "C" }, at most `cap`, excluding anything the policy
-- pool already provides.
function M.derive(train, have, cap)
  cap = cap or 8
  local in_sets, out_sets = {}, {}
  for _, ex in ipairs(train) do
    local a, b = {}, {}
    values_of(ex.input, a)
    values_of(ex.output, b)
    in_sets[#in_sets + 1] = a
    out_sets[#out_sets + 1] = b
  end

  local ranked = {}
  local seen = {}
  local function offer(v, rank)
    if v == nil or v ~= math.floor(v) or math.abs(v) > 1000 then return end
    if seen[v] then return end
    seen[v] = true
    ranked[#ranked + 1] = { value = v, rank = rank }
  end

  -- A value in every output but no input is the strongest signal there is: the program has to
  -- introduce it from somewhere, and a literal is the only way.
  local in_all_in, in_all_out = {}, {}
  for _, v in ipairs(intersect(in_sets)) do in_all_in[v] = true end
  for _, v in ipairs(intersect(out_sets)) do in_all_out[v] = true end
  for v in pairs(in_all_out) do if not in_all_in[v] then offer(v, 1) end end
  for v in pairs(in_all_out) do if in_all_in[v] then offer(v, 3) end end
  for v in pairs(in_all_in) do offer(v, 4) end

  -- Shapes the examples agree on: a fixed output width is a literal the program may need.
  local function dim(ex, which, side)
    local g = ex[side]
    if type(g) ~= "table" or not g.h then return nil end
    return which == "h" and g.h or g.w
  end
  offer(agreed(train, function(ex) return dim(ex, "h", "output") end), 2)
  offer(agreed(train, function(ex) return dim(ex, "w", "output") end), 2)
  offer(agreed(train, function(ex)
    local o = ex.output
    if type(o) ~= "table" or o.h then return nil end
    return #o
  end), 2)
  -- ratios between input and output size, which is how scaling factors show up
  offer(agreed(train, function(ex)
    local i, o = ex.input, ex.output
    if type(i) ~= "table" or type(o) ~= "table" or not i.h or not o.h then return nil end
    if i.h == 0 or o.h % i.h ~= 0 then return nil end
    return math.floor(o.h / i.h)
  end), 2)

  table.sort(ranked, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    return a.value < b.value
  end)

  local out = {}
  for _, e in ipairs(ranked) do
    if #out >= cap then break end
    local v = e.value
    local as_int = not (have and have.I and have.I[v])
    local as_col = v >= 0 and v <= 9 and not (have and have.C and have.C[v])
    if as_int then out[#out + 1] = { value = v, ty = "I" } end
    if as_col and #out < cap then out[#out + 1] = { value = v, ty = "C" } end
  end
  return out
end

-- Build the lookup the policy pool implies, so derived constants never duplicate it.
function M.pool_set(consts)
  local have = {}
  for ty, list in pairs(consts or {}) do
    have[ty] = {}
    for _, v in ipairs(list) do have[ty][v] = true end
  end
  return have
end

return M
