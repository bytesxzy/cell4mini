-- Run from the repo root: `lua5.3 tests/cell4_smoke_test.lua`
local scriptDir = arg[0]:match("(.*/)") or "./"
package.path = scriptDir .. "../?.lua;" .. package.path
local Cell4 = require("cell4")

local function assertEq(a, b, msg)
	if a ~= b then
		error(("assertion failed (%s): got %s, expected %s"):format(msg, tostring(a), tostring(b)))
	end
end

-- Utils
assertEq(Cell4.Utils.clamp(5, 0, 1), 1, "clamp high")
assertEq(Cell4.Utils.clamp(-5, 0, 1), 0, "clamp low")
local sm = Cell4.Utils.softmax({1, 1, 1})
assert(math.abs(sm[1] - sm[2]) < 1e-9 and math.abs(sm[2] - sm[3]) < 1e-9, "softmax uniform")
local total = sm[1] + sm[2] + sm[3]
assert(math.abs(total - 1) < 1e-9, "softmax sums to 1")

-- Memory
local mem = Cell4.Memory.new(3)
mem:remember("threatLevel", "high", 0.9)
local v, conf = mem:recall("threatLevel", 1000000) -- huge half-life -> negligible decay
assertEq(v, "high", "memory recall value")
assert(conf > 0.85, "memory recall confidence roughly preserved")

for i = 1, 5 do
	mem:pushObservation({ i = i }, i)
end
local recent = mem:recentContext(3)
assertEq(#recent, 3, "ring buffer caps at capacity")
assertEq(recent[1].data.i, 5, "most recent observation first")
assertEq(recent[3].data.i, 3, "ring buffer wrapped correctly")

-- NeuralNet: structural forward pass with zero weights should be inert (all zeros through relu/linear)
local net = Cell4.NeuralNet.new({2, 3, 2}, "relu", "linear")
assertEq(net:isLoaded(), false, "fresh net reports not loaded")
local out = net:forward({1, 2})
assertEq(out[1], 0, "zero-weight net outputs zero (1)")
assertEq(out[2], 0, "zero-weight net outputs zero (2)")

-- Load hand-built weights and check a known forward pass.
-- Layer 1: 2 in -> 2 hidden, identity-ish; Layer 2: 2 hidden -> 1 out, sum.
local tinyNet = Cell4.NeuralNet.new({2, 2, 1}, "relu", "linear")
tinyNet:loadWeights({
	layers = {
		{ weights = { {1, 0}, {0, 1} }, biases = {0, 0} },
		{ weights = { {1, 1} }, biases = {0} },
	},
})
assertEq(tinyNet:isLoaded(), true, "net reports loaded after loadWeights")
local r = tinyNet:forward({3, 4})
assertEq(r[1], 7, "tiny net computes sum of inputs through identity hidden layer")

-- Reasoning: pure rule-based, no policy net attached.
local reasoning = Cell4.Reasoning.new()
reasoning:registerGoal("flee", 1, function(state, memory)
	local threat = state.named.threat or 0
	return threat, ("threat signal is %.2f"):format(threat)
end)
reasoning:registerGoal("explore", 1, function(state, memory)
	local threat = state.named.threat or 0
	return 1 - threat, "inverse of threat"
end)
reasoning:registerGoal("broken", 1, function(state, memory)
	error("boom")
end)

local spec = { { key = "threat", min = 0, max = 1 } }
local state = Cell4.Perception.normalize({ threat = 0.9 }, spec)
local decision, trace = reasoning:decide(state, mem)
assertEq(decision.name, "flee", "high threat -> flee wins")
assert(#trace == 3, "trace includes all goals including the erroring one")
local brokenEntry
for _, t in ipairs(trace) do
	if t.name == "broken" then brokenEntry = t end
end
assertEq(brokenEntry.score, 0, "erroring goal scores zero, does not crash decide()")

-- Pipeline end-to-end
local pipeline = Cell4.Pipeline.new({
	perceptionSpec = spec,
	reasoning = reasoning,
	memory = Cell4.Memory.new(8),
})
local result = pipeline:step({ threat = 0.1 })
assertEq(result.decision, "explore", "low threat -> pipeline picks explore")
assert(result.trace and #result.trace == 3, "pipeline surfaces full trace")

-- Reasoning + policy net combined (policy vote should add to matching rule vote)
local policyNet = Cell4.NeuralNet.new({1, 2}, "relu", "linear")
policyNet:loadWeights({
	layers = {
		{ weights = { {10}, {0} }, biases = {0, 0} }, -- strongly favors action 1 ("flee")
	},
})
local reasoning2 = Cell4.Reasoning.new()
reasoning2:registerGoal("flee", 1, function(state) return 0.2, "baseline" end)
reasoning2:registerGoal("explore", 1, function(state) return 0.2, "baseline" end)
reasoning2:attachPolicy(policyNet, {"flee", "explore"})
local state2 = Cell4.Perception.normalize({ threat = 0.5 }, spec)
local decision2 = reasoning2:decide(state2, mem)
assertEq(decision2.name, "flee", "policy net vote pushes combined score toward flee")

print("ALL SMOKE TESTS PASSED")
