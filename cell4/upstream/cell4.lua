-- CELL4 — single-file combination of every Lua source in this project.
-- Kernel modules are registered with package.preload so every original
-- require("rsi....") call keeps working without separate files.
-- Genome files (mutable) are materialized to rsi/genome/ only if missing,
-- so loadfile/io.open in rsi.kernel.genome are unchanged.
-- Original module source is copied as-is. Nothing was rewritten.
--
-- Usage (one generation per process, then exit):
--   lua cell4.lua              one generation (default)
--   lua cell4.lua step         same
--   lua cell4.lua status | research | eval | narrate | history | selftest | unlock
--   lua cell4.lua transpile    original main.lua CELL2 transpiler
-- Persistent `loop` is rejected: schedule this process externally.
--
-- Included files:
--   rsi/config.lua  ->  package.preload['rsi.config']
--   rsi/kernel/json.lua  ->  package.preload['rsi.kernel.json']
--   rsi/kernel/rng.lua  ->  package.preload['rsi.kernel.rng']
--   rsi/kernel/sandbox.lua  ->  package.preload['rsi.kernel.sandbox']
--   rsi/kernel/serialize.lua  ->  package.preload['rsi.kernel.serialize']
--   rsi/kernel/constants.lua  ->  package.preload['rsi.kernel.constants']
--   rsi/kernel/features.lua  ->  package.preload['rsi.kernel.features']
--   rsi/kernel/ops.lua  ->  package.preload['rsi.kernel.ops']
--   rsi/kernel/program.lua  ->  package.preload['rsi.kernel.program']
--   rsi/kernel/stats.lua  ->  package.preload['rsi.kernel.stats']
--   rsi/kernel/mechanisms.lua  ->  package.preload['rsi.kernel.mechanisms']
--   rsi/kernel/inverses.lua  ->  package.preload['rsi.kernel.inverses']
--   rsi/kernel/dashboard.lua  ->  package.preload['rsi.kernel.dashboard']
--   rsi/kernel/journal.lua  ->  package.preload['rsi.kernel.journal']
--   rsi/kernel/challenge.lua  ->  package.preload['rsi.kernel.challenge']
--   rsi/kernel/genome.lua  ->  package.preload['rsi.kernel.genome']
--   rsi/kernel/evaluate.lua  ->  package.preload['rsi.kernel.evaluate']
--   rsi/kernel/tasks.lua  ->  package.preload['rsi.kernel.tasks']
--   rsi/kernel/lineage.lua  ->  package.preload['rsi.kernel.lineage']
--   rsi/kernel/mutate.lua  ->  package.preload['rsi.kernel.mutate']
--   rsi/kernel/research.lua  ->  package.preload['rsi.kernel.research']
--   rsi/kernel/narrator.lua  ->  package.preload['rsi.kernel.narrator']
--   rsi/kernel/benchmarks.lua  ->  package.preload['rsi.kernel.benchmarks']
--   rsi/kernel/cycle.lua  ->  package.preload['rsi.kernel.cycle']
--   rsi/lm/markov.lua  ->  package.preload['rsi.lm.markov']
--   rsi/genome/dsl_base.lua  ->  package.preload['rsi.genome.dsl_base']
--   rsi/genome/library.lua  ->  package.preload['rsi.genome.library']
--   rsi/genome/policy.lua  ->  package.preload['rsi.genome.policy']
--   rsi/genome/search.lua  ->  package.preload['rsi.genome.search']
--   main.lua  ->  package.preload['cell4.main']
--   run.lua  ->  main chunk (CLI entry)

do
  -- ==== rsi/config.lua ====
  package.preload['rsi.config'] = function(...)
-- Kernel configuration (stable). Budgets are in solver nodes (deterministic), with hard instruction/time caps.
local CONFIG = {
  root = "rsi",
  -- evaluation splits: tasks per family
  train_per_family = 10,       -- visible split: mutation operators may learn from its solutions
  heldout_per_family = 20,     -- secret-salted split: drives acceptance; the genome never sees its seeds.
                               -- Sized for statistical power: a paired test on 120 items with ~8 discordant
                               -- pairs cannot detect a true 3pp gain, so the bar stays high and n grows instead.
  adversarial_per_family = 8,  -- fresh every generation, hidden-op / larger-size families only
  adversarial_families = { "list_hidden", "list_wide", "grid_hidden", "grid_wide" },
  regression_cap = 160,        -- most recent N held-out tasks solved by accepted champions
  external_cap = 60,           -- ARC tasks evaluated per generation (external benchmark, never trained on)
  -- per-task solver budgets
  nodes = 3000,
  instructions = 60000000,
  seconds = 3,
  external_nodes = 2500,
  external_seconds = 4,
  -- acceptance
  bootstrap_reps = 3000,
  alpha = 0.05,
  adversarial_tolerance = -0.03, -- candidate may not lose more than this on the adversarial split
  overfit_gap = 0.10,           -- train gain minus held-out gain above this (with no held-out gain) = overfit
  efficiency_ratio = 0.80,      -- accept equal-score candidates only if they use <= 80% of the nodes
  candidates_per_gen = 4,
  -- benchmark management
  pressure_limit = 2,           -- same family drives 2 consecutive acceptances -> rotate secret split + spawn variant
  -- Challenge ranking (rsi/kernel/challenge.lua). The four components are measured; these weights
  -- are a declared convention, shown on the console and in JOURNAL.md so they can be argued with.
  challenge_weights = { information = 0.40, discrimination = 0.35, headroom = 0.15, freshness = 0.10 },
  saturation_solve_floor = 0.92, -- solved at least this often ...
  saturation_disc_floor = 0.05,  -- ... AND no longer separating candidates = spent, spawn a variant
  adversarial_from_ranking = true, -- point the adversarial split at whatever discriminates best
  -- research cadence (seconds)
  research_interval = 5400,     -- 1.5 h
  arc_per_fetch = 25,
  arxiv_max = 30,
  -- Queries aimed at the gaps declared in rsi/kernel/mechanisms.lua, not at machinery already built.
  arxiv_queries = {
    'all:"program synthesis"',
    'all:"ARC-AGI" OR all:"abstraction and reasoning corpus"',
    'all:"equality saturation" OR all:"e-graph"',
    'all:"sketch" AND all:"synthesis"',
    'all:"conflict-driven" OR all:"counterexample-guided"',
    'all:"type-directed" AND all:"synthesis"',
    'all:"library learning" OR all:"anti-unification"',
  },
}

-- THROTTLE. Shared hosting (Namecheap and friends) sells web serving, not compute, and enforces
-- that with CPU/entry-process limits and a fair-use clause. These four knobs are the ones that
-- decide how much CPU a single invocation spends; they can be lowered from the environment so a
-- constrained host can be respected without editing this file, and so one machine's throttle is not
-- baked into the genome that another machine inherits.
--
-- Deliberately NOT overridable: heldout_per_family, alpha, bootstrap_reps, adversarial_tolerance,
-- overfit_gap. Those set the evidential bar. Lowering them would not make the system cheaper, it
-- would make it wrong -- it would start accepting changes the evidence does not support.
--
--   CELL4_CANDIDATES=1        candidates evaluated per generation (default 4). The cheapest real
--                             lever: 1 candidate is roughly a third of the work of 4 and improves
--                             more slowly, but every acceptance is decided by the same rule.
--   CELL4_SECONDS=2           per-task solver wall-clock budget (default 3)
--   CELL4_NODES=2000          per-task solver node budget (default 3000)
--   CELL4_EXTERNAL_CAP=20     ARC tasks evaluated per generation (default 60)
--
-- Changing seconds/nodes changes what "solved" means, so the champion's cached scores are keyed on
-- these values (rsi/kernel/cycle.lua) and a changed budget forces a full re-evaluation rather than
-- comparing a candidate against a champion measured under a different budget.
local function env_num(name, default, lo, hi)
  local v = tonumber(os.getenv(name) or "")
  if not v then return default end
  if lo and v < lo then v = lo end
  if hi and v > hi then v = hi end
  return v
end

return (function(c)
  c.candidates_per_gen = env_num("CELL4_CANDIDATES", c.candidates_per_gen, 1, 16)
  c.seconds            = env_num("CELL4_SECONDS", c.seconds, 0.25, 120)
  c.nodes              = env_num("CELL4_NODES", c.nodes, 100, 1000000)
  c.external_cap       = env_num("CELL4_EXTERNAL_CAP", c.external_cap, 0, 10000)
  c.external_seconds   = env_num("CELL4_EXTERNAL_SECONDS", c.external_seconds, 0.25, 120)
  c.external_nodes     = env_num("CELL4_EXTERNAL_NODES", c.external_nodes, 100, 1000000)
  -- A one-line fingerprint of the budgets this process ran under. Recorded in state and used as part
  -- of the champion cache key, so a throttled run never silently reuses an unthrottled measurement.
  c.budget_profile = string.format("n%d/s%s/xn%d/xs%s", c.nodes, tostring(c.seconds),
    c.external_nodes, tostring(c.external_seconds))
  return c
end)(CONFIG)
  end

  -- ==== rsi/kernel/json.lua ====
  package.preload['rsi.kernel.json'] = function(...)
-- Minimal deterministic JSON encoder/decoder (Lua 5.1 / LuaJIT / 5.4).
local M = {}

local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  return n == #t
end

local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function encode(v, out)
  local t = type(v)
  if t == "nil" then out[#out + 1] = "null"
  elseif t == "boolean" then out[#out + 1] = tostring(v)
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then out[#out + 1] = "null"
    elseif v == math.floor(v) and math.abs(v) < 1e15 then out[#out + 1] = string.format("%d", v)
    else out[#out + 1] = string.format("%.14g", v) end
  elseif t == "string" then
    out[#out + 1] = '"' .. v:gsub('[%c"\\]', function(c) return escapes[c] or string.format("\\u%04x", c:byte()) end) .. '"'
  elseif t == "table" then
    if is_array(v) then
      out[#out + 1] = "["
      for i = 1, #v do
        if i > 1 then out[#out + 1] = "," end
        encode(v[i], out)
      end
      out[#out + 1] = "]"
    else
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = tostring(k) end
      table.sort(keys)
      out[#out + 1] = "{"
      for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = "," end
        encode(k, out)
        out[#out + 1] = ":"
        encode(v[k] == nil and v[tonumber(k)] or v[k], out)
      end
      out[#out + 1] = "}"
    end
  else
    out[#out + 1] = '"<' .. t .. '>"'
  end
end

function M.encode(v)
  local out = {}
  encode(v, out)
  return table.concat(out)
end

-- decoder
local function skip(s, i)
  local _, e = s:find("^[ \n\r\t]*", i)
  return e + 1
end

local decode_value

local function decode_string(s, i)
  local out, j = {}, i + 1
  while true do
    local c = s:sub(j, j)
    if c == "" then error("json: unterminated string") end
    if c == '"' then return table.concat(out), j + 1 end
    if c == "\\" then
      local n = s:sub(j + 1, j + 1)
      if n == "u" then
        local code = tonumber(s:sub(j + 2, j + 5), 16) or 63
        if code < 128 then out[#out + 1] = string.char(code)
        elseif code < 2048 then out[#out + 1] = string.char(192 + math.floor(code / 64), 128 + code % 64)
        else out[#out + 1] = string.char(224 + math.floor(code / 4096), 128 + math.floor(code / 64) % 64, 128 + code % 64) end
        j = j + 6
      else
        local map = { n = "\n", r = "\r", t = "\t", b = "\b", f = "\f" }
        out[#out + 1] = map[n] or n
        j = j + 2
      end
    else
      out[#out + 1] = c
      j = j + 1
    end
  end
end

decode_value = function(s, i)
  i = skip(s, i)
  local c = s:sub(i, i)
  if c == "{" then
    local obj = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == "}" then return obj, i + 1 end
    while true do
      local k
      k, i = decode_string(s, skip(s, i))
      i = skip(s, i)
      if s:sub(i, i) ~= ":" then error("json: expected ':' at " .. i) end
      local v
      v, i = decode_value(s, i + 1)
      obj[k] = v
      i = skip(s, i)
      local d = s:sub(i, i)
      if d == "}" then return obj, i + 1 end
      if d ~= "," then error("json: expected ',' at " .. i) end
      i = i + 1
    end
  elseif c == "[" then
    local arr = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == "]" then return arr, i + 1 end
    while true do
      local v
      v, i = decode_value(s, i)
      arr[#arr + 1] = v
      i = skip(s, i)
      local d = s:sub(i, i)
      if d == "]" then return arr, i + 1 end
      if d ~= "," then error("json: expected ',' at " .. i) end
      i = i + 1
    end
  elseif c == '"' then
    return decode_string(s, i)
  elseif s:sub(i, i + 3) == "true" then return true, i + 4
  elseif s:sub(i, i + 4) == "false" then return false, i + 5
  elseif s:sub(i, i + 3) == "null" then return nil, i + 4
  else
    local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
    if not num or num == "" then error("json: unexpected char '" .. c .. "' at " .. i) end
    return tonumber(num), i + #num
  end
end

function M.decode(s)
  local ok, v = pcall(function() return (decode_value(s, 1)) end)
  if not ok then return nil, v end
  return v
end

function M.read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return M.decode(s)
end

function M.write(path, v)
  local payload = M.encode(v)
  local tmp = path .. ".tmp"
  local f = assert(io.open(tmp, "w"))
  f:write(payload)
  f:close()
  if not os.rename(tmp, path) then
    os.remove(tmp)
    error("json.write: failed to replace " .. path)
  end
end

function M.append_line(path, v)
  local f = assert(io.open(path, "a"))
  f:write(M.encode(v), "\n")
  f:close()
end

function M.read_lines(path)
  local out = {}
  local f = io.open(path, "r")
  if not f then return out end
  for line in f:lines() do
    if line ~= "" then
      local v = M.decode(line)
      if v then out[#out + 1] = v end
    end
  end
  f:close()
  return out
end

return M
  end

  -- ==== rsi/kernel/rng.lua ====
  package.preload['rsi.kernel.rng'] = function(...)
-- Deterministic PRNG (Park-Miller minimal standard), Lua 5.1/LuaJIT/5.4 safe (no bit ops).
local M = {}
M.__index = M

local function hashstr(s)
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % 2147483647 end
  return h
end

function M.new(seed)
  if type(seed) == "string" then seed = hashstr(seed) end
  seed = math.floor(seed or 1) % 2147483647
  if seed == 0 then seed = 1 end
  return setmetatable({ s = seed }, M)
end

function M:next()
  self.s = (self.s * 16807) % 2147483647
  return self.s
end

function M:float() return (self:next() - 1) / 2147483646 end

function M:int(a, b)
  if b == nil then a, b = 1, a end
  return a + (self:next() % (b - a + 1))
end

function M:pick(t) return t[self:int(#t)] end

function M:shuffle(t)
  for i = #t, 2, -1 do
    local j = self:int(i)
    t[i], t[j] = t[j], t[i]
  end
  return t
end

function M:derive(label) return M.new(hashstr(tostring(self:next()) .. "|" .. tostring(label))) end

M.hash = hashstr
return M
  end

  -- ==== rsi/kernel/sandbox.lua ====
  package.preload['rsi.kernel.sandbox'] = function(...)
-- Hard execution limits for untrusted candidate code: VM instruction budget + error isolation.
local M = {}

local BUDGET_ERR = "SANDBOX_BUDGET"

-- LUAJIT. A `count` debug hook is only called from the interpreter: LuaJIT does not check hooks
-- inside a compiled trace, so on LuaJIT a plain debug.sethook budget is silently NOT a budget. This
-- is not theoretical -- `while true do x = x + 1 end` under this sandbox runs forever on LuaJIT and
-- aborts in 0.01s on PUC Lua. The budget is the last line of defence behind the solver's own node
-- and wall-clock caps, and a cap that quietly stops existing is worse than no cap, so on LuaJIT the
-- sandboxed function is marked non-compilable (recursively) for the duration. Everything outside the
-- sandbox -- task generation, evaluation, statistics, JSON, serialisation, the narrator -- still
-- gets the JIT, and LuaJIT's interpreter is itself considerably faster than PUC Lua's.
--
-- Set CELL4_JIT_SOLVER=1 to keep the JIT on inside the sandbox. That is a deliberate trade: it is
-- faster, and the instruction budget stops being enforceable, leaving only the solver's own
-- `nodes >= budget` and `clock() > deadline` checks (rsi/genome/search.lua, which no mutation
-- operator rewrites) between a bug in the search and a process that never returns.
local jit_off, jit_on
if type(rawget(_G, "jit")) == "table" and jit.off and os.getenv("CELL4_JIT_SOLVER") ~= "1" then
  jit_off, jit_on = jit.off, jit.on
end

-- Run fn(...) with at most `instructions` VM instructions. Returns ok, result_or_error, exhausted.
function M.run(instructions, fn, ...)
  local step = 1000
  local remaining = math.floor(instructions / step)
  local exhausted = false
  local function hook()
    remaining = remaining - 1
    if remaining <= 0 then
      exhausted = true
      error(BUDGET_ERR, 0)
    end
  end
  if jit_off then jit_off(fn, true) end
  debug.sethook(hook, "", step)
  local res = { pcall(fn, ...) }
  debug.sethook()
  if jit_on then jit_on(fn, true) end
  local ok = res[1]
  if not ok then return false, res[2], exhausted end
  return true, res[2], false
end

M.BUDGET_ERR = BUDGET_ERR
return M
  end

  -- ==== rsi/kernel/serialize.lua ====
  package.preload['rsi.kernel.serialize'] = function(...)
-- Deterministic Lua-source serializer for genome data files.
local M = {}

local function key_str(k)
  if type(k) == "string" and k:match("^[%a_][%w_]*$") then return k end
  return "[" .. string.format("%q", k) .. "]"
end

local function ser(v, indent, out)
  local t = type(v)
  if t == "number" then
    if v == math.floor(v) then out[#out + 1] = string.format("%d", v) else out[#out + 1] = string.format("%.14g", v) end
  elseif t == "string" then out[#out + 1] = string.format("%q", v)
  elseif t == "boolean" then out[#out + 1] = tostring(v)
  elseif t == "table" then
    local n = #v
    local isarr = n > 0
    if isarr then for k in pairs(v) do if type(k) ~= "number" or k > n or k < 1 then isarr = false break end end end
    local pad = string.rep("  ", indent + 1)
    if isarr then
      out[#out + 1] = "{"
      for i = 1, n do
        if i > 1 then out[#out + 1] = ", " end
        ser(v[i], indent + 1, out)
      end
      out[#out + 1] = "}"
    else
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = k end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      out[#out + 1] = "{\n"
      for _, k in ipairs(keys) do
        out[#out + 1] = pad .. key_str(k) .. " = "
        ser(v[k], indent + 1, out)
        out[#out + 1] = ",\n"
      end
      out[#out + 1] = string.rep("  ", indent) .. "}"
    end
  else
    out[#out + 1] = "nil"
  end
end

function M.to_lua(v, header)
  local out = { header and ("-- " .. header .. "\n") or "", "return " }
  ser(v, 0, out)
  out[#out + 1] = "\n"
  return table.concat(out)
end

function M.write(path, v, header)
  local payload = M.to_lua(v, header)
  local tmp = path .. ".tmp"
  local f = assert(io.open(tmp, "w"))
  f:write(payload)
  f:close()
  if not os.rename(tmp, path) then
    os.remove(tmp)
    error("serialize.write: failed to replace " .. path)
  end
end

return M
  end

  -- ==== rsi/kernel/constants.lua ====
  package.preload['rsi.kernel.constants'] = function(...)
-- Constants derived from the task's own examples.
--
-- The policy carries a fixed global pool ({0,1,2,3} for integers, {0..5} for colours). Widening that
-- pool was measured and it LOSES: adding 4..9 cost 3.5pp on 300 tasks, because every extra leaf
-- multiplies through every level of the enumeration. The problem is not that the pool is small, it is
-- that it is task-independent -- a task about the colour 7 gains nothing from the search also
-- carrying 4, 5, 6, 8 and 9.
--
-- So instead of more constants, better ones: a handful read off the examples themselves. This is
-- standard practice in inductive synthesis (FlashFill and its descendants mine literals from the I/O
-- pairs before searching) and it costs almost nothing, because the derived set is small.
--
-- A constant is one value used for every example, so only example-INVARIANT quantities qualify. A
-- value present in one input but not another is not a constant the program can use; that is what
-- `len($)` and `height($)` are for. Hence every rule below intersects or agrees across all examples.
local M = {}

local function values_of(v, into)
  if type(v) == "number" then
    into[v] = true
  elseif type(v) == "table" then
    if v.h then
      for r = 1, v.h do
        for c = 1, v.w do into[v[r][c]] = true end
      end
    else
      for i = 1, #v do into[v[i]] = true end
    end
  end
end

local function intersect(sets)
  if #sets == 0 then return {} end
  local out = {}
  for k in pairs(sets[1]) do
    local all = true
    for i = 2, #sets do
      if not sets[i][k] then all = false break end
    end
    if all then out[#out + 1] = k end
  end
  table.sort(out)
  return out
end

-- All examples agree on this scalar, or nil.
local function agreed(examples, f)
  local first
  for i, ex in ipairs(examples) do
    local ok, v = pcall(f, ex)
    if not ok or v == nil then return nil end
    if i == 1 then first = v elseif v ~= first then return nil end
  end
  return first
end

-- Returns a list of { value = n, ty = "I" | "C" }, at most `cap`, excluding anything the policy
-- pool already provides.
function M.derive(train, have, cap)
  cap = cap or 8
  local in_sets, out_sets = {}, {}
  for _, ex in ipairs(train) do
    local a, b = {}, {}
    values_of(ex.input, a)
    values_of(ex.output, b)
    in_sets[#in_sets + 1] = a
    out_sets[#out_sets + 1] = b
  end

  local ranked = {}
  local seen = {}
  local function offer(v, rank)
    if v == nil or v ~= math.floor(v) or math.abs(v) > 1000 then return end
    if seen[v] then return end
    seen[v] = true
    ranked[#ranked + 1] = { value = v, rank = rank }
  end

  -- A value in every output but no input is the strongest signal there is: the program has to
  -- introduce it from somewhere, and a literal is the only way.
  local in_all_in, in_all_out = {}, {}
  for _, v in ipairs(intersect(in_sets)) do in_all_in[v] = true end
  for _, v in ipairs(intersect(out_sets)) do in_all_out[v] = true end
  for v in pairs(in_all_out) do if not in_all_in[v] then offer(v, 1) end end
  for v in pairs(in_all_out) do if in_all_in[v] then offer(v, 3) end end
  for v in pairs(in_all_in) do offer(v, 4) end

  -- Shapes the examples agree on: a fixed output width is a literal the program may need.
  local function dim(ex, which, side)
    local g = ex[side]
    if type(g) ~= "table" or not g.h then return nil end
    return which == "h" and g.h or g.w
  end
  offer(agreed(train, function(ex) return dim(ex, "h", "output") end), 2)
  offer(agreed(train, function(ex) return dim(ex, "w", "output") end), 2)
  offer(agreed(train, function(ex)
    local o = ex.output
    if type(o) ~= "table" or o.h then return nil end
    return #o
  end), 2)
  -- ratios between input and output size, which is how scaling factors show up
  offer(agreed(train, function(ex)
    local i, o = ex.input, ex.output
    if type(i) ~= "table" or type(o) ~= "table" or not i.h or not o.h then return nil end
    if i.h == 0 or o.h % i.h ~= 0 then return nil end
    return math.floor(o.h / i.h)
  end), 2)

  table.sort(ranked, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    return a.value < b.value
  end)

  local out = {}
  for _, e in ipairs(ranked) do
    if #out >= cap then break end
    local v = e.value
    local as_int = not (have and have.I and have.I[v])
    local as_col = v >= 0 and v <= 9 and not (have and have.C and have.C[v])
    if as_int then out[#out + 1] = { value = v, ty = "I" } end
    if as_col and #out < cap then out[#out + 1] = { value = v, ty = "C" } end
  end
  return out
end

-- Build the lookup the policy pool implies, so derived constants never duplicate it.
function M.pool_set(consts)
  local have = {}
  for ty, list in pairs(consts or {}) do
    have[ty] = {}
    for _, v in ipairs(list) do have[ty][v] = true end
  end
  return have
end

return M
  end

  -- ==== rsi/kernel/features.lua ====
  package.preload['rsi.kernel.features'] = function(...)
-- Cheap task features computed from the training examples only. Used to key the genome's
-- task-conditioned priors (a tabular stand-in for a neural recognition model).
local M = {}

local function rel(b, a)
  if b < a then return "shrink" elseif b > a then return "grow" else return "same" end
end

local function contains(input, in_type, v)
  if in_type == "L" then
    for _, x in ipairs(input) do if x == v then return true end end
    return false
  end
  for r = 1, input.h do for c = 1, input.w do if input[r][c] == v then return true end end end
  return false
end

function M.bucket(task)
  local it, ot = task.in_type, task.out_type
  local key = it .. ">" .. ot
  local ex = task.train
  if (it == "L" and ot == "L") or (it == "G" and ot == "G") then
    local r
    for _, e in ipairs(ex) do
      local a = it == "L" and #e.input or (e.input.h * e.input.w)
      local b = ot == "L" and #e.output or (e.output.h * e.output.w)
      local rr = rel(b, a)
      if r == nil then r = rr elseif r ~= rr then r = "mixed" break end
    end
    key = key .. ":" .. (r or "same")
  elseif ot == "I" or ot == "C" then
    local inside = true
    for _, e in ipairs(ex) do
      if not contains(e.input, it, e.output) then inside = false break end
    end
    key = key .. (inside and ":member" or ":derived")
  end
  return key
end

return M
  end

  -- ==== rsi/kernel/ops.lua ====
  package.preload['rsi.kernel.ops'] = function(...)
-- Value model + the full operation catalogue used by the task generators.
-- The genome's DSL (rsi/genome/dsl_base.lua) selects a *subset* of these by name;
-- ops marked hidden=true exist only in the generators, so the solver must compose to reach them.
-- Types: I=int, L=list of int, G=grid (g[r][c], g.h, g.w), B=bool, C=color (int 0..9)
local M = {}

M.MAX_LIST = 256
M.MAX_DIM = 30

local floor = math.floor

-- ---------- constructors / equality / signatures ----------
function M.grid(h, w, fill)
  local g = { h = h, w = w }
  for r = 1, h do
    local row = {}
    for c = 1, w do row[c] = fill or 0 end
    g[r] = row
  end
  return g
end

function M.copy_grid(g)
  local o = { h = g.h, w = g.w }
  for r = 1, g.h do
    local row, src = {}, g[r]
    for c = 1, g.w do row[c] = src[c] end
    o[r] = row
  end
  return o
end

function M.equal(a, b)
  local ta, tb = type(a), type(b)
  if ta ~= tb then return false end
  if ta ~= "table" then return a == b end
  if a.h then
    if not b.h or a.h ~= b.h or a.w ~= b.w then return false end
    for r = 1, a.h do
      local ra, rb = a[r], b[r]
      for c = 1, a.w do if ra[c] ~= rb[c] then return false end end
    end
    return true
  end
  if b.h or #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

function M.sig(v)
  local t = type(v)
  if t == "number" then return "I" .. v end
  if t == "boolean" then return v and "T" or "F" end
  if t ~= "table" then return "?" end
  if v.h then
    local parts = { "G", v.h, "x", v.w, ":" }
    for r = 1, v.h do parts[#parts + 1] = table.concat(v[r], ",") parts[#parts + 1] = "|" end
    return table.concat(parts)
  end
  return "L" .. table.concat(v, ",")
end

function M.show(v)
  local t = type(v)
  if t ~= "table" then return tostring(v) end
  if v.h then
    local rows = {}
    for r = 1, v.h do rows[r] = table.concat(v[r], " ") end
    return "[" .. table.concat(rows, " / ") .. "]"
  end
  return "[" .. table.concat(v, ",") .. "]"
end

function M.typeof(v)
  local t = type(v)
  if t == "number" then return "I" end
  if t == "boolean" then return "B" end
  if t == "table" then return v.h and "G" or "L" end
  return "?"
end

local function chk_list(l) if #l > M.MAX_LIST then error("list too long") end return l end
local function chk_grid(g) if g.h > M.MAX_DIM or g.w > M.MAX_DIM or g.h < 1 or g.w < 1 then error("grid dim") end return g end
local function chk_int(x)
  if x ~= x or x == math.huge or x == -math.huge or math.abs(x) > 1e9 then error("int range") end
  return x
end

-- ---------- list ops ----------
local L = {}
function L.reverse(l) local o = {} for i = #l, 1, -1 do o[#o + 1] = l[i] end return o end
function L.sort(l) local o = {} for i = 1, #l do o[i] = l[i] end table.sort(o) return o end
function L.sort_desc(l) local o = L.sort(l) return L.reverse(o) end
function L.head(l) if #l == 0 then error("empty") end return l[1] end
function L.last(l) if #l == 0 then error("empty") end return l[#l] end
function L.tail(l) local o = {} for i = 2, #l do o[#o + 1] = l[i] end return o end
function L.init(l) local o = {} for i = 1, #l - 1 do o[#o + 1] = l[i] end return o end
function L.len(l) return #l end
function L.sum(l) local s = 0 for i = 1, #l do s = s + l[i] end return s end
function L.max(l) if #l == 0 then error("empty") end local m = l[1] for i = 2, #l do if l[i] > m then m = l[i] end end return m end
function L.min(l) if #l == 0 then error("empty") end local m = l[1] for i = 2, #l do if l[i] < m then m = l[i] end end return m end
function L.map_add(l, k) local o = {} for i = 1, #l do o[i] = chk_int(l[i] + k) end return o end
function L.map_sub(l, k) local o = {} for i = 1, #l do o[i] = chk_int(l[i] - k) end return o end
function L.map_mul(l, k) local o = {} for i = 1, #l do o[i] = chk_int(l[i] * k) end return o end
function L.map_mod(l, k) if k == 0 then error("mod0") end local o = {} for i = 1, #l do o[i] = l[i] % k end return o end
function L.filter_even(l) local o = {} for i = 1, #l do if l[i] % 2 == 0 then o[#o + 1] = l[i] end end return o end
function L.filter_odd(l) local o = {} for i = 1, #l do if l[i] % 2 ~= 0 then o[#o + 1] = l[i] end end return o end
function L.filter_gt(l, k) local o = {} for i = 1, #l do if l[i] > k then o[#o + 1] = l[i] end end return o end
function L.filter_lt(l, k) local o = {} for i = 1, #l do if l[i] < k then o[#o + 1] = l[i] end end return o end
function L.take(l, k) local o = {} for i = 1, math.min(#l, math.max(k, 0)) do o[i] = l[i] end return o end
function L.drop(l, k) local o = {} for i = math.max(k, 0) + 1, #l do o[#o + 1] = l[i] end return o end
function L.rotate(l, k) local n = #l if n == 0 then return {} end local o = {} for i = 1, n do o[i] = l[((i - 1 + k) % n) + 1] end return o end
function L.concat(a, b) local o = {} for i = 1, #a do o[#o + 1] = a[i] end for i = 1, #b do o[#o + 1] = b[i] end return chk_list(o) end
function L.dedup(l) local o, seen = {}, {} for i = 1, #l do if not seen[l[i]] then seen[l[i]] = true o[#o + 1] = l[i] end end return o end
function L.cumsum(l) local o, s = {}, 0 for i = 1, #l do s = s + l[i] o[i] = s end return o end
function L.diffs(l) local o = {} for i = 2, #l do o[#o + 1] = l[i] - l[i - 1] end return o end
function L.count(l, k) local c = 0 for i = 1, #l do if l[i] == k then c = c + 1 end end return c end
function L.index_of(l, k) for i = 1, #l do if l[i] == k then return i end end return 0 end
function L.range(n) if n < 0 or n > M.MAX_LIST then error("range") end local o = {} for i = 1, n do o[i] = i end return o end
function L.singleton(x) return { x } end
function L.nth(l, k) if k < 1 or k > #l then error("oob") end return l[k] end
function L.abs_all(l) local o = {} for i = 1, #l do o[i] = math.abs(l[i]) end return o end
function L.mirror(l) return L.concat(l, L.reverse(l)) end
function L.repeat_list(l, k) local o = {} for _ = 1, math.max(k, 0) do for i = 1, #l do o[#o + 1] = l[i] end end return chk_list(o) end
function L.zip_add(a, b) if #a ~= #b then error("len") end local o = {} for i = 1, #a do o[i] = chk_int(a[i] + b[i]) end return o end
function L.evens_idx(l) local o = {} for i = 2, #l, 2 do o[#o + 1] = l[i] end return o end
function L.odds_idx(l) local o = {} for i = 1, #l, 2 do o[#o + 1] = l[i] end return o end
function L.push_front(l, x) local o = { x } for i = 1, #l do o[#o + 1] = l[i] end return chk_list(o) end
function L.push_back(l, x) local o = {} for i = 1, #l do o[#o + 1] = l[i] end o[#o + 1] = x return chk_list(o) end
function L.product(l) local p = 1 for i = 1, #l do p = chk_int(p * l[i]) end return p end
function L.unique_count(l) return #L.dedup(l) end
-- hidden-only list ops (generators use them; not in the base DSL)
function L.mode(l) if #l == 0 then error("empty") end local cnt, best, bc = {}, nil, -1 for i = 1, #l do cnt[l[i]] = (cnt[l[i]] or 0) + 1 end for i = 1, #l do local v = l[i] if cnt[v] > bc or (cnt[v] == bc and v < best) then best, bc = v, cnt[v] end end return best end
function L.second_largest(l) local d = L.sort_desc(L.dedup(l)) if #d < 2 then error("n/a") end return d[2] end
function L.median(l) if #l == 0 then error("empty") end local s = L.sort(l) return s[floor((#s + 1) / 2)] end
function L.sort_by_freq(l) local cnt = {} for i = 1, #l do cnt[l[i]] = (cnt[l[i]] or 0) + 1 end local o = {} for i = 1, #l do o[i] = l[i] end table.sort(o, function(a, b) if cnt[a] ~= cnt[b] then return cnt[a] > cnt[b] end return a < b end) return o end
function L.remove_all(l, k) local o = {} for i = 1, #l do if l[i] ~= k then o[#o + 1] = l[i] end end return o end
function L.running_max(l) local o, m = {}, nil for i = 1, #l do if not m or l[i] > m then m = l[i] end o[i] = m end return o end
function L.argmax(l) if #l == 0 then error("empty") end local bi = 1 for i = 2, #l do if l[i] > l[bi] then bi = i end end return bi end
function L.is_sorted(l) for i = 2, #l do if l[i] < l[i - 1] then return false end end return true end
function L.is_palindrome(l) for i = 1, floor(#l / 2) do if l[i] ~= l[#l + 1 - i] then return false end end return true end
function L.squares(l) local o = {} for i = 1, #l do o[i] = chk_int(l[i] * l[i]) end return o end
function L.pairwise_sums(l) local o = {} for i = 1, #l - 1 do o[#o + 1] = l[i] + l[i + 1] end return o end
function L.swap_halves(l) local n = #l local h = floor(n / 2) local o = {} for i = h + 1, n do o[#o + 1] = l[i] end for i = 1, h do o[#o + 1] = l[i] end return o end

-- ---------- int ops ----------
local I = {}
function I.add(a, b) return chk_int(a + b) end
function I.sub(a, b) return chk_int(a - b) end
function I.mul(a, b) return chk_int(a * b) end
function I.div(a, b) if b == 0 then error("div0") end return floor(a / b) end
function I.mod(a, b) if b == 0 then error("mod0") end return a % b end
function I.max2(a, b) return a > b and a or b end
function I.min2(a, b) return a < b and a or b end
function I.sq(a) return chk_int(a * a) end
function I.inc(a) return a + 1 end
function I.dec(a) return a - 1 end
function I.double(a) return chk_int(a * 2) end
function I.half(a) return floor(a / 2) end
function I.abs(a) return math.abs(a) end
function I.neg(a) return -a end
function I.is_even(a) return a % 2 == 0 end
function I.gt(a, b) return a > b end
function I.eq(a, b) return a == b end
function I.if_int(c, a, b) if c then return a else return b end end
-- hidden
function I.digit_sum(a) a = math.abs(a) local s = 0 while a > 0 do s = s + a % 10 a = floor(a / 10) end return s end
function I.triangular(a) if a < 0 or a > 30000 then error("range") end return floor(a * (a + 1) / 2) end

-- ---------- grid ops ----------
local G = {}
function G.flip_h(g) local o = { h = g.h, w = g.w } for r = 1, g.h do local row = {} for c = 1, g.w do row[c] = g[r][g.w + 1 - c] end o[r] = row end return o end
function G.flip_v(g) local o = { h = g.h, w = g.w } for r = 1, g.h do o[r] = g[g.h + 1 - r] end return M.copy_grid(o) end
function G.transpose(g) local o = { h = g.w, w = g.h } for r = 1, g.w do local row = {} for c = 1, g.h do row[c] = g[c][r] end o[r] = row end return o end
function G.rot90(g) return G.flip_h(G.transpose(g)) end
function G.rot180(g) return G.flip_h(G.flip_v(g)) end
function G.rot270(g) return G.flip_v(G.transpose(g)) end
function G.height(g) return g.h end
function G.width(g) return g.w end
function G.hcat(a, b) if a.h ~= b.h then error("h mismatch") end local o = { h = a.h, w = a.w + b.w } for r = 1, a.h do local row = {} for c = 1, a.w do row[c] = a[r][c] end for c = 1, b.w do row[a.w + c] = b[r][c] end o[r] = row end return chk_grid(o) end
function G.vcat(a, b) if a.w ~= b.w then error("w mismatch") end local o = { h = a.h + b.h, w = a.w } for r = 1, a.h do o[r] = a[r] end for r = 1, b.h do o[a.h + r] = b[r] end return chk_grid(M.copy_grid(o)) end
function G.mirror_h(g) return G.hcat(g, G.flip_h(g)) end
function G.mirror_v(g) return G.vcat(g, G.flip_v(g)) end
function G.upscale(g, k) if k < 1 or k > 5 then error("k") end local o = { h = g.h * k, w = g.w * k } chk_grid(o) for r = 1, o.h do local row = {} local src = g[floor((r - 1) / k) + 1] for c = 1, o.w do row[c] = src[floor((c - 1) / k) + 1] end o[r] = row end return o end
function G.downscale(g, k) if k < 1 or g.h % k ~= 0 or g.w % k ~= 0 then error("k") end local o = { h = g.h / k, w = g.w / k } for r = 1, o.h do local row = {} for c = 1, o.w do row[c] = g[(r - 1) * k + 1][(c - 1) * k + 1] end o[r] = row end return o end
function G.recolor(g, a, b) local o = M.copy_grid(g) for r = 1, o.h do for c = 1, o.w do if o[r][c] == a then o[r][c] = b end end end return o end
function G.fill_nonzero(g, col) local o = M.copy_grid(g) for r = 1, o.h do for c = 1, o.w do if o[r][c] ~= 0 then o[r][c] = col end end end return o end
function G.count_color(g, col) local n = 0 for r = 1, g.h do for c = 1, g.w do if g[r][c] == col then n = n + 1 end end end return n end
function G.most_color(g) local cnt = {} for r = 1, g.h do for c = 1, g.w do cnt[g[r][c]] = (cnt[g[r][c]] or 0) + 1 end end local best, bc = 0, -1 for col = 0, 9 do if (cnt[col] or 0) > bc then best, bc = col, cnt[col] or 0 end end return best end
function G.most_nonzero_color(g) local cnt = {} for r = 1, g.h do for c = 1, g.w do local v = g[r][c] if v ~= 0 then cnt[v] = (cnt[v] or 0) + 1 end end end local best, bc = 0, 0 for col = 1, 9 do if (cnt[col] or 0) > bc then best, bc = col, cnt[col] end end return best end
function G.least_nonzero_color(g) local cnt = {} for r = 1, g.h do for c = 1, g.w do local v = g[r][c] if v ~= 0 then cnt[v] = (cnt[v] or 0) + 1 end end end local best, bc = 0, math.huge for col = 1, 9 do if cnt[col] and cnt[col] < bc then best, bc = col, cnt[col] end end return best end
function G.crop_bbox(g) local r1, r2, c1, c2 = g.h + 1, 0, g.w + 1, 0 for r = 1, g.h do for c = 1, g.w do if g[r][c] ~= 0 then if r < r1 then r1 = r end if r > r2 then r2 = r end if c < c1 then c1 = c end if c > c2 then c2 = c end end end end if r2 == 0 then error("empty") end local o = { h = r2 - r1 + 1, w = c2 - c1 + 1 } for r = r1, r2 do local row = {} for c = c1, c2 do row[c - c1 + 1] = g[r][c] end o[r - r1 + 1] = row end return o end
function G.gravity_down(g) local o = M.grid(g.h, g.w, 0) for c = 1, g.w do local wr = g.h for r = g.h, 1, -1 do if g[r][c] ~= 0 then o[wr][c] = g[r][c] wr = wr - 1 end end end return o end
function G.gravity_up(g) return G.flip_v(G.gravity_down(G.flip_v(g))) end
function G.gravity_left(g) return G.transpose(G.gravity_up(G.transpose(g))) end
function G.gravity_right(g) return G.transpose(G.gravity_down(G.transpose(g))) end
function G.shift_down(g, k) local o = M.grid(g.h, g.w, 0) for r = 1, g.h do local rr = r + k if rr >= 1 and rr <= g.h then for c = 1, g.w do o[rr][c] = g[r][c] end end end return o end
function G.shift_right(g, k) local o = M.grid(g.h, g.w, 0) for r = 1, g.h do for c = 1, g.w do local cc = c + k if cc >= 1 and cc <= g.w then o[r][cc] = g[r][c] end end end return o end
function G.add_border(g, col) local o = M.grid(g.h + 2, g.w + 2, col) chk_grid(o) for r = 1, g.h do for c = 1, g.w do o[r + 1][c + 1] = g[r][c] end end return o end
function G.remove_border(g) if g.h < 3 or g.w < 3 then error("small") end local o = { h = g.h - 2, w = g.w - 2 } for r = 2, g.h - 1 do local row = {} for c = 2, g.w - 1 do row[c - 1] = g[r][c] end o[r - 1] = row end return o end
function G.top_half(g) if g.h < 2 then error("small") end local o = { h = floor(g.h / 2), w = g.w } for r = 1, o.h do o[r] = g[r] end return M.copy_grid(o) end
function G.left_half(g) return G.transpose(G.top_half(G.transpose(g))) end
function G.bottom_half(g) if g.h < 2 then error("small") end local o = { h = floor(g.h / 2), w = g.w } for r = 1, o.h do o[r] = g[g.h - o.h + r] end return M.copy_grid(o) end
function G.right_half(g) return G.transpose(G.bottom_half(G.transpose(g))) end
function G.overlay(a, b) if a.h ~= b.h or a.w ~= b.w then error("dim") end local o = M.copy_grid(a) for r = 1, a.h do for c = 1, a.w do if b[r][c] ~= 0 then o[r][c] = b[r][c] end end end return o end
function G.flatten(g) local o = {} for r = 1, g.h do for c = 1, g.w do o[#o + 1] = g[r][c] end end return chk_list(o) end
function G.row(g, k) if k < 1 or k > g.h then error("oob") end local o = {} for c = 1, g.w do o[c] = g[k][c] end return o end
function G.col(g, k) if k < 1 or k > g.w then error("oob") end local o = {} for r = 1, g.h do o[r] = g[r][k] end return o end
function G.from_row(l) if #l == 0 then error("empty") end local o = { h = 1, w = #l } o[1] = {} for i = 1, #l do o[1][i] = l[i] end return chk_grid(o) end
function G.nonzero_count(g) local n = 0 for r = 1, g.h do for c = 1, g.w do if g[r][c] ~= 0 then n = n + 1 end end end return n end
function G.const_grid(g, col) return M.grid(g.h, g.w, col) end
function G.invert_mask(g) local o = M.copy_grid(g) for r = 1, o.h do for c = 1, o.w do o[r][c] = (o[r][c] == 0) and 1 or 0 end end return o end
function G.tile2x2(g) return G.vcat(G.hcat(g, g), G.hcat(g, g)) end

-- connected components (4-neighbour, nonzero, same colour)
local function components(g)
  local seen, comps = {}, {}
  for r = 1, g.h do seen[r] = {} end
  for r = 1, g.h do for c = 1, g.w do
    if g[r][c] ~= 0 and not seen[r][c] then
      local col, stack, cells = g[r][c], { { r, c } }, {}
      seen[r][c] = true
      while #stack > 0 do
        local p = table.remove(stack)
        cells[#cells + 1] = p
        local pr, pc = p[1], p[2]
        local nb = { { pr + 1, pc }, { pr - 1, pc }, { pr, pc + 1 }, { pr, pc - 1 } }
        for _, q in ipairs(nb) do
          local qr, qc = q[1], q[2]
          if qr >= 1 and qr <= g.h and qc >= 1 and qc <= g.w and not seen[qr][qc] and g[qr][qc] == col then
            seen[qr][qc] = true
            stack[#stack + 1] = q
          end
        end
      end
      comps[#comps + 1] = { color = col, cells = cells }
    end
  end end
  return comps
end
M.components = components

local function keep_component(g, comp)
  local o = M.grid(g.h, g.w, 0)
  for _, p in ipairs(comp.cells) do o[p[1]][p[2]] = comp.color end
  return o
end
function G.object_count(g) return #components(g) end
function G.keep_largest(g) local cs = components(g) if #cs == 0 then error("none") end local best = cs[1] for i = 2, #cs do if #cs[i].cells > #best.cells then best = cs[i] end end return keep_component(g, best) end
function G.keep_smallest(g) local cs = components(g) if #cs == 0 then error("none") end local best = cs[1] for i = 2, #cs do if #cs[i].cells < #best.cells then best = cs[i] end end return keep_component(g, best) end
function G.largest_object_size(g) local cs = components(g) local m = 0 for i = 1, #cs do if #cs[i].cells > m then m = #cs[i].cells end end return m end
-- hidden-only grid ops
function G.flip_diag(g) return G.transpose(g) end
function G.outline(g) local o = M.copy_grid(g) for r = 1, g.h do for c = 1, g.w do if g[r][c] ~= 0 then local interior = r > 1 and r < g.h and c > 1 and c < g.w and g[r-1][c] ~= 0 and g[r+1][c] ~= 0 and g[r][c-1] ~= 0 and g[r][c+1] ~= 0 if interior then o[r][c] = 0 end end end end return o end
function G.color_swap_top2(g) local a, b = G.most_nonzero_color(g), G.least_nonzero_color(g) if a == b then error("same") end local o = M.copy_grid(g) for r = 1, g.h do for c = 1, g.w do if o[r][c] == a then o[r][c] = b elseif o[r][c] == b then o[r][c] = a end end end return o end
function G.row_sums(g) local o = {} for r = 1, g.h do local s = 0 for c = 1, g.w do s = s + g[r][c] end o[r] = s end return o end
function G.col_sums(g) local o = {} for c = 1, g.w do local s = 0 for r = 1, g.h do s = s + g[r][c] end o[c] = s end return o end
function G.majority_row_fill(g) local o = M.copy_grid(g) for r = 1, g.h do local m = G.most_nonzero_color(G.from_row(g[r])) for c = 1, g.w do if o[r][c] ~= 0 then o[r][c] = m end end end return o end
function G.checker_mask(g) local o = M.copy_grid(g) for r = 1, g.h do for c = 1, g.w do if (r + c) % 2 == 1 then o[r][c] = 0 end end end return o end
function G.rotate_rows(g) local o = { h = g.h, w = g.w } for r = 1, g.h do o[r] = g[(r % g.h) + 1] end return M.copy_grid(o) end

-- ---------- catalogue ----------
-- entry: name -> {f=, t={argtypes}, r=rettype, hidden=bool}
local C = {}
local function def(name, f, args, ret, hidden) C[name] = { f = f, t = args, r = ret, hidden = hidden or false } end

-- list
def("reverse", L.reverse, { "L" }, "L")   def("sort", L.sort, { "L" }, "L")   def("sort_desc", L.sort_desc, { "L" }, "L")
def("head", L.head, { "L" }, "I")         def("last", L.last, { "L" }, "I")   def("tail", L.tail, { "L" }, "L")
def("init", L.init, { "L" }, "L")         def("len", L.len, { "L" }, "I")     def("sum", L.sum, { "L" }, "I")
def("max", L.max, { "L" }, "I")           def("min", L.min, { "L" }, "I")
def("map_add", L.map_add, { "L", "I" }, "L")  def("map_sub", L.map_sub, { "L", "I" }, "L")
def("map_mul", L.map_mul, { "L", "I" }, "L")  def("map_mod", L.map_mod, { "L", "I" }, "L")
def("filter_even", L.filter_even, { "L" }, "L")  def("filter_odd", L.filter_odd, { "L" }, "L")
def("filter_gt", L.filter_gt, { "L", "I" }, "L") def("filter_lt", L.filter_lt, { "L", "I" }, "L")
def("take", L.take, { "L", "I" }, "L")    def("drop", L.drop, { "L", "I" }, "L")   def("rotate", L.rotate, { "L", "I" }, "L")
def("concat", L.concat, { "L", "L" }, "L") def("dedup", L.dedup, { "L" }, "L")    def("cumsum", L.cumsum, { "L" }, "L")
def("diffs", L.diffs, { "L" }, "L")       def("count", L.count, { "L", "I" }, "I") def("index_of", L.index_of, { "L", "I" }, "I")
def("range", L.range, { "I" }, "L")       def("singleton", L.singleton, { "I" }, "L") def("nth", L.nth, { "L", "I" }, "I")
def("abs_all", L.abs_all, { "L" }, "L")   def("mirror", L.mirror, { "L" }, "L")  def("repeat_list", L.repeat_list, { "L", "I" }, "L")
def("zip_add", L.zip_add, { "L", "L" }, "L") def("evens_idx", L.evens_idx, { "L" }, "L") def("odds_idx", L.odds_idx, { "L" }, "L")
def("push_front", L.push_front, { "L", "I" }, "L") def("push_back", L.push_back, { "L", "I" }, "L")
def("product", L.product, { "L" }, "I")   def("unique_count", L.unique_count, { "L" }, "I")
def("mode", L.mode, { "L" }, "I", true)   def("second_largest", L.second_largest, { "L" }, "I", true)
def("median", L.median, { "L" }, "I", true) def("sort_by_freq", L.sort_by_freq, { "L" }, "L", true)
def("remove_all", L.remove_all, { "L", "I" }, "L", true) def("running_max", L.running_max, { "L" }, "L", true)
def("argmax", L.argmax, { "L" }, "I", true) def("is_sorted", L.is_sorted, { "L" }, "B", true)
def("is_palindrome", L.is_palindrome, { "L" }, "B", true) def("squares", L.squares, { "L" }, "L", true)
def("pairwise_sums", L.pairwise_sums, { "L" }, "L", true) def("swap_halves", L.swap_halves, { "L" }, "L", true)
-- int
def("add", I.add, { "I", "I" }, "I")  def("sub", I.sub, { "I", "I" }, "I")  def("mul", I.mul, { "I", "I" }, "I")
def("div", I.div, { "I", "I" }, "I")  def("mod", I.mod, { "I", "I" }, "I")  def("max2", I.max2, { "I", "I" }, "I")
def("min2", I.min2, { "I", "I" }, "I") def("sq", I.sq, { "I" }, "I")       def("inc", I.inc, { "I" }, "I")
def("dec", I.dec, { "I" }, "I")       def("double", I.double, { "I" }, "I") def("half", I.half, { "I" }, "I")
def("abs", I.abs, { "I" }, "I")       def("neg", I.neg, { "I" }, "I")
def("is_even", I.is_even, { "I" }, "B") def("gt", I.gt, { "I", "I" }, "B") def("eq", I.eq, { "I", "I" }, "B")
def("if_int", I.if_int, { "B", "I", "I" }, "I")
def("digit_sum", I.digit_sum, { "I" }, "I", true) def("triangular", I.triangular, { "I" }, "I", true)
-- grid
def("flip_h", G.flip_h, { "G" }, "G")  def("flip_v", G.flip_v, { "G" }, "G")  def("transpose", G.transpose, { "G" }, "G")
def("rot90", G.rot90, { "G" }, "G")    def("rot180", G.rot180, { "G" }, "G")  def("rot270", G.rot270, { "G" }, "G")
def("height", G.height, { "G" }, "I")  def("width", G.width, { "G" }, "I")
def("hcat", G.hcat, { "G", "G" }, "G") def("vcat", G.vcat, { "G", "G" }, "G")
def("mirror_h", G.mirror_h, { "G" }, "G") def("mirror_v", G.mirror_v, { "G" }, "G")
def("upscale", G.upscale, { "G", "I" }, "G") def("downscale", G.downscale, { "G", "I" }, "G")
def("recolor", G.recolor, { "G", "C", "C" }, "G") def("fill_nonzero", G.fill_nonzero, { "G", "C" }, "G")
def("count_color", G.count_color, { "G", "C" }, "I") def("most_color", G.most_color, { "G" }, "C")
def("most_nonzero_color", G.most_nonzero_color, { "G" }, "C") def("least_nonzero_color", G.least_nonzero_color, { "G" }, "C")
def("crop_bbox", G.crop_bbox, { "G" }, "G")
def("gravity_down", G.gravity_down, { "G" }, "G") def("gravity_up", G.gravity_up, { "G" }, "G")
def("gravity_left", G.gravity_left, { "G" }, "G") def("gravity_right", G.gravity_right, { "G" }, "G")
def("shift_down", G.shift_down, { "G", "I" }, "G") def("shift_right", G.shift_right, { "G", "I" }, "G")
def("add_border", G.add_border, { "G", "C" }, "G") def("remove_border", G.remove_border, { "G" }, "G")
def("top_half", G.top_half, { "G" }, "G") def("bottom_half", G.bottom_half, { "G" }, "G")
def("left_half", G.left_half, { "G" }, "G") def("right_half", G.right_half, { "G" }, "G")
def("overlay", G.overlay, { "G", "G" }, "G") def("flatten", G.flatten, { "G" }, "L")
def("row", G.row, { "G", "I" }, "L")   def("col", G.col, { "G", "I" }, "L")  def("from_row", G.from_row, { "L" }, "G")
def("nonzero_count", G.nonzero_count, { "G" }, "I") def("const_grid", G.const_grid, { "G", "C" }, "G")
def("invert_mask", G.invert_mask, { "G" }, "G") def("tile2x2", G.tile2x2, { "G" }, "G")
def("object_count", G.object_count, { "G" }, "I") def("keep_largest", G.keep_largest, { "G" }, "G")
def("keep_smallest", G.keep_smallest, { "G" }, "G") def("largest_object_size", G.largest_object_size, { "G" }, "I")
def("outline", G.outline, { "G" }, "G", true) def("color_swap_top2", G.color_swap_top2, { "G" }, "G", true)
def("row_sums", G.row_sums, { "G" }, "L", true) def("col_sums", G.col_sums, { "G" }, "L", true)
def("majority_row_fill", G.majority_row_fill, { "G" }, "G", true) def("checker_mask", G.checker_mask, { "G" }, "G", true)
def("rotate_rows", G.rotate_rows, { "G" }, "G", true)

M.catalogue = C
M.L, M.I, M.G = L, I, G
return M
  end

  -- ==== rsi/kernel/program.lua ====
  package.preload['rsi.kernel.program'] = function(...)
-- Program trees: {op=name,args={...}} | {var=true} | {var2=true} | {const=v, ty="I"|"C"}
-- Text form: op(a,b) | $ (first parameter) | @ (second parameter of a learned abstraction) | 3 | #3
local M = {}

function M.var() return { var = true } end
function M.var2() return { var2 = true } end
function M.const(v, ty) return { const = v, ty = ty or "I" } end
function M.node(op, args) return { op = op, args = args } end

function M.to_string(n)
  if n.var then return "$" end
  if n.var2 then return "@" end
  if n.const ~= nil then return (n.ty == "C" and "#" or "") .. tostring(n.const) end
  local parts = {}
  for i, a in ipairs(n.args) do parts[i] = M.to_string(a) end
  return n.op .. "(" .. table.concat(parts, ",") .. ")"
end

local function parse_at(s, i)
  local c = s:sub(i, i)
  if c == "$" then return M.var(), i + 1 end
  if c == "@" then return M.var2(), i + 1 end
  if c == "#" then
    local d = s:match("^%d+", i + 1)
    if not d then error("bad colour const at " .. i) end
    return M.const(tonumber(d), "C"), i + 1 + #d
  end
  local num = s:match("^%-?%d+", i)
  if num then return M.const(tonumber(num), "I"), i + #num end
  local name = s:match("^[%a_][%w_]*", i)
  if not name then error("parse error at " .. i .. " in " .. s) end
  i = i + #name
  if s:sub(i, i) ~= "(" then error("expected ( after " .. name) end
  i = i + 1
  local args = {}
  if s:sub(i, i) == ")" then return M.node(name, args), i + 1 end
  while true do
    local a
    a, i = parse_at(s, i)
    args[#args + 1] = a
    local d = s:sub(i, i)
    if d == ")" then return M.node(name, args), i + 1 end
    if d ~= "," then error("expected , or ) at " .. i .. " in " .. s) end
    i = i + 1
  end
end

function M.parse(s)
  local n, i = parse_at(s:gsub("%s", ""), 1)
  return n
end

-- Compile to a closure over the input using a prim table name -> {f=...}
function M.compile(n, prims)
  if n.var then return function(x) return x end end
  if n.var2 then return function(_, y) return y end end
  if n.const ~= nil then local v = n.const return function() return v end end
  local p = prims[n.op]
  if not p then error("unknown op " .. n.op) end
  local f = p.f
  local k = #n.args
  local cs = {}
  for i = 1, k do cs[i] = M.compile(n.args[i], prims) end
  if k == 1 then local a = cs[1] return function(x, y) return f(a(x, y)) end end
  if k == 2 then local a, b = cs[1], cs[2] return function(x, y) return f(a(x, y), b(x, y)) end end
  if k == 3 then local a, b, c = cs[1], cs[2], cs[3] return function(x, y) return f(a(x, y), b(x, y), c(x, y)) end end
  return function(x, y)
    local vals = {}
    for i = 1, k do vals[i] = cs[i](x, y) end
    return f((table.unpack or unpack)(vals, 1, k))
  end
end

function M.size(n)
  if n.var or n.var2 or n.const ~= nil then return 1 end
  local s = 1
  for _, a in ipairs(n.args) do s = s + M.size(a) end
  return s
end

function M.ops_used(n, acc)
  acc = acc or {}
  if n.op then
    acc[#acc + 1] = n.op
    for _, a in ipairs(n.args) do M.ops_used(a, acc) end
  end
  return acc
end

function M.uses_var(n)
  if n.var then return true end
  if n.var2 or n.const ~= nil then return false end
  for _, a in ipairs(n.args) do if M.uses_var(a) then return true end end
  return false
end

-- all subtrees that are op nodes and contain the input variable
function M.subtrees(n, acc)
  acc = acc or {}
  if n.op then
    if M.uses_var(n) then acc[#acc + 1] = n end
    for _, a in ipairs(n.args) do M.subtrees(a, acc) end
  end
  return acc
end

function M.ret_type(n, prims, in_type)
  if n.var then return in_type end
  if n.var2 then return n.ty2 end
  if n.const ~= nil then return n.ty end
  local p = prims[n.op]
  return p and p.r or "?"
end

function M.clone(n)
  if n.var then return M.var() end
  if n.var2 then return M.var2() end
  if n.const ~= nil then return M.const(n.const, n.ty) end
  local args = {}
  for i, a in ipairs(n.args) do args[i] = M.clone(a) end
  return M.node(n.op, args)
end

return M
  end

  -- ==== rsi/kernel/stats.lua ====
  package.preload['rsi.kernel.stats'] = function(...)
-- Statistics for the acceptance rule: paired bootstrap, sign test, Wilson interval.
local RNG = require("rsi.kernel.rng")
local M = {}

function M.mean(t)
  if #t == 0 then return 0 end
  local s = 0
  for i = 1, #t do s = s + t[i] end
  return s / #t
end

-- Wilson score interval for a proportion
function M.wilson(k, n, z)
  z = z or 1.96
  if n == 0 then return 0, 0, 0 end
  local p = k / n
  local den = 1 + z * z / n
  local centre = (p + z * z / (2 * n)) / den
  local half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / den
  return p, math.max(0, centre - half), math.min(1, centre + half)
end

-- Paired bootstrap on per-item differences d_i = b_i - a_i.
-- Returns mean diff, one-sided p-value P(diff <= 0), and 95% CI (lo, hi).
function M.paired_bootstrap(a, b, reps, seed)
  reps = reps or 2000
  local n = #a
  if n == 0 then return 0, 1, 0, 0 end
  local d = {}
  for i = 1, n do d[i] = (b[i] or 0) - (a[i] or 0) end
  local rng = RNG.new(seed or 12345)
  local means = {}
  local le = 0
  for r = 1, reps do
    local s = 0
    for _ = 1, n do s = s + d[rng:int(n)] end
    local m = s / n
    means[r] = m
    if m <= 0 then le = le + 1 end
  end
  table.sort(means)
  local lo = means[math.max(1, math.floor(reps * 0.025))]
  local hi = means[math.min(reps, math.ceil(reps * 0.975))]
  return M.mean(d), le / reps, lo, hi
end

-- Exact one-sided sign test on wins vs losses (ties dropped): P(X >= wins | Binomial(w+l, 0.5))
function M.sign_test(wins, losses)
  local n = wins + losses
  if n == 0 then return 1 end
  local p = 0
  local logc = 0
  for k = 0, n do
    if k > 0 then logc = logc + math.log(n - k + 1) - math.log(k) end
    if k >= wins then p = p + math.exp(logc - n * math.log(2)) end
  end
  return math.min(1, p)
end

function M.wins_losses(a, b)
  local w, l = 0, 0
  for i = 1, #a do
    if b[i] > a[i] then w = w + 1 elseif b[i] < a[i] then l = l + 1 end
  end
  return w, l
end

return M
  end

  -- ==== rsi/kernel/mechanisms.lua ====
  package.preload['rsi.kernel.mechanisms'] = function(...)
-- The registry of what this system's reasoning is built from, what it tried and threw away, and what
-- it has never had.
--
-- Its purpose is to make the paper feed useful without pretending to comprehension. There is no
-- language model here, so nothing can read a paper and derive a mechanism from it. What the registry
-- makes possible is narrower and still worth having: an abstract can be matched against a declared
-- list of mechanisms, and a paper that touches something in `gaps` is more likely to be worth a
-- human's attention than one describing what is already implemented. That is keyword matching against
-- an explicit gap list. It is not understanding, and the ranking says so on the console.
--
-- The honest value of this file is mostly the second field. `rejected` records mechanisms that were
-- implemented, measured, and found not to pay, with the numbers. Without it the system would happily
-- rediscover and re-propose the same losing ideas, and a reader would have no way to tell an untried
-- idea from a tried one.
local M = {}

M.implemented = {
  { name = "bottom-up enumeration", keys = { "bottom-up", "enumerative synthesis", "enumeration" },
    where = "rsi/genome/search.lua" },
  { name = "observational equivalence", keys = { "observational equivalence", "equivalence reduction" },
    where = "rsi/genome/search.lua: OE dedup on value tuples" },
  { name = "cost-guided search", keys = { "cost-guided", "weighted enumeration", "size-based enumeration" },
    where = "rsi/genome/search.lua: integer cost levels" },
  { name = "just-in-time weight learning", keys = { "just-in-time", "probe", "guided enumeration" },
    where = "rsi/genome/search.lua: partial-match cost decay (Barke et al.)" },
  { name = "library learning", keys = { "library learning", "dreamcoder", "abstraction learning", "compression" },
    where = "rsi/kernel/mutate.lua: library_learn" },
  { name = "anti-unification", keys = { "anti-unification", "antiunification", "stitch", "version space" },
    where = "rsi/kernel/mutate.lua: parameterized_abstraction" },
  { name = "inverse semantics", keys = { "inverse semantics", "witness function", "deductive synthesis", "flashfill", "inverse function" },
    where = "rsi/kernel/inverses.lua" },
  { name = "bidirectional search", keys = { "bidirectional", "meet in the middle", "meet-in-the-middle", "backward search" },
    where = "rsi/genome/search.lua: backward bank" },
  { name = "angelic / component-based synthesis", keys = { "angelic", "component-based synthesis", "argument deduction" },
    where = "rsi/genome/search.lua: binary_meet" },
  { name = "task-conditioned priors", keys = { "recognition model", "conditional prior", "amortized inference", "task embedding" },
    where = "rsi/kernel/mutate.lua: fit_conditional_priors" },
  { name = "algorithm portfolio", keys = { "portfolio", "algorithm selection", "restart strategy" },
    where = "rsi/genome/search.lua: two_phase" },
  { name = "automatic curriculum", keys = { "curriculum", "task generation", "self-play", "procedural generation" },
    where = "rsi/kernel/benchmarks.lua: variant spawning" },
  { name = "grounded natural-language report", keys = { "grounded generation", "data-to-text", "template generation", "faithfulness", "hallucination" },
    where = "rsi/kernel/narrator.lua: procedural, audited, NOT a language model" },
}

-- Measured and discarded. Each entry carries the number that killed it, so it is not re-proposed.
M.rejected = {
  { name = "hard operator whitelist", evidence = "-1.7pp on 300 tasks: 10 wins from the depth it buys, 15 losses from excluding operators the task needed" },
  { name = "unconditional library additions", evidence = "-2.7pp for 8 abstractions; every extra primitive widens branching at every level. Bucket-scoping recovered 2pp of that" },
  { name = "wider constant pool", evidence = "-3.5pp adding integers 4..9" },
  { name = "task-derived constants", evidence = "0.0pp on 300 mixed and 0.0pp on 180 large-value tasks; 86% of tasks derive nothing because generated values are already pooled. Retained but off" },
  { name = "binary meet replay", evidence = "+0.3pp, 1 win 0 losses, p=0.37. Real but not evidence. Off" },
  { name = "deeper cost ceiling", evidence = "max_cost 9 to 24 gave bit-for-bit identical results; the ceiling never binds" },
  { name = "bigger banks", evidence = "bank_cap 350 to 900 and back_cap 400 to 1200 both exactly flat" },
  { name = "more search budget", evidence = "13x the node budget (1500 to 20000) bought only +4.4pp; the remaining failures are reach-limited, not ordering-limited" },
}

-- Never implemented here. This is what the paper feed is ranked against.
M.gaps = {
  { name = "e-graphs / equality saturation", keys = { "e-graph", "egraph", "equality saturation", "rewrite rules" },
    note = "could collapse the redundant forward bank far harder than value-tuple dedup does" },
  { name = "conflict-driven learning", keys = { "conflict-driven", "cdcl", "clause learning", "nogood" },
    note = "the search currently learns nothing from a dead end beyond a cost tweak" },
  { name = "sketch-based synthesis", keys = { "sketch", "hole", "template", "partial program" },
    note = "top-down expansion with holes explores a different order than bottom-up banks" },
  { name = "constraint propagation / SMT", keys = { "smt", "constraint solving", "z3", "satisfiability modulo" },
    note = "would let arguments be solved for rather than enumerated" },
  { name = "type-directed / bidirectional typing", keys = { "type-directed", "bidirectional typing", "refinement type" },
    note = "prune branches that cannot reach the goal type within the remaining budget" },
  { name = "Monte Carlo tree search", keys = { "monte carlo tree", "mcts", "best-first search", "a* search" },
    note = "an ordering policy over the enumeration, which uniform cost levels currently lack" },
  { name = "abstraction refinement", keys = { "abstraction refinement", "cegar", "counterexample-guided" },
    note = "use a failing example to refine the search space rather than restart" },
  { name = "test-time compute scaling", keys = { "test-time", "inference-time", "repeated sampling", "budget forcing" },
    note = "measured here as weak: 13x budget bought 4.4pp, so scaling compute is not the lever" },
  { name = "neural guidance", keys = { "neural guided", "neural-guided", "learned policy", "transformer", "language model" },
    note = "EXCLUDED BY DESIGN: this system uses no learned model, by requirement" },
  { name = "program merging / multi-program", keys = { "program merging", "ensembles of programs", "disjunctive" },
    note = "combine partially-correct programs instead of discarding them" },
}

-- Score a piece of text against the registry. Returns matched gap names, matched implemented names,
-- and an actionability score: a paper touching something absent scores above one describing what is
-- already here. Excluded-by-design gaps score zero.
function M.score(text)
  local lower = text:lower()
  local gaps, known, note = {}, {}, nil
  for _, g in ipairs(M.gaps) do
    for _, k in ipairs(g.keys) do
      if lower:find(k, 1, true) then
        gaps[#gaps + 1] = g.name
        if not note then note = g.note end
        break
      end
    end
  end
  for _, e in ipairs(M.implemented) do
    for _, k in ipairs(e.keys) do
      if lower:find(k, 1, true) then
        known[#known + 1] = e.name
        break
      end
    end
  end
  local excluded = false
  for _, g in ipairs(gaps) do if g == "neural guidance" then excluded = true end end
  local score = 0
  if not excluded then score = 2 * #gaps + (#known > 0 and 1 or 0) end
  return score, gaps, known, note
end

function M.gap_names()
  local out = {}
  for _, g in ipairs(M.gaps) do
    if g.name ~= "neural guidance" then out[#out + 1] = g.name end
  end
  return out
end

return M
  end

  -- ==== rsi/kernel/inverses.lua ====
  package.preload['rsi.kernel.inverses'] = function(...)
-- Inverse semantics: for an operator f and a desired output o, a *candidate* preimage x with f(x)=o.
--
-- Why this exists. Bottom-up enumeration is blind: it builds every program of cost c and asks whether
-- any of them happens to hit the target. The node budget is spent on breadth, and the measured
-- bottleneck of this system is branching factor, not depth. Inverting the goal turns the outermost
-- operators from things to be *guessed* into things to be *deduced*: if the task's output is a
-- 90-degree rotation of something, then rotating the output back by 90 degrees says exactly what the
-- rest of the program has to produce. A depth-4 search becomes a depth-2 forward search meeting a
-- depth-2 backward chain.
--
-- Candidates are never trusted. The caller applies f to the candidate and keeps it only if the result
-- equals o on every training example. That makes a wrong or partial rule harmless (it is simply
-- rejected) and lets these rules be liberal: `shift_down` is not injective, but shifting the output
-- back up produces a preimage that verifies exactly when nothing was pushed off the edge, which is
-- the case that matters.
--
-- Only value-changing operators are listed. An idempotent operator (sort, gravity, crop_bbox) inverts
-- to the identity when the target is already a fixed point, which produces a backward entry with the
-- same value and type as one already present, so it is deduplicated away and buys nothing.
local ops = require("rsi.kernel.ops")
local L, G = ops.L, ops.G
local floor = math.floor
local M = {}

-- inv1[name](o) -> candidate preimage, or nil when this output cannot have come from this operator.
M.inv1 = {
  -- list
  reverse = function(o) return L.reverse(o) end,
  cumsum = function(o)
    local x = {}
    for i = 1, #o do x[i] = (i == 1) and o[1] or (o[i] - o[i - 1]) end
    return x
  end,
  mirror = function(o)
    local m = #o
    if m == 0 or m % 2 ~= 0 then return nil end
    local x = {}
    for i = 1, floor(m / 2) do x[i] = o[i] end
    return x
  end,
  singleton = function(o) if #o == 1 then return o[1] end return nil end,
  range = function(o) return #o end,
  from_row = function(o) if o.h == 1 then return G.row(o, 1) end return nil end,
  -- int
  inc = function(o) return o - 1 end,
  dec = function(o) return o + 1 end,
  neg = function(o) return -o end,
  double = function(o) if o % 2 == 0 then return floor(o / 2) end return nil end,
  sq = function(o)
    if o < 0 then return nil end
    local r = floor(math.sqrt(o) + 0.5)
    if r * r == o then return r end
    return nil
  end,
  -- grid: the structural transformations, which are exactly the ones that make grid tasks deep
  flip_h = function(o) return G.flip_h(o) end,
  flip_v = function(o) return G.flip_v(o) end,
  transpose = function(o) return G.transpose(o) end,
  rot90 = function(o) return G.rot270(o) end,
  rot180 = function(o) return G.rot180(o) end,
  rot270 = function(o) return G.rot90(o) end,
  mirror_h = function(o) if o.w % 2 ~= 0 then return nil end return G.left_half(o) end,
  mirror_v = function(o) if o.h % 2 ~= 0 then return nil end return G.top_half(o) end,
  tile2x2 = function(o)
    if o.h % 2 ~= 0 or o.w % 2 ~= 0 then return nil end
    return G.left_half(G.top_half(o))
  end,
  invert_mask = function(o) return G.invert_mask(o) end,
  remove_border = function(o) return G.add_border(o, 0) end,
}

-- inv2[name](o, k) -> candidate preimage for the FIRST argument, with the second argument fixed to
-- the constant k drawn from the policy's constant pool for that argument's type.
M.inv2 = {
  -- list
  map_add = function(o, k) return L.map_sub(o, k) end,
  map_sub = function(o, k) return L.map_add(o, k) end,
  map_mul = function(o, k)
    if k == 0 then return nil end
    local x = {}
    for i = 1, #o do
      if o[i] % k ~= 0 then return nil end
      x[i] = floor(o[i] / k)
    end
    return x
  end,
  rotate = function(o, k) return L.rotate(o, -k) end,
  push_front = function(o, x) if #o >= 1 and o[1] == x then return L.tail(o) end return nil end,
  push_back = function(o, x) if #o >= 1 and o[#o] == x then return L.init(o) end return nil end,
  repeat_list = function(o, k)
    if k < 1 or #o == 0 or #o % k ~= 0 then return nil end
    local x = {}
    for i = 1, floor(#o / k) do x[i] = o[i] end
    return x
  end,
  -- int
  add = function(o, k) return o - k end,
  sub = function(o, k) return o + k end,
  mul = function(o, k)
    if k == 0 or o % k ~= 0 then return nil end
    return floor(o / k)
  end,
  -- grid
  upscale = function(o, k)
    if k < 1 or o.h % k ~= 0 or o.w % k ~= 0 then return nil end
    return G.downscale(o, k)
  end,
  downscale = function(o, k)
    if k < 1 or k > 5 then return nil end
    return G.upscale(o, k)
  end,
  add_border = function(o, c)
    if o.h < 3 or o.w < 3 then return nil end
    return G.remove_border(o)
  end,
  shift_down = function(o, k) return G.shift_down(o, -k) end,
  shift_right = function(o, k) return G.shift_right(o, -k) end,
}

-- Binary meet. For an operator of two non-constant arguments, one argument taken from the forward
-- bank determines what the other must be: if the target is a wide grid and the left part is
-- something the search already knows how to build, the right part is fully determined. These rules
-- are also candidates only, and are verified forward exactly like the others.
local function grid_cols(g, c1, c2)
  if c1 > c2 or c1 < 1 or c2 > g.w then return nil end
  local o = { h = g.h, w = c2 - c1 + 1 }
  for r = 1, g.h do
    local row = {}
    for c = c1, c2 do row[c - c1 + 1] = g[r][c] end
    o[r] = row
  end
  return o
end

local function grid_rows(g, r1, r2)
  if r1 > r2 or r1 < 1 or r2 > g.h then return nil end
  local o = { h = r2 - r1 + 1, w = g.w }
  for r = r1, r2 do
    local row = {}
    for c = 1, g.w do row[c] = g[r][c] end
    o[r - r1 + 1] = row
  end
  return o
end

-- inv_arg2[name](o, a) -> the second argument b such that f(a, b) = o
M.inv_arg2 = {
  hcat = function(o, a) if o.h ~= a.h or a.w >= o.w then return nil end return grid_cols(o, a.w + 1, o.w) end,
  vcat = function(o, a) if o.w ~= a.w or a.h >= o.h then return nil end return grid_rows(o, a.h + 1, o.h) end,
  concat = function(o, a)
    if #a >= #o then return nil end
    local b = {}
    for i = #a + 1, #o do b[#b + 1] = o[i] end
    return b
  end,
  zip_add = function(o, a)
    if #o ~= #a then return nil end
    local b = {}
    for i = 1, #o do b[i] = o[i] - a[i] end
    return b
  end,
  -- overlay takes b's non-zero cells over a, so where the target already agrees with a the second
  -- argument may be zero, and where it differs it is pinned to the target
  overlay = function(o, a)
    if o.h ~= a.h or o.w ~= a.w then return nil end
    local b = ops.grid(o.h, o.w, 0)
    for r = 1, o.h do
      for c = 1, o.w do if o[r][c] ~= a[r][c] then b[r][c] = o[r][c] end end
    end
    return b
  end,
}

-- inv_arg1[name](o, b) -> the first argument a such that f(a, b) = o
M.inv_arg1 = {
  hcat = function(o, b) if o.h ~= b.h or b.w >= o.w then return nil end return grid_cols(o, 1, o.w - b.w) end,
  vcat = function(o, b) if o.w ~= b.w or b.h >= o.h then return nil end return grid_rows(o, 1, o.h - b.h) end,
  concat = function(o, b)
    if #b >= #o then return nil end
    local a = {}
    for i = 1, #o - #b do a[i] = o[i] end
    return a
  end,
  zip_add = function(o, b)
    if #o ~= #b then return nil end
    local a = {}
    for i = 1, #o do a[i] = o[i] - b[i] end
    return a
  end,
  overlay = function(o, b)
    if o.h ~= b.h or o.w ~= b.w then return nil end
    local a = ops.copy_grid(o)
    for r = 1, o.h do
      for c = 1, o.w do if b[r][c] ~= 0 then a[r][c] = 0 end end
    end
    return a
  end,
}

function M.count()
  local a, b = 0, 0
  for _ in pairs(M.inv1) do a = a + 1 end
  for _ in pairs(M.inv2) do b = b + 1 end
  return a, b
end

return M
  end

  -- ==== rsi/kernel/dashboard.lua ====
  package.preload['rsi.kernel.dashboard'] = function(...)
-- Writes www/state.json, www/progress.json and the static www/index.html research console.
-- The indicator on the page is the champion's held-out solve rate with a Wilson 95% interval;
-- it only moves when a candidate has passed the kernel's acceptance rule.
local json = require("rsi.kernel.json")
local M = {}

M.HTML_VERSION = 3

function M.write_progress(root, p)
  p.time = os.time()
  json.write(root .. "/www/progress.json", p)
end

function M.write_state(root, s)
  s.time = os.time()
  json.write(root .. "/www/state.json", s)
end

local HTML = [==[<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>CELL4 RSI console</title>
<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow">
<style>
:root{--bg:#0b0e11;--panel:#12171c;--ink:#e6edf3;--mute:#8b98a5;--ok:#3fb950;--bad:#f85149;--warn:#d29922;--acc:#58a6ff;--line:#22282f}
body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
header{padding:18px 24px;border-bottom:1px solid var(--line);display:flex;justify-content:space-between;align-items:baseline;flex-wrap:wrap;gap:8px}
h1{margin:0;font-size:16px;letter-spacing:.08em;text-transform:uppercase}
main{display:grid;grid-template-columns:repeat(auto-fit,minmax(340px,1fr));gap:14px;padding:14px 24px}
section{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:14px;min-width:0;overflow:auto}
h2{margin:0 0 10px;font-size:12px;color:var(--mute);letter-spacing:.1em;text-transform:uppercase}
.big{font-size:44px;font-weight:600;line-height:1}
.ci{color:var(--mute)} .ok{color:var(--ok)} .bad{color:var(--bad)} .warn{color:var(--warn)} .acc{color:var(--acc)}
table{border-collapse:collapse;width:100%} td,th{padding:4px 6px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top;font-size:12px}
th{color:var(--mute);font-weight:normal}
.bar{height:8px;background:#1c2430;border-radius:4px;overflow:hidden;margin-top:6px}.bar i{display:block;height:100%;background:var(--acc)}
svg{width:100%;height:220px;display:block} .wide{grid-column:1/-1}
.kv{display:grid;grid-template-columns:auto 1fr;gap:2px 12px} .kv b{color:var(--mute);font-weight:normal}
small{color:var(--mute)} ul{margin:0;padding-left:18px}
</style></head><body>
<header><h1>CELL4 &middot; recursive self-improvement console</h1><div id="hdr"><small>loading&hellip;</small></div></header>
<main>
<section><h2>Champion &middot; held-out solve rate</h2><div class="big" id="score">&ndash;</div><div class="ci" id="score_ci"></div>
<div class="kv" id="champ_kv" style="margin-top:10px"></div></section>
<section><h2>Live activity</h2><div id="phase">idle</div><div class="bar"><i id="pbar" style="width:0%"></i></div><div id="ptext" class="ci"></div>
<div class="kv" id="live_kv" style="margin-top:10px"></div></section>
<section><h2>Benchmarks</h2><div class="kv" id="bench_kv"></div></section>
<section class="wide"><h2>Champion held-out score by generation (accepted &#9679; rejected &#215; candidates)</h2><svg id="chart" viewBox="0 0 1000 220" preserveAspectRatio="none"></svg></section>
<section class="wide"><h2>Lineage (latest first)</h2><table><thead><tr><th>gen</th><th>operator</th><th>change</th><th>held-out &Delta;</th><th>p</th><th>adv &Delta;</th><th>regr</th><th>verdict</th></tr></thead><tbody id="lineage"></tbody></table></section>
<section class="wide"><h2>What is worth being challenged by</h2><table><thead><tr><th>family</th><th>n</th><th>solved</th><th>information</th><th>discrim</th><th>headroom</th><th>score</th></tr></thead><tbody id="challenge"></tbody></table>
<div id="saturated" class="ci" style="margin-top:8px"></div></section>
<section><h2>Research feed &middot; ranked by gap, not date</h2><div id="research"></div></section>
<section><h2>Learned library (champion)</h2><div id="lib"></div></section>
<section class="wide"><h2>What is real here / what is not</h2><ul>
<li>The score is the champion's solve rate on tasks generated from a <b>secret salt the genome never sees</b>; a solve requires the found program to be correct on a held-out test example of the task, not just the training pairs.</li>
<li>A candidate is retained only if its paired held-out gain is significant under <b>both</b> the bootstrap and the exact sign test (&alpha;=0.05 each; either test alone lets through a 3-win, 0-loss candidate that is not real evidence), it loses nothing on the regression suite, it does not drop on the fresh adversarial split, and its visible-split gain is not out of proportion to its held-out gain (overfit check).</li>
<li>Candidates are produced by operators that use the system's own experimental data: library learning from solved programs, near-miss abstraction, prior fitting, enumeration reordering, constant and hyperparameter changes, DSL pruning. Operator selection adapts to which operators have produced accepted candidates.</li>
<li>Internet research pulls fresh ARC tasks into the external, never-trained-on evaluation, and ranks arXiv abstracts against <code>rsi/kernel/mechanisms.lua</code> &mdash; what is implemented, what was measured and discarded, and what has never been built. A paper touching a declared gap outranks one restating existing machinery. <b>This is keyword matching against an explicit list, not comprehension: no language model is used anywhere</b>, so the system cannot read a paper and derive a mechanism from it. That is a fundamental limit of an LLM-free design, stated rather than hidden.</li>
<li>The challenge table is computed from the system's own runs. <code>information</code> is 4p(1-p) on the solve rate, peaking where a family is solved about half the time; <code>discrim</code> is how often candidates actually differ from the champion there, which is the benchmark's power to detect an improvement at all. A family solved 0% of the time scores low on purpose: difficulty alone is not the objective, distinguishing improvement from noise is. The four components are measured; the weights that combine them are a declared convention in <code>rsi/config.lua</code>.</li>
<li>Held-out seeds rotate and harder family variants are spawned automatically when one family drives repeated acceptances.</li>
</ul></section>
</main>
<script>
const $=id=>document.getElementById(id);
const pct=x=>(100*x).toFixed(1)+'%';
const esc=s=>String(s).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
async function load(){
  try{
    const s=await (await fetch('state.json?'+Date.now())).json();
    let p={};try{p=await (await fetch('progress.json?'+Date.now())).json();}catch(e){}
    let lines=[];try{const t=await (await fetch('lineage.jsonl?'+Date.now())).text();lines=t.trim().split('\n').filter(Boolean).map(l=>{try{return JSON.parse(l)}catch(e){return null}}).filter(Boolean);}catch(e){}
    render(s,p,lines);
  }catch(e){$('hdr').innerHTML='<small class="bad">state.json unavailable: '+esc(e)+'</small>';}
}
function render(s,p,lines){
  const age=Math.round(Date.now()/1000-s.time);
  $('hdr').innerHTML='<small>generation <b>'+s.gen+'</b> &middot; champion <b>'+esc(s.champion.fingerprint)+'</b> &middot; state age '+age+'s'+(age>900?' <span class="warn">(stale?)</span>':'')+'</small>';
  const c=s.champion;
  $('score').textContent=pct(c.heldout.rate);
  $('score_ci').textContent='95% CI '+pct(c.heldout.lo)+' – '+pct(c.heldout.hi)+' on '+c.heldout.n+' secret-salted tasks (epoch '+s.bench.epoch+')';
  $('champ_kv').innerHTML=['partial credit',pct(c.heldout.partial),'adversarial',pct(c.adversarial.rate)+' (n='+c.adversarial.n+')','regression suite',c.regression.solved+'/'+c.regression.n,'external ARC',c.external.n?c.external.solved+'/'+c.external.n:'no ARC tasks yet','mean nodes / task',c.heldout.nodes.toFixed(0),'library size',c.library_size,'visible ops',c.ops,'accepted so far',s.accepted_total+' of '+s.candidates_total+' candidates'].map((v,i)=>i%2?'<span>'+esc(v)+'</span>':'<b>'+v+'</b>').join('');
  const pa=p.time?Math.round(Date.now()/1000-p.time):null;
  $('phase').innerHTML=esc(p.phase||'idle')+(pa!==null?' <small>('+pa+'s ago)</small>':'');
  const frac=p.total?p.done/p.total:0;$('pbar').style.width=(100*frac).toFixed(1)+'%';
  $('ptext').textContent=p.total?p.done+'/'+p.total+' tasks, '+p.solved+' solved so far':'';
  $('live_kv').innerHTML=['candidate',p.candidate||'–','operator',p.operator||'–','change',p.change||'–','next research',s.research.next_in_s!=null?Math.max(0,s.research.next_in_s)+'s':'–'].map((v,i)=>i%2?'<span>'+esc(v)+'</span>':'<b>'+v+'</b>').join('');
  const b=s.bench;
  $('bench_kv').innerHTML=['held-out epoch',b.epoch,'active families',b.families.join(', '),'burned',b.burned.length?b.burned.join(', '):'none','variants spawned',b.variants.length?b.variants.join(', '):'none','pressure',Object.entries(b.pressure).filter(x=>x[1]>0).map(x=>x[0]+':'+x[1]).join(' ')||'none','rotations',b.rotations,'regression tasks',b.regression_size,'ARC tasks on disk',b.arc_on_disk].map((v,i)=>i%2?'<span>'+esc(v)+'</span>':'<b>'+v+'</b>').join('');
  // chart
  const pts=lines.map(l=>({g:l.gen,champ:l.champion_heldout,cand:l.candidate_heldout,acc:l.accepted}));
  const W=1000,H=220,px=40,py=14;
  let svg='';
  if(pts.length){
    const gmin=pts[0].g,gmax=Math.max(pts[pts.length-1].g,gmin+1);
    const X=g=>px+(g-gmin)/(gmax-gmin)*(W-2*px),Y=v=>H-py-v*(H-2*py);
    for(let v=0;v<=1;v+=0.25)svg+='<line x1="'+px+'" x2="'+(W-px)+'" y1="'+Y(v)+'" y2="'+Y(v)+'" stroke="#22282f"/><text x="4" y="'+(Y(v)+4)+'" fill="#8b98a5" font-size="11">'+Math.round(v*100)+'%</text>';
    let d='';pts.forEach((q,i)=>{const s2=q.acc?q.cand:q.champ;d+=(i?'L':'M')+X(q.g)+','+Y(s2)+' ';});
    svg+='<path d="'+d+'" fill="none" stroke="#58a6ff" stroke-width="2"/>';
    pts.forEach(q=>{svg+=q.acc?'<circle cx="'+X(q.g)+'" cy="'+Y(q.cand)+'" r="5" fill="#3fb950"/>':'<text x="'+(X(q.g)-4)+'" y="'+(Y(q.cand)+4)+'" fill="#f85149" font-size="12">×</text>';});
  }
  $('chart').innerHTML=svg;
  $('lineage').innerHTML=lines.slice().reverse().slice(0,40).map(l=>'<tr><td>'+l.gen+'</td><td>'+esc(l.operator)+'</td><td>'+esc(l.change)+'</td><td class="'+(l.heldout_delta>0?'ok':l.heldout_delta<0?'bad':'')+'">'+(l.heldout_delta>=0?'+':'')+(100*l.heldout_delta).toFixed(1)+'pp</td><td>'+(l.p_value!=null?l.p_value.toFixed(3):'')+'</td><td>'+(l.adversarial_delta!=null?((l.adversarial_delta>=0?'+':'')+(100*l.adversarial_delta).toFixed(1)+'pp'):'')+'</td><td>'+esc(l.regression||'')+'</td><td class="'+(l.accepted?'ok':'bad')+'">'+(l.accepted?'ACCEPT':'reject')+': '+esc(l.reason)+'</td></tr>').join('');
  $('challenge').innerHTML=(s.challenge||[]).slice(0,14).map(r=>'<tr><td><code>'+esc(r.family)+'</code></td><td>'+r.n+'</td><td>'+pct(r.solve_rate)+'</td><td>'+r.information.toFixed(2)+'</td><td>'+r.discrimination.toFixed(2)+'</td><td>'+r.headroom.toFixed(2)+'</td><td class="acc"><b>'+r.score.toFixed(3)+'</b></td></tr>').join('')||'<tr><td colspan="7"><small>no measurements yet</small></td></tr>';
  $('saturated').innerHTML=(s.saturated&&s.saturated.length)?'Saturated (solved almost always <b>and</b> no longer separating candidates): <code>'+s.saturated.map(esc).join('</code> <code>')+'</code> &mdash; harder variants are spawned from these.':'Nothing saturated: every family still separates candidates.';
  $('research').innerHTML=(s.research.papers||[]).map(r=>'<div style="margin-bottom:6px"><small>'+esc((r.published||'').slice(0,10))+'</small> '+esc(r.title)+(r.addresses_gap&&r.addresses_gap.length?' <small class="ok">[gap: '+esc(r.addresses_gap.join(', '))+']</small>':(r.already_have&&r.already_have.length?' <small class="mute">[already implemented: '+esc(r.already_have.join(', '))+']</small>':''))+'</div>').join('')||'<small>no papers fetched yet (needs outbound HTTPS from the server)</small>';
  $('lib').innerHTML=(c.library||[]).map(e=>'<div><b class="acc">'+esc(e.name)+'</b> = '+esc(e.expr)+' <small>'+esc(e.arg)+(e.arg2?','+esc(e.arg2):'')+'→'+esc(e.ret)+' &middot; '+esc(e.origin||'')+'</small></div>').join('')||'<small>empty: nothing learned yet</small>';
}
load();setInterval(load,4000);
</script></body></html>
]==]

function M.ensure_html(root)
  local path = root .. "/www/index.html"
  local f = io.open(path, "r")
  local cur = f and f:read("*a") or nil
  if f then f:close() end
  if cur ~= HTML then
    local w = assert(io.open(path, "w"))
    w:write(HTML)
    w:close()
  end
end

return M
  end

  -- ==== rsi/kernel/journal.lua ====
  package.preload['rsi.kernel.journal'] = function(...)
-- The system's record of how it got here.
--
-- Three artefacts, deliberately separate because they answer different questions:
--
--   data/corpus.jsonl   The training data. One line per task the system has ever solved: the task's
--                       family and feature bucket, the program it found, what the generator actually
--                       used, and the generation it happened in. This is the evidence every mutation
--                       operator learns from -- library learning, anti-unification and prior fitting
--                       all read this corpus and nothing else -- so it is the closest thing the
--                       system has to a training set. The generator's own expression is recorded for
--                       the reader only; the solver never sees it (see tasks.solver_view).
--
--   data/journal.jsonl  The milestones. Every accepted change with its evidence, every benchmark
--                       rotation, every research fetch, and the challenge ranking at that moment.
--                       Machine-readable, append-only, one JSON object per line.
--
--   JOURNAL.md          The same milestones rendered for a human, regenerated each generation.
--
-- The per-candidate verdicts stay in state/lineage.jsonl. That file answers "what was tried and why
-- was it refused"; this one answers "what changed and what did it cost to find out".
local json = require("rsi.kernel.json")
local M = {}

function M.record(root, entry)
  entry.time = entry.time or os.time()
  json.append_line(root .. "/data/journal.jsonl", entry)
end

function M.add_corpus(root, rows)
  if #rows == 0 then return 0 end
  local f = io.open(root .. "/data/corpus.jsonl", "a")
  if not f then return 0 end
  for _, r in ipairs(rows) do f:write(json.encode(r), "\n") end
  f:close()
  return #rows
end

function M.corpus_size(root)
  local n = 0
  local f = io.open(root .. "/data/corpus.jsonl", "r")
  if not f then return 0 end
  for _ in f:lines() do n = n + 1 end
  f:close()
  return n
end

local function pct(x) return string.format("%.1f%%", 100 * (x or 0)) end

-- Render the human-readable ledger. Kept short at the top (where the system stands) and long at the
-- bottom (how it got there), because the first question is usually "is it working".
function M.render(root, ctx)
  local entries = json.read_lines(root .. "/data/journal.jsonl")
  local out = {}
  local function w(s) out[#out + 1] = s end

  w("# CELL4 journal")
  w("")
  w("Auto-generated by `rsi/kernel/journal.lua` at the end of every generation. Do not edit; edits are")
  w("overwritten. The machine-readable form is `rsi/data/journal.jsonl`, the per-candidate verdicts are")
  w("in `rsi/state/lineage.jsonl`, and the solved-program corpus the operators learn from is")
  w("`rsi/data/corpus.jsonl`.")
  w("")
  w("## Where it stands")
  w("")
  w(string.format("* generation **%d**, champion `%s`", ctx.gen, ctx.fingerprint or "?"))
  w(string.format("* held-out **%d/%d** (%s), 95%% CI %s – %s, on secret-salted tasks of epoch %d",
    ctx.heldout.solved, ctx.heldout.n, pct(ctx.heldout.rate), pct(ctx.heldout.lo), pct(ctx.heldout.hi),
    ctx.heldout_epoch or 1))
  w(string.format("* adversarial %d/%d, regression %d/%d, external ARC %s",
    ctx.adversarial.solved, ctx.adversarial.n, ctx.regression.solved, ctx.regression.n,
    ctx.external.n > 0 and (ctx.external.solved .. "/" .. ctx.external.n) or "none fetched yet"))
  w(string.format("* %d of %d candidates accepted across the whole run", ctx.accepted_total, ctx.candidates_total))
  w(string.format("* solved-program corpus: **%d** entries", ctx.corpus_size or 0))
  w(string.format("* learned library: %d abstractions, visible operators: %d", ctx.library_size or 0, ctx.ops or 0))
  w("")

  if ctx.challenge and #ctx.challenge > 0 then
    w("## What is worth being challenged by, right now")
    w("")
    w("Ranked by the system's own measurements. `information` is 4p(1-p) on the solve rate, so it peaks")
    w("where the family is solved about half the time; `discrim` is how often candidates actually differ")
    w("from the champion there, which is the benchmark's power to detect an improvement at all;")
    w("`headroom` is mean partial credit on the tasks it fails. A family it never solves scores low on")
    w("purpose -- difficulty alone is not the objective, telling improvement from noise is.")
    w("")
    w("| family | n | solved | information | discrim | headroom | score |")
    w("|---|---|---|---|---|---|---|")
    for i, r in ipairs(ctx.challenge) do
      if i > 14 then break end
      w(string.format("| `%s` | %d | %s | %.2f | %.2f | %.2f | **%.3f** |",
        r.family, r.n, pct(r.solve_rate), r.information, r.discrimination, r.headroom, r.score))
    end
    w("")
    if ctx.saturated and #ctx.saturated > 0 then
      w("Saturated (nearly always solved *and* no longer separating candidates): `"
        .. table.concat(ctx.saturated, "`, `") .. "`. These get harder variants spawned from them.")
      w("")
    end
  end

  local accepted, rotations, research = {}, {}, {}
  for _, e in ipairs(entries) do
    if e.kind == "accepted" then accepted[#accepted + 1] = e
    elseif e.kind == "rotation" then rotations[#rotations + 1] = e
    elseif e.kind == "research" then research[#research + 1] = e end
  end

  w("## Levels reached")
  w("")
  if #accepted == 0 then
    w("No candidate has yet cleared the acceptance rule. That is the honest state, not a placeholder:")
    w("a change is retained only when its paired held-out gain is significant under **both** the")
    w("bootstrap and the exact sign test, it loses nothing on the regression suite, and it does not")
    w("drop on the fresh adversarial split. Every attempt and its numbers are in `state/lineage.jsonl`.")
  else
    w("| gen | operator | change | held-out | evidence |")
    w("|---|---|---|---|---|")
    for i = #accepted, math.max(1, #accepted - 40), -1 do
      local e = accepted[i]
      w(string.format("| %d | `%s` | %s | %s → %s | %s |", e.gen, e.operator, e.change,
        pct(e.before), pct(e.after), e.reason))
    end
  end
  w("")

  if #rotations > 0 then
    w("## Benchmark rotations")
    w("")
    w("When one family drives repeated acceptances, the secret held-out salt is replaced, new motifs")
    w("enter the world, and a harder variant of that family is spawned. This is what stops the system")
    w("from optimising against a fixed test set.")
    w("")
    for i = #rotations, math.max(1, #rotations - 20), -1 do
      local e = rotations[i]
      w(string.format("* **gen %d** — %s", e.gen, e.detail))
    end
    w("")
  end

  if #research > 0 then
    w("## Research fetches")
    w("")
    for i = #research, math.max(1, #research - 12), -1 do
      local e = research[i]
      w(string.format("* **gen %d** — %d new papers, %d new ARC tasks%s", e.gen or 0,
        e.papers_new or 0, e.arc_new or 0,
        (e.errors and e.errors > 0) and (" (" .. e.errors .. " fetch errors)") or ""))
    end
    w("")
  end

  w("## How to read a rejection")
  w("")
  w("Most candidates are rejected and that is the harness working. `screened out on held-out` means the")
  w("candidate solved strictly fewer held-out tasks, so it cannot pass any acceptance clause and the")
  w("remaining splits were not run. `not significant` means it gained but the gain is inside the noise")
  w("-- on 200 held-out tasks a candidate needs roughly nine wins against at most one loss to clear")
  w("p<0.05 on both tests. `regression: lost N` means it broke something a previous champion could do.")

  local f = assert(io.open(root .. "/../JOURNAL.md", "w"))
  f:write(table.concat(out, "\n"), "\n")
  f:close()
end

return M
  end

  -- ==== rsi/kernel/challenge.lua ====
  package.preload['rsi.kernel.challenge'] = function(...)
-- What is a good challenge for this system right now?
--
-- The inputs here are all measurements the system took on itself. The weighting that combines them
-- is a declared convention, printed alongside the result so it can be argued with and changed in
-- `rsi/config.lua`. That split is what "unbiased" means here: nothing is scored by preference, but
-- the recipe for combining the scores is a choice and is shown as one.
--
-- Four components, each in [0,1]:
--
--   information  4p(1-p) where p is the solve rate. This is the variance of a Bernoulli trial,
--                normalised to peak at p=0.5. A benchmark solved 100% or 0% of the time carries no
--                information about whether a change helped: every candidate scores the same on it.
--                This is the item-information idea from item response theory, in its simplest form.
--
--   discrimination  the rate at which candidates actually differ from the champion on this family's
--                tasks. This is the empirical count of discordant pairs -- exactly the quantity the
--                sign test consumes -- so it is a direct measure of the benchmark's statistical
--                power to detect a real improvement. A family that never produces a discordant pair
--                cannot ever justify an acceptance, however hard it looks.
--
--   headroom     mean partial credit on the tasks it fails. A family it misses by one example is
--                nearer to falling than one it misses entirely, so this points at reachable gains.
--
--   freshness    1/(1+generations since this family last discriminated). Penalises families that
--                have gone quiet, which is how saturation shows up before the solve rate saturates.
--
-- A family that is *hard* is not automatically a good challenge: one the system solves 0% of the
-- time scores zero information and zero discrimination, and correctly ranks below one it solves half
-- the time. Difficulty for its own sake is not the objective; the ability to tell improvement from
-- noise is.
local M = {}

M.DEFAULT_WEIGHTS = { information = 0.40, discrimination = 0.35, headroom = 0.15, freshness = 0.10 }

-- stats: family -> { n, solved, partial_unsolved_sum, partial_unsolved_n, discordant, comparisons,
--                    last_discordant_gen }
function M.rank(stats, gen, weights)
  weights = weights or M.DEFAULT_WEIGHTS
  local rows = {}
  local max_disc = 0
  for _, st in pairs(stats or {}) do
    local d = (st.comparisons or 0) > 0 and (st.discordant or 0) / st.comparisons or 0
    if d > max_disc then max_disc = d end
  end
  for fam, st in pairs(stats or {}) do
    if (st.n or 0) > 0 then
      local p = st.solved / st.n
      local information = 4 * p * (1 - p)
      local raw_disc = (st.comparisons or 0) > 0 and (st.discordant or 0) / st.comparisons or 0
      local discrimination = max_disc > 0 and raw_disc / max_disc or 0
      local headroom = (st.partial_unsolved_n or 0) > 0
        and st.partial_unsolved_sum / st.partial_unsolved_n or 0
      local since = gen - (st.last_discordant_gen or 0)
      local freshness = 1 / (1 + math.max(0, since))
      local score = weights.information * information
        + weights.discrimination * discrimination
        + weights.headroom * headroom
        + weights.freshness * freshness
      rows[#rows + 1] = {
        family = fam, n = st.n, solve_rate = p, score = score,
        information = information, discrimination = discrimination,
        headroom = headroom, freshness = freshness,
        discordant = st.discordant or 0, comparisons = st.comparisons or 0,
        since_discriminated = since,
      }
    end
  end
  table.sort(rows, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.family < b.family
  end)
  return rows
end

-- A family is saturated when it is nearly always solved AND has stopped separating candidates.
-- Both conditions matter: a family at 95% that still discriminates is still doing useful work.
function M.saturated(rows, solve_floor, disc_floor)
  solve_floor = solve_floor or 0.92
  disc_floor = disc_floor or 0.05
  local out = {}
  for _, r in ipairs(rows) do
    if r.solve_rate >= solve_floor and r.discrimination <= disc_floor and r.n >= 40 then
      out[#out + 1] = r.family
    end
  end
  return out
end

-- The families worth spending adversarial slots on: the best challenges that are not saturated.
function M.pick_adversarial(rows, k, fallback)
  local out = {}
  for _, r in ipairs(rows) do
    if #out >= k then break end
    if r.solve_rate < 0.95 then out[#out + 1] = r.family end
  end
  if #out == 0 then return fallback end
  return out
end

function M.update(stats, family, solved, partial, gen)
  local st = stats[family]
  if not st then
    st = { n = 0, solved = 0, partial_unsolved_sum = 0, partial_unsolved_n = 0,
           discordant = 0, comparisons = 0, last_discordant_gen = gen }
    stats[family] = st
  end
  st.n = st.n + 1
  st.solved = st.solved + solved
  if solved == 0 then
    st.partial_unsolved_sum = st.partial_unsolved_sum + (partial or 0)
    st.partial_unsolved_n = st.partial_unsolved_n + 1
  end
  return st
end

function M.note_comparison(stats, family, differed, gen)
  local st = stats[family]
  if not st then return end
  st.comparisons = (st.comparisons or 0) + 1
  if differed then
    st.discordant = (st.discordant or 0) + 1
    st.last_discordant_gen = gen
  end
end

return M
  end

  -- ==== rsi/kernel/genome.lua ====
  package.preload['rsi.kernel.genome'] = function(...)
-- Genome = a directory of mutable source: dsl_base.lua, library.lua, policy.lua, search.lua
-- The kernel loads it, enforces the visibility boundary (hidden ops are refused), and can save it.
local ops = require("rsi.kernel.ops")
local program = require("rsi.kernel.program")
local serialize = require("rsi.kernel.serialize")
local M = {}

local function loadfile_strict(path)
  local chunk, err = loadfile(path)
  if not chunk then error("genome load error: " .. tostring(err)) end
  return chunk()
end

function M.load(dir)
  local base = loadfile_strict(dir .. "/dsl_base.lua")
  local lib = loadfile_strict(dir .. "/library.lua")
  local policy = loadfile_strict(dir .. "/policy.lua")
  local search = loadfile_strict(dir .. "/search.lua")
  local prims, order = {}, {}
  for _, name in ipairs(base.ops) do
    local o = ops.catalogue[name]
    if o and not o.hidden and not prims[name] then
      prims[name] = { f = o.f, t = o.t, r = o.r, name = name }
      order[#order + 1] = name
    end
  end
  local lib_ok = {}
  for _, e in ipairs(lib) do
    local ok, err = pcall(function()
      local node = program.parse(e.expr)
      local f = program.compile(node, prims)
      local types = e.arg2 and { e.arg, e.arg2 } or { e.arg }
      prims[e.name] = { f = f, t = types, r = e.ret, learned = true, expr = e.expr, name = e.name, bucket = e.bucket }
      order[#order + 1] = e.name
      lib_ok[#lib_ok + 1] = e
    end)
    if not ok then io.stderr:write("library entry skipped: " .. tostring(e.name) .. " " .. tostring(err) .. "\n") end
  end
  return {
    dir = dir, prims = prims, order = order, policy = policy, solve = search.solve,
    base = base, lib = lib_ok,
    search_src = (function() local f = io.open(dir .. "/search.lua", "r") local s = f:read("*a") f:close() return s end)(),
  }
end

function M.save(g, dir)
  os.execute("mkdir -p '" .. dir .. "'")
  serialize.write(dir .. "/dsl_base.lua", g.base, "visible primitive selection (mutable)")
  serialize.write(dir .. "/library.lua", g.lib, "learned abstractions (mutable, grown by library learning)")
  serialize.write(dir .. "/policy.lua", g.policy, "search policy: costs, constants, budgets, strategy (mutable)")
  local tmp = dir .. "/search.lua.tmp"
  local f = assert(io.open(tmp, "w"))
  f:write(g.search_src)
  f:close()
  if not os.rename(tmp, dir .. "/search.lua") then
    os.remove(tmp)
    error("genome.save: failed to replace " .. dir .. "/search.lua")
  end
end

-- A deep copy of the data parts (search_src is a string, shared by value)
function M.clone(g)
  local function deep(v)
    if type(v) ~= "table" then return v end
    local o = {}
    for k, x in pairs(v) do o[k] = deep(x) end
    return o
  end
  return { base = deep(g.base), lib = deep(g.lib), policy = deep(g.policy), search_src = g.search_src }
end

-- Content fingerprint for lineage
function M.fingerprint(g)
  local s = serialize.to_lua(g.base) .. serialize.to_lua(g.lib) .. serialize.to_lua(g.policy) .. g.search_src
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
  return string.format("%08x", h)
end

return M
  end

  -- ==== rsi/kernel/evaluate.lua ====
  package.preload['rsi.kernel.evaluate'] = function(...)
-- Runs a genome's solver over a task set under hard budgets and verifies solutions on
-- kernel-only test examples. The solver never sees test examples or generator metadata.
local ops = require("rsi.kernel.ops")
local program = require("rsi.kernel.program")
local sandbox = require("rsi.kernel.sandbox")
local tasks = require("rsi.kernel.tasks")
local features = require("rsi.kernel.features")
local inverses = require("rsi.kernel.inverses")
local constants = require("rsi.kernel.constants")
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
      inverses = inverses,
      constants = constants,
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
  end

  -- ==== rsi/kernel/tasks.lua ====
  package.preload['rsi.kernel.tasks'] = function(...)
-- Seeded task generators. A task is a program-synthesis problem: train examples (shown to the solver),
-- test examples (kernel-only verification). Generation composes ops from the full catalogue,
-- including hidden ops the solver's DSL does not have, so the solver must genuinely compose.
local ops = require("rsi.kernel.ops")
local program = require("rsi.kernel.program")
local RNG = require("rsi.kernel.rng")
local M = {}

-- family definitions: in_type, allowed out types, depth range, whether hidden ops may appear, sizes
M.families = {
  list_d1     = { in_type = "L", outs = { "L", "I" }, depth = { 1, 1 }, hidden = false, maxlen = 7, maxval = 9 },
  list_d2     = { in_type = "L", outs = { "L", "I" }, depth = { 2, 2 }, hidden = false, maxlen = 7, maxval = 9 },
  list_d3     = { in_type = "L", outs = { "L", "I" }, depth = { 3, 3 }, hidden = false, maxlen = 6, maxval = 9 },
  list_hidden = { in_type = "L", outs = { "L", "I", "B" }, depth = { 1, 2 }, hidden = true, maxlen = 7, maxval = 9 },
  list_wide   = { in_type = "L", outs = { "L", "I" }, depth = { 2, 3 }, hidden = true, maxlen = 10, maxval = 30 },
  grid_d1     = { in_type = "G", outs = { "G", "I", "C" }, depth = { 1, 1 }, hidden = false, maxdim = 5 },
  grid_d2     = { in_type = "G", outs = { "G", "I", "L", "C" }, depth = { 2, 2 }, hidden = false, maxdim = 5 },
  grid_d3     = { in_type = "G", outs = { "G", "I", "L" }, depth = { 3, 3 }, hidden = false, maxdim = 4 },
  grid_hidden = { in_type = "G", outs = { "G", "L", "I" }, depth = { 1, 2 }, hidden = true, maxdim = 6 },
  grid_wide   = { in_type = "G", outs = { "G", "I", "L" }, depth = { 2, 3 }, hidden = true, maxdim = 8 },
}

-- Shared latent structure. Uniformly random composition produces tasks with no recurring motifs,
-- so abstraction has nothing to find (measured: 17 multi-op templates across 99 solutions, all used
-- once). Real domains are not like that. A motif pool, deterministic from the installation's world
-- salt and shared by every split, gives the distribution genuine recurring structure that the solver
-- must discover for itself: the motifs are never shown to it.
M.world = { salt = "world-default", epoch = 1 }
function M.set_world(salt, epoch)
  M.world.salt = salt or M.world.salt
  M.world.epoch = epoch or M.world.epoch
end

M.family_order = { "list_d1", "list_d2", "list_d3", "list_hidden", "list_wide", "grid_d1", "grid_d2", "grid_d3", "grid_hidden", "grid_wide" }

local cat = ops.catalogue
local by_ret = {}
local names = {}
for name in pairs(cat) do names[#names + 1] = name end
table.sort(names)
for _, name in ipairs(names) do
  local o = cat[name]
  by_ret[o.r] = by_ret[o.r] or {}
  table.insert(by_ret[o.r], name)
end

-- Can type t be produced from in_type within `depth` op applications?
local reach_cache = {}
local function reachable(t, in_type, depth, allow_hidden)
  if t == in_type then return true end
  if depth <= 0 then return false end
  local key = t .. in_type .. depth .. tostring(allow_hidden)
  if reach_cache[key] ~= nil then return reach_cache[key] end
  local r = false
  for _, name in ipairs(by_ret[t] or {}) do
    local o = cat[name]
    if allow_hidden or not o.hidden then
      for _, at in ipairs(o.t) do
        if reachable(at, in_type, depth - 1, allow_hidden) then r = true break end
      end
    end
    if r then break end
  end
  reach_cache[key] = r
  return r
end

local function rand_const(rng, ty, fam)
  if ty == "C" then return program.const(rng:int(0, 9), "C") end
  return program.const(rng:int(fam.in_type == "G" and 1 or 0, 4), "I")
end

local gen_expr

local motif_cache = {}
local function motifs_for(in_type, allow_hidden)
  local key = M.world.salt .. "|" .. M.world.epoch .. "|" .. in_type .. "|" .. tostring(allow_hidden)
  local cached = motif_cache[key]
  if cached then return cached end
  local rng = RNG.new(key)
  local fam = { in_type = in_type, maxlen = 7, maxval = 9, maxdim = 5 }
  local pool, tries = {}, 0
  local want = 8 + 4 * (M.world.epoch - 1)
  local out_types = in_type == "L" and { "L", "L", "I" } or { "G", "G", "I", "L" }
  while #pool < want and tries < 400 do
    tries = tries + 1
    local ty = rng:pick(out_types)
    local e = gen_expr(rng, ty, 2, fam, allow_hidden, true)
    if e then pool[#pool + 1] = { node = e, ty = ty } end
  end
  motif_cache[key] = pool
  return pool
end

-- Build an expression of type `ty` that uses the input variable, with exactly `depth` ops on the var path.
-- `no_motifs` is set while building the motif pool itself, to stop the recursion.
function gen_expr(rng, ty, depth, fam, allow_hidden, no_motifs)
  if depth == 2 and not no_motifs then
    local pool = motifs_for(fam.in_type, allow_hidden)
    local cands = {}
    for _, m in ipairs(pool) do if m.ty == ty then cands[#cands + 1] = m.node end end
    if #cands > 0 and rng:float() < 0.6 then return program.clone(rng:pick(cands)) end
  end
  if depth == 0 then
    if ty == fam.in_type then return program.var() end
    return nil
  end
  local cands = {}
  for _, name in ipairs(by_ret[ty] or {}) do
    local o = cat[name]
    if allow_hidden or not o.hidden then
      for i, at in ipairs(o.t) do
        if reachable(at, fam.in_type, depth - 1, allow_hidden) then cands[#cands + 1] = { name, i } break end
      end
    end
  end
  if #cands == 0 then return nil end
  for _ = 1, 6 do
    local pick = rng:pick(cands)
    local name = pick[1]
    local o = cat[name]
    -- choose which arg carries the variable path (any arg whose type is reachable)
    local slots = {}
    for i, at in ipairs(o.t) do if reachable(at, fam.in_type, depth - 1, allow_hidden) then slots[#slots + 1] = i end end
    local vslot = rng:pick(slots)
    local args, ok = {}, true
    for i, at in ipairs(o.t) do
      if i == vslot then
        args[i] = gen_expr(rng, at, depth - 1, fam, allow_hidden, no_motifs)
        if not args[i] then ok = false break end
      elseif at == "I" or at == "C" then
        -- occasionally a derived scalar from the input, mostly a constant
        if rng:float() < 0.25 and reachable(at, fam.in_type, 1, allow_hidden) then
          args[i] = gen_expr(rng, at, 1, fam, allow_hidden, no_motifs) or rand_const(rng, at, fam)
        else
          args[i] = rand_const(rng, at, fam)
        end
      elseif at == fam.in_type then
        -- second structural argument: the input itself or a shallow transform of it
        if rng:float() < 0.5 then args[i] = program.var() else args[i] = gen_expr(rng, at, 1, fam, allow_hidden, no_motifs) or program.var() end
      else
        args[i] = gen_expr(rng, at, math.max(depth - 1, 1), fam, allow_hidden, no_motifs)
        if not args[i] then ok = false break end
      end
    end
    if ok then return program.node(name, args) end
  end
  return nil
end

local function rand_list(rng, fam)
  local n = rng:int(3, fam.maxlen or 7)
  local l = {}
  for i = 1, n do l[i] = rng:int(0, fam.maxval or 9) end
  return l
end

local function rand_grid(rng, fam)
  local maxd = fam.maxdim or 5
  local h, w = rng:int(2, maxd), rng:int(2, maxd)
  local palette = { rng:int(1, 9), rng:int(1, 9) }
  local density = 0.3 + 0.4 * rng:float()
  local g = ops.grid(h, w, 0)
  for r = 1, h do for c = 1, w do
    if rng:float() < density then g[r][c] = rng:pick(palette) end
  end end
  return g
end

local function output_ok(v, ty)
  if v == nil then return false end
  local t = ops.typeof(v)
  if ty == "C" then return t == "I" and v >= 0 and v <= 9 end
  if t ~= ty then return false end
  if t == "L" and (#v == 0 or #v > 40) then return false end
  if t == "G" and (v.h * v.w > 400) then return false end
  if t == "I" and math.abs(v) > 100000 then return false end
  return true
end

-- Deterministic generation: task = f(family, salt, index)
function M.generate(family_name, salt, index, n_train, n_test)
  local fam = M.families[family_name]
  if not fam then error("unknown family " .. tostring(family_name)) end
  n_train, n_test = n_train or 4, n_test or 1
  local rng = RNG.new(tostring(salt) .. ":" .. family_name .. ":" .. tostring(index))
  local prims = {}
  for name, o in pairs(cat) do prims[name] = o end
  for attempt = 1, 60 do
    local out_ty = rng:pick(fam.outs)
    local depth = rng:int(fam.depth[1], fam.depth[2])
    local expr = gen_expr(rng, out_ty, depth, fam, fam.hidden)
    if expr and program.uses_var(expr) and program.size(expr) >= depth + 1 then
      local ok, f = pcall(program.compile, expr, prims)
      if ok then
        local examples, good = {}, true
        local train_sigs, any_identity = {}, 0
        for i = 1, n_train + n_test do
          local input = fam.in_type == "L" and rand_list(rng, fam) or rand_grid(rng, fam)
          local ok2, out = pcall(f, input)
          if not ok2 or not output_ok(out, out_ty) then good = false break end
          if i <= n_train then train_sigs[ops.sig(out)] = true end
          if ops.equal(out, input) then any_identity = any_identity + 1 end
          examples[i] = { input = input, output = out }
        end
        -- the training outputs alone must vary, otherwise a constant fits them and the task is degenerate
        local distinct = 0
        for _ in pairs(train_sigs) do distinct = distinct + 1 end
        if good and distinct >= 2 and any_identity < 2 then
          local train, test = {}, {}
          for i = 1, n_train do train[i] = examples[i] end
          for i = 1, n_test do test[i] = examples[n_train + i] end
          return {
            id = family_name .. "#" .. index,
            family = family_name,
            in_type = fam.in_type,
            out_type = out_ty == "C" and "C" or out_ty,
            train = train, test = test,
            meta = { expr = program.to_string(expr), depth = depth, attempt = attempt },
          }
        end
      end
    end
  end
  return nil
end

-- Generate `count` tasks from a family, skipping indices that fail to produce a valid task.
function M.generate_set(family_name, salt, count, offset)
  local out, idx = {}, offset or 0
  local misses = 0
  while #out < count and misses < count * 10 do
    idx = idx + 1
    local t = M.generate(family_name, salt, idx)
    if t then out[#out + 1] = t else misses = misses + 1 end
  end
  return out, idx
end

-- The solver-facing view: no test examples, no generator metadata.
function M.solver_view(task)
  return { id = task.id, in_type = task.in_type, out_type = task.out_type, train = task.train }
end

return M
  end

  -- ==== rsi/kernel/lineage.lua ====
  package.preload['rsi.kernel.lineage'] = function(...)
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

-- Rejected candidate snapshots accumulate at candidates_per_gen per generation, which is thousands
-- a day on a machine left running. Accepted champions are kept forever; rejected candidates are kept
-- for `keep` generations, long enough to inspect a recent verdict. Their evidence stays in
-- lineage.jsonl either way, so nothing that explains a decision is lost.
function M.prune(root, current_gen, keep)
  keep = keep or 50
  local cutoff = current_gen - keep
  if cutoff < 1 then return 0 end
  local p = io.popen("ls -1 '" .. root .. "/versions' 2>/dev/null")
  if not p then return 0 end
  local removed = 0
  for name in p:lines() do
    local g = tonumber(name:match("^g(%d+)_"))
    if g and g <= cutoff and not name:match("_champion$") then
      os.execute("rm -rf '" .. root .. "/versions/" .. name .. "'")
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
  end

  -- ==== rsi/kernel/mutate.lua ====
  package.preload['rsi.kernel.mutate'] = function(...)
-- Candidate generation: operators that rewrite the genome from empirical evidence
-- (solutions and near-misses on the visible split) or by controlled perturbation.
-- Operator selection is adaptive: operators that produced accepted candidates get sampled more.
local program = require("rsi.kernel.program")
local genome = require("rsi.kernel.genome")
local M = {}

M.operators = {
  "library_learn", "parameterized_abstraction", "near_miss_abstraction", "fit_priors", "fit_conditional_priors",
  "fit_conditional_ops", "reorder_ops", "prune_dsl_bulk",
  "perturb_hyper", "const_tune", "prune_library", "drop_op", "restore_op", "strategy_swap",
}

-- Evidence = the accumulated corpus of visible-split solutions (all generations), falling back to
-- this generation's results. Held-out programs are never part of it.
local function solved_programs(ctx)
  local out = {}
  if ctx.corpus and #ctx.corpus > 0 then
    for _, e in ipairs(ctx.corpus) do
      local ok, node = pcall(program.parse, e.expr)
      if ok then out[#out + 1] = { id = e.family .. ":" .. e.gen, node = node, bucket = e.bucket } end
    end
    return out
  end
  for _, r in ipairs(ctx.train_results.per_task) do
    if r.solved == 1 and r.program then out[#out + 1] = { id = r.id, node = program.parse(r.program) } end
  end
  return out
end

local function op_counts(progs)
  local cnt, total = {}, 0
  for _, p in ipairs(progs) do
    for _, op in ipairs(program.ops_used(p.node)) do cnt[op] = (cnt[op] or 0) + 1 total = total + 1 end
  end
  return cnt, total
end

local function lib_has(g, expr)
  for _, e in ipairs(g.lib) do if e.expr == expr then return true end end
  return false
end

local function next_lib_name(g)
  local n = 0
  for _, e in ipairs(g.lib) do local k = tonumber(e.name:match("lib_(%d+)")) if k and k > n then n = k end end
  return "lib_" .. (n + 1)
end

-- Count closed subtrees (containing $) across programs; score = compression gain (size-1)*(uses-1)
local function abstraction_candidates(g, progs, min_size)
  local seen_per_task, freq, info = {}, {}, {}
  for _, p in ipairs(progs) do
    local local_seen = {}
    for _, st in ipairs(program.subtrees(p.node)) do
      if program.size(st) >= (min_size or 3) and #program.ops_used(st) >= 2 then
        local s = program.to_string(st)
        if not local_seen[s] then
          local_seen[s] = true
          freq[s] = (freq[s] or 0) + 1
          info[s] = info[s] or { node = st, size = program.size(st), buckets = {} }
          if p.bucket then info[s].buckets[p.bucket] = (info[s].buckets[p.bucket] or 0) + 1 end
        end
      end
    end
  end
  local list = {}
  for s, f in pairs(freq) do
    if not lib_has(g, s) then
      -- the bucket this abstraction actually came from, when one clearly dominates
      local top, tc = nil, 0
      for b, c in pairs(info[s].buckets) do if c > tc or (c == tc and top and b < top) then top, tc = b, c end end
      local bucket = (top and tc >= math.max(2, math.ceil(0.6 * f))) and top or nil
      list[#list + 1] = { expr = s, uses = f, size = info[s].size, node = info[s].node, bucket = bucket,
        gain = (info[s].size - 1) * math.max(f - 1, 0) + f }
    end
  end
  table.sort(list, function(a, b) if a.gain ~= b.gain then return a.gain > b.gain end return a.expr < b.expr end)
  return list
end

local function in_type_of(node)
  -- the variable's type is whatever the innermost op expects at the position of $
  local function walk(n, prims, expected)
    if n.var then return expected end
    if n.const ~= nil then return nil end
    local p = prims[n.op]
    if not p then return nil end
    for i, a in ipairs(n.args) do
      local r = walk(a, prims, p.t[i])
      if r then return r end
    end
    return nil
  end
  return walk
end

local function add_abstractions(g, cands, ctx, max_add, tag)
  local added = {}
  local walk = in_type_of()
  for _, c in ipairs(cands) do
    if #added >= max_add then break end
    local arg = walk(c.node, ctx.prims, nil)
    local ret = program.ret_type(c.node, ctx.prims, arg)
    if arg and ret and ret ~= "?" and (c.uses >= 2 or tag == "near_miss") then
      local name = next_lib_name(g)
      -- Measured: every extra primitive widens the branching factor at every enumeration level, and
      -- a library of 8 cost 2.7pp on 300 tasks. So an abstraction is admitted only into the task
      -- feature bucket it was mined from; elsewhere the search never sees it and pays nothing.
      g.lib[#g.lib + 1] = { name = name, expr = c.expr, arg = arg, ret = ret, origin = tag,
        uses = c.uses, bucket = c.bucket }
      g.policy.cost[name] = math.max(1, (g.policy.default_cost or 2) - 1)
      added[#added + 1] = name .. "=" .. c.expr .. " (uses " .. c.uses .. (c.bucket and (", " .. c.bucket) or ", global") .. ")"
    end
  end
  return added
end

local ops_impl = {}

function ops_impl.library_learn(g, ctx)
  local progs = solved_programs(ctx)
  if #progs < 2 then return nil end
  local cands = abstraction_candidates(g, progs, 3)
  local added = add_abstractions(g, cands, ctx, 4, "library")
  if #added == 0 then return nil end
  return "library learning: " .. table.concat(added, "; ")
end

-- Anti-unification: find subtrees that are identical except for one integer/colour constant and
-- turn the differing position into a second parameter. This is where reuse actually lives: exact
-- subtree repeats are rare in generated tasks, but "same shape, different constant" is common.
-- (Version-space / Stitch-style abstraction, restricted to a single hole for tractability.)
local function templates_of(node)
  -- returns list of {tmpl=node with one constant replaced by @, value=v, ty=ty}
  local out = {}
  local function rebuild(n, target, replaced)
    if n == target then return program.var2(), true end
    if n.var or n.var2 or n.const ~= nil then return n, replaced end
    local args, done = {}, replaced
    for i, a in ipairs(n.args) do
      local r, d = rebuild(a, target, done)
      args[i] = r
      done = done or d
    end
    return program.node(n.op, args), done
  end
  local consts = {}
  local function collect(n)
    if n.const ~= nil then consts[#consts + 1] = n return end
    if n.op then for _, a in ipairs(n.args) do collect(a) end end
  end
  collect(node)
  for _, c in ipairs(consts) do
    local t, ok = rebuild(node, c, false)
    if ok then out[#out + 1] = { tmpl = t, value = c.const, ty = c.ty or "I" } end
  end
  return out
end

function ops_impl.parameterized_abstraction(g, ctx)
  local progs = solved_programs(ctx)
  if #progs < 20 then return nil end
  local groups = {}
  for _, p in ipairs(progs) do
    local local_seen = {}
    for _, st in ipairs(program.subtrees(p.node)) do
      if program.size(st) >= 3 and #program.ops_used(st) >= 2 then
        for _, t in ipairs(templates_of(st)) do
          local key = program.to_string(t.tmpl)
          -- a single-op template is just an alias of an existing primitive: pure enumeration cost
          if #program.ops_used(t.tmpl) >= 2 and not local_seen[key] and not lib_has(g, key) then
            local_seen[key] = true
            local grp = groups[key]
            if not grp then grp = { node = t.tmpl, ty = t.ty, values = {}, uses = 0, size = program.size(t.tmpl) } groups[key] = grp end
            grp.uses = grp.uses + 1
            grp.values[t.value] = true
          end
        end
      end
    end
  end
  local list = {}
  for key, grp in pairs(groups) do
    local distinct = 0
    for _ in pairs(grp.values) do distinct = distinct + 1 end
    -- require the hole to actually vary, otherwise a plain (unary) abstraction already covers it
    if distinct >= 2 and grp.uses >= 3 then
      list[#list + 1] = { expr = key, node = grp.node, uses = grp.uses, distinct = distinct, ty = grp.ty,
        gain = (grp.size - 1) * (grp.uses - 1) + distinct }
    end
  end
  if #list == 0 then return nil end
  table.sort(list, function(a, b) if a.gain ~= b.gain then return a.gain > b.gain end return a.expr < b.expr end)
  local walk = in_type_of()
  local added = {}
  for _, c in ipairs(list) do
    if #added >= 2 then break end
    local arg = walk(c.node, ctx.prims, nil)
    local ret = program.ret_type(c.node, ctx.prims, arg)
    if arg and ret and ret ~= "?" then
      local name = next_lib_name(g)
      g.lib[#g.lib + 1] = { name = name, expr = c.expr, arg = arg, arg2 = c.ty, ret = ret,
        origin = "anti_unification", uses = c.uses }
      g.policy.cost[name] = g.policy.default_cost or 2
      added[#added + 1] = string.format("%s(%s,%s)=%s [%d uses, %d distinct]", name, arg, c.ty, c.expr, c.uses, c.distinct)
    end
  end
  if #added == 0 then return nil end
  return "parameterized abstraction: " .. table.concat(added, "; ")
end

function ops_impl.near_miss_abstraction(g, ctx)
  local progs = {}
  for _, e in ipairs(ctx.near_corpus or {}) do
    local ok, node = pcall(program.parse, e.expr)
    if ok then progs[#progs + 1] = { id = e.family .. ":" .. e.gen, node = node } end
  end
  for _, r in ipairs(ctx.adversarial_results and ctx.adversarial_results.per_task or {}) do
    if r.solved == 0 and r.partial >= 0.5 and r.partial_program then
      progs[#progs + 1] = { id = r.id, node = program.parse(r.partial_program) }
    end
  end
  if #progs < 2 then return nil end
  local cands = abstraction_candidates(g, progs, 3)
  local filtered = {}
  for _, c in ipairs(cands) do if c.uses >= 2 then filtered[#filtered + 1] = c end end
  local added = add_abstractions(g, filtered, ctx, 1, "near_miss")
  if #added == 0 then return nil end
  return "near-miss abstraction: " .. table.concat(added, "; ")
end

function ops_impl.fit_priors(g, ctx)
  local progs = solved_programs(ctx)
  if #progs < 3 then return nil end
  local cnt, total = op_counts(progs)
  local names = {}
  for _, name in ipairs(g.base.ops) do names[#names + 1] = name end
  for _, e in ipairs(g.lib) do names[#names + 1] = e.name end
  -- gentle prior fitting: frequently used ops get cost 1, ordinary ops keep the default,
  -- ops never seen in any solution move one step above the default (max 3). Costs only move by
  -- one unit per candidate so the harness can attribute effects.
  local sorted = {}
  for _, name in ipairs(names) do sorted[#sorted + 1] = name end
  table.sort(sorted, function(a, b) local ca, cb = cnt[a] or 0, cnt[b] or 0 if ca ~= cb then return ca > cb end return a < b end)
  local top = math.max(3, math.floor(#sorted * 0.2))
  local d = g.policy.default_cost or 2
  local changed = 0
  for i, name in ipairs(sorted) do
    -- evidence so far: raising costs of rarely-used ops hurts the adversarial (hidden-op) split,
    -- so this operator only ever lowers costs of frequently used ops.
    if i <= top and (cnt[name] or 0) > 0 then
      local cur = g.policy.cost[name] or d
      if cur > 1 then g.policy.cost[name] = cur - 1 changed = changed + 1 end
    end
  end
  if changed == 0 then return nil end
  return string.format("fit priors from %d solutions: %d frequent ops made cheaper", #progs, changed)
end

-- Task-conditioned priors: per feature bucket (see kernel/features.lua), ops that solve tasks in that
-- bucket get cheaper and ops never seen in that bucket get one step dearer. The search applies the
-- bucket's table when it recognises the task's features.
function ops_impl.fit_conditional_priors(g, ctx)
  if not ctx.corpus or #ctx.corpus < 40 then return nil end
  local by_bucket = {}
  for _, e in ipairs(ctx.corpus) do
    if e.bucket then
      local ok, node = pcall(program.parse, e.expr)
      if ok then
        by_bucket[e.bucket] = by_bucket[e.bucket] or {}
        table.insert(by_bucket[e.bucket], { node = node })
      end
    end
  end
  local names = {}
  for _, name in ipairs(g.base.ops) do names[#names + 1] = name end
  for _, e in ipairs(g.lib) do names[#names + 1] = e.name end
  local d = g.policy.default_cost or 2
  g.policy.cond_cost = g.policy.cond_cost or {}
  local fitted = {}
  for bucket, progs in pairs(by_bucket) do
    if #progs >= 15 then
      local cnt = op_counts(progs)
      local sorted = {}
      for _, name in ipairs(names) do sorted[#sorted + 1] = name end
      table.sort(sorted, function(a, b) local ca, cb = cnt[a] or 0, cnt[b] or 0 if ca ~= cb then return ca > cb end return a < b end)
      local top = math.max(4, math.floor(#sorted * 0.25))
      local tbl = {}
      for i, name in ipairs(sorted) do
        local base = g.policy.cost[name] or d
        if i <= top and (cnt[name] or 0) > 0 then tbl[name] = 1
        elseif (cnt[name] or 0) == 0 then tbl[name] = math.min(3, base + 1)
        else tbl[name] = base end
      end
      g.policy.cond_cost[bucket] = tbl
      fitted[#fitted + 1] = bucket .. "(" .. #progs .. ")"
    end
  end
  if #fitted == 0 then return nil end
  table.sort(fitted)
  return "fitted task-conditioned priors for " .. table.concat(fitted, " ")
end

function ops_impl.prune_dsl_bulk(g, ctx)
  local progs = solved_programs(ctx)
  -- "unused" is only evidence once the corpus is large; on a small sample it just means unlucky
  if #progs < 250 then return nil end
  local cnt = op_counts(progs)
  local keep, dropped = {}, {}
  for _, name in ipairs(g.base.ops) do
    if cnt[name] then keep[#keep + 1] = name else dropped[#dropped + 1] = name end
  end
  if #dropped < 3 or #keep < 25 then return nil end
  -- drop up to a third of the unused ops at once (deterministic subset)
  local n = math.max(3, math.floor(#dropped / 3))
  ctx.rng:shuffle(dropped)
  local removed = {}
  local set = {}
  for i = 1, n do set[dropped[i]] = true removed[#removed + 1] = dropped[i] end
  local ops = {}
  for _, name in ipairs(g.base.ops) do if not set[name] then ops[#ops + 1] = name end end
  g.base.ops = ops
  g.base.dropped = g.base.dropped or {}
  for _, name in ipairs(removed) do g.base.dropped[#g.base.dropped + 1] = name end
  table.sort(removed)
  return string.format("pruned %d ops unused across %d solutions: %s", #removed, #progs, table.concat(removed, " "))
end

-- Per-bucket enumeration whitelist for the search's narrow phase: the operators that have ever
-- appeared in a solution of this task shape. Alone this is a bad trade (it excludes operators the
-- task turns out to need); it pays off only because the search falls back to the full operator set
-- with the remaining budget, so the narrow phase can only win. The harness decides whether it did.
function ops_impl.fit_conditional_ops(g, ctx)
  if not ctx.corpus or #ctx.corpus < 60 then return nil end
  local by_bucket = {}
  for _, e in ipairs(ctx.corpus) do
    if e.bucket then
      local ok, node = pcall(program.parse, e.expr)
      if ok then
        local b = by_bucket[e.bucket]
        if not b then b = { ops = {}, n = 0 } by_bucket[e.bucket] = b end
        b.n = b.n + 1
        for _, op in ipairs(program.ops_used(node)) do b.ops[op] = true end
      end
    end
  end
  local min_n = ctx.rng:pick({ 10, 12, 16, 20 })
  local cond, fitted = {}, {}
  for bucket, v in pairs(by_bucket) do
    if v.n >= min_n then
      local count = 0
      for _ in pairs(v.ops) do count = count + 1 end
      -- a whitelist that is nearly the whole DSL narrows nothing and only costs a phase
      if count < #g.base.ops * 0.6 then
        cond[bucket] = v.ops
        fitted[#fitted + 1] = bucket .. "(" .. count .. " ops/" .. v.n .. " sol)"
      end
    end
  end
  if #fitted == 0 then return nil end
  g.policy.cond_ops = cond
  g.policy.two_phase = true
  table.sort(fitted)
  return string.format("per-bucket enumeration whitelists (min %d solutions): %s", min_n, table.concat(fitted, " "))
end

function ops_impl.reorder_ops(g, ctx)
  local progs = solved_programs(ctx)
  if #progs < 3 then return nil end
  local cnt = op_counts(progs)
  local ops = g.base.ops
  local idx = {}
  for i, n in ipairs(ops) do idx[n] = i end
  table.sort(ops, function(a, b)
    local ca, cb = cnt[a] or 0, cnt[b] or 0
    if ca ~= cb then return ca > cb end
    return idx[a] < idx[b]
  end)
  return "reordered enumeration by solution usage"
end

function ops_impl.perturb_hyper(g, ctx)
  local rng = ctx.rng
  local p = g.policy
  local choice = rng:int(1, 13)
  if choice == 13 then
    p.bidirectional = not p.bidirectional
    return "bidirectional -> " .. tostring(p.bidirectional)
  elseif choice == 12 then
    p.binary_meet = not p.binary_meet
    return "binary_meet -> " .. tostring(p.binary_meet)
  elseif choice == 11 then
    p.back_max_cost = math.max(4, math.min(12, (p.back_max_cost or 6) + rng:pick({ -2, 2 })))
    return "back_max_cost -> " .. p.back_max_cost
  elseif choice == 10 then
    p.back_after_cost = math.max(1, math.min(7, (p.back_after_cost or 3) + rng:pick({ -1, 1 })))
    return "back_after_cost -> " .. p.back_after_cost
  elseif choice == 9 then
    p.two_phase = not p.two_phase
    return "two_phase -> " .. tostring(p.two_phase)
  elseif choice == 8 then
    p.phase1_frac = rng:pick({ 0.3, 0.4, 0.5, 0.6, 0.7 })
    return "phase1_frac -> " .. p.phase1_frac
  elseif choice == 7 then
    p.coerce_ic = not p.coerce_ic
    return "coerce_ic (int<->colour bank sharing) -> " .. tostring(p.coerce_ic)
  elseif choice == 1 then
    local d = rng:pick({ -1, 1 })
    p.max_cost = math.max(5, math.min(14, p.max_cost + d))
    return "max_cost -> " .. p.max_cost
  elseif choice == 2 then
    local f = rng:pick({ 0.7, 1.4 })
    p.bank_cap = math.max(100, math.min(2000, math.floor(p.bank_cap * f)))
    return "bank_cap -> " .. p.bank_cap
  elseif choice == 3 then
    p.jit = not p.jit
    return "jit -> " .. tostring(p.jit)
  elseif choice == 4 then
    p.jit_rate = p.jit_rate == 1 and 2 or 1
    return "jit_rate -> " .. p.jit_rate
  elseif choice == 5 then
    p.jit_min_match = p.jit_min_match == 1 and 2 or 1
    return "jit_min_match -> " .. p.jit_min_match
  else
    p.default_cost = p.default_cost == 2 and 3 or 2
    return "default_cost -> " .. p.default_cost
  end
end

function ops_impl.const_tune(g, ctx)
  local rng = ctx.rng
  local ty = rng:pick({ "I", "C" })
  local pool = ty == "I" and { 4, 5, 6, 7, 8, 9, 10, -1 } or { 6, 7, 8, 9 }
  local list = g.policy.consts[ty]
  local have = {}
  for _, v in ipairs(list) do have[v] = true end
  if rng:float() < 0.6 then
    local opts = {}
    for _, v in ipairs(pool) do if not have[v] then opts[#opts + 1] = v end end
    if #opts == 0 then return nil end
    local v = rng:pick(opts)
    list[#list + 1] = v
    table.sort(list)
    return "add const " .. ty .. " " .. v
  else
    if #list <= 2 then return nil end
    local i = rng:int(#list)
    local v = table.remove(list, i)
    return "remove const " .. ty .. " " .. v
  end
end

function ops_impl.prune_library(g, ctx)
  if #g.lib == 0 then return nil end
  local progs = solved_programs(ctx)
  local cnt = op_counts(progs)
  local unused = {}
  for i, e in ipairs(g.lib) do if not cnt[e.name] then unused[#unused + 1] = i end end
  if #unused == 0 then return nil end
  local i = unused[ctx.rng:int(#unused)]
  local e = table.remove(g.lib, i)
  g.policy.cost[e.name] = nil
  return "pruned unused " .. e.name .. "=" .. e.expr
end

function ops_impl.drop_op(g, ctx)
  local progs = solved_programs(ctx)
  if #progs < 120 then return nil end
  local cnt = op_counts(progs)
  local unused = {}
  for i, name in ipairs(g.base.ops) do if not cnt[name] then unused[#unused + 1] = i end end
  if #unused == 0 or #g.base.ops <= 20 then return nil end
  local i = unused[ctx.rng:int(#unused)]
  local name = table.remove(g.base.ops, i)
  g.base.dropped = g.base.dropped or {}
  g.base.dropped[#g.base.dropped + 1] = name
  return "dropped unused op " .. name
end

function ops_impl.restore_op(g, ctx)
  if not g.base.dropped or #g.base.dropped == 0 then return nil end
  local i = ctx.rng:int(#g.base.dropped)
  local name = table.remove(g.base.dropped, i)
  g.base.ops[#g.base.ops + 1] = name
  return "restored op " .. name
end

function ops_impl.strategy_swap(g, ctx)
  g.policy.strategy = g.policy.strategy == "probe" and "levelwise" or "probe"
  return "strategy -> " .. g.policy.strategy
end

-- meta: {tried={op=n}, accepted={op=n}}
function M.choose_operator(meta, rng, exclude)
  local weights, total = {}, 0
  for _, op in ipairs(M.operators) do
    if not exclude[op] then
      local t, a = (meta.tried[op] or 0), (meta.accepted[op] or 0)
      local w = (a + 1) / (t + 2) + 0.15 -- Laplace-smoothed success rate + exploration floor
      weights[#weights + 1] = { op, w }
      total = total + w
    end
  end
  if #weights == 0 then return nil end
  local x = rng:float() * total
  for _, e in ipairs(weights) do
    x = x - e[2]
    if x <= 0 then return e[1] end
  end
  return weights[#weights][1]
end

function M.make_candidate(champion, ctx, meta, used)
  local exclude = {}
  for op in pairs(used or {}) do exclude[op] = true end
  for _ = 1, #M.operators do
    local op = M.choose_operator(meta, ctx.rng, exclude)
    if not op then break end
    local g = genome.clone(champion)
    local ok, desc = pcall(ops_impl[op], g, ctx)
    if ok and desc then
      return g, op, desc
    end
    exclude[op] = true
    if not ok then io.stderr:write("operator " .. op .. " failed: " .. tostring(desc) .. "\n") end
  end
  return nil
end

M.impl = ops_impl
return M
  end

  -- ==== rsi/kernel/research.lua ====
  package.preload['rsi.kernel.research'] = function(...)
-- Scheduled internet research. Honest scope: without a language model in the loop, the system cannot
-- read a paper and derive a mechanism from it. What it CAN do automatically and does here:
--   1. pull fresh external benchmark tasks (ARC-AGI-1 / ARC-AGI-2 public training tasks) into the
--      external, never-trained-on evaluation set, so evaluation keeps changing under the system;
--   2. pull recent arXiv abstracts on program synthesis / library learning / self-improvement, dedupe,
--      keep a keyword-signal timeline, and surface them on the dashboard for the human researcher.
-- Hypotheses that drive experiments come from the system's own experimental data (see mutate.lua).
local json = require("rsi.kernel.json")
local mechanisms = require("rsi.kernel.mechanisms")
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

-- The most actionable paper written to papers.jsonl at or after `since`: the pick of what THIS run
-- actually downloaded. recent_papers ranks everything ever fetched, which answers a different
-- question. Returns nil when the run brought nothing new in.
function M.top_new(root, since)
  local best = nil
  for _, p in ipairs(json.read_lines(root .. "/data/research/papers.jsonl")) do
    if (p.fetched or 0) >= (since or 0) then
      if not best or (p.actionability or 0) > (best.actionability or 0) then best = p end
    end
  end
  return best
end

function M.registry()
  return mechanisms
end

return M
  end

  -- ==== rsi/kernel/narrator.lua ====
  package.preload['rsi.kernel.narrator'] = function(...)
-- The narrator: the system's account of itself, in English, for its own future reference.
--
-- WHAT THIS IS NOT. It is not a language model. There is no neural network, no training on text, no
-- external API, and it cannot say anything that is not already a number somewhere in this system.
-- Calling it one would be the same overclaim this project has refused everywhere else. What it is:
-- a procedural generator that turns measurements into prose, with the phrasing varied by a seeded
-- RNG and the *content* pinned to audited facts.
--
-- WHY IT EXISTS. JOURNAL.md is a ledger -- tables, deltas, p-values -- and answers "what are the
-- numbers". This answers "what happened and what did it mean", in a form you can read start to
-- finish, or hand to a future session to catch up. That is the history it keeps.
--
-- HOW ACCURACY IS ENFORCED, rather than hoped for. Every sentence declares which facts it uses. The
-- facts are gathered once from the run's results, and then INDEPENDENTLY RECOMPUTED from the raw
-- source by `audit`. A sentence whose facts disagree with the recomputation is never printed as
-- truth: it is printed, struck, and reissued with the corrected value, and the correction is written
-- to the history alongside it. So a bug in the gathering shows up as a visible correction rather
-- than as a confident falsehood. That is what "writes and corrects itself" means here -- a real
-- consistency check with a visible outcome, not a typing animation.
--
-- EMPHASIS. Words are capitalised only where a stated rule fires: a result significant under both
-- tests, a regression loss, a saturated benchmark, a new champion. At most `caps_budget` spans per
-- narration, spent on the highest-significance events first, so capitals keep meaning something.
local RNG = require("rsi.kernel.rng")
local json = require("rsi.kernel.json")
local M = {}

M.CAPS_BUDGET = 3

-- ---------------------------------------------------------------- facts

-- Gather the quantities the narration is allowed to talk about. Nothing outside this table can be
-- mentioned, because every phrasing interpolates from it.
function M.gather(raw)
  local f = {}
  f.gen = raw.gen
  f.fingerprint = raw.fingerprint
  f.heldout_solved = raw.heldout.solved
  f.heldout_n = raw.heldout.n
  f.heldout_pct = raw.heldout.n > 0 and (100 * raw.heldout.solved / raw.heldout.n) or 0
  f.adv_solved = raw.adversarial.solved
  f.adv_n = raw.adversarial.n
  f.regr_solved = raw.regression.solved
  f.regr_n = raw.regression.n
  f.ext_solved = raw.external.solved
  f.ext_n = raw.external.n
  f.candidates = #raw.candidates
  f.accepted = raw.accepted and 1 or 0
  f.corpus = raw.corpus_size or 0
  f.library = raw.library_size or 0
  f.nodes = math.floor((raw.heldout.nodes_mean or 0) + 0.5)
  f.best_delta_pp = 0
  f.best_operator = nil
  f.best_p = nil
  f.rejects_screened = 0
  f.rejects_regression = 0
  for _, c in ipairs(raw.candidates) do
    local d = (c.heldout_delta or 0) * 100
    if d > f.best_delta_pp then
      f.best_delta_pp = d
      f.best_operator = c.operator
      f.best_p = c.p_value
    end
    if c.reason and c.reason:find("screened out", 1, true) then f.rejects_screened = f.rejects_screened + 1 end
    if c.reason and c.reason:find("regression:", 1, true) then f.rejects_regression = f.rejects_regression + 1 end
  end
  -- The external ARC attempt. These were already gathered and then never spoken about: no sentence
  -- used them, so the one split that is not self-generated never reached the account. It does now.
  f.ext_pct = (raw.external.n or 0) > 0 and (100 * raw.external.solved / raw.external.n) or nil
  f.ext_delta = raw.external_delta          -- solved this generation minus solved last generation
  -- Research, when a fetch actually ran this generation. nil (and so unspeakable) when it did not.
  if raw.research then
    f.papers_new = raw.research.papers_new or 0
    f.arc_new = raw.research.arc_new or 0
    f.research_errors = #(raw.research.errors or {})
    f.top_paper = raw.research.top_paper        -- title, already trimmed to one bounded line
    f.top_paper_gap = raw.research.top_paper_gap
  end
  f.top_challenge = raw.challenge and raw.challenge[1] and raw.challenge[1].family or nil
  f.top_challenge_pct = raw.challenge and raw.challenge[1] and (100 * raw.challenge[1].solve_rate) or nil
  f.saturated = raw.saturated and #raw.saturated > 0 and raw.saturated[1] or nil
  f.accepted_total = raw.accepted_total or 0
  f.candidates_total = raw.candidates_total or 0
  return f
end

-- Recompute every fact from the raw source by a second route, and report disagreements. This is the
-- guard that makes the narration trustworthy: if `gather` is wrong, this says so.
function M.audit(f, raw)
  local problems = {}
  local function check(key, expected, tol)
    local got = f[key]
    if expected == nil and got == nil then return end
    if got == nil or expected == nil then
      problems[#problems + 1] = { key = key, stated = got, actual = expected }
      return
    end
    if type(expected) == "number" then
      if math.abs(got - expected) > (tol or 0) then
        problems[#problems + 1] = { key = key, stated = got, actual = expected }
      end
    elseif got ~= expected then
      problems[#problems + 1] = { key = key, stated = got, actual = expected }
    end
  end

  -- recount from the per-task vectors rather than trusting the summary fields
  local solved = 0
  for _, r in ipairs(raw.heldout.per_task or {}) do solved = solved + (r.solved or 0) end
  if raw.heldout.per_task and #raw.heldout.per_task > 0 then
    check("heldout_solved", solved)
    check("heldout_n", #raw.heldout.per_task)
    check("heldout_pct", 100 * solved / #raw.heldout.per_task, 0.05)
  end
  local adv = 0
  for _, r in ipairs(raw.adversarial.per_task or {}) do adv = adv + (r.solved or 0) end
  if raw.adversarial.per_task and #raw.adversarial.per_task > 0 then
    check("adv_solved", adv)
    check("adv_n", #raw.adversarial.per_task)
  end
  local ext = 0
  for _, r in ipairs((raw.external or {}).per_task or {}) do ext = ext + (r.solved or 0) end
  if raw.external and raw.external.per_task and #raw.external.per_task > 0 then
    check("ext_solved", ext)
    check("ext_n", #raw.external.per_task)
    check("ext_pct", 100 * ext / #raw.external.per_task, 0.05)
  end
  check("candidates", #raw.candidates)
  local acc = 0
  for _, c in ipairs(raw.candidates) do if c.accepted then acc = 1 end end
  check("accepted", acc)
  return problems
end

-- ---------------------------------------------------------------- phrasing

local function pct(x) return string.format("%.1f%%", x) end

-- Each entry: a list of equivalent phrasings and the facts it depends on. Varying the wording while
-- the asserted content stays fixed is what makes this procedural rather than a fixed printf; the
-- selftest checks every phrasing of every sentence against the same audit.
local SENTENCES = {
  -- Research, spoken only in the generations where a fetch actually ran. The counts are measured;
  -- the title is quoted verbatim from the fetched record (sanitised to one bounded line where it is
  -- gathered) rather than composed, so nothing here invents a paper that does not exist.
  {
    id = "research_fetch", uses = { "papers_new", "arc_new" },
    forms = {
      function(f) return string.format("Research ran first: %d new paper%s indexed and %d new ARC task%s pulled down.",
        f.papers_new, f.papers_new == 1 and "" or "s", f.arc_new, f.arc_new == 1 and "" or "s") end,
      function(f) return string.format("Before any of that I fetched the feeds: %d paper%s and %d ARC task%s I had not seen.",
        f.papers_new, f.papers_new == 1 and "" or "s", f.arc_new, f.arc_new == 1 and "" or "s") end,
    },
  },
  {
    id = "research_paper", uses = { "top_paper" },
    when = function(f) return f.top_paper ~= nil end,
    forms = {
      function(f) return string.format("The one I ranked highest was \"%s\"%s.", f.top_paper,
        f.top_paper_gap and (", which touches " .. f.top_paper_gap .. ", something I do not have") or "") end,
      function(f) return string.format("Top of that reading list: \"%s\"%s.", f.top_paper,
        f.top_paper_gap and (" -- it is about " .. f.top_paper_gap .. ", a declared gap of mine") or "") end,
    },
  },
  {
    id = "research_errors", uses = { "research_errors" },
    when = function(f) return f.research_errors and f.research_errors > 0 end,
    forms = {
      function(f) return string.format("%d of those fetches failed outright, so this reading is thinner than it looks.", f.research_errors) end,
      function(f) return string.format("%d feed%s would not answer, and what did not arrive cannot have been read.",
        f.research_errors, f.research_errors == 1 and "" or "s") end,
    },
  },
  {
    id = "standing", uses = { "gen", "heldout_solved", "heldout_n", "heldout_pct" },
    forms = {
      function(f) return string.format("Generation %d closed with %d of %d held-out tasks solved, %s.",
        f.gen, f.heldout_solved, f.heldout_n, pct(f.heldout_pct)) end,
      function(f) return string.format("At the end of generation %d I stood at %s on the secret split, %d of %d.",
        f.gen, pct(f.heldout_pct), f.heldout_solved, f.heldout_n) end,
      function(f) return string.format("Generation %d: %d solved out of %d held-out tasks (%s).",
        f.gen, f.heldout_solved, f.heldout_n, pct(f.heldout_pct)) end,
    },
  },
  {
    id = "supporting", uses = { "adv_solved", "adv_n", "regr_n", "nodes" },
    forms = {
      function(f) return string.format("The adversarial split gave %d of %d, the regression suite held %d task%s, and a task cost me %d search nodes on average.",
        f.adv_solved, f.adv_n, f.regr_n, f.regr_n == 1 and "" or "s", f.nodes) end,
      function(f) return string.format("Adversarially I managed %d of %d; %d regression task%s stood behind me; the mean task took %d nodes.",
        f.adv_solved, f.adv_n, f.regr_n, f.regr_n == 1 and "" or "s", f.nodes) end,
    },
  },
  {
    id = "verdict_none", uses = { "candidates", "best_delta_pp" },
    when = function(f) return f.accepted == 0 end,
    forms = {
      function(f)
        if f.best_operator then
          return string.format("I tried %d candidate%s and kept none. The closest was %s at +%.1fpp, which the tests would not call real.",
            f.candidates, f.candidates == 1 and "" or "s", f.best_operator, f.best_delta_pp)
        end
        return string.format("I tried %d candidate%s and kept none; not one of them gained ground.",
          f.candidates, f.candidates == 1 and "" or "s")
      end,
      function(f)
        if f.best_operator then
          return string.format("None of the %d candidates survived. %s came nearest with +%.1fpp, still inside the noise.",
            f.candidates, f.best_operator, f.best_delta_pp)
        end
        return string.format("None of the %d candidates survived, and none even gained.", f.candidates)
      end,
    },
  },
  {
    id = "verdict_accept", uses = { "best_operator", "best_delta_pp" },
    when = function(f) return f.accepted == 1 end,
    caps = { "NEW CHAMPION" },
    forms = {
      function(f) return string.format("NEW CHAMPION: %s gained +%.1fpp and cleared both tests, so I kept it.",
        f.best_operator or "a candidate", f.best_delta_pp) end,
      function(f) return string.format("I have a NEW CHAMPION. %s was worth +%.1fpp and passed the bootstrap and the sign test alike.",
        f.best_operator or "A candidate", f.best_delta_pp) end,
    },
  },
  {
    id = "screening", uses = { "rejects_screened" },
    when = function(f) return f.rejects_screened > 0 end,
    forms = {
      function(f) return string.format("%d of them solved strictly fewer held-out tasks and were screened out before the other splits were even run.",
        f.rejects_screened) end,
      function(f) return string.format("%d were dropped on the held-out screen alone, which no acceptance clause could have survived anyway.",
        f.rejects_screened) end,
    },
  },
  {
    id = "regression_loss", uses = { "rejects_regression" },
    when = function(f) return f.rejects_regression > 0 end,
    caps = { "LOST GROUND" },
    forms = {
      function(f) return string.format("%d candidate%s LOST GROUND on the regression suite, breaking something an earlier champion could already do.",
        f.rejects_regression, f.rejects_regression == 1 and "" or "s") end,
    },
  },
  {
    id = "challenge", uses = { "top_challenge", "top_challenge_pct" },
    when = function(f) return f.top_challenge ~= nil end,
    forms = {
      function(f) return string.format("The family with most left to teach me is %s, which I solve %s of the time.",
        f.top_challenge, pct(f.top_challenge_pct)) end,
      function(f) return string.format("%s is where I still learn the most: %s solved, and it still separates one candidate from another.",
        f.top_challenge, pct(f.top_challenge_pct)) end,
    },
  },
  {
    id = "saturation", uses = { "saturated" },
    when = function(f) return f.saturated ~= nil end,
    caps = { "SATURATED" },
    forms = {
      function(f) return string.format("%s is SATURATED -- I solve it almost every time and it no longer tells candidates apart -- so a harder variant was spawned from it.",
        f.saturated) end,
    },
  },
  -- The external ARC attempt. This is the only split the system did not generate for itself, so it
  -- is the only number here that answers "can it do the real thing"; it belongs in the account.
  {
    id = "external_attempt", uses = { "ext_solved", "ext_n", "ext_pct" },
    when = function(f) return f.ext_n and f.ext_n > 0 end,
    forms = {
      function(f) return string.format("On the downloaded ARC tasks -- the ones nobody here generated -- I attempted %d and solved %d, %s.",
        f.ext_n, f.ext_solved, pct(f.ext_pct)) end,
      function(f) return string.format("My ARC attempt this generation was %d of %d, %s, on tasks the benchmark never trained me on.",
        f.ext_solved, f.ext_n, pct(f.ext_pct)) end,
      function(f) return string.format("Against the external ARC corpus I got %d of %d right (%s).",
        f.ext_solved, f.ext_n, pct(f.ext_pct)) end,
    },
  },
  {
    id = "external_move", uses = { "ext_delta" },
    when = function(f) return f.ext_delta ~= nil and f.ext_delta ~= 0 end,
    forms = {
      function(f) return string.format("That is %d %s than the last generation that attempted them.",
        math.abs(f.ext_delta), f.ext_delta > 0 and "more" or "fewer") end,
      function(f) return string.format("Compared with the previous attempt I am %s by %d task%s there.",
        f.ext_delta > 0 and "up" or "down", math.abs(f.ext_delta), math.abs(f.ext_delta) == 1 and "" or "s") end,
    },
  },
  {
    id = "memory", uses = { "corpus", "library", "accepted_total", "candidates_total" },
    forms = {
      function(f) return string.format("I have %d solved programs on record and %d learned abstraction%s, from %d accepted change%s out of %d candidates in all.",
        f.corpus, f.library, f.library == 1 and "" or "s", f.accepted_total, f.accepted_total == 1 and "" or "s", f.candidates_total) end,
      function(f) return string.format("My corpus stands at %d solved programs; the library holds %d; across the whole run %d of %d candidates were kept.",
        f.corpus, f.library, f.accepted_total, f.candidates_total) end,
    },
  },
}

-- Build the narration. Deterministic given (facts, seed): same generation narrates the same way
-- twice, which matters because the history has to be stable when regenerated.
function M.compose(f, seed)
  local rng = RNG.new(seed or ("narrate:" .. tostring(f.gen)))
  local out, caps_used = {}, 0
  for _, s in ipairs(SENTENCES) do
    if not s.when or s.when(f) then
      local ok = true
      for _, key in ipairs(s.uses) do if f[key] == nil then ok = false break end end
      if ok then
        local form = s.forms[rng:int(#s.forms)]
        local text = form(f)
        if s.caps and caps_used >= M.CAPS_BUDGET then
          for _, span in ipairs(s.caps) do
            local lower = span:sub(1, 1) .. span:sub(2):lower()
            text = text:gsub(span, lower, 1)
          end
        elseif s.caps then
          caps_used = caps_used + #s.caps
        end
        out[#out + 1] = { id = s.id, text = text, uses = s.uses }
      end
    end
  end
  return out
end

-- ---------------------------------------------------------------- output

local sleep_works = nil
local function nap(seconds)
  if seconds <= 0 or sleep_works == false then return end
  local ok = os.execute("sleep " .. seconds)
  if sleep_works == nil then sleep_works = (ok == true or ok == 0) end
end

-- Type it out a word at a time. `delay` of 0 prints instantly, which is what the loop uses so a
-- generation is not slowed by its own narration.
function M.stream(text, delay)
  delay = delay or 0
  local first = true
  for word in text:gmatch("%S+") do
    io.write(first and "" or " ", word)
    io.flush()
    first = false
    nap(delay)
  end
  io.write("\n")
  io.flush()
end

-- Narrate, auditing as it goes. A sentence whose facts fail the audit is struck and reissued.
-- Returns the sentences actually asserted, plus any corrections made.
function M.narrate(raw, opts)
  opts = opts or {}
  local delay = opts.delay or 0
  local f = M.gather(raw)
  local problems = M.audit(f, raw)
  local bad = {}
  for _, p in ipairs(problems) do bad[p.key] = p end

  local sentences = M.compose(f, opts.seed)
  local asserted, corrections, ids = {}, {}, {}

  for _, s in ipairs(sentences) do
    local wrong = nil
    for _, key in ipairs(s.uses) do if bad[key] then wrong = bad[key] break end end
    if wrong then
      -- print what it was about to claim, then withdraw it in the open
      if not opts.quiet then
        M.stream("  " .. s.text, delay)
        M.stream(string.format("  ^ CORRECTION: '%s' was stated as %s but recomputes to %s. Reissuing.",
          wrong.key, tostring(wrong.stated), tostring(wrong.actual)), delay)
      end
      local fixed = {}
      for k, v in pairs(f) do fixed[k] = v end
      fixed[wrong.key] = wrong.actual
      local redone = M.compose(fixed, opts.seed)
      local replacement = s.text
      for _, r in ipairs(redone) do if r.id == s.id then replacement = r.text end end
      if not opts.quiet then M.stream("  " .. replacement, delay) end
      asserted[#asserted + 1] = replacement
      ids[#ids + 1] = s.id
      corrections[#corrections + 1] = { key = wrong.key, stated = wrong.stated, actual = wrong.actual }
    else
      if not opts.quiet then M.stream("  " .. s.text, delay) end
      asserted[#asserted + 1] = s.text
      ids[#ids + 1] = s.id
    end
  end

  return { gen = f.gen, time = os.time(), sentences = asserted, ids = ids, corrections = corrections,
    facts = f, audited_clean = #problems == 0 }
end

-- The two or three lines that go on the public page. The full narration is kept in
-- rsi/data/narrative.jsonl and rendered into HISTORY.md; this picks the short form for live.json,
-- preferring what the run actually did in the world (the ARC attempt, the papers it pulled down)
-- over the internal bookkeeping, and falling back to the head of the narration when neither ran.
-- These are the same audited sentences, not a second, unaudited rendering of the same facts.
M.HIGHLIGHT_ORDER = { "external_attempt", "external_move", "research_fetch", "research_paper",
                      "verdict_accept", "standing", "verdict_none", "research_errors", "challenge" }

function M.highlights(res, n)
  n = n or 3
  local by_id, taken, out = {}, {}, {}
  for i, id in ipairs(res.ids or {}) do
    if id and not by_id[id] then by_id[id] = res.sentences[i] end
  end
  for _, id in ipairs(M.HIGHLIGHT_ORDER) do
    if #out >= n then break end
    if by_id[id] then out[#out + 1] = by_id[id] taken[by_id[id]] = true end
  end
  for _, text in ipairs(res.sentences or {}) do
    if #out >= n then break end
    if not taken[text] then out[#out + 1] = text taken[text] = true end
  end
  return out
end

function M.record(root, entry)
  json.append_line(root .. "/data/narrative.jsonl", entry)
end

function M.render_history(root)
  local all = json.read_lines(root .. "/data/narrative.jsonl")
  local out = {}
  local function w(s) out[#out + 1] = s end
  w("# CELL4 history")
  w("")
  w("The system's own account of what happened, newest first. Written by")
  w("`rsi/kernel/narrator.lua`, which is a procedural generator over audited measurements -- **not a")
  w("language model**: there is no network, no training on text, no external call, and it cannot")
  w("state anything that is not a measured number. Phrasing varies; content does not.")
  w("")
  w("Every sentence declares the facts it uses, and those facts are recomputed from the raw results")
  w("before the sentence is allowed to stand. Where a recomputation disagreed, the correction is")
  w("recorded below the entry rather than quietly applied.")
  w("")
  w("Capitals mark events by rule, not for decoration: a result significant under both tests, a")
  w("regression loss, a saturated benchmark, a new champion.")
  w("")
  for i = #all, 1, -1 do
    local e = all[i]
    w(string.format("## Generation %d — %s", e.gen or 0, os.date("!%Y-%m-%d %H:%M UTC", e.time or 0)))
    w("")
    for _, s in ipairs(e.sentences or {}) do w(s) end
    w("")
    if e.corrections and #e.corrections > 0 then
      for _, c in ipairs(e.corrections) do
        w(string.format("> Corrected while writing: `%s` was stated as %s and recomputed to %s.",
          c.key, tostring(c.stated), tostring(c.actual)))
      end
      w("")
    elseif e.audited_clean == false then
      w("> This entry failed its audit in a way the narrator could not repair.")
      w("")
    end
  end
  local fh = assert(io.open(root .. "/../HISTORY.md", "w"))
  fh:write(table.concat(out, "\n"), "\n")
  fh:close()
end

M.SENTENCES = SENTENCES
return M
  end

  -- ==== rsi/kernel/benchmarks.lua ====
  package.preload['rsi.kernel.benchmarks'] = function(...)
-- Benchmark management: secret held-out salts, fresh adversarial splits, regression suite,
-- external (ARC) tasks, optimisation-pressure tracking and rotation, generated family variants.
local json = require("rsi.kernel.json")
local tasks = require("rsi.kernel.tasks")
local RNG = require("rsi.kernel.rng")
local M = {}

local function now_salt()
  return string.format("%x-%x-%x", os.time(), math.floor(os.clock() * 1e6), RNG.new(os.time()):int(1, 1e9))
end

function M.load(root)
  local path = root .. "/state/bench.json"
  local s = json.read(path)
  if not s then
    s = {
      secret_salt = now_salt(), heldout_epoch = 1, pressure = {}, burned = {}, variants = {},
      regression = {}, rotations = {}, created = os.time(),
      -- the installation's latent world: which motifs recur across every split
      world_salt = now_salt(), motif_epoch = 1,
    }
    os.execute("mkdir -p '" .. root .. "/state'")
    json.write(path, s)
  end
  -- register generated family variants
  for name, def in pairs(s.variants or {}) do
    if not tasks.families[name] then
      tasks.families[name] = def
      tasks.family_order[#tasks.family_order + 1] = name
    end
  end
  s._path = path
  return s
end

function M.save(s)
  local p = s._path
  s._path = nil
  json.write(p, s)
  s._path = p
end

local function active_families(s)
  local out = {}
  for _, f in ipairs(tasks.family_order) do
    if not s.burned[f] then out[#out + 1] = f end
  end
  return out
end

function M.build_splits(s, cfg, gen)
  local splits = { train = {}, heldout = {}, adversarial = {}, regression = {} }
  tasks.set_world(s.world_salt, s.motif_epoch)
  local fams = active_families(s)
  for _, f in ipairs(fams) do
    for _, t in ipairs(tasks.generate_set(f, "train:" .. gen, cfg.train_per_family)) do splits.train[#splits.train + 1] = t end
    for _, t in ipairs(tasks.generate_set(f, s.secret_salt .. ":h" .. s.heldout_epoch, cfg.heldout_per_family)) do splits.heldout[#splits.heldout + 1] = t end
  end
  for _, f in ipairs(s.adversarial_families or cfg.adversarial_families) do
    if tasks.families[f] then
      for _, t in ipairs(tasks.generate_set(f, s.secret_salt .. ":adv:" .. gen, cfg.adversarial_per_family)) do splits.adversarial[#splits.adversarial + 1] = t end
    end
  end
  -- regression tasks regenerate under the motif epoch they were first solved in, so a later
  -- rotation of the world cannot silently change what the suite is testing
  for _, spec in ipairs(s.regression) do
    tasks.set_world(s.world_salt, spec.motif_epoch or 1)
    local t = tasks.generate(spec.family, spec.salt, spec.index)
    if t then splits.regression[#splits.regression + 1] = t end
  end
  tasks.set_world(s.world_salt, s.motif_epoch)
  return splits
end

-- Record held-out tasks the accepted champion solved, so no later champion may lose them.
function M.extend_regression(s, cfg, heldout_tasks, results)
  local have = {}
  for _, spec in ipairs(s.regression) do have[spec.family .. "|" .. spec.salt .. "|" .. spec.index] = true end
  local added = 0
  for i, r in ipairs(results.per_task) do
    if r.solved == 1 then
      local t = heldout_tasks[i]
      local salt = s.secret_salt .. ":h" .. s.heldout_epoch
      local index = tonumber(t.id:match("#(%d+)$"))
      local key = t.family .. "|" .. salt .. "|" .. index
      if not have[key] then
        s.regression[#s.regression + 1] = { family = t.family, salt = salt, index = index, gen = results.gen,
          motif_epoch = s.motif_epoch }
        have[key] = true
        added = added + 1
      end
    end
  end
  while #s.regression > cfg.regression_cap do table.remove(s.regression, 1) end
  return added
end

-- Which family contributed most to the accepted candidate's held-out gain?
function M.driver_family(heldout_tasks, champ, cand)
  local gain = {}
  for i, t in ipairs(heldout_tasks) do
    local d = (cand.per_task[i].solved - champ.per_task[i].solved)
    gain[t.family] = (gain[t.family] or 0) + d
  end
  local best, bv = nil, 0
  for f, v in pairs(gain) do if v > bv or (v == bv and best and f < best) then best, bv = f, v end end
  return best, bv
end

-- Spawn a harder variant of a family (deeper compositions / bigger inputs / hidden ops on)
local function spawn_variant(s, base_name)
  local base = tasks.families[base_name]
  if not base then return nil end
  local k = 1
  while tasks.families[base_name .. "_v" .. k] do k = k + 1 end
  local name = base_name .. "_v" .. k
  local def = {}
  for kk, v in pairs(base) do
    if type(v) == "table" then local c = {} for i, x in ipairs(v) do c[i] = x end def[kk] = c else def[kk] = v end
  end
  def.depth = { base.depth[1] + 1, base.depth[2] + 1 }
  def.hidden = true
  if def.maxlen then def.maxlen = def.maxlen + 2 end
  if def.maxdim then def.maxdim = math.min(10, def.maxdim + 2) end
  s.variants[name] = def
  tasks.families[name] = def
  tasks.family_order[#tasks.family_order + 1] = name
  return name
end

-- A family that is nearly always solved AND has stopped separating candidates has nothing left to
-- teach. Rather than wait for an acceptance to trigger a rotation, spawn a harder variant from it as
-- soon as the challenge ranking says it is spent. This is how the system goes looking for harder
-- work instead of waiting to be given it.
function M.spawn_from_saturation(s, saturated, gen)
  s.saturation_spawned = s.saturation_spawned or {}
  for _, fam in ipairs(saturated or {}) do
    if not s.saturation_spawned[fam] then
      local variant = spawn_variant(s, fam)
      if variant then
        s.saturation_spawned[fam] = gen
        return string.format("saturation at gen %d: '%s' is solved almost always and no longer separates candidates -> spawned harder variant %s", gen, fam, variant)
      end
    end
  end
  return nil
end

-- Point the adversarial split at whatever currently discriminates best.
function M.set_adversarial(s, families)
  if families and #families > 0 then s.adversarial_families = families end
end

-- Called after an acceptance. Returns a description of any rotation performed.
function M.after_accept(s, cfg, driver, gen)
  if not driver then return nil end
  for f in pairs(s.pressure) do if f ~= driver then s.pressure[f] = 0 end end
  s.pressure[driver] = (s.pressure[driver] or 0) + 1
  if s.pressure[driver] >= cfg.pressure_limit then
    s.pressure[driver] = 0
    s.heldout_epoch = s.heldout_epoch + 1
    s.secret_salt = now_salt()
    -- new motifs enter the world, so the abstractions that earned the last acceptances stop being
    -- sufficient; already-solved regression tasks keep their own epoch and stay enforceable
    s.motif_epoch = s.motif_epoch + 1
    local variant = spawn_variant(s, driver)
    s.burned[driver] = (s.burned[driver] or 0) + 1
    if s.burned[driver] >= 2 then s.burned[driver] = true else s.burned[driver] = nil end
    local msg = string.format("benchmark rotation at gen %d: '%s' drove %d consecutive acceptances -> secret held-out epoch %d, motif epoch %d, spawned variant %s",
      gen, driver, cfg.pressure_limit, s.heldout_epoch, s.motif_epoch, tostring(variant))
    s.rotations[#s.rotations + 1] = { gen = gen, driver = driver, epoch = s.heldout_epoch,
      motif_epoch = s.motif_epoch, variant = variant }
    -- the regression suite keeps its own salts, so old solved tasks remain enforceable
    return msg
  end
  return nil
end

-- External benchmark: ARC-format JSON files in data/arc/*.json (train/test pairs of grids)
function M.load_external(root, cap)
  local dir = root .. "/data/arc"
  local list = {}
  local p = io.popen("ls '" .. dir .. "' 2>/dev/null")
  if p then
    for name in p:lines() do if name:match("%.json$") then list[#list + 1] = name end end
    p:close()
  end
  table.sort(list)
  local out = {}
  for _, name in ipairs(list) do
    if #out >= cap then break end
    local d = json.read(dir .. "/" .. name)
    if d and d.train and d.test then
      local function grid(a)
        local g = { h = #a, w = #a[1] }
        for r = 1, g.h do local row = {} for c = 1, g.w do row[c] = a[r][c] end g[r] = row end
        return g
      end
      local ok, t = pcall(function()
        local train, test = {}, {}
        for i, ex in ipairs(d.train) do train[i] = { input = grid(ex.input), output = grid(ex.output) } end
        for i, ex in ipairs(d.test) do if ex.output then test[#test + 1] = { input = grid(ex.input), output = grid(ex.output) } end end
        if #test == 0 then error("no test outputs") end
        return { id = "arc:" .. name:gsub("%.json$", ""), family = "arc", in_type = "G", out_type = "G", train = train, test = test }
      end)
      if ok and t then out[#out + 1] = t end
    end
  end
  return out
end

M.active_families = active_families
return M
  end

  -- ==== rsi/kernel/cycle.lua ====
  package.preload['rsi.kernel.cycle'] = function(...)
-- One generation of the research loop:
--   research (if due) -> build splits -> evaluate champion -> generate candidates from evidence ->
--   evaluate candidates -> acceptance rule -> retain / reject -> lineage -> benchmark management -> dashboard
local cfg = require("rsi.config")
local json = require("rsi.kernel.json")
local RNG = require("rsi.kernel.rng")
local genome = require("rsi.kernel.genome")
local evaluate = require("rsi.kernel.evaluate")
local stats = require("rsi.kernel.stats")
local mutate = require("rsi.kernel.mutate")
local benchmarks = require("rsi.kernel.benchmarks")
local lineage = require("rsi.kernel.lineage")
local research = require("rsi.kernel.research")
local dashboard = require("rsi.kernel.dashboard")
local features = require("rsi.kernel.features")
local challenge = require("rsi.kernel.challenge")
local journal = require("rsi.kernel.journal")
local narrator = require("rsi.kernel.narrator")
local M = {}

local ROOT = cfg.root

local function ensure_dirs()
  os.execute(string.format("mkdir -p '%s/state' '%s/www' '%s/versions' '%s/data/arc' '%s/data/research'", ROOT, ROOT, ROOT, ROOT, ROOT))
end

local function load_state()
  local s = json.read(ROOT .. "/state/state.json")
  if not s then
    s = { gen = 0, accepted_total = 0, candidates_total = 0, meta = { tried = {}, accepted = {} }, last_research = 0, log = {} }
  end
  s.meta = s.meta or { tried = {}, accepted = {} }
  return s
end

local function save_state(s) json.write(ROOT .. "/state/state.json", s) end

local function summarize(res)
  local p, lo, hi = stats.wilson(res.solved, res.n)
  return { rate = p, lo = lo, hi = hi, n = res.n, solved = res.solved, partial = res.partial_mean, nodes = res.nodes_mean, time = res.time }
end

-- Liveness heartbeat for the single-writer lock below. Installed once LOCK exists; a no-op until
-- then, and a no-op in any process that is not holding the lock (the stamp file lives inside the
-- lock directory, so the write simply fails when there is no lock).
local touch_lock = function() end

local function progress(phase, extra)
  touch_lock()
  local p = { phase = phase }
  for k, v in pairs(extra or {}) do p[k] = v end
  dashboard.write_progress(ROOT, p)
end

local function eval_split(g, tasks_, label, opts, extra)
  local o = { nodes = cfg.nodes, instructions = cfg.instructions, seconds = cfg.seconds }
  for k, v in pairs(opts or {}) do o[k] = v end
  o.on_progress = function(i, n, solved)
    local e = { done = i, total = n, solved = solved }
    for k, v in pairs(extra or {}) do e[k] = v end
    progress(label, e)
  end
  return evaluate.run(g, tasks_, o)
end

local function eval_all(g, splits, external, label, extra)
  local r = {}
  r.heldout = eval_split(g, splits.heldout, label .. ": held-out", nil, extra)
  r.train = eval_split(g, splits.train, label .. ": visible split", nil, extra)
  r.adversarial = eval_split(g, splits.adversarial, label .. ": adversarial", nil, extra)
  r.regression = eval_split(g, splits.regression, label .. ": regression suite", nil, extra)
  r.external = eval_split(g, external, label .. ": external ARC", { nodes = cfg.external_nodes, seconds = cfg.external_seconds }, extra)
  return r
end

-- The acceptance rule. Returns accepted(bool), reason(string), evidence(table).
local function decide(champ, cand, gen)
  local ev = {}
  -- 1. regression: nothing previously solved may be lost
  if cand.regression.n > 0 and cand.regression.solved < cand.regression.n then
    ev.regression = cand.regression.solved .. "/" .. cand.regression.n
    return false, "regression: lost " .. (cand.regression.n - cand.regression.solved) .. " previously solved task(s)", ev
  end
  ev.regression = cand.regression.solved .. "/" .. cand.regression.n
  -- 2. external non-regression
  if cand.external.n > 0 and cand.external.solved < champ.external.solved then
    return false, string.format("external ARC dropped %d -> %d", champ.external.solved, cand.external.solved), ev
  end
  -- 3. paired held-out comparison
  local a, b = evaluate.vector(champ.heldout), evaluate.vector(cand.heldout)
  local d, p, lo, hi = stats.paired_bootstrap(a, b, cfg.bootstrap_reps, "boot:" .. gen)
  local wins, losses = stats.wins_losses(a, b)
  local sp = stats.sign_test(wins, losses)
  ev.heldout_delta, ev.p_value, ev.ci = d, p, { lo, hi }
  ev.wins, ev.losses, ev.sign_p = wins, losses, sp
  local ad = cand.adversarial.solve_rate - champ.adversarial.solve_rate
  ev.adversarial_delta = ad
  local pa, pb = evaluate.vector(champ.adversarial, "partial"), evaluate.vector(cand.adversarial, "partial")
  ev.adversarial_partial_delta = stats.mean(pb) - stats.mean(pa)
  local train_gain = cand.train.solve_rate - champ.train.solve_rate
  ev.train_delta = train_gain
  ev.nodes_ratio = champ.heldout.nodes_mean > 0 and cand.heldout.nodes_mean / champ.heldout.nodes_mean or 1
  if ad < cfg.adversarial_tolerance then
    return false, string.format("adversarial drop %.1fpp exceeds tolerance", ad * 100), ev
  end
  if d <= 0 and train_gain - d > cfg.overfit_gap then
    return false, string.format("overfit: visible-split gain %.1fpp with no held-out gain", train_gain * 100), ev
  end
  -- Both tests must pass. With few discordant pairs the paired bootstrap is not measuring the
  -- effect: with 3 wins and 0 losses out of 200 it reports p=0.047 simply because a resample almost
  -- always contains one of the three wins, while the exact sign test correctly says 0.125. Taking
  -- either test alone lets that through, so the rule takes the conjunction.
  local significant = d > 0 and p < cfg.alpha and sp < cfg.alpha and wins > losses
  if significant then
    return true, string.format("held-out +%.1fpp (bootstrap p=%.3f, sign p=%.3f, wins %d / losses %d)",
      d * 100, p, sp, wins, losses), ev
  end
  if d >= 0 and losses == 0 and ev.nodes_ratio <= cfg.efficiency_ratio and ev.adversarial_partial_delta >= 0 then
    return true, string.format("efficiency: same solves with %.0f%% of the search nodes, no losses", ev.nodes_ratio * 100), ev
  end
  if d > 0 then
    return false, string.format("held-out +%.1fpp not significant (bootstrap p=%.3f, sign p=%.3f, wins %d / losses %d)",
      d * 100, p, sp, wins, losses), ev
  end
  return false, string.format("no held-out gain (%.1fpp, wins %d / losses %d)", d * 100, wins, losses), ev
end

local function champion_summary(g, r, bench, external_n)
  local lib = {}
  for _, e in ipairs(g.lib) do lib[#lib + 1] = { name = e.name, expr = e.expr, arg = e.arg, arg2 = e.arg2, ret = e.ret, origin = e.origin } end
  return {
    fingerprint = genome.fingerprint(g), heldout = summarize(r.heldout), adversarial = summarize(r.adversarial),
    regression = { solved = r.regression.solved, n = r.regression.n },
    external = { solved = r.external.solved, n = r.external.n },
    train = summarize(r.train), library = lib, library_size = #g.lib, ops = #g.base.ops,
    policy = g.policy,
  }
end

local function write_dashboard(state, bench, champ_g, champ_r, external)
  local arc_on_disk = 0
  local p = io.popen("ls '" .. ROOT .. "/data/arc' 2>/dev/null | wc -l")
  if p then arc_on_disk = tonumber(p:read("*a")) or 0 p:close() end
  local variants = {}
  for name in pairs(bench.variants or {}) do variants[#variants + 1] = name end
  table.sort(variants)
  local burned = {}
  for name, v in pairs(bench.burned or {}) do if v == true then burned[#burned + 1] = name end end
  table.sort(burned)
  dashboard.write_state(ROOT, {
    gen = state.gen, accepted_total = state.accepted_total, candidates_total = state.candidates_total,
    champion = champion_summary(champ_g, champ_r, bench, #external),
    bench = { epoch = bench.heldout_epoch, families = benchmarks.active_families(bench), burned = burned, variants = variants,
      pressure = bench.pressure, rotations = #bench.rotations, regression_size = #bench.regression, arc_on_disk = arc_on_disk },
    research = { last = state.last_research, next_in_s = (state.last_research or 0) + cfg.research_interval - os.time(),
      papers = research.recent_papers(ROOT, 12) },
    challenge = state.challenge, saturated = state.saturated,
    corpus_size = journal.corpus_size(ROOT),
    meta = state.meta, log = state.log,
  })
  dashboard.ensure_html(ROOT)
end

-- Titles arrive off a public feed. Reduce one to a single bounded line before it can reach
-- JOURNAL.md, HISTORY.md or live.json: no control characters, no quote characters that would have to
-- be escaped again downstream, no runaway length.
local function one_line(str, cap)
  if type(str) ~= "string" then return nil end
  cap = cap or 90
  str = str:gsub("%c", " "):gsub('"', "'"):gsub("\\", "/"):gsub("%s+", " ")
  str = str:gsub("^%s+", ""):gsub("%s+$", "")
  if #str > cap then str = str:sub(1, cap - 3) .. "..." end
  return #str > 0 and str or nil
end

local function log(state, msg)
  state.log = state.log or {}
  table.insert(state.log, 1, os.date("!%Y-%m-%d %H:%M:%S") .. " " .. msg)
  while #state.log > 30 do table.remove(state.log) end
  io.write(msg, "\n")
  io.flush()
end

-- Single-writer lock. Two invocations sharing rsi/state interleave their writes and silently corrupt
-- the lineage; mkdir is atomic on every POSIX filesystem, so it is the lock. There is no daemon and
-- no background process here: the lock is a directory, and it is removed before this process exits.
--
-- os.execute's return value has two shapes: Lua 5.1 and LuaJIT return the C `system()` status (0 on
-- success, non-zero otherwise), Lua 5.2+ return true on success and nil on failure. EVERY number is
-- truthy in Lua, so a bare `if os.execute("mkdir ...") then` reports success on 5.1/LuaJIT whether
-- the directory was created or not -- which silently turns this lock into a no-op exactly when two
-- scheduled runs overlap. Test both shapes explicitly.
local function sh_ok(r) return r == true or r == 0 end

local LOCK = ROOT .. "/state/.lock"

-- Staleness is measured against a heartbeat, not against a guess at how long a generation takes. A
-- generation legitimately runs for hours (10 families x 20 held-out + 10 visible, 32 adversarial, up
-- to 160 regression and 60 external tasks at 3-4s each, then the same again for up to 4 candidates),
-- so a fixed "a generation cannot exceed N" timeout is always either too short to be safe or too
-- long to recover from a kill. Instead the holder re-stamps the lock as it works (every progress
-- report, at most once per 10s), and the only silent stretch is the research fetch: 7 arXiv queries
-- plus 2 listings plus <=25 ARC downloads, each capped by `curl --max-time 45`, i.e. ~26 minutes in
-- the pathological all-timeouts case. One hour gives that ~2.3x of headroom while bounding recovery
-- from a hard kill (SIGKILL, host reboot) to one hour rather than to a whole day.
local LOCK_STALE = 3600

local last_stamp = 0
local function write_lock_stamp()
  local f = io.open(LOCK .. "/pid", "w")
  if f then f:write(tostring(os.time())) f:close() end
  last_stamp = os.time()
end

touch_lock = function()
  if os.time() - last_stamp >= 10 then write_lock_stamp() end
end

local function acquire_lock()
  if sh_ok(os.execute("mkdir '" .. LOCK .. "' 2>/dev/null")) then write_lock_stamp() return true end
  local f = io.open(LOCK .. "/pid", "r")
  local age = nil
  if f then
    local t = tonumber(f:read("*a") or "")
    f:close()
    if t then age = os.time() - t end
  end
  if not age then
    -- A lock directory with no readable stamp: a process was killed between mkdir and its first
    -- stamp. Date it now so it becomes breakable one LOCK_STALE from here instead of blocking every
    -- future run forever. This cannot steal a live lock: a live holder rewrites the stamp within
    -- seconds of acquiring it, so a missing stamp means nobody is running.
    write_lock_stamp()
    return false
  end
  if age > LOCK_STALE then
    os.execute("rm -rf '" .. LOCK .. "'")
    if sh_ok(os.execute("mkdir '" .. LOCK .. "' 2>/dev/null")) then write_lock_stamp() return true end
    return false
  end
  return false
end

local function release_lock() os.execute("rm -rf '" .. LOCK .. "'") end

-- One process invocation runs this exactly once and then returns. Nothing below it schedules,
-- sleeps, retries or re-enters: the next generation is a new process started by the scheduler.
function M.step(opts)
  opts = opts or {}
  ensure_dirs()
  if not acquire_lock() then
    error("another generation is already running (" .. LOCK .. "); refusing to share state")
  end
  local ok_run, err = pcall(M.run_generation, opts)
  release_lock()
  if not ok_run then error(err, 0) end
  return err
end

-- `research` on the command line writes the same rsi/state/state.json a generation writes, so it
-- takes the same lock and the same defaulted load_state(). Reading state.json directly and falling
-- back to a bare `{}` (as the CLI used to) had two failure modes: it could overwrite a concurrent
-- generation's committed state with a stale copy, and with no state.json on disk it wrote one that
-- had no `gen` field, after which every later generation died on `state.gen + 1` -- permanently,
-- because the file then existed and load_state's defaults no longer applied.
function M.force_research(opts)
  opts = opts or {}
  ensure_dirs()
  if not acquire_lock() then
    error("a generation is already running (" .. LOCK .. "); refusing to write state concurrently")
  end
  local ok_run, r = pcall(function()
    local state = load_state()
    local res = research.run(ROOT, cfg, state)
    save_state(state)
    return res
  end)
  release_lock()
  if not ok_run then error(r, 0) end
  return r
end

-- Operator escape hatch. A generation killed outright (SIGKILL, host reboot, a scheduler that caps
-- run time) leaves its lock directory behind, and the next runs correctly refuse until LOCK_STALE
-- has passed. That is the safe default, but an operator who knows nothing is running should not have
-- to wait an hour or guess at a path. Refuses while the stamp still looks live unless forced.
function M.unlock(force)
  local f = io.open(LOCK .. "/pid", "r")
  if not f then
    local probe = io.open(LOCK .. "/.probe", "w")
    if not probe then return true, "no lock held" end   -- nothing to clear is not a failure
    probe:close() os.remove(LOCK .. "/.probe")
  end
  local age
  if f then
    local t = tonumber(f:read("*a") or "")
    f:close()
    if t then age = os.time() - t end
  end
  if age and age < 120 and not force then
    return false, string.format("the lock was refreshed %ds ago, so a generation is probably alive; " ..
      "use `unlock force` only if you are certain it is not", age)
  end
  os.execute("rm -rf '" .. LOCK .. "'")
  return true, age and string.format("removed a lock last refreshed %ds ago", age) or "removed an unstamped lock"
end

function M.run_generation(opts)
  local state = load_state()
  local bench = benchmarks.load(ROOT)
  local gen = state.gen + 1
  state.gen = gen
  local rng = RNG.new("gen:" .. gen .. ":" .. (bench.secret_salt or ""))
  local out = { gen = gen, accepted = false }

  -- research
  local research_note = nil
  if not opts.skip_research and research.due(state, cfg) then
    progress("research: fetching arXiv + ARC")
    local since = os.time()
    local r = research.run(ROOT, cfg, state)
    log(state, string.format("research: %d new papers, %d new ARC tasks%s", r.papers_new, r.arc_new, #r.errors > 0 and (" (" .. #r.errors .. " fetch errors)") or ""))
    journal.record(ROOT, { kind = "research", gen = gen, papers_new = r.papers_new,
      arc_new = r.arc_new, errors = #r.errors, gaps = r.gaps })
    -- What the narration is allowed to say about this fetch. Counts are measured; the title is
    -- quoted from the record that was written to papers.jsonl, not composed.
    local top = (r.papers_new or 0) > 0 and research.top_new(ROOT, since) or nil
    research_note = { papers_new = r.papers_new or 0, arc_new = r.arc_new or 0, errors = r.errors or {},
      top_paper = top and one_line(top.title) or nil,
      top_paper_gap = top and top.addresses_gap and one_line(top.addresses_gap[1], 48) or nil }
  end

  -- The adversarial split is aimed at whatever currently separates candidates best, rather than at a
  -- fixed list. Chosen from the previous generation's ranking so this generation's splits are built
  -- before its own statistics exist.
  if cfg.adversarial_from_ranking and state.challenge and #state.challenge > 0 then
    benchmarks.set_adversarial(bench,
      challenge.pick_adversarial(state.challenge, #cfg.adversarial_families, cfg.adversarial_families))
  end

  -- benchmarks
  progress("building splits")
  local splits = benchmarks.build_splits(bench, cfg, gen)
  local external = benchmarks.load_external(ROOT, cfg.external_cap)

  -- champion
  local champ_g = genome.load(ROOT .. "/genome")
  local champ_fp = genome.fingerprint(champ_g)
  local champ_r
  local cache = state.champion_cache
  -- The budget profile is part of the key. "Solved" means "solved within this node and wall-clock
  -- budget", so a champion measured at 3s/3000 nodes is not comparable with a candidate measured at
  -- 2s/2000, and reusing the cached score across a budget change would corrupt the acceptance
  -- decision rather than merely slow it down. A changed budget forces a full re-evaluation.
  if cache and cache.fingerprint == champ_fp and cache.epoch == bench.heldout_epoch and cache.regression_n == #splits.regression
    and cache.external_n == #external and cache.heldout_n == #splits.heldout
    and cache.budget == cfg.budget_profile then
    champ_r = { heldout = cache.heldout, regression = cache.regression, external = cache.external }
    champ_r.train = eval_split(champ_g, splits.train, "champion: visible split")
    champ_r.adversarial = eval_split(champ_g, splits.adversarial, "champion: adversarial")
  else
    champ_r = eval_all(champ_g, splits, external, "champion", { candidate = "champion" })
    state.champion_cache = { fingerprint = champ_fp, epoch = bench.heldout_epoch, regression_n = #splits.regression,
      external_n = #external, heldout_n = #splits.heldout, budget = cfg.budget_profile,
      heldout = champ_r.heldout, regression = champ_r.regression, external = champ_r.external }
  end
  log(state, string.format("gen %d champion %s: held-out %d/%d, visible %d/%d, adversarial %d/%d, regression %d/%d, ARC %d/%d",
    gen, champ_fp, champ_r.heldout.solved, champ_r.heldout.n, champ_r.train.solved, champ_r.train.n,
    champ_r.adversarial.solved, champ_r.adversarial.n, champ_r.regression.solved, champ_r.regression.n, champ_r.external.solved, champ_r.external.n))

  -- Challenge statistics. Difficulty comes from the champion's held-out and adversarial results;
  -- discrimination is filled in per candidate below, since it is a property of the comparison rather
  -- than of any one run.
  state.family_stats = state.family_stats or {}
  for _, split in ipairs({ champ_r.heldout, champ_r.adversarial }) do
    for _, r in ipairs(split.per_task) do
      challenge.update(state.family_stats, r.family, r.solved, r.partial, gen)
    end
  end

  -- evidence corpus: every visible-split solution and near-miss ever seen (never held-out data)
  state.corpus = state.corpus or {}
  state.near_corpus = state.near_corpus or {}
  local have = {}
  for _, e in ipairs(state.corpus) do have[e.expr] = true end
  for i, r in ipairs(champ_r.train.per_task) do
    local bucket = features.bucket(splits.train[i])
    if r.solved == 1 and r.program and not have[r.program] then
      state.corpus[#state.corpus + 1] = { expr = r.program, family = r.family, gen = gen, bucket = bucket }
      have[r.program] = true
    elseif r.solved == 0 and r.partial >= 0.66 and r.partial_program then
      state.near_corpus[#state.near_corpus + 1] = { expr = r.partial_program, family = r.family, gen = gen, bucket = bucket }
    end
  end
  while #state.corpus > 3000 do table.remove(state.corpus, 1) end
  while #state.near_corpus > 800 do table.remove(state.near_corpus, 1) end

  -- The durable training set. state.corpus is a rolling window the operators read; this file keeps
  -- everything, so the record of what the system learned from does not get trimmed away.
  do
    local rows = {}
    for i, r in ipairs(champ_r.train.per_task) do
      if r.solved == 1 and r.program then
        local t = splits.train[i]
        rows[#rows + 1] = {
          gen = gen, family = r.family, bucket = features.bucket(t),
          in_type = t.in_type, out_type = t.out_type, program = r.program, nodes = r.nodes,
          -- recorded for the reader only; the solver is handed tasks.solver_view, which omits it
          generator = t.meta and t.meta.expr, depth = t.meta and t.meta.depth,
        }
      end
    end
    journal.add_corpus(ROOT, rows)
  end

  -- candidates
  local ctx = { rng = rng, prims = champ_g.prims, train_results = champ_r.train, adversarial_results = champ_r.adversarial,
    corpus = state.corpus, near_corpus = state.near_corpus }
  local best = nil
  local used = {}
  local narrated_candidates = {}
  for k = 1, cfg.candidates_per_gen do
    local cand_g, op, desc = mutate.make_candidate(champ_g, ctx, state.meta, used)
    if not cand_g then log(state, "no applicable mutation operator") break end
    used[op] = true
    state.meta.tried[op] = (state.meta.tried[op] or 0) + 1
    state.candidates_total = state.candidates_total + 1
    local tag = string.format("c%d_%s", k, op)
    local dir = lineage.snapshot(ROOT, gen, tag, cand_g)
    local loaded = genome.load(dir)
    local extra = { candidate = tag, operator = op, change = desc }
    -- Cheap screen: every acceptance clause requires a non-negative held-out delta, so a candidate
    -- that solves strictly fewer held-out tasks is rejected without running the other four splits.
    -- This is equivalent to the full rule, not a relaxation of it.
    local cand_r = { heldout = eval_split(loaded, splits.heldout, "candidate " .. k .. ": held-out", nil, extra) }
    for i, cr in ipairs(cand_r.heldout.per_task) do
      challenge.note_comparison(state.family_stats, cr.family,
        cr.solved ~= champ_r.heldout.per_task[i].solved, gen)
    end
    local accepted, reason, ev
    if cand_r.heldout.solved < champ_r.heldout.solved then
      local a, b = evaluate.vector(champ_r.heldout), evaluate.vector(cand_r.heldout)
      local wins, losses = stats.wins_losses(a, b)
      local d = cand_r.heldout.solve_rate - champ_r.heldout.solve_rate
      accepted, reason = false, string.format("screened out on held-out (%.1fpp, wins %d / losses %d)", d * 100, wins, losses)
      ev = { heldout_delta = d, wins = wins, losses = losses, screened = true }
    else
      cand_r.train = eval_split(loaded, splits.train, "candidate " .. k .. ": visible split", nil, extra)
      cand_r.adversarial = eval_split(loaded, splits.adversarial, "candidate " .. k .. ": adversarial", nil, extra)
      cand_r.regression = eval_split(loaded, splits.regression, "candidate " .. k .. ": regression suite", nil, extra)
      cand_r.external = eval_split(loaded, external, "candidate " .. k .. ": external ARC", { nodes = cfg.external_nodes, seconds = cfg.external_seconds }, extra)
      accepted, reason, ev = decide(champ_r, cand_r, gen .. ":" .. k)
    end
    local entry = {
      gen = gen, candidate = k, operator = op, change = desc, accepted = accepted, reason = reason,
      champion_fp = champ_fp, candidate_fp = genome.fingerprint(loaded), snapshot = dir,
      champion_heldout = champ_r.heldout.solve_rate, candidate_heldout = cand_r.heldout.solve_rate,
      heldout_delta = ev.heldout_delta or 0, p_value = ev.p_value, ci = ev.ci, wins = ev.wins, losses = ev.losses,
      adversarial_delta = ev.adversarial_delta, train_delta = ev.train_delta, nodes_ratio = ev.nodes_ratio,
      regression = ev.regression, external = cand_r.external and (cand_r.external.solved .. "/" .. cand_r.external.n) or nil,
      time = os.time(),
    }
    -- bookkeeping must never take down a generation: the verdict is already decided
    pcall(function()
      os.execute("mkdir -p '" .. dir .. "'")
      json.write(dir .. "/evidence.json", { entry = entry, heldout = cand_r.heldout,
        adversarial = cand_r.adversarial, train = cand_r.train })
    end)
    pcall(lineage.record, ROOT, entry)
    narrated_candidates[#narrated_candidates + 1] = entry
    log(state, string.format("  candidate %d [%s] %s -> %s: %s", k, op, desc, accepted and "ACCEPT" or "reject", reason))
    if accepted and (not best or (cand_r.heldout.solve_rate > best.r.heldout.solve_rate)) then
      best = { g = cand_g, loaded = loaded, r = cand_r, op = op, desc = desc, dir = dir, entry = entry }
    end
  end

  -- retain
  if best then
    state.meta.accepted[best.op] = (state.meta.accepted[best.op] or 0) + 1
    state.accepted_total = state.accepted_total + 1
    genome.save(best.g, ROOT .. "/genome")
    lineage.snapshot(ROOT, gen, "champion", best.g)
    best.r.heldout.gen = gen
    local added = benchmarks.extend_regression(bench, cfg, splits.heldout, best.r.heldout)
    local driver = benchmarks.driver_family(splits.heldout, champ_r.heldout, best.r.heldout)
    local rotation = benchmarks.after_accept(bench, cfg, driver, gen)
    log(state, string.format("  retained candidate from %s; regression suite +%d (now %d); driver family %s", best.op, added, #bench.regression, tostring(driver)))
    journal.record(ROOT, { kind = "accepted", gen = gen, operator = best.op, change = best.desc,
      reason = best.entry.reason, before = champ_r.heldout.solve_rate, after = best.r.heldout.solve_rate,
      driver = driver, fingerprint = genome.fingerprint(best.g) })
    if rotation then
      log(state, "  " .. rotation)
      journal.record(ROOT, { kind = "rotation", gen = gen, detail = rotation })
    end
    state.champion_cache = nil
    champ_g, champ_r = best.loaded, best.r
    out.accepted, out.operator, out.change = true, best.op, best.desc
  end

  -- challenge ranking, and the journal
  local ranking = challenge.rank(state.family_stats, gen, cfg.challenge_weights)
  local saturated = challenge.saturated(ranking, cfg.saturation_solve_floor, cfg.saturation_disc_floor)
  state.challenge = ranking
  state.saturated = saturated
  local spawned = benchmarks.spawn_from_saturation(bench, saturated, gen)
  if spawned then
    log(state, "  " .. spawned)
    journal.record(ROOT, { kind = "rotation", gen = gen, detail = spawned })
  end
  do
    local ok_j, err_j = pcall(journal.render, ROOT, {
      gen = gen, fingerprint = genome.fingerprint(champ_g),
      heldout = { solved = champ_r.heldout.solved, n = champ_r.heldout.n,
        rate = champ_r.heldout.solve_rate, lo = select(2, stats.wilson(champ_r.heldout.solved, champ_r.heldout.n)),
        hi = select(3, stats.wilson(champ_r.heldout.solved, champ_r.heldout.n)) },
      adversarial = champ_r.adversarial, regression = champ_r.regression, external = champ_r.external,
      accepted_total = state.accepted_total, candidates_total = state.candidates_total,
      corpus_size = journal.corpus_size(ROOT), library_size = #champ_g.lib, ops = #champ_g.base.ops,
      challenge = ranking, saturated = saturated, heldout_epoch = bench.heldout_epoch,
    })
    if not ok_j then io.stderr:write("journal render failed: " .. tostring(err_j) .. "\n") end
  end

  -- Movement on the external ARC set, generation over generation. Only comparable when the same
  -- number of tasks was attempted, so the delta is left nil (and stays unspoken) when it is not.
  local ext_delta = nil
  local prev_ext = state.last_external
  if prev_ext and champ_r.external.n > 0 and prev_ext.n == champ_r.external.n then
    ext_delta = champ_r.external.solved - prev_ext.solved
  end
  state.last_external = { solved = champ_r.external.solved, n = champ_r.external.n, gen = gen }

  -- The narration. Written every generation with no typing delay so the generation is not slowed by
  -- it; `lua cell4.lua narrate` replays the latest entry a word at a time.
  do
    local ok_n, res = pcall(narrator.narrate, {
      gen = gen, fingerprint = genome.fingerprint(champ_g),
      heldout = champ_r.heldout, adversarial = champ_r.adversarial,
      regression = champ_r.regression, external = champ_r.external,
      external_delta = ext_delta, research = research_note,
      candidates = narrated_candidates, accepted = best ~= nil,
      corpus_size = journal.corpus_size(ROOT), library_size = #champ_g.lib,
      challenge = ranking, saturated = saturated,
      accepted_total = state.accepted_total, candidates_total = state.candidates_total,
    }, { quiet = true, seed = "narrate:" .. gen })
    if ok_n then
      pcall(narrator.record, ROOT, res)
      pcall(narrator.render_history, ROOT)
      -- The short form the public page shows. Committed into state.json with everything else, so
      -- live.json is derived from persisted state rather than from anything still in memory, and so
      -- the lines survive this process exiting. narrative.jsonl keeps the full account either way.
      local lines = narrator.highlights(res, 3)
      state.narration = { gen = gen, time = res.time, lines = lines,
        corrections = #(res.corrections or {}) }
      state.narration_log = state.narration_log or {}
      table.insert(state.narration_log, 1, { gen = gen, time = res.time, lines = lines })
      while #state.narration_log > 8 do table.remove(state.narration_log) end
      if res.corrections and #res.corrections > 0 then
        log(state, string.format("  narrator corrected %d fact(s) against recomputation", #res.corrections))
      end
    else
      io.stderr:write("narration failed: " .. tostring(res) .. "\n")
    end
  end

  local pruned = lineage.prune(ROOT, gen, 50)
  if pruned > 0 then log(state, string.format("  pruned %d rejected candidate snapshots older than generation %d", pruned, gen - 50)) end

  out.heldout = champ_r.heldout.solve_rate
  -- Which budgets this generation actually ran under. Two generations at different budgets are not
  -- directly comparable, and without this the ledger gives no way to notice that.
  out.budget = cfg.budget_profile
  state.budget_profile = cfg.budget_profile
  if state.last_budget_profile and state.last_budget_profile ~= cfg.budget_profile then
    log(state, string.format("  budget profile changed: %s -> %s (champion re-measured, earlier generations are not directly comparable)",
      state.last_budget_profile, cfg.budget_profile))
  end
  state.last_budget_profile = cfg.budget_profile
  benchmarks.save(bench)
  save_state(state)
  write_dashboard(state, bench, champ_g, champ_r, external)
  progress("idle after generation " .. gen)
  return out
end

function M.status()
  ensure_dirs()
  local state = load_state()
  local bench = benchmarks.load(ROOT)
  return state, bench
end

return M
  end

  -- ==== rsi/lm/markov.lua ====
  package.preload['rsi.lm.markov'] = function(...)
-- An n-gram Markov language model. Trained by counting, sampled with backoff and temperature.
--
-- This IS a language model in the textbook sense: it estimates P(w_t | w_{t-1} ... w_{t-n+1}) from a
-- corpus and generates by sampling that distribution. It is the pre-neural kind -- no network, no
-- gradient, no external service -- which is what lets it live inside this project without breaking
-- the no-external-model rule. It is not a transformer and nothing here pretends otherwise.
--
-- THE ONE INVARIANT THAT MAKES IT SAFE. A Markov chain will happily produce a fluent falsehood: it
-- has no idea what is true. So the vocabulary is forbidden to contain numerals. Every quantity in a
-- generated sentence arrives through a {slot}, filled from audited facts after sampling. A training
-- line containing a bare number is REJECTED at load time, and a sampled token that is a bare number
-- is refused at generation time. The chain therefore controls wording and word order; it can never
-- control a number. See rsi/lm/generate.lua for the verification that runs after slot filling.
local M = {}
M.__index = M

local SEP = "\1"

function M.new(order)
  return setmetatable({
    order = math.max(2, order or 3),
    n = {},          -- n[k][context_key][token] = count, for context lengths k = order-1 .. 0
    vocab = {},
    lines = 0,
    rejected = {},   -- training lines refused, with the reason
  }, M)
end

-- Punctuation is split off so "tasks." and "tasks" are the same word to the model.
function M.tokenize(line)
  local out = {}
  line = line:gsub("([%.,;:%?!%(%)])", " %1 ")
  for tok in line:gmatch("%S+") do out[#out + 1] = tok end
  return out
end

function M.detokenize(toks)
  local s = table.concat(toks, " ")
  s = s:gsub(" ([%.,;:%?!%)])", "%1"):gsub("%( ", "(")
  return s
end

local function is_slot(tok) return tok:match("^{[%w_]+}$") ~= nil end

-- A bare numeral, or a token whose digits are not inside a slot. This is the guard.
local function has_free_number(tok)
  if is_slot(tok) then return false end
  return tok:match("%d") ~= nil
end

function M:add(k, ctx, tok)
  local lvl = self.n[k]
  if not lvl then lvl = {} self.n[k] = lvl end
  local row = lvl[ctx]
  if not row then row = { total = 0 } lvl[ctx] = row end
  row[tok] = (row[tok] or 0) + 1
  row.total = row.total + 1
end

-- A training line is: [topic] word word {slot} word .
-- The topic tag becomes the first token, so conditioning on a topic is just seeding the context.
function M:train_line(line)
  line = line:gsub("^%s+", ""):gsub("%s+$", "")
  if line == "" or line:sub(1, 1) == "#" then return true end
  local toks = M.tokenize(line)
  if #toks < 3 then
    self.rejected[#self.rejected + 1] = { line = line, why = "too short" }
    return false
  end
  if not toks[1]:match("^%[[%w_]+%]$") then
    self.rejected[#self.rejected + 1] = { line = line, why = "missing [topic] tag" }
    return false
  end
  for _, t in ipairs(toks) do
    if has_free_number(t) then
      self.rejected[#self.rejected + 1] = { line = line, why = "contains a bare number: " .. t }
      return false
    end
  end
  toks[#toks + 1] = "</s>"
  for _, t in ipairs(toks) do self.vocab[t] = (self.vocab[t] or 0) + 1 end
  for i = 1, #toks do
    for k = 0, self.order - 1 do
      local parts = {}
      for j = i - k, i - 1 do parts[#parts + 1] = toks[j] or "<s>" end
      self:add(k, table.concat(parts, SEP), toks[i])
    end
  end
  self.lines = self.lines + 1
  return true
end

function M:train_file(path)
  local f = io.open(path, "r")
  if not f then return nil, "cannot open " .. path end
  for line in f:lines() do self:train_line(line) end
  f:close()
  return self
end

function M:vocab_size()
  local n = 0
  for _ in pairs(self.vocab) do n = n + 1 end
  return n
end

function M:topics()
  local out = {}
  for w in pairs(self.vocab) do
    if w:match("^%[[%w_]+%]$") then out[#out + 1] = w end
  end
  table.sort(out)
  return out
end

-- Sample the next token, backing off from the longest available context to the shortest.
-- Returns the token and the context length that produced it (useful for diagnostics).
function M:next_token(history, rng, temperature, reject)
  temperature = temperature or 1.0
  for k = self.order - 1, 0, -1 do
    local parts = {}
    for j = #history - k + 1, #history do parts[#parts + 1] = history[j] or "<s>" end
    local row = self.n[k] and self.n[k][table.concat(parts, SEP)]
    if row and row.total > 0 then
      local weights, toks, sum = {}, {}, 0
      for tok, c in pairs(row) do
        if tok ~= "total" and not (reject and reject(tok)) then
          local w = (temperature == 1.0) and c or (c ^ (1.0 / temperature))
          toks[#toks + 1] = tok
          weights[#weights + 1] = w
          sum = sum + w
        end
      end
      if sum > 0 then
        -- sort for determinism: pairs() order is not stable across runs
        local idx = {}
        for i = 1, #toks do idx[i] = i end
        table.sort(idx, function(a, b) return toks[a] < toks[b] end)
        local x = rng:float() * sum
        for _, i in ipairs(idx) do
          x = x - weights[i]
          if x <= 0 then return toks[i], k end
        end
        return toks[idx[#idx]], k
      end
    end
  end
  return "</s>", -1
end

-- Generate one sentence for a topic. Numerals can never be emitted: the reject filter refuses any
-- token carrying a digit outside a slot, at every backoff level.
function M:generate(topic, rng, opts)
  opts = opts or {}
  local max_len = opts.max_len or 40
  local temperature = opts.temperature or 0.9
  local history = { "<s>", "<s>", topic }
  local out = { topic }
  for _ = 1, max_len do
    local tok = self:next_token(history, rng, temperature, has_free_number)
    if tok == "</s>" or tok == "<s>" then break end
    out[#out + 1] = tok
    history[#history + 1] = tok
  end
  if #out < 2 then return nil end
  table.remove(out, 1)  -- drop the topic tag from the surface form
  return M.detokenize(out), out
end

function M:stats()
  local contexts = 0
  for _, lvl in pairs(self.n) do
    for _ in pairs(lvl) do contexts = contexts + 1 end
  end
  return { lines = self.lines, vocab = self:vocab_size(), contexts = contexts,
    order = self.order, rejected = #self.rejected }
end

M.is_slot = is_slot
M.has_free_number = has_free_number
return M
  end

  -- ==== rsi/genome/dsl_base.lua ====
  package.preload['rsi.genome.dsl_base'] = function(...)
-- visible primitive selection (mutable)
return {
  ops = {
    -- list
    "reverse", "sort", "sort_desc", "head", "last", "tail", "init", "len", "sum", "max", "min",
    "map_add", "map_sub", "map_mul", "map_mod", "filter_even", "filter_odd", "filter_gt", "filter_lt",
    "take", "drop", "rotate", "concat", "dedup", "cumsum", "diffs", "count", "index_of", "range",
    "singleton", "nth", "abs_all", "mirror", "repeat_list", "zip_add", "evens_idx", "odds_idx",
    "push_front", "push_back", "product", "unique_count",
    -- int
    "add", "sub", "mul", "div", "mod", "max2", "min2", "sq", "inc", "dec", "double", "half", "abs", "neg",
    "is_even", "gt", "eq", "if_int",
    -- grid
    "flip_h", "flip_v", "transpose", "rot90", "rot180", "rot270", "height", "width", "hcat", "vcat",
    "mirror_h", "mirror_v", "upscale", "downscale", "recolor", "fill_nonzero", "count_color", "most_color",
    "most_nonzero_color", "least_nonzero_color", "crop_bbox", "gravity_down", "gravity_up", "gravity_left",
    "gravity_right", "shift_down", "shift_right", "add_border", "remove_border", "top_half", "bottom_half",
    "left_half", "right_half", "overlay", "flatten", "row", "col", "from_row", "nonzero_count", "const_grid",
    "invert_mask", "tile2x2", "object_count", "keep_largest", "keep_smallest", "largest_object_size",
  },
}
  end

  -- ==== rsi/genome/library.lua ====
  package.preload['rsi.genome.library'] = function(...)
return {}
  end

  -- ==== rsi/genome/policy.lua ====
  package.preload['rsi.genome.policy'] = function(...)
-- search policy: costs, constants, budgets, strategy (mutable)
return {
  strategy = "probe",       -- "probe" (cost-guided bottom-up + just-in-time learning) | "levelwise" (plain size-based)
  default_cost = 2,         -- integer cost of a primitive application unless overridden in cost{}
  const_cost = 1,
  leaf_cost = 1,
  max_cost = 9,             -- deepest cost level the enumeration will reach
  bank_cap = 350,           -- max distinct programs kept per (type, cost) bucket
  jit = true,               -- Probe-style just-in-time weight learning from partially-correct programs
  jit_rate = 1,             -- cost decrease applied to ops of partially-correct programs (per level)
  jit_min_match = 1,        -- minimum matching examples for a program to count as partial evidence
  coerce_ic = false,        -- let small non-negative ints feed colour slots and colours feed int slots
  consts = { I = { 0, 1, 2, 3 }, C = { 0, 1, 2, 3, 4, 5 } },
  -- Measured flat on this distribution (0.0pp on 300 mixed tasks, 0.0pp on 180 large-value tasks):
  -- the generated values are small and the pool above already covers them, so 86% of tasks derive
  -- nothing. Kept because it is the standard remedy where literals matter (real ARC uses ten colours
  -- and dimensions to 30) and the mutation operators can switch it on if evidence ever appears.
  derived_consts = false,   -- also mine example-invariant literals from the task's own I/O pairs
  derived_const_cap = 8,    -- at most this many, ranked by how much the examples demand them
  derived_const_cost = 1,   -- cost of a derived literal leaf
  cost = {},                -- per-op cost overrides, learned by prior fitting
  cond_cost = {},           -- task-feature bucket -> {op -> cost}, learned task-conditioned priors
  cond_ops = {},            -- task-feature bucket -> {op -> true}, per-bucket enumeration whitelist
  -- Verified on four independent 300-task sets (+6.3, +3.0, +8.3, +6.0 pp; pooled 66.0% -> 71.8%,
  -- 66 wins against 14 losses) while using fewer search nodes. On by default.
  bidirectional = true,     -- build the backward bank and meet the forward enumeration in the middle
  back_frac = 0.25,         -- share of the node budget the backward bank may consume
  back_max_cost = 6,        -- deepest backward chain, in the same cost units as the forward search
  back_after_cost = 3,      -- build it only once forward search past this cost level has failed
  back_cap = 400,           -- max backward entries
  binary_meet = true,       -- deduce one argument of a binary operator from the other
  binary_meet_depth = 2,    -- only from backward entries at most this deep
  binary_meet_cap = 24,     -- cheapest forward candidates offered as the known argument
  -- measured at +0.3pp (1 win, 0 losses, p=0.37) on 300 tasks: real but not evidence, so off
  meet_replay = false,      -- replay the binary meet once the forward bank has grown
  meet_replay_slack = 4,    -- extra cost the replay may spend, since its known argument is deeper
  two_phase = true,         -- try the narrow whitelist first, then fall back to the full operator set
  phase1_frac = 0.5,        -- share of the node budget given to the narrow phase
}
  end

  -- ==== rsi/genome/search.lua ====
  package.preload['rsi.genome.search'] = function(...)
-- search engine (mutable): bidirectional cost-guided enumeration with observational equivalence.
-- Mechanisms: bottom-up enumeration by integer cost with OE dedup (Udupa et al. / TRANSIT style),
-- Probe-style just-in-time cost learning from partially-correct programs (Barke et al. 2020),
-- learned library primitives enter as ordinary unary ops (DreamCoder-style reuse), and a backward
-- bank built by inverting the goal through invertible operators, met in the middle by the forward
-- enumeration (inverse semantics / witness functions, as in FlashFill-style deductive synthesis).
--
-- The backward bank is the reason this engine is not blind. Forward enumeration spends its budget on
-- breadth and asks "did anything I built happen to equal the target"; the backward bank asks "what
-- would the rest of the program have to produce for this operator to finish the job", which is a
-- deduction, not a guess. Backward entries are counted against the same node budget as forward ones,
-- so the two halves compete for one resource and the comparison against a purely forward search is
-- like for like.
local M = {}

function M.solve(task, ctx)
  local prims, order = ctx.dsl.prims, ctx.dsl.order
  local policy = ctx.policy
  local sig, equal, P = ctx.sig, ctx.equal, ctx.program
  local INV = ctx.inverses
  local CONSTS = ctx.constants
  local train = task.train
  local n = #train
  local inputs, targets = {}, {}
  for i = 1, n do inputs[i] = train[i].input targets[i] = train[i].output end
  local in_type, out_type = task.in_type, task.out_type
  local total_budget, deadline = ctx.budget, ctx.deadline
  local clock = os.clock

  -- op costs: task-conditioned table (learned recognition prior) if one matches this task's features,
  -- otherwise the unconditional learned costs, otherwise the default
  local feat_bucket = ctx.features and ctx.features(task)
  local cond = policy.cond_cost and feat_bucket and policy.cond_cost[feat_bucket]
  local cost = {}
  for _, name in ipairs(order) do cost[name] = (cond and cond[name]) or policy.cost[name] or policy.default_cost end
  -- Branching factor, not depth, is what the node budget buys. A per-bucket whitelist of operators
  -- that have ever appeared in a solution of this task shape narrows every level of the enumeration.
  local narrow = policy.cond_ops and feat_bucket and policy.cond_ops[feat_bucket]

  -- Two-phase portfolio. Measured: a per-bucket operator whitelist saves ~23% of the nodes and wins
  -- 11 tasks the wide enumeration misses, but loses 22 by excluding operators it turns out to need.
  -- So run the narrow enumeration first on a slice of the budget, then fall back to the full operator
  -- set with what remains. The narrow phase keeps its wins; the fallback keeps the losses off.
  local nodes = 0
  local function enumerate(allow, budget)
  local bank, seen = {}, {}
  local function bucket(ty, c)
    local b = bank[ty]
    if not b then b = {} bank[ty] = b end
    local l = b[c]
    if not l then l = {} b[c] = l end
    return l
  end

  local best_matches, best_node = 0, nil
  local level_partials = {}

  -- ---------- backward bank ----------
  -- A backward entry maps a value-tuple the forward search might produce to a context that turns it
  -- into the target. Each step is verified by applying the operator forward to the candidate
  -- preimage, so reaching an entry is a solution by construction rather than a hypothesis.
  local back, back_n, back_entries = {}, 0, {}
  local function back_key(ty, vals)
    local parts = {}
    for i = 1, n do parts[i] = sig(vals[i]) end
    return ty .. "|" .. table.concat(parts, ";")
  end

  -- mkargs turns the hole into the operator's full argument list, so the same routine serves unary
  -- inverses, inverses with a constant second argument, and both hole positions of a binary meet.
  local function add_back(vals, ty, c, parent, name, mkargs, nextf)
    local key = back_key(ty, vals)
    if back[key] then return end
    nodes = nodes + 1
    back_n = back_n + 1
    local pb = parent.build
    local e = {
      vals = vals, ty = ty, cost = c,
      build = function(node) return pb(P.node(name, mkargs(node))) end,
    }
    back[key] = e
    back_entries[#back_entries + 1] = e
    if nextf then nextf[#nextf + 1] = e end
  end

  local function args_unary(node) return { node } end

  -- Only a minority of operators are invertible. Scanning the whole DSL for every frontier entry was
  -- the dominant cost of the backward bank; indexing by return type cuts that loop by an order of
  -- magnitude, which matters because the wall-clock deadline, not the node budget, was the binding
  -- constraint when this was measured.
  local inv_by_ret = nil
  local function index_inverses(allow)
    local idx = {}
    for _, name in ipairs(order) do
      local p = prims[name]
      local has = (INV.inv1[name] and #p.t == 1) or (INV.inv2[name] and #p.t == 2)
        or ((INV.inv_arg1[name] or INV.inv_arg2[name]) and #p.t == 2)
      if has and not (p.bucket and p.bucket ~= feat_bucket) and not (allow and not allow[name]) then
        idx[p.r] = idx[p.r] or {}
        table.insert(idx[p.r], name)
      end
    end
    return idx
  end

  -- cheapest-first view of the forward bank, for the binary meet
  -- min_cost lets the replay pass draw on material the first pass could not have seen: without it
  -- the cheapest-first cap returns the same candidates every time and replaying deduces nothing.
  local function forward_candidates(ty, cap, min_cost)
    local out = {}
    local byc = bank[ty]
    if not byc then return out end
    local costs = {}
    for c in pairs(byc) do if not min_cost or c >= min_cost then costs[#costs + 1] = c end end
    table.sort(costs)
    for _, c in ipairs(costs) do
      for _, en in ipairs(byc[c]) do
        out[#out + 1] = { entry = en, cost = c }
        if #out >= cap then return out end
      end
    end
    return out
  end

  -- Binary meet: with one argument drawn from what the forward search can already build, the other
  -- argument is determined. This is what reaches the compositional shapes -- concat of the input with
  -- a transform of it, a grid beside its own mirror, one grid overlaid on another -- where neither
  -- argument is a constant and the outer operator is therefore invisible to the plain inverse rules.
  -- Restricted to shallow backward entries and to the cheapest forward candidates, because the
  -- forward bank is large and this is quadratic in it.
  local function binary_meet_over(list, nextf, budget, maxc, cap, min_cost)
    if not policy.binary_meet then return end
    local depth_limit = policy.binary_meet_depth or 2
    local fcap = policy.binary_meet_cap or 24
    for _, e in ipairs(list) do
      if e.cost <= depth_limit then
        for _, name in ipairs(inv_by_ret[e.ty] or {}) do
          local p = prims[name]
          if #p.t == 2 then
            for slot = 1, 2 do
              local rule = (slot == 2) and INV.inv_arg2[name] or INV.inv_arg1[name]
              local known_ty = (slot == 2) and p.t[1] or p.t[2]
              local hole_ty = (slot == 2) and p.t[2] or p.t[1]
              if rule then
                for _, fc in ipairs(forward_candidates(known_ty, fcap, min_cost)) do
                  if nodes >= budget or back_n >= cap then return end
                  local nc = e.cost + cost[name] + fc.cost
                  if nc <= maxc then
                    local cand, ok = {}, true
                    for i = 1, n do
                      local known = fc.entry.outs[i]
                      local ok2, v = pcall(rule, e.vals[i], known)
                      if not ok2 or v == nil then ok = false break end
                      local ok3, chk
                      if slot == 2 then ok3, chk = pcall(p.f, known, v) else ok3, chk = pcall(p.f, v, known) end
                      if not ok3 or not equal(chk, e.vals[i]) then ok = false break end
                      cand[i] = v
                    end
                    if ok then
                      local sib = fc.entry.node
                      local mk = (slot == 2)
                        and function(node) return { sib, node } end
                        or function(node) return { node, sib } end
                      add_back(cand, hole_ty, nc, e, name, mk, nextf)
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  local function build_back(allow, budget)
    inv_by_ret = index_inverses(allow)
    local root = { vals = targets, ty = out_type, cost = 0, build = function(node) return node end }
    back[back_key(out_type, targets)] = root
    back_entries[#back_entries + 1] = root
    -- an integer-valued forward program can answer a colour-typed task and the other way round
    local alt = (out_type == "C" and "I") or (out_type == "I" and "C") or nil
    if alt then back[back_key(alt, targets)] = root end
    local frontier = { root }
    local maxc = policy.back_max_cost or 6
    local cap = policy.back_cap or 400
    for _ = 1, maxc do
      local nextf = {}
      local frontier_in = frontier
      for _, e in ipairs(frontier) do
        for _, name in ipairs(inv_by_ret[e.ty] or {}) do
          if nodes >= budget or back_n >= cap then return end
          local p = prims[name]
          do
            local nc = e.cost + cost[name]
            if nc <= maxc then
              local k1, k2 = INV.inv1[name], INV.inv2[name]
              if k1 and #p.t == 1 then
                local cand, ok = {}, true
                for i = 1, n do
                  local ok2, v = pcall(k1, e.vals[i])
                  if not ok2 or v == nil then ok = false break end
                  local ok3, chk = pcall(p.f, v)
                  if not ok3 or not equal(chk, e.vals[i]) then ok = false break end
                  cand[i] = v
                end
                if ok then add_back(cand, p.t[1], nc, e, name, args_unary, nextf) end
              elseif k2 and #p.t == 2 then
                for _, kv in ipairs(policy.consts[p.t[2]] or {}) do
                  local cand, ok = {}, true
                  for i = 1, n do
                    local ok2, v = pcall(k2, e.vals[i], kv)
                    if not ok2 or v == nil then ok = false break end
                    local ok3, chk = pcall(p.f, v, kv)
                    if not ok3 or not equal(chk, e.vals[i]) then ok = false break end
                    cand[i] = v
                  end
                  if ok then
                    local kn = P.const(kv, p.t[2])
                    add_back(cand, p.t[1], nc, e, name, function(node) return { node, kn } end, nextf)
                  end
                end
              end
            end
          end
        end
      end
      binary_meet_over(frontier_in, nextf, budget, maxc, cap)
      frontier = nextf
      if #frontier == 0 then break end
    end
  end

  -- Values already in the forward bank were created before the backward bank existed, so they were
  -- never offered a meet. One sweep after the bank is built catches them.
  local function sweep_bank()
    for ty, byc in pairs(bank) do
      for _, list in pairs(byc) do
        for _, e in ipairs(list) do
          local hit = back[back_key(ty, e.outs)]
          if hit then return hit.build(e.node) end
        end
      end
    end
    return nil
  end

  -- The backward bank is built lazily. Measured: building it up front cost seven depth-1 list tasks,
  -- because a task solvable by a single operator was made to pay for machinery it never needed and
  -- ran out of wall-clock before the forward search started. Deferring it until the forward search
  -- has exhausted every depth-1 program (all of which have cost <= 3) makes the investment conditional
  -- on the task actually being hard.
  local back_built, meet_replayed = false, false
  local function maybe_build_back(allow)
    if back_built or not (policy.bidirectional and INV) then return nil end
    back_built = true
    build_back(allow, math.min(budget, nodes + math.floor(total_budget * (policy.back_frac or 0.25))))
    return sweep_bank()
  end

  -- The binary meet can only pair with forward values that existed when it ran, and it runs early,
  -- when the bank holds little more than the input and the depth-1 programs. Replaying it once the
  -- bank has grown lets it deduce arguments it could not have seen the first time.
  local function maybe_replay_meet(allow)
    if meet_replayed or back_built == false or not (policy.bidirectional and INV) then return nil end
    if not policy.meet_replay then return nil end
    meet_replayed = true
    binary_meet_over(back_entries, nil,
      math.min(budget, nodes + math.floor(total_budget * (policy.back_frac or 0.25))),
      (policy.back_max_cost or 6) + (policy.meet_replay_slack or 4), policy.back_cap or 400,
      (policy.back_after_cost or 3) + 1)
    return sweep_bank()
  end

  local function type_matches(ty)
    return ty == out_type or (out_type == "C" and ty == "I") or (out_type == "I" and ty == "C")
  end

  -- returns solution node if all train examples match
  local function consider(ty, c, node, outs)
    local parts = {}
    for i = 1, n do parts[i] = sig(outs[i]) end
    local key = ty .. "|" .. table.concat(parts, ";")
    if seen[key] then return nil end
    seen[key] = true
    nodes = nodes + 1
    -- meet in the middle: this value is one the backward chain knows how to finish
    local hit = back[key]
    if hit then return hit.build(node) end
    local l = bucket(ty, c)
    if #l < policy.bank_cap then
      local entry = { node = node, outs = outs }
      l[#l + 1] = entry
      -- optional int<->colour sharing: small non-negative ints may feed colour slots and vice versa
      if policy.coerce_ic and (ty == "I" or ty == "C") then
        local other = ty == "I" and "C" or "I"
        local fits = true
        if other == "C" then
          for i = 1, n do local v = outs[i] if v < 0 or v > 9 or v ~= math.floor(v) then fits = false break end end
        end
        if fits then
          local l2 = bucket(other, c)
          if #l2 < policy.bank_cap then l2[#l2 + 1] = entry end
        end
      end
    end
    if type_matches(ty) then
      local m = 0
      for i = 1, n do if equal(outs[i], targets[i]) then m = m + 1 end end
      if m == n then return node end
      if m > best_matches then best_matches, best_node = m, node end
      if m >= policy.jit_min_match then level_partials[#level_partials + 1] = node end
    end
    return nil
  end

  -- leaves
  do
    local outs = {}
    for i = 1, n do outs[i] = inputs[i] end
    consider(in_type, policy.leaf_cost, P.var(), outs)
    local function leaf_const(v, ty, c)
      local o = {}
      for i = 1, n do o[i] = v end
      return consider(ty, c, P.const(v, ty), o)
    end
    for ty, list in pairs(policy.consts) do
      for _, v in ipairs(list) do
        local s = leaf_const(v, ty, policy.const_cost)
        if s then return { program = s, nodes = nodes, partial = 1 } end
      end
    end
    -- Literals read off this task's own examples. Widening the global pool was measured and lost
    -- 3.5pp, because every extra leaf multiplies through every level; these are few and relevant.
    if policy.derived_consts and CONSTS then
      local ok, derived = pcall(CONSTS.derive, train, CONSTS.pool_set(policy.consts),
        policy.derived_const_cap or 8)
      if ok then
        for _, d in ipairs(derived) do
          local s = leaf_const(d.value, d.ty, policy.derived_const_cost or policy.const_cost)
          if s then return { program = s, nodes = nodes, partial = 1 } end
        end
      end
    end
  end

  local function apply1(f, a)
    local outs = {}
    for i = 1, n do outs[i] = f(a.outs[i]) end
    return outs
  end
  local function apply2(f, a, b)
    local outs = {}
    for i = 1, n do outs[i] = f(a.outs[i], b.outs[i]) end
    return outs
  end
  local function apply3(f, a, b, c)
    local outs = {}
    for i = 1, n do outs[i] = f(a.outs[i], b.outs[i], c.outs[i]) end
    return outs
  end

  local function exhausted()
    if nodes >= budget then return true end
    if nodes % 64 == 0 and clock() > deadline then return true end
    return false
  end

  for C = 2, policy.max_cost do
    if C > (policy.back_after_cost or 3) then
      local s = maybe_build_back(allow)
      if s then return { program = s, nodes = nodes, partial = 1 } end
    end
    if C > (policy.back_after_cost or 3) + 2 then
      local s = maybe_replay_meet(allow)
      if s then return { program = s, nodes = nodes, partial = 1 } end
    end
    level_partials = {}
    for _, name in ipairs(order) do
      local p = prims[name]
      local w = cost[name]
      local R = C - w
      local k = #p.t
      -- a bucket-scoped abstraction only enters the enumeration for tasks of that shape, so learned
      -- ops cost nothing on the tasks they were not learned from
      if p.bucket and p.bucket ~= feat_bucket then R = -1 end
      if allow and not allow[name] then R = -1 end
      if R >= k then
        local f, t = p.f, p.t
        if k == 1 then
          local A = bank[t[1]] and bank[t[1]][R]
          if A then
            for ai = 1, #A do
              local a = A[ai]
              local ok, outs = pcall(apply1, f, a)
              if ok then
                local s = consider(p.r, C, P.node(name, { a.node }), outs)
                if s then return { program = s, nodes = nodes, partial = 1 } end
              end
              if exhausted() then return { program = nil, nodes = nodes, partial = best_matches / n, best_partial = best_node } end
            end
          end
        elseif k == 2 then
          for c1 = 1, R - 1 do
            local c2 = R - c1
            local A = bank[t[1]] and bank[t[1]][c1]
            local B = bank[t[2]] and bank[t[2]][c2]
            if A and B then
              for ai = 1, #A do
                local a = A[ai]
                for bi = 1, #B do
                  local b = B[bi]
                  local ok, outs = pcall(apply2, f, a, b)
                  if ok then
                    local s = consider(p.r, C, P.node(name, { a.node, b.node }), outs)
                    if s then return { program = s, nodes = nodes, partial = 1 } end
                  end
                  if exhausted() then return { program = nil, nodes = nodes, partial = best_matches / n, best_partial = best_node } end
                end
              end
            end
          end
        elseif k == 3 then
          for c1 = 1, R - 2 do
            for c2 = 1, R - 1 - c1 do
              local c3 = R - c1 - c2
              local A = bank[t[1]] and bank[t[1]][c1]
              local B = bank[t[2]] and bank[t[2]][c2]
              local Cc = bank[t[3]] and bank[t[3]][c3]
              if A and B and Cc then
                for ai = 1, #A do
                  for bi = 1, #B do
                    for ci = 1, #Cc do
                      local a, b, c = A[ai], B[bi], Cc[ci]
                      local ok, outs = pcall(apply3, f, a, b, c)
                      if ok then
                        local s = consider(p.r, C, P.node(name, { a.node, b.node, c.node }), outs)
                        if s then return { program = s, nodes = nodes, partial = 1 } end
                      end
                      if exhausted() then return { program = nil, nodes = nodes, partial = best_matches / n, best_partial = best_node } end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
    -- just-in-time learning: ops appearing in partially-correct programs become cheaper for later levels
    if policy.jit and policy.strategy == "probe" and #level_partials > 0 then
      local touched = {}
      for _, node in ipairs(level_partials) do
        for _, op in ipairs(P.ops_used(node)) do touched[op] = true end
      end
      for op in pairs(touched) do cost[op] = math.max(1, cost[op] - policy.jit_rate) end
    end
  end
  return { program = nil, nodes = nodes, partial = best_matches / n, best_partial = best_node }
  end

  if narrow and policy.two_phase then
    local first = enumerate(narrow, math.floor(total_budget * (policy.phase1_frac or 0.5)))
    if first.program then return first end
    local second = enumerate(nil, total_budget)
    if second.partial >= first.partial then return second end
    second.partial, second.best_partial = first.partial, first.best_partial
    return second
  end
  return enumerate(narrow, total_budget)
end

return M
  end

  -- ==== main.lua ====
  package.preload['cell4.main'] = function(...)
--back end
local RFLevel = 1
local ifthen = [[<WELL>]]
local loop   = [[<REANIMATE>]]
local writes = [[<EX_>]]
local prints = [[<PRINT>]]
local dates  = [[<TIME>]]
local locals = [[<MANIFEST>]]
local string = [[<STRING>]]
local rand   = [[<PSEUDO>]]
local commas = [[,]]
local sleep  = [[<SLUMBER>]]
local elses  = [[<ELSE>]]
local varis  = [[___]]
local opens  = [[<CREATE>]]
local state  = [[<STATE>]]
local reads  = [[<EYE>]]
local closes = [[<CLOSE>]]
local basket = [[<BASKET>]]
local done = [[<DONE>]]
local __for = [[<FOR>]]
local lua = [[<PURE>]]
--front end
local background = [[FILL:]]
local size = [[XY:]]
local color = [[RGB:]]
local align = [[POSITION:]]
local display = [[DISPLAY:]]
local displayx = [[DISPLAYX:]]
local linkframe = [[LINKFRAME:]]
local linkframex = [[LINKFRAMEX:]]
local attachment = [[ATTACH:]]
local attachmentx = [[ATTACHX:]]
local attachmentl = [[ATTACHL:]]
local bracket = [[BRACKET:]]
local html = [[HTML:]]

local UIDirectory = [[source/index.html]]
local amounts = 0
local M_file = ""
local unnecessary_output = false
if unnecessary_output == true then 
io.write("@",os.date(),"//",os.time(),": in process")
end
local endmountenabled = false
local tasks = 0
local rands = false
local endmount = 0
io.open(UIDirectory:gsub("\n",""),"w"):write(""):close()

io.output("source/execute.lua")
for line in io.lines("CELL2") do -- change name if needed
  local min = true
  local vo = false
  local Translation = line:upper()
  local line = line 


  if Translation:find(loop) and Translation:find(sleep) and not Translation:find(lua) then
    io.write("while")
    local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(commas,""):gsub(commas:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(sleep,""):gsub(sleep:lower(),"")
     FP1:match("^%s*(.-)%s*$")
     local FP2 = FP1
     io.write(" os.execute('sleep",FP2,"')")
     io.write(" do\n")
    endmount = endmount + 1
  else
if Translation:find(loop) and not Translation:find(sleep) and not Translation:find(lua) then
  io.write("while true do\n")
  endmount = endmount + 1
end
end
end
amounts = amounts + 1
for line in io.lines("CELL2") do -- change name if needed
  amounts = amounts + 1
  local Translation = line:upper()
  local line = line

  if Translation:find(opens) and not Translation:find(state) and not Translation:find(reads) and not Translation:find(lua) then
       local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(commas,""):gsub(commas:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(opens,""):gsub(opens:lower(),"")
       FP1 = FP1:match("^%s*(.-)%s*$")
       local FP2 = FP1
       M_file = FP2
       io.write("local ",varis,RFLevel," = ","io.open('",FP2,"','a')\n")
  end
  if Translation:find(locals) and Translation:find(reads) and not Translation:find("____")  and not Translation:find("FUNCTION") and not Translation:find(lua) then


     local FP1 = line:gsub(loop,""):gsub(string,""):gsub(locals,""):gsub(rand,""):gsub(prints,""):gsub(writes,""):gsub(ifthen,""):gsub(line,"")
    io.write("local ",varis,RFLevel," = ")
       local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(reads,""):gsub(reads:lower(),"")
       FP1 = FP1:match("^%s*(.-)%s*$")
       local FP2 = FP1
io.write([[io.open(']],FP2,[[','r'):read('*a')]].."\n")
  else


      
if Translation:find(locals) and Translation:find("FUNCTION") and not Translation:find(basket) and not Translation:find(lua) then
     local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(commas,""):gsub(commas:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(line,""):gsub(loop,""):gsub(loop:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(basket:lower(),""):gsub(basket,"")
     FP1:match("^%s*(.-)%s*$")
     io.write("local function ",varis,RFLevel,"(")
    RFLevel = RFLevel + 1
    io.write(varis,RFLevel,")\n")
  end
  end

    if Translation:find(sleep) and not Translation:find(loop) and not Translation:find(sleep) and not Translation:find(lua) then
       local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(commas,""):gsub(commas:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(sleep,""):gsub(sleep:lower(),"")
       FP1:match("^%s*(.-)%s*$")
       local FP2 = FP1
       io.write("\nos.execute('sleep",FP2,"')\n")
    end
    if Translation:find(ifthen) and not Translation:find(lua) then
     local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(commas,""):gsub(commas:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(line,"")
       FP1:match("^%s*(.-)%s*$")
       local FP2 = FP1
       io.write("\nif ",FP2," then\n")
    endmount = endmount + 1
    end
if Translation:find(lua) then
   local FP1 = line:gsub(lua,""):gsub(lua:lower(),"")
     FP1:match("^%s*(.-)%s*$")
     local FP2 = FP1
     io.write("\n",FP2,"\n")
  end
    if Translation:find(__for) and not Translation:find(lua) then
     local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub("<",""):gsub(">","")
       FP1:match("^%s*(.-)%s*$")
       local FP2 = FP1
       io.write(FP2," do\n")
    endmount = endmount + 1
    end
    if Translation:find(done) and not Translation:find(lua) then
     local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(commas,""):gsub(commas:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(line,"")
       FP1:match("^%s*(.-)%s*$")
       local FP2 = FP1
       io.write("\nend\n")
    endmount = endmount - 1
    end






  if not Translation:find(ifthen) and not Translation:find(lua) then



    if Translation:find(varis) and Translation:find(state) and not Translation:find("FOR") and not Translation:find(lua) then
           local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(closes,""):gsub(closes:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(closes,""):gsub(closes:lower(),"")
      FP1:match("^%s*(.-)%s*$")
      local removed = FP1:gsub(line,"")
io.write(removed)
      if Translation:find(closes) and not Translation:find(lua) then
      io.write(":close()")
      else
      io.write("\n")
    end
    end

    if Translation:find(varis) and not Translation:find(state) and not Translation:find("____") and not Translation:find(reads) and not Translation:find(prints) and not Translation:find(writes)  and not Translation:find("FOR") and not Translation:find(locals) and not Translation:find(lua) then
           local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(commas,""):gsub(commas:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(line,"")
         FP1:match("^%s*(.-)%s*$")
      if Translation:find("1") or Translation:find("2") or Translation:find("3") or Translation:find("4") or Translation:find("5") or Translation:find("6") or Translation:find("7") or Translation:find("8") or Translation:find("9") or Translation:find("0") then
         io.write(line,"\n")
      else
        io.write(Translation,"\n")
    end
end
    if Translation:find(varis) and Translation:find(reads) and not Translation:find(locals) and not Translation:find("____") and not Translation:find(lua) then
           local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(commas,""):gsub(commas:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(line,"")
      FP1:match("^%s*(.-)%s*$")
      io.write("io.open('",M_file,"','r'):read()\n")
    end

  if Translation:find(state) and not Translation:find(lua) and not Translation:find(varis) then
           local FP1 = line:gsub(closes,""):gsub(closes:lower(),""):gsub(state,""):gsub(state:lower(),"")
        FP1:match("^%s*(.-)%s*$")
        local FP2 = FP1
        local removed = FP2:gsub(line,"")
        io.write(":write(",removed:gsub("[A-Z]",""),")")
      if Translation:find(closes) then
      io.write(":close()\n")
      else
      io.write("")
      end
  end


  end -- 121







  if Translation:find(basket) and not Translation:find(lua) then

     local FP1 = line:gsub(loop,""):gsub(string,""):gsub(locals,""):gsub(rand,""):gsub(prints,""):gsub(writes,""):gsub(ifthen,""):gsub(basket,""):gsub(basket:lower(),""):gsub(locals, ""):gsub(locals:lower(), "")
    io.write("local ",varis,RFLevel," = {",FP1,"}\n")
min = true
vo = false
RFLevel = RFLevel + 1
else



if vo == false then
if Translation:find(locals) and not Translation:find(reads) and not Translation:find("FUNCTION") then
    if Translation:find(dates) and Translation:find(locals) and not Translation:find(reads) and not Translation:find(state) and not Translation:find(lua) then
    local FP2 = line:gsub(loop,""):gsub(writes,""):gsub(prints,""):gsub(string,""):gsub(locals,"")
    FP2 = FP2:match("^%s*(.-)%s*$")
    io.write("local ",varis,RFLevel," = os.date()\n")
    end
    if Translation:find(rand) and Translation:find(commas) and not Translation:find(dates) and not Translation:find(reads) and not Translation:find(state) and not Translation:find(lua) then
   local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(line,"")
      io.write("local ",varis,RFLevel," =".." math.random(",FP1,")\n")
  else
    local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(line,"")
    FP1:match("^%s*(.-)%s*$")

      if Translation:find("[%d]") and not Translation:find(lua) and not Translation:find(dates) then
        io.write("local ",varis,RFLevel," = ",FP1,"\n")
      else
      if Translation:find("[A-Z]") and not Translation:find(lua) and not Translation:find(dates) then
        io.write("local ",varis,RFLevel," = [[",FP1,"]]\n")
      end
      end
    end
    if Translation:find(string) and not Translation:find(lua) then
  io.write("\n")
   local FP1 = line:gsub(loop,""):gsub(string,""):gsub(locals,""):gsub(rand,""):gsub(prints,""):gsub(writes,"")
    FP1:match("^%s*(.-)%s*$")
    if Translation:find("1") or Translation:find("2") or Translation:find("3") or Translation:find("4") or Translation:find("5") or Translation:find("6") or Translation:find("7") or Translation:find("8") or Translation:find("9") or Translation:find("0") and not Translation:find(dates) then
    io.write("\n"..varis,RFLevel," ="..FP1.."\n")
    else
    io.write("\n"..varis,RFLevel," =[["..FP1.."]]\n")
    end
end
end
  end
if rands == false then


--1234
if not Translation:find(reads) and not Translation:find(state) then
if Translation:find(string) and Translation:find(prints) or Translation:find(locals) and Translation:find(prints) and not Translation:find(state) and not Translation:find(reads) and not Translation:find(lua) then
  local FP2 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(line,"")
  FP2 = FP2:match("^%s*(.-)%s*$")
  io.write("print(",varis,RFLevel,")\n")
  else
if Translation:find(string) and Translation:find(writes) or Translation:find(locals) and Translation:find(writes) and not Translation:find(state) and not Translation:find(lua) then
  local FP2 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(line,"")
  FP2 = FP2:match("^%s*(.-)%s*$")
  io.write("\n".."io.write(",varis,RFLevel,")\n")

else

if Translation:find("+") or Translation:find("-") or Translation:find("*") or Translation:find("/") or Translation:find(varis) and not Translation:find("____") and not Translation:find(state) and not Translation:find(lua) then

  if unnecessary_output == true then
  io.write("\n > Asking for math")
  end

  tasks = tasks + 1
  if unnecessary_output == true then
  io.write(" (",tasks,")")
  end

  if Translation:find(string) and Translation:find(prints) or Translation:find(locals) and Translation:find(prints) and not Translation:find(lua) then
  local FP2 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(line,"")
  FP2 = FP2:match("^%s*(.-)%s*$")
  io.write("print(",varis,RFLevel,")\n")
  else
  if Translation:find(string) and Translation:find(writes) or Translation:find(string) and Translation:find(writes) and not Translation:find(lua) then
  local FP2 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(line,"")
  FP2 = FP2:match("^%s*(.-)%s*$")
  io.write("\nio.write(",varis,RFLevel,")\n")
  else
  if Translation:find(prints) and not Translation:find(lua) then
  local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(line,"")
  FP1 = FP1:match("^%s*(.-)%s*$")
  io.write("print(",FP1,")\n")
  else
  if Translation:find(writes) and not Translation:find(lua) then
 local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(line,"")
  FP1 = FP1:match("^%s*(.-)%s*$"):gsub(writes,""):gsub(writes:lower(),"")
  io.write("\nio.write(",FP1,")\n")
  end
  end
  end
  end --1234


else
if Translation:find(prints) and not Translation:find(state) and not Translation:find(lua) then

  local Anti_mixup = false

  if Translation:find(dates) and not Translation:find(lua) then
  Anti_mixup = true
  if unnecessary_output == true then
  io.write("> Asking for date \n")
  end

  tasks = tasks + 1
  if unnecessary_output == true then
  io.write(" (",tasks,")")
  end

  local FP1 = "os.date()"
  FP1 = FP1:match("^%s*(.-)%s*$")
  io.write("print(",FP1,")\n")


else
if Anti_mixup == false then
  if unnecessary_output == true then
  tasks = tasks + 1
  io.write("(",tasks,")\n")
  end
  local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),"")
  FP1 = FP1:match("^%s*(.-)%s*$")
  io.write("print('",FP1,"')\n")
end
end
else

if Translation:find(writes) and not Translation:find(state) and not Translation:find(lua) then

  local Anti_mixup = false

  if Translation:find(dates) and not Translation:find(lua) then
  Anti_mixup = true
  if unnecessary_output == true then
  io.write("> Asking for date \n")
  end

  tasks = tasks + 1
  if unnecessary_output == true then
  io.write(" (",tasks,")")
  end

  local FP1 = "os.date()"
  FP1 = FP1:match("^%s*(.-)%s*$")
  io.write("\n".."io.write(",FP1,")\n")

else
if Anti_mixup == false then
  if unnecessary_output == true then
  tasks = tasks + 1
  io.write("(",tasks,")\n")
  end
  local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),"")
  FP1 = FP1:match("^%s*(.-)%s*$")
  io.write("\n".."io.write('",FP1,"')\n")

else

if Translation:find("+") or Translation:find("-") or Translation:find("*") or Translation:find("/") and not Translation:find(state) and not Translation:find(lua) then

    if unnecessary_output == true then
    io.write(" > Asking for math\n")
    end

    tasks = tasks + 1
    if unnecessary_output == true then
    io.write("(",tasks,")\n")
    end

    if Translation:find(prints) and not Translation:find(state) and not Translation:find(lua) then

    local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),"")
    FP1 = FP1:match("^%s*(.-)%s*$")
    io.write("print(",FP1,")\n")

    else

    if Translation:find(writes) and not Translation:find(state) and not Translation:find(lua) then
    local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),"")
    FP1 = FP1:match("^%s*(.-)%s*$")
    io.write("\n".."io.write(",FP1,")\n")
    end
    end
end
end
end
end
end
end

end
end


end
if unnecessary_output == true then
  io.write("",RFLevel,"\n")
end
  RFLevel = RFLevel + 1
end
end
if endmountenabled == true then
for i = 1, endmount do
  io.write("\nend\n")
end
end
local htmlStart = io.open(UIDirectory,"w")
htmlStart:write("<!DOCTYPE html><html><head><meta charset='UTF-8'><title>Generated</title></head><body>"):close()









for line in io.lines("CELL2") do -- change name if needed
  amounts = amounts + 1
  local Translation = line:upper()
  local line = line



if Translation:find(background) then
    local _ = io.open(UIDirectory,"a")
    local FP1 = line:gsub(background,""):gsub(background:lower(),"")
    FP1 = FP1:match("^%s*(.-)%s*$")
    _:write("<body style='background-color:",FP1,";'>")
end

    if Translation:find(displayx) then
        local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(background,""):gsub(background:lower(),""):gsub(align,""):gsub(align:lower(),""):gsub(linkframe,""):gsub(linkframe:lower(),""):gsub(displayx,""):gsub(displayx:lower(),"")
        FP1 = FP1:match("^%s*(.-)%s*$")
        local _ = io.open(UIDirectory,"a")
        _:write("<h2 style='font-size:15px; font-style:serif;'>",FP1,"</h2>")
  end

  if Translation:find("AUPD:") then
    local _ = io.popen('dir /b *.html')

    _:write([[<body style="overflow:hidden;"><div id="content"><script>function updateContent(){fetch('source/index.html').then(response => response.text()).then(data =>{document.getElementById('content').innerHTML = data;});}setInterval(updateContent,1000);</script>]])
end
  if Translation:find(bracket) then
  local _ = io.open(UIDirectory,"a")
  _:write("<a style ='")
  end


  local sync= false
  local model = [[WORLD:]]
  local char = [[CHARACTER:]]
  if Translation:find(model) then -- old feature, probably will be removed down the line..
    sync= true
        local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(background,""):gsub(background:lower(),""):gsub(align,""):gsub(align:lower(),""):gsub(linkframe,""):gsub(linkframe:lower(),""):gsub(model,""):gsub(model:lower(),"")
        FP1 = FP1:match("^%s*(.-)%s*$")
        local _ = io.open(UIDirectory,"a")
    _:write([[
      <body oncontextmenu="return false;" onmousedown="if(event.button===2)this.requestPointerLock()">
      <script src="https://unpkg.com/fflate"></script>
      <script src="https://cdnjs.cloudflare.com/ajax/libs/three.js/r128/three.min.js"></script>
      <script src="https://cdn.jsdelivr.net/npm/three@0.128.0/examples/js/controls/OrbitControls.js"></script>
      <script src="https://cdn.jsdelivr.net/npm/three@0.128.0/examples/js/loaders/FBXLoader.js" ></script>
      <script>
        const workspace = new THREE.Scene(), perspective = new THREE.PerspectiveCamera(75, window.innerWidth / window.innerHeight, 0.1, 1000)
        const engine = new THREE.WebGLRenderer({alpha:true});
        engine.setSize(window.innerWidth,window.innerHeight);

        document.body.appendChild(engine.domElement);
        perspective.position.z = 5;
        perspective.position.y = 5;
        perspective.position.x = 5;

        const brightness = new THREE.AmbientLight(0xcdd1b4, 1)
        workspace.add(brightness);

        workspace.background = null;

        const FL = new THREE.DirectionalLight(0xcdd1b4,1.5);
        FL.position.set(3.5,4,2.5);
        workspace.add(FL);




        new THREE.FBXLoader().load(']],FP1)

    _:write([[', (fbx) => {workspace.add(fbx); animate(); });



        function animate()
          {
          requestAnimationFrame(animate);
          engine.render(workspace, perspective);

          }
          window.addEventListener('resize',()=> {engine.setSize(window.innerWidth,window.innerHeight); perspective.aspect = window.innerWidth / window.innerHeight; perspective.updateProjectionMatrix();});




const loadtexture = new THREE.TextureLoader();
const texture = loadtexture.load("WorldSpace/Texture/maptexture.png");
        const loader = new THREE.FBXLoader();
        loader.load(']],FP1)


        _:write([[', (fbx) => {
          fbx.traverse((child) => { 
            if (child.isMesh) {
              child.material.map = texture;
          child.material.needsUpdate = true;
            }
          });
          workspace.add(fbx);
          animate();
        }
          )

      document.addEventListener("mousemove", e => {
      perspective.rotation.y -= e.movementX * 0.001;
      })
      document.addEventListener("keydown", e => {
      const scene = new THREE.Scene();
      const raycaster = new THREE.Raycaster();
      const move = new THREE.Vector3();
      const speed = 0.255;
      const direction = new THREE.Vector3();
          if (e.key === "w"){ perspective.getWorldDirection(direction);
          perspective.position.addScaledVector(direction, speed);

          }
          if (e.key === "s"){ perspective.getWorldDirection(direction);
          perspective.position.addScaledVector(direction, -speed);

          }
          if (e.key === "a"){ 
          perspective.getWorldDirection(direction);
          direction.crossVectors(perspective.up,direction).normalize();
          perspective.position.addScaledVector(direction, speed);

          }
          if (e.key === "d"){ perspective.getWorldDirection(direction).normalize();
          direction.crossVectors(perspective.up,direction).normalize();
          perspective.position.addScaledVector(direction, -speed);

          }


    raycaster.set(perspective.position, move.clone().normalize());
      const intersects = raycaster.intersectObjects(scene.children, true);
      const closest = intersects.length ? intersects[0].distance : Infinity;
      if (closest > move.length()) {
      perspective.position.add(move);
      }
      });
      </script>
      </body>
      ]]) 

  end




  if Translation:find(size) then
    local _ = io.open(UIDirectory,"a")
    local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(background,""):gsub(background:lower(),""):gsub(align,""):gsub(align:lower(),""):gsub(display,""):gsub(display:lower(),""):gsub(linkframe,""):gsub(linkframe:lower(),""):gsub("middle",""):gsub("left",""):gsub("right",""):gsub("top",""):gsub("bottom",""):gsub(attachment,""):gsub(attachment:lower(),""):gsub(size,""):gsub(size:lower(),"")
    _:write("<a style='")
  if Translation:find(size) and not Translation:find([["]]) then
      _:write("transform: scale(",FP1,"); display: inline-block;")
  end
  _:write("'>")
  end

  if Translation:find(attachmentl) then
    local _ = io.open(UIDirectory,"a")
      local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(background,""):gsub(background:lower(),""):gsub(align,""):gsub(align:lower(),""):gsub(display,""):gsub(display:lower(),""):gsub(linkframe,""):gsub(linkframe:lower(),""):gsub("middle",""):gsub("left",""):gsub("right",""):gsub("top",""):gsub("bottom",""):gsub(attachmentl,""):gsub(attachmentl:lower(),"")
    _:write("<img src='",FP1,"' ")
    if Translation:find(align) then
      if line:find("middle") then
       _:write("class='img-middle'")
    else
      if line:find("left") then
       _:write("class='img-left'")
    else
      if line:find("right") then
       _:write("class='img-right'")
    else
      if line:find("bottom") then
       _:write("class='img-bottom'")
    else
      if line:find("top") then
       _:write("class='img-top'")
    end
    end
    end
    end
    end
  end
    _:write("style ='display:block; margin:0 auto; width:240px; height:420px;'>")
  end


  if Translation:find(attachment) then
    local _ = io.open(UIDirectory,"a")
      local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(background,""):gsub(background:lower(),""):gsub(align,""):gsub(align:lower(),""):gsub(display,""):gsub(display:lower(),""):gsub(linkframe,""):gsub(linkframe:lower(),""):gsub("middle",""):gsub("left",""):gsub("right",""):gsub("top",""):gsub("bottom",""):gsub(attachment,""):gsub(attachment:lower(),"")
    _:write("<img src='",FP1,"' ")
    if Translation:find(align) then
      if line:find("middle") then
      _:write("class='img-middle'")
    else
      if line:find("left") then
       _:write("class='img-left'")
    else
      if line:find("right") then
       _:write("class='img-right'")
    else
      if line:find("bottom") then
       _:write("class='img-bottom'")
    else
      if line:find("top") then
       _:write("class='img-top'")
    end
    end
    end
    end
    end
  end
    _:write("style ='display:block; margin:0 auto; width:70px; height:70px; border-radius:2.5px;'>")
  end
  if Translation:find(attachmentx) then
    local _ = io.open(UIDirectory,"a")
      local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(background,""):gsub(background:lower(),""):gsub(align,""):gsub(align:lower(),""):gsub(display,""):gsub(display:lower(),""):gsub(linkframe,""):gsub(linkframe:lower(),""):gsub("middle",""):gsub("left",""):gsub("right",""):gsub("top",""):gsub("bottom",""):gsub(attachmentx,""):gsub(attachmentx:lower(),"")
    _:write("<img src='",FP1,"' ")
    if Translation:find(align) then
      if line:find("middle") then
       _:write("class='img-middle'")
    else
      if line:find("left") then
       _:write("class='img-left'")
    else
      if line:find("right") then
       _:write("class='img-right'")
    else
      if line:find("bottom") then
       _:write("class='img-bottom'")
    else
      if line:find("top") then
       _:write("class='img-top'")
    end
    end
    end
    end
    end
  end
    _:write("style ='display:block; margin:0 auto; width:240px; height:240px;'>")
  end






    if Translation:find(display) then
        local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(background,""):gsub(background:lower(),""):gsub(align,""):gsub(align:lower(),""):gsub(linkframe,""):gsub(linkframe:lower(),""):gsub(display,""):gsub(display:lower(),"")
        FP1 = FP1:match("^%s*(.-)%s*$")
        local _ = io.open(UIDirectory,"a")
        _:write("<h2 style='font-size:12px; font-style:serif;'>",FP1,"</h2>")
  end
  if Translation:find(linkframe) and not Translation:find(attachment) then
    local _ = io.open(UIDirectory,"a")
      local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(background,""):gsub(background:lower(),""):gsub(align,""):gsub(align:lower(),""):gsub(display,""):gsub(display:lower(),""):gsub(linkframe,""):gsub(linkframe:lower(),""):gsub("middle",""):gsub("left",""):gsub("right",""):gsub("top",""):gsub("bottom","")
    _:write("<iframe ")
    _:write("src='",FP1,"' ")
    if Translation:find(align) then
      FP1 = FP1:match("^%s*(.-)%s*$")
      if line:find("middle") then
        _:write("align='middle' ")
      else
      if line:find("left") then
        _:write("align='left' ")
      else
      if line:find("right") then
        _:write("align='right' ")
      else
      if line:find("top") then
        _:write("align='top' ")
      else
      if line:find("bottom") then
        _:write("align='bottom' ")
      else
      end
      end
      end
      end
      end
      end
    _:write("style ='display:block; margin:0 auto; width:15%; height:15%;' frameborder='0'></iframe>")
  end

  if Translation:find(linkframex) and not Translation:find(attachment) then
    local _ = io.open(UIDirectory,"a")
      local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(background,""):gsub(linkframex:lower(),""):gsub(linkframex,""):gsub(background:lower(),""):gsub(align,""):gsub(align:lower(),""):gsub(display,""):gsub(display:lower(),""):gsub(linkframe,""):gsub(linkframe:lower(),""):gsub("middle",""):gsub("left",""):gsub("right",""):gsub("top",""):gsub("bottom","")
    _:write("<iframe")
    _:write(" src='",FP1,"' ")
    if Translation:find(align) then
      FP1 = FP1:match("^%s*(.-)%s*$")
      if line:find("middle") then
        _:write("class='middle' ")
      else
      if line:find("left") then
        _:write("class='left' ")
      else
      if line:find("right") then
        _:write("class='right' ")
      else
      if line:find("top") then
        _:write("class='top' ")
      else
      if line:find("bottom") then
        _:write("class='bottom' ")
      else
      end
      end
      end
      end
      end
      end
    _:write([[style ="border-radius:20px display:block; margin:0; width:100%; height:125%;" frameborder="0" scrolling="no""></iframe>]])
  end



  ---------------------------------
if Translation:find(align) or Translation:find(color) and not Translation:find(linkframe) and not Translation:find(linkframe) and not Translation:find(attachment) and not Translation:find(background) then
    anti_loop = true

      local FP1 = line:gsub(ifthen,""):gsub(ifthen:lower(),""):gsub(loop,""):gsub(loop:lower(),""):gsub(writes,""):gsub(writes:lower(),""):gsub(prints,""):gsub(prints:lower(),""):gsub(dates,""):gsub(dates:lower(),""):gsub(locals,""):gsub(locals:lower(),""):gsub(string,""):gsub(string:lower(),""):gsub(rand,""):gsub(rand:lower(),""):gsub(sleep,""):gsub(sleep:lower(),""):gsub(elses,""):gsub(elses:lower(),""):gsub(opens,""):gsub(opens:lower(),""):gsub(reads,""):gsub(reads:lower(),""):gsub(state,""):gsub(state:lower(),""):gsub(background,""):gsub(background:lower(),""):gsub(display,""):gsub(display:lower(),""):gsub(color,""):gsub(color:lower(),""):gsub(linkframe,""):gsub(linkframe:lower(),""):gsub(align,""):gsub(align:lower(),""):gsub("center",""):gsub("left",""):gsub("right",""):gsub("top",""):gsub("bottom",""):gsub(attachment,""):gsub(attachment:lower(),"")
      FP1 = FP1:match("^%s*(.-)%s*$")
    local _ = io.open(UIDirectory,"a")
    if Translation:find(color) and not Translation:find(linkframe) then
     _:write("color:",FP1,";")
    else

      if Translation:find(align) and line:find("center") and not Translation:find(linkframe) and not Translation:find(color) then

       _:write("text-align:center;")
        _:write("'>")
      else
        if Translation:find(align) and line:find("left") and not Translation:find(linkframe) and not Translation:find(color) then

         _:write("text-align:left;")
          _:write("'>")
        else
        if Translation:find(align) and line:find("right") and not Translation:find(linkframe) and not Translation:find(color) then

         _:write("text-align:right;")
            _:write("'>")
end
        end
      end
  if Translation:find(color) and not Translation:find(linkframe) and not Translation:find(align) then

      _:write("'>")
    end
end


---------------------------------------------------
    if Translation:find(html) then
     local FP1 = line:gsub(html,""):gsub(html:lower(),"")
       FP1:match("^%s*(.-)%s*$")
       local FP2 = FP1
       _:write(FP2,"\n")
    end












    end
end
end ---
io.close()
local htmlFile = io.open(UIDirectory,"a")
if htmlFile then
  htmlFile:write("</body></html>")
  htmlFile:close()
end
os.execute("sleep 2")
os.execute("lua source/execute.lua")
  end

end

-- Every path in this program is relative to the working directory: cfg.root is "rsi", and live.json
-- is written into the current directory. A scheduler that runs `lua /path/to/cell4.lua` WITHOUT
-- cd-ing there first therefore starts a second, empty installation wherever cron happens to put it,
-- reports generation 1 forever, and leaves the real state untouched and unadvanced. That looks
-- exactly like "the program resets every time it runs", so refuse rather than do it quietly. State
-- beside the script but not under the working directory is the signature of that mistake.
local function require_correct_cwd()
  local dir = (arg[0] or ""):match("^(.*)/[^/]+$")
  if not dir or dir == "" or dir == "." then return end
  local here = io.open("rsi/state/state.json", "r")
  if here then here:close() return end
  local there = io.open(dir .. "/rsi/state/state.json", "r")
  if not there then return end
  there:close()
  io.stderr:write("refusing to run: persisted state exists at " .. dir .. "/rsi/state/state.json,\n")
  io.stderr:write("but the working directory is elsewhere, so this run would start an empty\n")
  io.stderr:write("installation at generation 1 and leave the real one untouched.\n")
  io.stderr:write("schedule it as:  cd " .. dir .. " && lua cell4.lua\n")
  os.exit(1)
end

-- Checked before anything below can create rsi/ in the wrong place. `transpile` is exempt: it works
-- on whatever directory it was pointed at and has nothing to do with the RSI state.
if not (arg and (arg[1] == "transpile" or arg[1] == "main")) then require_correct_cwd() end

do
  local function _write_if_missing(path, src)
    local f = io.open(path, "r")
    if f then f:close() return end
    local dir = path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" then os.execute("mkdir -p '" .. dir .. "'") end
    f = assert(io.open(path, "w"))
    f:write(src)
    f:close()
  end
  _write_if_missing('rsi/genome/dsl_base.lua', [[
-- visible primitive selection (mutable)
return {
  ops = {
    -- list
    "reverse", "sort", "sort_desc", "head", "last", "tail", "init", "len", "sum", "max", "min",
    "map_add", "map_sub", "map_mul", "map_mod", "filter_even", "filter_odd", "filter_gt", "filter_lt",
    "take", "drop", "rotate", "concat", "dedup", "cumsum", "diffs", "count", "index_of", "range",
    "singleton", "nth", "abs_all", "mirror", "repeat_list", "zip_add", "evens_idx", "odds_idx",
    "push_front", "push_back", "product", "unique_count",
    -- int
    "add", "sub", "mul", "div", "mod", "max2", "min2", "sq", "inc", "dec", "double", "half", "abs", "neg",
    "is_even", "gt", "eq", "if_int",
    -- grid
    "flip_h", "flip_v", "transpose", "rot90", "rot180", "rot270", "height", "width", "hcat", "vcat",
    "mirror_h", "mirror_v", "upscale", "downscale", "recolor", "fill_nonzero", "count_color", "most_color",
    "most_nonzero_color", "least_nonzero_color", "crop_bbox", "gravity_down", "gravity_up", "gravity_left",
    "gravity_right", "shift_down", "shift_right", "add_border", "remove_border", "top_half", "bottom_half",
    "left_half", "right_half", "overlay", "flatten", "row", "col", "from_row", "nonzero_count", "const_grid",
    "invert_mask", "tile2x2", "object_count", "keep_largest", "keep_smallest", "largest_object_size",
  },
}
]])
  _write_if_missing('rsi/genome/library.lua', [[
return {}
]])
  _write_if_missing('rsi/genome/policy.lua', [[
-- search policy: costs, constants, budgets, strategy (mutable)
return {
  strategy = "probe",       -- "probe" (cost-guided bottom-up + just-in-time learning) | "levelwise" (plain size-based)
  default_cost = 2,         -- integer cost of a primitive application unless overridden in cost{}
  const_cost = 1,
  leaf_cost = 1,
  max_cost = 9,             -- deepest cost level the enumeration will reach
  bank_cap = 350,           -- max distinct programs kept per (type, cost) bucket
  jit = true,               -- Probe-style just-in-time weight learning from partially-correct programs
  jit_rate = 1,             -- cost decrease applied to ops of partially-correct programs (per level)
  jit_min_match = 1,        -- minimum matching examples for a program to count as partial evidence
  coerce_ic = false,        -- let small non-negative ints feed colour slots and colours feed int slots
  consts = { I = { 0, 1, 2, 3 }, C = { 0, 1, 2, 3, 4, 5 } },
  -- Measured flat on this distribution (0.0pp on 300 mixed tasks, 0.0pp on 180 large-value tasks):
  -- the generated values are small and the pool above already covers them, so 86% of tasks derive
  -- nothing. Kept because it is the standard remedy where literals matter (real ARC uses ten colours
  -- and dimensions to 30) and the mutation operators can switch it on if evidence ever appears.
  derived_consts = false,   -- also mine example-invariant literals from the task's own I/O pairs
  derived_const_cap = 8,    -- at most this many, ranked by how much the examples demand them
  derived_const_cost = 1,   -- cost of a derived literal leaf
  cost = {},                -- per-op cost overrides, learned by prior fitting
  cond_cost = {},           -- task-feature bucket -> {op -> cost}, learned task-conditioned priors
  cond_ops = {},            -- task-feature bucket -> {op -> true}, per-bucket enumeration whitelist
  -- Verified on four independent 300-task sets (+6.3, +3.0, +8.3, +6.0 pp; pooled 66.0% -> 71.8%,
  -- 66 wins against 14 losses) while using fewer search nodes. On by default.
  bidirectional = true,     -- build the backward bank and meet the forward enumeration in the middle
  back_frac = 0.25,         -- share of the node budget the backward bank may consume
  back_max_cost = 6,        -- deepest backward chain, in the same cost units as the forward search
  back_after_cost = 3,      -- build it only once forward search past this cost level has failed
  back_cap = 400,           -- max backward entries
  binary_meet = true,       -- deduce one argument of a binary operator from the other
  binary_meet_depth = 2,    -- only from backward entries at most this deep
  binary_meet_cap = 24,     -- cheapest forward candidates offered as the known argument
  -- measured at +0.3pp (1 win, 0 losses, p=0.37) on 300 tasks: real but not evidence, so off
  meet_replay = false,      -- replay the binary meet once the forward bank has grown
  meet_replay_slack = 4,    -- extra cost the replay may spend, since its known argument is deeper
  two_phase = true,         -- try the narrow whitelist first, then fall back to the full operator set
  phase1_frac = 0.5,        -- share of the node budget given to the narrow phase
}
]])
  _write_if_missing('rsi/genome/search.lua', [=[
-- search engine (mutable): bidirectional cost-guided enumeration with observational equivalence.
-- Mechanisms: bottom-up enumeration by integer cost with OE dedup (Udupa et al. / TRANSIT style),
-- Probe-style just-in-time cost learning from partially-correct programs (Barke et al. 2020),
-- learned library primitives enter as ordinary unary ops (DreamCoder-style reuse), and a backward
-- bank built by inverting the goal through invertible operators, met in the middle by the forward
-- enumeration (inverse semantics / witness functions, as in FlashFill-style deductive synthesis).
--
-- The backward bank is the reason this engine is not blind. Forward enumeration spends its budget on
-- breadth and asks "did anything I built happen to equal the target"; the backward bank asks "what
-- would the rest of the program have to produce for this operator to finish the job", which is a
-- deduction, not a guess. Backward entries are counted against the same node budget as forward ones,
-- so the two halves compete for one resource and the comparison against a purely forward search is
-- like for like.
local M = {}

function M.solve(task, ctx)
  local prims, order = ctx.dsl.prims, ctx.dsl.order
  local policy = ctx.policy
  local sig, equal, P = ctx.sig, ctx.equal, ctx.program
  local INV = ctx.inverses
  local CONSTS = ctx.constants
  local train = task.train
  local n = #train
  local inputs, targets = {}, {}
  for i = 1, n do inputs[i] = train[i].input targets[i] = train[i].output end
  local in_type, out_type = task.in_type, task.out_type
  local total_budget, deadline = ctx.budget, ctx.deadline
  local clock = os.clock

  -- op costs: task-conditioned table (learned recognition prior) if one matches this task's features,
  -- otherwise the unconditional learned costs, otherwise the default
  local feat_bucket = ctx.features and ctx.features(task)
  local cond = policy.cond_cost and feat_bucket and policy.cond_cost[feat_bucket]
  local cost = {}
  for _, name in ipairs(order) do cost[name] = (cond and cond[name]) or policy.cost[name] or policy.default_cost end
  -- Branching factor, not depth, is what the node budget buys. A per-bucket whitelist of operators
  -- that have ever appeared in a solution of this task shape narrows every level of the enumeration.
  local narrow = policy.cond_ops and feat_bucket and policy.cond_ops[feat_bucket]

  -- Two-phase portfolio. Measured: a per-bucket operator whitelist saves ~23% of the nodes and wins
  -- 11 tasks the wide enumeration misses, but loses 22 by excluding operators it turns out to need.
  -- So run the narrow enumeration first on a slice of the budget, then fall back to the full operator
  -- set with what remains. The narrow phase keeps its wins; the fallback keeps the losses off.
  local nodes = 0
  local function enumerate(allow, budget)
  local bank, seen = {}, {}
  local function bucket(ty, c)
    local b = bank[ty]
    if not b then b = {} bank[ty] = b end
    local l = b[c]
    if not l then l = {} b[c] = l end
    return l
  end

  local best_matches, best_node = 0, nil
  local level_partials = {}

  -- ---------- backward bank ----------
  -- A backward entry maps a value-tuple the forward search might produce to a context that turns it
  -- into the target. Each step is verified by applying the operator forward to the candidate
  -- preimage, so reaching an entry is a solution by construction rather than a hypothesis.
  local back, back_n, back_entries = {}, 0, {}
  local function back_key(ty, vals)
    local parts = {}
    for i = 1, n do parts[i] = sig(vals[i]) end
    return ty .. "|" .. table.concat(parts, ";")
  end

  -- mkargs turns the hole into the operator's full argument list, so the same routine serves unary
  -- inverses, inverses with a constant second argument, and both hole positions of a binary meet.
  local function add_back(vals, ty, c, parent, name, mkargs, nextf)
    local key = back_key(ty, vals)
    if back[key] then return end
    nodes = nodes + 1
    back_n = back_n + 1
    local pb = parent.build
    local e = {
      vals = vals, ty = ty, cost = c,
      build = function(node) return pb(P.node(name, mkargs(node))) end,
    }
    back[key] = e
    back_entries[#back_entries + 1] = e
    if nextf then nextf[#nextf + 1] = e end
  end

  local function args_unary(node) return { node } end

  -- Only a minority of operators are invertible. Scanning the whole DSL for every frontier entry was
  -- the dominant cost of the backward bank; indexing by return type cuts that loop by an order of
  -- magnitude, which matters because the wall-clock deadline, not the node budget, was the binding
  -- constraint when this was measured.
  local inv_by_ret = nil
  local function index_inverses(allow)
    local idx = {}
    for _, name in ipairs(order) do
      local p = prims[name]
      local has = (INV.inv1[name] and #p.t == 1) or (INV.inv2[name] and #p.t == 2)
        or ((INV.inv_arg1[name] or INV.inv_arg2[name]) and #p.t == 2)
      if has and not (p.bucket and p.bucket ~= feat_bucket) and not (allow and not allow[name]) then
        idx[p.r] = idx[p.r] or {}
        table.insert(idx[p.r], name)
      end
    end
    return idx
  end

  -- cheapest-first view of the forward bank, for the binary meet
  -- min_cost lets the replay pass draw on material the first pass could not have seen: without it
  -- the cheapest-first cap returns the same candidates every time and replaying deduces nothing.
  local function forward_candidates(ty, cap, min_cost)
    local out = {}
    local byc = bank[ty]
    if not byc then return out end
    local costs = {}
    for c in pairs(byc) do if not min_cost or c >= min_cost then costs[#costs + 1] = c end end
    table.sort(costs)
    for _, c in ipairs(costs) do
      for _, en in ipairs(byc[c]) do
        out[#out + 1] = { entry = en, cost = c }
        if #out >= cap then return out end
      end
    end
    return out
  end

  -- Binary meet: with one argument drawn from what the forward search can already build, the other
  -- argument is determined. This is what reaches the compositional shapes -- concat of the input with
  -- a transform of it, a grid beside its own mirror, one grid overlaid on another -- where neither
  -- argument is a constant and the outer operator is therefore invisible to the plain inverse rules.
  -- Restricted to shallow backward entries and to the cheapest forward candidates, because the
  -- forward bank is large and this is quadratic in it.
  local function binary_meet_over(list, nextf, budget, maxc, cap, min_cost)
    if not policy.binary_meet then return end
    local depth_limit = policy.binary_meet_depth or 2
    local fcap = policy.binary_meet_cap or 24
    for _, e in ipairs(list) do
      if e.cost <= depth_limit then
        for _, name in ipairs(inv_by_ret[e.ty] or {}) do
          local p = prims[name]
          if #p.t == 2 then
            for slot = 1, 2 do
              local rule = (slot == 2) and INV.inv_arg2[name] or INV.inv_arg1[name]
              local known_ty = (slot == 2) and p.t[1] or p.t[2]
              local hole_ty = (slot == 2) and p.t[2] or p.t[1]
              if rule then
                for _, fc in ipairs(forward_candidates(known_ty, fcap, min_cost)) do
                  if nodes >= budget or back_n >= cap then return end
                  local nc = e.cost + cost[name] + fc.cost
                  if nc <= maxc then
                    local cand, ok = {}, true
                    for i = 1, n do
                      local known = fc.entry.outs[i]
                      local ok2, v = pcall(rule, e.vals[i], known)
                      if not ok2 or v == nil then ok = false break end
                      local ok3, chk
                      if slot == 2 then ok3, chk = pcall(p.f, known, v) else ok3, chk = pcall(p.f, v, known) end
                      if not ok3 or not equal(chk, e.vals[i]) then ok = false break end
                      cand[i] = v
                    end
                    if ok then
                      local sib = fc.entry.node
                      local mk = (slot == 2)
                        and function(node) return { sib, node } end
                        or function(node) return { node, sib } end
                      add_back(cand, hole_ty, nc, e, name, mk, nextf)
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  local function build_back(allow, budget)
    inv_by_ret = index_inverses(allow)
    local root = { vals = targets, ty = out_type, cost = 0, build = function(node) return node end }
    back[back_key(out_type, targets)] = root
    back_entries[#back_entries + 1] = root
    -- an integer-valued forward program can answer a colour-typed task and the other way round
    local alt = (out_type == "C" and "I") or (out_type == "I" and "C") or nil
    if alt then back[back_key(alt, targets)] = root end
    local frontier = { root }
    local maxc = policy.back_max_cost or 6
    local cap = policy.back_cap or 400
    for _ = 1, maxc do
      local nextf = {}
      local frontier_in = frontier
      for _, e in ipairs(frontier) do
        for _, name in ipairs(inv_by_ret[e.ty] or {}) do
          if nodes >= budget or back_n >= cap then return end
          local p = prims[name]
          do
            local nc = e.cost + cost[name]
            if nc <= maxc then
              local k1, k2 = INV.inv1[name], INV.inv2[name]
              if k1 and #p.t == 1 then
                local cand, ok = {}, true
                for i = 1, n do
                  local ok2, v = pcall(k1, e.vals[i])
                  if not ok2 or v == nil then ok = false break end
                  local ok3, chk = pcall(p.f, v)
                  if not ok3 or not equal(chk, e.vals[i]) then ok = false break end
                  cand[i] = v
                end
                if ok then add_back(cand, p.t[1], nc, e, name, args_unary, nextf) end
              elseif k2 and #p.t == 2 then
                for _, kv in ipairs(policy.consts[p.t[2]] or {}) do
                  local cand, ok = {}, true
                  for i = 1, n do
                    local ok2, v = pcall(k2, e.vals[i], kv)
                    if not ok2 or v == nil then ok = false break end
                    local ok3, chk = pcall(p.f, v, kv)
                    if not ok3 or not equal(chk, e.vals[i]) then ok = false break end
                    cand[i] = v
                  end
                  if ok then
                    local kn = P.const(kv, p.t[2])
                    add_back(cand, p.t[1], nc, e, name, function(node) return { node, kn } end, nextf)
                  end
                end
              end
            end
          end
        end
      end
      binary_meet_over(frontier_in, nextf, budget, maxc, cap)
      frontier = nextf
      if #frontier == 0 then break end
    end
  end

  -- Values already in the forward bank were created before the backward bank existed, so they were
  -- never offered a meet. One sweep after the bank is built catches them.
  local function sweep_bank()
    for ty, byc in pairs(bank) do
      for _, list in pairs(byc) do
        for _, e in ipairs(list) do
          local hit = back[back_key(ty, e.outs)]
          if hit then return hit.build(e.node) end
        end
      end
    end
    return nil
  end

  -- The backward bank is built lazily. Measured: building it up front cost seven depth-1 list tasks,
  -- because a task solvable by a single operator was made to pay for machinery it never needed and
  -- ran out of wall-clock before the forward search started. Deferring it until the forward search
  -- has exhausted every depth-1 program (all of which have cost <= 3) makes the investment conditional
  -- on the task actually being hard.
  local back_built, meet_replayed = false, false
  local function maybe_build_back(allow)
    if back_built or not (policy.bidirectional and INV) then return nil end
    back_built = true
    build_back(allow, math.min(budget, nodes + math.floor(total_budget * (policy.back_frac or 0.25))))
    return sweep_bank()
  end

  -- The binary meet can only pair with forward values that existed when it ran, and it runs early,
  -- when the bank holds little more than the input and the depth-1 programs. Replaying it once the
  -- bank has grown lets it deduce arguments it could not have seen the first time.
  local function maybe_replay_meet(allow)
    if meet_replayed or back_built == false or not (policy.bidirectional and INV) then return nil end
    if not policy.meet_replay then return nil end
    meet_replayed = true
    binary_meet_over(back_entries, nil,
      math.min(budget, nodes + math.floor(total_budget * (policy.back_frac or 0.25))),
      (policy.back_max_cost or 6) + (policy.meet_replay_slack or 4), policy.back_cap or 400,
      (policy.back_after_cost or 3) + 1)
    return sweep_bank()
  end

  local function type_matches(ty)
    return ty == out_type or (out_type == "C" and ty == "I") or (out_type == "I" and ty == "C")
  end

  -- returns solution node if all train examples match
  local function consider(ty, c, node, outs)
    local parts = {}
    for i = 1, n do parts[i] = sig(outs[i]) end
    local key = ty .. "|" .. table.concat(parts, ";")
    if seen[key] then return nil end
    seen[key] = true
    nodes = nodes + 1
    -- meet in the middle: this value is one the backward chain knows how to finish
    local hit = back[key]
    if hit then return hit.build(node) end
    local l = bucket(ty, c)
    if #l < policy.bank_cap then
      local entry = { node = node, outs = outs }
      l[#l + 1] = entry
      -- optional int<->colour sharing: small non-negative ints may feed colour slots and vice versa
      if policy.coerce_ic and (ty == "I" or ty == "C") then
        local other = ty == "I" and "C" or "I"
        local fits = true
        if other == "C" then
          for i = 1, n do local v = outs[i] if v < 0 or v > 9 or v ~= math.floor(v) then fits = false break end end
        end
        if fits then
          local l2 = bucket(other, c)
          if #l2 < policy.bank_cap then l2[#l2 + 1] = entry end
        end
      end
    end
    if type_matches(ty) then
      local m = 0
      for i = 1, n do if equal(outs[i], targets[i]) then m = m + 1 end end
      if m == n then return node end
      if m > best_matches then best_matches, best_node = m, node end
      if m >= policy.jit_min_match then level_partials[#level_partials + 1] = node end
    end
    return nil
  end

  -- leaves
  do
    local outs = {}
    for i = 1, n do outs[i] = inputs[i] end
    consider(in_type, policy.leaf_cost, P.var(), outs)
    local function leaf_const(v, ty, c)
      local o = {}
      for i = 1, n do o[i] = v end
      return consider(ty, c, P.const(v, ty), o)
    end
    for ty, list in pairs(policy.consts) do
      for _, v in ipairs(list) do
        local s = leaf_const(v, ty, policy.const_cost)
        if s then return { program = s, nodes = nodes, partial = 1 } end
      end
    end
    -- Literals read off this task's own examples. Widening the global pool was measured and lost
    -- 3.5pp, because every extra leaf multiplies through every level; these are few and relevant.
    if policy.derived_consts and CONSTS then
      local ok, derived = pcall(CONSTS.derive, train, CONSTS.pool_set(policy.consts),
        policy.derived_const_cap or 8)
      if ok then
        for _, d in ipairs(derived) do
          local s = leaf_const(d.value, d.ty, policy.derived_const_cost or policy.const_cost)
          if s then return { program = s, nodes = nodes, partial = 1 } end
        end
      end
    end
  end

  local function apply1(f, a)
    local outs = {}
    for i = 1, n do outs[i] = f(a.outs[i]) end
    return outs
  end
  local function apply2(f, a, b)
    local outs = {}
    for i = 1, n do outs[i] = f(a.outs[i], b.outs[i]) end
    return outs
  end
  local function apply3(f, a, b, c)
    local outs = {}
    for i = 1, n do outs[i] = f(a.outs[i], b.outs[i], c.outs[i]) end
    return outs
  end

  local function exhausted()
    if nodes >= budget then return true end
    if nodes % 64 == 0 and clock() > deadline then return true end
    return false
  end

  for C = 2, policy.max_cost do
    if C > (policy.back_after_cost or 3) then
      local s = maybe_build_back(allow)
      if s then return { program = s, nodes = nodes, partial = 1 } end
    end
    if C > (policy.back_after_cost or 3) + 2 then
      local s = maybe_replay_meet(allow)
      if s then return { program = s, nodes = nodes, partial = 1 } end
    end
    level_partials = {}
    for _, name in ipairs(order) do
      local p = prims[name]
      local w = cost[name]
      local R = C - w
      local k = #p.t
      -- a bucket-scoped abstraction only enters the enumeration for tasks of that shape, so learned
      -- ops cost nothing on the tasks they were not learned from
      if p.bucket and p.bucket ~= feat_bucket then R = -1 end
      if allow and not allow[name] then R = -1 end
      if R >= k then
        local f, t = p.f, p.t
        if k == 1 then
          local A = bank[t[1]] and bank[t[1]][R]
          if A then
            for ai = 1, #A do
              local a = A[ai]
              local ok, outs = pcall(apply1, f, a)
              if ok then
                local s = consider(p.r, C, P.node(name, { a.node }), outs)
                if s then return { program = s, nodes = nodes, partial = 1 } end
              end
              if exhausted() then return { program = nil, nodes = nodes, partial = best_matches / n, best_partial = best_node } end
            end
          end
        elseif k == 2 then
          for c1 = 1, R - 1 do
            local c2 = R - c1
            local A = bank[t[1]] and bank[t[1]][c1]
            local B = bank[t[2]] and bank[t[2]][c2]
            if A and B then
              for ai = 1, #A do
                local a = A[ai]
                for bi = 1, #B do
                  local b = B[bi]
                  local ok, outs = pcall(apply2, f, a, b)
                  if ok then
                    local s = consider(p.r, C, P.node(name, { a.node, b.node }), outs)
                    if s then return { program = s, nodes = nodes, partial = 1 } end
                  end
                  if exhausted() then return { program = nil, nodes = nodes, partial = best_matches / n, best_partial = best_node } end
                end
              end
            end
          end
        elseif k == 3 then
          for c1 = 1, R - 2 do
            for c2 = 1, R - 1 - c1 do
              local c3 = R - c1 - c2
              local A = bank[t[1]] and bank[t[1]][c1]
              local B = bank[t[2]] and bank[t[2]][c2]
              local Cc = bank[t[3]] and bank[t[3]][c3]
              if A and B and Cc then
                for ai = 1, #A do
                  for bi = 1, #B do
                    for ci = 1, #Cc do
                      local a, b, c = A[ai], B[bi], Cc[ci]
                      local ok, outs = pcall(apply3, f, a, b, c)
                      if ok then
                        local s = consider(p.r, C, P.node(name, { a.node, b.node, c.node }), outs)
                        if s then return { program = s, nodes = nodes, partial = 1 } end
                      end
                      if exhausted() then return { program = nil, nodes = nodes, partial = best_matches / n, best_partial = best_node } end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
    -- just-in-time learning: ops appearing in partially-correct programs become cheaper for later levels
    if policy.jit and policy.strategy == "probe" and #level_partials > 0 then
      local touched = {}
      for _, node in ipairs(level_partials) do
        for _, op in ipairs(P.ops_used(node)) do touched[op] = true end
      end
      for op in pairs(touched) do cost[op] = math.max(1, cost[op] - policy.jit_rate) end
    end
  end
  return { program = nil, nodes = nodes, partial = best_matches / n, best_partial = best_node }
  end

  if narrow and policy.two_phase then
    local first = enumerate(narrow, math.floor(total_budget * (policy.phase1_frac or 0.5)))
    if first.program then return first end
    local second = enumerate(nil, total_budget)
    if second.partial >= first.partial then return second end
    second.partial, second.best_partial = first.partial, first.best_partial
    return second
  end
  return enumerate(narrow, total_budget)
end

return M
]=])
end

if arg and (arg[1] == "transpile" or arg[1] == "main") then
  require("cell4.main")
  return
end

-- ==== run.lua (CLI entry) ====
-- One process invocation = one generation, then exit.
--   lua cell4.lua [step]        load persisted state, one cycle.step(), persist, live.json, exit
--   lua cell4.lua status        print state summary
--   lua cell4.lua unlock [force] clear a lock left behind by a killed generation
--   lua cell4.lua research      force a research fetch now
--   lua cell4.lua eval          evaluate the champion on fresh splits without mutating anything
--   lua cell4.lua narrate [delay] replay the latest generation's account, a word at a time
--   lua cell4.lua history       print the whole narrated history
--   lua cell4.lua selftest      verify the external ARC benchmark path end to end
-- Persistent loop is not supported: schedule this file externally (cron / Namecheap cron).
package.path = "./?.lua;./?/init.lua;" .. package.path
local cmd = arg[1] or "step"
local cycle = require("rsi.kernel.cycle")

-- live.json is a derived snapshot of the latest committed generation. It is written only after
-- cycle.step() returns, which itself only returns after save_state / genome / bench are persisted.
-- It is not the authoritative store; rsi/state/state.json and rsi/genome/ are.
local function write_live(r)
  local cfg = require("rsi.config")
  local json = require("rsi.kernel.json")
  local state = json.read(cfg.root .. "/state/state.json")
  if not state then error("state.json missing after generation; refusing to advertise live.json") end
  local live = {
    ok = true,
    time = os.time(),
    gen = r.gen or state.gen,
    heldout = r.heldout,
    accepted = r.accepted and true or false,
    operator = r.operator,
    change = r.change,
    accepted_total = state.accepted_total,
    candidates_total = state.candidates_total,
    -- The generation's own account of itself: two or three sentences composed procedurally from
    -- audited measurements by rsi/kernel/narrator.lua (no network, no model, no external call), read
    -- back out of the state.json that was just committed rather than from anything still in memory.
    -- `narrated_gen` says which generation they belong to, so a generation whose narration failed
    -- cannot pass off the previous one's lines as its own.
    -- The solver budgets this generation ran under. Two generations at different budgets are not
    -- directly comparable, so the public page should not present them as if they were.
    budget = state.budget_profile,
    narrated_gen = state.narration and state.narration.gen or nil,
    lines = state.narration and state.narration.lines or nil,
    recent = state.narration_log,
  }
  json.write("live.json", live)
end

if cmd == "step" then
  local ok, r = pcall(cycle.step)
  if not ok then
    io.stderr:write(tostring(r), "\n")
    os.exit(1)
  end
  local live_ok, live_err = pcall(write_live, r)
  if not live_ok then
    io.stderr:write("live.json write failed (generation was still persisted): ", tostring(live_err), "\n")
  end
  print(string.format("generation %d done: held-out %.1f%% %s", r.gen, r.heldout * 100, r.accepted and ("ACCEPTED " .. r.operator) or "(no change)"))
elseif cmd == "loop" then
  io.stderr:write("persistent execution is not supported: this process runs exactly one generation and exits.\n")
  io.stderr:write("schedule `lua cell4.lua` (or `lua cell4.lua step`) externally.\n")
  os.exit(1)
elseif cmd == "unlock" then
  -- Clear a lock left behind by a killed generation. Read the message before using `unlock force`.
  local ok, msg = cycle.unlock(arg[2] == "force")
  print(msg)
  if not ok then os.exit(1) end
elseif cmd == "status" then
  local state, bench = cycle.status()
  print("generation", state.gen, "accepted", state.accepted_total, "of", state.candidates_total)
  print("held-out epoch", bench.heldout_epoch, "regression suite", #bench.regression, "rotations", #bench.rotations)
  for _, l in ipairs(state.log or {}) do print(l) end
elseif cmd == "research" then
  -- Goes through cycle.force_research so it takes the single-writer lock and the same defaulted
  -- state load a generation uses. It must never write a state.json a later generation cannot read.
  local json = require("rsi.kernel.json")
  local ok, r = pcall(cycle.force_research)
  if not ok then
    io.stderr:write(tostring(r), "\n")
    os.exit(1)
  end
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
