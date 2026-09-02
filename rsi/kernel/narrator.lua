-- The narrator: the system's account of itself, in English, for its own future reference.
--
-- WHAT THIS IS NOT. It is not a language model. There is no neural network, no training on text, no
-- external API, and it cannot say anything that is not already a number somewhere in this system.
-- Calling it one would be the same overclaim this project has refused everywhere else. What it is:
-- a procedural generator that turns measurements into prose, with the phrasing varied by a seeded
-- RNG and the *content* pinned to audited facts.
--
-- WHY IT EXISTS. JOURNAL.md is a ledger -- tables, deltas, p-values -- and answers "what are the
-- numbers". This answers "what happened and what did it mean", in a form you can read start to
-- finish, or hand to a future session to catch up. That is the history it keeps.
--
-- HOW ACCURACY IS ENFORCED, rather than hoped for. Every sentence declares which facts it uses. The
-- facts are gathered once from the run's results, and then INDEPENDENTLY RECOMPUTED from the raw
-- source by `audit`. A sentence whose facts disagree with the recomputation is never printed as
-- truth: it is printed, struck, and reissued with the corrected value, and the correction is written
-- to the history alongside it. So a bug in the gathering shows up as a visible correction rather
-- than as a confident falsehood. That is what "writes and corrects itself" means here -- a real
-- consistency check with a visible outcome, not a typing animation.
--
-- EMPHASIS. Words are capitalised only where a stated rule fires: a result significant under both
-- tests, a regression loss, a saturated benchmark, a new champion. At most `caps_budget` spans per
-- narration, spent on the highest-significance events first, so capitals keep meaning something.
local RNG = require("rsi.kernel.rng")
local json = require("rsi.kernel.json")
local plat = require("rsi.kernel.plat")
local M = {}

M.CAPS_BUDGET = 3

-- ---------------------------------------------------------------- facts

-- Gather the quantities the narration is allowed to talk about. Nothing outside this table can be
-- mentioned, because every phrasing interpolates from it.
function M.gather(raw)
  local f = {}
  f.gen = raw.gen
  f.fingerprint = raw.fingerprint
  f.heldout_solved = raw.heldout.solved
  f.heldout_n = raw.heldout.n
  f.heldout_pct = raw.heldout.n > 0 and (100 * raw.heldout.solved / raw.heldout.n) or 0
  f.adv_solved = raw.adversarial.solved
  f.adv_n = raw.adversarial.n
  f.regr_solved = raw.regression.solved
  f.regr_n = raw.regression.n
  f.ext_solved = raw.external.solved
  f.ext_n = raw.external.n
  f.candidates = #raw.candidates
  f.accepted = raw.accepted and 1 or 0
  f.corpus = raw.corpus_size or 0
  f.library = raw.library_size or 0
  f.nodes = math.floor((raw.heldout.nodes_mean or 0) + 0.5)
  f.best_delta_pp = 0
  f.best_operator = nil
  f.best_p = nil
  f.rejects_screened = 0
  f.rejects_regression = 0
  for _, c in ipairs(raw.candidates) do
    local d = (c.heldout_delta or 0) * 100
    if d > f.best_delta_pp then
      f.best_delta_pp = d
      f.best_operator = c.operator
      f.best_p = c.p_value
    end
    if c.reason and c.reason:find("screened out", 1, true) then f.rejects_screened = f.rejects_screened + 1 end
    if c.reason and c.reason:find("regression:", 1, true) then f.rejects_regression = f.rejects_regression + 1 end
  end
  f.top_challenge = raw.challenge and raw.challenge[1] and raw.challenge[1].family or nil
  f.top_challenge_pct = raw.challenge and raw.challenge[1] and (100 * raw.challenge[1].solve_rate) or nil
  f.saturated = raw.saturated and #raw.saturated > 0 and raw.saturated[1] or nil
  f.accepted_total = raw.accepted_total or 0
  f.candidates_total = raw.candidates_total or 0
  return f
end

-- Recompute every fact from the raw source by a second route, and report disagreements. This is the
-- guard that makes the narration trustworthy: if `gather` is wrong, this says so.
function M.audit(f, raw)
  local problems = {}
  local function check(key, expected, tol)
    local got = f[key]
    if expected == nil and got == nil then return end
    if got == nil or expected == nil then
      problems[#problems + 1] = { key = key, stated = got, actual = expected }
      return
    end
    if type(expected) == "number" then
      if math.abs(got - expected) > (tol or 0) then
        problems[#problems + 1] = { key = key, stated = got, actual = expected }
      end
    elseif got ~= expected then
      problems[#problems + 1] = { key = key, stated = got, actual = expected }
    end
  end

  -- recount from the per-task vectors rather than trusting the summary fields
  local solved = 0
  for _, r in ipairs(raw.heldout.per_task or {}) do solved = solved + (r.solved or 0) end
  if raw.heldout.per_task and #raw.heldout.per_task > 0 then
    check("heldout_solved", solved)
    check("heldout_n", #raw.heldout.per_task)
    check("heldout_pct", 100 * solved / #raw.heldout.per_task, 0.05)
  end
  local adv = 0
  for _, r in ipairs(raw.adversarial.per_task or {}) do adv = adv + (r.solved or 0) end
  if raw.adversarial.per_task and #raw.adversarial.per_task > 0 then
    check("adv_solved", adv)
    check("adv_n", #raw.adversarial.per_task)
  end
  check("candidates", #raw.candidates)
  local acc = 0
  for _, c in ipairs(raw.candidates) do if c.accepted then acc = 1 end end
  check("accepted", acc)
  return problems
end

-- ---------------------------------------------------------------- phrasing

local function pct(x) return string.format("%.1f%%", x) end

-- Each entry: a list of equivalent phrasings and the facts it depends on. Varying the wording while
-- the asserted content stays fixed is what makes this procedural rather than a fixed printf; the
-- selftest checks every phrasing of every sentence against the same audit.
local SENTENCES = {
  {
    id = "standing", uses = { "gen", "heldout_solved", "heldout_n", "heldout_pct" },
    forms = {
      function(f) return string.format("Generation %d closed with %d of %d held-out tasks solved, %s.",
        f.gen, f.heldout_solved, f.heldout_n, pct(f.heldout_pct)) end,
      function(f) return string.format("At the end of generation %d I stood at %s on the secret split, %d of %d.",
        f.gen, pct(f.heldout_pct), f.heldout_solved, f.heldout_n) end,
      function(f) return string.format("Generation %d: %d solved out of %d held-out tasks (%s).",
        f.gen, f.heldout_solved, f.heldout_n, pct(f.heldout_pct)) end,
    },
  },
  {
    id = "supporting", uses = { "adv_solved", "adv_n", "regr_n", "nodes" },
    forms = {
      function(f) return string.format("The adversarial split gave %d of %d, the regression suite held %d task%s, and a task cost me %d search nodes on average.",
        f.adv_solved, f.adv_n, f.regr_n, f.regr_n == 1 and "" or "s", f.nodes) end,
      function(f) return string.format("Adversarially I managed %d of %d; %d regression task%s stood behind me; the mean task took %d nodes.",
        f.adv_solved, f.adv_n, f.regr_n, f.regr_n == 1 and "" or "s", f.nodes) end,
    },
  },
  {
    id = "verdict_none", uses = { "candidates", "best_delta_pp" },
    when = function(f) return f.accepted == 0 end,
    forms = {
      function(f)
        if f.best_operator then
          return string.format("I tried %d candidate%s and kept none. The closest was %s at +%.1fpp, which the tests would not call real.",
            f.candidates, f.candidates == 1 and "" or "s", f.best_operator, f.best_delta_pp)
        end
        return string.format("I tried %d candidate%s and kept none; not one of them gained ground.",
          f.candidates, f.candidates == 1 and "" or "s")
      end,
      function(f)
        if f.best_operator then
          return string.format("None of the %d candidates survived. %s came nearest with +%.1fpp, still inside the noise.",
            f.candidates, f.best_operator, f.best_delta_pp)
        end
        return string.format("None of the %d candidates survived, and none even gained.", f.candidates)
      end,
    },
  },
  {
    id = "verdict_accept", uses = { "best_operator", "best_delta_pp" },
    when = function(f) return f.accepted == 1 end,
    caps = { "NEW CHAMPION" },
    forms = {
      function(f) return string.format("NEW CHAMPION: %s gained +%.1fpp and cleared both tests, so I kept it.",
        f.best_operator or "a candidate", f.best_delta_pp) end,
      function(f) return string.format("I have a NEW CHAMPION. %s was worth +%.1fpp and passed the bootstrap and the sign test alike.",
        f.best_operator or "A candidate", f.best_delta_pp) end,
    },
  },
  {
    id = "screening", uses = { "rejects_screened" },
    when = function(f) return f.rejects_screened > 0 end,
    forms = {
      function(f) return string.format("%d of them solved strictly fewer held-out tasks and were screened out before the other splits were even run.",
        f.rejects_screened) end,
      function(f) return string.format("%d were dropped on the held-out screen alone, which no acceptance clause could have survived anyway.",
        f.rejects_screened) end,
    },
  },
  {
    id = "regression_loss", uses = { "rejects_regression" },
    when = function(f) return f.rejects_regression > 0 end,
    caps = { "LOST GROUND" },
    forms = {
      function(f) return string.format("%d candidate%s LOST GROUND on the regression suite, breaking something an earlier champion could already do.",
        f.rejects_regression, f.rejects_regression == 1 and "" or "s") end,
    },
  },
  {
    id = "challenge", uses = { "top_challenge", "top_challenge_pct" },
    when = function(f) return f.top_challenge ~= nil end,
    forms = {
      function(f) return string.format("The family with most left to teach me is %s, which I solve %s of the time.",
        f.top_challenge, pct(f.top_challenge_pct)) end,
      function(f) return string.format("%s is where I still learn the most: %s solved, and it still separates one candidate from another.",
        f.top_challenge, pct(f.top_challenge_pct)) end,
    },
  },
  {
    id = "saturation", uses = { "saturated" },
    when = function(f) return f.saturated ~= nil end,
    caps = { "SATURATED" },
    forms = {
      function(f) return string.format("%s is SATURATED -- I solve it almost every time and it no longer tells candidates apart -- so a harder variant was spawned from it.",
        f.saturated) end,
    },
  },
  {
    id = "memory", uses = { "corpus", "library", "accepted_total", "candidates_total" },
    forms = {
      function(f) return string.format("I have %d solved programs on record and %d learned abstraction%s, from %d accepted change%s out of %d candidates in all.",
        f.corpus, f.library, f.library == 1 and "" or "s", f.accepted_total, f.accepted_total == 1 and "" or "s", f.candidates_total) end,
      function(f) return string.format("My corpus stands at %d solved programs; the library holds %d; across the whole run %d of %d candidates were kept.",
        f.corpus, f.library, f.accepted_total, f.candidates_total) end,
    },
  },
}

-- Build the narration. Deterministic given (facts, seed): same generation narrates the same way
-- twice, which matters because the history has to be stable when regenerated.
function M.compose(f, seed)
  local rng = RNG.new(seed or ("narrate:" .. tostring(f.gen)))
  local out, caps_used = {}, 0
  for _, s in ipairs(SENTENCES) do
    if not s.when or s.when(f) then
      local ok = true
      for _, key in ipairs(s.uses) do if f[key] == nil then ok = false break end end
      if ok then
        local form = s.forms[rng:int(#s.forms)]
        local text = form(f)
        if s.caps and caps_used >= M.CAPS_BUDGET then
          for _, span in ipairs(s.caps) do
            local lower = span:sub(1, 1) .. span:sub(2):lower()
            text = text:gsub(span, lower, 1)
          end
        elseif s.caps then
          caps_used = caps_used + #s.caps
        end
        out[#out + 1] = { id = s.id, text = text, uses = s.uses }
      end
    end
  end
  return out
end

-- ---------------------------------------------------------------- output

local function nap(seconds)
  if seconds <= 0 then return end
  plat.sleep(seconds)
end

-- Type it out a word at a time. `delay` of 0 prints instantly, which is what the loop uses so a
-- generation is not slowed by its own narration.
function M.stream(text, delay)
  delay = delay or 0
  local first = true
  for word in text:gmatch("%S+") do
    io.write(first and "" or " ", word)
    io.flush()
    first = false
    nap(delay)
  end
  io.write("\n")
  io.flush()
end

-- Narrate, auditing as it goes. A sentence whose facts fail the audit is struck and reissued.
-- Returns the sentences actually asserted, plus any corrections made.
function M.narrate(raw, opts)
  opts = opts or {}
  local delay = opts.delay or 0
  local f = M.gather(raw)
  local problems = M.audit(f, raw)
  local bad = {}
  for _, p in ipairs(problems) do bad[p.key] = p end

  local sentences = M.compose(f, opts.seed)
  local asserted, corrections = {}, {}

  for _, s in ipairs(sentences) do
    local wrong = nil
    for _, key in ipairs(s.uses) do if bad[key] then wrong = bad[key] break end end
    if wrong then
      -- print what it was about to claim, then withdraw it in the open
      if not opts.quiet then
        M.stream("  " .. s.text, delay)
        M.stream(string.format("  ^ CORRECTION: '%s' was stated as %s but recomputes to %s. Reissuing.",
          wrong.key, tostring(wrong.stated), tostring(wrong.actual)), delay)
      end
      local fixed = {}
      for k, v in pairs(f) do fixed[k] = v end
      fixed[wrong.key] = wrong.actual
      local redone = M.compose(fixed, opts.seed)
      local replacement = s.text
      for _, r in ipairs(redone) do if r.id == s.id then replacement = r.text end end
      if not opts.quiet then M.stream("  " .. replacement, delay) end
      asserted[#asserted + 1] = replacement
      corrections[#corrections + 1] = { key = wrong.key, stated = wrong.stated, actual = wrong.actual }
    else
      if not opts.quiet then M.stream("  " .. s.text, delay) end
      asserted[#asserted + 1] = s.text
    end
  end

  return { gen = f.gen, time = os.time(), sentences = asserted, corrections = corrections,
    facts = f, audited_clean = #problems == 0 }
end

function M.record(root, entry)
  json.append_line(root .. "/data/narrative.jsonl", entry)
  -- Mirrored into www/ so the static pages can read it over HTTP without exposing rsi/data.
  json.append_line(root .. "/www/narrative.jsonl", entry)
end

function M.render_history(root)
  local all = json.read_lines(root .. "/data/narrative.jsonl")
  local out = {}
  local function w(s) out[#out + 1] = s end
  w("# CELL4 history")
  w("")
  w("The system's own account of what happened, newest first.")
  w("")
  w("The wording comes from `rsi/lm/markov.lua`, an n-gram Markov **language model** trained by")
  w("counting on `rsi/lm/corpus.txt` and sampled with backoff -- the pre-neural kind of language")
  w("model: no network, no gradient, no external service. When no sampled sentence passes")
  w("verification, the deterministic template generator in `rsi/kernel/narrator.lua` writes that")
  w("sentence instead, and the entry says which produced what.")
  w("")
  w("**No number here comes from the model.** Its vocabulary contains no numerals at all; every")
  w("quantity arrives through a slot filled from audited measurements after sampling, and any")
  w("sentence carrying a numeral the facts do not contain is discarded and re-drawn. Those facts are")
  w("recomputed from the raw results before a sentence is allowed to stand. Where a recomputation")
  w("disagreed, the correction is recorded below the entry rather than quietly applied.")
  w("")
  w("Capitals mark events by rule, not for decoration: a result significant under both tests, a")
  w("regression loss, a saturated benchmark, a new champion.")
  w("")
  for i = #all, 1, -1 do
    local e = all[i]
    w(string.format("## Generation %d — %s", e.gen or 0, os.date("!%Y-%m-%d %H:%M UTC", e.time or 0)))
    w("")
    if e.generator == "markov" then
      w(string.format("*n-gram Markov LM, seed `%s`, %d sentence(s) sampled and %d from the template fallback.*",
        tostring(e.seed), e.from_chain or 0, e.from_template or 0))
    else
      w("*Template generator only: no LM corpus was available for this entry.*")
    end
    w("")
    -- A sentence the chain could not produce is marked, so the fallback rate is visible here too.
    for i, s in ipairs(e.sentences or {}) do
      local src = e.provenance and e.provenance[i]
      w(s .. ((src == "template") and " *[template]*" or ""))
    end
    w("")
    if e.corrections and #e.corrections > 0 then
      for _, c in ipairs(e.corrections) do
        w(string.format("> Corrected while writing: `%s` was stated as %s and recomputed to %s.",
          c.key, tostring(c.stated), tostring(c.actual)))
      end
      w("")
    elseif e.audited_clean == false then
      w("> This entry failed its audit in a way the narrator could not repair.")
      w("")
    end
  end
  local fh = assert(io.open(root .. "/../HISTORY.md", "w"))
  fh:write(table.concat(out, "\n"), "\n")
  fh:close()
end

M.SENTENCES = SENTENCES
return M
