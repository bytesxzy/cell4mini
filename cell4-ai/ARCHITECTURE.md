# cell4.lua — AI Reasoning Architecture

Status: **design only, night 1**. No implementation, no training. This document
is the living spec that gets refined night over night; `NIGHTLY_LOG.md` tracks
what changed and why.

## 0. What actually exists right now

Important to say plainly, so nobody mistakes this for progress on real code:
there is no `cell4.lua` in this repository, on any branch, at any point in its
history. There's a `cell4.png` and a portfolio site (`index.html`/`service.html`)
for a commissions team, but nothing describing what this script controls —
which engine/runtime it runs in (Roblox/Luau, Garry's Mod, FiveM, a standalone
Lua VM, an embedded scripting host, etc.), what it perceives, what actions it
can take, or what "reasoning" needs to accomplish for it.

Given that, tonight's design is deliberately **engine-agnostic**: a reasoning
core with a thin, swappable adapter boundary. Whichever runtime it lands in,
only the adapter layer (Section 3) should need to change. The open questions
in Section 8 are the things that would let later nights stop guessing and
start specializing.

## 1. Design goals

- **Bounded per-tick cost.** Game/script loops run on a frame or tick budget.
  Reasoning must never block the loop waiting on something slow (disk, network,
  an LLM call).
- **Two speeds of thought.** Cheap, reactive decisions happen synchronously
  every tick. Expensive, deliberate reasoning happens asynchronously and its
  results get folded in whenever they arrive — never blocking.
- **External heavy compute stays external.** The user's servers do any actual
  model inference/training; `cell4.lua` only calls out to it and consumes the
  result. The Lua side owns fast heuristics, state, and safety — not model
  weights.
- **Legality before execution.** Nothing suggested by a slow/deliberative
  source (including an external model) executes without being checked against
  a locally-known list of currently-legal actions. This is the guard against
  a remote reasoning step hallucinating an action that doesn't apply to the
  current state.
- **Explainable failure.** When reasoning breaks, it should degrade to the
  simplest reactive behavior rather than stall or crash the host script.

## 2. Layered overview

```
 ┌───────────────────────────────────────────────────────────────┐
 │                         cell4.lua                              │
 │                                                                 │
 │  ┌────────────┐   ┌───────────────┐   ┌─────────────────────┐  │
 │  │  Adapter   │──▶│  World Model  │──▶│   Fast Reasoning     │  │
 │  │ (sensors)  │   │  (blackboard) │   │   Core (utility AI)  │  │
 │  └────────────┘   └───────┬───────┘   └──────────┬──────────┘  │
 │                            │                      │             │
 │                            ▼                      ▼             │
 │                    ┌───────────────┐      ┌───────────────┐    │
 │                    │    Memory      │      │  Action Queue │    │
 │                    │ (short + long) │      │  + Legality   │    │
 │                    └───────┬───────┘       │    Filter     │    │
 │                            │                └───────┬───────┘   │
 │                            ▼                        ▼           │
 │                    ┌───────────────┐        ┌───────────────┐  │
 │                    │  Deliberative │        │   Adapter     │  │
 │                    │   Planner     │        │  (effectors)  │  │
 │                    │  (GOAP/BT)    │        └───────────────┘  │
 │                    └───────┬───────┘                            │
 │                            │ async, non-blocking                │
 │                            ▼                                    │
 │                    ┌───────────────────┐                        │
 │                    │  Brain Bridge      │───▶  external server   │
 │                    │ (queue + cache +  │      (user's model,     │
 │                    │  timeout/fallback)│       runs elsewhere)   │
 │                    └───────────────────┘                        │
 └───────────────────────────────────────────────────────────────┘
```

## 3. Adapter layer (sensors / effectors)

The only part meant to be engine-specific. Two small interfaces:

- `sensors.poll() -> partial WorldState table` — called once per tick, must be
  O(1)-ish, never blocks.
- `effectors.execute(action) -> ok, result` — takes one item off the action
  queue and performs it in the host environment. Must report success/failure
  back (Section 6 needs this for the adaptation loop).

Everything above this layer only ever deals with plain Lua tables, never
engine APIs directly. That's what makes the reasoning core portable and
independently testable (Section 7).

## 4. World Model (blackboard)

A single normalized table, replacing rather than merging on each adapter poll
for volatile fields, with timestamps per field so staleness is detectable:

```lua
WorldState = {
  self = { pos, health, state, ... },
  entities = { [id] = { pos, kind, last_seen_tick, ... } },
  facts = { [key] = { value, tick, confidence } },  -- derived/inferred facts
  tick = <current tick number>,
}
```

`confidence` matters once the Brain Bridge (Section 6) starts writing derived
facts back in — a locally-observed fact and a remotely-suggested one shouldn't
be treated as equally certain.

## 5. Fast Reasoning Core — utility AI + reactive rules

Runs every tick, synchronously, bounded cost:

1. Enumerate currently-applicable **considerations** (small pure functions of
   WorldState → score 0..1), e.g. `threat_proximity`, `goal_progress`,
   `resource_need`.
2. Combine per-action scores via weighted product/average (utility-AI style —
   cheap, avoids the "one huge if/else" trap, and weights are the one thing
   the adaptation loop in Section 8 is allowed to touch at runtime).
3. Pick the top-scoring **goal**, not an action directly — the goal gets handed
   to the planner (Section 6) to be turned into a concrete action sequence.
4. A small set of **reflex overrides** bypass scoring entirely for
   safety-critical cases (e.g. "health critical → flee") — reactive rules that
   run before utility scoring and can preempt it.

This layer never talks to the Brain Bridge. It always has an answer, even if
the deliberative/external layers are stalled or timed out — that's the
degrade-gracefully guarantee from Section 1.

## 6. Deliberative Planner + Brain Bridge

The planner turns a goal into an ordered action list. Two sources feed it:

- **Local planner** (GOAP-style: search over known action preconditions/effects
  to connect current state to goal state). Always available, always fast
  enough to run within a tick or spread across a few ticks via coroutine.
- **Brain Bridge**: an async, queued channel to the user's external server for
  cases the local planner scores as high-stakes or high-ambiguity. Contract:

```lua
-- request (Lua table, gets serialized — JSON is the obvious choice)
{ id, tick, goal, world_snapshot, legal_actions }

-- response
{ id, suggested_plan = { action, ... }, confidence, ttl_ticks }
```

Rules that make this safe to bolt onto a real-time loop:

- Fire-and-forget request, never awaited synchronously. Coroutine resumes
  when/if a response lands.
- Every suggested action is checked against `legal_actions` (computed locally,
  at response time, not request time — the world may have moved on) before
  being queued. A suggestion referencing a now-invalid action is dropped, not
  patched or guessed at.
- `ttl_ticks` — if the response arrives after its own relevance window, it's
  discarded. Stale advice is worse than no advice.
- Response cache keyed by a coarse world-state hash, so repeated similar
  situations don't all pay the round-trip.
- Timeout → local planner's answer stands, nothing waits on the network.

## 7. Memory

- **Working memory**: ring buffer of the last N ticks' key events, feeds the
  Fast Core's considerations (e.g. "has this entity been hostile recently").
- **Episodic memory**: coarser, longer-lived log of goal outcomes
  (goal, context features, success/failure) — this is what Section 8's
  adaptation loop reads, and what a future "real" training pipeline on the
  user's servers would export.
- **Decay**: both use simple time-based decay/reinforcement (exponential
  weighting), not because it's the most powerful option but because it's cheap
  and has no training step — consistent with "no need to train it" for the
  Lua side.

## 8. Adaptation loop (not training — tuning)

Explicitly *not* machine learning. After each completed goal, nudge the
relevant consideration weights from Section 5 by a small step toward whatever
worked (reward = did the goal succeed, cheaply, without a reflex override
firing). This is the only thing that self-modifies at runtime, it's bounded
and reversible, and it's the natural seam where the user's actual trained
model (built externally) could later replace hand-tuned weights entirely.

## 9. Testing strategy (for once code exists)

A headless harness that runs the reasoning core against scripted/replayed
`WorldState` sequences with a mock adapter and a mock Brain Bridge (fixed
latency + fixed/garbage responses, to exercise the timeout and legality-filter
paths specifically) — decoupled entirely from any real game/engine, since
Section 3 is the only place engine specifics leak in.

## 10. Open questions (would sharpen every night after this one)

1. What runtime/engine hosts `cell4.lua`? (Determines the whole Adapter layer,
   and whether it's Lua 5.1/5.4/LuaJIT/Luau — table/coroutine behavior differs.)
2. What does this AI actually control — an NPC, a game-logic manager, a bot's
   decision layer, something else? Determines what "considerations" and
   "actions" actually are.
3. What's the tick/frame budget in practice (16ms? 100ms? per-command in a
   turn-based system)? Determines how aggressive the coroutine-spreading in
   Section 6 needs to be.
4. What does "the external server" already look like, if anything exists —
   is Brain Bridge designing a new protocol, or matching one that's already
   running on the user's side?

Until these are answered, later nights will deepen the pieces above
(GOAP planner details, the weight-tuning math, the wire format for Brain
Bridge) rather than guess at engine-specific specifics that would just get
thrown out.
