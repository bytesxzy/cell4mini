-- Is the "selection" lever real?
--
-- measure_overfit.lua finds tasks where the solver returned a program consistent with every
-- training example that then failed the test example. The search cannot see the alternatives
-- (OE dedup collapses every train-consistent program onto one key, and the first found is
-- returned), so the question is whether a correct sibling was in reach at all.
--
-- This probes that WITHOUT modifying the genome: re-solve each such task several times with the
-- op-cost table jittered, which is exactly what a mutation operator does. A different cost order
-- surfaces a different member of the consistent set. If some restart returns a program that also
-- satisfies the test example, the correct program was reachable and only the choice was wrong --
-- which is the upside a real selection rule could capture.
--
-- Usage: luajit probe_selection.lua [restarts] [nodes] [seconds]
package.path = "./?.lua;./?/init.lua;" .. package.path
local src = assert(io.open("cell4.lua", "r")):read("*a")
local cut = src:find("-- ==== run%.lua %(CLI entry%) ====")
assert(load(src:sub(1, cut - 1), "@cell4.lua"))()

local cfg        = require("rsi.config")
local benchmarks = require("rsi.kernel.benchmarks")
local genome     = require("rsi.kernel.genome")
local evaluate   = require("rsi.kernel.evaluate")
local program    = require("rsi.kernel.program")
local ops        = require("rsi.kernel.ops")
local tasks      = require("rsi.kernel.tasks")
local features   = require("rsi.kernel.features")
local inverses   = require("rsi.kernel.inverses")
local constants  = require("rsi.kernel.constants")
local sandbox    = require("rsi.kernel.sandbox")
local RNG        = require("rsi.kernel.rng")

local RESTARTS = tonumber(arg[1]) or 8
local NODES    = tonumber(arg[2]) or 800
local SECS     = tonumber(arg[3]) or 1

local g = genome.load(cfg.root .. "/genome")
local bench = benchmarks.load(cfg.root)
local splits = benchmarks.build_splits(bench, cfg, "overfit-probe")

-- baseline pass: find the tasks the solver got wrong despite a train-consistent program
local base = evaluate.run(g, splits.heldout, { nodes = NODES, seconds = SECS })
local targets = {}
for i, r in ipairs(base.per_task) do
  if r.solved == 0 and r.overfit_train then targets[#targets + 1] = { task = splits.heldout[i], r = r } end
end
print(string.format("held-out %d tasks: %d solved, %d train-consistent-but-wrong",
  base.n, base.solved, #targets))
print(string.format("probing those %d with %d cost-jittered restarts each\n", #targets, RESTARTS))

local function verify(node, examples)
  local ok, f = pcall(program.compile, node, g.prims)
  if not ok then return false end
  for _, ex in ipairs(examples) do
    local ok2, out = pcall(f, ex.input)
    if not ok2 or not ops.equal(out, ex.output) then return false end
  end
  return true
end

local function solve_with(task, policy)
  local view = tasks.solver_view(task)
  local ctx = { dsl = { prims = g.prims, order = g.order }, policy = policy,
    budget = NODES, deadline = os.clock() + SECS, sig = ops.sig, equal = ops.equal,
    program = program, features = features.bucket, inverses = inverses, constants = constants }
  local ok, res = sandbox.run(60000000, g.solve, view, ctx)
  if ok and type(res) == "table" and res.program then return res.program end
  return nil
end

local recoverable, votes_right, votes_wrong = 0, 0, 0
for _, t in ipairs(targets) do
  local found, correct, order = {}, nil, {}
  for k = 1, RESTARTS do
    local rng = RNG.new(t.task.id .. ":" .. k)
    local p = {}
    for key, v in pairs(g.policy) do p[key] = v end
    p.cost = {}
    for _, name in ipairs(g.order) do
      local c = g.policy.cost[name] or g.policy.default_cost
      p.cost[name] = math.max(1, c + rng:int(-1, 1))
    end
    local node = solve_with(t.task, p)
    if node then
      local s = program.to_string(node)
      if not found[s] then
        found[s] = { n = 0, ok = verify(node, t.task.train) and verify(node, t.task.test) }
        order[#order + 1] = s
      end
      found[s].n = found[s].n + 1
      if found[s].ok and not correct then correct = s end
    end
  end
  -- plurality vote across restarts, ties broken by first-seen
  local best, bn = nil, -1
  for _, s in ipairs(order) do if found[s].n > bn then best, bn = s, found[s].n end end
  if correct then recoverable = recoverable + 1 end
  if best and found[best].ok then votes_right = votes_right + 1 elseif best then votes_wrong = votes_wrong + 1 end
  print(string.format("  %-18s %d distinct program(s); correct sibling reachable: %-3s  plurality pick: %s",
    t.task.id, #order, correct and "YES" or "no", best and (found[best].ok and "CORRECT" or "wrong") or "none"))
end

print("")
print(string.format("of %d wrongly-chosen tasks, a CORRECT program was reachable in %d (%.0f%%)",
  #targets, recoverable, 100 * recoverable / math.max(#targets, 1)))
print(string.format("plurality vote across restarts would have been right on %d, wrong on %d",
  votes_right, votes_wrong))
print(string.format("ceiling for a perfect selection rule: +%.1fpp held-out (%d of %d tasks)",
  100 * recoverable / base.n, recoverable, base.n))
