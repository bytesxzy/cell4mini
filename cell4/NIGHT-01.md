# Night 1 — 2026-09-05

Scope: understand the system, establish a measured baseline, and fix the thing that was
preventing every other improvement from being measurable. No training was run.

Environment: LuaJIT 2.1.1703358377, Lua 5.4.6, 4 cores. Build under analysis is the uploaded
server tree (`cell4_1.zip`), preserved unmodified in `upstream/`.

---

## The headline

**The system's real ARC ability is 46/550 (8.36%). It has been reporting 0.0% for 67
generations because of how the benchmark window is selected, not because of what it can solve.**

That number is a hard veto clause in the acceptance rule, so the defect also silently disabled
the system's only guard against overfitting to its own synthetic tasks.

Fixed, measured, and shipped in `cell4.lua` (this directory). At the exact production budget the
same champion now finds real ARC tasks where it previously found none.

---

## 1. Baseline, re-measured

Not taken from `HISTORY.md` — re-run here:

    $ luajit cell4.lua selftest      → OK
    $ luajit cell4.lua eval
    train         99/130 solved  partial 0.89  nodes 821  4.9s
    heldout      190/260 solved  partial 0.87  nodes 810  9.1s
    adversarial   24/ 32 solved  partial 0.94  nodes 851  2.7s
    regression     0/  0

Held-out is 190/260 at the config default budget but 181/260 at the production throttle
(`CELL4_NODES=800 CELL4_SECONDS=1`). Both numbers are correct; the throttle costs 9 solves. The
acceptance rule is unaffected, because champion and candidate are always compared under the same
`budget_profile`.

Full local ARC corpus, `nodes=2500 seconds=4`:

    RESULT solved=46 n=550 pct=8.36 partial=0.1216

## 2. Why it reported 0.0%

`benchmarks.load_external(root, cap)` listed `rsi/data/arc`, **sorted the filenames, and took the
first `cap`**. `run-once.sh` sets `CELL4_EXTERNAL_CAP=20`. The earliest solvable task sits at
sorted position **31** (`arc1_1cf80156`).

So the evaluated window was positions 1–20, which contains **zero solvable tasks by construction**.
The reported figure was measuring the alphabet, not the solver.

Three independent confirmations:

1. Running the champion on the old fixed window at the production budget gives exactly `0/20`.
2. `HISTORY.md` generation 6 records **"4 of 50 right (8.0%)"**, from a period when the cap was 50.
   Solvable tasks at sorted positions ≤ 50 are exactly {31, 32, 36, 49} — **four**. The recorded
   history matches the mechanism precisely.
3. Generations 7–73, with cap back at 20, all record 0/20.

### It was not cosmetic

`decide()` (upstream `cell4.lua:3911`) has this as acceptance clause 2:

```lua
if cand.external.n > 0 and cand.external.solved < champ.external.solved then
  return false, "external ARC dropped ..."
```

Since `champ.external.solved` was always 0, the clause could never fire. The designed guard
against overfitting to self-generated families has been inert for the entire run.

## 3. The fix

All changes are kernel-side (see §5 for why that matters). 143 changed lines, 6 hunks.

- **Rotating window.** `load_external(root, cap, seed)` now draws a deterministic,
  seed-derived, prefix-stratified sample (`arc1_`/`arc2_` proportionally). Same cost per
  generation; every task is eventually scored. Seeded on the generation, so the window is fixed
  *within* a generation — champion and every candidate see identical tasks — and rotates between
  them. `seed == nil` reproduces the old prefix exactly, which is what `selftest` relies on.
- **Digest-keyed caching.** The champion cache and the generation-over-generation delta both
  compared task *count*, which was sound only while the window was a fixed prefix. Two different
  samples of size 20 are not the same measurement. Both now key on `external_digest`, a hash of
  the actual task ids. Held-out and regression are cached separately from the external score, so
  rotating the window no longer discards a valid 260-task held-out measurement.
- **Cumulative ARC coverage.** Any single rotating window is a sample, so the durable progress
  measure is the set of distinct ARC tasks ever solved. Monotone, immune to the luck of the draw.

### Measured effect

Same champion, same code, same production budget (`nodes=800 seconds=1`, `cap=20`) — only the
window differs:

    FIXED  prefix window   cap=20  solved 0/20
    gen  1 rotating        cap=20  solved  1/20   cumulative distinct  1
    gen  2 rotating        cap=20  solved  2/20   cumulative distinct  3
    gen  3 rotating        cap=20  solved  5/20   cumulative distinct  7
    ...
    gen 10 rotating        cap=20  solved  1/20   cumulative distinct 11
    TOTALS over 10 generations: 13 solve-events, 11 distinct ARC tasks discovered

Two real generations end-to-end on the patched build at production settings, exit 0:

    gen 74 champion 04da6714: held-out 181/260, ..., ARC 3/20
    ARC coverage: 3 of 550 ARC tasks solved at least once (+3 new this generation)
    gen 75 champion 04da6714: held-out 181/260, ..., ARC 1/20
    ARC coverage: 4 of 550 ARC tasks solved at least once (+1 new this generation)

`selftest` still passes. Held-out is served from cache and unchanged at 181/260, so the patch
does not disturb the acceptance path.

### Edge cases and coverage, checked

    cap=0    seed=1     -> 0 tasks, no error        cap=549   seed=7 -> 549
    cap=0    seed=nil   -> 0 tasks, no error        cap=550   seed=7 -> 550
    cap=1    seed=1     -> 1 task                   cap=10000 seed=7 -> 550 (clamped to corpus)
    cap=20   seed=nil   -> arc1_007bbfb7 first, i.e. the old prefix exactly
    same seed twice     -> IDENTICAL window (deterministic, so a generation stays reproducible)
    seed 42 vs 43       -> DIFFERENT windows (it really does rotate)

    coverage over 200 generations at cap=20: 550/550 distinct tasks drawn,
    per-task draws min=1 max=16

The last line is the property that matters: the window is not merely different each generation,
it genuinely sweeps the corpus. At the cron cadence in `run-once.sh` (every 30 min, ~48
generations/day) the whole 550-task corpus is covered in under two weeks, and the cumulative
coverage counter makes that progress legible without ever comparing two different samples.

## 4. Why the self-improvement loop has accepted 0 of 76 candidates

Investigated separately and **the acceptance rule is not the problem**. Pooled over every
candidate ever evaluated, mutations won 908 held-out tasks and lost 987 — net −79, two-sided
binomial p = 5.7e-05 against the hypothesis that they are neutral. The mutations are
significantly *harmful* on average, so rejecting all 76 is the correct outcome. The best
candidate ever (gen 51) reached +2.69pp with sign-test p = 0.155; the smallest p ever produced
was 0.145, never within a factor of 2.9 of alpha.

Calibration, computed by running the shipped stats code: the floor is 5 wins / 0 losses
(+1.92pp); at the churn actually observed (median 14 losses per candidate) acceptance needs
27 wins vs 15 losses (+4.62pp); 80% power arrives only at a true +5pp effect.

### The mechanical cause, and where the real reasoning gain is

Evaluation was verified bit-deterministic at the production budget, so the ~25 flipped held-out
outcomes per candidate (9.6% of 260) are **real behavioural churn**, not noise. The reason is in
`search.lua`:

```lua
if s then return { program = s, nodes = nodes, partial = 1 } end
```

The search returns the **first** program consistent with the training examples and never
considers alternatives. Every mutation operator works by changing enumeration *order* — op costs,
whitelists, constant pools, library entries — so it changes *which* of the many train-consistent
programs is found first. A different program generalises differently to the held-out test
example, essentially at random. Three lineage rows (gens 57, 66, 68) show `nodes_ratio` exactly
1.0 alongside 10 wins and 10 losses: identical work, different program chosen.

Worse, the alternatives are not merely ignored — they are **structurally invisible**. The
observational-equivalence dedup keys on the signature of a program's outputs over the *training
inputs*:

```lua
local key = ty .. "|" .. table.concat(parts, ";")
if seen[key] then return nil end
seen[key] = true
```

Every train-consistent program produces exactly the training targets, so all of them collapse to
one key. The first is returned; any later one is discarded as a duplicate before it is ever
compared. Collecting alternatives requires a deliberate exemption at the target key.

## 4a. How much is that worth? Measured, and the answer differs by benchmark

`evaluate.run` already records `overfit_train` — the solver returned a program fitting every
training example that then failed the test example. Running that over both benchmarks
(`bench/measure_overfit.lua`) decomposes the failures:

| | held-out (260, production budget) | real ARC (550, nodes=2500 s=4) |
| --- | --- | --- |
| solved | 181 (69.6%) | 46 (8.4%) |
| **train-consistent but wrong** | **15 (5.8%; 19.0% of failures)** | **2 (0.4%; 0.4% of failures)** |
| no program in reach at all | 64 (24.6%) | 502 (91.3%) |

**The two benchmarks fail for entirely different reasons, and this is the most important fact of
the night.**

- On its own generated families, roughly one failure in five *looks* like a **selection**
  failure: a program consistent with training was found and it was the wrong one. See §4b — when
  probed, most of these turn out to be reach failures in disguise.
- On real ARC, selection is almost irrelevant: **91.3% of tasks have no consistent program in
  reach at any budget**. Nothing about choosing better among consistent programs helps there.
  This independently reproduces the system's own recorded finding that failures are
  *"reach-limited, not ordering-limited"* (13× the node budget bought +4.4pp).

## 4b. I then tested the selection lever, and it is much weaker than that table suggests

Rather than assume those 15 tasks were recoverable, I probed them
(`bench/probe_selection.lua`): re-solve each with the op-cost table jittered — which is exactly
what a mutation operator does — and see whether any restart returns a program that also satisfies
the *test* example.

    of 15 wrongly-chosen tasks, a CORRECT program was reachable in 5 (33%)
    plurality vote across restarts would have been right on 1, wrong on 14
    ceiling for a perfect selection rule: +1.9pp held-out (5 of 260 tasks)

Two corrections to what I wrote above, both of which cut against the more interesting story:

- **The ceiling is +1.9pp, not +5.8pp.** In 10 of the 15, *no* perturbation produced a correct
  program: the consistent set simply does not contain the right answer. Those are reach failures
  wearing a selection failure's clothes. +1.9pp sits exactly on the +1.92pp acceptance floor, so
  even a perfect selection oracle would only barely clear the bar, and only if it introduced no
  losses at all.
- **The obvious implementation actively fails.** Plurality voting across restarts picks correctly
  in 1 case out of 15. That is not noise, it is a mechanism: the most *frequent* program under
  cost perturbation is the one the learned cost prior favours, which is the same wrong one. Where
  a correct sibling exists it is rare, so frequency is anti-correlated with correctness. Any
  ensemble scheme that weights by agreement would be worse than what the system does today.

So the honest decomposition of held-out failure is not 5.8% selection / 24.6% reach. It is
roughly **1.9% selection, 28.5% reach** — and on real ARC it is 0.4% / 91.3%.

**Reach is the lever on both benchmarks.** That is the single most useful thing measured tonight,
and it is the opposite of where the churn evidence alone would have pointed.

Selection is still worth something, but for a different reason than score: a selection rule that
is *invariant* to cost perturbation (canonical choice among the consistent set) would decouple
held-out outcomes from enumeration order, which is what the ~25-flip churn is made of. Tasks
returning one program across all 8 restarts are stable; those returning 4–6 are the churn
sources. Cutting churn lowers the acceptance bar from +4.62pp toward the +1.92pp floor. That is a
**stability** argument, not an accuracy one, and it should be made and measured as such.

### The two levers, corrected

1. **To improve reasoning** → **DSL reach**. 91.3% of real ARC and ~28.5% of held-out have no
   correct program in the consistent set at any budget. This is the lever the original request is
   about, and it is gated on the genome-migration problem in §5.
2. **To unstick self-improvement** → **stabilise selection** so mutations stop reshuffling
   outcomes. Expected gain in score ≈ 0; expected gain in *statistical power* is the point.

## 4c. What reach actually costs: a one-line change worth +4 ARC tasks, and seven primitives worth +27

Since reach is the lever, the question is what to add. Two results.

### The colour pool stops at 5 — verified here, not taken on trust

`rsi/genome/policy.lua:13` reads `consts = { I = { 0, 1, 2, 3 }, C = { 0, 1, 2, 3, 4, 5 } }`, and
line 18 has `derived_consts = false`. The colour slots of `recolor`, `fill_nonzero`, `add_border`,
`const_grid` and `count_color` can therefore never receive 6–9. ARC uses ten colours. Tasks
needing a literal 6, 7 or 8 are outside the hypothesis space at any budget.

I changed that one line to `C = { 0,...,9 }` and re-ran the whole corpus at identical budget:

    baseline           RESULT solved=46 n=550 pct=8.36 partial=0.1216
    colours 0-9        RESULT solved=50 n=550 pct=9.09 partial=0.1293

**+4 tasks, no losses, one line.** Examples it could not previously write at all:
`recolor($,#6,#2)` and `recolor($,#7,#5)` — single-op programs.

Note carefully why this was not found by the system itself: `mechanisms.lua` records *"wider
constant pool — −3.5pp adding integers 4..9"* and so never re-proposes it. That measurement was
taken on the **synthetic** distribution, where generated values are small and already pooled. It
does not transfer to ARC, which uses all ten colours. The rejection list is doing its job for the
benchmark it was measured on, and generalising it to ARC is wrong. Better still would be
`derived_consts = true`, which mines literals from the task's own I/O pairs; that code path exists
and is dead today.

**Caveat:** this is a `policy.lua` change, so per §5 it does **not** ship by dropping in a new
`cell4.lua` — it must be applied to the genome on the server, or proposed by an adoption operator.
I have not measured its effect on the held-out split, where the −3.5pp precedent suggests it could
cost something. That measurement must happen before it is adopted permanently.

### Seven primitives put 27 of the 504 unsolved ARC tasks in reach

From an exhaustive sweep over the unsolved set, with each candidate program checked against the
held-out test pair (26 of the 27 also pass test, not just train):

| primitive | signature | unsolved tasks it reaches |
| --- | --- | --- |
| `mask_and` / `mask_or` / `mask_xor` / `mask_nor` | `(G,G,C) -> G` | **14** |
| `fill_periodic` | `(G,C) -> G` | 6 |
| `fill_symmetry` + `crop_diff` | `(G,C) -> G`, `(G,G) -> G` | 4 |
| `fill_holes` | `(G,C) -> G` | 3 |

That is 46/550 → **73/550 (13.3%)**. Worked example, verified on train and test:
`mask_or(top_half($), bottom_half($), 3)` solves `arc1_ce4f8723` — two panels split by a separator
row, combined cellwise. The DSL's only two-grid cellwise op is `overlay`, which is an OR that
keeps colours; there is no AND, XOR or NOR, so that whole ARC family is unreachable.

`fill_holes` is worth calling out because it exposes a structural blind spot rather than a missing
convenience: `components` (cell4.lua:902) walks **only non-zero cells**
(`if g[r][c] ~= 0 and not seen[r][c]`). Nothing in the DSL can ask whether a *background* region
is enclosed, so "colour the inside of every closed shape" is inexpressible at any depth.

### And the honest ceiling on that strategy

196 of the 504 unsolved tasks have ≥3 connected objects in every train input, and 19 need two
objects in the *same* grid recoloured differently. The catalogue has exactly four object-aware ops
(`object_count`, `keep_largest`, `keep_smallest`, `largest_object_size`) and **every one collapses
the object set to a single scalar or a single object**. The type universe is `{B, C, G, I, L}`
with max arity 3, no function type and no list-of-grids type, so "apply a different function to
each object depending on its properties" is not a composition of existing primitives at any depth.

That is not a missing primitive, it is a missing *type*. Fixing it means adding a type to the
catalogue plus `objects`, `sort_objects`, `nth_object`, `paint_objects` and a map combinator —
touching `def`, the per-type banks in `search.lua`, the OE signature function and the inverse
tables. **A kernel change, not a genome mutation, which is a large part of why 73 generations of
genome mutation never found it.** It bounds "add primitives" at roughly 46 → 75–90 of 550.

## 4d. Library learning: proposed correctly, used correctly, and correctly rejected

The library is empty not because the machinery is broken but because there is almost nothing to
compress. `corpus.jsonl` has 6,136 rows but only **1,333 distinct programs**. Of 1,536 distinct
eligible subtrees, 211 appear in ≥2 programs and 15 in ≥5; the best single abstraction compresses
26 of 5,855 corpus nodes (**0.44%**).

Measured A/B on the deterministic held-out split at production budget: champion 181/260; the
operator's own 4-abstraction bundle 182/260 (3W/2L, sign p=0.500); a maximal hand-built library of
**all 63** mineable abstractions 186/260 (13W/8L, p=0.192). Acceptance needs at minimum 5W/0L or
15W/6L. **Nothing the corpus can yield clears the bar.**

On real ARC, seven library configurations were measured and every one scored exactly 46/550 —
the abstractions are bucket-scoped to non-`G>G` buckets while all 550 ARC tasks are `G>G`.

Four real defects sit on top of that ceiling, worth fixing but not worth expecting much from:
`near_miss_abstraction` drops the bucket field, so it can only ever produce the unconditional
additions the system itself measured at −2.7pp; `parameterized_abstraction` is subsumed by the
backward bank (with `bidirectional=false` its abstractions appear in 5 solutions, with it on, 0);
learned ops have no inverse rules so they are excluded from the bidirectional search; and
`library_learn` bundles four abstractions per candidate, mixing a +2 with a −1.

## 5. A constraint that governs everything shipped from here

`genome.load()` reads `rsi/genome/*.lua` **from disk**; the copies embedded in `cell4.lua` are
written by `_write_if_missing`, i.e. only when the file is absent. Verified empirically: a
sentinel op inserted into the embedded `dsl_base.lua` had no effect on a tree with an existing
`rsi/genome/`.

**Therefore: kernel changes ship; genome changes do not.** Editing the DSL, the policy or
`search.lua` inside `cell4.lua` is a no-op on the servers. Tonight's patch is entirely
kernel-side, so it takes effect on drop-in. Anything touching the DSL or the search engine needs
a migration path — and the right one, given this system's evidence discipline, is a mutation
operator that *proposes* adopting new kernel primitives so they still face the acceptance test,
rather than a silent rewrite of an evolved genome.

## 6. Two latent defects found, deliberately NOT shipped

Both are real; neither explains any of the 76 rejections; both change the evidential bar, which
`config.lua` explicitly marks as not-to-be-tuned. Flagging rather than shipping.

- **`adversarial_tolerance = -0.03` is finer than the split's resolution.** The adversarial split
  has 32 tasks, so the smallest possible negative delta is −1/32 = −0.03125, already past the
  threshold. The documented "may lose up to 3pp" is in practice **zero tolerance**. Suggested:
  compare integer task counts with an explicit slack, so the clause cannot be silently retuned by
  a change to `adversarial_per_family`.
- **The regression clause becomes near-unsatisfiable after the first acceptance.** Clause 1
  demands 100% of the regression suite. The suite is empty today only because it is populated
  inside the *retain* branch. The first acceptance would fill it with up to `regression_cap=160`
  tasks, after which zero-loss on 160 is ~2.5e-06 at the observed churn. **As written the loop
  can accept roughly once, then stop.** Suggested: bounded loss, or require the regression loss
  itself to be significant under the sign test already in use.

## 7. Open / unverified

- Whether the churn is inherent to bottom-up enumeration or specific to certain operators. The
  first-solution-wins mechanism and the OE collapse are both confirmed in code, and the 15
  train-consistent-but-wrong held-out tasks bound the selection prize — but I have *not* yet
  measured how many distinct consistent programs a task actually admits, nor whether a majority
  vote among them beats the first-found. That needs the OE exemption and is not done.
- Whether any operator could in principle reach +5pp. 76 samples with best +2.69pp bound this
  weakly at most.
- The regression-trap arithmetic is a projection from current churn, not an observation — no
  acceptance has ever occurred.
- **The §4c and §4d numbers did not get an independent adversarial check.** The analysis session
  hit its limit before the verification pass ran, so of those results only the colour-pool
  measurement (46 → 50) was re-run by me from scratch. The seven-primitive table, the 27-task
  figure and the library A/B numbers come from a single careful pass with cited evidence and
  quoted commands, but nobody tried to refute them. **Treat §4c and §4d as strong leads, not as
  settled fact** — re-deriving them is the first item of night 2, before any code is written
  against them.
- The 27-task figure is explicitly a *lower* bound: it came from a hand-written candidate program
  space, not an exhaustive depth ≤ 3 enumeration over the extended DSL (that run was killed after
  stalling on large grids).
- No proposed primitive was proved inexpressible at unbounded depth. What was shown is weaker but
  decisive in practice: at 40× the production budget with the colour pool widened, the existing
  DSL solved 4 of 35 candidate tasks, and all four were colour-literal cases.
- The system's own record says failures are *reach-limited, not ordering-limited*
  ("13x the node budget bought only +4.4pp"), and that unconditional library additions cost
  −2.7pp because every extra primitive widens branching everywhere. Any new DSL primitive must
  therefore be introduced **bucket-scoped**, via `cond_ops`, not globally.

## 8. Next

Ordered by what the measurements above actually support.

1. **Characterise the 502 out-of-reach ARC tasks.** This is where 91.3% of the real-ARC failure
   lives, so it is where reasoning gains have to come from. Deliverable: a table of candidate
   primitives with, for each, the number of currently-unsolved tasks it would bring within a
   depth ≤ 3 composition. Counts, not intuition — and bucket-scoped, since the system already
   measured unconditional primitive additions at −2.7pp.
2. **Build the kernel-primitive adoption operator.** Nothing in (1) can reach a running server
   without it (§5). Shaped as a mutation operator so new primitives still face the acceptance
   test rather than bypassing the evidence discipline.
3. **Canonical selection, for stability rather than score** (§4b). Expect ~0 score; the point is
   decoupling outcomes from enumeration order to cut the churn that keeps the acceptance bar at
   +4.62pp. Requires exempting the target key from OE dedup. Do **not** build an
   agreement-weighted ensemble — measured right on 1 of 15.
4. Recommend a decision on the two latent defects in §6 — they need the owner's call, since both
   touch the evidential bar.
