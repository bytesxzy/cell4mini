#!/usr/bin/env python3
"""Night 1 patch: make the external ARC benchmark actually observe the corpus.

The old load_external() took the first `cap` filenames in sorted order, so the external
benchmark was a fixed prefix. Production runs cap=20; the earliest solvable task sits at
sorted position 31; hence "0 of 20" in every generation while the champion in fact solves
46 of the 550 tasks available.

This patch:
  1. rotates the window (deterministic, generation-seeded, prefix-stratified sample),
  2. keys the champion cache and the generation-over-generation delta on a digest of the
     actual task ids rather than on their count, which a rotating window would otherwise
     silently invalidate,
  3. tracks cumulative distinct ARC tasks ever solved, a progress measure that survives
     rotation.
"""
import re, sys, pathlib

path = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "cell4.lua")
src = path.read_text()
orig = src

# ---------------------------------------------------------------- 1. load_external
OLD_HEAD = """function M.load_external(root, cap)
  local dir = root .. "/data/arc"
  local list = {}
  local p = io.popen("ls '" .. dir .. "' 2>/dev/null")
  if p then
    for name in p:lines() do if name:match("%.json$") then list[#list + 1] = name end end
    p:close()
  end
  table.sort(list)
  local out = {}
  for _, name in ipairs(list) do
    if #out >= cap then break end
"""

NEW_HEAD = """-- Which ARC files a generation scores.
--
-- This used to be `the first cap filenames in sorted order`, which made the external benchmark a
-- fixed prefix of the corpus rather than a sample of it. With the production cap of 20 the same 20
-- tasks were scored every generation; none of them happen to be within the champion's reach, so the
-- external score read 0/20 from generation 7 to 73 while the champion in fact solved 46 of the 550
-- tasks on disk. The number was not measuring capability, it was measuring the prefix.
--
-- The window now rotates: a deterministic, seed-derived, prefix-stratified sample. Same cost per
-- generation, but every task is eventually scored, so the figure tracks the corpus instead of an
-- accident of alphabetical order. Determinism is preserved -- the same seed yields the same window,
-- so a generation remains exactly reproducible.
--
-- `seed == nil` reproduces the old prefix behaviour verbatim, which is what selftest wants.
local function select_external(list, cap, seed)
  if cap >= #list or seed == nil then
    local out = {}
    for i = 1, math.min(cap, #list) do out[i] = list[i] end
    return out
  end
  -- Stratify by corpus prefix (arc1_, arc2_, ...) so one corpus cannot crowd out another when the
  -- sample is small; within a stratum the choice is a seeded shuffle.
  local groups, order = {}, {}
  for _, name in ipairs(list) do
    local k = name:match("^([^_]+)_") or "other"
    if not groups[k] then groups[k] = {} order[#order + 1] = k end
    groups[k][#groups[k] + 1] = name
  end
  local rng = RNG.new("external-window:" .. tostring(seed))
  local picked, taken = {}, {}
  for _, k in ipairs(order) do
    local g = groups[k]
    local idx = {}
    for i = 1, #g do idx[i] = i end
    rng:shuffle(idx)
    groups[k] = { files = g, idx = idx, at = 0 }
    local want = math.floor(cap * #g / #list)
    for _ = 1, want do
      local st = groups[k]
      st.at = st.at + 1
      if st.idx[st.at] then
        local name = st.files[st.idx[st.at]]
        picked[#picked + 1] = name taken[name] = true
      end
    end
  end
  -- Integer rounding leaves the sample short; top it up by cycling the strata deterministically so
  -- the total is exactly `cap` whenever the corpus is large enough to supply it.
  local gi = 0
  while #picked < cap do
    local progressed = false
    for _ = 1, #order do
      gi = (gi % #order) + 1
      local st = groups[order[gi]]
      st.at = st.at + 1
      local j = st.idx[st.at]
      if j then
        local name = st.files[j]
        if not taken[name] then
          picked[#picked + 1] = name taken[name] = true
          progressed = true
        end
      end
      if #picked >= cap then break end
    end
    if not progressed then break end
  end
  table.sort(picked)
  return picked
end

-- A stable fingerprint of the task ids a run actually scored. The champion cache and the
-- generation-over-generation delta both used to compare `n` alone, which was sound only while the
-- window was a fixed prefix: with a rotating window two different samples of the same size are not
-- the same measurement, and comparing them would silently corrupt both.
function M.external_digest(ext)
  local ids = {}
  for i, t in ipairs(ext) do ids[i] = t.id end
  table.sort(ids)
  return string.format("%d:%x", #ids, RNG.hash(table.concat(ids, ",")))
end

local function external_list(root)
  local dir = root .. "/data/arc"
  local list = {}
  local p = io.popen("ls '" .. dir .. "' 2>/dev/null")
  if p then
    for name in p:lines() do if name:match("%.json$") then list[#list + 1] = name end end
    p:close()
  end
  table.sort(list)
  return list
end

-- How many ARC tasks exist on disk, as opposed to how many a generation drew. Coverage is only
-- meaningful against this denominator.
function M.external_corpus_size(root)
  return #external_list(root)
end

function M.load_external(root, cap, seed)
  local dir = root .. "/data/arc"
  local list = external_list(root)
  local chosen = select_external(list, cap, seed)
  local out = {}
  for _, name in ipairs(chosen) do
"""
assert OLD_HEAD in src, "load_external head not found"
src = src.replace(OLD_HEAD, NEW_HEAD, 1)

# the old loop body had `if #out >= cap then break end` as its first statement; it is gone now,
# and the loop variable is `name` over `chosen`, so the rest of the body still type-checks.

# ---------------------------------------------------------------- 2. cycle: seed + digest
OLD_LOAD = '  local external = benchmarks.load_external(ROOT, cfg.external_cap)\n'
NEW_LOAD = ('  -- Seeded on the generation so the window rotates across generations but is fixed within one:\n'
            '  -- champion and every candidate are scored on exactly the same ARC tasks.\n'
            '  local external = benchmarks.load_external(ROOT, cfg.external_cap, gen)\n'
            '  local external_digest = benchmarks.external_digest(external)\n')
assert OLD_LOAD in src, "external load line not found"
src = src.replace(OLD_LOAD, NEW_LOAD, 1)

# The external window rotates every generation, so folding its digest into the single champion-cache
# key would invalidate the whole cache each time and force a full re-evaluation of the 260-task
# held-out split -- a large cost for no reason, since held-out and regression do not depend on which
# ARC tasks were drawn. Cache the two independently: the expensive splits keep the original key, and
# the external score is reused only when it was measured on exactly the same tasks.
OLD_CACHE_BLOCK = """  if cache and cache.fingerprint == champ_fp and cache.epoch == bench.heldout_epoch and cache.regression_n == #splits.regression
    and cache.external_n == #external and cache.heldout_n == #splits.heldout
    and cache.budget == cfg.budget_profile then
    champ_r = { heldout = cache.heldout, regression = cache.regression, external = cache.external }
    champ_r.train = eval_split(champ_g, splits.train, "champion: visible split")
    champ_r.adversarial = eval_split(champ_g, splits.adversarial, "champion: adversarial")
  else
    champ_r = eval_all(champ_g, splits, external, "champion", { candidate = "champion" })
    state.champion_cache = { fingerprint = champ_fp, epoch = bench.heldout_epoch, regression_n = #splits.regression,
      external_n = #external, heldout_n = #splits.heldout, budget = cfg.budget_profile,
      heldout = champ_r.heldout, regression = champ_r.regression, external = champ_r.external }
  end
"""
NEW_CACHE_BLOCK = """  -- The external window rotates by generation while held-out and regression do not depend on it, so
  -- the two are cached under separate keys. Folding the window digest into one key would discard a
  -- valid 260-task held-out measurement every generation for no reason.
  if cache and cache.fingerprint == champ_fp and cache.epoch == bench.heldout_epoch and cache.regression_n == #splits.regression
    and cache.heldout_n == #splits.heldout
    and cache.budget == cfg.budget_profile then
    champ_r = { heldout = cache.heldout, regression = cache.regression }
    -- Reuse the cached ARC score only if it was measured on exactly these tasks; otherwise rescore
    -- just the external split, which is the cheap one.
    if cache.external_digest == external_digest and cache.external then
      champ_r.external = cache.external
    else
      champ_r.external = eval_split(champ_g, external, "champion: external ARC",
        { nodes = cfg.external_nodes, seconds = cfg.external_seconds }, { candidate = "champion" })
      cache.external, cache.external_digest = champ_r.external, external_digest
    end
    champ_r.train = eval_split(champ_g, splits.train, "champion: visible split")
    champ_r.adversarial = eval_split(champ_g, splits.adversarial, "champion: adversarial")
  else
    champ_r = eval_all(champ_g, splits, external, "champion", { candidate = "champion" })
    state.champion_cache = { fingerprint = champ_fp, epoch = bench.heldout_epoch, regression_n = #splits.regression,
      external_digest = external_digest, heldout_n = #splits.heldout, budget = cfg.budget_profile,
      heldout = champ_r.heldout, regression = champ_r.regression, external = champ_r.external }
  end
"""
assert OLD_CACHE_BLOCK in src, "champion cache block not found"
src = src.replace(OLD_CACHE_BLOCK, NEW_CACHE_BLOCK, 1)

# ---------------------------------------------------------------- 3. delta gated on digest
OLD_DELTA = """  local ext_delta = nil
  local prev_ext = state.last_external
  if prev_ext and champ_r.external.n > 0 and prev_ext.n == champ_r.external.n then
    ext_delta = champ_r.external.solved - prev_ext.solved
  end
  state.last_external = { solved = champ_r.external.solved, n = champ_r.external.n, gen = gen }
"""
NEW_DELTA = """  -- Comparable only when the *same tasks* were attempted, not merely the same number of them.
  -- The window rotates by generation, so this is usually nil and the narrator stays silent about
  -- movement rather than comparing two different samples as if they were one.
  local ext_delta = nil
  local prev_ext = state.last_external
  if prev_ext and champ_r.external.n > 0 and prev_ext.digest == external_digest then
    ext_delta = champ_r.external.solved - prev_ext.solved
  end
  state.last_external = { solved = champ_r.external.solved, n = champ_r.external.n,
    digest = external_digest, gen = gen }

  -- Cumulative ARC coverage. A rotating window makes any single generation's count a sample, so the
  -- durable progress measure is the set of distinct ARC tasks this system has ever solved. It only
  -- grows, it is unaffected by which window came up, and unlike the per-generation figure it cannot
  -- be moved by luck of the draw.
  do
    local seen = state.arc_solved_ids or {}
    local before = 0
    for _ in pairs(seen) do before = before + 1 end
    for _, r in ipairs(champ_r.external.per_task or {}) do
      if r.solved == 1 and r.id then seen[r.id] = (seen[r.id] or 0) + 1 end
    end
    local after = 0
    for _ in pairs(seen) do after = after + 1 end
    state.arc_solved_ids = seen
    local corpus = benchmarks.external_corpus_size(ROOT)
    state.arc_coverage = { distinct_solved = after, new_this_gen = after - before,
      attempted_this_gen = champ_r.external.n, corpus_size = corpus }
    if after > before then
      log(state, string.format("ARC coverage: %d of %d ARC tasks solved at least once (+%d new this generation)",
        after, corpus, after - before))
    end
  end
"""
assert OLD_DELTA in src, "delta block not found"
src = src.replace(OLD_DELTA, NEW_DELTA, 1)

assert src != orig
path.write_text(src)
print("patched OK:", path)
