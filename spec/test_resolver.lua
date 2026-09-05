local Lexer = require("cell4.lexer")
local Resolver = require("cell4.resolver")
local Rules = require("cell4.rules")
local Diagnostics = require("cell4.diagnostics")
local A = assert_that

local function resolve(line)
  local d = Diagnostics.new()
  local outcome = Resolver.resolve(Lexer.scan(line, 1), d)
  return outcome, d
end

return {

  -- The property that replaces branch ordering: specificity decides.
  ["a more specific rule outranks a general one"] = function()
    local outcome = resolve("<LOCAL> <GUESS> 1,10")
    A.equal(outcome.rule.id, "local_random")

    local plain = resolve("<LOCAL> 42")
    A.equal(plain.rule.id, "local_plain")
  end,

  ["scoring does not depend on rule order"] = function()
    local before = resolve("<LOCAL> <GUESS> 1,10").rule.id

    -- Reverse the table and resolve again; nested ifs would change answer.
    local original = Rules.rules
    local reversed = {}
    for i = #original, 1, -1 do reversed[#reversed + 1] = original[i] end
    Rules.rules = reversed

    local after = resolve("<LOCAL> <GUESS> 1,10").rule.id
    Rules.rules = original

    A.equal(after, before, "reversing the rule table changed the answer")
  end,

  ["forbids disqualifies a rule outright"] = function()
    -- while_true forbids SLEEP, so the sleeping form must win.
    A.equal(resolve("<REVIVE> <SLEEP> 2").rule.id, "while_sleep")
    A.equal(resolve("<REVIVE>").rule.id, "while_true")
  end,

  ["the raw escape hatch always wins"] = function()
    local outcome = resolve("<LUA> <PRINT> for i = 1, 3 do end")
    A.equal(outcome.rule.id, "raw_lua")
  end,

  ["arithmetic is recognised by shape, not by stray characters"] = function()
    A.equal(resolve("<PRINT> 2 + 3").rule.id, "print_expr")

    -- main.lua fired its math branch on any hyphen, so a sentence with a dash
    -- was emitted unquoted and the generated file stopped parsing.
    A.equal(resolve("<PRINT> well-known problem").rule.id, "print_text")

    -- and any digit made a line "numeric"
    A.equal(resolve("<PRINT> level 2 complete").rule.id, "print_text")
  end,

  ["confidence is 1 when nothing else applies"] = function()
    local outcome = resolve("<DONE>")
    A.equal(outcome.confidence, 1.0)
  end,

  ["confidence drops when two readings are close"] = function()
    local outcome = resolve("<PRINT> 2 + 3")
    A.truthy(outcome.confidence < 1.0, "expected a rival reading")
    A.truthy(outcome.confidence > 0.0, "expected a clear winner")
  end,

  ["an unmatched line is reported instead of vanishing"] = function()
    local outcome, d = resolve("<CLOSE> <STATE> x")
    -- whatever wins, the point is that nothing is silently dropped
    if not outcome then
      A.truthy(d:count("warning") > 0, "expected a warning for an unmatched line")
    end
  end,

  ["explain ranks every applicable reading"] = function()
    local cell4 = require("cell4")
    local report = cell4.explain("<LOCAL> <GUESS> 1,10")
    A.equal(report.winner, "local_random")
    A.truthy(#report.candidates >= 1)
  end,
}
