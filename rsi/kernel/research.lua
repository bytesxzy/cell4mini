-- Scheduled internet research. Honest scope: without a language model in the loop, the system cannot
-- read a paper and derive a mechanism from it. What it CAN do automatically and does here:
--   1. pull fresh external benchmark tasks (ARC-AGI-1 / ARC-AGI-2 public training tasks) into the
--      external, never-trained-on evaluation set, so evaluation keeps changing under the system;
--   2. pull recent arXiv abstracts on program synthesis / library learning / self-improvement, dedupe,
--      keep a keyword-signal timeline, and surface them on the dashboard for the human researcher.
-- Hypotheses that drive experiments come from the system's own experimental data (see mutate.lua).
local json = require("rsi.kernel.json")
local M = {}

local function fetch(url)
  local cmd = "curl -sL --max-time 45 -A 'cell4-rsi/1.0' '" .. url:gsub("'", "%%27") .. "' 2>/dev/null"
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

local SIGNALS = { "library learning", "bottom-up", "observational equivalence", "self-improv", "program synthesis",
  "verification", "search", "abstraction", "ARC", "test-time", "curriculum", "neural-guided", "enumerat" }

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
          local hits = {}
          local text = (title .. " " .. summary):lower()
          for _, s in ipairs(SIGNALS) do if text:find(s:lower(), 1, true) then hits[#hits + 1] = s signals[s] = (signals[s] or 0) + 1 end end
          json.append_line(papers_path, { id = id, title = title, published = published, query = q, signals = hits,
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
  os.execute("mkdir -p '" .. dir .. "'")
  local have = {}
  local p = io.popen("ls '" .. dir .. "' 2>/dev/null")
  if p then for name in p:lines() do have[name] = true end p:close() end
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
  os.execute("mkdir -p '" .. root .. "/data/research'")
  local logs = {}
  local function log(m) logs[#logs + 1] = m end
  local papers, signals = fetch_arxiv(root, cfg, log)
  local arc = fetch_arc(root, cfg, log)
  state.last_research = os.time()
  local entry = { time = os.time(), papers_new = papers, arc_new = arc, signals = signals, errors = logs }
  json.append_line(root .. "/data/research/log.jsonl", entry)
  return entry
end

function M.recent_papers(root, n)
  local all = json.read_lines(root .. "/data/research/papers.jsonl")
  local out = {}
  for i = #all, math.max(1, #all - n + 1), -1 do out[#out + 1] = all[i] end
  return out
end

return M
