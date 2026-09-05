# Nightly progress log — cell4.lua AI reasoning architecture

Format: one entry per run. Each entry states what was verified, what was
added/changed, and what's still open — so the next night doesn't re-derive
context or, worse, silently contradict a decision already made.

---

## Night 1 — 2026-09-05

**Verified (not assumed):** searched the full repo, all branches, entire git
history — there is no `cell4.lua` file, no prior architecture notes, no spec
for what engine/game this targets. This is a genuinely fresh start, not a
continuation of unseen prior work.

**Added:** `ARCHITECTURE.md` — a first-draft, engine-agnostic layered design:
adapter boundary, world-model blackboard, a fast synchronous utility-AI core,
a deliberative GOAP-style planner, an async "Brain Bridge" to an external
server (for the user's own model/training work), memory with decay, and a
bounded runtime weight-tuning loop that is explicitly not training.

**Reasoning for the two-speed split:** the brief says training happens on the
user's own servers and this side shouldn't need it — that only works cleanly
if the real-time Lua loop never blocks on the external call, always has a
fast local answer, and treats anything the external side suggests as
untrusted input to be checked against a locally-computed legal-action list
before it's ever executed. That constraint shaped most of Sections 5–6.

**Open, blocking further specialization** (see ARCHITECTURE.md §10):
target engine/runtime, what the AI actually controls, the real tick budget,
and whether an external server protocol already exists to match rather than
design fresh. Answering any of these turns the next few nights from "design
in the abstract" into "design for the actual thing."

**Plan for upcoming nights** (subject to revision once the above is answered):
- Night 2: flesh out the GOAP planner (action schema, search bound per tick).
- Night 3: memory decay/reinforcement math, concretely.
- Night 4: Brain Bridge wire format + caching key design.
- Night 5: failure-mode catalogue (timeout, garbage response, thrashing) and
  the guardrail for each.
- Night 6: headless test-harness design (Section 9), so implementation (when
  it happens, on the user's side) has something to validate against.
- Night 7: consolidate, prune anything that turned out over-designed for the
  real target once it's known.
