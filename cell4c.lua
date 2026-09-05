#!/usr/bin/env lua
--[[ cell4c -- compile a CELL source file.

  lua cell4c.lua                        compile ./CELL2
  lua cell4c.lua path/to/src            compile that file
  lua cell4c.lua --check                report diagnostics, write nothing
  lua cell4c.lua --explain '<PRINT> hi' show how one line is understood
  lua cell4c.lua --run                  compile, then run the generated Lua

--run is opt-in on purpose. main.lua ended with an unconditional
`os.execute("luajit source/execute.lua")`, so any compile -- including one that
had just mis-parsed the file -- immediately executed its own output.
]]

-- Resolve modules relative to this script rather than the shell's cwd.
local script = arg and arg[0] or "cell4c.lua"
local here = script:match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. here .. "/?/init.lua;" .. package.path

local cell4 = require("cell4")

local DEFAULT_INPUT = "CELL2"
local DEFAULT_LUA = "source/execute.lua"
local DEFAULT_HTML = "source/testing.html"

local function read_file(path)
  local handle, err = io.open(path, "r")
  if not handle then return nil, err end
  local text = handle:read("*a")
  handle:close()
  return text
end

local function write_file(path, text)
  local handle, err = io.open(path, "w")
  if not handle then return nil, err end
  handle:write(text)
  handle:close()
  return true
end

local function fail(message)
  io.stderr:write("cell4c: " .. message .. "\n")
  os.exit(1)
end

local function parse_args(argv)
  local opts = { input = nil, run = false, check = false, explain = nil,
                 lua_out = DEFAULT_LUA, html_out = DEFAULT_HTML, quiet = false }
  local i = 1
  while argv[i] do
    local a = argv[i]
    if a == "--run" then opts.run = true
    elseif a == "--check" then opts.check = true
    elseif a == "--quiet" then opts.quiet = true
    elseif a == "--explain" then
      i = i + 1
      opts.explain = argv[i] or fail("--explain needs a line")
    elseif a == "--lua-out" then
      i = i + 1
      opts.lua_out = argv[i] or fail("--lua-out needs a path")
    elseif a == "--html-out" then
      i = i + 1
      opts.html_out = argv[i] or fail("--html-out needs a path")
    elseif a == "--help" or a == "-h" then
      print((io.open(script):read("*a"):match("%-%-%[%[(.-)%]%]")))
      os.exit(0)
    elseif a:sub(1, 2) == "--" then
      fail("unknown option " .. a)
    else
      opts.input = a
    end
    i = i + 1
  end
  return opts
end

local opts = parse_args(arg or {})

-- --explain: show the ranking for one line and stop.
if opts.explain then
  local report = cell4.explain(opts.explain)
  print("tokens:     " .. (#report.tokens > 0 and table.concat(report.tokens, "  ") or "(none)"))
  if not report.winner then
    print("winner:     (no rule applies)")
    os.exit(1)
  end
  print(string.format("winner:     %s (confidence %.2f)", report.winner, report.confidence))
  print("candidates:")
  for _, c in ipairs(report.candidates) do
    print(string.format("  %-18s %3d", c.id, c.score))
  end
  os.exit(0)
end

local input = opts.input or DEFAULT_INPUT
local text, read_err = read_file(input)
if not text then
  fail("cannot read " .. input .. ": " .. tostring(read_err))
end

local result = cell4.compile(text)

local report = result.diagnostics:format()
if report ~= "" then
  io.stderr:write(report .. "\n")
end

if not result.ok then
  fail(string.format("%d error(s); nothing written",
    result.diagnostics:count("error")))
end

if opts.check then
  if not opts.quiet then
    print(string.format("ok: %d lines, %d statements, %d warning(s)",
      result.stats.lines, result.stats.resolved,
      result.diagnostics:count("warning")))
  end
  os.exit(0)
end

local ok_lua, lua_err = write_file(opts.lua_out, result.lua)
if not ok_lua then fail("cannot write " .. opts.lua_out .. ": " .. tostring(lua_err)) end

local ok_html, html_err = write_file(opts.html_out, result.html)
if not ok_html then fail("cannot write " .. opts.html_out .. ": " .. tostring(html_err)) end

if not opts.quiet then
  print(string.format("%s -> %s, %s  (%d statements, %d warning(s))",
    input, opts.lua_out, opts.html_out,
    result.stats.resolved, result.diagnostics:count("warning")))
end

if opts.run then
  local interpreter = os.getenv("CELL4_LUA") or "luajit"
  os.execute(interpreter .. " " .. opts.lua_out)
end
