package.path = "./?.lua;./?/init.lua;" .. package.path
local src = assert(io.open("cell4.lua","r")):read("*a")
local cut = src:find("-- ==== run%.lua %(CLI entry%) ====")
assert(load(src:sub(1,cut-1),"@cell4.lua"))()
local cfg=require("rsi.config") local benchmarks=require("rsi.kernel.benchmarks")
local bench=benchmarks.load(cfg.root)
local sp=benchmarks.build_splits(bench,cfg,"defect-check")
print(string.format("adversarial split size      : %d tasks", #sp.adversarial))
local n=#sp.adversarial
print(string.format("smallest possible negative delta on it: -1/%d = %.5f", n, -1/n))
print(string.format("configured adversarial_tolerance      : %.5f", cfg.adversarial_tolerance))
if -1/n < cfg.adversarial_tolerance then
  print("=> ANY single adversarial regression already breaches tolerance. Documented 'may lose up to 3pp' is ZERO tolerance in practice. NIGHT-01 §6 CONFIRMED.")
else
  print("=> tolerance admits at least one adversarial loss. NIGHT-01 §6 claim does NOT hold at this split size.")
end
print(string.format("regression_cap                        : %d", cfg.regression_cap))
print(string.format("heldout split size                    : %d", #sp.heldout))
print(string.format("train split size                      : %d", #sp.train))
