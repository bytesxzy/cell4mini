# cell4.lua architecture — nightly progress log

Newest entry on top. Each entry is what actually changed that night and why
— no forward-looking claims about what the system "will" do until it's
actually designed.

---

## Night 1 — 2026-09-05

**Context**: no `cell4.lua` or related design work existed anywhere in this
repo before tonight. Starting from a blank slate.

**Did**:
- Wrote `ARCHITECTURE.md`: overall shape of the reasoning system — a
  Behavior Tree for hard priority ordering (survive > engage > reposition >
  idle) layered with Utility AI for scoring choices within a priority
  category, a per-tick immutable Blackboard snapshot, and a single
  `WeightProvider` seam where externally-tuned numbers plug in later without
  touching control flow.
- Wrote four Luau interface/stub files under `interfaces/` (`Action.lua`,
  `Blackboard.lua`, `WeightProvider.lua`, `Reasoner.lua`) that give the
  architecture concrete, typed shape — not a working AI, just the contracts
  and tick-loop control flow the design implies.

**Explicitly not done / not guessed**:
- No actual game state, action list, or balance numbers — I don't know which
  game or genre `cell4.lua` targets, so I did not invent specifics. The
  architecture is written generically and flagged with its assumptions at
  the top of `ARCHITECTURE.md`.
- No training, no weight values, no ML of any kind — confirmed out of scope.

**Needs your input before next passes go further**:
1. Is the tick-model assumption right (throttled server tick, small
   enumerable action set), or is this closer to something else (e.g. a
   dialogue/companion AI, a puzzle solver, something continuous)?
2. What's the actual initial action list for the "Engage" category? Night 2
   was going to add a light multi-step planning layer on top of single-action
   scoring — that only makes sense once there's a real action set to plan
   over.
3. Is there an existing `cell4.lua` anywhere (not in this repo) that this
   should be reconciled against, rather than designed fresh?

If no correction arrives before the next run, tomorrow night proceeds on the
current assumptions and says so again rather than quietly treating them as
confirmed.

**Next planned (per ARCHITECTURE.md §7)**: Night 2 — multi-step tactics layer
above single-action utility scoring.
