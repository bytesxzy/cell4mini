# CELL4 — where the reasoning actually breaks, and the plan

A standing document. It states the architecture as measured, not as intended, and it is revised
when a measurement contradicts it. Every number here has a command behind it in a night report.

Last revised: night 1 (2026-09-05).

---

## The system in one paragraph

CELL4 solves ARC-style tasks by **bottom-up program enumeration** over a typed DSL of ~100
primitives. It enumerates programs in integer cost order, dedups by observational equivalence on
the training inputs, learns per-op cost priors just-in-time from partially-correct programs
(Probe-style), and meets a backward bank built by inverting the goal through invertible operators.
Around that solver sits a **self-improvement loop**: each generation mutates the genome (op costs,
whitelists, constant pools, learned library, hyperparameters), evaluates the candidate against the
champion on a secret-salted held-out split, and accepts only on a paired bootstrap **and** an exact
sign test. There is no neural network anywhere, by design.

## The measured state

| | value | where |
| --- | --- | --- |
| Held-out (self-generated families) | 181/260 (69.6%) at production budget; 190/260 at default | night 1 §1 |
| Real ARC corpus | **46/550 (8.36%)** | night 1 §1 |
| Real ARC as the system reported it | 0/20 for 67 generations | **instrument defect**, fixed night 1 |
| Candidates accepted | **0 of 76** across 73 generations | night 1 §4 |
| Learned library | empty after 6,136 rows / **1,333 distinct** programs | night 1 §4d — correctly rejected, nothing to compress |
| ARC with colour literals 6-9 enabled | **50/550 (9.09%)**, +4, no losses | night 1 §4c — one line in `policy.lua` |

## Where the failures actually are

This is the central table. The two benchmarks fail for different reasons, and conflating them
sends the work in the wrong direction.

| failure mode | held-out (260) | real ARC (550) | what fixes it |
| --- | --- | --- | --- |
| solved | 181 (69.6%) | 46 (8.4%) | — |
| a consistent program was found, but the **wrong** one | 15 (5.8%) | 2 (0.4%) | see below |
| **no** consistent program in reach at any budget | 64 (24.6%) | **502 (91.3%)** | more **reach** (DSL) |

The middle row was probed rather than assumed (`bench/probe_selection.lua`): re-solve each such
task with the op-cost table jittered, as a mutation would, and see whether any restart yields a
program that also satisfies the test example. **Only 5 of the 15 have a correct sibling in reach
at all**; the other 10 are reach failures wearing a selection failure's clothes. So the real
held-out split is closer to **1.9% selection, 28.5% reach**.

Two independent levers:

**Lever A — selection, and it is weaker than it looks.** The search returns the *first* program
consistent with the training examples. Alternatives are not just ignored, they are invisible: OE
dedup keys on the train-output signature and every train-consistent program shares it, so all but
the first collapse to one key. Because every mutation operator works by changing enumeration
*order*, a mutation changes *which* sibling is returned — which is why candidates flip ~25 of 260
held-out outcomes (9.6%) with mean net −1.04.

Measured ceiling for a perfect selection rule: **+1.9pp**, sitting exactly on the +1.92pp
acceptance floor. And plurality voting across restarts is right on **1 of 15** — the most frequent
program under perturbation is the one the cost prior favours, i.e. the same wrong one, so
agreement is anti-correlated with correctness. Ensemble schemes would be worse than today.

Selection is therefore a **stability** lever, not an accuracy one: a rule that picks canonically
among the consistent set would decouple outcomes from enumeration order, cutting the churn that
holds the acceptance bar at +4.62pp instead of the +1.92pp floor. Worth doing to restore
statistical power, not to raise the score.

**Lever B — reach, and it dominates both benchmarks.** 91.3% of real ARC tasks — and, after the
probe above, ~28.5% of held-out — have no correct program in reach at all. The system's own
records agree: *"13× the node budget bought only +4.4pp; the remaining failures are reach-limited,
not ordering-limited"*, and `max_cost` 9→24 was bit-for-bit identical. **No amount of search
tuning or compute touches this.** Only DSL expressiveness does. This is the lever that improves
real reasoning.

## Two constraints that govern everything

1. **Genome files on disk shadow the embedded copies.** `genome.load()` reads
   `rsi/genome/*.lua` from disk; `_write_if_missing` writes the embedded copy only when absent.
   Verified empirically. **Kernel changes ship; genome changes do not.** Anything touching the
   DSL, the policy or `search.lua` needs a migration path, and the right one — given this
   system's evidence discipline — is a *mutation operator* that proposes adopting new kernel
   primitives, so they still face the acceptance test. `restore_op` is the nearest existing
   operator but only restores previously-dropped ops, so this is genuinely new.
2. **The residual needs a new TYPE, not new primitives.** 196 of the 504 unsolved ARC tasks have
   ≥3 connected objects per input; the four object-aware ops all collapse the object set to one
   scalar or one object, and the type universe `{B,C,G,I,L}` has no list-of-grids type and no map
   combinator. Per-object heterogeneous reasoning is therefore inexpressible at any depth. This
   bounds "add primitives" at roughly 46 → 75-90 of 550, and it is a kernel change.
3. **Primitives must be introduced bucket-scoped.** The system measured unconditional library
   additions at **−2.7pp** for 8 abstractions: every extra primitive widens branching at every
   level. `policy.cond_ops` (per-feature-bucket whitelists) already exists and is the correct
   vehicle. A new primitive that helps 20 grid tasks must not be paid for by every list task.

## Plan

Ordered so that each step unblocks the next, and so nothing ships without evidence.

- **N1 — make the benchmark tell the truth.** *Done.* Rotating, stratified, digest-keyed ARC
  window; cumulative coverage. Without this, no ARC-directed change could ever have been measured,
  and the anti-overfitting guard in acceptance clause 2 was inert.
- **N2 — characterise the 502.** *Largely done, but unverified* (night 1 §4c). Seven primitives
  reach 27 of the 504: `mask_and/or/xor/nor (G,G,C)->G` (14), `fill_periodic (G,C)->G` (6),
  `fill_symmetry` + `crop_diff` (4), `fill_holes (G,C)->G` (3) — 46/550 → 73/550. The
  verification pass never ran, so **night 2 starts by re-deriving these**, not by coding them.
  Separately: widening the colour pool to 0-9 is +4 ARC for one line, measured twice.
- **N3 — the adoption operator.** Kernel-side mutation operator that proposes newly-catalogued
  primitives, bucket-scoped, through the normal acceptance test. Prerequisite for N4.
- **N4 — add primitives, smallest set first**, justified by N2's counts, measured on real ARC and
  on held-out separately.
- **N5 — canonical selection, for stability not score.** Requires exempting the target key from
  OE dedup. Measure the change in churn (wins/losses spread per candidate), which is the point;
  do **not** expect score, and do not build an agreement-weighted ensemble — measured at 1/15.
- **Ongoing** — the two latent acceptance defects in night 1 §6 need the owner's decision,
  because both touch the evidential bar that `config.lua` marks as deliberately not tunable.

## Things that are settled, so they are not re-proposed

- More compute is not the lever (13× budget → +4.4pp; measured by the system, reproduced in
  spirit by the 91.3% out-of-reach figure).
- The acceptance test is not miscalibrated. Mutations are significantly *harmful* on average
  (908 wins vs 987 losses over 76 candidates, binomial p = 5.7e-05). Loosening alpha would admit
  changes the data says are bad. The generator is the bottleneck, not the judge.
- Evaluation is bit-deterministic at the production budget, so candidate churn is real
  behavioural change and cannot be averaged away by repeated runs.
- Selection is not an accuracy lever: perfect selection is +1.9pp, and plurality voting across
  restarts is right on 1 of 15 because agreement is anti-correlated with correctness.
- Library learning is not fixable by tuning. Only 1,333 distinct programs exist in a 6,136-row
  corpus; the best abstraction compresses 0.44% of nodes, and even a maximal 63-entry library is
  186/260 (13W/8L, p=0.192) — short of the bar, and exactly 46/550 on ARC. The machinery works;
  there is nothing to compress.
- The `rejected` list in `mechanisms.lua` is scoped to the synthetic distribution and must not be
  generalised to ARC. "Wider constant pool: -3.5pp" was measured on generated tasks with small
  pooled values; on ARC, which uses ten colours, widening the pool is +4 with no losses.
- No neural component. Excluded by design, and nothing above needs one.
