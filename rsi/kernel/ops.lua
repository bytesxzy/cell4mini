-- Value model + the full operation catalogue used by the task generators.
-- The genome's DSL (rsi/genome/dsl_base.lua) selects a *subset* of these by name;
-- ops marked hidden=true exist only in the generators, so the solver must compose to reach them.
-- Types: I=int, L=list of int, G=grid (g[r][c], g.h, g.w), B=bool, C=color (int 0..9)
local M = {}

M.MAX_LIST = 256
M.MAX_DIM = 30

local floor = math.floor

-- ---------- constructors / equality / signatures ----------
function M.grid(h, w, fill)
  local g = { h = h, w = w }
  for r = 1, h do
    local row = {}
    for c = 1, w do row[c] = fill or 0 end
    g[r] = row
  end
  return g
end

function M.copy_grid(g)
  local o = { h = g.h, w = g.w }
  for r = 1, g.h do
    local row, src = {}, g[r]
    for c = 1, g.w do row[c] = src[c] end
    o[r] = row
  end
  return o
end

function M.equal(a, b)
  local ta, tb = type(a), type(b)
  if ta ~= tb then return false end
  if ta ~= "table" then return a == b end
  if a.h then
    if not b.h or a.h ~= b.h or a.w ~= b.w then return false end
    for r = 1, a.h do
      local ra, rb = a[r], b[r]
      for c = 1, a.w do if ra[c] ~= rb[c] then return false end end
    end
    return true
  end
  if b.h or #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

function M.sig(v)
  local t = type(v)
  if t == "number" then return "I" .. v end
  if t == "boolean" then return v and "T" or "F" end
  if t ~= "table" then return "?" end
  if v.h then
    local parts = { "G", v.h, "x", v.w, ":" }
    for r = 1, v.h do parts[#parts + 1] = table.concat(v[r], ",") parts[#parts + 1] = "|" end
    return table.concat(parts)
  end
  return "L" .. table.concat(v, ",")
end

function M.show(v)
  local t = type(v)
  if t ~= "table" then return tostring(v) end
  if v.h then
    local rows = {}
    for r = 1, v.h do rows[r] = table.concat(v[r], " ") end
    return "[" .. table.concat(rows, " / ") .. "]"
  end
  return "[" .. table.concat(v, ",") .. "]"
end

function M.typeof(v)
  local t = type(v)
  if t == "number" then return "I" end
  if t == "boolean" then return "B" end
  if t == "table" then return v.h and "G" or "L" end
  return "?"
end

local function chk_list(l) if #l > M.MAX_LIST then error("list too long") end return l end
local function chk_grid(g) if g.h > M.MAX_DIM or g.w > M.MAX_DIM or g.h < 1 or g.w < 1 then error("grid dim") end return g end
local function chk_int(x)
  if x ~= x or x == math.huge or x == -math.huge or math.abs(x) > 1e9 then error("int range") end
  return x
end

-- ---------- list ops ----------
local L = {}
function L.reverse(l) local o = {} for i = #l, 1, -1 do o[#o + 1] = l[i] end return o end
function L.sort(l) local o = {} for i = 1, #l do o[i] = l[i] end table.sort(o) return o end
function L.sort_desc(l) local o = L.sort(l) return L.reverse(o) end
function L.head(l) if #l == 0 then error("empty") end return l[1] end
function L.last(l) if #l == 0 then error("empty") end return l[#l] end
function L.tail(l) local o = {} for i = 2, #l do o[#o + 1] = l[i] end return o end
function L.init(l) local o = {} for i = 1, #l - 1 do o[#o + 1] = l[i] end return o end
function L.len(l) return #l end
function L.sum(l) local s = 0 for i = 1, #l do s = s + l[i] end return s end
function L.max(l) if #l == 0 then error("empty") end local m = l[1] for i = 2, #l do if l[i] > m then m = l[i] end end return m end
function L.min(l) if #l == 0 then error("empty") end local m = l[1] for i = 2, #l do if l[i] < m then m = l[i] end end return m end
function L.map_add(l, k) local o = {} for i = 1, #l do o[i] = chk_int(l[i] + k) end return o end
function L.map_sub(l, k) local o = {} for i = 1, #l do o[i] = chk_int(l[i] - k) end return o end
function L.map_mul(l, k) local o = {} for i = 1, #l do o[i] = chk_int(l[i] * k) end return o end
function L.map_mod(l, k) if k == 0 then error("mod0") end local o = {} for i = 1, #l do o[i] = l[i] % k end return o end
function L.filter_even(l) local o = {} for i = 1, #l do if l[i] % 2 == 0 then o[#o + 1] = l[i] end end return o end
function L.filter_odd(l) local o = {} for i = 1, #l do if l[i] % 2 ~= 0 then o[#o + 1] = l[i] end end return o end
function L.filter_gt(l, k) local o = {} for i = 1, #l do if l[i] > k then o[#o + 1] = l[i] end end return o end
function L.filter_lt(l, k) local o = {} for i = 1, #l do if l[i] < k then o[#o + 1] = l[i] end end return o end
function L.take(l, k) local o = {} for i = 1, math.min(#l, math.max(k, 0)) do o[i] = l[i] end return o end
function L.drop(l, k) local o = {} for i = math.max(k, 0) + 1, #l do o[#o + 1] = l[i] end return o end
function L.rotate(l, k) local n = #l if n == 0 then return {} end local o = {} for i = 1, n do o[i] = l[((i - 1 + k) % n) + 1] end return o end
function L.concat(a, b) local o = {} for i = 1, #a do o[#o + 1] = a[i] end for i = 1, #b do o[#o + 1] = b[i] end return chk_list(o) end
function L.dedup(l) local o, seen = {}, {} for i = 1, #l do if not seen[l[i]] then seen[l[i]] = true o[#o + 1] = l[i] end end return o end
function L.cumsum(l) local o, s = {}, 0 for i = 1, #l do s = s + l[i] o[i] = s end return o end
function L.diffs(l) local o = {} for i = 2, #l do o[#o + 1] = l[i] - l[i - 1] end return o end
function L.count(l, k) local c = 0 for i = 1, #l do if l[i] == k then c = c + 1 end end return c end
function L.index_of(l, k) for i = 1, #l do if l[i] == k then return i end end return 0 end
function L.range(n) if n < 0 or n > M.MAX_LIST then error("range") end local o = {} for i = 1, n do o[i] = i end return o end
function L.singleton(x) return { x } end
function L.nth(l, k) if k < 1 or k > #l then error("oob") end return l[k] end
function L.abs_all(l) local o = {} for i = 1, #l do o[i] = math.abs(l[i]) end return o end
function L.mirror(l) return L.concat(l, L.reverse(l)) end
function L.repeat_list(l, k) local o = {} for _ = 1, math.max(k, 0) do for i = 1, #l do o[#o + 1] = l[i] end end return chk_list(o) end
function L.zip_add(a, b) if #a ~= #b then error("len") end local o = {} for i = 1, #a do o[i] = chk_int(a[i] + b[i]) end return o end
function L.evens_idx(l) local o = {} for i = 2, #l, 2 do o[#o + 1] = l[i] end return o end
function L.odds_idx(l) local o = {} for i = 1, #l, 2 do o[#o + 1] = l[i] end return o end
function L.push_front(l, x) local o = { x } for i = 1, #l do o[#o + 1] = l[i] end return chk_list(o) end
function L.push_back(l, x) local o = {} for i = 1, #l do o[#o + 1] = l[i] end o[#o + 1] = x return chk_list(o) end
function L.product(l) local p = 1 for i = 1, #l do p = chk_int(p * l[i]) end return p end
function L.unique_count(l) return #L.dedup(l) end
-- hidden-only list ops (generators use them; not in the base DSL)
function L.mode(l) if #l == 0 then error("empty") end local cnt, best, bc = {}, nil, -1 for i = 1, #l do cnt[l[i]] = (cnt[l[i]] or 0) + 1 end for i = 1, #l do local v = l[i] if cnt[v] > bc or (cnt[v] == bc and v < best) then best, bc = v, cnt[v] end end return best end
function L.second_largest(l) local d = L.sort_desc(L.dedup(l)) if #d < 2 then error("n/a") end return d[2] end
function L.median(l) if #l == 0 then error("empty") end local s = L.sort(l) return s[floor((#s + 1) / 2)] end
function L.sort_by_freq(l) local cnt = {} for i = 1, #l do cnt[l[i]] = (cnt[l[i]] or 0) + 1 end local o = {} for i = 1, #l do o[i] = l[i] end table.sort(o, function(a, b) if cnt[a] ~= cnt[b] then return cnt[a] > cnt[b] end return a < b end) return o end
function L.remove_all(l, k) local o = {} for i = 1, #l do if l[i] ~= k then o[#o + 1] = l[i] end end return o end
function L.running_max(l) local o, m = {}, nil for i = 1, #l do if not m or l[i] > m then m = l[i] end o[i] = m end return o end
function L.argmax(l) if #l == 0 then error("empty") end local bi = 1 for i = 2, #l do if l[i] > l[bi] then bi = i end end return bi end
function L.is_sorted(l) for i = 2, #l do if l[i] < l[i - 1] then return false end end return true end
function L.is_palindrome(l) for i = 1, floor(#l / 2) do if l[i] ~= l[#l + 1 - i] then return false end end return true end
function L.squares(l) local o = {} for i = 1, #l do o[i] = chk_int(l[i] * l[i]) end return o end
function L.pairwise_sums(l) local o = {} for i = 1, #l - 1 do o[#o + 1] = l[i] + l[i + 1] end return o end
function L.swap_halves(l) local n = #l local h = floor(n / 2) local o = {} for i = h + 1, n do o[#o + 1] = l[i] end for i = 1, h do o[#o + 1] = l[i] end return o end

-- ---------- int ops ----------
local I = {}
function I.add(a, b) return chk_int(a + b) end
function I.sub(a, b) return chk_int(a - b) end
function I.mul(a, b) return chk_int(a * b) end
function I.div(a, b) if b == 0 then error("div0") end return floor(a / b) end
function I.mod(a, b) if b == 0 then error("mod0") end return a % b end
function I.max2(a, b) return a > b and a or b end
function I.min2(a, b) return a < b and a or b end
function I.sq(a) return chk_int(a * a) end
function I.inc(a) return a + 1 end
function I.dec(a) return a - 1 end
function I.double(a) return chk_int(a * 2) end
function I.half(a) return floor(a / 2) end
function I.abs(a) return math.abs(a) end
function I.neg(a) return -a end
function I.is_even(a) return a % 2 == 0 end
function I.gt(a, b) return a > b end
function I.eq(a, b) return a == b end
function I.if_int(c, a, b) if c then return a else return b end end
-- hidden
function I.digit_sum(a) a = math.abs(a) local s = 0 while a > 0 do s = s + a % 10 a = floor(a / 10) end return s end
function I.triangular(a) if a < 0 or a > 30000 then error("range") end return floor(a * (a + 1) / 2) end

-- ---------- grid ops ----------
local G = {}
function G.flip_h(g) local o = { h = g.h, w = g.w } for r = 1, g.h do local row = {} for c = 1, g.w do row[c] = g[r][g.w + 1 - c] end o[r] = row end return o end
function G.flip_v(g) local o = { h = g.h, w = g.w } for r = 1, g.h do o[r] = g[g.h + 1 - r] end return M.copy_grid(o) end
function G.transpose(g) local o = { h = g.w, w = g.h } for r = 1, g.w do local row = {} for c = 1, g.h do row[c] = g[c][r] end o[r] = row end return o end
function G.rot90(g) return G.flip_h(G.transpose(g)) end
function G.rot180(g) return G.flip_h(G.flip_v(g)) end
function G.rot270(g) return G.flip_v(G.transpose(g)) end
function G.height(g) return g.h end
function G.width(g) return g.w end
function G.hcat(a, b) if a.h ~= b.h then error("h mismatch") end local o = { h = a.h, w = a.w + b.w } for r = 1, a.h do local row = {} for c = 1, a.w do row[c] = a[r][c] end for c = 1, b.w do row[a.w + c] = b[r][c] end o[r] = row end return chk_grid(o) end
function G.vcat(a, b) if a.w ~= b.w then error("w mismatch") end local o = { h = a.h + b.h, w = a.w } for r = 1, a.h do o[r] = a[r] end for r = 1, b.h do o[a.h + r] = b[r] end return chk_grid(M.copy_grid(o)) end
function G.mirror_h(g) return G.hcat(g, G.flip_h(g)) end
function G.mirror_v(g) return G.vcat(g, G.flip_v(g)) end
function G.upscale(g, k) if k < 1 or k > 5 then error("k") end local o = { h = g.h * k, w = g.w * k } chk_grid(o) for r = 1, o.h do local row = {} local src = g[floor((r - 1) / k) + 1] for c = 1, o.w do row[c] = src[floor((c - 1) / k) + 1] end o[r] = row end return o end
function G.downscale(g, k) if k < 1 or g.h % k ~= 0 or g.w % k ~= 0 then error("k") end local o = { h = g.h / k, w = g.w / k } for r = 1, o.h do local row = {} for c = 1, o.w do row[c] = g[(r - 1) * k + 1][(c - 1) * k + 1] end o[r] = row end return o end
function G.recolor(g, a, b) local o = M.copy_grid(g) for r = 1, o.h do for c = 1, o.w do if o[r][c] == a then o[r][c] = b end end end return o end
function G.fill_nonzero(g, col) local o = M.copy_grid(g) for r = 1, o.h do for c = 1, o.w do if o[r][c] ~= 0 then o[r][c] = col end end end return o end
function G.count_color(g, col) local n = 0 for r = 1, g.h do for c = 1, g.w do if g[r][c] == col then n = n + 1 end end end return n end
function G.most_color(g) local cnt = {} for r = 1, g.h do for c = 1, g.w do cnt[g[r][c]] = (cnt[g[r][c]] or 0) + 1 end end local best, bc = 0, -1 for col = 0, 9 do if (cnt[col] or 0) > bc then best, bc = col, cnt[col] or 0 end end return best end
function G.most_nonzero_color(g) local cnt = {} for r = 1, g.h do for c = 1, g.w do local v = g[r][c] if v ~= 0 then cnt[v] = (cnt[v] or 0) + 1 end end end local best, bc = 0, 0 for col = 1, 9 do if (cnt[col] or 0) > bc then best, bc = col, cnt[col] end end return best end
function G.least_nonzero_color(g) local cnt = {} for r = 1, g.h do for c = 1, g.w do local v = g[r][c] if v ~= 0 then cnt[v] = (cnt[v] or 0) + 1 end end end local best, bc = 0, math.huge for col = 1, 9 do if cnt[col] and cnt[col] < bc then best, bc = col, cnt[col] end end return best end
function G.crop_bbox(g) local r1, r2, c1, c2 = g.h + 1, 0, g.w + 1, 0 for r = 1, g.h do for c = 1, g.w do if g[r][c] ~= 0 then if r < r1 then r1 = r end if r > r2 then r2 = r end if c < c1 then c1 = c end if c > c2 then c2 = c end end end end if r2 == 0 then error("empty") end local o = { h = r2 - r1 + 1, w = c2 - c1 + 1 } for r = r1, r2 do local row = {} for c = c1, c2 do row[c - c1 + 1] = g[r][c] end o[r - r1 + 1] = row end return o end
function G.gravity_down(g) local o = M.grid(g.h, g.w, 0) for c = 1, g.w do local wr = g.h for r = g.h, 1, -1 do if g[r][c] ~= 0 then o[wr][c] = g[r][c] wr = wr - 1 end end end return o end
function G.gravity_up(g) return G.flip_v(G.gravity_down(G.flip_v(g))) end
function G.gravity_left(g) return G.transpose(G.gravity_up(G.transpose(g))) end
function G.gravity_right(g) return G.transpose(G.gravity_down(G.transpose(g))) end
function G.shift_down(g, k) local o = M.grid(g.h, g.w, 0) for r = 1, g.h do local rr = r + k if rr >= 1 and rr <= g.h then for c = 1, g.w do o[rr][c] = g[r][c] end end end return o end
function G.shift_right(g, k) local o = M.grid(g.h, g.w, 0) for r = 1, g.h do for c = 1, g.w do local cc = c + k if cc >= 1 and cc <= g.w then o[r][cc] = g[r][c] end end end return o end
function G.add_border(g, col) local o = M.grid(g.h + 2, g.w + 2, col) chk_grid(o) for r = 1, g.h do for c = 1, g.w do o[r + 1][c + 1] = g[r][c] end end return o end
function G.remove_border(g) if g.h < 3 or g.w < 3 then error("small") end local o = { h = g.h - 2, w = g.w - 2 } for r = 2, g.h - 1 do local row = {} for c = 2, g.w - 1 do row[c - 1] = g[r][c] end o[r - 1] = row end return o end
function G.top_half(g) if g.h < 2 then error("small") end local o = { h = floor(g.h / 2), w = g.w } for r = 1, o.h do o[r] = g[r] end return M.copy_grid(o) end
function G.left_half(g) return G.transpose(G.top_half(G.transpose(g))) end
function G.bottom_half(g) if g.h < 2 then error("small") end local o = { h = floor(g.h / 2), w = g.w } for r = 1, o.h do o[r] = g[g.h - o.h + r] end return M.copy_grid(o) end
function G.right_half(g) return G.transpose(G.bottom_half(G.transpose(g))) end
function G.overlay(a, b) if a.h ~= b.h or a.w ~= b.w then error("dim") end local o = M.copy_grid(a) for r = 1, a.h do for c = 1, a.w do if b[r][c] ~= 0 then o[r][c] = b[r][c] end end end return o end
function G.flatten(g) local o = {} for r = 1, g.h do for c = 1, g.w do o[#o + 1] = g[r][c] end end return chk_list(o) end
function G.row(g, k) if k < 1 or k > g.h then error("oob") end local o = {} for c = 1, g.w do o[c] = g[k][c] end return o end
function G.col(g, k) if k < 1 or k > g.w then error("oob") end local o = {} for r = 1, g.h do o[r] = g[r][k] end return o end
function G.from_row(l) if #l == 0 then error("empty") end local o = { h = 1, w = #l } o[1] = {} for i = 1, #l do o[1][i] = l[i] end return chk_grid(o) end
function G.nonzero_count(g) local n = 0 for r = 1, g.h do for c = 1, g.w do if g[r][c] ~= 0 then n = n + 1 end end end return n end
function G.const_grid(g, col) return M.grid(g.h, g.w, col) end
function G.invert_mask(g) local o = M.copy_grid(g) for r = 1, o.h do for c = 1, o.w do o[r][c] = (o[r][c] == 0) and 1 or 0 end end return o end
function G.tile2x2(g) return G.vcat(G.hcat(g, g), G.hcat(g, g)) end

-- connected components (4-neighbour, nonzero, same colour)
local function components(g)
  local seen, comps = {}, {}
  for r = 1, g.h do seen[r] = {} end
  for r = 1, g.h do for c = 1, g.w do
    if g[r][c] ~= 0 and not seen[r][c] then
      local col, stack, cells = g[r][c], { { r, c } }, {}
      seen[r][c] = true
      while #stack > 0 do
        local p = table.remove(stack)
        cells[#cells + 1] = p
        local pr, pc = p[1], p[2]
        local nb = { { pr + 1, pc }, { pr - 1, pc }, { pr, pc + 1 }, { pr, pc - 1 } }
        for _, q in ipairs(nb) do
          local qr, qc = q[1], q[2]
          if qr >= 1 and qr <= g.h and qc >= 1 and qc <= g.w and not seen[qr][qc] and g[qr][qc] == col then
            seen[qr][qc] = true
            stack[#stack + 1] = q
          end
        end
      end
      comps[#comps + 1] = { color = col, cells = cells }
    end
  end end
  return comps
end
M.components = components

local function keep_component(g, comp)
  local o = M.grid(g.h, g.w, 0)
  for _, p in ipairs(comp.cells) do o[p[1]][p[2]] = comp.color end
  return o
end
function G.object_count(g) return #components(g) end
function G.keep_largest(g) local cs = components(g) if #cs == 0 then error("none") end local best = cs[1] for i = 2, #cs do if #cs[i].cells > #best.cells then best = cs[i] end end return keep_component(g, best) end
function G.keep_smallest(g) local cs = components(g) if #cs == 0 then error("none") end local best = cs[1] for i = 2, #cs do if #cs[i].cells < #best.cells then best = cs[i] end end return keep_component(g, best) end
function G.largest_object_size(g) local cs = components(g) local m = 0 for i = 1, #cs do if #cs[i].cells > m then m = #cs[i].cells end end return m end
-- hidden-only grid ops
function G.flip_diag(g) return G.transpose(g) end
function G.outline(g) local o = M.copy_grid(g) for r = 1, g.h do for c = 1, g.w do if g[r][c] ~= 0 then local interior = r > 1 and r < g.h and c > 1 and c < g.w and g[r-1][c] ~= 0 and g[r+1][c] ~= 0 and g[r][c-1] ~= 0 and g[r][c+1] ~= 0 if interior then o[r][c] = 0 end end end end return o end
function G.color_swap_top2(g) local a, b = G.most_nonzero_color(g), G.least_nonzero_color(g) if a == b then error("same") end local o = M.copy_grid(g) for r = 1, g.h do for c = 1, g.w do if o[r][c] == a then o[r][c] = b elseif o[r][c] == b then o[r][c] = a end end end return o end
function G.row_sums(g) local o = {} for r = 1, g.h do local s = 0 for c = 1, g.w do s = s + g[r][c] end o[r] = s end return o end
function G.col_sums(g) local o = {} for c = 1, g.w do local s = 0 for r = 1, g.h do s = s + g[r][c] end o[c] = s end return o end
function G.majority_row_fill(g) local o = M.copy_grid(g) for r = 1, g.h do local m = G.most_nonzero_color(G.from_row(g[r])) for c = 1, g.w do if o[r][c] ~= 0 then o[r][c] = m end end end return o end
function G.checker_mask(g) local o = M.copy_grid(g) for r = 1, g.h do for c = 1, g.w do if (r + c) % 2 == 1 then o[r][c] = 0 end end end return o end
function G.rotate_rows(g) local o = { h = g.h, w = g.w } for r = 1, g.h do o[r] = g[(r % g.h) + 1] end return M.copy_grid(o) end

-- ---------- catalogue ----------
-- entry: name -> {f=, t={argtypes}, r=rettype, hidden=bool}
local C = {}
local function def(name, f, args, ret, hidden) C[name] = { f = f, t = args, r = ret, hidden = hidden or false } end

-- list
def("reverse", L.reverse, { "L" }, "L")   def("sort", L.sort, { "L" }, "L")   def("sort_desc", L.sort_desc, { "L" }, "L")
def("head", L.head, { "L" }, "I")         def("last", L.last, { "L" }, "I")   def("tail", L.tail, { "L" }, "L")
def("init", L.init, { "L" }, "L")         def("len", L.len, { "L" }, "I")     def("sum", L.sum, { "L" }, "I")
def("max", L.max, { "L" }, "I")           def("min", L.min, { "L" }, "I")
def("map_add", L.map_add, { "L", "I" }, "L")  def("map_sub", L.map_sub, { "L", "I" }, "L")
def("map_mul", L.map_mul, { "L", "I" }, "L")  def("map_mod", L.map_mod, { "L", "I" }, "L")
def("filter_even", L.filter_even, { "L" }, "L")  def("filter_odd", L.filter_odd, { "L" }, "L")
def("filter_gt", L.filter_gt, { "L", "I" }, "L") def("filter_lt", L.filter_lt, { "L", "I" }, "L")
def("take", L.take, { "L", "I" }, "L")    def("drop", L.drop, { "L", "I" }, "L")   def("rotate", L.rotate, { "L", "I" }, "L")
def("concat", L.concat, { "L", "L" }, "L") def("dedup", L.dedup, { "L" }, "L")    def("cumsum", L.cumsum, { "L" }, "L")
def("diffs", L.diffs, { "L" }, "L")       def("count", L.count, { "L", "I" }, "I") def("index_of", L.index_of, { "L", "I" }, "I")
def("range", L.range, { "I" }, "L")       def("singleton", L.singleton, { "I" }, "L") def("nth", L.nth, { "L", "I" }, "I")
def("abs_all", L.abs_all, { "L" }, "L")   def("mirror", L.mirror, { "L" }, "L")  def("repeat_list", L.repeat_list, { "L", "I" }, "L")
def("zip_add", L.zip_add, { "L", "L" }, "L") def("evens_idx", L.evens_idx, { "L" }, "L") def("odds_idx", L.odds_idx, { "L" }, "L")
def("push_front", L.push_front, { "L", "I" }, "L") def("push_back", L.push_back, { "L", "I" }, "L")
def("product", L.product, { "L" }, "I")   def("unique_count", L.unique_count, { "L" }, "I")
def("mode", L.mode, { "L" }, "I", true)   def("second_largest", L.second_largest, { "L" }, "I", true)
def("median", L.median, { "L" }, "I", true) def("sort_by_freq", L.sort_by_freq, { "L" }, "L", true)
def("remove_all", L.remove_all, { "L", "I" }, "L", true) def("running_max", L.running_max, { "L" }, "L", true)
def("argmax", L.argmax, { "L" }, "I", true) def("is_sorted", L.is_sorted, { "L" }, "B", true)
def("is_palindrome", L.is_palindrome, { "L" }, "B", true) def("squares", L.squares, { "L" }, "L", true)
def("pairwise_sums", L.pairwise_sums, { "L" }, "L", true) def("swap_halves", L.swap_halves, { "L" }, "L", true)
-- int
def("add", I.add, { "I", "I" }, "I")  def("sub", I.sub, { "I", "I" }, "I")  def("mul", I.mul, { "I", "I" }, "I")
def("div", I.div, { "I", "I" }, "I")  def("mod", I.mod, { "I", "I" }, "I")  def("max2", I.max2, { "I", "I" }, "I")
def("min2", I.min2, { "I", "I" }, "I") def("sq", I.sq, { "I" }, "I")       def("inc", I.inc, { "I" }, "I")
def("dec", I.dec, { "I" }, "I")       def("double", I.double, { "I" }, "I") def("half", I.half, { "I" }, "I")
def("abs", I.abs, { "I" }, "I")       def("neg", I.neg, { "I" }, "I")
def("is_even", I.is_even, { "I" }, "B") def("gt", I.gt, { "I", "I" }, "B") def("eq", I.eq, { "I", "I" }, "B")
def("if_int", I.if_int, { "B", "I", "I" }, "I")
def("digit_sum", I.digit_sum, { "I" }, "I", true) def("triangular", I.triangular, { "I" }, "I", true)
-- grid
def("flip_h", G.flip_h, { "G" }, "G")  def("flip_v", G.flip_v, { "G" }, "G")  def("transpose", G.transpose, { "G" }, "G")
def("rot90", G.rot90, { "G" }, "G")    def("rot180", G.rot180, { "G" }, "G")  def("rot270", G.rot270, { "G" }, "G")
def("height", G.height, { "G" }, "I")  def("width", G.width, { "G" }, "I")
def("hcat", G.hcat, { "G", "G" }, "G") def("vcat", G.vcat, { "G", "G" }, "G")
def("mirror_h", G.mirror_h, { "G" }, "G") def("mirror_v", G.mirror_v, { "G" }, "G")
def("upscale", G.upscale, { "G", "I" }, "G") def("downscale", G.downscale, { "G", "I" }, "G")
def("recolor", G.recolor, { "G", "C", "C" }, "G") def("fill_nonzero", G.fill_nonzero, { "G", "C" }, "G")
def("count_color", G.count_color, { "G", "C" }, "I") def("most_color", G.most_color, { "G" }, "C")
def("most_nonzero_color", G.most_nonzero_color, { "G" }, "C") def("least_nonzero_color", G.least_nonzero_color, { "G" }, "C")
def("crop_bbox", G.crop_bbox, { "G" }, "G")
def("gravity_down", G.gravity_down, { "G" }, "G") def("gravity_up", G.gravity_up, { "G" }, "G")
def("gravity_left", G.gravity_left, { "G" }, "G") def("gravity_right", G.gravity_right, { "G" }, "G")
def("shift_down", G.shift_down, { "G", "I" }, "G") def("shift_right", G.shift_right, { "G", "I" }, "G")
def("add_border", G.add_border, { "G", "C" }, "G") def("remove_border", G.remove_border, { "G" }, "G")
def("top_half", G.top_half, { "G" }, "G") def("bottom_half", G.bottom_half, { "G" }, "G")
def("left_half", G.left_half, { "G" }, "G") def("right_half", G.right_half, { "G" }, "G")
def("overlay", G.overlay, { "G", "G" }, "G") def("flatten", G.flatten, { "G" }, "L")
def("row", G.row, { "G", "I" }, "L")   def("col", G.col, { "G", "I" }, "L")  def("from_row", G.from_row, { "L" }, "G")
def("nonzero_count", G.nonzero_count, { "G" }, "I") def("const_grid", G.const_grid, { "G", "C" }, "G")
def("invert_mask", G.invert_mask, { "G" }, "G") def("tile2x2", G.tile2x2, { "G" }, "G")
def("object_count", G.object_count, { "G" }, "I") def("keep_largest", G.keep_largest, { "G" }, "G")
def("keep_smallest", G.keep_smallest, { "G" }, "G") def("largest_object_size", G.largest_object_size, { "G" }, "I")
def("outline", G.outline, { "G" }, "G", true) def("color_swap_top2", G.color_swap_top2, { "G" }, "G", true)
def("row_sums", G.row_sums, { "G" }, "L", true) def("col_sums", G.col_sums, { "G" }, "L", true)
def("majority_row_fill", G.majority_row_fill, { "G" }, "G", true) def("checker_mask", G.checker_mask, { "G" }, "G", true)
def("rotate_rows", G.rotate_rows, { "G" }, "G", true)

M.catalogue = C
M.L, M.I, M.G = L, I, G
return M
