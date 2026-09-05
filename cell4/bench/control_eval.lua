-- Control: the UNMODIFIED solver on the exact same split the selection probe used.
-- If the harness is faithful, solved here == "first-found correct" there.
package.path = "./?.lua;./?/init.lua;" .. package.path
local src = assert(io.open("cell4.lua", "r")):read("*a")
local cut = src:find("-- ==== run%.lua %(CLI entry%) ====")
assert(load(src:sub(1, cut - 1), "@cell4.lua"))()
local cfg = require("rsi.config")
local benchmarks = require("rsi.kernel.benchmarks")
local genome = require("rsi.kernel.genome")
local evaluate = require("rsi.kernel.evaluate")
local bench = benchmarks.load(cfg.root)
local splits = benchmarks.build_splits(bench, cfg, "selection-probe")
local list = splits.heldout
local NT = tonumber(arg[3]) or 260
if NT < #list then local t={} for i=1,NT do t[i]=list[i] end list=t end
local r = evaluate.run(genome.load(cfg.root .. "/genome"), list,
  { nodes = tonumber(arg[1]) or 800, seconds = tonumber(arg[2]) or 1 })
print(string.format("UNMODIFIED solver, same split: solved %d / %d", r.solved, r.n))
