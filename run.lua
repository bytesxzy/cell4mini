-- CLI entry for the CELL4 recursive self-improvement loop.
--   lua run.lua step            one generation
--   lua run.lua loop [seconds]  run forever, sleeping `seconds` between generations (default 20)
--   lua run.lua status          print state summary
--   lua run.lua research        force a research fetch now
--   lua run.lua eval            evaluate the champion on fresh splits without mutating anything
--   lua run.lua selftest        verify the external ARC benchmark path end to end
package.path = "./?.lua;./?/init.lua;" .. package.path
local cmd = arg[1] or "step"
local cycle = require("rsi.kernel.cycle")

if cmd == "step" then
  local ok, r = pcall(cycle.step)
  if not ok then
    io.stderr:write(tostring(r), "\n")
    os.exit(1)
  end
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
elseif cmd == "selftest" then
  -- End-to-end check of the external-benchmark path, using ARC-format files in a temp directory so
  -- the real rsi/data/arc is never polluted with synthetic tasks.
  local cfg = require("rsi.config")
  local benchmarks = require("rsi.kernel.benchmarks")
  local genome = require("rsi.kernel.genome")
  local evaluate = require("rsi.kernel.evaluate")
  local json = require("rsi.kernel.json")
  local dir = "/tmp/cell4-selftest"
  os.execute("rm -rf '" .. dir .. "' && mkdir -p '" .. dir .. "/data/arc'")
  local samples = { { { 1, 0, 2 }, { 0, 1, 0 }, { 2, 0, 1 } }, { { 0, 1, 1 }, { 1, 0, 0 }, { 0, 0, 1 } },
                    { { 2, 2, 0 }, { 0, 1, 0 }, { 1, 0, 2 } }, { { 1, 1, 0 }, { 0, 2, 1 }, { 0, 0, 0 } } }
  local function flip(g) local o = {} for r = 1, #g do local row = {} for c = 1, #g[r] do row[c] = g[r][#g[r] + 1 - c] end o[r] = row end return o end
  local function recolor(g) local o = {} for r = 1, #g do local row = {} for c = 1, #g[r] do row[c] = g[r][c] == 1 and 3 or g[r][c] end o[r] = row end return o end
  local cases = { flip = flip, recolor = recolor }
  for name, f in pairs(cases) do
    local d = { train = {}, test = {} }
    for i = 1, 3 do d.train[i] = { input = samples[i], output = f(samples[i]) } end
    d.test[1] = { input = samples[4], output = f(samples[4]) }
    json.write(dir .. "/data/arc/" .. name .. ".json", d)
  end
  local ext = benchmarks.load_external(dir, 10)
  local g = genome.load(cfg.root .. "/genome")
  local r = evaluate.run(g, ext, { nodes = cfg.external_nodes, seconds = cfg.external_seconds })
  for _, x in ipairs(r.per_task) do
    print(string.format("  %-22s %s", x.id, x.solved == 1 and ("solved: " .. x.program) or "UNSOLVED"))
  end
  os.execute("rm -rf '" .. dir .. "'")
  if #ext == 2 and r.solved == 2 then
    print("selftest OK: ARC-format loading, solving and held-out verification all work")
  else
    print(string.format("selftest FAILED: loaded %d/2 tasks, solved %d/%d", #ext, r.solved, r.n))
    os.exit(1)
  end
else
  print("unknown command " .. cmd)
  os.exit(1)
end
