--[[ spec/test_regression.lua

Each case below was first run through the original source/main.lua under
Lua 5.4 and its wrong output recorded. The assertions pin the corrected
behaviour so these cannot come back.
]]

local cell4 = require("cell4")
local A = assert_that

local function compile(text)
  local r = cell4.compile(text)
  A.truthy(r.ok, "expected a clean compile, got:\n" .. r.diagnostics:format())
  return r
end

local function count(haystack, needle)
  local n, at = 0, 1
  while true do
    local found = haystack:find(needle, at, true)
    if not found then return n end
    n = n + 1
    at = found + #needle
  end
end

return {

  -- main.lua emitted, for this single input line:
  --     local ___1 = [[  hello world]]
  --     ___1 =[[  hello world]]
  -- Two statements for one declaration, both with the trim skipped.
  ["a declaration emits once, trimmed"] = function()
    local code = compile("<LOCAL> <STRING> hello world").lua
    A.equal(count(code, "___1"), 1, "declaration emitted more than once:\n" .. code)
    A.contains(code, '"hello world"')
    A.omits(code, "  hello world")
  end,

  -- main.lua produced:
  --     while true do
  --     while true do
  --     print('loop one body')
  --     end
  --     print('loop two body')
  --     end
  ["two loops do not nest"] = function()
    local code = compile(table.concat({
      "<REVIVE>", "<PRINT> loop one body", "<DONE>",
      "<REVIVE>", "<PRINT> loop two body", "<DONE>",
    }, "\n")).lua

    A.parses(code)
    A.equal(count(code, "while true do"), 2)
    A.equal(count(code, "end"), 2)

    local one = code:find("loop one body", 1, true)
    local two = code:find("loop two body", 1, true)
    local between = code:sub(one, two)
    A.contains(between, "end", "the first loop must close before the second body")
  end,

  -- main.lua produced an if with both branches inside it and no else at all:
  --     if  1 == 2 then
  --     print('yes')
  --     print('no')
  --     end
  ["else is not swallowed into the then-branch"] = function()
    local code = compile(table.concat({
      "<WELL> 1 == 2", "<PRINT> yes", "<ELSE>", "<PRINT> no", "<DONE>",
    }, "\n")).lua

    A.parses(code)
    A.contains(code, "else")

    local yes = code:find("yes", 1, true)
    local no = code:find("no", 1, true)
    A.contains(code:sub(yes, no), "else",
      "the else must separate the two branches:\n" .. code)

    -- and it must actually behave: 1 == 2 is false, so only "no" runs
    local loader = load or loadstring
    local captured = {}
    local chunk = loader(code:gsub("print%(", "__capture("))
    local env = { __capture = function(v) captured[#captured + 1] = v end, os = os, io = io, math = math }
    if setfenv then setfenv(chunk, env) else
      chunk = loader("local __capture = ... " .. code:gsub("print%(", "__capture("))
    end
    chunk(env.__capture)
    A.equal(#captured, 1, "exactly one branch should run")
    A.equal(captured[1], "no")
  end,

  -- main.lua produced:
  --   ...<body></body></html>text-align:center;'><body style='background-color:#000000 POSITION: center;'>
  ["frontend output lands inside the document, in order"] = function()
    local html = compile("FILL: #000000 POSITION: center").html

    A.equal(count(html, "</html>"), 1)
    A.omits(html, "POSITION:")
    A.omits(html, "text-align:center;'>")

    local body_open = html:find("<body", 1, true)
    local body_close = html:find("</body>", 1, true)
    A.truthy(body_open < body_close, "body tags out of order:\n" .. html)

    local tail = html:sub(html:find("</html>", 1, true) + #"</html>")
    A.equal((tail:gsub("%s", "")), "", "content after </html>:\n" .. html)
  end,

  ["the compiler never executes what it generated"] = function()
    -- main.lua ended with os.execute("luajit source/execute.lua"), so a
    -- mis-parse ran itself. compile() is pure; running is cell4c's --run flag.
    local marker = os.tmpname()
    os.remove(marker)
    compile('<LUA> io.open("' .. marker .. '", "w"):close()')
    local f = io.open(marker, "r")
    A.falsy(f, "compiling must not run the generated program")
    if f then f:close(); os.remove(marker) end
  end,
}
