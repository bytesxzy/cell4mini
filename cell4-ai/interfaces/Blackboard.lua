--!strict
-- Shape of the per-tick world-state snapshot the reasoner reads. Built once
-- per tick before any decision runs, so a whole tick reasons over one
-- consistent view instead of live-querying game state mid-decision.
-- See ARCHITECTURE.md section 3. This is a type/shape reference, not a
-- working builder — populating it from real game state is game-specific and
-- intentionally left out.

export type Cooldowns = { [string]: number } -- abilityId -> readyAt (os.clock())

export type SelfState = {
	health: number,
	maxHealth: number,
	position: Vector3,
	facing: Vector3,
	cooldowns: Cooldowns,
	stateTag: string, -- "engaged" | "idle" | "fleeing" | "staggered"
}

export type TargetInfo = {
	entity: Instance,
	distance: number,
	health: number,
	threatScore: number,
	lastSeenAt: number,
}

export type EnvironmentInfo = {
	hazards: { Instance },
	coverPoints: { Vector3 },
}

export type DecisionRecord = {
	tick: number,
	category: string,
	chosenActionId: string?,
	scores: { [string]: number },
}

export type Blackboard = {
	self: SelfState,
	targets: { TargetInfo }, -- sorted nearest-first, pre-filtered to relevant range
	environment: EnvironmentInfo,
	history: { DecisionRecord }, -- fixed-size ring buffer, oldest overwritten first
}

return {}
