-- What is a good challenge for this system right now?
--
-- The inputs here are all measurements the system took on itself. The weighting that combines them
-- is a declared convention, printed alongside the result so it can be argued with and changed in
-- `rsi/config.lua`. That split is what "unbiased" means here: nothing is scored by preference, but
-- the recipe for combining the scores is a choice and is shown as one.
--
-- Four components, each in [0,1]:
--
--   information  4p(1-p) where p is the solve rate. This is the variance of a Bernoulli trial,
--                normalised to peak at p=0.5. A benchmark solved 100% or 0% of the time carries no
--                information about whether a change helped: every candidate scores the same on it.
--                This is the item-information idea from item response theory, in its simplest form.
--
--   discrimination  the rate at which candidates actually differ from the champion on this family's
--                tasks. This is the empirical count of discordant pairs -- exactly the quantity the
--                sign test consumes -- so it is a direct measure of the benchmark's statistical
--                power to detect a real improvement. A family that never produces a discordant pair
--                cannot ever justify an acceptance, however hard it looks.
--
--   headroom     mean partial credit on the tasks it fails. A family it misses by one example is
--                nearer to falling than one it misses entirely, so this points at reachable gains.
--
--   freshness    1/(1+generations since this family last discriminated). Penalises families that
--                have gone quiet, which is how saturation shows up before the solve rate saturates.
--
-- A family that is *hard* is not automatically a good challenge: one the system solves 0% of the
-- time scores zero information and zero discrimination, and correctly ranks below one it solves half
-- the time. Difficulty for its own sake is not the objective; the ability to tell improvement from
-- noise is.
local M = {}

M.DEFAULT_WEIGHTS = { information = 0.40, discrimination = 0.35, headroom = 0.15, freshness = 0.10 }

-- stats: family -> { n, solved, partial_unsolved_sum, partial_unsolved_n, discordant, comparisons,
--                    last_discordant_gen }
function M.rank(stats, gen, weights)
  weights = weights or M.DEFAULT_WEIGHTS
  local rows = {}
  local max_disc = 0
  for _, st in pairs(stats or {}) do
    local d = (st.comparisons or 0) > 0 and (st.discordant or 0) / st.comparisons or 0
    if d > max_disc then max_disc = d end
  end
  for fam, st in pairs(stats or {}) do
    if (st.n or 0) > 0 then
      local p = st.solved / st.n
      local information = 4 * p * (1 - p)
      local raw_disc = (st.comparisons or 0) > 0 and (st.discordant or 0) / st.comparisons or 0
      local discrimination = max_disc > 0 and raw_disc / max_disc or 0
      local headroom = (st.partial_unsolved_n or 0) > 0
        and st.partial_unsolved_sum / st.partial_unsolved_n or 0
      local since = gen - (st.last_discordant_gen or 0)
      local freshness = 1 / (1 + math.max(0, since))
      local score = weights.information * information
        + weights.discrimination * discrimination
        + weights.headroom * headroom
        + weights.freshness * freshness
      rows[#rows + 1] = {
        family = fam, n = st.n, solve_rate = p, score = score,
        information = information, discrimination = discrimination,
        headroom = headroom, freshness = freshness,
        discordant = st.discordant or 0, comparisons = st.comparisons or 0,
        since_discriminated = since,
      }
    end
  end
  table.sort(rows, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.family < b.family
  end)
  return rows
end

-- A family is saturated when it is nearly always solved AND has stopped separating candidates.
-- Both conditions matter: a family at 95% that still discriminates is still doing useful work.
function M.saturated(rows, solve_floor, disc_floor)
  solve_floor = solve_floor or 0.92
  disc_floor = disc_floor or 0.05
  local out = {}
  for _, r in ipairs(rows) do
    if r.solve_rate >= solve_floor and r.discrimination <= disc_floor and r.n >= 40 then
      out[#out + 1] = r.family
    end
  end
  return out
end

-- The families worth spending adversarial slots on: the best challenges that are not saturated.
function M.pick_adversarial(rows, k, fallback)
  local out = {}
  for _, r in ipairs(rows) do
    if #out >= k then break end
    if r.solve_rate < 0.95 then out[#out + 1] = r.family end
  end
  if #out == 0 then return fallback end
  return out
end

function M.update(stats, family, solved, partial, gen)
  local st = stats[family]
  if not st then
    st = { n = 0, solved = 0, partial_unsolved_sum = 0, partial_unsolved_n = 0,
           discordant = 0, comparisons = 0, last_discordant_gen = gen }
    stats[family] = st
  end
  st.n = st.n + 1
  st.solved = st.solved + solved
  if solved == 0 then
    st.partial_unsolved_sum = st.partial_unsolved_sum + (partial or 0)
    st.partial_unsolved_n = st.partial_unsolved_n + 1
  end
  return st
end

function M.note_comparison(stats, family, differed, gen)
  local st = stats[family]
  if not st then return end
  st.comparisons = (st.comparisons or 0) + 1
  if differed then
    st.discordant = (st.discordant or 0) + 1
    st.last_discordant_gen = gen
  end
end

return M
