-- Scheduled internet research. Honest scope: without a language model in the loop, the system cannot
-- read a paper and derive a mechanism from it. What it CAN do automatically and does here:
--   1. pull fresh external benchmark tasks (ARC-AGI-1 / ARC-AGI-2 public training tasks) into the
--      external, never-trained-on evaluation set, so evaluation keeps changing under the system;
--   2. pull recent arXiv abstracts on program synthesis / library learning / self-improvement, dedupe,
--      keep a keyword-signal timeline, and surface them on the dashboard for the human researcher.
-- Hypotheses that drive experiments come from the system's own experimental data (see mutate.lua).
local json = require("rsi.kernel.json")
local mechanisms = require("rsi.kernel.mechanisms")
local plat = require("rsi.kernel.plat")
local M = {}

local function fetch(url)
  -- Quoting and the null device differ between sh and cmd.exe; plat.quote picks the right one.
  local safe = url:gsub("'", "%%27"):gsub('"', "%%22")
  local cmd = "curl -sL --max-time 45 -A " .. plat.quote("cell4-rsi/1.0") .. " " ..
    plat.quote(safe) .. (plat.windows and " 2>nul" or " 2>/dev/null")
  local p = io.popen(cmd)
  if not p then return nil end
  local body = p:read("*a")
  p:close()
  if not body or #body == 0 then return nil end
  return body
end

local function xml_unescape(s)
  return (s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&"))
end

-- Papers are ranked against rsi/kernel/mechanisms.lua: what this system already implements, what it
-- measured and discarded, and what it has never had. A paper touching a declared gap outranks one
-- describing machinery that is already here. This is keyword matching against an explicit list, not
-- comprehension -- there is no model here to read anything -- and the console says so.

local function fetch_arxiv(root, cfg, log)
  local papers_path = root .. "/data/research/papers.jsonl"
  local known = {}
  for _, p in ipairs(json.read_lines(papers_path)) do known[p.id] = true end
  local new_count, signals = 0, {}
  for _, q in ipairs(cfg.arxiv_queries) do
    local url = "https://export.arxiv.org/api/query?search_query=" .. q:gsub(" ", "%%20"):gsub('"', "%%22") ..
      "&sortBy=submittedDate&sortOrder=descending&max_results=" .. cfg.arxiv_max
    local body = fetch(url)
    if body then
      for entry in body:gmatch("<entry>(.-)</entry>") do
        local id = entry:match("<id>(.-)</id>")
        local title = entry:match("<title>(.-)</title>")
        local summary = entry:match("<summary>(.-)</summary>")
        local published = entry:match("<published>(.-)</published>")
        if id and title and not known[id] then
          known[id] = true
          title = xml_unescape(title:gsub("%s+", " "))
          summary = xml_unescape((summary or ""):gsub("%s+", " "))
          local score, gaps, already, note = mechanisms.score(title .. " " .. summary)
          for _, g in ipairs(gaps) do signals[g] = (signals[g] or 0) + 1 end
          json.append_line(papers_path, { id = id, title = title, published = published, query = q,
            addresses_gap = gaps, already_have = already, actionability = score, why = note,
            summary = summary:sub(1, 600), fetched = os.time() })
          new_count = new_count + 1
        end
      end
    else
      log("arxiv fetch failed for query: " .. q)
    end
  end
  return new_count, signals
end

local ARC_SOURCES = {
  { repo = "fchollet/ARC-AGI", path = "data/training", prefix = "arc1_" },
  { repo = "arcprize/ARC-AGI-2", path = "data/training", prefix = "arc2_" },
}

local function fetch_arc(root, cfg, log)
  local dir = root .. "/data/arc"
  plat.mkdirp(dir)
  local have = {}
  for _, name in ipairs(plat.ls(dir)) do have[name] = true end
  local fetched = 0
  for _, src in ipairs(ARC_SOURCES) do
    if fetched >= cfg.arc_per_fetch then break end
    local listing = fetch("https://api.github.com/repos/" .. src.repo .. "/contents/" .. src.path)
    local arr = listing and json.decode(listing)
    if type(arr) == "table" and arr[1] then
      for _, item in ipairs(arr) do
        if fetched >= cfg.arc_per_fetch then break end
        local name = item.name
        if type(name) == "string" and name:match("%.json$") and not have[src.prefix .. name] and item.download_url then
          local body = fetch(item.download_url)
          if body and json.decode(body) then
            local f = io.open(dir .. "/" .. src.prefix .. name, "w")
            if f then f:write(body) f:close() fetched = fetched + 1 have[src.prefix .. name] = true end
          end
        end
      end
    else
      log("ARC listing fetch failed for " .. src.repo)
    end
  end
  return fetched
end

function M.due(state, cfg)
  return (os.time() - (state.last_research or 0)) >= cfg.research_interval
end

function M.run(root, cfg, state)
  plat.mkdirp(root .. "/data/research")
  local logs = {}
  local function log(m) logs[#logs + 1] = m end
  local papers, signals = fetch_arxiv(root, cfg, log)
  local arc = fetch_arc(root, cfg, log)
  state.last_research = os.time()
  local entry = { time = os.time(), papers_new = papers, arc_new = arc, signals = signals, errors = logs,
    gaps = mechanisms.gap_names() }
  json.append_line(root .. "/data/research/log.jsonl", entry)
  return entry
end

-- Most actionable first, then most recent. A feed ordered by date buries the one paper that touches
-- something the system does not have under thirty that restate what it already does.
function M.recent_papers(root, n)
  local all = json.read_lines(root .. "/data/research/papers.jsonl")
  local recent = {}
  for i = #all, math.max(1, #all - 300 + 1), -1 do recent[#recent + 1] = all[i] end
  table.sort(recent, function(a, b)
    local sa, sb = a.actionability or 0, b.actionability or 0
    if sa ~= sb then return sa > sb end
    return (a.fetched or 0) > (b.fetched or 0)
  end)
  local out = {}
  for i = 1, math.min(n, #recent) do out[i] = recent[i] end
  return out
end

function M.registry()
  return mechanisms
end

return M
