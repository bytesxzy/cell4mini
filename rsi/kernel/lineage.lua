-- Versioned lineage: every candidate is snapshotted with its evidence and the accept/reject verdict.
local json = require("rsi.kernel.json")
local genome = require("rsi.kernel.genome")
local plat = require("rsi.kernel.plat")
local M = {}

function M.record(root, entry)
  json.append_line(root .. "/state/lineage.jsonl", entry)
  json.append_line(root .. "/www/lineage.jsonl", entry)
end

function M.snapshot(root, gen, tag, g, evidence)
  local dir = string.format("%s/versions/g%04d_%s", root, gen, tag)
  genome.save(g, dir)
  if evidence then json.write(dir .. "/evidence.json", evidence) end
  return dir
end

-- Rejected candidate snapshots accumulate at candidates_per_gen per generation, which is thousands
-- a day on a machine left running. Accepted champions are kept forever; rejected candidates are kept
-- for `keep` generations, long enough to inspect a recent verdict. Their evidence stays in
-- lineage.jsonl either way, so nothing that explains a decision is lost.
function M.prune(root, current_gen, keep)
  keep = keep or 50
  local cutoff = current_gen - keep
  if cutoff < 1 then return 0 end
  local removed = 0
  for _, name in ipairs(plat.ls(root .. "/versions")) do
    local g = tonumber(name:match("^g(%d+)_"))
    if g and g <= cutoff and not name:match("_champion$") then
      plat.rmrf(root .. "/versions/" .. name)
      removed = removed + 1
    end
  end
  p:close()
  return removed
end

function M.history(root, limit)
  local all = json.read_lines(root .. "/state/lineage.jsonl")
  if limit and #all > limit then
    local out = {}
    for i = #all - limit + 1, #all do out[#out + 1] = all[i] end
    return out
  end
  return all
end

return M
