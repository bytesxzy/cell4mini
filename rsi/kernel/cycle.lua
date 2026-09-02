-- One generation of the research loop:
--   research (if due) -> build splits -> evaluate champion -> generate candidates from evidence ->
--   evaluate candidates -> acceptance rule -> retain / reject -> lineage -> benchmark management -> dashboard
local cfg = require("rsi.config")
local json = require("rsi.kernel.json")
local RNG = require("rsi.kernel.rng")
local genome = require("rsi.kernel.genome")
local evaluate = require("rsi.kernel.evaluate")
local stats = require("rsi.kernel.stats")
local mutate = require("rsi.kernel.mutate")
local benchmarks = require("rsi.kernel.benchmarks")
local lineage = require("rsi.kernel.lineage")
local research = require("rsi.kernel.research")
local dashboard = require("rsi.kernel.dashboard")
local features = require("rsi.kernel.features")
local challenge = require("rsi.kernel.challenge")
local journal = require("rsi.kernel.journal")
local narrator = require("rsi.kernel.narrator")
local M = {}

local ROOT = cfg.root

local function ensure_dirs()
  os.execute(string.format("mkdir -p '%s/state' '%s/www' '%s/versions' '%s/data/arc' '%s/data/research'", ROOT, ROOT, ROOT, ROOT, ROOT))
end

local function load_state()
  local s = json.read(ROOT .. "/state/state.json")
  if not s then
    s = { gen = 0, accepted_total = 0, candidates_total = 0, meta = { tried = {}, accepted = {} }, last_research = 0, log = {} }
  end
  s.meta = s.meta or { tried = {}, accepted = {} }
  return s
end

local function save_state(s) json.write(ROOT .. "/state/state.json", s) end

local function summarize(res)
  local p, lo, hi = stats.wilson(res.solved, res.n)
  return { rate = p, lo = lo, hi = hi, n = res.n, solved = res.solved, partial = res.partial_mean, nodes = res.nodes_mean, time = res.time }
end

local function progress(phase, extra)
  local p = { phase = phase }
  for k, v in pairs(extra or {}) do p[k] = v end
  dashboard.write_progress(ROOT, p)
end

local function eval_split(g, tasks_, label, opts, extra)
  local o = { nodes = cfg.nodes, instructions = cfg.instructions, seconds = cfg.seconds }
  for k, v in pairs(opts or {}) do o[k] = v end
  o.on_progress = function(i, n, solved)
    local e = { done = i, total = n, solved = solved }
    for k, v in pairs(extra or {}) do e[k] = v end
    progress(label, e)
  end
  return evaluate.run(g, tasks_, o)
end

local function eval_all(g, splits, external, label, extra)
  local r = {}
  r.heldout = eval_split(g, splits.heldout, label .. ": held-out", nil, extra)
  r.train = eval_split(g, splits.train, label .. ": visible split", nil, extra)
  r.adversarial = eval_split(g, splits.adversarial, label .. ": adversarial", nil, extra)
  r.regression = eval_split(g, splits.regression, label .. ": regression suite", nil, extra)
  r.external = eval_split(g, external, label .. ": external ARC", { nodes = cfg.external_nodes, seconds = cfg.external_seconds }, extra)
  return r
end

-- The acceptance rule. Returns accepted(bool), reason(string), evidence(table).
local function decide(champ, cand, gen)
  local ev = {}
  -- 1. regression: nothing previously solved may be lost
  if cand.regression.n > 0 and cand.regression.solved < cand.regression.n then
    ev.regression = cand.regression.solved .. "/" .. cand.regression.n
    return false, "regression: lost " .. (cand.regression.n - cand.regression.solved) .. " previously solved task(s)", ev
  end
  ev.regression = cand.regression.solved .. "/" .. cand.regression.n
  -- 2. external non-regression
  if cand.external.n > 0 and cand.external.solved < champ.external.solved then
    return false, string.format("external ARC dropped %d -> %d", champ.external.solved, cand.external.solved), ev
  end
  -- 3. paired held-out comparison
  local a, b = evaluate.vector(champ.heldout), evaluate.vector(cand.heldout)
  local d, p, lo, hi = stats.paired_bootstrap(a, b, cfg.bootstrap_reps, "boot:" .. gen)
  local wins, losses = stats.wins_losses(a, b)
  local sp = stats.sign_test(wins, losses)
  ev.heldout_delta, ev.p_value, ev.ci = d, p, { lo, hi }
  ev.wins, ev.losses, ev.sign_p = wins, losses, sp
  local ad = cand.adversarial.solve_rate - champ.adversarial.solve_rate
  ev.adversarial_delta = ad
  local pa, pb = evaluate.vector(champ.adversarial, "partial"), evaluate.vector(cand.adversarial, "partial")
  ev.adversarial_partial_delta = stats.mean(pb) - stats.mean(pa)
  local train_gain = cand.train.solve_rate - champ.train.solve_rate
  ev.train_delta = train_gain
  ev.nodes_ratio = champ.heldout.nodes_mean > 0 and cand.heldout.nodes_mean / champ.heldout.nodes_mean or 1
  if ad < cfg.adversarial_tolerance then
    return false, string.format("adversarial drop %.1fpp exceeds tolerance", ad * 100), ev
  end
  if d <= 0 and train_gain - d > cfg.overfit_gap then
    return false, string.format("overfit: visible-split gain %.1fpp with no held-out gain", train_gain * 100), ev
  end
  -- Both tests must pass. With few discordant pairs the paired bootstrap is not measuring the
  -- effect: with 3 wins and 0 losses out of 200 it reports p=0.047 simply because a resample almost
  -- always contains one of the three wins, while the exact sign test correctly says 0.125. Taking
  -- either test alone lets that through, so the rule takes the conjunction.
  local significant = d > 0 and p < cfg.alpha and sp < cfg.alpha and wins > losses
  if significant then
    return true, string.format("held-out +%.1fpp (bootstrap p=%.3f, sign p=%.3f, wins %d / losses %d)",
      d * 100, p, sp, wins, losses), ev
  end
  if d >= 0 and losses == 0 and ev.nodes_ratio <= cfg.efficiency_ratio and ev.adversarial_partial_delta >= 0 then
    return true, string.format("efficiency: same solves with %.0f%% of the search nodes, no losses", ev.nodes_ratio * 100), ev
  end
  if d > 0 then
    return false, string.format("held-out +%.1fpp not significant (bootstrap p=%.3f, sign p=%.3f, wins %d / losses %d)",
      d * 100, p, sp, wins, losses), ev
  end
  return false, string.format("no held-out gain (%.1fpp, wins %d / losses %d)", d * 100, wins, losses), ev
end

local function champion_summary(g, r, bench, external_n)
  local lib = {}
  for _, e in ipairs(g.lib) do lib[#lib + 1] = { name = e.name, expr = e.expr, arg = e.arg, arg2 = e.arg2, ret = e.ret, origin = e.origin } end
  return {
    fingerprint = genome.fingerprint(g), heldout = summarize(r.heldout), adversarial = summarize(r.adversarial),
    regression = { solved = r.regression.solved, n = r.regression.n },
    external = { solved = r.external.solved, n = r.external.n },
    train = summarize(r.train), library = lib, library_size = #g.lib, ops = #g.base.ops,
    policy = g.policy,
  }
end

local function write_dashboard(state, bench, champ_g, champ_r, external)
  local arc_on_disk = 0
  local p = io.popen("ls '" .. ROOT .. "/data/arc' 2>/dev/null | wc -l")
  if p then arc_on_disk = tonumber(p:read("*a")) or 0 p:close() end
  local variants = {}
  for name in pairs(bench.variants or {}) do variants[#variants + 1] = name end
  table.sort(variants)
  local burned = {}
  for name, v in pairs(bench.burned or {}) do if v == true then burned[#burned + 1] = name end end
  table.sort(burned)
  dashboard.write_state(ROOT, {
    gen = state.gen, accepted_total = state.accepted_total, candidates_total = state.candidates_total,
    champion = champion_summary(champ_g, champ_r, bench, #external),
    bench = { epoch = bench.heldout_epoch, families = benchmarks.active_families(bench), burned = burned, variants = variants,
      pressure = bench.pressure, rotations = #bench.rotations, regression_size = #bench.regression, arc_on_disk = arc_on_disk },
    research = { last = state.last_research, next_in_s = (state.last_research or 0) + cfg.research_interval - os.time(),
      papers = research.recent_papers(ROOT, 12) },
    challenge = state.challenge, saturated = state.saturated,
    corpus_size = journal.corpus_size(ROOT),
    meta = state.meta, log = state.log,
  })
  dashboard.ensure_html(ROOT)
end

local function log(state, msg)
  state.log = state.log or {}
  table.insert(state.log, 1, os.date("!%Y-%m-%d %H:%M:%S") .. " " .. msg)
  while #state.log > 30 do table.remove(state.log) end
  io.write(msg, "\n")
  io.flush()
end

-- Single-writer lock. Two loops sharing rsi/state interleave their writes and silently corrupt the
-- lineage; mkdir is atomic on every POSIX filesystem, so it is the lock. A stale lock (killed
-- process) is broken after 30 minutes.
local LOCK = ROOT .. "/state/.lock"
local function acquire_lock()
  if os.execute("mkdir '" .. LOCK .. "' 2>/dev/null") then return true end
  local f = io.open(LOCK .. "/pid", "r")
  local age = nil
  if f then
    local t = tonumber(f:read("*a") or "")
    f:close()
    if t then age = os.time() - t end
  end
  if age and age > 1800 then
    os.execute("rm -rf '" .. LOCK .. "'")
    return os.execute("mkdir '" .. LOCK .. "' 2>/dev/null") and true or false
  end
  return false
end

local function write_lock_stamp()
  local f = io.open(LOCK .. "/pid", "w")
  if f then f:write(tostring(os.time())) f:close() end
end

local function release_lock() os.execute("rm -rf '" .. LOCK .. "'") end

function M.step(opts)
  opts = opts or {}
  ensure_dirs()
  if not acquire_lock() then
    error("another generation is already running (" .. LOCK .. "); refusing to share state")
  end
  write_lock_stamp()
  local ok_run, err = pcall(M.run_generation, opts)
  release_lock()
  if not ok_run then error(err, 0) end
  return err
end

function M.run_generation(opts)
  local state = load_state()
  local bench = benchmarks.load(ROOT)
  local gen = state.gen + 1
  state.gen = gen
  local rng = RNG.new("gen:" .. gen .. ":" .. (bench.secret_salt or ""))
  local out = { gen = gen, accepted = false }

  -- research
  if not opts.skip_research and research.due(state, cfg) then
    progress("research: fetching arXiv + ARC")
    local r = research.run(ROOT, cfg, state)
    log(state, string.format("research: %d new papers, %d new ARC tasks%s", r.papers_new, r.arc_new, #r.errors > 0 and (" (" .. #r.errors .. " fetch errors)") or ""))
    journal.record(ROOT, { kind = "research", gen = gen, papers_new = r.papers_new,
      arc_new = r.arc_new, errors = #r.errors, gaps = r.gaps })
  end

  -- The adversarial split is aimed at whatever currently separates candidates best, rather than at a
  -- fixed list. Chosen from the previous generation's ranking so this generation's splits are built
  -- before its own statistics exist.
  if cfg.adversarial_from_ranking and state.challenge and #state.challenge > 0 then
    benchmarks.set_adversarial(bench,
      challenge.pick_adversarial(state.challenge, #cfg.adversarial_families, cfg.adversarial_families))
  end

  -- benchmarks
  progress("building splits")
  local splits = benchmarks.build_splits(bench, cfg, gen)
  local external = benchmarks.load_external(ROOT, cfg.external_cap)

  -- champion
  local champ_g = genome.load(ROOT .. "/genome")
  local champ_fp = genome.fingerprint(champ_g)
  local champ_r
  local cache = state.champion_cache
  if cache and cache.fingerprint == champ_fp and cache.epoch == bench.heldout_epoch and cache.regression_n == #splits.regression
    and cache.external_n == #external and cache.heldout_n == #splits.heldout then
    champ_r = { heldout = cache.heldout, regression = cache.regression, external = cache.external }
    champ_r.train = eval_split(champ_g, splits.train, "champion: visible split")
    champ_r.adversarial = eval_split(champ_g, splits.adversarial, "champion: adversarial")
  else
    champ_r = eval_all(champ_g, splits, external, "champion", { candidate = "champion" })
    state.champion_cache = { fingerprint = champ_fp, epoch = bench.heldout_epoch, regression_n = #splits.regression,
      external_n = #external, heldout_n = #splits.heldout, heldout = champ_r.heldout, regression = champ_r.regression, external = champ_r.external }
  end
  log(state, string.format("gen %d champion %s: held-out %d/%d, visible %d/%d, adversarial %d/%d, regression %d/%d, ARC %d/%d",
    gen, champ_fp, champ_r.heldout.solved, champ_r.heldout.n, champ_r.train.solved, champ_r.train.n,
    champ_r.adversarial.solved, champ_r.adversarial.n, champ_r.regression.solved, champ_r.regression.n, champ_r.external.solved, champ_r.external.n))

  -- Challenge statistics. Difficulty comes from the champion's held-out and adversarial results;
  -- discrimination is filled in per candidate below, since it is a property of the comparison rather
  -- than of any one run.
  state.family_stats = state.family_stats or {}
  for _, split in ipairs({ champ_r.heldout, champ_r.adversarial }) do
    for _, r in ipairs(split.per_task) do
      challenge.update(state.family_stats, r.family, r.solved, r.partial, gen)
    end
  end

  -- evidence corpus: every visible-split solution and near-miss ever seen (never held-out data)
  state.corpus = state.corpus or {}
  state.near_corpus = state.near_corpus or {}
  local have = {}
  for _, e in ipairs(state.corpus) do have[e.expr] = true end
  for i, r in ipairs(champ_r.train.per_task) do
    local bucket = features.bucket(splits.train[i])
    if r.solved == 1 and r.program and not have[r.program] then
      state.corpus[#state.corpus + 1] = { expr = r.program, family = r.family, gen = gen, bucket = bucket }
      have[r.program] = true
    elseif r.solved == 0 and r.partial >= 0.66 and r.partial_program then
      state.near_corpus[#state.near_corpus + 1] = { expr = r.partial_program, family = r.family, gen = gen, bucket = bucket }
    end
  end
  while #state.corpus > 3000 do table.remove(state.corpus, 1) end
  while #state.near_corpus > 800 do table.remove(state.near_corpus, 1) end

  -- The durable training set. state.corpus is a rolling window the operators read; this file keeps
  -- everything, so the record of what the system learned from does not get trimmed away.
  do
    local rows = {}
    for i, r in ipairs(champ_r.train.per_task) do
      if r.solved == 1 and r.program then
        local t = splits.train[i]
        rows[#rows + 1] = {
          gen = gen, family = r.family, bucket = features.bucket(t),
          in_type = t.in_type, out_type = t.out_type, program = r.program, nodes = r.nodes,
          -- recorded for the reader only; the solver is handed tasks.solver_view, which omits it
          generator = t.meta and t.meta.expr, depth = t.meta and t.meta.depth,
        }
      end
    end
    journal.add_corpus(ROOT, rows)
  end

  -- candidates
  local ctx = { rng = rng, prims = champ_g.prims, train_results = champ_r.train, adversarial_results = champ_r.adversarial,
    corpus = state.corpus, near_corpus = state.near_corpus }
  local best = nil
  local used = {}
  local narrated_candidates = {}
  for k = 1, cfg.candidates_per_gen do
    local cand_g, op, desc = mutate.make_candidate(champ_g, ctx, state.meta, used)
    if not cand_g then log(state, "no applicable mutation operator") break end
    used[op] = true
    state.meta.tried[op] = (state.meta.tried[op] or 0) + 1
    state.candidates_total = state.candidates_total + 1
    local tag = string.format("c%d_%s", k, op)
    local dir = lineage.snapshot(ROOT, gen, tag, cand_g)
    local loaded = genome.load(dir)
    local extra = { candidate = tag, operator = op, change = desc }
    -- Cheap screen: every acceptance clause requires a non-negative held-out delta, so a candidate
    -- that solves strictly fewer held-out tasks is rejected without running the other four splits.
    -- This is equivalent to the full rule, not a relaxation of it.
    local cand_r = { heldout = eval_split(loaded, splits.heldout, "candidate " .. k .. ": held-out", nil, extra) }
    for i, cr in ipairs(cand_r.heldout.per_task) do
      challenge.note_comparison(state.family_stats, cr.family,
        cr.solved ~= champ_r.heldout.per_task[i].solved, gen)
    end
    local accepted, reason, ev
    if cand_r.heldout.solved < champ_r.heldout.solved then
      local a, b = evaluate.vector(champ_r.heldout), evaluate.vector(cand_r.heldout)
      local wins, losses = stats.wins_losses(a, b)
      local d = cand_r.heldout.solve_rate - champ_r.heldout.solve_rate
      accepted, reason = false, string.format("screened out on held-out (%.1fpp, wins %d / losses %d)", d * 100, wins, losses)
      ev = { heldout_delta = d, wins = wins, losses = losses, screened = true }
    else
      cand_r.train = eval_split(loaded, splits.train, "candidate " .. k .. ": visible split", nil, extra)
      cand_r.adversarial = eval_split(loaded, splits.adversarial, "candidate " .. k .. ": adversarial", nil, extra)
      cand_r.regression = eval_split(loaded, splits.regression, "candidate " .. k .. ": regression suite", nil, extra)
      cand_r.external = eval_split(loaded, external, "candidate " .. k .. ": external ARC", { nodes = cfg.external_nodes, seconds = cfg.external_seconds }, extra)
      accepted, reason, ev = decide(champ_r, cand_r, gen .. ":" .. k)
    end
    local entry = {
      gen = gen, candidate = k, operator = op, change = desc, accepted = accepted, reason = reason,
      champion_fp = champ_fp, candidate_fp = genome.fingerprint(loaded), snapshot = dir,
      champion_heldout = champ_r.heldout.solve_rate, candidate_heldout = cand_r.heldout.solve_rate,
      heldout_delta = ev.heldout_delta or 0, p_value = ev.p_value, ci = ev.ci, wins = ev.wins, losses = ev.losses,
      adversarial_delta = ev.adversarial_delta, train_delta = ev.train_delta, nodes_ratio = ev.nodes_ratio,
      regression = ev.regression, external = cand_r.external and (cand_r.external.solved .. "/" .. cand_r.external.n) or nil,
      time = os.time(),
    }
    -- bookkeeping must never take down a generation: the verdict is already decided
    pcall(function()
      os.execute("mkdir -p '" .. dir .. "'")
      json.write(dir .. "/evidence.json", { entry = entry, heldout = cand_r.heldout,
        adversarial = cand_r.adversarial, train = cand_r.train })
    end)
    pcall(lineage.record, ROOT, entry)
    narrated_candidates[#narrated_candidates + 1] = entry
    log(state, string.format("  candidate %d [%s] %s -> %s: %s", k, op, desc, accepted and "ACCEPT" or "reject", reason))
    if accepted and (not best or (cand_r.heldout.solve_rate > best.r.heldout.solve_rate)) then
      best = { g = cand_g, loaded = loaded, r = cand_r, op = op, desc = desc, dir = dir, entry = entry }
    end
  end

  -- retain
  if best then
    state.meta.accepted[best.op] = (state.meta.accepted[best.op] or 0) + 1
    state.accepted_total = state.accepted_total + 1
    genome.save(best.g, ROOT .. "/genome")
    lineage.snapshot(ROOT, gen, "champion", best.g)
    best.r.heldout.gen = gen
    local added = benchmarks.extend_regression(bench, cfg, splits.heldout, best.r.heldout)
    local driver = benchmarks.driver_family(splits.heldout, champ_r.heldout, best.r.heldout)
    local rotation = benchmarks.after_accept(bench, cfg, driver, gen)
    log(state, string.format("  retained candidate from %s; regression suite +%d (now %d); driver family %s", best.op, added, #bench.regression, tostring(driver)))
    journal.record(ROOT, { kind = "accepted", gen = gen, operator = best.op, change = best.desc,
      reason = best.entry.reason, before = champ_r.heldout.solve_rate, after = best.r.heldout.solve_rate,
      driver = driver, fingerprint = genome.fingerprint(best.g) })
    if rotation then
      log(state, "  " .. rotation)
      journal.record(ROOT, { kind = "rotation", gen = gen, detail = rotation })
    end
    state.champion_cache = nil
    champ_g, champ_r = best.loaded, best.r
    out.accepted, out.operator, out.change = true, best.op, best.desc
  end

  -- challenge ranking, and the journal
  local ranking = challenge.rank(state.family_stats, gen, cfg.challenge_weights)
  local saturated = challenge.saturated(ranking, cfg.saturation_solve_floor, cfg.saturation_disc_floor)
  state.challenge = ranking
  state.saturated = saturated
  local spawned = benchmarks.spawn_from_saturation(bench, saturated, gen)
  if spawned then
    log(state, "  " .. spawned)
    journal.record(ROOT, { kind = "rotation", gen = gen, detail = spawned })
  end
  do
    local ok_j, err_j = pcall(journal.render, ROOT, {
      gen = gen, fingerprint = genome.fingerprint(champ_g),
      heldout = { solved = champ_r.heldout.solved, n = champ_r.heldout.n,
        rate = champ_r.heldout.solve_rate, lo = select(2, stats.wilson(champ_r.heldout.solved, champ_r.heldout.n)),
        hi = select(3, stats.wilson(champ_r.heldout.solved, champ_r.heldout.n)) },
      adversarial = champ_r.adversarial, regression = champ_r.regression, external = champ_r.external,
      accepted_total = state.accepted_total, candidates_total = state.candidates_total,
      corpus_size = journal.corpus_size(ROOT), library_size = #champ_g.lib, ops = #champ_g.base.ops,
      challenge = ranking, saturated = saturated, heldout_epoch = bench.heldout_epoch,
    })
    if not ok_j then io.stderr:write("journal render failed: " .. tostring(err_j) .. "\n") end
  end

  -- The narration. Written every generation with no typing delay so the loop is not slowed by it;
  -- `lua run.lua narrate` replays the latest entry a word at a time.
  do
    local ok_n, res = pcall(narrator.narrate, {
      gen = gen, fingerprint = genome.fingerprint(champ_g),
      heldout = champ_r.heldout, adversarial = champ_r.adversarial,
      regression = champ_r.regression, external = champ_r.external,
      candidates = narrated_candidates, accepted = best ~= nil,
      corpus_size = journal.corpus_size(ROOT), library_size = #champ_g.lib,
      challenge = ranking, saturated = saturated,
      accepted_total = state.accepted_total, candidates_total = state.candidates_total,
    }, { quiet = true, seed = "narrate:" .. gen })
    if ok_n then
      pcall(narrator.record, ROOT, res)
      pcall(narrator.render_history, ROOT)
      if res.corrections and #res.corrections > 0 then
        log(state, string.format("  narrator corrected %d fact(s) against recomputation", #res.corrections))
      end
    else
      io.stderr:write("narration failed: " .. tostring(res) .. "\n")
    end
  end

  local pruned = lineage.prune(ROOT, gen, 50)
  if pruned > 0 then log(state, string.format("  pruned %d rejected candidate snapshots older than generation %d", pruned, gen - 50)) end

  out.heldout = champ_r.heldout.solve_rate
  benchmarks.save(bench)
  save_state(state)
  write_dashboard(state, bench, champ_g, champ_r, external)
  progress("idle after generation " .. gen)
  return out
end

function M.status()
  ensure_dirs()
  local state = load_state()
  local bench = benchmarks.load(ROOT)
  return state, bench
end

return M
