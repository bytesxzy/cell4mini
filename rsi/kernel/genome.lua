-- Genome = a directory of mutable source: dsl_base.lua, library.lua, policy.lua, search.lua
-- The kernel loads it, enforces the visibility boundary (hidden ops are refused), and can save it.
local ops = require("rsi.kernel.ops")
local program = require("rsi.kernel.program")
local serialize = require("rsi.kernel.serialize")
local M = {}

local function loadfile_strict(path)
  local chunk, err = loadfile(path)
  if not chunk then error("genome load error: " .. tostring(err)) end
  return chunk()
end

function M.load(dir)
  local base = loadfile_strict(dir .. "/dsl_base.lua")
  local lib = loadfile_strict(dir .. "/library.lua")
  local policy = loadfile_strict(dir .. "/policy.lua")
  local search = loadfile_strict(dir .. "/search.lua")
  local prims, order = {}, {}
  for _, name in ipairs(base.ops) do
    local o = ops.catalogue[name]
    if o and not o.hidden and not prims[name] then
      prims[name] = { f = o.f, t = o.t, r = o.r, name = name }
      order[#order + 1] = name
    end
  end
  local lib_ok = {}
  for _, e in ipairs(lib) do
    local ok, err = pcall(function()
      local node = program.parse(e.expr)
      local f = program.compile(node, prims)
      local types = e.arg2 and { e.arg, e.arg2 } or { e.arg }
      prims[e.name] = { f = f, t = types, r = e.ret, learned = true, expr = e.expr, name = e.name, bucket = e.bucket }
      order[#order + 1] = e.name
      lib_ok[#lib_ok + 1] = e
    end)
    if not ok then io.stderr:write("library entry skipped: " .. tostring(e.name) .. " " .. tostring(err) .. "\n") end
  end
  return {
    dir = dir, prims = prims, order = order, policy = policy, solve = search.solve,
    base = base, lib = lib_ok,
    search_src = (function() local f = io.open(dir .. "/search.lua", "r") local s = f:read("*a") f:close() return s end)(),
  }
end

function M.save(g, dir)
  os.execute("mkdir -p '" .. dir .. "'")
  serialize.write(dir .. "/dsl_base.lua", g.base, "visible primitive selection (mutable)")
  serialize.write(dir .. "/library.lua", g.lib, "learned abstractions (mutable, grown by library learning)")
  serialize.write(dir .. "/policy.lua", g.policy, "search policy: costs, constants, budgets, strategy (mutable)")
  local f = assert(io.open(dir .. "/search.lua", "w"))
  f:write(g.search_src)
  f:close()
end

-- A deep copy of the data parts (search_src is a string, shared by value)
function M.clone(g)
  local function deep(v)
    if type(v) ~= "table" then return v end
    local o = {}
    for k, x in pairs(v) do o[k] = deep(x) end
    return o
  end
  return { base = deep(g.base), lib = deep(g.lib), policy = deep(g.policy), search_src = g.search_src }
end

-- Content fingerprint for lineage
function M.fingerprint(g)
  local s = serialize.to_lua(g.base) .. serialize.to_lua(g.lib) .. serialize.to_lua(g.policy) .. g.search_src
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
  return string.format("%08x", h)
end

return M
