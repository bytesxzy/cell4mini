local cell4 = require("cell4")
local A = assert_that

local function compile(text)
  return cell4.compile(text)
end

local function lua_of(text)
  local r = compile(text)
  A.truthy(r.ok, "expected a clean compile, got:\n" .. r.diagnostics:format())
  return r.lua
end

return {

  ["generated code parses as Lua"] = function()
    A.parses(lua_of(table.concat({
      "<LOCAL> <STRING> hello",
      "<PRINT> starting up",
      "<PRINT> <TIME>",
      "<LOCAL> <GUESS> 1,10",
      "<PRINT> 2 + 3",
      "<WELL> 1 == 1",
      "<PRINT> inside",
      "<ELSE>",
      "<PRINT> outside",
      "<DONE>",
    }, "\n")))
  end,

  ["sequential loops emit as siblings"] = function()
    local code = lua_of("<REVIVE>\n<PRINT> one\n<DONE>\n<REVIVE>\n<PRINT> two\n<DONE>")
    A.parses(code)
    -- The old output nested them, which put "two" inside the first loop.
    local first_end = code:find("end", 1, true)
    local second_while = code:find("while", code:find("while", 1, true) + 1, true)
    A.truthy(first_end < second_while,
      "the first loop must close before the second opens:\n" .. code)
  end,

  ["else reaches the output"] = function()
    local code = lua_of("<WELL> 1 == 2\n<PRINT> yes\n<ELSE>\n<PRINT> no\n<DONE>")
    A.parses(code)
    A.contains(code, "else")
    A.contains(code, 'print("yes")')
    A.contains(code, 'print("no")')
  end,

  ["text with quotes and brackets stays a valid literal"] = function()
    -- main.lua wrapped payloads in [[ ]] and single quotes, so a payload
    -- containing either produced code that would not load.
    A.parses(lua_of("<PRINT> it's a ]] bracket \"quote\""))
    A.parses(lua_of("<LOCAL> <STRING> it's a ]] bracket"))
  end,

  ["numbers are emitted as numbers and prose as strings"] = function()
    local code = lua_of("<LOCAL> 42")
    A.contains(code, "= 42")

    local text = lua_of("<LOCAL> forty two")
    A.contains(text, '= "forty two"')
  end,

  ["arithmetic is not quoted, prose is"] = function()
    local code = lua_of("<PRINT> 2 + 3")
    A.contains(code, "print(2 + 3)")

    local prose = lua_of("<PRINT> well-known problem")
    A.contains(prose, 'print("well-known problem")')
    A.parses(prose)
  end,

  ["sleep must be numeric"] = function()
    local bad = compile("<SLEEP> ; rm -rf /")
    A.falsy(bad.ok, "a non-numeric delay must not compile")
    A.contains(bad.diagnostics:format(), "needs a number")

    local good = lua_of("<SLEEP> 2")
    A.contains(good, 'os.execute("sleep 2")')
  end,

  ["random bounds must be numeric"] = function()
    local bad = compile("<LOCAL> <GUESS> os.exit()")
    A.falsy(bad.ok)
    A.contains(bad.diagnostics:format(), "numeric bounds")
  end,

  ["file handles are opened once and reused"] = function()
    local code = lua_of(table.concat({
      "<CREATE> out.txt",
      "<STATE> hello",
      "<CLOSE>",
    }, "\n"))
    A.parses(code)
    A.contains(code, 'assert(io.open("out.txt", "w"))')
    A.contains(code, ":write(")
    A.contains(code, ":close()")
  end,

  ["the raw escape hatch passes through untouched"] = function()
    local code = lua_of("<LUA> local t = {1, 2, 3}")
    A.contains(code, "local t = {1, 2, 3}")
    A.parses(code)
  end,

  ["a function opens a block that DONE closes"] = function()
    -- main.lua opened `local function ___n(` and never wrote the matching end.
    A.parses(lua_of("<LOCAL> <FUNCTION>\n<PRINT> inside\n<DONE>"))
  end,

  ["generated code avoids syntax newer than 5.1"] = function()
    local code = lua_of("<PRINT> hi\n<LOCAL> 3\n<REVIVE>\n<PRINT> x\n<DONE>")
    A.omits(code, "goto ")
    A.omits(code, "//")
  end,
}
