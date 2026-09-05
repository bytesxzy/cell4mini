local Lexer = require("cell4.lexer")
local A = assert_that

return {

  ["scans a bare keyword"] = function()
    local s = Lexer.scan("<PRINT> hello", 1)
    A.equal(#s.tokens, 1)
    A.equal(s.tokens[1].name, "PRINT")
    A.equal(s.tokens[1].value, "hello")
  end,

  ["matching is case-insensitive but payload keeps its case"] = function()
    local s = Lexer.scan("<print> Hello World", 1)
    A.equal(s.tokens[1].name, "PRINT")
    A.equal(s.tokens[1].value, "Hello World")
  end,

  -- main.lua called FP1:match("^%s*(.-)%s*$") and threw the result away, so
  -- `<LOCAL> <STRING> hello world` compiled to `[[  hello world]]`.
  ["payload is trimmed exactly once"] = function()
    local s = Lexer.scan("<LOCAL> <STRING>   hello world   ", 1)
    A.equal(Lexer.payload(s), "hello world")
  end,

  -- The bug that produced `background-color:#000000 POSITION: center;`:
  -- each keyword now owns only the text that follows it.
  ["each keyword owns its own value"] = function()
    local s = Lexer.scan("FILL: #000000 POSITION: center", 1)
    A.equal(#s.tokens, 2)
    A.equal(Lexer.value_of(s, "FILL"), "#000000")
    A.equal(Lexer.value_of(s, "POSITION"), "center")
  end,

  ["longest keyword wins"] = function()
    local s = Lexer.scan("DISPLAYX: big", 1)
    A.equal(#s.tokens, 1)
    A.equal(s.tokens[1].name, "DISPLAYX")

    local t = Lexer.scan("LINKFRAMEX: frame.html", 1)
    A.equal(t.tokens[1].name, "LINKFRAMEX")

    local u = Lexer.scan("ATTACHL: a.png", 1)
    A.equal(u.tokens[1].name, "ATTACHL")
  end,

  ["variable references carry their slot"] = function()
    local s = Lexer.scan("<PRINT> ___12", 1)
    A.truthy(s.present.VAR, "expected a VAR token")
    A.equal(s.present.VAR.slot, 12)
  end,

  ["text before the first keyword is kept as lead"] = function()
    local s = Lexer.scan("note <PRINT> hi", 1)
    A.equal(s.lead, "note")
  end,

  ["a line with no keywords produces no tokens"] = function()
    local s = Lexer.scan("just some prose", 1)
    A.equal(#s.tokens, 0)
  end,

  ["CRLF input does not leak a carriage return"] = function()
    local lines = Lexer.scan_all("<PRINT> one\r\n<PRINT> two\r\n")
    A.equal(#lines, 2)
    A.equal(lines[1].tokens[1].value, "one")
    A.equal(lines[2].tokens[1].value, "two")
  end,

  ["scan_all does not invent a trailing line"] = function()
    A.equal(#Lexer.scan_all("<PRINT> one\n"), 1)
    A.equal(#Lexer.scan_all("<PRINT> one"), 1)
  end,
}
