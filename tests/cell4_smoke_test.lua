-- Run from the repo root: `lua5.3 tests/cell4_smoke_test.lua`
local scriptDir = arg[0]:match("(.*/)") or "./"
package.path = scriptDir .. "../?.lua;" .. package.path
local Cell4 = require("cell4")

local checks = 0
local function assertEq(a, b, msg)
	checks = checks + 1
	if a ~= b then
		error(("assertion failed (%s): got %s, expected %s"):format(msg, tostring(a), tostring(b)), 2)
	end
end
local function assertTrue(cond, msg)
	checks = checks + 1
	if not cond then
		error(("assertion failed (%s)"):format(msg), 2)
	end
end
local function assertNear(a, b, tol, msg)
	checks = checks + 1
	if math.abs(a - b) > tol then
		error(("assertion failed (%s): got %s, expected ~%s"):format(msg, tostring(a), tostring(b)), 2)
	end
end

-- A controllable clock so time-dependent behaviour is deterministic and
-- tests never have to sleep.
local fakeTime = 0
local function fakeClock() return fakeTime end

-- =====================================================================
-- Utils
-- =====================================================================
assertEq(Cell4.Utils.clamp(5, 0, 1), 1, "clamp high")
assertEq(Cell4.Utils.clamp(-5, 0, 1), 0, "clamp low")
local sm = Cell4.Utils.softmax({1, 1, 1})
assertNear(sm[1], sm[2], 1e-9, "softmax uniform")
assertNear(sm[1] + sm[2] + sm[3], 1, 1e-9, "softmax sums to 1")
-- Large values would overflow exp() without the max-subtraction trick.
local big = Cell4.Utils.softmax({1000, 1001})
assertTrue(big[1] == big[1] and big[2] == big[2], "softmax is numerically stable on large inputs")
assertNear(big[1] + big[2], 1, 1e-9, "stable softmax still sums to 1")

local sorted = Cell4.Utils.sortScored({
	{ name = "b", score = 1 }, { name = "a", score = 1 }, { name = "c", score = 2 },
}, "name")
assertEq(sorted[1].name, "c", "sortScored orders by score")
assertEq(sorted[2].name, "a", "sortScored breaks ties deterministically by name")

-- =====================================================================
-- RingBuffer
-- =====================================================================
local rb = Cell4.RingBuffer.new(3)
for i = 1, 5 do rb:push(i) end
assertEq(rb.count, 3, "ring buffer caps at capacity")
local recent = rb:recent(3)
assertEq(recent[1], 5, "recent() is newest first")
assertEq(recent[3], 3, "recent() wraps correctly")
local chrono = rb:toArray()
assertEq(chrono[1], 3, "toArray() is oldest first")
assertEq(chrono[3], 5, "toArray() ends at newest")
rb:clear()
assertEq(rb.count, 0, "clear() empties the buffer")

-- =====================================================================
-- Memory
-- =====================================================================
local mem = Cell4.Memory.new(3, fakeClock)
mem:remember("threatLevel", "high", 0.9)
local v, conf = mem:recall("threatLevel", 10)
assertEq(v, "high", "memory recall value")
assertNear(conf, 0.9, 1e-9, "confidence intact at zero age")

fakeTime = 10 -- exactly one half-life
local _, decayed = mem:recall("threatLevel", 10)
assertNear(decayed, 0.45, 1e-9, "confidence halves after one half-life")
fakeTime = 0

assertEq((mem:recall("nothing-here")), nil, "recall of unknown key returns nil")

for i = 1, 5 do mem:pushObservation({ i = i }, i) end
local ctx = mem:recentContext(3)
assertEq(#ctx, 3, "memory keeps only capacity observations")
assertEq(ctx[1].data.i, 5, "most recent observation first")

-- =====================================================================
-- NeuralNet
-- =====================================================================
local net = Cell4.NeuralNet.new({2, 3, 2}, "relu", "linear")
assertEq(net:isLoaded(), false, "fresh net reports not loaded")
local out = net:forward({1, 2})
assertEq(out[1], 0, "zero-weight net outputs zero (1)")
assertEq(out[2], 0, "zero-weight net outputs zero (2)")

local desc = net:describe()
assertEq(desc.parameters, (2 * 3 + 3) + (3 * 2 + 2), "describe() counts weights + biases")
assertEq(desc.layerSizes[1], 2, "describe() reports input size")
assertEq(desc.loaded, false, "describe() reports load state")

-- Hand-computed forward pass: identity hidden layer, summing output layer.
local tinyNet = Cell4.NeuralNet.new({2, 2, 1}, "relu", "linear")
tinyNet:loadWeights({
	layers = {
		{ weights = { {1, 0}, {0, 1} }, biases = {0, 0} },
		{ weights = { {1, 1} }, biases = {0} },
	},
})
assertEq(tinyNet:isLoaded(), true, "net reports loaded after loadWeights")
assertEq(tinyNet:forward({3, 4})[1], 7, "tiny net sums inputs through identity hidden layer")

-- relu must actually clip negatives, not pass them through.
local reluNet = Cell4.NeuralNet.new({1, 1}, "relu", "relu")
reluNet:loadWeights({ layers = { { weights = { {-1} }, biases = {0} } } })
assertEq(reluNet:forward({5})[1], 0, "relu clips negative pre-activation to zero")

-- Shape mismatches must be loud, not silently truncated.
local mismatched = Cell4.NeuralNet.new({2, 2}, "relu", "linear")
assertTrue(not pcall(function()
	mismatched:loadWeights({ layers = { { weights = { {1, 2, 3}, {1, 2, 3} }, biases = {0, 0} } } })
end), "loadWeights rejects wrong input width")
assertTrue(not pcall(function()
	mismatched:loadWeights({ layers = { { weights = { {1, 2} }, biases = {0} } } })
end), "loadWeights rejects wrong output count")
assertTrue(not pcall(function() net:forward({1}) end), "forward rejects wrong input size")
assertTrue(not pcall(function() Cell4.NeuralNet.new({2, 2}, "nonsense") end), "unknown activation rejected")

-- Every selectable activation must actually be reachable and correct, not
-- just present in the table.
local sigmoidNet = Cell4.NeuralNet.new({1, 1}, "relu", "sigmoid")
sigmoidNet:loadWeights({ layers = { { weights = { {0} }, biases = {0} } } })
assertNear(sigmoidNet:forward({1})[1], 0.5, 1e-9, "sigmoid(0) = 0.5")

local tanhNet = Cell4.NeuralNet.new({1, 1}, "relu", "tanh")
tanhNet:loadWeights({ layers = { { weights = { {1} }, biases = {0} } } })
assertNear(tanhNet:forward({0})[1], 0, 1e-9, "tanh(0) = 0")
assertNear(tanhNet:forward({1})[1], 0.7615941559, 1e-9, "tanh(1) matches the reference value")
assertNear(tanhNet:forward({-1})[1], -0.7615941559, 1e-9, "tanh is odd-symmetric")
-- Activations must saturate at extremes, never overflow to NaN. A single
-- NaN activation propagates through the pass and destroys every decision
-- downstream, and large weights are exactly what training produces.
for _, extreme in ipairs({1e3, 1e6, 1e300, -1e3, -1e6, -1e300}) do
	local t = Cell4.Utils.tanh(extreme)
	assertTrue(t == t, ("tanh(%g) is not NaN"):format(extreme))
	assertTrue(t >= -1 and t <= 1, ("tanh(%g) stays in [-1,1]"):format(extreme))
	local s = Cell4.Utils.sigmoid(extreme)
	assertTrue(s == s, ("sigmoid(%g) is not NaN"):format(extreme))
	assertTrue(s >= 0 and s <= 1, ("sigmoid(%g) stays in [0,1]"):format(extreme))
end
assertNear(Cell4.Utils.tanh(1e6), 1, 1e-12, "tanh saturates to +1")
assertNear(Cell4.Utils.tanh(-1e6), -1, 1e-12, "tanh saturates to -1")
assertNear(Cell4.Utils.sigmoid(1e6), 1, 1e-12, "sigmoid saturates to 1")
assertNear(Cell4.Utils.sigmoid(-1e6), 0, 1e-12, "sigmoid saturates to 0")
-- A whole forward pass with weights big enough to overflow the naive form.
local hugeNet = Cell4.NeuralNet.new({1, 1, 1}, "tanh", "tanh")
hugeNet:loadWeights({
	layers = { { weights = { {1e9} }, biases = {0} }, { weights = { {1e9} }, biases = {0} } },
})
local hugeOut = hugeNet:forward({1})[1]
assertTrue(hugeOut == hugeOut, "a forward pass with huge weights produces no NaN")
assertNear(hugeOut, 1, 1e-12, "huge weights saturate rather than blowing up")

-- =====================================================================
-- Perception
-- =====================================================================
local spec = {
	{ key = "threat", min = 0, max = 100 },
	{ key = "health", min = 0, max = 100 },
}
local state = Cell4.Perception.normalize({ threat = 50, health = 200 }, spec)
assertNear(state.named.threat, 0.5, 1e-9, "normalize scales into [0,1]")
assertEq(state.named.health, 1, "normalize clamps above max")
assertEq(state.featureVector[1], state.named.threat, "featureVector matches named, in spec order")
assertEq(state.predicted, false, "observed state is not flagged predicted")

local derived = Cell4.Perception.withDelta(state, spec, { threat = -0.3 })
assertNear(derived.named.threat, 0.2, 1e-9, "withDelta applies delta")
assertNear(derived.featureVector[1], 0.2, 1e-9, "withDelta keeps featureVector in sync")
assertEq(derived.predicted, true, "derived state is flagged predicted")
assertNear(state.named.threat, 0.5, 1e-9, "withDelta does not mutate the source state")
assertEq(Cell4.Perception.withValues(state, spec, { threat = 9 }).named.threat, 1, "withValues clamps")

-- =====================================================================
-- Derived features: a single frame is not a sufficient state.
-- =====================================================================
local derivedSpec = {
	{ key = "threat", min = 0, max = 100 },
	{ key = "health", min = 0, max = 100 },
	{ key = "threatTrend", derive = Cell4.Perception.delta("threat") },
	-- A derived feature may build on earlier ones, derived ones included.
	{ key = "danger", derive = function(f) return f.threat * (1 - f.health) end },
}

local first = Cell4.Perception.normalize({ threat = 50, health = 100 }, derivedSpec, nil)
assertNear(first.named.threatTrend, 0.5, 1e-9, "with no previous tick, trend reads as unchanged")
assertNear(first.named.danger, 0, 1e-9, "composite feature computes from earlier features")
assertEq(#first.featureVector, 4, "derived features occupy their own vector slots")

local rising = Cell4.Perception.normalize({ threat = 90, health = 100 }, derivedSpec, first.named)
assertTrue(rising.named.threatTrend > 0.5, "a rising signal reads above 0.5")
local falling = Cell4.Perception.normalize({ threat = 10, health = 100 }, derivedSpec, rising.named)
assertTrue(falling.named.threatTrend < 0.5, "a falling signal reads below 0.5")
local steadySignal = Cell4.Perception.normalize({ threat = 10, health = 100 }, derivedSpec, falling.named)
assertNear(steadySignal.named.threatTrend, 0.5, 1e-9, "an unchanged signal reads as exactly 0.5")

-- The whole point: identical raw readings, opposite trends.
assertNear(rising.named.threat, 0.9, 1e-9, "same raw threat")
local alsoNinety = Cell4.Perception.normalize({ threat = 90, health = 100 }, derivedSpec,
	{ threat = 1.0, health = 1 })
assertNear(alsoNinety.named.threat, 0.9, 1e-9, "same raw threat again")
assertTrue(rising.named.threatTrend ~= alsoNinety.named.threatTrend,
	"identical raw states are distinguishable once trend is a feature")

-- delta scale controls how quickly the signal saturates.
local coarse = Cell4.Perception.delta("threat", 0.1)
assertNear(coarse({ threat = 1 }, { threat = 0 }), 0.55, 1e-9, "a small scale keeps deltas near neutral")
local sharp = Cell4.Perception.delta("threat", 10)
assertNear(sharp({ threat = 1 }, { threat = 0 }), 1, 1e-9, "a large scale saturates")

-- A broken derive() must not take the tick down, and must not hide.
local brokenSpec = {
	{ key = "threat", min = 0, max = 100 },
	{ key = "bad", derive = function() error("derive exploded") end },
	{ key = "alsoBad", derive = function() return "not a number" end },
}
local brokenState = Cell4.Perception.normalize({ threat = 50 }, brokenSpec, nil)
assertNear(brokenState.named.threat, 0.5, 1e-9, "a broken feature does not stop the others")
assertEq(brokenState.named.bad, 0, "a failed derive contributes a neutral zero")
assertEq(brokenState.named.alsoBad, 0, "a non-numeric derive contributes a neutral zero")
assertTrue(brokenState.featureErrors ~= nil, "broken features are recorded")
assertTrue(brokenState.featureErrors.bad:find("failed"), "an erroring derive explains itself")
assertTrue(brokenState.featureErrors.alsoBad:find("returned string"), "a mistyped derive explains itself")
assertEq(first.featureErrors, nil, "a healthy tick records no feature errors")

-- End to end through the pipeline, including the episode boundary rule.
local trendReasoning = Cell4.Reasoning.new()
trendReasoning:registerRule("brace", 1, function(s) return s.named.threatTrend, "threat trend" end)
trendReasoning:registerRule("relax", 1, function(s) return 1 - s.named.threatTrend, "inverse trend" end)
local trendPipeline = Cell4.Pipeline.new({
	perceptionSpec = derivedSpec, reasoning = trendReasoning, clock = fakeClock,
})
fakeTime = fakeTime + 1
trendPipeline:step({ threat = 10, health = 100 })
fakeTime = fakeTime + 1
local climbing = trendPipeline:step({ threat = 90, health = 100 })
assertEq(climbing.decision, "brace", "the pipeline reacts to a rising trend")
assertTrue(climbing.state.named.threatTrend > 0.5, "the pipeline threads the previous tick through")

-- A delta measured across a death is change that never happened.
trendPipeline:endEpisode(0)
fakeTime = fakeTime + 1
local reincarnated = trendPipeline:step({ threat = 10, health = 100 })
assertNear(reincarnated.state.named.threatTrend, 0.5, 1e-9,
	"trend does not measure across an episode boundary")

-- Derived features appear in the contract, flagged as such.
local trendContract = trendPipeline:trainingContract()
assertEq(#trendContract.features, 4, "the contract covers derived features too")
assertEq(trendContract.features[3].name, "threatTrend", "derived features keep their vector position")
assertEq(trendContract.features[3].derived, true, "derived features are flagged in the contract")
assertEq(trendContract.features[3].max, 1, "derived features are already normalized")
assertEq(trendContract.features[1].derived, false, "raw features are flagged as raw")

-- The planner must keep imagined states self-consistent: an action that
-- lowers threat has to make the trend read as falling in that imagined
-- future, not keep the trend the real world happened to have.
local trendPlanner = Cell4.Planner.new({ spec = derivedSpec, maxDepth = 1 })
trendPlanner:registerAction({
	name = "calm",
	effects = function(s, h) return h.withDelta({ threat = -0.5 }) end,
})
trendPlanner:registerAction({
	name = "provoke",
	effects = function(s, h) return h.withDelta({ threat = 0.5 }) end,
})
local trendScorer = Cell4.Reasoning.new()
-- This goal reads ONLY the derived trend, so it can only work if imagined
-- states recompute it.
trendScorer:registerGoal("wantsFallingThreat", 1, function(s) return 1 - s.named.threatTrend end)
local risingState = Cell4.Perception.normalize({ threat = 90, health = 100 }, derivedSpec, first.named)
assertTrue(risingState.named.threatTrend > 0.5, "the real state's trend is rising")
local trendPlan = trendPlanner:plan(risingState, mem, trendScorer)
assertEq(trendPlan.firstAction, "calm", "the planner sees the trend its own action would create")

-- Directly: recomputeDerived rewrites derived features from the base ones.
local imagined = Cell4.Perception.withDelta(risingState, derivedSpec, { threat = -0.5 })
assertTrue(imagined.named.threatTrend > 0.5, "before recompute, the trend is stale")
local consistent = Cell4.Perception.recomputeDerived(imagined, derivedSpec, risingState.named)
assertTrue(consistent.named.threatTrend < 0.5, "after recompute, the trend reflects the imagined change")
assertNear(consistent.named.danger, consistent.named.threat * (1 - consistent.named.health), 1e-9,
	"composites are recomputed from the imagined base features")
assertNear(consistent.featureVector[3], consistent.named.threatTrend, 1e-9,
	"recompute keeps the vector in sync with the named table")
assertNear(risingState.named.threatTrend, imagined.named.threatTrend, 1e-9,
	"recompute does not mutate the state it was given")

-- A broken feature surfaces in the human-readable trace.
local brokenPipeline = Cell4.Pipeline.new({
	perceptionSpec = brokenSpec, reasoning = trendReasoning, clock = fakeClock,
})
fakeTime = fakeTime + 1
local brokenResult = brokenPipeline:step({ threat = 50 })
assertTrue(brokenResult.featureErrors ~= nil, "the pipeline surfaces feature errors")
assertTrue(brokenPipeline:explain(brokenResult):find("BROKEN FEATURE"), "explain() flags broken features")

-- =====================================================================
-- Reasoning: rules only
-- =====================================================================
local reasoning = Cell4.Reasoning.new()
reasoning:registerRule("flee", 1, function(s)
	return s.named.threat, ("threat is %.2f"):format(s.named.threat)
end)
reasoning:registerRule("explore", 1, function(s)
	return 1 - s.named.threat, "inverse of threat"
end)
reasoning:registerRule("broken", 1, function() error("boom") end)

local decision, trace = reasoning:decide(state, mem)
-- threat is 0.5, so flee and explore both score 0.5; the tie must resolve
-- deterministically (alphabetically), not by table iteration order.
assertEq(decision.name, "explore", "exact tie resolves alphabetically, deterministically")
local highThreat = Cell4.Perception.normalize({ threat = 90, health = 100 }, spec)
assertEq(reasoning:decide(highThreat, mem).name, "flee", "high threat -> flee wins outright")
local lowThreat = Cell4.Perception.normalize({ threat = 10, health = 100 }, spec)
assertEq(reasoning:decide(lowThreat, mem).name, "explore", "low threat -> explore wins outright")
assertEq(#trace, 3, "trace includes every goal, including the broken one")
local brokenEntry
for _, entry in ipairs(trace) do
	if entry.name == "broken" then brokenEntry = entry end
end
assertEq(brokenEntry.score, 0, "erroring goal scores zero without crashing decide()")
assertTrue(brokenEntry.reasons[1]:find("failed"), "erroring goal explains itself in the trace")

-- A goal returning a non-number is handled like an error, not coerced.
local badTypeReasoning = Cell4.Reasoning.new()
badTypeReasoning:registerRule("weird", 1, function() return "not a number" end)
local badDecision = badTypeReasoning:decide(state, mem)
assertEq(badDecision.score, 0, "non-numeric goal score treated as zero")

-- scoreState aggregates by weight, and a broken goal drags the score down
-- rather than being quietly excluded.
local scoreOnly = Cell4.Reasoning.new()
scoreOnly:registerGoal("a", 1, function() return 1 end)
scoreOnly:registerGoal("b", 1, function() return 0 end)
assertNear(scoreOnly:scoreState(state, mem), 0.5, 1e-9, "scoreState averages by weight")
scoreOnly:registerGoal("c", 1, function() error("nope") end)
assertNear(scoreOnly:scoreState(state, mem), 1 / 3, 1e-9, "broken goal counts as 0 utility, still counted in weight")

-- =====================================================================
-- Confidence
-- =====================================================================
local clearCut = Cell4.Reasoning.new()
clearCut:registerRule("win", 1, function() return 1 end)
clearCut:registerRule("lose", 1, function() return 0 end)
local clearDecision = clearCut:decide(state, mem)
assertEq(clearDecision.name, "win", "clear winner chosen")
assertNear(clearDecision.confidence, 1, 1e-9, "dominant choice is full confidence")

local tied = Cell4.Reasoning.new()
tied:registerRule("left", 1, function() return 0.5 end)
tied:registerRule("right", 1, function() return 0.5 end)
local tiedDecision = tied:decide(state, mem)
assertNear(tiedDecision.confidence, 0, 1e-9, "exact tie is zero confidence")

local nothing = Cell4.Reasoning.new()
nothing:registerRule("meh", 1, function() return 0 end)
assertNear(nothing:decide(state, mem).confidence, 0, 1e-9, "all-zero scores is zero confidence")

local empty = Cell4.Reasoning.new()
local noDecision, emptyTrace = empty:decide(state, mem)
assertEq(noDecision, nil, "no goals -> no decision")
assertEq(#emptyTrace, 0, "no goals -> empty trace")

-- =====================================================================
-- Planner
-- =====================================================================
-- World model: "retreat" lowers threat, "advance" raises it. The goal set
-- rewards low threat, so the planner should prefer retreating.
local planner = Cell4.Planner.new({ spec = spec, maxDepth = 3, beamWidth = 4, discount = 0.9 })
planner:registerAction({
	name = "retreat",
	effects = function(s, h) return h.withDelta({ threat = -0.4 }) end,
})
planner:registerAction({
	name = "advance",
	effects = function(s, h) return h.withDelta({ threat = 0.4 }) end,
})

local safety = Cell4.Reasoning.new()
safety:registerGoal("safety", 1, function(s) return 1 - s.named.threat, "prefers low threat" end)

local plan = planner:plan(state, mem, safety)
assertEq(plan.firstAction, "retreat", "planner picks the action that lowers threat")
assertEq(plan.depth, 3, "planner searches to max depth when it keeps improving")
assertEq(plan.sequence[1], "retreat", "plan sequence starts with the chosen action")
assertTrue(plan.score > 0.5, "retreat plan scores above neutral")
assertTrue(plan.expanded > 0, "planner reports how many nodes it expanded")

-- Preconditions must actually gate actions.
local gated = Cell4.Planner.new({ spec = spec, maxDepth = 1 })
gated:registerAction({
	name = "impossible",
	preconditions = function() return false end,
	effects = function(s, h) return h.withDelta({ threat = -1 }) end,
})
assertEq(gated:plan(state, mem, safety), nil, "action with false preconditions is never planned")

-- An action whose effects/preconditions blow up must not take the plan down.
local risky = Cell4.Planner.new({ spec = spec, maxDepth = 1 })
risky:registerAction({ name = "explodes", effects = function() error("bang") end })
risky:registerAction({ name = "safe", effects = function(s, h) return h.withDelta({ threat = -0.5 }) end })
local riskyPlan = risky:plan(state, mem, safety)
assertEq(riskyPlan.firstAction, "safe", "a broken action is skipped, planning continues")

local errPrecond = Cell4.Planner.new({ spec = spec, maxDepth = 1 })
errPrecond:registerAction({
	name = "bad-guard",
	preconditions = function() error("guard exploded") end,
	effects = function(s, h) return h.clone() end,
})
assertEq(errPrecond:plan(state, mem, safety), nil, "erroring precondition means not applicable, not assumed true")

assertEq(Cell4.Planner.new({ spec = spec }):plan(state, mem, safety), nil, "planner with no actions returns nil")
assertTrue(not pcall(function() Cell4.Planner.new({}) end), "planner requires a perception spec")
assertTrue(not pcall(function() planner:registerAction({ name = "no-effects" }) end), "action requires effects()")

-- Cost penalty should make an expensive action lose to an equivalent cheap one.
local costly = Cell4.Planner.new({ spec = spec, maxDepth = 1, costPenalty = 0.5 })
costly:registerAction({ name = "cheap", cost = 1, effects = function(s, h) return h.withDelta({ threat = -0.4 }) end })
costly:registerAction({ name = "pricey", cost = 4, effects = function(s, h) return h.withDelta({ threat = -0.5 }) end })
assertEq(costly:plan(state, mem, safety).firstAction, "cheap", "cost penalty outweighs a marginally better outcome")

-- =====================================================================
-- Reasoning + planner + policy: all three votes land in one ranking
-- =====================================================================
local combined = Cell4.Reasoning.new()
-- Flat action preferences: on their own these tie and decide nothing.
combined:registerRule("retreat", 1, function() return 0.2, "baseline" end)
combined:registerRule("advance", 1, function() return 0.2, "baseline" end)
-- The goal is what gives the planner something to rank futures by. Note it
-- is NOT an action - "safety" must never show up as a thing the agent does.
combined:registerGoal("safety", 1, function(s) return 1 - s.named.threat end)
combined:attachPlanner(planner, 1)
local combinedDecision, combinedTrace = combined:decide(state, mem)
assertEq(combinedDecision.name, "retreat", "planner vote tips the decision toward retreat")
assertTrue(#combinedDecision.sources >= 2, "winning action shows both rule and plan sources")
local sawPlanSource = false
for _, entry in ipairs(combinedTrace) do
	for _, src in ipairs(entry.sources) do
		if src == "plan" then sawPlanSource = true end
	end
end
assertTrue(sawPlanSource, "plan vote is attributed in the trace")
assertTrue(combined.lastPlan ~= nil, "planner exposes the plan it produced")

-- Goals describe desirable states, not things to do. A goal must never leak
-- into the action ranking or the action list as a phantom action.
for _, entry in ipairs(combinedTrace) do
	assertTrue(entry.name ~= "safety", "a goal never appears as a candidate action")
end
for _, name in ipairs(combined:actionNames()) do
	assertTrue(name ~= "safety", "a goal never appears in the action contract")
end
assertEq(combined:hasGoals(), true, "reasoner reports having goals")

-- Without goals there is no value function, so the planner must decline to
-- plan rather than return an arbitrary pick that looks like reasoning.
local goalless = Cell4.Reasoning.new()
goalless:registerRule("retreat", 1, function() return 0.2, "baseline" end)
assertEq(goalless:hasGoals(), false, "reasoner reports having no goals")
assertEq(planner:plan(state, mem, goalless), nil, "planner declines to plan with no goals")
goalless:attachPlanner(planner, 1)
local goallessDecision, goallessTrace = goalless:decide(state, mem)
assertEq(goallessDecision.name, "retreat", "reactive rules still decide without goals")
assertEq(goalless.lastPlan, nil, "no plan is fabricated when planning is impossible")
assertEq(#goallessTrace, 1, "no phantom plan vote enters the ranking")

-- Policy net: one input (threat), two outputs, strongly favouring index 1.
local policyNet = Cell4.NeuralNet.new({2, 2}, "relu", "linear")
policyNet:loadWeights({
	layers = { { weights = { {10, 0}, {0, 0} }, biases = {0, 0} } },
})
local withPolicy = Cell4.Reasoning.new()
withPolicy:registerRule("advance", 1, function() return 0.2, "baseline" end)
withPolicy:registerRule("retreat", 1, function() return 0.2, "baseline" end)
withPolicy:attachPolicy(policyNet, { "advance", "retreat" })
assertEq(withPolicy:decide(state, mem).name, "advance", "policy vote tips an otherwise tied decision")

-- A policy whose input width doesn't match the spec must surface, not hide.
local wrongShape = Cell4.NeuralNet.new({5, 2}, "relu", "linear")
wrongShape:loadWeights({
	layers = { { weights = { {0,0,0,0,0}, {0,0,0,0,0} }, biases = {0, 0} } },
})
local mismatchReasoning = Cell4.Reasoning.new()
mismatchReasoning:registerRule("advance", 1, function() return 0.5, "baseline" end)
mismatchReasoning:attachPolicy(wrongShape, { "advance", "retreat" })
local mismatchScored = mismatchReasoning:evaluate(state, mem)
local sawPolicyError = false
for _, entry in ipairs(mismatchScored) do
	if entry.source == "policy-error" then sawPolicyError = true end
end
assertTrue(sawPolicyError, "policy shape mismatch is reported in evaluate()")
local mismatchDecision, mismatchTrace = mismatchReasoning:decide(state, mem)
assertEq(mismatchDecision.name, "advance", "decision still works with a broken policy")
assertEq(#mismatchTrace, 1, "policy-error diagnostic is kept out of the action ranking")

-- An unloaded policy net contributes nothing at all.
local unloadedReasoning = Cell4.Reasoning.new()
unloadedReasoning:registerRule("advance", 1, function() return 0.5, "baseline" end)
unloadedReasoning:attachPolicy(Cell4.NeuralNet.new({2, 2}), { "advance", "retreat" })
local _, unloadedTrace = unloadedReasoning:decide(state, mem)
assertEq(#unloadedTrace, 1, "unloaded policy casts no votes")

-- actionNames unions every source and stays sorted (it defines training indices).
local naming = Cell4.Reasoning.new()
naming:registerRule("zulu", 1, function() return 0 end)
naming:attachPlanner(planner, 1)
naming:attachPolicy(policyNet, { "alpha", "zulu" })
local names = naming:actionNames()
assertEq(table.concat(names, ","), "advance,alpha,retreat,zulu", "actionNames is a sorted dedup union")

-- =====================================================================
-- Pipeline end-to-end
-- =====================================================================
local pipeline = Cell4.Pipeline.new({
	perceptionSpec = spec,
	reasoning = combined,
	clock = fakeClock,
	experienceCapacity = 8,
})
fakeTime = 1
local r1 = pipeline:step({ threat = 90, health = 100 })
assertEq(r1.decision, "retreat", "high threat -> retreat")
assertTrue(r1.plan ~= nil, "pipeline surfaces the plan behind the decision")
assertEq(r1.state.predicted, false, "pipeline reasons from an observed state")
assertTrue(#r1.trace >= 2, "pipeline surfaces the full trace")

-- Experience: the first step has nothing to close yet; the second closes the first.
assertEq(#pipeline:exportExperience().records, 0, "no completed transition after one step")
fakeTime = 2
pipeline:step({ threat = 40, health = 100 }, 1.5)
local exported = pipeline:exportExperience()
assertEq(#exported.records, 1, "second step closes out the first transition")
local rec = exported.records[1]
assertEq(rec.action, "retreat", "recorded the action actually taken")
assertEq(rec.reward, 1.5, "reward attributed to the step that earned it")
assertNear(rec.features[1], 0.9, 1e-9, "recorded the state the action was taken in")
assertNear(rec.nextFeatures[1], 0.4, 1e-9, "recorded the state it led to")
assertEq(rec.t, 1, "recorded the timestamp of the originating step")
assertTrue(rec.actionIndex ~= nil, "recorded action resolved to a contract index")
assertEq(exported.contract.actions[rec.actionIndex], rec.action, "actionIndex round-trips through the contract")

-- Missing reward defaults to 0 rather than nil (trainers can't learn from nil).
fakeTime = 3
pipeline:step({ threat = 10, health = 100 })
local rec2 = pipeline:exportExperience().records[2]
assertEq(rec2.reward, 0, "absent reward recorded as 0")

-- Experience is bounded and clearable.
for i = 1, 20 do
	fakeTime = fakeTime + 1
	pipeline:step({ threat = i, health = 100 }, 0.1)
end
assertEq(#pipeline:exportExperience().records, 8, "experience buffer respects its capacity")
local chronoRecords = pipeline:exportExperience().records
assertTrue(chronoRecords[1].step < chronoRecords[8].step, "exported experience is chronological")
pipeline:clearExperience()
assertEq(#pipeline:exportExperience().records, 0, "clearExperience empties the buffer")

-- Training contract
local contract = pipeline:trainingContract()
assertEq(contract.features[1].name, "threat", "contract lists features in spec order")
assertEq(contract.features[1].max, 100, "contract carries the raw range for each feature")
assertEq(#contract.features, 2, "contract covers every feature")
assertEq(contract.actionIndex[contract.actions[1]], 1, "contract action indices are consistent")
assertEq(contract.policy, nil, "no policy attached -> no policy shape in contract")
assertEq(contract.version, Cell4.VERSION, "contract is version-stamped")

local contractWithPolicy = Cell4.Pipeline.new({
	perceptionSpec = spec,
	reasoning = withPolicy,
	clock = fakeClock,
}):trainingContract()
assertEq(contractWithPolicy.policy.layerSizes[1], 2, "contract reports the policy input width")
assertEq(contractWithPolicy.policy.layerSizes[2], 2, "contract reports the policy output width")

-- Abstention: a tied decision below the confidence floor falls back.
local abstaining = Cell4.Pipeline.new({
	perceptionSpec = spec,
	reasoning = tied, -- both goals return 0.5 -> confidence 0
	clock = fakeClock,
	minConfidence = 0.25,
	fallbackAction = "hold",
})
local abstained = abstaining:step({ threat = 50, health = 50 })
assertEq(abstained.decision, "hold", "low confidence falls back instead of guessing")
assertEq(abstained.abstained, true, "abstention is flagged")
assertTrue(abstained.abstainReason:find("below floor"), "abstention explains itself")
fakeTime = fakeTime + 1
abstaining:step({ threat = 50, health = 50 }, 0)
local abstainedRec = abstaining:exportExperience().records[1]
assertEq(abstainedRec.action, "hold", "the fallback action is what gets recorded as taken")
assertEq(abstainedRec.abstained, true, "experience records that this step was an abstention")

-- A confident decision passes the same floor untouched.
local confidentPipeline = Cell4.Pipeline.new({
	perceptionSpec = spec,
	reasoning = clearCut,
	clock = fakeClock,
	minConfidence = 0.25,
	fallbackAction = "hold",
})
local confidentResult = confidentPipeline:step({ threat = 50, health = 50 })
assertEq(confidentResult.decision, "win", "confident decision is not overridden by the floor")
assertEq(confidentResult.abstained, false, "confident decision is not flagged as abstaining")

-- With no fallback configured, abstaining yields no action and records nothing.
local noFallback = Cell4.Pipeline.new({
	perceptionSpec = spec,
	reasoning = tied,
	clock = fakeClock,
	minConfidence = 0.5,
})
local noAction = noFallback:step({ threat = 50, health = 50 })
assertEq(noAction.decision, nil, "abstaining with no fallback yields no action")
fakeTime = fakeTime + 1
noFallback:step({ threat = 50, health = 50 }, 1)
assertEq(#noFallback:exportExperience().records, 0, "a step with no action records no transition")

-- =====================================================================
-- Temporal smoothing: reasoning must run on a smoothed view, not one
-- noisy frame, while memory keeps the raw observations.
-- =====================================================================
local smoothingPipeline = Cell4.Pipeline.new({
	perceptionSpec = spec,
	reasoning = reasoning, -- flee scales with threat, explore inversely
	clock = fakeClock,
	smoothing = { threat = 3 },
})
fakeTime = fakeTime + 1
local s1 = smoothingPipeline:step({ threat = 0, health = 100 })
assertNear(s1.state.named.threat, 0, 1e-9, "first tick has only itself to average")
fakeTime = fakeTime + 1
local s2 = smoothingPipeline:step({ threat = 60, health = 100 })
assertNear(s2.state.named.threat, 0.3, 1e-9, "two observations average to 0.3")
assertNear(s2.observed.named.threat, 0.6, 1e-9, "the raw observation is preserved alongside")
fakeTime = fakeTime + 1
-- A single extreme spike must not drag the smoothed view all the way up.
local s3 = smoothingPipeline:step({ threat = 100, health = 100 })
assertNear(s3.observed.named.threat, 1, 1e-9, "spike is observed at full value")
assertNear(s3.state.named.threat, (0 + 0.6 + 1) / 3, 1e-9, "spike is damped by the 3-tick window")
assertTrue(s3.state.named.threat < s3.observed.named.threat, "smoothing damps the spike")
assertEq(s3.state.predicted, false, "a smoothed observation is not flagged predicted")
-- Unsmoothed features pass through untouched.
assertNear(s3.state.named.health, 1, 1e-9, "features without a smoothing window are unchanged")

-- Training transitions must be internally consistent: `features` and
-- `nextFeatures` have to be the same representation reasoning ran on
-- (smoothed), or every transition teaches the model a contradiction.
local smoothedRecords = smoothingPipeline:exportExperience().records
assertNear(smoothedRecords[1].features[1], 0, 1e-9, "s recorded from the smoothed view")
assertNear(smoothedRecords[1].nextFeatures[1], 0.3, 1e-9, "s' recorded from the smoothed view too")
assertNear(smoothedRecords[2].features[1], smoothedRecords[1].nextFeatures[1], 1e-9,
	"one step's s' is exactly the next step's s")

-- =====================================================================
-- Hysteresis: don't stutter between two near-equal actions.
-- =====================================================================
local flipFlop = Cell4.Reasoning.new()
local leftScore, rightScore = 0.60, 0.55
flipFlop:registerRule("left", 1, function() return leftScore, "left rule" end)
flipFlop:registerRule("right", 1, function() return rightScore, "right rule" end)

local steady = Cell4.Pipeline.new({
	perceptionSpec = spec,
	reasoning = flipFlop,
	clock = fakeClock,
	switchMargin = 0.2,
})
fakeTime = fakeTime + 1
assertEq(steady:step({ threat = 50, health = 50 }).decision, "left", "first tick commits to the leader")
-- Right now narrowly leads, but not by the margin: the agent should hold.
leftScore, rightScore = 0.55, 0.60
fakeTime = fakeTime + 1
local heldResult = steady:step({ threat = 50, health = 50 })
assertEq(heldResult.decision, "left", "a narrow challenger does not steal the decision")
assertEq(heldResult.held, true, "the hold is flagged")
assertTrue(heldResult.heldReason:find("switch margin"), "the hold explains itself")
assertTrue(steady:explain(heldResult):find("HELD by hysteresis"), "explain() surfaces the hold")
-- A decisive challenger does get through.
leftScore, rightScore = 0.1, 0.9
fakeTime = fakeTime + 1
local switched = steady:step({ threat = 50, health = 50 })
assertEq(switched.decision, "right", "a decisively better challenger wins")
assertEq(switched.held, false, "a real switch is not flagged as held")

-- Hysteresis must never resurrect an action that is no longer a candidate.
local vanishing = Cell4.Reasoning.new()
local offerLeft = true
vanishing:registerRule("left", 1, function()
	if not offerLeft then return 0, "withdrawn" end
	return 0.9, "left rule"
end)
vanishing:registerRule("right", 1, function() return 0.5, "right rule" end)
local vanishPipeline = Cell4.Pipeline.new({
	perceptionSpec = spec, reasoning = vanishing, clock = fakeClock, switchMargin = 0.9,
})
fakeTime = fakeTime + 1
assertEq(vanishPipeline:step({ threat = 50, health = 50 }).decision, "left", "commits to left")
offerLeft = false
fakeTime = fakeTime + 1
local moved = vanishPipeline:step({ threat = 50, health = 50 })
assertEq(moved.decision, "right", "a zero-scoring incumbent is not clung to")
assertEq(moved.held, false, "no hold when the incumbent scores zero")

-- With nothing worth doing, hysteresis must not hold, so the confidence
-- floor can still fire.
local deadEnd = Cell4.Reasoning.new()
deadEnd:registerRule("left", 1, function() return 0, "nothing to do" end)
local deadEndPipeline = Cell4.Pipeline.new({
	perceptionSpec = spec, reasoning = deadEnd, clock = fakeClock,
	switchMargin = 0.5, minConfidence = 0.5, fallbackAction = "idle",
})
fakeTime = fakeTime + 1
local dead = deadEndPipeline:step({ threat = 50, health = 50 })
assertEq(dead.decision, "idle", "all-zero scores still abstain to the fallback")
assertEq(dead.held, false, "hysteresis does not hold when nothing scores")

assertTrue(not pcall(function() Cell4.Pipeline.new({ perceptionSpec = spec }) end), "pipeline requires reasoning")
assertTrue(not pcall(function() Cell4.Pipeline.new({ reasoning = combined }) end), "pipeline requires a perception spec")

-- explain() renders something a human can actually read in a log.
local explanation = pipeline:explain(r1)
assertTrue(explanation:find("decision: retreat"), "explain() names the decision")
assertTrue(explanation:find("confidence"), "explain() reports confidence")
assertTrue(explanation:find("plan:"), "explain() shows the plan")
assertTrue(explanation:find("1%."), "explain() ranks the alternatives")
assertTrue(explanation:find("ABSTAINED") == nil, "explain() only flags abstention when it happened")
assertTrue(abstaining:explain(abstained):find("ABSTAINED"), "explain() flags abstention when it did happen")

-- =====================================================================
-- PolicyFormat: the trainer <-> runtime interchange.
-- =====================================================================
local PF = Cell4.PolicyFormat
local sampleBundle = {
	features = { "threat", "health" },
	actions = { "explore", "flee" },
	activation = "tanh",
	outputActivation = "linear",
	layers = {
		{ weights = { {0.5, -0.25}, {1e-8, 123456.75}, {0, 1} }, biases = {0.1, -0.2, 0.3} },
		{ weights = { {1, 2, 3}, {-1, -2, -3} }, biases = {0, 0.5} },
	},
}
local encoded = PF.encode(sampleBundle)
local decoded, decodeErr = PF.decode(encoded)
assertTrue(decoded ~= nil, "round-trip decodes: " .. tostring(decodeErr))
assertEq(table.concat(decoded.features, ","), "threat,health", "features round-trip")
assertEq(table.concat(decoded.actions, ","), "explore,flee", "actions round-trip")
assertEq(decoded.activation, "tanh", "activation round-trips")
assertEq(decoded.outputActivation, "linear", "output activation round-trips")
assertEq(#decoded.layers, 2, "layer count round-trips")
assertEq(table.concat(decoded.layerSizes, ","), "2,3,2", "layer shape is derived from the weights")
-- Exact float round-trip matters: quantization here is silent model drift.
assertEq(decoded.layers[1].weights[2][2], 123456.75, "large values round-trip exactly")
assertEq(decoded.layers[1].weights[2][1], 1e-8, "small values round-trip exactly")
assertEq(decoded.layers[1].weights[1][2], -0.25, "negative values round-trip exactly")
assertEq(decoded.layers[2].biases[2], 0.5, "biases round-trip exactly")
assertEq(PF.encode(decoded), encoded, "re-encoding a decoded bundle is byte-identical")

-- Cross-language contract: this fixture is produced by the Python exporter
-- in tools/export_policy.py (and pinned byte-for-byte by
-- tests/test_export_policy.py). Parsing it here is what proves the trainer
-- side and the runtime side actually agree, rather than each being
-- self-consistently wrong.
local goldenFile = io.open(scriptDir .. "fixtures/golden_policy.cell4", "r")
assertTrue(goldenFile ~= nil, "the golden policy fixture exists")
local goldenText = goldenFile:read("*a")
goldenFile:close()
local golden, goldenErr = PF.decode(goldenText)
assertTrue(golden ~= nil, "the exporter's output parses here: " .. tostring(goldenErr))
assertEq(table.concat(golden.features, ","), "threat,health", "golden features match")
assertEq(table.concat(golden.actions, ","), "explore,flee", "golden actions match")
assertEq(table.concat(golden.layerSizes, ","), "2,3,2", "golden shape matches")
assertEq(golden.activation, "tanh", "golden activation matches")
-- The values Python wrote must arrive here as the identical doubles.
assertEq(golden.layers[1].weights[2][1], 1e-08, "tiny value survives the language boundary")
assertEq(golden.layers[1].weights[2][2], 123456.75, "large value survives the language boundary")
assertEq(golden.layers[1].weights[1][2], -0.25, "negative value survives the language boundary")
assertEq(golden.layers[2].biases[2], 0.5, "bias survives the language boundary")
-- And it must actually run as a network.
local goldenNet = Cell4.NeuralNet.new(golden.layerSizes, golden.activation, golden.outputActivation)
goldenNet:loadWeights({ layers = golden.layers })
local goldenOut = goldenNet:forward({0.5, 0.5})
assertEq(#goldenOut, 2, "the imported policy produces one output per action")
assertTrue(goldenOut[1] == goldenOut[1], "the imported policy produces real numbers")

-- Comments and blank lines are ignored.
local withComments = PF.decode("# a trained policy\ncell4-policy 1\n\nfeatures a\nactions x\n"
	.. "activation relu linear\nlayer 1 1\nw 1  # the only weight\nb 0\n")
assertTrue(withComments ~= nil, "comments and blank lines are ignored")

-- Malformed input must be reported, never raised, and never executed.
local badCases = {
	{ "", "empty file" },
	{ "features a\nactions x\n", "missing version header" },
	{ "cell4-policy 99\n", "unsupported version" },
	{ "cell4-policy 1\nfeatures a\nactions x\n", "no layers" },
	{ "cell4-policy 1\nfeatures a\nactions x\nlayer 1 1\nw 1\n", "missing bias line" },
	{ "cell4-policy 1\nfeatures a\nactions x\nlayer 1 2\nw 1\nb 0 0\n", "too few w lines" },
	{ "cell4-policy 1\nfeatures a\nactions x\nlayer 2 1\nw 1\nb 0\n", "w line too short" },
	{ "cell4-policy 1\nfeatures a\nactions x\nlayer 1 1\nw 1 2\nb 0\n", "w line too long" },
	{ "cell4-policy 1\nfeatures a\nactions x\nlayer 1 1\nw notanumber\nb 0\n", "non-numeric weight" },
	{ "cell4-policy 1\nfeatures a\nactions x\nw 1\n", "w outside a layer" },
	{ "cell4-policy 1\nfeatures a\nactions x\nlayer 1 1\nw 1\nb 0\nb 0\n", "duplicate bias line" },
	{ "cell4-policy 1\nfeatures a\nactions x\nlayer 1 1\nsabotage()\n", "unknown keyword" },
	{ "cell4-policy 1\nfeatures a\nactions x\nlayer 1 2\nw 1\nw 1\nb 0 0\nlayer 1 1\nw 1\nb 0\n",
		"layer shapes that do not chain" },
}
for _, case in ipairs(badCases) do
	local result, err = PF.decode(case[1])
	assertEq(result, nil, "rejects " .. case[2])
	assertTrue(type(err) == "string" and #err > 0, "explains rejection of " .. case[2])
end
assertEq(PF.decode(42), nil, "non-string input is rejected")

-- =====================================================================
-- Contract-validated policy loading
-- =====================================================================
local loaderReasoning = Cell4.Reasoning.new()
loaderReasoning:registerRule("explore", 1, function() return 0.3, "baseline" end)
loaderReasoning:registerRule("flee", 1, function() return 0.3, "baseline" end)
local loaderPipeline = Cell4.Pipeline.new({
	perceptionSpec = spec, reasoning = loaderReasoning, clock = fakeClock,
})

-- The template tells the trainer exactly what to produce.
local template = loaderPipeline:policyTemplate({ 8 })
assertEq(table.concat(template.features, ","), "threat,health", "template lists features in order")
assertEq(table.concat(template.actions, ","), "explore,flee", "template lists actions in index order")
assertEq(table.concat(template.layerSizes, ","), "2,8,2", "template pins input and output widths")

local goodPolicy = PF.encode({
	features = { "threat", "health" },
	actions = { "explore", "flee" },
	activation = "relu",
	outputActivation = "linear",
	layers = { { weights = { {0, 0}, {5, 0} }, biases = {0, 0} } },
})
local okLoad, loadErr = loaderPipeline:loadPolicy(goodPolicy)
assertEq(okLoad, true, "a matching policy loads: " .. tostring(loadErr))
fakeTime = fakeTime + 1
local policyDriven = loaderPipeline:step({ threat = 80, health = 50 })
assertEq(policyDriven.decision, "flee", "the loaded policy actually influences decisions")

-- Every mismatch that would silently produce a confidently-wrong agent.
local rejections = {
	{
		why = "feature order drift",
		text = PF.encode({
			features = { "health", "threat" }, -- swapped
			actions = { "explore", "flee" },
			layers = { { weights = { {0, 0}, {0, 0} }, biases = {0, 0} } },
		}),
		expect = "feature mismatch",
	},
	{
		why = "a feature the runtime no longer perceives",
		text = PF.encode({
			features = { "threat", "health", "ammo" },
			actions = { "explore", "flee" },
			layers = { { weights = { {0, 0, 0}, {0, 0, 0} }, biases = {0, 0} } },
		}),
		expect = "feature mismatch",
	},
	{
		why = "an action the runtime cannot take",
		text = PF.encode({
			features = { "threat", "health" },
			actions = { "explore", "teleport" },
			layers = { { weights = { {0, 0}, {0, 0} }, biases = {0, 0} } },
		}),
		expect = "action mismatch",
	},
	{
		why = "a policy missing an action the agent has",
		text = PF.encode({
			features = { "threat", "health" },
			actions = { "explore" },
			layers = { { weights = { {0, 0} }, biases = {0} } },
		}),
		expect = "action mismatch",
	},
}
for _, case in ipairs(rejections) do
	local accepted, reason = loaderPipeline:loadPolicy(case.text)
	assertEq(accepted, false, "rejects " .. case.why)
	assertTrue(reason:find(case.expect), "rejection of " .. case.why .. " names the cause: " .. tostring(reason))
end

local garbageOk, garbageReason = loaderPipeline:loadPolicy("not a policy at all")
assertEq(garbageOk, false, "rejects unparseable input")
assertTrue(garbageReason:find("could not parse"), "unparseable input is reported as a parse failure")
assertEq((loaderPipeline:loadPolicy(42)), false, "rejects a non-string, non-bundle argument")

-- A rejected load must leave the previously working policy untouched.
fakeTime = fakeTime + 1
assertEq(loaderPipeline:step({ threat = 80, health = 50 }).decision, "flee",
	"a rejected load does not disturb the policy already in use")

-- A decoded bundle can be passed directly, without re-serializing.
local bundleOk = loaderPipeline:loadPolicy(PF.decode(goodPolicy))
assertEq(bundleOk, true, "an already-decoded bundle loads directly")

-- =====================================================================
-- Episode boundaries: a transition must never bridge two lives.
-- =====================================================================
local episodic = Cell4.Pipeline.new({
	perceptionSpec = spec,
	reasoning = reasoning, -- flee scales with threat, explore inversely
	clock = fakeClock,
	smoothing = { threat = 3 },
	switchMargin = 0.5,
})
fakeTime = fakeTime + 1
episodic:step({ threat = 90, health = 100 })
fakeTime = fakeTime + 1
episodic:step({ threat = 95, health = 100 }, 1)
assertEq(#episodic:exportExperience().records, 1, "normal step closes the previous transition")

-- The agent dies here.
assertEq(episodic:endEpisode(-10), true, "endEpisode closes the outstanding transition")
local afterDeath = episodic:exportExperience().records
assertEq(#afterDeath, 2, "the final transition of the episode is recorded")
local terminal = afterDeath[2]
assertEq(terminal.done, true, "the final transition is marked terminal")
assertEq(terminal.nextFeatures, nil, "a terminal transition has no next state to bootstrap from")
assertEq(terminal.reward, -10, "the terminal reward is recorded")
assertEq(afterDeath[1].done, false, "mid-episode transitions are not marked terminal")
assertEq(afterDeath[1].episode, 1, "transitions carry their episode id")

-- New life: nothing from the old one may leak in.
fakeTime = fakeTime + 1
local reborn = episodic:step({ threat = 0, health = 100 })
assertEq(reborn.decision, "explore", "the new life decides on its own state, not the old commitment")
assertEq(reborn.held, false, "hysteresis does not hold an action across a death")
assertNear(reborn.state.named.threat, 0, 1e-9,
	"smoothing does not average the previous life's telemetry into the new one")

fakeTime = fakeTime + 1
episodic:step({ threat = 0, health = 100 }, 1)
local records = episodic:exportExperience().records
assertEq(#records, 3, "the new episode records its own transitions")
assertEq(records[3].episode, 2, "new transitions carry the new episode id")
-- The crucial guarantee: no record bridges the boundary.
for i = 2, #records do
	if records[i].episode ~= records[i - 1].episode then
		assertEq(records[i - 1].done, true, "the last record of an episode is always terminal")
	end
end

-- endEpisode with nothing outstanding is a safe no-op that still resets.
local idleEpisodic = Cell4.Pipeline.new({
	perceptionSpec = spec, reasoning = reasoning, clock = fakeClock,
})
assertEq(idleEpisodic:endEpisode(0), false, "endEpisode with no pending transition records nothing")
assertEq(#idleEpisodic:exportExperience().records, 0, "no phantom terminal record is invented")
assertEq(idleEpisodic.episode, 2, "the episode counter still advances")

-- Beliefs written by rules survive a boundary; the committed action does not.
local survivor = Cell4.Pipeline.new({
	perceptionSpec = spec, reasoning = reasoning, clock = fakeClock,
})
survivor.memory:remember("learned:enemyIsFast", true, 1)
fakeTime = fakeTime + 1
survivor:step({ threat = 90, health = 100 })
survivor:endEpisode(0)
assertEq((survivor.memory:recall("learned:enemyIsFast", math.huge)), true,
	"knowledge learned in one episode carries forward")
assertEq((survivor.memory:recall("cell4:lastAction", math.huge)), nil,
	"the committed action does not carry forward")
assertEq(#survivor.memory:recentContext(10), 0, "observations are cleared at the boundary")

-- =====================================================================
-- Integration soak: every feature enabled at once, driven over many ticks
-- with varying signals. Unit tests cover each part in isolation; this is
-- where interaction bugs between them would show up.
-- =====================================================================
local soakReasoning = Cell4.Reasoning.new()
soakReasoning:registerGoal("safety", 2, function(s) return 1 - s.named.threat end)
soakReasoning:registerGoal("vitality", 1, function(s) return s.named.health end)
soakReasoning:registerRule("flee", 1, function(s)
	return s.named.threat, ("threat %.2f"):format(s.named.threat)
end)
soakReasoning:registerRule("heal", 1, function(s)
	return 1 - s.named.health, ("health %.2f"):format(s.named.health)
end)
soakReasoning:registerRule("patrol", 0.5, function(s)
	return 0.4, "default activity"
end)

-- The soak spec carries a derived trend, so the whole stack (smoothing,
-- planning, policy, experience export) runs with derived features present.
local soakSpec = {
	{ key = "threat", min = 0, max = 100 },
	{ key = "health", min = 0, max = 100 },
	{ key = "threatTrend", derive = Cell4.Perception.delta("threat", 4) },
}
soakReasoning:registerRule("brace", 1, function(s)
	return s.named.threatTrend * 0.6, ("trend %.2f"):format(s.named.threatTrend)
end)

local soakPlanner = Cell4.Planner.new({ spec = soakSpec, maxDepth = 3, beamWidth = 4 })
soakPlanner:registerAction({
	name = "flee",
	preconditions = function(s) return s.named.threat > 0.1 end,
	effects = function(s, h) return h.withDelta({ threat = -0.35 }) end,
})
soakPlanner:registerAction({
	name = "heal",
	preconditions = function(s) return s.named.health < 0.95 end,
	effects = function(s, h) return h.withDelta({ health = 0.3 }) end,
	cost = 2,
})
soakPlanner:registerAction({
	name = "patrol",
	effects = function(s, h) return h.withDelta({ threat = 0.05 }) end,
})
soakReasoning:attachPlanner(soakPlanner, 1)

-- 3 features in, 4 actions out (brace joined the repertoire).
local soakPolicy = Cell4.NeuralNet.new({3, 4}, "tanh", "linear")
soakPolicy:loadWeights({
	layers = { { weights = {
		{0.4, -0.2, 0.1}, {-0.3, 0.6, 0.0}, {0.1, 0.1, 0.2}, {0.0, 0.1, 0.5},
	}, biases = {0, 0, 0, 0} } },
})
soakReasoning:attachPolicy(soakPolicy, { "brace", "flee", "heal", "patrol" }, 0.5)

local soak = Cell4.Pipeline.new({
	perceptionSpec = soakSpec,
	reasoning = soakReasoning,
	clock = fakeClock,
	smoothing = { threat = 3, health = 2 },
	switchMargin = 0.05,
	minConfidence = 0.02,
	fallbackAction = "patrol",
	experienceCapacity = 64,
	memoryCapacity = 16,
})

local seen = {}
local switches, holds, abstentions = 0, 0, 0
local previousDecision = nil
for tick = 1, 200 do
	fakeTime = fakeTime + 1
	-- Deterministic but non-trivial signal shape, with an occasional spike.
	local threat = 50 + 45 * math.sin(tick / 7)
	local health = 60 + 35 * math.cos(tick / 11)
	if tick % 23 == 0 then threat = 100 end

	local result = soak:step({ threat = threat, health = health }, (tick % 5) * 0.1)

	assertTrue(result.decision ~= nil, "soak tick " .. tick .. " produced a decision")
	assertTrue(result.confidence >= 0 and result.confidence <= 1,
		"soak tick " .. tick .. " confidence stays in [0,1]")
	assertTrue(result.state.named.threat >= 0 and result.state.named.threat <= 1,
		"soak tick " .. tick .. " features stay normalized")
	assertTrue(type(soak:explain(result)) == "string", "soak tick " .. tick .. " stays explainable")

	seen[result.decision] = true
	if result.held then holds = holds + 1 end
	if result.abstained then abstentions = abstentions + 1 end
	if previousDecision and previousDecision ~= result.decision then switches = switches + 1 end
	previousDecision = result.decision

	-- The agent "dies" periodically; the run must survive it and the
	-- recorded experience must stay well-formed across the boundary.
	if tick % 37 == 0 then
		soak:endEpisode(-1)
		previousDecision = nil
	end
end
assertTrue(soak.episode > 1, "soak ran across multiple episodes")

-- The agent should actually use its repertoire rather than collapsing onto
-- one action, and should not stutter on every single tick either.
assertTrue(seen["flee"], "soak agent flees at some point")
assertTrue(seen["heal"], "soak agent heals at some point")
assertTrue(switches > 0, "soak agent does change its mind as the world changes")
assertTrue(switches < 100, "soak agent is not thrashing every other tick")

local soakExport = soak:exportExperience()
assertEq(#soakExport.records, 64, "soak fills the experience buffer to capacity")
for i, record in ipairs(soakExport.records) do
	assertTrue(record.actionIndex ~= nil, "soak record " .. i .. " has a contract action index")
	assertEq(#record.features, 3, "soak record " .. i .. " has a full feature vector")
	assertTrue(type(record.reward) == "number", "soak record " .. i .. " has a numeric reward")
	-- Terminal and non-terminal records must be internally consistent: a
	-- terminal record has no next state, a non-terminal one always does.
	if record.done then
		assertEq(record.nextFeatures, nil, "soak terminal record " .. i .. " has no next state")
	else
		assertEq(#record.nextFeatures, 3, "soak record " .. i .. " has a full next-state vector")
	end
	if i > 1 then
		local previous = soakExport.records[i - 1]
		assertEq(record.step, previous.step + 1, "soak records are contiguous")
		if record.episode ~= previous.episode then
			assertEq(previous.done, true, "soak: an episode never ends without a terminal record")
		else
			assertEq(previous.done, false, "soak: a terminal record never sits mid-episode")
		end
	end
end
assertEq(#soakExport.contract.actions, 4, "soak contract lists exactly the real actions")
assertEq(soakExport.contract.policy.layerSizes[2], 4, "soak contract matches the attached policy")
assertEq(soakExport.contract.features[3].derived, true, "soak contract flags the derived feature")

print(("ALL SMOKE TESTS PASSED (%d checks)"):format(checks))
