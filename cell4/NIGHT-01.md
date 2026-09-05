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

- On its own generated families, roughly one failure in five is a **selection** failure: a
  correct program was within reach and the search picked a wrong sibling. Ceiling for better
  selection: +5.8pp. That is above the +1.92pp acceptance floor and within reach of the +4.62pp
  bar — so fixing selection is the lever that would **unstick the RSI loop**, both by adding real
  gain and by cutting the churn that currently raises the bar.
- On real ARC, selection is almost irrelevant: **91.3% of tasks have no consistent program in
  reach at any budget**. Nothing about choosing better among consistent programs helps there.
  This independently reproduces the system's own recorded finding that failures are
  *"reach-limited, not ordering-limited"* (13× the node budget bought +4.4pp).

So there are two distinct levers, and they must not be confused:

1. **To unstick self-improvement** → better selection among train-consistent programs
   (the declared, never-implemented gap *"program merging / multi-program"*). Bounded upside on
   held-out: +5.8pp.
2. **To improve reasoning on real ARC** → **DSL reach**. Expressiveness, not search. This is the
   lever the original request is really about, and it is gated on the genome-migration problem in
   §5, because DSL changes do not reach an evolved genome.

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
- What the 504 unsolved ARC tasks actually require, primitive by primitive. Analysis in flight;
  not reported here because it is not yet verified.
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
3. **Selection among train-consistent programs**, measured on held-out and ARC separately. Worth
   up to +5.8pp on held-out and ~0 on ARC, but its real value is cutting the churn that keeps the
   acceptance bar at +4.62pp. Requires exempting the target key from OE dedup (§4).
4. Recommend a decision on the two latent defects in §6 — they need the owner's call, since both
   touch the evidential bar.
