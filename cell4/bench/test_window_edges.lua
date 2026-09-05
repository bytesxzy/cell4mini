package.path = "./?.lua;./?/init.lua;" .. package.path
local src = assert(io.open("cell4.lua", "r")):read("*a")
local cut = src:find("-- ==== run%.lua %(CLI entry%) ====")
assert(load(src:sub(1, cut - 1), "@cell4.lua"))()
local cfg = require("rsi.config")
local B = require("rsi.kernel.benchmarks")

local function try(label, fn)
  local ok, a, b = pcall(fn)
  print(string.format("%-34s %s", label, ok and (tostring(a) .. "  " .. tostring(b or "")) or ("ERROR: " .. tostring(a))))
end

try("cap=0   seed=1", function() local e = B.load_external(cfg.root, 0, 1) return #e, B.external_digest(e) end)
try("cap=0   seed=nil", function() local e = B.load_external(cfg.root, 0, nil) return #e end)
try("cap=1   seed=1", function() local e = B.load_external(cfg.root, 1, 1) return #e, e[1].id end)
try("cap=20  seed=1", function() local e = B.load_external(cfg.root, 20, 1) return #e end)
try("cap=20  seed=nil (old)", function() local e = B.load_external(cfg.root, 20, nil) return #e, e[1].id end)
try("cap=549 seed=7", function() local e = B.load_external(cfg.root, 549, 7) return #e end)
try("cap=550 seed=7", function() local e = B.load_external(cfg.root, 550, 7) return #e end)
try("cap=10000 seed=7", function() local e = B.load_external(cfg.root, 10000, 7) return #e end)
try("corpus size", function() return B.external_corpus_size(cfg.root) end)

-- determinism: same seed must give the same window, different seeds must differ
local a1 = B.external_digest(B.load_external(cfg.root, 20, 42))
local a2 = B.external_digest(B.load_external(cfg.root, 20, 42))
local a3 = B.external_digest(B.load_external(cfg.root, 20, 43))
print("determinism  same seed twice :", a1 == a2 and "IDENTICAL (correct)" or "DIFFERS (BUG)")
print("rotation     seed 42 vs 43   :", a1 ~= a3 and "DIFFERS (correct)" or "IDENTICAL (BUG)")

-- stratification + coverage: every task must be reachable across enough generations
local seen, gens = {}, 200
for g = 1, gens do
  for _, t in ipairs(B.load_external(cfg.root, 20, g)) do seen[t.id] = (seen[t.id] or 0) + 1 end
end
local n, mn, mx = 0, math.huge, 0
for _, c in pairs(seen) do n = n + 1 if c < mn then mn = c end if c > mx then mx = c end end
print(string.format("coverage over %d gens at cap=20: %d/%d distinct tasks drawn, per-task draws min=%d max=%d",
  gens, n, B.external_corpus_size(cfg.root), mn, mx))
