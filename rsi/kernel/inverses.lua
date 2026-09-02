-- Inverse semantics: for an operator f and a desired output o, a *candidate* preimage x with f(x)=o.
--
-- Why this exists. Bottom-up enumeration is blind: it builds every program of cost c and asks whether
-- any of them happens to hit the target. The node budget is spent on breadth, and the measured
-- bottleneck of this system is branching factor, not depth. Inverting the goal turns the outermost
-- operators from things to be *guessed* into things to be *deduced*: if the task's output is a
-- 90-degree rotation of something, then rotating the output back by 90 degrees says exactly what the
-- rest of the program has to produce. A depth-4 search becomes a depth-2 forward search meeting a
-- depth-2 backward chain.
--
-- Candidates are never trusted. The caller applies f to the candidate and keeps it only if the result
-- equals o on every training example. That makes a wrong or partial rule harmless (it is simply
-- rejected) and lets these rules be liberal: `shift_down` is not injective, but shifting the output
-- back up produces a preimage that verifies exactly when nothing was pushed off the edge, which is
-- the case that matters.
--
-- Only value-changing operators are listed. An idempotent operator (sort, gravity, crop_bbox) inverts
-- to the identity when the target is already a fixed point, which produces a backward entry with the
-- same value and type as one already present, so it is deduplicated away and buys nothing.
local ops = require("rsi.kernel.ops")
local L, G = ops.L, ops.G
local floor = math.floor
local M = {}

-- inv1[name](o) -> candidate preimage, or nil when this output cannot have come from this operator.
M.inv1 = {
  -- list
  reverse = function(o) return L.reverse(o) end,
  cumsum = function(o)
    local x = {}
    for i = 1, #o do x[i] = (i == 1) and o[1] or (o[i] - o[i - 1]) end
    return x
  end,
  mirror = function(o)
    local m = #o
    if m == 0 or m % 2 ~= 0 then return nil end
    local x = {}
    for i = 1, floor(m / 2) do x[i] = o[i] end
    return x
  end,
  singleton = function(o) if #o == 1 then return o[1] end return nil end,
  range = function(o) return #o end,
  from_row = function(o) if o.h == 1 then return G.row(o, 1) end return nil end,
  -- int
  inc = function(o) return o - 1 end,
  dec = function(o) return o + 1 end,
  neg = function(o) return -o end,
  double = function(o) if o % 2 == 0 then return floor(o / 2) end return nil end,
  sq = function(o)
    if o < 0 then return nil end
    local r = floor(math.sqrt(o) + 0.5)
    if r * r == o then return r end
    return nil
  end,
  -- grid: the structural transformations, which are exactly the ones that make grid tasks deep
  flip_h = function(o) return G.flip_h(o) end,
  flip_v = function(o) return G.flip_v(o) end,
  transpose = function(o) return G.transpose(o) end,
  rot90 = function(o) return G.rot270(o) end,
  rot180 = function(o) return G.rot180(o) end,
  rot270 = function(o) return G.rot90(o) end,
  mirror_h = function(o) if o.w % 2 ~= 0 then return nil end return G.left_half(o) end,
  mirror_v = function(o) if o.h % 2 ~= 0 then return nil end return G.top_half(o) end,
  tile2x2 = function(o)
    if o.h % 2 ~= 0 or o.w % 2 ~= 0 then return nil end
    return G.left_half(G.top_half(o))
  end,
  invert_mask = function(o) return G.invert_mask(o) end,
  remove_border = function(o) return G.add_border(o, 0) end,
}

-- inv2[name](o, k) -> candidate preimage for the FIRST argument, with the second argument fixed to
-- the constant k drawn from the policy's constant pool for that argument's type.
M.inv2 = {
  -- list
  map_add = function(o, k) return L.map_sub(o, k) end,
  map_sub = function(o, k) return L.map_add(o, k) end,
  map_mul = function(o, k)
    if k == 0 then return nil end
    local x = {}
    for i = 1, #o do
      if o[i] % k ~= 0 then return nil end
      x[i] = floor(o[i] / k)
    end
    return x
  end,
  rotate = function(o, k) return L.rotate(o, -k) end,
  push_front = function(o, x) if #o >= 1 and o[1] == x then return L.tail(o) end return nil end,
  push_back = function(o, x) if #o >= 1 and o[#o] == x then return L.init(o) end return nil end,
  repeat_list = function(o, k)
    if k < 1 or #o == 0 or #o % k ~= 0 then return nil end
    local x = {}
    for i = 1, floor(#o / k) do x[i] = o[i] end
    return x
  end,
  -- int
  add = function(o, k) return o - k end,
  sub = function(o, k) return o + k end,
  mul = function(o, k)
    if k == 0 or o % k ~= 0 then return nil end
    return floor(o / k)
  end,
  -- grid
  upscale = function(o, k)
    if k < 1 or o.h % k ~= 0 or o.w % k ~= 0 then return nil end
    return G.downscale(o, k)
  end,
  downscale = function(o, k)
    if k < 1 or k > 5 then return nil end
    return G.upscale(o, k)
  end,
  add_border = function(o, c)
    if o.h < 3 or o.w < 3 then return nil end
    return G.remove_border(o)
  end,
  shift_down = function(o, k) return G.shift_down(o, -k) end,
  shift_right = function(o, k) return G.shift_right(o, -k) end,
}

-- Binary meet. For an operator of two non-constant arguments, one argument taken from the forward
-- bank determines what the other must be: if the target is a wide grid and the left part is
-- something the search already knows how to build, the right part is fully determined. These rules
-- are also candidates only, and are verified forward exactly like the others.
local function grid_cols(g, c1, c2)
  if c1 > c2 or c1 < 1 or c2 > g.w then return nil end
  local o = { h = g.h, w = c2 - c1 + 1 }
  for r = 1, g.h do
    local row = {}
    for c = c1, c2 do row[c - c1 + 1] = g[r][c] end
    o[r] = row
  end
  return o
end

local function grid_rows(g, r1, r2)
  if r1 > r2 or r1 < 1 or r2 > g.h then return nil end
  local o = { h = r2 - r1 + 1, w = g.w }
  for r = r1, r2 do
    local row = {}
    for c = 1, g.w do row[c] = g[r][c] end
    o[r - r1 + 1] = row
  end
  return o
end

-- inv_arg2[name](o, a) -> the second argument b such that f(a, b) = o
M.inv_arg2 = {
  hcat = function(o, a) if o.h ~= a.h or a.w >= o.w then return nil end return grid_cols(o, a.w + 1, o.w) end,
  vcat = function(o, a) if o.w ~= a.w or a.h >= o.h then return nil end return grid_rows(o, a.h + 1, o.h) end,
  concat = function(o, a)
    if #a >= #o then return nil end
    local b = {}
    for i = #a + 1, #o do b[#b + 1] = o[i] end
    return b
  end,
  zip_add = function(o, a)
    if #o ~= #a then return nil end
    local b = {}
    for i = 1, #o do b[i] = o[i] - a[i] end
    return b
  end,
  -- overlay takes b's non-zero cells over a, so where the target already agrees with a the second
  -- argument may be zero, and where it differs it is pinned to the target
  overlay = function(o, a)
    if o.h ~= a.h or o.w ~= a.w then return nil end
    local b = ops.grid(o.h, o.w, 0)
    for r = 1, o.h do
      for c = 1, o.w do if o[r][c] ~= a[r][c] then b[r][c] = o[r][c] end end
    end
    return b
  end,
}

-- inv_arg1[name](o, b) -> the first argument a such that f(a, b) = o
M.inv_arg1 = {
  hcat = function(o, b) if o.h ~= b.h or b.w >= o.w then return nil end return grid_cols(o, 1, o.w - b.w) end,
  vcat = function(o, b) if o.w ~= b.w or b.h >= o.h then return nil end return grid_rows(o, 1, o.h - b.h) end,
  concat = function(o, b)
    if #b >= #o then return nil end
    local a = {}
    for i = 1, #o - #b do a[i] = o[i] end
    return a
  end,
  zip_add = function(o, b)
    if #o ~= #b then return nil end
    local a = {}
    for i = 1, #o do a[i] = o[i] - b[i] end
    return a
  end,
  overlay = function(o, b)
    if o.h ~= b.h or o.w ~= b.w then return nil end
    local a = ops.copy_grid(o)
    for r = 1, o.h do
      for c = 1, o.w do if b[r][c] ~= 0 then a[r][c] = 0 end end
    end
    return a
  end,
}

function M.count()
  local a, b = 0, 0
  for _ in pairs(M.inv1) do a = a + 1 end
  for _ in pairs(M.inv2) do b = b + 1 end
  return a, b
end

return M
