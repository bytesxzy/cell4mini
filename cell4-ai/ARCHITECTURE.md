# cell4.lua — AI Reasoning Architecture

Status: living document, revised nightly. This is a design spec, not the shipped
script — no model weights, no training data, no training code live here. The
part that actually learns/trains happens on the requester's own servers; this
document (and the stub modules under `interfaces/`) only defines the shape
that reasoning takes inside Roblox/Luau and the seam where trained parameters
plug in later.

## Assumptions (please correct if wrong)

No copy of `cell4.lua` or the target game exists in this repo yet, so the
design below is written against generic constraints of a Roblox combat/NPC AI
rather than a specific game's rules. Flagging assumptions explicitly instead
of inventing game-specific detail:

- Runs server-side, per-NPC, as a `ModuleScript` required by a controller script.
- Tick rate is throttled (not every Heartbeat) — assumed ~5–10 Hz, not 60 Hz.
- The agent picks among a small, enumerable set of actions per tick (attack
  variants, movement, defend, retreat, ability use), not open-ended text/tool use.
- "Reasoning" means better *decision quality* (right action, right time,
  legible priority under pressure) — not natural-language reasoning.

If the real cell4.lua differs (different genre, tick model, or action space),
say so and the next nightly pass will re-baseline against it instead of
building further on a wrong assumption.

## Non-goals

- No LLM calls at runtime. Roblox has no low-latency path to an external
  inference server per-tick; anything like that belongs to a pre-computed
  policy/weight table pushed in from outside, not a live API call.
- No gameplay-specific balancing numbers. Those depend on the actual game and
  should come from the requester, not be guessed.
- No training loop, dataset, or gradient anything. Out of scope by request.

## 1. Design goals

1. **Fast**: bounded, cheap work per tick per agent — this runs for every NPC
   using it, potentially many at once.
2. **Legible**: given a blackboard snapshot, a human can read *why* the agent
   chose an action, not just *that* it did. Needed for debugging and for
   tuning without re-reading the whole script.
3. **Tunable without redeploys**: numeric weights/thresholds live in data,
   not scattered through `if` chains, so behavior can be retuned (by hand now,
   by the requester's external training later) without touching control flow.
4. **Server-authoritative**: all decision state and the actions that follow
   from it live and are validated server-side; clients only render outcomes.
5. **Gracefully degrading**: a missing/malformed blackboard field or an action
   that throws should not stall the agent — fall back to a safe default action
   (e.g. idle/hold position), never hang or error the whole NPC.

## 2. Module map

```
cell4.lua (controller, required per-NPC)
 ├─ Blackboard.lua      -- world-state snapshot the reasoner reads (pure data)
 ├─ Reasoner.lua         -- the tick loop: BT for priority, Utility AI for choice
 ├─ Actions/
 │   ├─ Action.lua       -- interface/contract every action module implements
 │   ├─ Attack.lua, Retreat.lua, Reposition.lua, ...  (per-behavior modules)
 ├─ WeightProvider.lua   -- indirection point for externally-tuned weights
 └─ Telemetry.lua        -- structured trace of decisions, for debugging/tuning
```

Each box is a separate `ModuleScript`. Actions are self-contained and
independently addable/removable — the reasoner never hardcodes a list of
action names, it iterates whatever is registered.

## 3. Blackboard (working memory)

A single plain table rebuilt (or incrementally updated) once per tick,
*before* reasoning runs, so the whole tick reasons over one consistent
snapshot instead of live-querying the game state mid-decision (which would
make behavior order-dependent and hard to reason about).

Proposed shape:

```lua
Blackboard = {
  self = {
    health, maxHealth, position, facing, cooldowns = {[abilityId]=readyAt},
    stateTag,        -- e.g. "engaged" | "idle" | "fleeing" | "staggered"
  },
  targets = {         -- sorted nearest-first, pre-filtered to relevant range
    { entity, distance, health, threatScore, lastSeenAt },
    ...
  },
  environment = {
    hazards = {...},  -- anything the agent should route around/avoid standing in
    coverPoints = {...},
  },
  history = RingBuffer(N),  -- last N decisions + outcomes, for Night 3's
                            -- adaptation layer; write-only for now
}
```

`threatScore` and similar derived fields are computed once when the
blackboard is built, not recomputed per candidate action — keeps the utility
scoring pass (below) cheap.

## 4. Decision core: Behavior Tree for priority, Utility AI for choice

Pure Utility AI (score everything, pick the max) tends to produce mushy
priorities — a slightly-higher-scoring "attack" can beat an "I am nearly dead,
flee" response if the weights aren't perfectly balanced. Pure Behavior Trees
tend to produce brittle, hand-ordered `if/elseif` chains that are hard to
extend. Using both, layered:

- **Behavior Tree = priority skeleton.** A small `Selector` of high-level
  categories, evaluated in fixed order, each gated by a cheap precondition:
  `Survive` (low health / no escape) → `Engage` (valid target in range) →
  `Reposition` (no target, needs to relocate) → `Idle`. The tree decides
  *which category is even eligible this tick*; it does not pick the specific
  action.
- **Utility AI = choice within a category.** Once a category is entered, every
  registered action in that category scores itself against the blackboard
  (`0..1`), and the reasoner runs the highest-scoring one whose `CanRun`
  check passes. This is where "smarter" decisions come from — e.g. choosing
  *which* attack based on cooldowns, range, and target health rather than
  always using the same one.

This means "Survive" always outranks "Engage" regardless of utility scores
(a hard priority a pure utility system can't cleanly express), while within
"Engage" the agent still picks the *best* attack rather than the *first*
attack (which a pure behavior tree tends to degrade into).

## 5. Action contract

Every action module implements the same interface (see
`interfaces/Action.lua`):

```lua
Action.Category  : string               -- which BT branch this belongs to
Action.GetUtility(blackboard) -> number -- 0..1, cheap, no side effects
Action.CanRun(blackboard)     -> boolean-- hard gate (cooldown ready, in range, ...)
Action.Execute(agent, blackboard)       -- the only place with side effects
```

Keeping `GetUtility` side-effect-free is what makes the system debuggable:
the reasoner can score every action every tick purely for the telemetry trace
even when it isn't the one chosen, without changing game state.

## 6. Tick loop (pseudocode)

```lua
function Reasoner.tick(agent, blackboard)
  local category = BehaviorTree.selectCategory(blackboard)  -- Survive/Engage/Reposition/Idle
  local candidates = ActionRegistry.forCategory(category)

  local best, bestScore = nil, -1
  for _, action in candidates do
    if action.CanRun(blackboard) then
      local score = action.GetUtility(blackboard) * WeightProvider.get(action.Id)
      if score > bestScore then best, bestScore = action, score end
    end
  end

  Telemetry.recordDecision(agent, category, candidates, best, bestScore)

  if best then
    best.Execute(agent, blackboard)
  else
    Actions.Idle.Execute(agent, blackboard)  -- guaranteed-safe fallback
  end
end
```

`WeightProvider.get` is the one line that separates "hand-tuned constant" from
"externally trained parameter" — see §8.

## 7. Roadmap for later nights (not yet designed)

- **Night 2**: multi-step tactics — a thin planning layer above single-action
  utility scoring (e.g. "retreat to cover, THEN heal") without going full GOAP.
- **Night 3**: the `history` ring buffer gets consumed — short-term adaptation
  (e.g. down-weighting an attack the target keeps dodging).
- **Night 4**: Telemetry → a replayable decision trace format, so the
  requester can inspect *why* an agent did something after the fact.
- **Night 5**: multi-agent coordination (shared blackboard slice so squads
  don't all pick the same target/action).
- **Night 6**: failure modes and abuse cases — what happens under a
  corrupted/adversarial blackboard (spoofed client data), stuck cooldown
  tables, action `Execute` throwing mid-tick.
- **Night 7**: consolidation pass — tighten whatever the previous six nights
  produced into one coherent spec, flag anything that turned out to be a dead
  end.

Each night's entry goes in `PROGRESS.md`, and this file gets amended in place
rather than growing an unbounded changelog of its own.

## 8. Seam for externally-trained parameters

`WeightProvider.lua` is intentionally the only module allowed to hold tunable
numbers. It starts as a hardcoded table (see `interfaces/WeightProvider.lua`)
but its interface (`get(actionId) -> number`) is the same whether the table
is hand-written or generated by an offline training process run elsewhere and
dropped in as a data file. That means the training work mentioned as
happening "on your servers" doesn't require changing the Lua reasoning
architecture at all — it only needs to produce a table matching this shape.
