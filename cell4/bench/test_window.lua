-- Score the champion through the rotating window at the production cap, for N generations,
-- and compare against the old fixed-prefix window. Uses the production budget from run-once.sh.
package.path = "./?.lua;./?/init.lua;" .. package.path
local src = assert(io.open("cell4.lua", "r")):read("*a")
local cut = src:find("-- ==== run%.lua %(CLI entry%) ====")
assert(load(src:sub(1, cut - 1), "@cell4.lua"))()

local cfg        = require("rsi.config")
local benchmarks = require("rsi.kernel.benchmarks")
local genome     = require("rsi.kernel.genome")
local evaluate   = require("rsi.kernel.evaluate")

local CAP   = tonumber(arg[1]) or 20
local GENS  = tonumber(arg[2]) or 8
local NODES = tonumber(arg[3]) or 800     -- production CELL4_NODES
local SECS  = tonumber(arg[4]) or 1       -- production CELL4_SECONDS

local g = genome.load(cfg.root .. "/genome")
local opts = { nodes = NODES, seconds = SECS }

-- old behaviour: fixed sorted prefix (seed = nil)
local fixed = benchmarks.load_external(cfg.root, CAP, nil)
local rf = evaluate.run(g, fixed, opts)
print(string.format("FIXED  prefix window   cap=%d  solved %d/%d  digest %s",
  CAP, rf.solved, rf.n, benchmarks.external_digest(fixed)))

local union, total = {}, 0
for gen = 1, GENS do
  local ext = benchmarks.load_external(cfg.root, CAP, gen)
  local r = evaluate.run(g, ext, opts)
  total = total + r.solved
  local names = {}
  for _, x in ipairs(r.per_task) do
    if x.solved == 1 then union[x.id] = true names[#names + 1] = x.id:gsub("^arc:", "") end
  end
  local n = 0 for _ in pairs(union) do n = n + 1 end
  print(string.format("gen %2d rotating window cap=%d  solved %2d/%d  cumulative distinct %2d  %s",
    gen, CAP, r.solved, r.n, n, table.concat(names, " ")))
end
local n = 0 for _ in pairs(union) do n = n + 1 end
print(string.format("TOTALS over %d generations: %d solve-events, %d distinct ARC tasks discovered",
  GENS, total, n))
