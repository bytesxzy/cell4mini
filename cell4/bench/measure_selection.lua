-- How many DISTINCT train-consistent programs does a task actually admit, and would choosing
-- among them differently beat taking the first one found?
--
-- NIGHT-01 listed this as open and unverified. The production search returns the first consistent
-- program; OE dedup keys on the train-output signature, so every later consistent program collapses
-- to the same key and is discarded unseen. This harness exempts that key and collects them all.
package.path = "./?.lua;./?/init.lua;" .. package.path
local src = assert(io.open("cell4.lua", "r")):read("*a")
local cut = src:find("-- ==== run%.lua %(CLI entry%) ====")
assert(load(src:sub(1, cut - 1), "@cell4.lua"))()

local cfg        = require("rsi.config")
local benchmarks = require("rsi.kernel.benchmarks")
local genome     = require("rsi.kernel.genome")
local program    = require("rsi.kernel.program")
local ops        = require("rsi.kernel.ops")
local features   = require("rsi.kernel.features")
local inverses   = require("rsi.kernel.inverses")
local constants  = require("rsi.kernel.constants")

local NODES = tonumber(arg[1]) or 800
local SECS  = tonumber(arg[2]) or 1
local NTASK = tonumber(arg[3]) or 260

local g = genome.load(cfg.root .. "/genome")
local collect = dofile("rsi/genome/search_collect.lua")

local bench  = benchmarks.load(cfg.root)
local splits = benchmarks.build_splits(bench, cfg, "selection-probe")
local list   = splits.heldout
if NTASK < #list then local t = {} for i = 1, NTASK do t[i] = list[i] end list = t end

local hist, tot_first_right, tot_any_right, tot_majority_right, multi = {}, 0, 0, 0, 0
local n_solvable, shortest_right, examples = 0, 0, {}

for _, task in ipairs(list) do
  local ctx = {
    dsl = { prims = g.prims, order = g.order }, policy = g.policy,
    sig = ops.sig, equal = ops.equal, program = program,
    inverses = inverses, constants = constants, features = features.bucket,
    budget = NODES, deadline = os.clock() + SECS,
  }
  local ok = pcall(collect.solve, task, ctx)
  local found = ok and (collect.COLLECT or {}) or {}

  -- distinct by source text
  local seen, progs = {}, {}
  for _, node in ipairs(found) do
    local s = program.to_string(node)
    if not seen[s] then seen[s] = true progs[#progs + 1] = { s = s, node = node } end
  end
  if #progs > 0 then
    n_solvable = n_solvable + 1
    local b = #progs >= 10 and "10+" or tostring(#progs)
    hist[b] = (hist[b] or 0) + 1
    if #progs > 1 then multi = multi + 1 end

    -- which of them actually generalise to the test example?
    local right, votes = {}, {}
    for i, p in ipairs(progs) do
      local okc, f = pcall(program.compile, p.node, g.prims)
      local good = false
      if okc then
        good = true
        for _, ex in ipairs(task.test) do
          local oka, out = pcall(f, ex.input)
          if not oka or not ops.equal(out, ex.output) then good = false break end
        end
      end
      right[i] = good
      -- majority vote over predicted test outputs
      if okc then
        local oka, out = pcall(f, task.test[1].input)
        if oka then local k = ops.sig(out) votes[k] = (votes[k] or 0) + 1 end
      end
    end
    if right[1] then tot_first_right = tot_first_right + 1 end
    local any = false
    for _, r in ipairs(right) do if r then any = true break end end
    if any then tot_any_right = tot_any_right + 1 end

    -- shortest-program rule
    local bi, bs = 1, math.huge
    for i, p in ipairs(progs) do local sz = program.size(p.node) if sz < bs then bi, bs = i, sz end end
    if right[bi] then shortest_right = shortest_right + 1 end

    -- majority rule: most-voted predicted output, does it equal the true test output?
    local bestk, bestc = nil, -1
    for k, c in pairs(votes) do if c > bestc then bestk, bestc = k, c end end
    if bestk and bestk == ops.sig(task.test[1].output) then tot_majority_right = tot_majority_right + 1 end

    if #progs > 1 and not right[1] and any and #examples < 8 then
      examples[#examples + 1] = string.format("%s: first=%s (WRONG), %d consistent programs, a right one exists",
        task.id, progs[1].s, #progs)
    end
  end
end

print(string.format("held-out tasks probed        : %d   (nodes=%d seconds=%s)", #list, NODES, tostring(SECS)))
print(string.format("tasks with >=1 consistent prog: %d", n_solvable))
print(string.format("tasks with >=2 (choice exists): %d  (%.1f%% of solvable)", multi, 100*multi/math.max(n_solvable,1)))
print("")
print("distribution of distinct consistent programs per task:")
local keys = {} for k in pairs(hist) do keys[#keys+1] = k end
table.sort(keys, function(a,b) return (tonumber(a) or 99) < (tonumber(b) or 99) end)
for _, k in ipairs(keys) do print(string.format("  %-4s programs : %d tasks", k, hist[k])) end
print("")
print("SELECTION RULES compared, on tasks where the search found any consistent program:")
print(string.format("  first-found (what production does) : %d correct", tot_first_right))
print(string.format("  shortest program                   : %d correct", shortest_right))
print(string.format("  majority vote on predicted output  : %d correct", tot_majority_right))
print(string.format("  an oracle picking the best one     : %d correct  <- ceiling for ANY selection rule", tot_any_right))
print("")
for _, e in ipairs(examples) do print("  " .. e) end
