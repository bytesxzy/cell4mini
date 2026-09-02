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
  for _, f in ipairs(cfg.adversarial_families) do
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
