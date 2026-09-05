# CELL4 AI Reasoning — Architecture Log

This file is the memory for this project across nightly sessions. Each
night is a fresh Claude session with no recollection of prior nights except
what's committed to this repo. **Read this whole file first before doing
anything else**, then append tonight's entry at the bottom of the log
instead of rewriting history above it.

## Ground rules for every night

- `cell4.lua` is inference + reasoning **only**. Never add training code —
  training happens on the user's own servers, out of scope here.
- Every claim of progress in the log below must be backed by something
  runnable: `lua5.3 tests/cell4_smoke_test.lua` must print
  `ALL SMOKE TESTS PASSED` before you write "done" next to anything.
  If a test fails or you're not sure something works, say so plainly —
  the instruction from the user was explicitly "don't hallucinate."
- Keep changes additive and reversible. This is architecture exploration,
  not a rewrite-everything exercise — don't restructure prior nights' work
  without a concrete reason, and note the reason in the log if you do.
- Budget: default to direct implementation (Read/Edit/Bash), not
  multi-agent orchestration — this is a small single-file Lua module and
  fanning it out across agents burns tokens for no benefit.
- Target runtime: Lua 5.1 / Luau-compatible syntax (this repo's portfolio
  mentions Roblox work, so assume the eventual host may be Roblox). Tested
  here against a stock `lua5.3` interpreter since that's what's available
  in-session; avoid 5.3-only syntax (no `//`, no bitwise operators, no
  `<const>`/`<close>`) so it stays portable.

## Current shape of `cell4.lua`

Single file, six internal modules (Lua tables), in dependency order:

1. **Utils** — clamp/lerp/sigmoid/relu/tanh/dot/softmax. Pure functions,
   no state.
2. **Memory** — a fixed-capacity ring buffer of recent observations
   (`pushObservation` / `recentContext`) plus a belief store
   (`remember` / `recall`) where confidence decays with a half-life
   instead of beliefs just vanishing or staying stale forever.
3. **NeuralNet** — feedforward inference only. `NeuralNet.new(layerSizes,
   activation, outputActivation)` builds zeroed weight tables (so a
   pipeline can be wired and tested before any trained model exists);
   `loadWeights({layers = {...}})` validates shape and copies in weights
   produced externally; `forward(input)` runs the pass.
4. **Perception** — `normalize(rawSignals, spec)` turns arbitrary raw
   signals into a `{named=, featureVector=, raw=}` state object: a
   name-keyed table for rule authors, a fixed-order vector for the neural
   net, both from one declarative spec.
5. **Reasoning** — goal-based utility scoring. Each goal is
   `(name, weight, evaluate(state, memory) -> score[0,1], rationale)`.
   `evaluate()` returns every goal's score *and why*; a goal that throws
   scores 0 with the error captured in the trace rather than crashing the
   decision cycle. A loaded policy `NeuralNet` can be attached
   (`attachPolicy(net, actionNames)`) and contributes one more scored vote
   per output — it adds to a rule's score for the same action name rather
   than overriding rules, so a trained model can nudge decisions but never
   silently replace the hand-authored logic. `decide()` combines
   duplicate-named votes and returns `(topChoice, fullRankedTrace)`.
6. **Pipeline** — `step(rawSignals)` chains perception → memory → decide
   and returns `{decision, score, trace, state}` in one call, so a caller
   (or a human reading logs) always has the "why" alongside the "what."

`tests/cell4_smoke_test.lua` exercises all six modules, including the
"erroring goal doesn't crash the cycle" path and the "policy vote combines
with a rule vote" path. Run it from the repo root:
`lua5.3 tests/cell4_smoke_test.lua`.

## Explicitly NOT built yet

- No planning/lookahead (e.g. GOAP, multi-step search) — Reasoning is
  currently single-step utility scoring only.
- No serialization format defined for how the external trainer's weights
  reach `loadWeights()` in practice (file? Roblox DataStore? HTTP?) —
  `loadWeights` accepts a plain Lua table today, format-agnostic on
  purpose until this is decided.
- No integration with an actual game loop / real signal sources — Pipeline
  is exercised only with synthetic test signals so far.
- No performance profiling for a live game environment (table churn per
  `step()` call, GC pressure) — correctness first, tuned later.

## Plan for upcoming nights (adjust as reality dictates — this is a plan, not a promise)

- **Night 2**: Multi-step planning on top of Reasoning (goal-oriented
  action sequencing), so decisions aren't purely reactive frame-to-frame.
- **Night 3**: Define and implement a concrete weight-export/import format
  between the external trainer and `NeuralNet:loadWeights`, with a
  round-trip test.
- **Night 4**: Perception spec authoring ergonomics + a couple of realistic
  example signal sets (still synthetic, but shaped like plausible game
  telemetry) to stress-test Reasoning against more than toy inputs.
- **Night 5**: Debug/explainability tooling — a human-readable trace
  formatter for `Pipeline:step()` output, since "explainable decisions"
  is a stated design goal but today the trace is just raw tables.
- **Night 6**: Performance pass for a live-loop context (avoid per-step
  table allocation where it's cheap to, benchmark `forward()` and
  `decide()` costs).
- **Night 7**: Consolidation — re-read this whole log, fix any drift
  between what's documented and what's actually in `cell4.lua`, tidy up.

Each night should update "Explicitly NOT built yet" and this plan to match
reality rather than leaving them stale.

---

## Log

### Night 1 — 2026-09-05

Starting point: repo had no `cell4.lua` and no prior architecture notes —
confirmed via `git log --all --grep="cell4.lua" -i`, empty. This is
genuinely the first session on this, not a continuation.

Built the six-module skeleton described above in one file
(`cell4.lua`, ~350 lines) plus `tests/cell4_smoke_test.lua`. Installed
`lua5.3` in-session (none was preinstalled) specifically so this could be
executed rather than eyeballed for syntax errors. All smoke tests pass as
of this commit — output was literally `ALL SMOKE TESTS PASSED`, not
inferred from reading the code.

What was verified concretely, not just asserted:
- Ring buffer memory wraps correctly at capacity and returns newest-first.
- Belief confidence decay math (`0.5^(age/halfLife)`) behaves as expected
  at a negligible-decay half-life.
- A hand-computed 2→2→1 feedforward pass (identity hidden layer, sum
  output layer) matches the network's output exactly.
- A goal function that errors is caught and scored 0 without aborting the
  rest of the decision cycle.
- Attaching a policy net whose forward pass strongly favors one action
  measurably shifts the combined decision toward that action, without
  removing the rule-based votes it's competing against.

Not started: planning/lookahead, the weights interchange format, real
signal integration, explainability formatting, and performance tuning —
all deferred per the plan above, not because of a blocker.
