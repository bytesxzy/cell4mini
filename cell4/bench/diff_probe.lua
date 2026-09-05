package.path = "./?.lua;./?/init.lua;" .. package.path
local src = assert(io.open("cell4.lua", "r")):read("*a")
local cut = src:find("-- ==== run%.lua %(CLI entry%) ====")
assert(load(src:sub(1, cut - 1), "@cell4.lua"))()
local cfg=require("rsi.config") local benchmarks=require("rsi.kernel.benchmarks")
local genome=require("rsi.kernel.genome") local program=require("rsi.kernel.program")
local ops=require("rsi.kernel.ops") local features=require("rsi.kernel.features")
local inverses=require("rsi.kernel.inverses") local constants=require("rsi.kernel.constants")
local tasks=require("rsi.kernel.tasks") local sandbox=require("rsi.kernel.sandbox")
local g=genome.load(cfg.root.."/genome")
local collect=dofile("rsi/genome/search_collect.lua")
local bench=benchmarks.load(cfg.root)
local splits=benchmarks.build_splits(bench,cfg,"selection-probe")
local list=splits.heldout
local function mkctx() return { dsl={prims=g.prims,order=g.order}, policy=g.policy,
  budget=800, deadline=os.clock()+1, sig=ops.sig, equal=ops.equal, program=program,
  features=features.bucket, inverses=inverses, constants=constants } end
local prod_only,both,collect_only,agree=0,0,0,0
local samples={}
for _,task in ipairs(list) do
  local view=tasks.solver_view(task)
  local okp,resp=sandbox.run(40000000,g.solve,view,mkctx())
  local pprog=(okp and type(resp)=="table" and resp.program) and program.to_string(resp.program) or nil
  local cc=mkctx() cc.budget=12000 cc.deadline=os.clock()+10 local okc=pcall(collect.solve,view,cc)
  local first=(okc and collect.COLLECT and collect.COLLECT[1]) and program.to_string(collect.COLLECT[1]) or nil
  if pprog and first then
    both=both+1
    if pprog==first then agree=agree+1
    elseif #samples<6 then samples[#samples+1]=task.id.."\n      prod   : "..pprog.."\n      collect: "..first end
  elseif pprog then prod_only=prod_only+1
  elseif first then collect_only=collect_only+1 end
end
print(string.format("tasks: %d", #list))
print(string.format("  both found a program        : %d   (identical program: %d)", both, agree))
print(string.format("  production found, collect NOT: %d   <- collect is WEAKER here", prod_only))
print(string.format("  collect found, production NOT: %d   <- collect is STRONGER here", collect_only))
for _,s in ipairs(samples) do print("    "..s) end
