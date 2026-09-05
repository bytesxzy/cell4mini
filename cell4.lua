--[[
	cell4.lua - AI reasoning core (architecture skeleton)

	Scope: this file is inference + reasoning ONLY. It never trains anything.
	Any neural weights it uses are produced by an external trainer (run on
	separate servers) and handed to NeuralNet:loadWeights() as plain tables.
	What this file DOES do for training is emit the data to train on and
	declare the contract the trainer must satisfy (Pipeline:trainingContract).

	Design goals:
	  1. Every decision is explainable - Reasoning:decide() returns not just
	     a choice but the scored alternatives and why each score came out
	     that way. A black box that "just picks something" is exactly the
	     failure mode we're trying to avoid.
	  2. One decision path, no competing subsystems. Rules, the planner and
	     the policy network all cast *votes* into the same scoring pass, so
	     adding intelligence never creates a second way for the agent to
	     decide something behind the first one's back.
	  3. Reasoning degrades gracefully. Pure rule/utility scoring works
	     standalone; planner and policy net each improve it when present and
	     are inert (not fatal) when absent.
	  4. The agent knows when it doesn't know. Decisions carry a confidence
	     derived from the margin over the runner-up, and the pipeline can
	     abstain to a fallback rather than coin-flip between near-ties.
	  5. Lua 5.1 / Luau compatible (no 5.2+ goto, no 5.3 bitwise/integer
	     division, no string.pack). Executed against a stock lua5.3
	     interpreter; nothing below relies on 5.3-only syntax.

	See CELL4_AI_ARCHITECTURE.md for the running design log and the plan
	for what gets built on subsequent nights.
]]

local Cell4 = {}
Cell4.VERSION = "0.2.0-arch"

-- =========================================================================
-- Utils: small numeric helpers shared by every other module.
-- =========================================================================
local Utils = {}

function Utils.clamp(x, lo, hi)
	if x < lo then return lo end
	if x > hi then return hi end
	return x
end

function Utils.sigmoid(x)
	return 1 / (1 + math.exp(-x))
end

function Utils.relu(x)
	if x > 0 then return x end
	return 0
end

function Utils.tanh(x)
	-- math.tanh was removed in some Lua builds, so define it directly rather
	-- than depending on which stdlib we're linked against.
	--
	-- The naive (e^2x - 1)/(e^2x + 1) overflows to inf/inf = NaN once x is
	-- large (around x > 355 for doubles), instead of saturating to 1. A
	-- single NaN activation propagates through the whole forward pass and
	-- silently destroys every decision downstream. Branching on the sign
	-- keeps the exponent negative, so it underflows harmlessly to 0 and the
	-- result saturates correctly at the limits.
	if x >= 0 then
		local z = math.exp(-2 * x)
		return (1 - z) / (1 + z)
	end
	local z = math.exp(2 * x)
	return (z - 1) / (z + 1)
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

function Utils.copyArray(source)
	local out = {}
	for i = 1, #source do
		out[i] = source[i]
	end
	return out
end

-- Sorts scored entries highest-first, breaking ties on a stable string key.
-- Deterministic ordering matters here: these decisions become training data,
-- and identical inputs must produce identical labels across runs/machines.
function Utils.sortScored(entries, tieKey)
	table.sort(entries, function(a, b)
		if a.score == b.score then
			return tostring(a[tieKey]) < tostring(b[tieKey])
		end
		return a.score > b.score
	end)
	return entries
end

Cell4.Utils = Utils

-- =========================================================================
-- RingBuffer: fixed-capacity circular store. Used by Memory (recent
-- observations) and by Pipeline (recorded experience), so the wrap-around
-- indexing lives in exactly one tested place instead of two.
-- =========================================================================
local RingBuffer = {}
RingBuffer.__index = RingBuffer

function RingBuffer.new(capacity)
	local self = setmetatable({}, RingBuffer)
	self.capacity = capacity or 32
	self.items = {}
	self.head = 0 -- index of most recent item
	self.count = 0
	return self
end

function RingBuffer:push(item)
	self.head = (self.head % self.capacity) + 1
	self.items[self.head] = item
	if self.count < self.capacity then
		self.count = self.count + 1
	end
	return item
end

-- Newest first. Used where recency is what matters (memory recall).
function RingBuffer:recent(n)
	n = math.min(n or self.count, self.count)
	local out = {}
	local idx = self.head
	for i = 1, n do
		out[i] = self.items[idx]
		idx = idx - 1
		if idx < 1 then idx = self.capacity end
	end
	return out
end

-- Oldest first. Used where chronological order matters (experience export,
-- since transitions must be replayed in the order they happened).
function RingBuffer:toArray()
	local out = {}
	local idx = self.head - self.count + 1
	if idx < 1 then idx = idx + self.capacity end
	for i = 1, self.count do
		out[i] = self.items[idx]
		idx = (idx % self.capacity) + 1
	end
	return out
end

function RingBuffer:clear()
	self.items = {}
	self.head = 0
	self.count = 0
end

Cell4.RingBuffer = RingBuffer

-- =========================================================================
-- Memory: short-term working memory (recent observations) plus a long-term
-- belief store with confidence that decays on a half-life.
--
-- This exists so Reasoning never has to act on a single instantaneous
-- frame of perception - it can ask "what has been true recently" and
-- "what do we believe and how sure are we," which is what keeps decisions
-- from flip-flopping on one noisy signal.
-- =========================================================================
local Memory = {}
Memory.__index = Memory

-- clock is injectable so the whole system can share one time source (and so
-- tests can drive time deterministically instead of sleeping).
function Memory.new(capacity, clock)
	local self = setmetatable({}, Memory)
	self.buffer = RingBuffer.new(capacity or 32)
	self.beliefs = {} -- key -> {value=, confidence=, updatedAt=}
	self.clock = clock or os.clock
	return self
end

function Memory:pushObservation(data, t)
	self.buffer:push({ t = t or self.clock(), data = data })
end

-- Returns up to n most recent observations, newest first.
function Memory:recentContext(n)
	return self.buffer:recent(n)
end

function Memory:remember(key, value, confidence)
	self.beliefs[key] = {
		value = value,
		confidence = Utils.clamp(confidence or 1, 0, 1),
		updatedAt = self.clock(),
	}
end

-- Confidence decays over time so stale beliefs stop dominating decisions
-- without being forgotten outright. halfLife is in clock units.
function Memory:forget(key)
	self.beliefs[key] = nil
end

-- Drops recent observations while keeping beliefs. Used at an episode
-- boundary: telemetry from a previous life must not be averaged into the
-- new one, but learned beliefs may legitimately outlive a single episode.
function Memory:clearObservations()
	self.buffer:clear()
end

function Memory:recall(key, halfLife)
	local belief = self.beliefs[key]
	if not belief then return nil, 0 end
	halfLife = halfLife or 30
	local age = self.clock() - belief.updatedAt
	local decayed = belief.confidence * (0.5 ^ (age / halfLife))
	return belief.value, decayed
end

Cell4.Memory = Memory

-- =========================================================================
-- NeuralNet: feedforward inference only. Layer shapes are declared here;
-- weights arrive later (from the external trainer's export) via
-- loadWeights. Forward pass runs with zeroed weights until then, which
-- makes it inert rather than crashing, so a reasoning pipeline can be
-- wired up and tested before a trained model exists.
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
	activation = activation or "relu"
	outputActivation = outputActivation or "linear"
	assert(ACTIVATIONS[activation], "unknown activation: " .. tostring(activation))
	assert(ACTIVATIONS[outputActivation], "unknown output activation: " .. tostring(outputActivation))

	local self = setmetatable({}, NeuralNet)
	self.layerSizes = layerSizes
	self.activation = activation
	self.outputActivation = outputActivation
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

-- The exact shape the external trainer must produce. Exported as part of
-- Pipeline:trainingContract() so the training side never has to guess.
function NeuralNet:describe()
	local parameters = 0
	for _, layer in ipairs(self.layers) do
		for o = 1, #layer.weights do
			parameters = parameters + #layer.weights[o] + 1 -- +1 for the bias
		end
	end
	return {
		layerSizes = Utils.copyArray(self.layerSizes),
		activation = self.activation,
		outputActivation = self.outputActivation,
		parameters = parameters,
		loaded = self.loaded,
	}
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
		assert(#src.biases == #dst.biases, "bias size mismatch at layer " .. i)
		for o = 1, #dst.weights do
			assert(#src.weights[o] == #dst.weights[o], "input size mismatch at layer " .. i)
			for j = 1, #dst.weights[o] do
				local w = src.weights[o][j]
				assert(type(w) == "number" and w == w, "non-numeric weight at layer " .. i)
				dst.weights[o][j] = w
			end
			local b = src.biases[o]
			assert(type(b) == "number" and b == b, "non-numeric bias at layer " .. i)
			dst.biases[o] = b
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
		local nextValues = {}
		for o = 1, #layer.weights do
			nextValues[o] = fn(Utils.dot(layer.weights[o], current) + layer.biases[o])
		end
		current = nextValues
	end
	return current
end

Cell4.NeuralNet = NeuralNet

-- =========================================================================
-- PolicyFormat: the interchange between the external trainer and this
-- runtime. A plain line-based text format, parsed by hand.
--
-- Deliberately NOT a Lua chunk loaded with load()/loadstring: that would
-- execute whatever arrives, and Roblox disables loadstring by default
-- anyway. Deliberately not JSON either, so this file needs no JSON library
-- and no host-specific API. The parser only ever reads numbers and names.
--
-- The format carries the training contract alongside the weights, which is
-- the whole point: a model trained against a stale feature or action set
-- must be rejected at load time, not silently produce confident garbage.
--
--   cell4-policy 1
--   features threat health
--   actions flee heal patrol
--   activation relu linear
--   layer 2 4          # inputs outputs
--   w 0.1 -0.2         # one line per output neuron, `inputs` numbers each
--   w ...              # (4 w-lines for this layer)
--   b 0.0 0.0 0.0 0.0  # `outputs` numbers
--   layer 4 3
--   ...
--
-- Blank lines and `#` comments are ignored.
-- =========================================================================
local PolicyFormat = {}

PolicyFormat.VERSION = 1

local function formatNumber(x)
	-- %.17g round-trips an IEEE double exactly.
	return string.format("%.17g", x)
end

local function joinNumbers(values)
	local parts = {}
	for i = 1, #values do
		parts[i] = formatNumber(values[i])
	end
	return table.concat(parts, " ")
end

-- bundle: { features = {names}, actions = {names}, activation, outputActivation,
--           layers = { {weights = {{...}}, biases = {...}}, ... } }
function PolicyFormat.encode(bundle)
	assert(bundle.features, "bundle needs features")
	assert(bundle.actions, "bundle needs actions")
	assert(bundle.layers and #bundle.layers > 0, "bundle needs layers")

	local lines = {
		"cell4-policy " .. PolicyFormat.VERSION,
		"features " .. table.concat(bundle.features, " "),
		"actions " .. table.concat(bundle.actions, " "),
		"activation " .. (bundle.activation or "relu") .. " " .. (bundle.outputActivation or "linear"),
	}

	for _, layer in ipairs(bundle.layers) do
		local outSize = #layer.weights
		local inSize = #layer.weights[1]
		table.insert(lines, string.format("layer %d %d", inSize, outSize))
		for o = 1, outSize do
			table.insert(lines, "w " .. joinNumbers(layer.weights[o]))
		end
		table.insert(lines, "b " .. joinNumbers(layer.biases))
	end

	return table.concat(lines, "\n") .. "\n"
end

-- table.unpack is 5.2+; Lua 5.1 spells it `unpack`. Copy explicitly so the
-- parser stays portable across both.
local function sliceTokens(tokens, from)
	local out = {}
	for i = from, #tokens do
		out[#out + 1] = tokens[i]
	end
	return out
end

local function parseNumbers(tokens, from, count, context)
	local values = {}
	for i = 1, count do
		local token = tokens[from + i - 1]
		local n = tonumber(token)
		if n == nil or n ~= n then
			error(("%s: expected %d numbers, got %s at position %d"):format(
				context, count, tostring(token), i), 0)
		end
		values[i] = n
	end
	if tokens[from + count] ~= nil then
		error(("%s: expected %d numbers, found extra values"):format(context, count), 0)
	end
	return values
end

-- Returns the bundle, or (nil, errorMessage). Never raises on malformed
-- input: a bad model file is an expected condition, not a crash.
function PolicyFormat.decode(text)
	if type(text) ~= "string" then
		return nil, "expected a string"
	end

	local ok, result = pcall(function()
		local bundle = { layers = {} }
		local currentLayer, expectedIn, expectedOut = nil, nil, nil
		local lineNumber = 0

		local function finishLayer()
			if not currentLayer then return end
			if #currentLayer.weights ~= expectedOut then
				error(("layer declared %d outputs but has %d w-lines"):format(
					expectedOut, #currentLayer.weights), 0)
			end
			if not currentLayer.biases then
				error("layer is missing its b line", 0)
			end
			table.insert(bundle.layers, currentLayer)
			currentLayer = nil
		end

		for line in (text .. "\n"):gmatch("([^\n]*)\n") do
			lineNumber = lineNumber + 1
			line = line:gsub("#.*$", ""):match("^%s*(.-)%s*$")
			if line ~= "" then
				local tokens = {}
				for token in line:gmatch("%S+") do
					table.insert(tokens, token)
				end
				local keyword = tokens[1]
				local where = "line " .. lineNumber

				if keyword == "cell4-policy" then
					local version = tonumber(tokens[2])
					if version ~= PolicyFormat.VERSION then
						error(("unsupported format version %s (this runtime reads %d)"):format(
							tostring(tokens[2]), PolicyFormat.VERSION), 0)
					end
					bundle.version = version
				elseif keyword == "features" then
					bundle.features = sliceTokens(tokens, 2)
				elseif keyword == "actions" then
					bundle.actions = sliceTokens(tokens, 2)
				elseif keyword == "activation" then
					bundle.activation = tokens[2]
					bundle.outputActivation = tokens[3]
				elseif keyword == "layer" then
					finishLayer()
					expectedIn, expectedOut = tonumber(tokens[2]), tonumber(tokens[3])
					if not expectedIn or not expectedOut or expectedIn < 1 or expectedOut < 1 then
						error(where .. ": layer needs positive input and output sizes", 0)
					end
					currentLayer = { weights = {}, biases = nil }
				elseif keyword == "w" then
					if not currentLayer then error(where .. ": w line outside any layer", 0) end
					if currentLayer.biases then error(where .. ": w line after this layer's b line", 0) end
					table.insert(currentLayer.weights, parseNumbers(tokens, 2, expectedIn, where))
				elseif keyword == "b" then
					if not currentLayer then error(where .. ": b line outside any layer", 0) end
					if currentLayer.biases then error(where .. ": duplicate b line", 0) end
					currentLayer.biases = parseNumbers(tokens, 2, expectedOut, where)
				else
					error(where .. ": unknown keyword '" .. tostring(keyword) .. "'", 0)
				end
			end
		end
		finishLayer()

		if not bundle.version then error("missing 'cell4-policy <version>' header", 0) end
		if not bundle.features then error("missing 'features' line", 0) end
		if not bundle.actions then error("missing 'actions' line", 0) end
		if #bundle.layers == 0 then error("no layers in file", 0) end

		-- Layer shapes must chain: each layer's inputs are the previous
		-- layer's outputs.
		bundle.layerSizes = { #bundle.layers[1].weights[1] }
		for i, layer in ipairs(bundle.layers) do
			local inSize = #layer.weights[1]
			if inSize ~= bundle.layerSizes[i] then
				error(("layer %d takes %d inputs but the previous layer emits %d"):format(
					i, inSize, bundle.layerSizes[i]), 0)
			end
			table.insert(bundle.layerSizes, #layer.weights)
		end

		return bundle
	end)

	if not ok then
		return nil, tostring(result)
	end
	return result
end

Cell4.PolicyFormat = PolicyFormat

-- =========================================================================
-- Perception: turns raw, unbounded world signals into a normalized feature
-- vector the neural net can consume, plus a plain named table the
-- rule-based goals can read without caring about vector ordering.
--
-- The derived constructors (clone/withValues/withDelta) exist so the
-- planner can imagine future states without hand-syncing `named` and
-- `featureVector` - if those two ever drift apart, the rules and the
-- network are reasoning about different worlds.
-- =========================================================================
local Perception = {}

-- spec: an ordered list, where each entry is either
--   raw:     {key = "threat", min = 0, max = 100}
--   derived: {key = "threatRising", derive = function(features, previous) -> [0,1]}
--
-- Derived features exist because a single frame is not a sufficient state.
-- "health 50 and falling" and "health 50 and rising" are the same raw vector
-- but call for opposite actions, and no amount of training can recover a
-- distinction the input representation cannot express. Derived entries are
-- computed in spec order after the raw ones, so a derived feature may build
-- on any feature declared before it.
--
-- `features` is the named table built so far this tick; `previous` is the
-- previous tick's named table, or nil on the first tick of an episode.
function Perception.normalize(rawSignals, spec, previous)
	local named = {}
	local featureVector = {}
	local featureErrors = nil

	for i, field in ipairs(spec) do
		local value
		if field.derive then
			local ok, derived = pcall(field.derive, named, previous)
			if ok and type(derived) == "number" and derived == derived then
				value = Utils.clamp(derived, 0, 1)
			else
				-- Consistent with rules and goals: a broken feature contributes
				-- a neutral value rather than crashing the tick, but it is
				-- recorded so it cannot fail silently.
				value = 0
				featureErrors = featureErrors or {}
				featureErrors[field.key] = ok
					and ("derive() returned " .. type(derived))
					or ("derive() failed: " .. tostring(derived))
			end
		else
			local raw = rawSignals[field.key] or 0
			value = Utils.clamp((raw - field.min) / (field.max - field.min), 0, 1)
		end
		named[field.key] = value
		featureVector[i] = value
	end

	return {
		named = named,
		featureVector = featureVector,
		raw = rawSignals,
		predicted = false,
		featureErrors = featureErrors,
	}
end

-- Rate-of-change of an existing feature, mapped so 0.5 means "unchanged",
-- above means rising and below means falling. `scale` sets how large a
-- per-tick change saturates the signal (scale = 1 means a full 0->1 swing
-- in one tick reaches the extreme).
--
-- Returns 0.5 when there is no previous tick to compare against: at the
-- start of an episode the honest answer is "no observed change," not an
-- invented direction.
function Perception.delta(key, scale)
	scale = scale or 1
	return function(features, previous)
		if not previous or previous[key] == nil then return 0.5 end
		local change = (features[key] or 0) - previous[key]
		return Utils.clamp(0.5 + change * scale * 0.5, 0, 1)
	end
end

function Perception.clone(state)
	local named = {}
	for k, v in pairs(state.named) do
		named[k] = v
	end
	return {
		named = named,
		featureVector = Utils.copyArray(state.featureVector),
		raw = state.raw,
		predicted = state.predicted,
		featureErrors = state.featureErrors,
	}
end

-- Returns a NEW state with the given normalized values overridden, keeping
-- `named` and `featureVector` in sync. The result is flagged predicted=true:
-- anything downstream can tell an imagined state from an observed one, which
-- is the difference between planning and hallucinating.
function Perception.withValues(state, spec, values)
	local out = Perception.clone(state)
	out.predicted = true
	for i, field in ipairs(spec) do
		local v = values[field.key]
		if v ~= nil then
			local clamped = Utils.clamp(v, 0, 1)
			out.named[field.key] = clamped
			out.featureVector[i] = clamped
		end
	end
	return out
end

-- Recomputes every derived feature of a state from its current base
-- features, treating `previous` as the tick it followed.
--
-- The planner needs this: an action's effects change base features, but a
-- derived feature like "threat trend" would otherwise keep the value it had
-- in the real world. A goal reading that stale trend while evaluating an
-- imagined future is being fed a fact from a different timeline. Derived
-- features are functions of base features by definition, so an imagined
-- state has to recompute them to stay internally consistent.
function Perception.recomputeDerived(state, spec, previous)
	local out = Perception.clone(state)
	for i, field in ipairs(spec) do
		if field.derive then
			local ok, derived = pcall(field.derive, out.named, previous)
			local value = 0
			if ok and type(derived) == "number" and derived == derived then
				value = Utils.clamp(derived, 0, 1)
			end
			out.named[field.key] = value
			out.featureVector[i] = value
		end
	end
	return out
end

function Perception.withDelta(state, spec, deltas)
	local values = {}
	for key, delta in pairs(deltas) do
		values[key] = (state.named[key] or 0) + delta
	end
	return Perception.withValues(state, spec, values)
end

Cell4.Perception = Perception

-- =========================================================================
-- Planner: bounded-beam lookahead over declared actions.
--
-- Each action declares when it's applicable (preconditions) and what it's
-- expected to do to the world (effects). The planner searches short action
-- sequences and scores the states they'd produce using the SAME goal
-- utilities the reactive layer uses - one definition of "good," never two.
--
-- It returns the best sequence but only the first action is ever acted on
-- (receding horizon): re-planning every step with fresh perception beats
-- committing to a stale plan.
-- =========================================================================
local Planner = {}
Planner.__index = Planner

function Planner.new(config)
	config = config or {}
	assert(config.spec, "Planner needs the perception spec to build predicted states")
	local self = setmetatable({}, Planner)
	self.spec = config.spec
	self.actions = {}
	self.maxDepth = config.maxDepth or 3
	self.beamWidth = config.beamWidth or 4
	self.discount = config.discount or 0.9 -- future utility is worth slightly less
	self.costPenalty = config.costPenalty or 0.05 -- utility charged per unit of action cost

	-- Only pay for derived-feature recomputation if the spec actually has any.
	self.hasDerived = false
	for _, field in ipairs(config.spec) do
		if field.derive then
			self.hasDerived = true
			break
		end
	end
	return self
end

-- action: {
--   name          = string,
--   preconditions = optional function(state, memory) -> boolean,
--   effects       = function(state, helpers) -> predicted state,
--   cost          = optional number (default 1),
-- }
-- `helpers` gives effects functions a safe way to derive the next state:
--   helpers.withDelta{threat = -0.4}  /  helpers.withValues{threat = 0}
function Planner:registerAction(action)
	assert(type(action.name) == "string", "action needs a name")
	assert(type(action.effects) == "function", "action '" .. tostring(action.name) .. "' needs effects()")
	table.insert(self.actions, {
		name = action.name,
		preconditions = action.preconditions,
		effects = action.effects,
		cost = action.cost or 1,
	})
end

function Planner:actionNames()
	local names = {}
	for _, action in ipairs(self.actions) do
		table.insert(names, action.name)
	end
	return names
end

function Planner:_helpers(state)
	local spec = self.spec
	return {
		withDelta = function(deltas) return Perception.withDelta(state, spec, deltas) end,
		withValues = function(values) return Perception.withValues(state, spec, values) end,
		clone = function() return Perception.clone(state) end,
	}
end

-- Normalizer for a plan of `depth` steps: the sum of the discount factors
-- applied so far. Dividing by it turns accumulated utility into *average
-- discounted utility per step*, which is what makes a 1-step plan and a
-- 3-step plan comparable instead of "longer always scores higher."
function Planner:_normalizer(depth)
	local total = 0
	for i = 1, depth do
		total = total + self.discount ^ (i - 1)
	end
	return total
end

-- scorer must provide scoreState(state, memory); Reasoning is the intended
-- implementation. Returns nil when there is nothing to plan: no actions,
-- none applicable, or - importantly - no goals to rank futures by. Planning
-- without a value function would return an arbitrary pick dressed up as
-- reasoning, which is worse than admitting there is no plan.
-- Otherwise: {firstAction, sequence, score (avg discounted utility, 0..1),
--             depth, cost, expanded}
function Planner:plan(state, memory, scorer)
	if #self.actions == 0 then return nil end
	if scorer.hasGoals and not scorer:hasGoals() then return nil end

	local beam = { { state = state, sequence = {}, score = 0 } }
	local best = nil
	local expanded = 0

	for depth = 1, self.maxDepth do
		local normalizer = self:_normalizer(depth)
		local discountAtDepth = self.discount ^ (depth - 1)
		local candidates = {}

		for _, node in ipairs(beam) do
			for _, action in ipairs(self.actions) do
				local applicable = true
				if action.preconditions then
					local ok, result = pcall(action.preconditions, node.state, memory)
					-- A precondition that errors is treated as "not applicable"
					-- rather than crashing the plan or being assumed true.
					applicable = ok and result and true or false
				end

				if applicable then
					local ok, predicted = pcall(action.effects, node.state, self:_helpers(node.state))
					if ok and type(predicted) == "table" and predicted.featureVector then
						if self.hasDerived then
							-- Keep imagined states self-consistent: the action
							-- moved base features, so trends and composites
							-- derived from them have to move too.
							predicted = Perception.recomputeDerived(predicted, self.spec, node.state.named)
						end
						expanded = expanded + 1
						local utility = scorer:scoreState(predicted, memory)
						local step = discountAtDepth * (utility - self.costPenalty * action.cost)
						local sequence = Utils.copyArray(node.sequence)
						table.insert(sequence, action.name)

						local candidate = {
							state = predicted,
							sequence = sequence,
							score = node.score + step,
							depth = depth,
							cost = (node.cost or 0) + action.cost,
						}
						candidate.normalized = candidate.score / normalizer
						table.insert(candidates, candidate)

						if not best or candidate.normalized > best.normalized
							or (candidate.normalized == best.normalized
								and table.concat(candidate.sequence, ">") < table.concat(best.sequence, ">")) then
							best = candidate
						end
					end
				end
			end
		end

		if #candidates == 0 then break end

		table.sort(candidates, function(a, b)
			if a.normalized == b.normalized then
				return table.concat(a.sequence, ">") < table.concat(b.sequence, ">")
			end
			return a.normalized > b.normalized
		end)

		beam = {}
		for i = 1, math.min(self.beamWidth, #candidates) do
			beam[i] = candidates[i]
		end
	end

	if not best then return nil end
	return {
		firstAction = best.sequence[1],
		sequence = best.sequence,
		score = Utils.clamp(best.normalized, 0, 1),
		depth = best.depth,
		cost = best.cost,
		expanded = expanded,
	}
end

Cell4.Planner = Planner

-- =========================================================================
-- Reasoning: utility reasoning, and the single place a decision is made.
--
-- Two distinct kinds of hand-authored knowledge live here, and keeping them
-- separate is the core of the design:
--
--   GOALS answer "how good is this *state*?" - safety, health, progress.
--     They describe what the agent ultimately wants, never what it should
--     do. The planner scores imagined futures with them.
--   RULES answer "how much do I want this *action* right now?" - flee when
--     threatened, heal when hurt. They are reactive action preferences.
--
-- Collapsing these into one list is tempting and wrong: a state utility
-- would leak into the action ranking as a phantom action, and constant
-- action preferences would give the planner nothing to differentiate
-- futures with.
--
-- Three vote sources feed one ranking:
--   * rule   - hand-authored action preferences (above)
--   * plan   - the first step of the best lookahead sequence, whose value
--              comes from the GOALS, so planning and wanting share one
--              definition of "good"
--   * policy - the trained network's action preferences
-- Votes for the same action name add together. That's the "don't
-- hallucinate" guardrail: a trained model or a plan can push a decision,
-- but a documented rule can always outweigh it, and the trace shows
-- exactly which source contributed what.
-- =========================================================================
local Reasoning = {}
Reasoning.__index = Reasoning

function Reasoning.new(policyNet)
	local self = setmetatable({}, Reasoning)
	self.goals = {} -- state utilities: {name, weight, evaluate}
	self.rules = {} -- action preferences: {action, weight, evaluate}
	self.policyNet = policyNet -- optional NeuralNet
	self.policyActions = nil -- action names matching policyNet's output order
	self.policyWeight = 1
	self.planner = nil
	self.planWeight = 1
	self.lastPlan = nil
	return self
end

-- A state utility. evaluate(state, memory) -> score in [0,1].
-- Registering a goal does NOT create an action; goals describe what is
-- desirable, and the planner works out which actions get there.
function Reasoning:registerGoal(name, weight, evaluate)
	assert(type(evaluate) == "function", "goal '" .. tostring(name) .. "' needs an evaluate function")
	table.insert(self.goals, { name = name, weight = weight or 1, evaluate = evaluate })
end

-- A reactive action preference. evaluate(state, memory) -> score in [0,1],
-- rationale string. `action` is the action name this rule votes for.
function Reasoning:registerRule(action, weight, evaluate)
	assert(type(evaluate) == "function", "rule for '" .. tostring(action) .. "' needs an evaluate function")
	table.insert(self.rules, { action = action, weight = weight or 1, evaluate = evaluate })
end

function Reasoning:hasGoals()
	return #self.goals > 0
end

function Reasoning:attachPolicy(net, actionNames, weight)
	self.policyNet = net
	self.policyActions = actionNames
	self.policyWeight = weight or 1
end

function Reasoning:attachPlanner(planner, weight)
	self.planner = planner
	self.planWeight = weight or 1
end

-- Aggregate "how good is this state" across all goals, normalized to [0,1]
-- by total goal weight. The planner scores imagined states with this, so
-- lookahead and reactive scoring can never disagree about what's desirable.
-- A goal that errors contributes 0 while still counting toward the weight
-- total: a broken goal makes the agent less sure, not accidentally happier.
function Reasoning:scoreState(state, memory)
	local total, weightSum = 0, 0
	for _, goal in ipairs(self.goals) do
		weightSum = weightSum + goal.weight
		local ok, score = pcall(goal.evaluate, state, memory)
		if ok and type(score) == "number" and score == score then
			total = total + Utils.clamp(score, 0, 1) * goal.weight
		end
	end
	if weightSum == 0 then return 0 end
	return total / weightSum
end

function Reasoning:evaluate(state, memory)
	local scored = {}

	for _, rule in ipairs(self.rules) do
		local ok, score, why = pcall(rule.evaluate, state, memory)
		if ok and type(score) == "number" and score == score then
			table.insert(scored, {
				name = rule.action,
				score = Utils.clamp(score, 0, 1) * rule.weight,
				why = why or "(no rationale given)",
				source = "rule",
			})
		else
			-- A rule that errors or returns a non-number contributes nothing
			-- rather than crashing the decision cycle; it still appears in the
			-- trace so it can't fail silently either.
			table.insert(scored, {
				name = rule.action,
				score = 0,
				why = ok and ("evaluate() returned " .. type(score)) or ("evaluate() failed: " .. tostring(score)),
				source = "rule-error",
			})
		end
	end

	self.lastPlan = nil
	if self.planner then
		local plan = self.planner:plan(state, memory, self)
		if plan and plan.firstAction then
			self.lastPlan = plan
			table.insert(scored, {
				name = plan.firstAction,
				score = plan.score * self.planWeight,
				why = string.format(
					"step 1 of %d-step plan [%s], predicted avg utility %.3f",
					plan.depth, table.concat(plan.sequence, " -> "), plan.score
				),
				source = "plan",
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
					score = (probs[i] or 0) * self.policyWeight,
					why = string.format("policy net weight %.3f", probs[i] or 0),
					source = "policy",
				})
			end
		else
			-- Most likely a feature-vector/input-size mismatch: the loaded model
			-- doesn't match this pipeline's perception spec. Surface it instead
			-- of quietly reasoning without the model.
			table.insert(scored, {
				name = "__policy_error__",
				score = 0,
				why = "policy forward() failed: " .. tostring(outputs),
				source = "policy-error",
			})
		end
	end

	return Utils.sortScored(scored, "name")
end

-- Every action name this reasoner could ever emit, deduplicated and sorted.
-- Sorted because this list defines the action *index* the trainer will use
-- for policy outputs - it has to be stable across runs and machines.
function Reasoning:actionNames()
	local seen, names = {}, {}
	local function add(name)
		if name and not seen[name] then
			seen[name] = true
			table.insert(names, name)
		end
	end
	for _, rule in ipairs(self.rules) do
		add(rule.action)
	end
	if self.planner then
		for _, name in ipairs(self.planner:actionNames()) do
			add(name)
		end
	end
	if self.policyActions then
		for _, name in ipairs(self.policyActions) do
			add(name)
		end
	end
	table.sort(names)
	return names
end

-- Combines votes for the same action, then returns the winner plus the full
-- ranked trace. The winner carries `confidence`: the margin over the
-- runner-up as a fraction of the winning score. Near-ties produce low
-- confidence, which is what lets Pipeline abstain instead of guessing.
function Reasoning:decide(state, memory)
	local scored = self:evaluate(state, memory)
	local combined, order = {}, {}

	-- rule-error entries stay in the trace at score 0 so a broken goal is
	-- visible; policy-error is a diagnostic, not a candidate action, so it
	-- is kept out of the ranking entirely.
	for _, entry in ipairs(scored) do
		if entry.source ~= "policy-error" then
			local existing = combined[entry.name]
			if existing then
				existing.score = existing.score + entry.score
				table.insert(existing.reasons, entry.why)
				table.insert(existing.sources, entry.source)
			else
				combined[entry.name] = {
					name = entry.name,
					score = entry.score,
					reasons = { entry.why },
					sources = { entry.source },
				}
				table.insert(order, entry.name)
			end
		end
	end

	local trace = {}
	for _, name in ipairs(order) do
		table.insert(trace, combined[name])
	end
	Utils.sortScored(trace, "name")

	if #trace == 0 then
		return nil, trace
	end

	local top = trace[1]
	local runnerUp = trace[2]
	top.margin = top.score - (runnerUp and runnerUp.score or 0)
	if top.score > 0 then
		top.confidence = Utils.clamp(top.margin / top.score, 0, 1)
	else
		-- Nothing scored above zero: the agent has no positive reason to do
		-- anything. That is a zero-confidence situation, not a tie to break.
		top.confidence = 0
	end

	return top, trace
end

Cell4.Reasoning = Reasoning

-- =========================================================================
-- Pipeline: wires perception -> memory -> reasoning into one step() call,
-- enforces the confidence floor, and records the transitions that the
-- external trainer will learn from.
--
-- Experience is recorded in the standard RL shape: the action taken in a
-- state, the reward that followed, and the state it led to. Because the
-- reward for a step is only known after it plays out, each step closes out
-- the *previous* step's record - so the buffer only ever contains
-- transitions that actually completed.
-- =========================================================================
local Pipeline = {}
Pipeline.__index = Pipeline

function Pipeline.new(config)
	assert(config and config.perceptionSpec, "Pipeline needs a perceptionSpec")
	assert(config.reasoning, "Pipeline needs a reasoning instance")

	local self = setmetatable({}, Pipeline)
	self.spec = config.perceptionSpec
	self.now = config.clock or os.clock
	self.memory = config.memory or Memory.new(config.memoryCapacity, self.now)
	self.reasoning = config.reasoning

	-- Below this confidence the pipeline refuses to commit to its own top
	-- choice and falls back. Default 0 = never abstain (opt-in behaviour).
	self.minConfidence = config.minConfidence or 0
	self.fallbackAction = config.fallbackAction

	-- smoothing: {featureKey = windowSize}. Averages a feature over its last
	-- N observations before reasoning on it. Raw per-tick game telemetry is
	-- noisy, and an agent that re-decides on every spike is useless.
	self.smoothing = config.smoothing

	-- switchMargin: how much better a challenger must score than the action
	-- already running before the agent will switch to it. Without this, two
	-- near-equal actions make the agent stutter between them every tick.
	-- Default 0 = switch freely (opt-in behaviour).
	self.switchMargin = config.switchMargin or 0

	self.experience = RingBuffer.new(config.experienceCapacity or 256)
	self.pending = nil
	self.steps = 0
	self.episode = 1
	return self
end

-- Key under which the currently-committed action is held in memory. Namespaced
-- so it can't collide with beliefs written by rules and goals.
local LAST_ACTION_KEY = "cell4:lastAction"

-- Averages configured features over their recent observation window. Reads
-- from memory, which holds the RAW observations - smoothing never feeds on
-- its own output, so it can't compound into drift.
function Pipeline:_smooth(state)
	if not self.smoothing then return state end

	local maxWindow = 1
	for _, window in pairs(self.smoothing) do
		if window > maxWindow then maxWindow = window end
	end

	local recent = self.memory:recentContext(maxWindow) -- newest first, includes this tick
	local values, any = {}, false
	for key, window in pairs(self.smoothing) do
		if window > 1 then
			local sum, n = 0, 0
			for i = 1, math.min(window, #recent) do
				local observed = recent[i].data
				if observed and observed.named and observed.named[key] then
					sum = sum + observed.named[key]
					n = n + 1
				end
			end
			if n > 0 then
				values[key] = sum / n
				any = true
			end
		end
	end
	if not any then return state end

	local smoothed = Perception.withValues(state, self.spec, values)
	-- withValues flags derived states as predicted, but a smoothed
	-- observation is still an observation, not an imagined future.
	smoothed.predicted = false
	return smoothed
end

function Pipeline:_closePending(reward, nextState, t)
	if not self.pending then return end
	self.pending.reward = reward or 0
	self.pending.nextFeatures = Utils.copyArray(nextState.featureVector)
	self.pending.done = false
	self.pending.closedAt = t
	self.experience:push(self.pending)
	self.pending = nil
end

-- Ends the current episode (death, round end, reset).
--
-- This exists because without it the agent's last action of one life gets
-- recorded as transitioning into the first state of the next life. That is
-- a transition that never happened, and a value estimator bootstrapping
-- across it learns that dying leads to respawning - which is exactly
-- backwards. The final transition is instead closed as terminal
-- (done = true, no nextFeatures), which is the signal a trainer needs to
-- stop bootstrapping there and use the final reward as-is.
--
-- The boundary also resets what must not leak between lives: the committed
-- action (so hysteresis doesn't hold an action from a previous life) and
-- recent observations (so smoothing doesn't average the old life's
-- telemetry into the new one's). Beliefs written by rules survive, since
-- knowledge learned in one episode may legitimately carry forward.
function Pipeline:endEpisode(finalReward)
	local closed = false
	if self.pending then
		self.pending.reward = finalReward or 0
		self.pending.nextFeatures = nil -- terminal: there is no next state
		self.pending.done = true
		self.pending.closedAt = self.now()
		self.experience:push(self.pending)
		self.pending = nil
		closed = true
	end

	self.episode = self.episode + 1
	self.memory:forget(LAST_ACTION_KEY)
	self.memory:clearObservations()
	-- Derived features compare against the previous tick, so this must go
	-- too: a delta measured across a death is change that never happened.
	self.previousNamed = nil
	return closed
end

-- rawSignals: table of this tick's world signals.
-- reward: the reward attributable to the PREVIOUS step's action, if any.
function Pipeline:step(rawSignals, reward)
	local t = self.now()
	local observed = Perception.normalize(rawSignals, self.spec, self.previousNamed)
	self.previousNamed = observed.named
	-- Memory stores the raw observation; reasoning runs on the smoothed view.
	self.memory:pushObservation(observed, t)
	local state = self:_smooth(observed)

	-- Close the previous transition against the SMOOTHED state, because that
	-- is what reasoning and the policy network actually saw. Recording `s`
	-- smoothed and `s'` raw would put the two halves of every training
	-- transition in different representations and quietly poison learning.
	self:_closePending(reward, state, t)
	local decision, trace = self.reasoning:decide(state, self.memory)
	local confidence = decision and decision.confidence or 0
	local chosen = decision and decision.name or nil
	local abstained = false
	local abstainReason = nil
	local held = false
	local heldReason = nil

	-- Hysteresis: keep doing what we're already doing unless the challenger
	-- is meaningfully better. Only applies when the incumbent is still a
	-- live candidate scoring above zero - we never cling to an action that
	-- is no longer applicable, or hold on when nothing is worth doing.
	if decision and self.switchMargin > 0 then
		local incumbent = self.memory:recall(LAST_ACTION_KEY, math.huge)
		if incumbent and incumbent ~= decision.name then
			local incumbentScore = 0
			for _, entry in ipairs(trace) do
				if entry.name == incumbent then incumbentScore = entry.score end
			end
			if incumbentScore > 0 and (decision.score - incumbentScore) < self.switchMargin then
				held = true
				heldReason = string.format(
					"held '%s' (%.3f): challenger '%s' (%.3f) is within the %.3f switch margin",
					incumbent, incumbentScore, decision.name, decision.score, self.switchMargin
				)
				chosen = incumbent
			end
		end
	end

	-- The confidence floor is a gate on acting at all. It does not fire when
	-- hysteresis held the incumbent: continuing a prior commitment is a
	-- deliberate choice, not the coin-flip the floor exists to prevent.
	if decision and not held and confidence < self.minConfidence then
		abstained = true
		abstainReason = string.format(
			"confidence %.3f below floor %.3f (top '%s' %.3f vs runner-up %.3f)",
			confidence, self.minConfidence, decision.name, decision.score,
			trace[2] and trace[2].score or 0
		)
		chosen = self.fallbackAction
	end

	if chosen ~= nil then
		self.memory:remember(LAST_ACTION_KEY, chosen, 1)
	end

	self.steps = self.steps + 1

	-- Only record a transition when an action was actually taken; there is
	-- nothing to learn from a step where the agent did nothing.
	if chosen ~= nil then
		self.pending = {
			step = self.steps,
			episode = self.episode,
			t = t,
			features = Utils.copyArray(state.featureVector),
			action = chosen,
			confidence = confidence,
			abstained = abstained,
		}
	end

	return {
		decision = chosen,
		score = decision and decision.score or 0,
		confidence = confidence,
		abstained = abstained,
		abstainReason = abstainReason,
		held = held,
		heldReason = heldReason,
		plan = self.reasoning.lastPlan,
		trace = trace,
		state = state, -- the smoothed view reasoning actually ran on
		observed = observed, -- what perception literally saw this tick
		featureErrors = observed.featureErrors, -- nil unless a derive() failed
	}
end

-- The contract the external trainer must satisfy: which features arrive in
-- which order, which actions exist in which index order, and what shape the
-- policy network is. Emitted alongside the experience so a training run can
-- never silently mismatch the runtime it will be deployed into.
function Pipeline:trainingContract()
	local features = {}
	for i, field in ipairs(self.spec) do
		if field.derive then
			-- Derived features are produced already normalized, so their range
			-- is [0,1] by construction rather than by a declared raw range.
			features[i] = { name = field.key, min = 0, max = 1, derived = true }
		else
			features[i] = { name = field.key, min = field.min, max = field.max, derived = false }
		end
	end

	local actions = self.reasoning:actionNames()
	local actionIndex = {}
	for i, name in ipairs(actions) do
		actionIndex[name] = i
	end

	return {
		version = Cell4.VERSION,
		features = features,
		actions = actions,
		actionIndex = actionIndex,
		policy = self.reasoning.policyNet and self.reasoning.policyNet:describe() or nil,
	}
end

-- Loads a trained policy, but only if it was trained against this runtime.
--
-- Accepts either a PolicyFormat string or an already-decoded bundle.
-- Returns true on success, or (false, reason) - a mismatched model is an
-- expected condition to report, not a crash.
--
-- Validation is the point of this function. A model whose feature order or
-- action set has drifted from the runtime will still happily produce
-- numbers; those numbers just mean something else now. Silently loading it
-- yields an agent that is confidently wrong, which is far worse than one
-- that refuses to load. The rules:
--   * features must match the perception spec exactly, in order (they are
--     the input vector - position IS meaning)
--   * actions must match the runtime's action set exactly, in order (they
--     are the output indices). This requires the policy to have an output
--     for every action the agent can take.
--   * layer shape must chain from #features to #actions
function Pipeline:loadPolicy(source)
	local bundle = source
	if type(source) == "string" then
		local decoded, decodeError = PolicyFormat.decode(source)
		if not decoded then
			return false, "could not parse policy: " .. tostring(decodeError)
		end
		bundle = decoded
	end
	if type(bundle) ~= "table" or not bundle.layers then
		return false, "expected a policy string or decoded bundle"
	end

	local function describeList(list)
		return "[" .. table.concat(list, ", ") .. "]"
	end
	local function sameList(a, b)
		if #a ~= #b then return false end
		for i = 1, #a do
			if a[i] ~= b[i] then return false end
		end
		return true
	end

	local liveFeatures = {}
	for i, field in ipairs(self.spec) do
		liveFeatures[i] = field.key
	end
	if not bundle.features or not sameList(bundle.features, liveFeatures) then
		return false, ("feature mismatch: policy was trained on %s but this runtime perceives %s")
			:format(describeList(bundle.features or {}), describeList(liveFeatures))
	end

	-- The live action set must be computed as if this policy were already
	-- attached, since a policy may legitimately introduce actions that no
	-- rule votes for.
	local previousActions = self.reasoning.policyActions
	self.reasoning.policyActions = bundle.actions
	local liveActions = self.reasoning:actionNames()
	self.reasoning.policyActions = previousActions

	if not bundle.actions or not sameList(bundle.actions, liveActions) then
		return false, ("action mismatch: policy outputs %s but this runtime's actions are %s")
			:format(describeList(bundle.actions or {}), describeList(liveActions))
	end

	local layerSizes = bundle.layerSizes
	if not layerSizes then
		layerSizes = { #bundle.layers[1].weights[1] }
		for _, layer in ipairs(bundle.layers) do
			table.insert(layerSizes, #layer.weights)
		end
	end
	if layerSizes[1] ~= #liveFeatures then
		return false, ("policy takes %d inputs but there are %d features")
			:format(layerSizes[1], #liveFeatures)
	end
	if layerSizes[#layerSizes] ~= #liveActions then
		return false, ("policy emits %d outputs but there are %d actions")
			:format(layerSizes[#layerSizes], #liveActions)
	end

	local net = NeuralNet.new(layerSizes, bundle.activation, bundle.outputActivation)
	local loaded, loadError = pcall(function()
		net:loadWeights({ layers = bundle.layers })
	end)
	if not loaded then
		return false, "weights rejected: " .. tostring(loadError)
	end

	self.reasoning:attachPolicy(net, bundle.actions, self.reasoning.policyWeight)
	return true
end

-- Everything the external trainer needs to export a policy this runtime
-- will accept: the contract, plus the exact layer shape to produce. The
-- hidden layer sizes are the trainer's choice; the first and last are not.
function Pipeline:policyTemplate(hiddenSizes)
	local contract = self:trainingContract()
	local layerSizes = { #contract.features }
	for _, size in ipairs(hiddenSizes or {}) do
		table.insert(layerSizes, size)
	end
	table.insert(layerSizes, #contract.actions)

	local features = {}
	for i, field in ipairs(contract.features) do
		features[i] = field.name
	end

	return {
		features = features,
		actions = contract.actions,
		layerSizes = layerSizes,
	}
end

-- Completed transitions, oldest first, each with the action resolved to its
-- contract index so the trainer can use it as a label directly.
function Pipeline:exportExperience()
	local contract = self:trainingContract()
	local records = {}
	for i, record in ipairs(self.experience:toArray()) do
		records[i] = {
			step = record.step,
			episode = record.episode,
			t = record.t,
			features = record.features,
			action = record.action,
			actionIndex = contract.actionIndex[record.action],
			confidence = record.confidence,
			abstained = record.abstained,
			reward = record.reward,
			-- done = true means terminal: nextFeatures is absent and a value
			-- estimator must not bootstrap past this transition.
			done = record.done,
			nextFeatures = record.nextFeatures,
		}
	end
	return { contract = contract, records = records }
end

function Pipeline:clearExperience()
	self.experience:clear()
	self.pending = nil
end

-- Human-readable decision trace. "Explainable" is only true if a person can
-- actually read it, and raw nested tables aren't readable in a log file.
function Pipeline:explain(result)
	local lines = {}
	table.insert(lines, string.format(
		"decision: %s (score %.3f, confidence %.3f)%s%s",
		tostring(result.decision), result.score, result.confidence,
		result.abstained and "  [ABSTAINED -> fallback]" or "",
		result.held and "  [HELD by hysteresis]" or ""
	))
	if result.abstainReason then
		table.insert(lines, "  reason: " .. result.abstainReason)
	end
	if result.heldReason then
		table.insert(lines, "  hysteresis: " .. result.heldReason)
	end
	if result.featureErrors then
		for key, message in pairs(result.featureErrors) do
			table.insert(lines, "  BROKEN FEATURE " .. key .. ": " .. message)
		end
	end
	if result.plan then
		table.insert(lines, "  plan: " .. table.concat(result.plan.sequence, " -> "))
	end
	for rank, entry in ipairs(result.trace) do
		table.insert(lines, string.format("  %d. %s  %.3f  [%s]",
			rank, entry.name, entry.score, table.concat(entry.sources, ",")))
		for _, reason in ipairs(entry.reasons) do
			table.insert(lines, "       - " .. reason)
		end
	end
	return table.concat(lines, "\n")
end

Cell4.Pipeline = Pipeline

return Cell4
