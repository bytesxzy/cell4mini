--!strict
-- Skeleton of the tick loop described in ARCHITECTURE.md section 6.
-- Wires BehaviorTree (priority) + Utility AI (choice) + WeightProvider
-- (tunable numbers) + Telemetry (why a decision was made) together.
-- BehaviorTree/ActionRegistry/Telemetry are referenced but not implemented
-- here — this file shows control flow, not a runnable system.

local WeightProvider = require(script.Parent.WeightProvider)
local ActionModule = require(script.Parent.Action)
type Action = ActionModule.Action
type Blackboard = ActionModule.Blackboard

local Reasoner = {}

-- Placeholder: real category selection is a small fixed-order Selector
-- (Survive -> Engage -> Reposition -> Idle), each gated by a cheap
-- precondition on the blackboard. Left as a stub pending the actual game's
-- category set (see ARCHITECTURE.md "Assumptions").
local function selectCategory(blackboard: Blackboard): string
	return "Idle"
end

-- Placeholder: returns every registered action whose Category matches.
-- Real implementation is just a registry lookup, no logic of its own.
local function candidatesForCategory(category: string): { Action }
	return {}
end

function Reasoner.tick(agent: Instance, blackboard: Blackboard)
	local category = selectCategory(blackboard)
	local candidates = candidatesForCategory(category)

	local best: Action? = nil
	local bestScore = -1

	local scores: { [string]: number } = {}

	for _, action in candidates do
		if action:CanRun(blackboard) then
			local score = action:GetUtility(blackboard) * WeightProvider.get(action.Id)
			scores[action.Id] = score
			if score > bestScore then
				best, bestScore = action, score
			end
		end
	end

	-- Telemetry.recordDecision(agent, category, scores, best) -- Night 4

	if best then
		best:Execute(agent, blackboard)
	end
	-- else: fall through to a guaranteed-safe Idle action once one is
	-- registered (ARCHITECTURE.md goal 5: never stall, never error out).
end

return Reasoner
