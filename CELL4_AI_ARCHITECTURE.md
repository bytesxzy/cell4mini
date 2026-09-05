# CELL4 AI Reasoning — Architecture Log

This file is the memory for this project across nightly sessions. Each
night is a fresh Claude session with no recollection of prior nights except
what's committed to this repo. **Read this whole file first before doing
anything else**, then append tonight's entry at the bottom of the log
instead of rewriting history above it.

## Ground rules for every night

- `cell4.lua` is inference + reasoning **only**. Never add training code —
  training happens on the user's own servers, out of scope here. What this
  file *does* owe the trainer is data to learn from and a contract to learn
  against (`Pipeline:exportExperience`, `Pipeline:trainingContract`).
- **Nothing dead, nothing half-wired.** Every function must be reachable
  from a real code path and exercised by a test. Before committing, audit
  for unused functions and delete them rather than leaving them "for later."
  A capability described in a comment but not actually implemented counts
  as worse than dead code — that's the failure mode to avoid entirely.
- Every claim of progress in the log below must be backed by something
  runnable: `lua5.3 tests/cell4_smoke_test.lua` must pass before you write
  "done" next to anything. If a test fails or you're unsure something works,
  say so plainly — the standing instruction is "don't hallucinate."
- Keep changes additive where possible. Restructuring earlier work is
  allowed when it fixes a genuine design flaw, but the reason goes in the
  log, and the tests that pinned the old behaviour get updated deliberately,
  never deleted to make red turn green.
- Budget: default to direct implementation (Read/Edit/Bash), not
  multi-agent orchestration — this is a single-file Lua module and fanning
  it out across agents burns tokens for no benefit.
- Target runtime: Lua 5.1 / Luau-compatible syntax (this repo's portfolio
  mentions Roblox work, so assume the eventual host may be Roblox). Tested
  against a stock `lua5.3` interpreter (`apt-get install -y lua5.3`, not
  preinstalled in the session); avoid 5.3-only syntax (no `//`, no bitwise
  operators, no `<const>`/`<close>`) so it stays portable.

## The central distinction: goals vs. rules

This is the load-bearing idea in the design, and it was got *wrong* on
night 1 and fixed on night 2. Two different questions need two different
registries:

| | `registerGoal(name, weight, fn)` | `registerRule(action, weight, fn)` |
|---|---|---|
| answers | "how good is this **state**?" | "how much do I want this **action** now?" |
| examples | safety, vitality, progress | flee, heal, patrol |
| used by | `scoreState` → the **planner** | the reactive **vote** in `decide` |
| creates an action? | **no** | yes |

Collapsing them into one list (night 1's mistake) breaks both directions:
a state utility like "safety" leaks into the action ranking as a phantom
action the agent could try to "do," and constant action-preferences give
the planner nothing to tell futures apart with. Keep them separate.

## Current shape of `cell4.lua`

Single file, eight internal modules (Lua tables), in dependency order:

1. **Utils** — clamp/sigmoid/relu/tanh/dot/softmax/copyArray/sortScored.
   Pure functions. `softmax` subtracts the max before exponentiating
   (numerically stable on large logits). `sortScored` breaks ties on a
   string key: **decisions become training labels, so identical inputs must
   produce identical outputs across runs and machines.**
2. **RingBuffer** — fixed-capacity circular store with `recent(n)` (newest
   first) and `toArray()` (oldest first). Used by both Memory and Pipeline
   so wrap-around indexing lives in exactly one tested place.
3. **Memory** — recent observations plus a belief store whose confidence
   decays on a half-life. Clock is injectable, so the whole system shares
   one time source and tests drive time deterministically instead of
   sleeping.
4. **NeuralNet** — feedforward inference only. `new(layerSizes, activation,
   outputActivation)` builds zeroed weights (a pipeline can be wired and
   tested before a trained model exists); `loadWeights` validates shape
   *and* rejects non-numeric/NaN values; `describe()` reports the exact
   shape the trainer must produce; `forward()` runs the pass.
5. **Perception** — `normalize(raw, spec)` produces
   `{named, featureVector, raw, predicted}`: a name-keyed table for rule
   authors and a fixed-order vector for the network, from one declarative
   spec. `clone`/`withValues`/`withDelta` derive new states while keeping
   `named` and `featureVector` in sync — if those drift apart, the rules and
   the network are reasoning about different worlds. Derived states are
   flagged `predicted = true`: **the difference between planning and
   hallucinating is knowing which states you imagined.**
6. **Planner** — bounded beam search over registered actions
   (`preconditions` / `effects` / `cost`). Scores imagined states with the
   reasoner's *goals*, so lookahead and wanting share one definition of
   "good." Plans are scored as **average discounted utility per step**
   (accumulated discounted utility ÷ the discount sum at that depth), which
   is what makes a 1-step and a 3-step plan comparable instead of "longer
   always wins." Only the first action is ever acted on (receding horizon:
   re-plan each tick with fresh perception). Returns `nil` — rather than an
   arbitrary pick — when there are no actions, none applicable, or no goals
   to rank futures by.
7. **Reasoning** — the single place a decision is made. Three vote sources
   feed one ranking: `rule` (reactive preferences), `plan` (first step of
   the best sequence), `policy` (the trained net's softmaxed preferences).
   Votes for the same action name **add**. That's the anti-hallucination
   guardrail: a model or a plan can push a decision, but a documented rule
   can always outweigh it, and the trace attributes every contribution.
   `decide()` returns the winner plus the full ranked trace, and the winner
   carries `confidence` = margin over the runner-up ÷ winning score.
8. **Pipeline** — `step(rawSignals, reward)` chains
   perceive → smooth → remember → decide → hysteresis → confidence gate,
   and records the transition. Also `explain(result)` (human-readable
   trace), `trainingContract()`, `exportExperience()`, `clearExperience()`.

### Behaviour that isn't obvious from the module list

- **Temporal smoothing** (`smoothing = {feature = window}`): reasoning runs
  on a rolling average of the last N observations, while memory keeps the
  raw ones — so smoothing never feeds on its own output and can't compound
  into drift. Raw game telemetry is noisy and an agent that re-decides on
  every spike is useless. The result exposes both `state` (smoothed, what
  reasoning saw) and `observed` (what perception literally saw).
- **Hysteresis** (`switchMargin`): a challenger must beat the currently
  running action by the margin before the agent switches, which stops it
  stuttering between two near-equal options every tick. It never clings to
  an action that has stopped being a candidate or that scores zero.
- **Abstention** (`minConfidence` + `fallbackAction`): below the confidence
  floor the pipeline refuses to commit to its own top choice and falls back.
  It deliberately does *not* fire when hysteresis held the incumbent —
  continuing a prior commitment is a choice, not the coin-flip the floor
  exists to prevent.
- **Experience recording**: transitions are stored in the standard RL shape
  `(features, action, reward, nextFeatures)`. Because a step's reward is
  only known after it plays out, each step closes out the *previous* step's
  record — so the buffer only ever holds transitions that actually
  completed. Steps where no action was taken record nothing.

## Verified performance

~9,600 `step()` calls/sec (~0.10 ms/step) on the session's container, with
a 3-action planner at depth 3 / beam 4, two goals, three rules and smoothing
on. The planner dominates that cost (up to `beam × actions × depth` state
evaluations per step). Measured, not estimated — but on a dev container, so
treat it as a relative baseline rather than a number to quote.

## Explicitly NOT built yet

- No serialization format between the trainer and `NeuralNet:loadWeights`.
  It accepts a plain Lua table today, format-agnostic on purpose. The
  decision (JSON over HttpService? a Roblox DataStore blob? a flat string?)
  depends on how the servers will ship weights to the runtime.
- No integration with a real game loop or real signal sources — every test
  drives synthetic signals.
- `Planner` uses hand-written `effects` functions as its world model. A
  learned transition model would be strictly more powerful and is a natural
  future use of the recorded experience, but nothing supports that yet.
- No reward shaping helpers; `reward` is whatever the caller passes in.
- No memory of *episodes* (resets/deaths). Experience is one continuous
  stream, which will matter for bootstrapping value estimates in training.

## Plan for upcoming nights (a plan, not a promise — adjust as reality dictates)

- **Night 3**: Episode boundaries (`Pipeline:endEpisode()`), so transitions
  don't bridge across a death/reset and teach the model a false transition.
  This is a prerequisite for correct value bootstrapping and is arguably
  the biggest remaining correctness gap for training.
- **Night 4**: Concrete weight interchange format + round-trip test, and a
  matching contract-validation helper (`loadWeights` should be able to
  reject a model whose shape doesn't match the live `trainingContract`).
- **Night 5**: Richer perception — derived/composite features (ratios,
  deltas, time-since-event) declared in the spec, since raw signals alone
  are a weak input representation for a policy.
- **Night 6**: Performance pass for a live loop (cut per-step allocation,
  optionally cache plan results across ticks when the state barely moved).
- **Night 7**: Consolidation — re-read this log, fix any drift between what
  is documented and what is actually in `cell4.lua`, tidy up.

Each night should update "Explicitly NOT built yet" and this plan to match
reality rather than leaving them stale.

---

## Log

### Night 1 — 2026-09-05

Starting point: repo had no `cell4.lua` and no prior architecture notes —
confirmed via `git log --all --grep="cell4.lua" -i`, empty. This is
genuinely the first session on this, not a continuation.

Built a six-module skeleton (`cell4.lua`, ~350 lines) plus
`tests/cell4_smoke_test.lua`. Installed `lua5.3` in-session (none was
preinstalled) specifically so this could be executed rather than eyeballed
for syntax errors. All smoke tests passed as of that commit.

Verified concretely, not just asserted: ring-buffer wrap-around; belief
confidence decay; a hand-computed 2→2→1 forward pass; a goal function that
errors being contained without aborting the decision cycle; a policy net
measurably shifting a decision without removing the rule votes it competes
with.

Not started: planning/lookahead, the weights interchange format, real
signal integration, explainability formatting, performance tuning.

### Night 2 — 2026-09-05 (same session, continued at the user's request)

Test suite went from 24 to **1284 assertions**, all passing
(`ALL SMOKE TESTS PASSED (1284 checks)`). Roughly a thousand of those come
from the new 200-tick integration soak, which is deliberate: unit tests
cover each part alone, the soak is where interaction bugs surface.

**Design flaw found and fixed (breaking change).** Night 1's `registerGoal`
was doing two incompatible jobs — scoring states and voting for actions.
Split into `registerGoal` (state utility) and `registerRule` (action
preference); see the table near the top of this file. This was found by a
failing test, not by inspection: a planner attached to a reasoner whose
"goals" were constant action-preferences couldn't tell any future from any
other and silently picked alphabetically. Fixing the conflation was the
right call over patching the test, because the phantom-action bug would
have put junk entries in the action contract the trainer indexes against.
**If any code outside this repo already calls `registerGoal` expecting an
action vote, it needs to move to `registerRule`.**

**Bug found and fixed during review, worth calling out:** with smoothing
enabled, `features` was recorded from the smoothed state but `nextFeatures`
from the raw observation, so every `(s, a, r, s')` tuple had its two halves
in different representations. That would have quietly poisoned training
without ever failing loudly. Now both come from the smoothed view, pinned
by a test asserting one step's `s'` is exactly the next step's `s`.

Added this night:
- **Planner** (module 6 above) — beam-search lookahead, cost-penalized,
  depth-normalized so plan lengths compare fairly. Erroring preconditions
  count as "not applicable" rather than being assumed true; erroring
  effects skip that branch instead of taking the plan down.
- **Confidence + abstention** — decisions carry a margin-based confidence,
  and the pipeline can fall back rather than coin-flip a near-tie.
- **Hysteresis** — anti-stutter commitment to the running action.
- **Temporal smoothing** — reasoning on a rolling average, raw kept in
  memory.
- **Experience recording + `trainingContract()`** — the runtime now emits
  trainer-ready transitions and declares feature order, action indices and
  policy shape, so a training run can't silently mismatch the runtime it
  deploys into.
- **`explain()`** — renders a decision, its confidence, its plan and the
  full attributed trace as text a human can read in a log.
- **`RingBuffer`** — extracted so Memory and Pipeline share one tested
  implementation.

Dead-code audit run before committing (every `function` in the file
cross-referenced against call sites in source and tests). It found
`Utils.lerp` unused — **deleted** rather than kept "for later" — and found
that `sigmoid`/`tanh` were reachable but untested, so tests were added
pinning them to reference values. It also surfaced that `Memory`'s comments
claimed it existed to stop the agent reacting to one noisy signal while
nothing in the core actually used it that way; smoothing and hysteresis are
what make that claim true, and they are the reason `recentContext`,
`remember` and `recall` are now load-bearing rather than decorative.

Behaviour spot-checked on unambiguous scenarios rather than assumed:
calm+healthy → `patrol`, heavy threat → `flee`, badly hurt+safe → `heal`,
and hurt **and** threatened → `flee` at confidence 0.39 versus ~0.88 for
the clear-cut cases. That the confidence signal drops on a genuine dilemma
is the evidence that it means something.

Still not started: everything under "Explicitly NOT built yet" above.
Episode boundaries are the most important of those for training
correctness, which is why they lead the plan for night 3.
