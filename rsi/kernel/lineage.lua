-- Versioned lineage: every candidate is snapshotted with its evidence and the accept/reject verdict.
local json = require("rsi.kernel.json")
local genome = require("rsi.kernel.genome")
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
