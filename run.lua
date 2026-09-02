-- CLI entry for the CELL4 recursive self-improvement loop.
--   lua run.lua step            one generation
--   lua run.lua loop [seconds]  run forever, sleeping `seconds` between generations (default 20)
--   lua run.lua status          print state summary
--   lua run.lua research        force a research fetch now
--   lua run.lua eval            evaluate the champion on fresh splits without mutating anything
--   lua run.lua narrate [delay] replay the latest generation's account, a word at a time
--   lua run.lua history         print the whole narrated history
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
elseif cmd == "narrate" then
  -- Replay the most recent narration with the typewriter delay. The text was composed and audited
  -- when the generation ran; this only re-types it, so nothing can drift between the two.
  local cfg = require("rsi.config")
  local narrator = require("rsi.kernel.narrator")
  local json = require("rsi.kernel.json")
  local delay = tonumber(arg[2]) or 0.05
  local all = json.read_lines(cfg.root .. "/data/narrative.jsonl")
  local e = all[#all]
  if not e then
    print("nothing narrated yet -- run `lua run.lua step` first")
    os.exit(1)
  end
  print(string.format("generation %d, narrated %s", e.gen or 0, os.date("!%Y-%m-%d %H:%M UTC", e.time or 0)))
  print("")
  for _, s in ipairs(e.sentences or {}) do narrator.stream("  " .. s, delay) end
  if e.corrections and #e.corrections > 0 then
    print("")
    for _, c in ipairs(e.corrections) do
      print(string.format("  (corrected while writing: %s was stated as %s, recomputed to %s)",
        c.key, tostring(c.stated), tostring(c.actual)))
    end
  end
elseif cmd == "history" then
  local cfg = require("rsi.config")
  local narrator = require("rsi.kernel.narrator")
  narrator.render_history(cfg.root)
  local f = io.open("HISTORY.md", "r")
  if f then io.write(f:read("*a")) f:close() else print("no history yet") end
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
  os.execute("rm -rf '" .. dir .. "'")

  -- The narrator's accuracy guard, checked rather than asserted. A summary field is deliberately
  -- corrupted; the narrator must catch it by recomputing from the per-task vector, correct it, and
  -- never let the false number reach the text it asserts.
  local narrator = require("rsi.kernel.narrator")
  local per = {}
  for i = 1, 50 do per[i] = { solved = i <= 37 and 1 or 0, family = "selftest" } end
  local raw = {
    gen = 0, fingerprint = "selftest",
    heldout = { solved = 9999, n = 50, nodes_mean = 100, per_task = per },  -- 9999 is a lie
    adversarial = { solved = 0, n = 0, per_task = {} },
    regression = { solved = 0, n = 0 }, external = { solved = 0, n = 0 },
    candidates = {}, accepted = false, corpus_size = 0, library_size = 0,
    accepted_total = 0, candidates_total = 0,
  }
  local nres = narrator.narrate(raw, { quiet = true, seed = "selftest" })
  local text = table.concat(nres.sentences, " ")
  local caught, corrected = false, false
  for _, c in ipairs(nres.corrections) do
    if c.key == "heldout_solved" and c.actual == 37 then caught = true end
  end
  corrected = text:find("37", 1, true) ~= nil and text:find("9999", 1, true) == nil
  for _, x in ipairs(r.per_task) do
    print(string.format("  %-22s %s", x.id, x.solved == 1 and ("solved: " .. x.program) or "UNSOLVED"))
  end
  print(string.format("  %-22s %s", "narrator guard", caught and corrected
    and "caught a corrupted fact, recomputed it to 37, kept the false 9999 out of the text"
    or "FAILED to catch the corrupted fact"))

  if #ext == 2 and r.solved == 2 and caught and corrected then
    print("selftest OK: ARC-format loading, solving, held-out verification and the narrator's accuracy guard all work")
  else
    print(string.format("selftest FAILED: loaded %d/2 tasks, solved %d/%d, narrator guard %s",
      #ext, r.solved, r.n, (caught and corrected) and "ok" or "BROKEN"))
    os.exit(1)
  end
else
  print("unknown command " .. cmd)
  os.exit(1)
end
