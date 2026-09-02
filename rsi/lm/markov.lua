-- An n-gram Markov language model. Trained by counting, sampled with backoff and temperature.
--
-- This IS a language model in the textbook sense: it estimates P(w_t | w_{t-1} ... w_{t-n+1}) from a
-- corpus and generates by sampling that distribution. It is the pre-neural kind -- no network, no
-- gradient, no external service -- which is what lets it live inside this project without breaking
-- the no-external-model rule. It is not a transformer and nothing here pretends otherwise.
--
-- THE ONE INVARIANT THAT MAKES IT SAFE. A Markov chain will happily produce a fluent falsehood: it
-- has no idea what is true. So the vocabulary is forbidden to contain numerals. Every quantity in a
-- generated sentence arrives through a {slot}, filled from audited facts after sampling. A training
-- line containing a bare number is REJECTED at load time, and a sampled token that is a bare number
-- is refused at generation time. The chain therefore controls wording and word order; it can never
-- control a number. See rsi/lm/generate.lua for the verification that runs after slot filling.
local M = {}
M.__index = M

local SEP = "\1"

-- Counts are kept PER TOPIC. That matters: with a shared model, backing off to a short context lets
-- the chain jump from one topic's phrasing into another's mid-sentence, and the result reads like
-- two sentences spliced together. Scoping the counts to the topic means backoff can shorten the
-- context but can never leave the subject the reasoning state chose. (This is the usual
-- class-conditional n-gram arrangement.)
function M.new(order)
  return setmetatable({
    order = math.max(2, order or 3),
    topics_n = {},   -- topics_n[topic][k][context_key][token] = count
    vocab = {},
    lines = 0,
    rejected = {},   -- training lines refused, with the reason
  }, M)
end

-- Punctuation is split off so "tasks." and "tasks" are the same word to the model.
function M.tokenize(line)
  local out = {}
  line = line:gsub("([%.,;:%?!%(%)])", " %1 ")
  for tok in line:gmatch("%S+") do out[#out + 1] = tok end
  return out
end

function M.detokenize(toks)
  local s = table.concat(toks, " ")
  s = s:gsub(" ([%.,;:%?!%)])", "%1"):gsub("%( ", "(")
  return s
end

local function is_slot(tok) return tok:match("^{[%w_]+}$") ~= nil end

-- A bare numeral, or a token whose digits are not inside a slot. This is the guard.
local function has_free_number(tok)
  if is_slot(tok) then return false end
  return tok:match("%d") ~= nil
end

function M:add(topic, k, ctx, tok)
  local tn = self.topics_n[topic]
  if not tn then tn = {} self.topics_n[topic] = tn end
  local lvl = tn[k]
  if not lvl then lvl = {} tn[k] = lvl end
  local row = lvl[ctx]
  if not row then row = { total = 0 } lvl[ctx] = row end
  row[tok] = (row[tok] or 0) + 1
  row.total = row.total + 1
end

-- A training line is: [topic] word word {slot} word .
-- The topic tag becomes the first token, so conditioning on a topic is just seeding the context.
function M:train_line(line)
  line = line:gsub("^%s+", ""):gsub("%s+$", "")
  if line == "" or line:sub(1, 1) == "#" then return true end
  local toks = M.tokenize(line)
  if #toks < 3 then
    self.rejected[#self.rejected + 1] = { line = line, why = "too short" }
    return false
  end
  if not toks[1]:match("^%[[%w_]+%]$") then
    self.rejected[#self.rejected + 1] = { line = line, why = "missing [topic] tag" }
    return false
  end
  for _, t in ipairs(toks) do
    if has_free_number(t) then
      self.rejected[#self.rejected + 1] = { line = line, why = "contains a bare number: " .. t }
      return false
    end
  end
  local topic = toks[1]
  toks[#toks + 1] = "</s>"
  for _, t in ipairs(toks) do self.vocab[t] = (self.vocab[t] or 0) + 1 end
  for i = 2, #toks do
    for k = 0, self.order - 1 do
      local parts = {}
      for j = i - k, i - 1 do parts[#parts + 1] = toks[j] or "<s>" end
      self:add(topic, k, table.concat(parts, SEP), toks[i])
    end
  end
  self.lines = self.lines + 1
  return true
end

function M:train_file(path)
  local f = io.open(path, "r")
  if not f then return nil, "cannot open " .. path end
  for line in f:lines() do self:train_line(line) end
  f:close()
  return self
end

function M:vocab_size()
  local n = 0
  for _ in pairs(self.vocab) do n = n + 1 end
  return n
end

function M:topics()
  local out = {}
  for w in pairs(self.vocab) do
    if w:match("^%[[%w_]+%]$") then out[#out + 1] = w end
  end
  table.sort(out)
  return out
end

-- Sample the next token, backing off from the longest available context to the shortest.
-- Returns the token and the context length that produced it (useful for diagnostics).
function M:next_token(topic, history, rng, temperature, reject)
  temperature = temperature or 1.0
  local tn = self.topics_n[topic]
  if not tn then return "</s>", -1 end
  for k = self.order - 1, 0, -1 do
    local parts = {}
    for j = #history - k + 1, #history do parts[#parts + 1] = history[j] or "<s>" end
    local row = tn[k] and tn[k][table.concat(parts, SEP)]
    if row and row.total > 0 then
      local weights, toks, sum = {}, {}, 0
      for tok, c in pairs(row) do
        if tok ~= "total" and not (reject and reject(tok)) then
          local w = (temperature == 1.0) and c or (c ^ (1.0 / temperature))
          toks[#toks + 1] = tok
          weights[#weights + 1] = w
          sum = sum + w
        end
      end
      if sum > 0 then
        -- sort for determinism: pairs() order is not stable across runs
        local idx = {}
        for i = 1, #toks do idx[i] = i end
        table.sort(idx, function(a, b) return toks[a] < toks[b] end)
        local x = rng:float() * sum
        for _, i in ipairs(idx) do
          x = x - weights[i]
          if x <= 0 then return toks[i], k end
        end
        return toks[idx[#idx]], k
      end
    end
  end
  return "</s>", -1
end

-- Generate one sentence for a topic. Numerals can never be emitted: the reject filter refuses any
-- token carrying a digit outside a slot, at every backoff level.
function M:generate(topic, rng, opts)
  opts = opts or {}
  local max_len = opts.max_len or 40
  local temperature = opts.temperature or 0.9
  if not self.topics_n[topic] then return nil end
  local history = { "<s>", "<s>", topic }
  local out = { topic }
  for _ = 1, max_len do
    local tok = self:next_token(topic, history, rng, temperature, has_free_number)
    if tok == "</s>" or tok == "<s>" then break end
    out[#out + 1] = tok
    history[#history + 1] = tok
  end
  if #out < 2 then return nil end
  table.remove(out, 1)  -- drop the topic tag from the surface form
  return M.detokenize(out), out
end

function M:stats()
  local contexts, topics = 0, 0
  for _, tn in pairs(self.topics_n) do
    topics = topics + 1
    for _, lvl in pairs(tn) do
      for _ in pairs(lvl) do contexts = contexts + 1 end
    end
  end
  return { lines = self.lines, vocab = self:vocab_size(), contexts = contexts,
    order = self.order, rejected = #self.rejected, topics = topics }
end

M.is_slot = is_slot
M.has_free_number = has_free_number
return M
