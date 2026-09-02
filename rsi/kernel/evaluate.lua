-- Runs a genome's solver over a task set under hard budgets and verifies solutions on
-- kernel-only test examples. The solver never sees test examples or generator metadata.
local ops = require("rsi.kernel.ops")
local program = require("rsi.kernel.program")
local sandbox = require("rsi.kernel.sandbox")
local tasks = require("rsi.kernel.tasks")
local features = require("rsi.kernel.features")
local M = {}

local function verify(node, prims, examples)
  local ok, f = pcall(program.compile, node, prims)
  if not ok then return false end
  for _, ex in ipairs(examples) do
    local ok2, out = pcall(f, ex.input)
    if not ok2 or not ops.equal(out, ex.output) then return false end
  end
  return true
end

-- cfg: {nodes=, instructions=, seconds=, on_progress=function(i,n,solved)}
function M.run(g, task_list, cfg)
  cfg = cfg or {}
  local nodes = cfg.nodes or 3000
  local instructions = cfg.instructions or 40000000
  local seconds = cfg.seconds or 3
  local results = { per_task = {}, solved = 0, partial_sum = 0, nodes_sum = 0, n = #task_list, time = 0 }
  local t0 = os.clock()
  for i, task in ipairs(task_list) do
    local view = tasks.solver_view(task)
    local ctx = {
      dsl = { prims = g.prims, order = g.order },
      policy = g.policy,
      budget = nodes,
      deadline = os.clock() + seconds,
      sig = ops.sig,
      equal = ops.equal,
      program = program,
      features = features.bucket,
    }
    local t1 = os.clock()
    local ok, res, exhausted = sandbox.run(instructions, g.solve, view, ctx)
    local r = { id = task.id, family = task.family, solved = 0, partial = 0, nodes = 0, program = nil, err = nil }
    if ok and type(res) == "table" then
      r.nodes = res.nodes or 0
      r.partial = res.partial or 0
      if res.program then
        -- train fit is claimed by the solver; the kernel checks train AND held-out test examples
        if verify(res.program, g.prims, task.train) and verify(res.program, g.prims, task.test) then
          r.solved = 1
          r.partial = 1
          r.program = program.to_string(res.program)
        else
          r.overfit_train = verify(res.program, g.prims, task.train)
          r.program_rejected = program.to_string(res.program)
        end
      end
      if res.best_partial then r.partial_program = program.to_string(res.best_partial) end
    else
      r.err = exhausted and "budget" or tostring(res)
    end
    r.time = os.clock() - t1
    results.per_task[i] = r
    results.solved = results.solved + r.solved
    results.partial_sum = results.partial_sum + r.partial
    results.nodes_sum = results.nodes_sum + r.nodes
    if cfg.on_progress and (i % 5 == 0 or i == #task_list) then cfg.on_progress(i, #task_list, results.solved) end
  end
  results.time = os.clock() - t0
  results.solve_rate = results.n > 0 and results.solved / results.n or 0
  results.partial_mean = results.n > 0 and results.partial_sum / results.n or 0
  results.nodes_mean = results.n > 0 and results.nodes_sum / results.n or 0
  return results
end

function M.vector(results, field)
  local v = {}
  for i, r in ipairs(results.per_task) do v[i] = r[field or "solved"] end
  return v
end

return M
