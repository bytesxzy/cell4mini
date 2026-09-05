-- How often does the solver return a program that fits every training example but fails the
-- held-out test example?
--
-- The search returns the FIRST train-consistent program it finds and never considers alternatives
-- (rsi/genome/search.lua: `if s then return { program = s, ... }`). Observational-equivalence dedup
-- keys on the train-output signature, and every train-consistent program shares that signature, so
-- alternatives are structurally invisible. Each task counted here is one where the search HAD a
-- correct program within reach of its own definition of "consistent" and picked a wrong one.
--
-- Usage: luajit measure_overfit.lua [split] [n] [nodes] [seconds]
--        split = heldout | train | adversarial | arc
package.path = "./?.lua;./?/init.lua;" .. package.path
local src = assert(io.open("cell4.lua", "r")):read("*a")
local cut = src:find("-- ==== run%.lua %(CLI entry%) ====")
assert(load(src:sub(1, cut - 1), "@cell4.lua"))()

local cfg        = require("rsi.config")
local benchmarks = require("rsi.kernel.benchmarks")
local genome     = require("rsi.kernel.genome")
local evaluate   = require("rsi.kernel.evaluate")

local SPLIT = arg[1] or "heldout"
local N     = tonumber(arg[2]) or 0
local NODES = tonumber(arg[3]) or 800
local SECS  = tonumber(arg[4]) or 1

local list
if SPLIT == "arc" then
  list = benchmarks.load_external(cfg.root, N > 0 and N or 10000, nil)
else
  local bench = benchmarks.load(cfg.root)
  local splits = benchmarks.build_splits(bench, cfg, "overfit-probe")
  list = splits[SPLIT]
  if N > 0 then
    local t = {}
    for i = 1, math.min(N, #list) do t[i] = list[i] end
    list = t
  end
end

local g = genome.load(cfg.root .. "/genome")
local r = evaluate.run(g, list, { nodes = NODES, seconds = SECS })

local overfit, none, examples = 0, 0, {}
for _, x in ipairs(r.per_task) do
  if x.solved == 0 then
    if x.overfit_train then
      overfit = overfit + 1
      if #examples < 12 then examples[#examples + 1] = x.id .. "  picked: " .. tostring(x.program_rejected) end
    else
      none = none + 1
    end
  end
end

print(string.format("split=%s n=%d nodes=%d seconds=%s", SPLIT, r.n, NODES, tostring(SECS)))
print(string.format("  solved                     %4d  (%.1f%%)", r.solved, 100 * r.solved / math.max(r.n, 1)))
print(string.format("  train-consistent but WRONG %4d  (%.1f%% of all tasks, %.1f%% of failures)",
  overfit, 100 * overfit / math.max(r.n, 1), 100 * overfit / math.max(r.n - r.solved, 1)))
print(string.format("  no program found at all    %4d  (%.1f%%)", none, 100 * none / math.max(r.n, 1)))
print("")
print("  a task in the middle row is one where the search satisfied its own consistency test and")
print("  still got the answer wrong -- the ceiling for any better choice among consistent programs.")
for _, e in ipairs(examples) do print("    " .. e) end
