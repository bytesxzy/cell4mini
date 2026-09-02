-- CLI entry for the CELL4 recursive self-improvement loop.
--   lua run.lua step            one generation
--   lua run.lua loop [seconds]  run forever, sleeping `seconds` between generations (default 20)
--   lua run.lua status          print state summary
--   lua run.lua research        force a research fetch now
--   lua run.lua eval            evaluate the champion on fresh splits without mutating anything
package.path = "./?.lua;./?/init.lua;" .. package.path
local cmd = arg[1] or "step"
local cycle = require("rsi.kernel.cycle")

if cmd == "step" then
  local r = cycle.step()
  print(string.format("generation %d done: held-out %.1f%% %s", r.gen, r.heldout * 100, r.accepted and ("ACCEPTED " .. r.operator) or "(no change)"))
elseif cmd == "loop" then
  local pause = tonumber(arg[2]) or 20
  while true do
    local ok, err = pcall(cycle.step)
    if not ok then io.stderr:write("generation failed: " .. tostring(err) .. "\n") end
    os.execute("sleep " .. pause)
  end
elseif cmd == "status" then
  local state, bench = cycle.status()
  print("generation", state.gen, "accepted", state.accepted_total, "of", state.candidates_total)
  print("held-out epoch", bench.heldout_epoch, "regression suite", #bench.regression, "rotations", #bench.rotations)
  for _, l in ipairs(state.log or {}) do print(l) end
elseif cmd == "research" then
  local cfg = require("rsi.config")
  local research = require("rsi.kernel.research")
  local json = require("rsi.kernel.json")
  local state = json.read(cfg.root .. "/state/state.json") or {}
  local r = research.run(cfg.root, cfg, state)
  json.write(cfg.root .. "/state/state.json", state)
  print(json.encode(r))
elseif cmd == "eval" then
  local cfg = require("rsi.config")
  local genome = require("rsi.kernel.genome")
  local benchmarks = require("rsi.kernel.benchmarks")
  local evaluate = require("rsi.kernel.evaluate")
  local g = genome.load(cfg.root .. "/genome")
  local bench = benchmarks.load(cfg.root)
  local splits = benchmarks.build_splits(bench, cfg, "eval-" .. os.time())
  for _, name in ipairs({ "train", "heldout", "adversarial", "regression" }) do
    local r = evaluate.run(g, splits[name], { nodes = cfg.nodes, seconds = cfg.seconds })
    print(string.format("%-12s %3d/%3d solved  partial %.2f  nodes %.0f  %.1fs", name, r.solved, r.n, r.partial_mean, r.nodes_mean, r.time))
  end
else
  print("unknown command " .. cmd)
  os.exit(1)
end
