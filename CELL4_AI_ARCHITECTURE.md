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
4b. **PolicyFormat** — the trainer ↔ runtime interchange: a line-based text
   format carrying the training contract alongside the weights. Parsed by
   hand, deliberately **not** a Lua chunk run through `load()` (that would
   execute whatever arrives, and Roblox disables `loadstring` anyway) and
   deliberately not JSON (no library, no host-specific API needed). Malformed
   input returns `(nil, reason)` rather than raising — a bad model file is an
   expected condition. `tools/export_policy.py` is the trainer-side half.
5. **Perception** — `normalize(raw, spec, previous)` produces
   `{named, featureVector, raw, predicted, featureErrors}`: a name-keyed
   table for rule authors and a fixed-order vector for the network, from one
   declarative spec. `clone`/`withValues`/`withDelta` derive new states while
   keeping `named` and `featureVector` in sync — if those drift apart, the
   rules and the network are reasoning about different worlds. Derived states
   are flagged `predicted = true`: **the difference between planning and
   hallucinating is knowing which states you imagined.**

   Spec entries are either raw (`{key, min, max}`) or **derived**
   (`{key, derive = function(features, previous)}`), computed in spec order
   so a derived feature can build on any declared before it. Derived features
   exist because a single frame is not a sufficient state: "health 50 and
   falling" and "health 50 and rising" are the same raw vector but call for
   opposite actions, and **no amount of training recovers a distinction the
   input representation cannot express.** `Perception.delta(key, scale)` is
   the built-in trend feature (0.5 = unchanged). `recomputeDerived` keeps
   imagined states self-consistent — the planner calls it after every action's
   effects, so a goal reading a trend during lookahead sees the trend that
   action would create rather than one left over from the real world.
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
- **Episode boundaries** (`Pipeline:endEpisode(finalReward)`): without this,
  the last action of one life is recorded as transitioning into the first
  state of the next — a transition that never happened, which teaches a
  bootstrapping value estimator that dying leads to respawning. The final
  transition is closed as terminal (`done = true`, no `nextFeatures`), which
  is the signal a trainer needs to stop bootstrapping there. The boundary
  also resets what must not leak between lives: the committed action (so
  hysteresis doesn't hold an action from a previous life) and recent
  observations (so smoothing doesn't average the old life's telemetry into
  the new one). Beliefs written by rules survive, since knowledge learned in
  one episode may legitimately carry forward.

## Verified performance

~9,600 `step()` calls/sec (~0.10 ms/step) on the session's container, with
a 3-action planner at depth 3 / beam 4, two goals, three rules and smoothing
on. The planner dominates that cost (up to `beam × actions × depth` state
evaluations per step). Measured, not estimated — but on a dev container, so
treat it as a relative baseline rather than a number to quote.

## How to actually train against this

1. Build the pipeline (spec, goals, rules, planner) and run the agent.
2. `pipeline:policyTemplate({16, 16})` → the exact input order, action order
   and layer shape your trainer must produce.
3. `pipeline:exportExperience()` → `{contract, records}` where each record is
   `(features, action, actionIndex, reward, nextFeatures, done, episode)`.
   Ship those to the training servers. `done = true` means terminal: no
   `nextFeatures`, do not bootstrap past it.
4. Train off-box. Nothing in this repo does that, by design.
5. Export with `tools/export_policy.py` → a `.cell4` text file.
6. `pipeline:loadPolicy(text)` → `true`, or `false, reason` if the model's
   features or actions have drifted from the runtime. **A refusal is the
   system working.** Don't hand-edit the header to get past it; regenerate
   against the current template instead.

## Explicitly NOT built yet

- No integration with a real game loop or real signal sources — every test
  drives synthetic signals.
- `Planner` uses hand-written `effects` functions as its world model. A
  learned transition model would be strictly more powerful and is a natural
  future use of the recorded experience, but nothing supports that yet.
- No reward shaping helpers; `reward` is whatever the caller passes in.

## Plan for upcoming nights (a plan, not a promise — adjust as reality dictates)

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

### Night 3 — 2026-09-05 (same session, continued while the user was away)

Brought forward from the night-3 plan: **episode boundaries**, the largest
remaining correctness gap for training. `Pipeline:endEpisode(finalReward)`
closes the outstanding transition as terminal (`done = true`, no
`nextFeatures`) and resets exactly what must not leak between lives — the
committed action and recent observations — while leaving rule-written
beliefs intact. Added `Memory:forget` and `Memory:clearObservations` to
support it; both are load-bearing, not speculative API.

The guarantee is pinned two ways: directly (a death mid-run, asserting the
new life neither inherits the old commitment nor smooths across the
boundary), and structurally in the soak, which now dies every 37 ticks and
asserts across all 64 exported records that an episode never ends without a
terminal record and a terminal record never sits mid-episode.

Tests: 1284 → **1368 assertions**, all passing. Dead-code audit re-run
clean before commit.

Still not started: everything under "Explicitly NOT built yet" above.

### Night 4 — 2026-09-05 (same session, continued while the user was away)

Closed the loop between the training servers and the runtime.

- **`PolicyFormat`** (module 4b above) — encode/decode for the interchange
  format, with a hand-written parser that only ever reads numbers and names.
  Malformed input returns `(nil, reason)`; a test feeds it a line containing
  `sabotage()` to pin that nothing in a model file is ever executed.
- **`Pipeline:loadPolicy(textOrBundle)`** — the part that actually matters.
  A model whose feature order or action set has drifted still produces
  numbers; they just mean something else now, which yields an agent that is
  confidently wrong. Loading is refused unless features match the perception
  spec exactly in order, actions match the runtime's action set exactly in
  order, and the layer shape chains from `#features` to `#actions`. Each
  refusal names the specific drift. A rejected load leaves any
  already-working policy untouched (tested).
- **`Pipeline:policyTemplate(hiddenSizes)`** — hands the trainer the exact
  contract to build against, so the refusal above is avoidable rather than
  a guessing game.
- **`tools/export_policy.py`** — dependency-free reference exporter for the
  trainer side, which validates shapes there too and preserves full float
  precision (`repr()`, which round-trips a double exactly — quantizing on
  export is silent model drift).
- **Cross-language contract test** — `tests/fixtures/golden_policy.cell4` is
  produced by the Python exporter and parsed by the Lua suite, with both
  sides checking it independently. Verified end-to-end for real, not
  assumed: Python wrote a policy, Lua validated and loaded it, and the
  policy measurably drove the decision (0.972 weight on `flee` at threat 95).
- **`tests/run_all.sh`** runs both suites.

**Bug found and fixed, and this one was live.** The golden fixture carries a
weight of 123456.75, and loading it produced NaN. Cause: `Utils.tanh` used
the naive `(e^2x - 1)/(e^2x + 1)`, which overflows to `inf/inf = NaN` for
large inputs instead of saturating to 1. One NaN activation propagates
through the whole forward pass and destroys every decision downstream — and
large weights are exactly what training produces, so this would have
detonated on the first real model rather than on any toy example. Rewritten
to branch on the sign so the exponent stays negative and underflows
harmlessly. All activations are now pinned at ±1e300 against both NaN and
range violations, plus a full forward pass with 1e9 weights.

That bug is the argument for testing with realistic values: every earlier
test used weights around 1, and all of them passed against the broken
implementation.

Tests: 1368 → **1468 Lua assertions + 9 Python**, all passing. Dead-code
audit clean.

### Night 5 — 2026-09-05 (same session, continued while the user was away)

**Derived features**, brought forward from the night-5 plan. This is a
representational fix rather than a feature: the input vector previously had
no history in it at all, so "health 50 and falling" and "health 50 and
rising" were literally the same input. That is a ceiling on what any trained
policy can learn, however good the training run is, and it was worth fixing
before training starts rather than after.

Spec entries may now be derived (`{key, derive = fn}`), computed in order so
they can build on earlier features, with `Perception.delta(key, scale)` as
the built-in trend. A `derive` that throws or returns a non-number yields a
neutral 0 and is recorded in `state.featureErrors`, which `explain()` prints
as `BROKEN FEATURE` — consistent with how broken rules and goals are handled
everywhere else: contained, but never silent.

Two consistency rules fall out of this and are both tested:
- **Episode boundaries clear the previous tick.** A delta measured across a
  death is change that never happened, exactly like the bridged transition
  fixed on night 3.
- **The planner recomputes derived features on imagined states**
  (`Perception.recomputeDerived`). Without it, an action's effects move the
  base features while a trend keeps the value it had in the real world, so a
  goal evaluating that imagined future reads a fact from a different
  timeline. Pinned by a test where the only goal reads the derived trend: the
  planner picks the action that *creates* a falling trend, which is only
  possible if imagined states recompute.

Derived features are flagged in `trainingContract()` (`derived = true`,
range [0,1] by construction) so the trainer knows which inputs are computed
rather than sensed. The integration soak now runs a derived trend through
the whole stack — smoothing, planning, policy voting and experience export.

Tests: 1468 → **1504 Lua assertions + 9 Python**, all passing. Dead-code
audit clean. Throughput unchanged at ~9,900 steps/sec.
