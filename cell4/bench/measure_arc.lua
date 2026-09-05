-- Measure the champion genome against the full local ARC corpus.
-- Loads cell4.lua for its package.preload registrations without running its CLI.
package.path = "./?.lua;./?/init.lua;" .. package.path

local CAP     = tonumber(arg[1]) or 10000
local NODES   = tonumber(arg[2])
local SECONDS = tonumber(arg[3])

-- cell4.lua is: do <preload registrations> end  ..  <CLI entry>.
-- Read it and execute only up to the CLI marker, so requires resolve but no command runs.
local src = assert(io.open("cell4.lua", "r")):read("*a")
local cut = src:find("-- ==== run%.lua %(CLI entry%) ====")
assert(cut, "CLI marker not found in cell4.lua")
assert(load(src:sub(1, cut - 1), "@cell4.lua"))()

local cfg        = require("rsi.config")
local benchmarks = require("rsi.kernel.benchmarks")
local genome     = require("rsi.kernel.genome")
local evaluate   = require("rsi.kernel.evaluate")

local nodes   = NODES   or cfg.external_nodes
local seconds = SECONDS or cfg.external_seconds

local ext = benchmarks.load_external(cfg.root, CAP)
io.write(string.format("loaded %d ARC tasks (nodes=%d seconds=%s)\n", #ext, nodes, tostring(seconds)))

local g = genome.load(cfg.root .. "/genome")
local t0 = os.clock()
local r = evaluate.run(g, ext, { nodes = nodes, seconds = seconds })
local dt = os.clock() - t0

for _, x in ipairs(r.per_task) do
  if x.solved == 1 then print("SOLVED " .. x.id .. "  ->  " .. tostring(x.program)) end
end
print(string.format("RESULT solved=%d n=%d pct=%.2f partial=%.4f nodes_mean=%.0f cpu=%.1fs",
  r.solved, r.n, 100 * r.solved / math.max(r.n, 1), r.partial_mean, r.nodes_mean, dt))
