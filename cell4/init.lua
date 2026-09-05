--[[ cell4 -- the CELL keyword language, compiled.

    local cell4 = require("cell4")
    local result = cell4.compile(source_text)

    result.lua           generated Lua        (nil when compilation failed)
    result.html          generated HTML       (nil when compilation failed)
    result.ok            no errors were raised
    result.diagnostics   the findings bag; :format() renders them
    result.program       the AST, if you want to inspect the reasoning
    result.stats         lines / resolved / unresolved / low_confidence

Nothing here touches the filesystem, which is what makes the whole pipeline
testable without a scratch directory. cell4c.lua does the I/O.
]]

local Diagnostics = require("cell4.diagnostics")
local Parser = require("cell4.parser")
local EmitLua = require("cell4.emit_lua")
local EmitHtml = require("cell4.emit_html")
local Resolver = require("cell4.resolver")
local Lexer = require("cell4.lexer")

local M = {
  _VERSION = "cell4 0.1.0",
  lexer = Lexer,
  parser = Parser,
  resolver = Resolver,
  diagnostics = Diagnostics,
}

--- Compile CELL source text.
function M.compile(text)
  local diagnostics = Diagnostics.new()
  local program = Parser.parse(text or "", diagnostics)

  local lua_source = EmitLua.generate(program, diagnostics)
  local html_source = EmitHtml.generate(program, diagnostics)

  local ok = not diagnostics:has_errors()

  return {
    ok = ok,
    lua = ok and lua_source or nil,
    html = ok and html_source or nil,
    program = program,
    stats = program.stats,
    diagnostics = diagnostics,
  }
end

--- Explain how one line was understood, without compiling anything.
--
-- The reason this is part of the public surface: main.lua's classification was
-- only observable by reading its output, so an unexpected result meant
-- bisecting nine levels of nested conditions by hand.
function M.explain(line)
  local scanned = Lexer.scan(line, 1)
  local candidates = Resolver.candidates(scanned)

  local tokens = {}
  for _, t in ipairs(scanned.tokens) do
    tokens[#tokens + 1] = t.name .. (t.value ~= "" and ("=" .. t.value) or "")
  end

  local ranked = {}
  for _, c in ipairs(candidates) do
    ranked[#ranked + 1] = { id = c.rule.id, score = c.score }
  end

  local confidence = 1.0
  if ranked[2] and ranked[1] then
    confidence = (ranked[1].score - ranked[2].score) / ranked[1].score
  elseif not ranked[1] then
    confidence = 0
  end

  return {
    tokens = tokens,
    candidates = ranked,
    winner = ranked[1] and ranked[1].id or nil,
    confidence = confidence,
  }
end

return M
