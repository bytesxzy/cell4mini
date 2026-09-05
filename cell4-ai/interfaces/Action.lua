--!strict
-- Contract every action module must satisfy. This file defines the shape
-- only; it is not itself a usable action. See ARCHITECTURE.md section 5.

export type Blackboard = { [string]: any }

export type Action = {
	Id: string,
	Category: string, -- "Survive" | "Engage" | "Reposition" | "Idle"

	-- Cheap, side-effect-free. Called every tick for every candidate in the
	-- active category, including ones that won't be chosen (telemetry needs
	-- the full score spread, not just the winner).
	GetUtility: (self: Action, blackboard: Blackboard) -> number, -- 0..1

	-- Hard gate: cooldown ready, target in range, resource available, etc.
	-- Checked before GetUtility is trusted for selection.
	CanRun: (self: Action, blackboard: Blackboard) -> boolean,

	-- The only place allowed to mutate game state.
	Execute: (self: Action, agent: Instance, blackboard: Blackboard) -> (),
}

return {}
