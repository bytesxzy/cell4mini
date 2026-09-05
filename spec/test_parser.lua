local Parser = require("cell4.parser")
local Diagnostics = require("cell4.diagnostics")
local A = assert_that

local function parse(text)
  local d = Diagnostics.new()
  return Parser.parse(text, d), d
end

return {

  -- THE regression. Verified against main.lua before this was written: two
  -- sequential loops came out nested, with the second body inside the first.
  ["sequential blocks stay siblings"] = function()
    local program = parse(table.concat({
      "<REVIVE>", "<PRINT> one", "<DONE>",
      "<REVIVE>", "<PRINT> two", "<DONE>",
    }, "\n"))

    A.equal(#program.body, 2, "expected two top-level loops")
    A.equal(program.body[1].op, "while_true")
    A.equal(program.body[2].op, "while_true")
    A.equal(#program.body[1].body, 1, "first loop should hold exactly its own body")
    A.equal(#program.body[2].body, 1, "second loop should hold exactly its own body")
    A.equal(program.body[1].body[1].text, "one")
    A.equal(program.body[2].body[1].text, "two")
  end,

  ["nested blocks nest"] = function()
    local program = parse(table.concat({
      "<REVIVE>", "<WELL> x == 1", "<PRINT> deep", "<DONE>", "<DONE>",
    }, "\n"))

    A.equal(#program.body, 1)
    A.equal(program.body[1].op, "while_true")
    A.equal(program.body[1].body[1].op, "if_stmt")
    A.equal(program.body[1].body[1].body[1].text, "deep")
  end,

  -- <ELSE> was declared in main.lua, stripped by every gsub chain, and never
  -- emitted, so both branches ran as one.
  ["else splits the branch"] = function()
    local program = parse(table.concat({
      "<WELL> 1 == 2", "<PRINT> yes", "<ELSE>", "<PRINT> no", "<DONE>",
    }, "\n"))

    local iff = program.body[1]
    A.equal(iff.op, "if_stmt")
    A.equal(#iff.body, 1, "then-branch should hold one statement")
    A.equal(iff.body[1].text, "yes")
    A.truthy(iff.orelse, "expected an else-branch")
    A.equal(#iff.orelse, 1)
    A.equal(iff.orelse[1].text, "no")
  end,

  ["an unclosed block is an error naming its opening line"] = function()
    local _, d = parse("<REVIVE>\n<PRINT> forever")
    A.truthy(d:has_errors(), "expected an error for the unclosed block")
    A.contains(d:format(), "never closed")
    A.contains(d:format(), "line 1")
  end,

  ["a stray DONE is an error"] = function()
    local _, d = parse("<PRINT> hi\n<DONE>")
    A.truthy(d:has_errors())
    A.contains(d:format(), "no open block")
  end,

  ["else outside an if is an error"] = function()
    local _, d = parse("<ELSE>")
    A.truthy(d:has_errors())
    A.contains(d:format(), "outside")
  end,

  ["two elses in one block is an error"] = function()
    local _, d = parse("<WELL> x\n<ELSE>\n<ELSE>\n<DONE>")
    A.truthy(d:has_errors())
    A.contains(d:format(), "second <ELSE>")
  end,

  -- main.lua named variables after their line number (RFLevel incremented once
  -- per line), so `___4` on line 4 could not be referred to predictably.
  ["slots are allocated in declaration order"] = function()
    local program = parse(table.concat({
      "<LOCAL> <STRING> first",
      "",
      "<PRINT> noise",
      "<LOCAL> <STRING> second",
    }, "\n"))

    A.equal(program.body[1].slot, 1)
    A.equal(program.body[3].slot, 2, "second declaration should be slot 2, not line 4")
  end,

  ["writing to a file before opening one is an error"] = function()
    local _, d = parse("<STATE> hello")
    A.truthy(d:has_errors())
    A.contains(d:format(), "no file is open")
  end,

  ["a reference to an undeclared variable is reported"] = function()
    local _, d = parse("<PRINT> ___7")
    A.contains(d:format(), "___7 is not declared")
  end,

  ["frontend nodes collect in source order"] = function()
    local program = parse(table.concat({
      "FILL: #000000",
      "DISPLAY: one",
      "DISPLAYX: two",
    }, "\n"))

    A.equal(#program.document, 3)
    A.equal(program.document[1].op, "fe_fill")
    A.equal(program.document[2].text, "one")
    A.equal(program.document[3].text, "two")
  end,
}
