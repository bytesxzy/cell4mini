--[[ cell4/resolver.lua -- pick what a line means, and say how sure you are.

This is the part main.lua called reasoning. There it was a tree of nested
`if Translation:find(K) and not Translation:find(J) ...` branches roughly nine
levels deep, with an `Anti_mixup` boolean threaded through the print/write
subtree to stop two branches firing on one line. Three properties made it hard
to extend:

  1. first branch to match wins, so meaning depended on source order;
  2. a new keyword needed a new `and not` clause in every earlier branch;
  3. when nothing matched, the line vanished with no message.

Here every rule is scored, the best-scoring rule wins, and the margin between
the best two is reported as confidence. Order in rules.lua does not affect the
outcome; ties are broken by rule id so a given input always compiles the same
way.

What "confidence" means: (top - runner_up) / top, clamped to [0,1]. 1.0 means
nothing else was applicable. Near 0 means two readings fit equally well and the
line is genuinely ambiguous -- which is reported rather than guessed past.
]]

local Rules = require("cell4.rules")

local M = {}

-- Below this, the pick is reported as a note so the author can disambiguate.
M.LOW_CONFIDENCE = 0.15

--- Score one rule against one scanned line. Returns nil when inapplicable.
local function score(rule, scanned)
  local present = scanned.present

  if rule.requires then
    for _, name in ipairs(rule.requires) do
      if not present[name] then return nil end
    end
  end

  if rule.forbids then
    for _, name in ipairs(rule.forbids) do
      if present[name] then return nil end
    end
  end

  local total = 10 * (rule.requires and #rule.requires or 0)

  if rule.prefers then
    for _, name in ipairs(rule.prefers) do
      if present[name] then total = total + 2 end
    end
  end

  if rule.bonus then
    total = total + (rule.bonus(scanned) or 0)
  end

  return total + (rule.priority or 0)
end

M.score = score

--- All applicable rules for a line, best first.
function M.candidates(scanned)
  local found = {}
  for _, rule in ipairs(Rules.rules) do
    local s = score(rule, scanned)
    if s then
      found[#found + 1] = { rule = rule, score = s }
    end
  end

  table.sort(found, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.rule.id < b.rule.id -- deterministic tie-break
  end)

  return found
end

--- Resolve one line.
--
-- Returns `nil` when no rule applies, otherwise a table:
--   rule        the winning rule
--   node        the AST node it built
--   score       winning score
--   confidence  0..1, margin over the runner-up
--   rivals      every other applicable rule id, for diagnostics
function M.resolve(scanned, diagnostics)
  if #scanned.tokens == 0 then
    return nil -- blank or prose line; the caller decides whether that matters
  end

  local found = M.candidates(scanned)

  if #found == 0 then
    if diagnostics then
      local names = {}
      for _, t in ipairs(scanned.tokens) do names[#names + 1] = t.name end
      diagnostics:warning(scanned.lineno,
        "no rule matches keywords {" .. table.concat(names, ", ") ..
        "}; line produces no output")
    end
    return nil
  end

  local best = found[1]
  local runner = found[2]

  local confidence = 1.0
  if runner then
    confidence = (best.score - runner.score) / best.score
    if confidence < 0 then confidence = 0 end
    if confidence > 1 then confidence = 1 end
  end

  local rivals = {}
  for i = 2, #found do rivals[#rivals + 1] = found[i].rule.id end

  if diagnostics and runner and best.score == runner.score then
    diagnostics:warning(scanned.lineno,
      "ambiguous: '" .. best.rule.id .. "' and '" .. runner.rule.id ..
      "' both score " .. best.score .. "; taking '" .. best.rule.id .. "'")
  elseif diagnostics and confidence < M.LOW_CONFIDENCE then
    diagnostics:note(scanned.lineno,
      string.format("low confidence (%.2f) picking '%s' over '%s'",
        confidence, best.rule.id, runner.rule.id))
  end

  local node = best.rule.build(scanned)
  node.line = scanned.lineno
  node.rule = best.rule.id

  return {
    rule = best.rule,
    node = node,
    score = best.score,
    confidence = confidence,
    rivals = rivals,
  }
end

return M
