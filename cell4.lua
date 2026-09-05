--[[
	cell4.lua - AI reasoning core (architecture skeleton)

	Scope: this file is inference + reasoning ONLY. It never trains anything.
	Any neural weights it uses are produced by an external trainer (run on
	separate servers) and handed to NeuralNet:loadWeights() as plain tables.

	Design goals for this pass:
	  1. Every decision is explainable - Reasoning:decide() returns not just
	     a choice but the scored alternatives and why each score came out
	     that way. A black box that "just picks something" is exactly the
	     failure mode we're trying to avoid.
	  2. Reasoning must degrade gracefully with no trained model loaded.
	     Pure rule/utility scoring works standalone; a policy network, once
	     loaded, only nudges the utility scores rather than replacing them.
	  3. Lua 5.1 / Luau compatible (no 5.2+ goto, no 5.3 bitwise/integer
	     division, no string.pack). Written and executed for now against a
	     stock lua5.3 interpreter, since that's what's available to actually
	     run against; nothing below relies on 5.3-only syntax.

	See CELL4_AI_ARCHITECTURE.md for the running design log and the plan
	for what gets built on subsequent nights.
]]

local Cell4 = {}
Cell4.VERSION = "0.1.0-arch"

-- =========================================================================
-- Utils: small numeric helpers shared by every other module.
-- =========================================================================
local Utils = {}

function Utils.clamp(x, lo, hi)
	if x < lo then return lo end
	if x > hi then return hi end
	return x
end

function Utils.lerp(a, b, t)
	return a + (b - a) * t
end

function Utils.sigmoid(x)
	return 1 / (1 + math.exp(-x))
end

function Utils.relu(x)
	if x > 0 then return x end
	return 0
end

function Utils.tanh(x)
	-- math.tanh was removed in some Lua builds; define it directly so we
	-- don't depend on which stdlib we're linked against.
	local e2x = math.exp(2 * x)
	return (e2x - 1) / (e2x + 1)
end

function Utils.dot(a, b)
	local sum = 0
	for i = 1, #a do
		sum = sum + a[i] * b[i]
	end
	return sum
end

function Utils.softmax(values)
	local maxV = -math.huge
	for i = 1, #values do
		if values[i] > maxV then maxV = values[i] end
	end
	local sumExp = 0
	local exps = {}
	for i = 1, #values do
		local e = math.exp(values[i] - maxV) -- subtract max for numerical stability
		exps[i] = e
		sumExp = sumExp + e
	end
	local out = {}
	for i = 1, #exps do
		out[i] = exps[i] / sumExp
	end
	return out
end

Cell4.Utils = Utils

-- =========================================================================
-- Memory: short-term working memory (decaying ring buffer of observations)
-- plus a long-term key/value belief store with confidence and staleness.
--
-- This exists so Reasoning never has to act on a single instantaneous
-- frame of perception - it can ask "what has been true recently" and
-- "what do we believe and how sure are we," which is what keeps decisions
-- from flip-flopping on one noisy signal.
-- =========================================================================
local Memory = {}
Memory.__index = Memory

function Memory.new(capacity)
	local self = setmetatable({}, Memory)
	self.capacity = capacity or 32
	self.observations = {} -- ring buffer of {t=, data=}
	self.head = 0
	self.count = 0
	self.beliefs = {} -- key -> {value=, confidence=, updatedAt=}
	return self
end

function Memory:pushObservation(data, t)
	self.head = (self.head % self.capacity) + 1
	self.observations[self.head] = { t = t, data = data }
	if self.count < self.capacity then
		self.count = self.count + 1
	end
end

-- Returns up to n most recent observations, newest first.
function Memory:recentContext(n)
	n = math.min(n or self.count, self.count)
	local out = {}
	local idx = self.head
	for i = 1, n do
		out[i] = self.observations[idx]
		idx = idx - 1
		if idx < 1 then idx = self.capacity end
	end
	return out
end

function Memory:remember(key, value, confidence)
	self.beliefs[key] = {
		value = value,
		confidence = Utils.clamp(confidence or 1, 0, 1),
		updatedAt = os.clock(),
	}
end

-- Confidence decays over time so stale beliefs stop dominating decisions
-- without being forgotten outright. halfLife is in seconds.
function Memory:recall(key, halfLife)
	local belief = self.beliefs[key]
	if not belief then return nil, 0 end
	halfLife = halfLife or 30
	local age = os.clock() - belief.updatedAt
	local decayed = belief.confidence * (0.5 ^ (age / halfLife))
	return belief.value, decayed
end

Cell4.Memory = Memory

-- =========================================================================
-- NeuralNet: feedforward inference only. Layer shapes are declared here;
-- weights arrive later (from disk, network, or the external trainer's
-- export format) via loadWeights. Forward pass runs with zeroed weights
-- until then, which makes it inert rather than crashing, so a reasoning
-- pipeline can be wired up and tested before a trained model exists.
-- =========================================================================
local NeuralNet = {}
NeuralNet.__index = NeuralNet

local ACTIVATIONS = {
	relu = Utils.relu,
	sigmoid = Utils.sigmoid,
	tanh = Utils.tanh,
	linear = function(x) return x end,
}

-- layerSizes: e.g. {8, 16, 16, 4} = 8 inputs, two hidden layers of 16, 4 outputs.
-- activation: name applied to every layer except the last, which uses outputActivation.
function NeuralNet.new(layerSizes, activation, outputActivation)
	assert(#layerSizes >= 2, "NeuralNet needs at least an input and output layer")
	local self = setmetatable({}, NeuralNet)
	self.layerSizes = layerSizes
	self.activation = activation or "relu"
	self.outputActivation = outputActivation or "linear"
	self.loaded = false
	self.layers = {} -- [i] = { weights = [outSize][inSize], biases = [outSize] }

	for i = 1, #layerSizes - 1 do
		local inSize, outSize = layerSizes[i], layerSizes[i + 1]
		local weights = {}
		for o = 1, outSize do
			weights[o] = {}
			for j = 1, inSize do
				weights[o][j] = 0
			end
		end
		local biases = {}
		for o = 1, outSize do
			biases[o] = 0
		end
		self.layers[i] = { weights = weights, biases = biases }
	end

	return self
end

-- serialized shape: { layers = { {weights = {...}, biases = {...}}, ... } }
-- Dimensions must match what NeuralNet.new declared; we check rather than
-- silently truncating/padding, since a shape mismatch means the wrong
-- model was handed to the wrong pipeline.
function NeuralNet:loadWeights(serialized)
	assert(serialized and serialized.layers, "loadWeights expects {layers = {...}}")
	assert(#serialized.layers == #self.layers, "layer count mismatch")

	for i = 1, #self.layers do
		local dst = self.layers[i]
		local src = serialized.layers[i]
		assert(#src.weights == #dst.weights, "output size mismatch at layer " .. i)
		for o = 1, #dst.weights do
			assert(#src.weights[o] == #dst.weights[o], "input size mismatch at layer " .. i)
			for j = 1, #dst.weights[o] do
				dst.weights[o][j] = src.weights[o][j]
			end
			dst.biases[o] = src.biases[o]
		end
	end
	self.loaded = true
end

function NeuralNet:isLoaded()
	return self.loaded
end

function NeuralNet:forward(input)
	assert(#input == self.layerSizes[1], "input size mismatch")
	local activationFn = ACTIVATIONS[self.activation]
	local outputFn = ACTIVATIONS[self.outputActivation]

	local current = input
	for i, layer in ipairs(self.layers) do
		local isLast = (i == #self.layers)
		local fn = isLast and outputFn or activationFn
		local next = {}
		for o = 1, #layer.weights do
			local sum = Utils.dot(layer.weights[o], current) + layer.biases[o]
			next[o] = fn(sum)
		end
		current = next
	end
	return current
end

Cell4.NeuralNet = NeuralNet

-- =========================================================================
-- Reasoning: goal-based utility reasoning. Each registered goal scores the
-- current state/memory in [0,1] with a human-readable rationale. A loaded
-- policy network (if any) contributes one more scored "goal" per output,
-- so it competes on equal footing with hand-authored rules rather than
-- overriding them - this is the "don't hallucinate" guardrail: a trained
-- model can suggest, but a documented rule can always outweigh it.
-- =========================================================================
local Reasoning = {}
Reasoning.__index = Reasoning

function Reasoning.new(policyNet)
	local self = setmetatable({}, Reasoning)
	self.goals = {} -- list of {name, weight, evaluate}
	self.policyNet = policyNet -- optional NeuralNet, output order must match policyActions
	self.policyActions = nil -- optional list of goal names matching policyNet's output vector
	return self
end

-- evaluate(state, memory) -> score in [0,1], rationale string
function Reasoning:registerGoal(name, weight, evaluate)
	table.insert(self.goals, { name = name, weight = weight or 1, evaluate = evaluate })
end

function Reasoning:attachPolicy(net, actionNames)
	self.policyNet = net
	self.policyActions = actionNames
end

function Reasoning:evaluate(state, memory)
	local scored = {}

	for _, goal in ipairs(self.goals) do
		local ok, score, why = pcall(goal.evaluate, state, memory)
		if ok then
			table.insert(scored, {
				name = goal.name,
				score = Utils.clamp(score, 0, 1) * goal.weight,
				why = why or "(no rationale given)",
				source = "rule",
			})
		else
			-- A goal that errors contributes nothing rather than crashing the
			-- whole decision cycle; the error is surfaced in the trace so it
			-- doesn't fail silently either.
			table.insert(scored, {
				name = goal.name,
				score = 0,
				why = "evaluate() failed: " .. tostring(score),
				source = "rule-error",
			})
		end
	end

	if self.policyNet and self.policyNet:isLoaded() and self.policyActions then
		local ok, outputs = pcall(function()
			return self.policyNet:forward(state.featureVector)
		end)
		if ok then
			local probs = Utils.softmax(outputs)
			for i, name in ipairs(self.policyActions) do
				table.insert(scored, {
					name = name,
					score = probs[i] or 0,
					why = string.format("policy net weight %.3f", probs[i] or 0),
					source = "policy",
				})
			end
		end
	end

	table.sort(scored, function(a, b) return a.score > b.score end)
	return scored
end

-- Combines duplicate-named entries (a rule and a policy vote for the same
-- action) by summing their scores, then returns the top choice plus the
-- full ranked trace for logging/debugging.
function Reasoning:decide(state, memory)
	local scored = self:evaluate(state, memory)
	local combined = {}
	local order = {}
	for _, entry in ipairs(scored) do
		local existing = combined[entry.name]
		if existing then
			existing.score = existing.score + entry.score
			table.insert(existing.reasons, entry.why)
		else
			combined[entry.name] = { name = entry.name, score = entry.score, reasons = { entry.why } }
			table.insert(order, entry.name)
		end
	end

	local trace = {}
	for _, name in ipairs(order) do
		table.insert(trace, combined[name])
	end
	table.sort(trace, function(a, b) return a.score > b.score end)

	if #trace == 0 then
		return nil, trace
	end
	return trace[1], trace
end

Cell4.Reasoning = Reasoning

-- =========================================================================
-- Perception: turns raw, unbounded game/world signals into a normalized
-- feature vector the neural net can consume, plus a plain named table the
-- rule-based goals can read without caring about vector ordering.
-- =========================================================================
local Perception = {}

-- spec: ordered list of {key, min, max} describing how to normalize each
-- named raw signal into [0,1] for featureVector, in a fixed order.
function Perception.normalize(rawSignals, spec)
	local named = {}
	local featureVector = {}
	for i, field in ipairs(spec) do
		local raw = rawSignals[field.key] or 0
		local norm = Utils.clamp((raw - field.min) / (field.max - field.min), 0, 1)
		named[field.key] = norm
		featureVector[i] = norm
	end
	return { named = named, featureVector = featureVector, raw = rawSignals }
end

Cell4.Perception = Perception

-- =========================================================================
-- Pipeline: wires perception -> memory -> reasoning into one step() call
-- and returns both the decision and a full trace, so callers (and the
-- humans reviewing logs) can see *why* every decision was made rather
-- than trusting an opaque output.
-- =========================================================================
local Pipeline = {}
Pipeline.__index = Pipeline

function Pipeline.new(config)
	local self = setmetatable({}, Pipeline)
	self.spec = config.perceptionSpec
	self.memory = config.memory or Memory.new(config.memoryCapacity)
	self.reasoning = config.reasoning
	self.now = config.clock or os.clock
	return self
end

function Pipeline:step(rawSignals)
	local state = Perception.normalize(rawSignals, self.spec)
	self.memory:pushObservation(state, self.now())

	local decision, trace = self.reasoning:decide(state, self.memory)

	return {
		decision = decision and decision.name or nil,
		score = decision and decision.score or 0,
		trace = trace,
		state = state,
	}
end

Cell4.Pipeline = Pipeline

return Cell4
