dofile("/tmp/claude-0/-home-user-cell4mini/264d82ac-3d60-59de-a5a9-1527d50c6c13/scratchpad/verify/kernel_only.lua")
local ops = require("rsi.kernel.ops")
local base = dofile("rsi/genome/dsl_base.lua")
local inb = {} for _,n in ipairs(base.ops) do inb[n]=true end
local vis, hid = {}, {}
for name, o in pairs(ops.catalogue) do
  local sig = name .. "(" .. table.concat(o.t, ",") .. ") -> " .. o.r
  if o.hidden then hid[#hid+1] = sig else vis[#vis+1] = sig end
end
table.sort(vis); table.sort(hid)
print("# CELL4 DSL — the solver's complete vocabulary")
print("# Types: I=int, L=list of int, G=grid (g[r][c], g.h, g.w), B=bool, C=colour 0..9")
print("# Programs are compositions over a single input variable $. No lambdas, no loops,")
print("# no let-bindings, no user-defined control flow. Every program is a nested call chain.")
print("")
print("## VISIBLE to the solver (" .. #vis .. " ops) — these are all it can ever compose:")
for _, s in ipairs(vis) do print("  " .. s) end
print("")
print("## HIDDEN (" .. #hid .. " ops) — implemented but REFUSED by genome.load.")
print("## They exist only so task generators can build targets the solver must reach by composition.")
print("## Exposing them would inflate the held-out score without improving reasoning. Off limits.")
for _, s in ipairs(hid) do print("  " .. s) end
