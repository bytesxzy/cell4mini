-- Score the champion on a named split of the reconstructed public ARC corpus.
-- Writes per-task outcomes to JSON so the gap analysis can be done on facts, not impressions.
package.path = "./?.lua;./?/init.lua;" .. package.path
local src = assert(io.open("cell4.lua", "r")):read("*a")
local cut = src:find("-- ==== run%.lua %(CLI entry%) ====")
assert(load(src:sub(1, cut - 1), "@cell4.lua"))()

local cfg      = require("rsi.config")
local genome   = require("rsi.kernel.genome")
local evaluate = require("rsi.kernel.evaluate")
local json     = require("rsi.kernel.json")

local WANT  = arg[1] or "design"
local NODES = tonumber(arg[2]) or 2500
local SECS  = tonumber(arg[3]) or 4

local manifest = json.read("corpus_manifest.json")
local dir = cfg.root .. "/data/arc"
local names = {}
for name, split in pairs(manifest) do if split == WANT then names[#names+1] = name end end
table.sort(names)

local function grid(a)
  local g = { h = #a, w = #a[1] }
  for r = 1, g.h do local row = {} for c = 1, g.w do row[c] = a[r][c] end g[r] = row end
  return g
end
local list = {}
for _, name in ipairs(names) do
  local d = json.read(dir .. "/" .. name)
  local ok, t = pcall(function()
    local train, test = {}, {}
    for i, ex in ipairs(d.train) do train[i] = { input = grid(ex.input), output = grid(ex.output) } end
    for _, ex in ipairs(d.test) do if ex.output then test[#test+1] = { input = grid(ex.input), output = grid(ex.output) } end end
    if #test == 0 then error("no test outputs") end
    return { id = name:gsub("%.json$",""), family = "arc", in_type="G", out_type="G", train=train, test=test }
  end)
  if ok and t then list[#list+1] = t end
end

io.stderr:write(string.format("scoring %d tasks (split=%s, nodes=%d, seconds=%s)\n", #list, WANT, NODES, tostring(SECS)))
local r = evaluate.run(genome.load(cfg.root .. "/genome"), list, { nodes = NODES, seconds = SECS })

local solved, overfit, noreach = {}, {}, {}
for _, x in ipairs(r.per_task) do
  if x.solved == 1 then solved[#solved+1] = { id = x.id, program = x.program }
  elseif x.overfit_train then overfit[#overfit+1] = { id = x.id, picked = tostring(x.program_rejected) }
  else noreach[#noreach+1] = { id = x.id, partial = x.partial } end
end
local out = io.open("result_" .. WANT .. ".json", "w")
out:write(json.encode({ split=WANT, nodes=NODES, seconds=SECS, n=r.n,
  solved=solved, overfit=overfit, noreach=noreach }))
out:close()
print(string.format("split=%s n=%d nodes=%d s=%s", WANT, r.n, NODES, tostring(SECS)))
print(string.format("  solved                     %4d (%.2f%%)", #solved, 100*#solved/math.max(r.n,1)))
print(string.format("  train-consistent but wrong %4d (%.2f%%)", #overfit, 100*#overfit/math.max(r.n,1)))
print(string.format("  no program in reach        %4d (%.2f%%)", #noreach, 100*#noreach/math.max(r.n,1)))
