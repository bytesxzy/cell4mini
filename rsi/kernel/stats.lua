-- Statistics for the acceptance rule: paired bootstrap, sign test, Wilson interval.
local RNG = require("rsi.kernel.rng")
local M = {}

function M.mean(t)
  if #t == 0 then return 0 end
  local s = 0
  for i = 1, #t do s = s + t[i] end
  return s / #t
end

-- Wilson score interval for a proportion
function M.wilson(k, n, z)
  z = z or 1.96
  if n == 0 then return 0, 0, 0 end
  local p = k / n
  local den = 1 + z * z / n
  local centre = (p + z * z / (2 * n)) / den
  local half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / den
  return p, math.max(0, centre - half), math.min(1, centre + half)
end

-- Paired bootstrap on per-item differences d_i = b_i - a_i.
-- Returns mean diff, one-sided p-value P(diff <= 0), and 95% CI (lo, hi).
function M.paired_bootstrap(a, b, reps, seed)
  reps = reps or 2000
  local n = #a
  if n == 0 then return 0, 1, 0, 0 end
  local d = {}
  for i = 1, n do d[i] = (b[i] or 0) - (a[i] or 0) end
  local rng = RNG.new(seed or 12345)
  local means = {}
  local le = 0
  for r = 1, reps do
    local s = 0
    for _ = 1, n do s = s + d[rng:int(n)] end
    local m = s / n
    means[r] = m
    if m <= 0 then le = le + 1 end
  end
  table.sort(means)
  local lo = means[math.max(1, math.floor(reps * 0.025))]
  local hi = means[math.min(reps, math.ceil(reps * 0.975))]
  return M.mean(d), le / reps, lo, hi
end

-- Exact one-sided sign test on wins vs losses (ties dropped): P(X >= wins | Binomial(w+l, 0.5))
function M.sign_test(wins, losses)
  local n = wins + losses
  if n == 0 then return 1 end
  local p = 0
  local logc = 0
  for k = 0, n do
    if k > 0 then logc = logc + math.log(n - k + 1) - math.log(k) end
    if k >= wins then p = p + math.exp(logc - n * math.log(2)) end
  end
  return math.min(1, p)
end

function M.wins_losses(a, b)
  local w, l = 0, 0
  for i = 1, #a do
    if b[i] > a[i] then w = w + 1 elseif b[i] < a[i] then l = l + 1 end
  end
  return w, l
end

return M
