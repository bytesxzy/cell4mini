-- Reasoning-integrated generation: the Markov chain writes the words, the reasoning state chooses
-- what to talk about and supplies every number, and a verification pass refuses anything that does
-- not check out.
--
-- The three stages, in order:
--
--   1. REASONING SELECTS THE TOPICS. The facts decide which [topic] tags are appropriate: a
--      generation with an acceptance gets [verdict_accept], one without gets [verdict_none], a
--      saturated family adds [saturation]. The chain never chooses its subject; it is told.
--
--   2. THE CHAIN WRITES. Sampling P(w | previous words) at the given temperature, seeded from
--      os.time() mixed with the generation number and a counter, so the wording differs between runs
--      while remaining reproducible from the recorded seed.
--
--   3. VERIFICATION REFUSES. A sampled sentence is rejected if it carries a slot the facts cannot
--      fill, if any numeral survives outside a slot, or if a filled value disagrees with the audited
--      facts. Rejected samples are re-drawn up to `attempts` times; if none passes, the deterministic
--      narrator template for that topic is used instead. The output is therefore never unverified,
--      and the fallback rate is reported rather than hidden.
--
-- That last stage is the whole point. A Markov chain has no notion of truth and will cheerfully
-- produce a fluent falsehood. Constraining it to a numeral-free vocabulary and filling quantities
-- from audited facts is what makes it safe to let it speak at all.
local markov = require("rsi.lm.markov")
local narrator = require("rsi.kernel.narrator")
local RNG = require("rsi.kernel.rng")
local M = {}

M.CORPUS = "rsi/lm/corpus.txt"

-- os.time() is coarse (one second), so on its own it would give every generation in the same second
-- the same wording. Mixing in os.clock() and the generation number makes the seed vary properly
-- while still being recorded, so any narration can be reproduced exactly.
function M.seed(gen, counter)
  return string.format("%d:%d:%d:%d", os.time(), math.floor((os.clock() * 1e6) % 1e6),
    gen or 0, counter or 0)
end

local model_cache = nil

function M.load(path, order)
  path = path or M.CORPUS
  if model_cache and model_cache.path == path then return model_cache.model end
  local m = markov.new(order or 3)
  local ok, err = m:train_file(path)
  if not ok then return nil, err end
  model_cache = { path = path, model = m }
  return m
end

-- Which topics does the reasoning state call for, and in what order?
function M.topics_for(f)
  local t = { "standing", "supporting" }
  t[#t + 1] = (f.accepted == 1) and "verdict_accept" or "verdict_none"
  if (f.rejects_screened or 0) > 0 then t[#t + 1] = "screening" end
  if (f.rejects_regression or 0) > 0 then t[#t + 1] = "regression_loss" end
  if f.top_challenge then t[#t + 1] = "challenge" end
  if f.saturated then t[#t + 1] = "saturation" end
  t[#t + 1] = "memory"
  return t
end

local function fmt(v)
  if type(v) ~= "number" then return tostring(v) end
  if v == math.floor(v) then return string.format("%d", v) end
  return string.format("%.1f", v)
end

-- Slots whose value is a percentage read better with the sign attached.
local PCT = { heldout_pct = true, top_challenge_pct = true, best_delta_pp = true }

local function fill(text, f)
  local missing = nil
  local filled = text:gsub("{([%w_]+)}", function(key)
    local v = f[key]
    if v == nil then
      missing = missing or key
      return "{" .. key .. "}"
    end
    if PCT[key] then
      if key == "best_delta_pp" then return string.format("%.1f", v) end
      return string.format("%.1f%%", v)
    end
    return fmt(v)
  end)
  return filled, missing
end

-- Every numeral in the finished sentence must be one the facts actually contain. This catches a
-- corpus line that slipped a number past the loader, and any arithmetic the filler got wrong.
local function numerals_are_grounded(text, f)
  local allowed = {}
  for _, v in pairs(f) do
    if type(v) == "number" then
      allowed[fmt(v)] = true
      allowed[string.format("%.1f", v)] = true
      allowed[string.format("%d", math.floor(v))] = true
    end
  end
  for num in text:gmatch("%d+%.?%d*") do
    if not allowed[num] then return false, num end
  end
  return true
end

-- Sparse n-gram counts splice: backing off to a two-word context can rejoin the tail of one training
-- line to the middle of another, producing a sentence that says the same thing twice or trails off
-- with its subject missing. Verification cannot catch that -- the numbers are all real -- so these are
-- structural checks on the surface form, applied before the sentence is allowed out. A rejected
-- sample is re-drawn; the fallback rate is reported rather than hidden.
local STOP = {
  ["the"]=1,["a"]=1,["an"]=1,["of"]=1,["and"]=1,["to"]=1,["in"]=1,["on"]=1,["it"]=1,["i"]=1,
  ["is"]=1,["was"]=1,["were"]=1,["at"]=1,["that"]=1,["this"]=1,["for"]=1,["with"]=1,["as"]=1,
  ["but"]=1,["not"]=1,["no"]=1,["me"]=1,["my"]=1,["them"]=1,["they"]=1,["one"]=1,["more"]=1,
}

local function well_formed(raw_toks)
  local words = {}
  for _, t in ipairs(raw_toks) do
    if t:match("^[%w{}_%%%.]") then words[#words + 1] = t:lower() end
  end
  -- Too short to be a sentence: "At {top_challenge_pct} solved ." has lost its subject.
  if #words < 6 then return false, "too short" end
  -- A content word three times over is the signature of a splice.
  local seen, bigrams = {}, {}
  for i, w in ipairs(words) do
    if not STOP[w] and #w > 2 then
      seen[w] = (seen[w] or 0) + 1
      if seen[w] > 2 then return false, "repeats " .. w end
    end
    if i > 1 then
      local b = words[i - 1] .. " " .. w
      if bigrams[b] then return false, "repeats phrase " .. b end
      bigrams[b] = true
    end
  end
  -- A sentence the chain walked off the end of: a function word cannot be the last word.
  local DANGLING = {
    ["the"]=1,["a"]=1,["an"]=1,["of"]=1,["and"]=1,["to"]=1,["in"]=1,["on"]=1,["at"]=1,["for"]=1,
    ["with"]=1,["as"]=1,["but"]=1,["that"]=1,["than"]=1,["from"]=1,["by"]=1,["is"]=1,["was"]=1,
    ["were"]=1,["it"]=1,["i"]=1,["my"]=1,["this"]=1,["not"]=1,["no"]=1,["which"]=1,["when"]=1,
  }
  if DANGLING[words[#words]] then return false, "ends on " .. words[#words] end
  -- Two independent clauses joined by "and" that restate the same measurement.
  local halves = {}
  for part in table.concat(words, " "):gmatch("[^,]+") do halves[#halves + 1] = part end
  for i = 1, #halves do
    for j = i + 1, #halves do
      if halves[i] == halves[j] then return false, "duplicate clause" end
    end
  end
  return true
end

M.well_formed = well_formed

-- Generate one sentence for a topic, or nil if nothing verifiable came out.
function M.sentence(model, topic, f, rng, opts)
  opts = opts or {}
  local attempts = opts.attempts or 12
  for _ = 1, attempts do
    local raw, toks = model:generate("[" .. topic .. "]", rng, {
      temperature = opts.temperature or 0.85, max_len = opts.max_len or 44,
    })
    if raw then
      local shaped, why = well_formed(toks or {})
      if not shaped then
        opts.last_reject = "malformed: " .. tostring(why)
        raw = nil
      end
    end
    if raw then
      local text, missing = fill(raw, f)
      if not missing then
        local ok, bad = numerals_are_grounded(text, f)
        if ok then
          local first = text:sub(1, 1):upper() .. text:sub(2)
          if not first:match("[%.%?!]$") then first = first .. "." end
          return first, raw
        else
          opts.last_reject = "ungrounded numeral " .. tostring(bad)
        end
      else
        opts.last_reject = "unfillable slot {" .. missing .. "}"
      end
    end
  end
  return nil
end

-- The full narration. Returns the same shape as narrator.narrate so the two are interchangeable,
-- plus per-sentence provenance saying whether the chain or the template produced each line.
function M.narrate(raw, opts)
  opts = opts or {}
  local model, err = M.load(opts.corpus, opts.order)
  if not model then return nil, err end

  local f = narrator.gather(raw)
  local problems = narrator.audit(f, raw)
  -- Correct before generating: the chain must never be handed a fact that failed its audit.
  local corrections = {}
  for _, p in ipairs(problems) do
    corrections[#corrections + 1] = { key = p.key, stated = p.stated, actual = p.actual }
    f[p.key] = p.actual
  end

  local seed = opts.seed or M.seed(f.gen, 0)
  local rng = RNG.new(seed)
  local fallback_templates = narrator.compose(f, "fallback:" .. tostring(f.gen))
  local by_id = {}
  for _, s in ipairs(fallback_templates) do by_id[s.id] = s.text end

  local sentences, provenance, from_chain, from_template = {}, {}, 0, 0
  for _, topic in ipairs(M.topics_for(f)) do
    local text = M.sentence(model, topic, f, rng, opts)
    if text then
      from_chain = from_chain + 1
      provenance[#provenance + 1] = "chain"
    else
      text = by_id[topic]
      if text then
        from_template = from_template + 1
        provenance[#provenance + 1] = "template"
      end
    end
    if text then sentences[#sentences + 1] = text end
  end

  return {
    gen = f.gen, time = os.time(), sentences = sentences, corrections = corrections,
    facts = f, audited_clean = #problems == 0,
    generator = "markov", seed = seed, provenance = provenance,
    from_chain = from_chain, from_template = from_template,
    model = model:stats(),
  }
end

return M
