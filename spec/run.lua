#!/usr/bin/env lua
--[[ spec/run.lua -- no-dependency test runner.

  lua spec/run.lua            run every spec
  lua spec/run.lua parser     run specs whose file name contains "parser"

Each spec file returns `{ ["name of the case"] = function() ... end, ... }`.
]]

local script = arg and arg[0] or "spec/run.lua"
local here = script:match("^(.*)[/\\][^/\\]*$") or "."
local root = here:match("^(.*)[/\\][^/\\]*$") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local FILES = {
  "spec.test_lexer",
  "spec.test_resolver",
  "spec.test_parser",
  "spec.test_emit_lua",
  "spec.test_emit_html",
  "spec.test_regression",
}

-- ---------------------------------------------------------------------------
-- assertions
-- ---------------------------------------------------------------------------

local A = {}

local function fail(message, level)
  error(message, (level or 2) + 1)
end

function A.equal(actual, expected, note)
  if actual ~= expected then
    fail(string.format("%sexpected %s, got %s",
      note and (note .. ": ") or "",
      string.format("%q", tostring(expected)),
      string.format("%q", tostring(actual))))
  end
end

function A.truthy(value, note)
  if not value then fail((note or "expected a truthy value") .. " (got " .. tostring(value) .. ")") end
end

function A.falsy(value, note)
  if value then fail((note or "expected a falsy value") .. " (got " .. tostring(value) .. ")") end
end

function A.contains(haystack, needle, note)
  if not string.find(haystack, needle, 1, true) then
    fail(string.format("%sexpected to find %q in:\n%s",
      note and (note .. ": ") or "", needle, haystack))
  end
end

function A.omits(haystack, needle, note)
  if string.find(haystack, needle, 1, true) then
    fail(string.format("%sexpected NOT to find %q in:\n%s",
      note and (note .. ": ") or "", needle, haystack))
  end
end

--- Generated Lua must at minimum parse.
function A.parses(code, note)
  local loader = load or loadstring
  local chunk, err = loader(code, "generated")
  if not chunk then
    fail(string.format("%sgenerated code does not parse: %s\n---\n%s\n---",
      note and (note .. ": ") or "", tostring(err), code))
  end
end

_G.assert_that = A

-- ---------------------------------------------------------------------------
-- runner
-- ---------------------------------------------------------------------------

local filter = arg and arg[1]
local passed, failed = 0, 0
local failures = {}

for _, module_name in ipairs(FILES) do
  if not filter or module_name:find(filter, 1, true) then
    local cases = require(module_name)

    local names = {}
    for name in pairs(cases) do names[#names + 1] = name end
    table.sort(names)

    for _, name in ipairs(names) do
      local ok, err = pcall(cases[name])
      if ok then
        passed = passed + 1
      else
        failed = failed + 1
        failures[#failures + 1] = { module_name, name, tostring(err) }
      end
    end
  end
end

if #failures > 0 then
  print("")
  for _, f in ipairs(failures) do
    print(string.format("FAIL  %s :: %s\n      %s\n", f[1], f[2], (f[3]:gsub("\n", "\n      "))))
  end
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
