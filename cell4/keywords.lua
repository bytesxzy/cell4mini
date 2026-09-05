--[[ cell4/keywords.lua -- the vocabulary, as data.

In main.lua the vocabulary was 35 `local` string constants that every branch
had to re-strip by hand, so adding a keyword meant editing ~30 gsub chains.
Here a keyword is a table row. Adding one is adding a row.

`lexeme` is stored lowercase; the lexer lowercases the input line before
comparing, which is how matching stays case-insensitive without the
`:gsub(k,""):gsub(k:lower(),"")` double-strip the original needed everywhere.
]]

local M = {}

-- kind: "backend"  -> contributes to source/execute.lua
--       "frontend" -> contributes to source/testing.html
--       "meta"     -> neither on its own (modifiers, references)
local defs = {
  -- backend --------------------------------------------------------------
  { name = "WELL",       lexeme = "<well>",      kind = "backend",  doc = "if <expr> then" },
  { name = "ELSE",       lexeme = "<else>",      kind = "backend",  doc = "else" },
  { name = "REVIVE",     lexeme = "<revive>",    kind = "backend",  doc = "while loop" },
  { name = "FOR",        lexeme = "<for>",       kind = "backend",  doc = "numeric/generic for" },
  { name = "DONE",       lexeme = "<done>",      kind = "backend",  doc = "close the open block" },
  { name = "WRITE",      lexeme = "<write>",     kind = "backend",  doc = "io.write" },
  { name = "PRINT",      lexeme = "<print>",     kind = "backend",  doc = "print" },
  { name = "TIME",       lexeme = "<time>",      kind = "backend",  doc = "os.date()" },
  { name = "LOCAL",      lexeme = "<local>",     kind = "backend",  doc = "declare a variable" },
  { name = "STRING",     lexeme = "<string>",    kind = "backend",  doc = "treat payload as text" },
  { name = "GUESS",      lexeme = "<guess>",     kind = "backend",  doc = "math.random" },
  { name = "SLEEP",      lexeme = "<sleep>",     kind = "backend",  doc = "delay" },
  { name = "CREATE",     lexeme = "<create>",    kind = "backend",  doc = "io.open(path,'w')" },
  { name = "STATE",      lexeme = "<state>",     kind = "backend",  doc = "write to the open file" },
  { name = "READ",       lexeme = "<read>",      kind = "backend",  doc = "read the open file" },
  { name = "CLOSE",      lexeme = "<close>",     kind = "backend",  doc = "close the open file" },
  { name = "BASKET",     lexeme = "<basket>",    kind = "backend",  doc = "table constructor" },
  { name = "FUNCTION",   lexeme = "<function>",  kind = "backend",  doc = "declare a function" },
  { name = "LUA",        lexeme = "<lua>",       kind = "backend",  doc = "raw Lua escape hatch" },

  -- frontend -------------------------------------------------------------
  { name = "FILL",       lexeme = "fill:",       kind = "frontend", doc = "body background colour" },
  { name = "XY",         lexeme = "xy:",         kind = "frontend", doc = "transform: scale()" },
  { name = "RGB",        lexeme = "rgb:",        kind = "frontend", doc = "text colour" },
  { name = "POSITION",   lexeme = "position:",   kind = "frontend", doc = "text alignment" },
  { name = "DISPLAYX",   lexeme = "displayx:",   kind = "frontend", doc = "heading, 15px" },
  { name = "DISPLAY",    lexeme = "display:",    kind = "frontend", doc = "heading, 12px" },
  { name = "LINKFRAMEX", lexeme = "linkframex:", kind = "frontend", doc = "full-width iframe" },
  { name = "LINKFRAME",  lexeme = "linkframe:",  kind = "frontend", doc = "15% iframe" },
  { name = "ATTACHX",    lexeme = "attachx:",    kind = "frontend", doc = "image, 240x240" },
  { name = "ATTACHL",    lexeme = "attachl:",    kind = "frontend", doc = "image, 240x420" },
  { name = "ATTACH",     lexeme = "attach:",     kind = "frontend", doc = "image, 70x70" },
  { name = "BRACKET",    lexeme = "bracket:",    kind = "frontend", doc = "open a styled span" },
  { name = "HTML",       lexeme = "html:",       kind = "frontend", doc = "raw HTML escape hatch" },
  { name = "WORLD",      lexeme = "world:",      kind = "frontend", doc = "three.js FBX viewer" },
}

M.defs = defs

-- name -> def
M.by_name = {}
for _, d in ipairs(defs) do M.by_name[d.name] = d end

-- Longest lexeme first, so DISPLAYX: wins over DISPLAY: and LINKFRAMEX: over
-- LINKFRAME:. main.lua relied on hand-written `and not find(...)` guards for
-- this; ordering the table removes the whole class of mistake.
M.ordered = {}
for _, d in ipairs(defs) do M.ordered[#M.ordered + 1] = d end
table.sort(M.ordered, function(a, b)
  if #a.lexeme ~= #b.lexeme then return #a.lexeme > #b.lexeme end
  return a.lexeme < b.lexeme
end)

return M
