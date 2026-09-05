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
| Learned library | empty (`return {}`) after 6,136 solved programs | under investigation |

## Where the failures actually are

This is the central table. The two benchmarks fail for different reasons, and conflating them
sends the work in the wrong direction.

| failure mode | held-out (260) | real ARC (550) | what fixes it |
| --- | --- | --- | --- |
| solved | 181 (69.6%) | 46 (8.4%) | — |
| a consistent program was found, but the **wrong** one | 15 (5.8%) | 2 (0.4%) | better **selection** |
| **no** consistent program in reach at any budget | 64 (24.6%) | **502 (91.3%)** | more **reach** (DSL) |

Two independent levers:

**Lever A — selection.** The search returns the *first* program consistent with the training
examples. Alternatives are not just ignored, they are invisible: OE dedup keys on the train-output
signature and every train-consistent program shares it, so all but the first collapse to one key.
Because every mutation operator works by changing enumeration *order*, a mutation changes *which*
sibling is returned — which is why candidates flip ~25 of 260 held-out outcomes (9.6%) with mean
net −1.04, and why 0 of 76 were ever accepted. Fixing selection is worth up to +5.8pp on held-out
and, more importantly, **cuts the churn that holds the acceptance bar at +4.62pp** (the floor is
+1.92pp at zero losses). This is the lever that unsticks self-improvement.

**Lever B — reach.** 91.3% of real ARC tasks have no consistent program at all. The system's own
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
2. **Primitives must be introduced bucket-scoped.** The system measured unconditional library
   additions at **−2.7pp** for 8 abstractions: every extra primitive widens branching at every
   level. `policy.cond_ops` (per-feature-bucket whitelists) already exists and is the correct
   vehicle. A new primitive that helps 20 grid tasks must not be paid for by every list task.

## Plan

Ordered so that each step unblocks the next, and so nothing ships without evidence.

- **N1 — make the benchmark tell the truth.** *Done.* Rotating, stratified, digest-keyed ARC
  window; cumulative coverage. Without this, no ARC-directed change could ever have been measured,
  and the anti-overfitting guard in acceptance clause 2 was inert.
- **N2 — characterise the 502.** For each candidate primitive, the number of currently-unsolved
  ARC tasks it would bring within a depth ≤ 3 composition. Counts, not intuition. This is the
  only honest way to choose what to add.
- **N3 — the adoption operator.** Kernel-side mutation operator that proposes newly-catalogued
  primitives, bucket-scoped, through the normal acceptance test. Prerequisite for N4.
- **N4 — add primitives, smallest set first**, justified by N2's counts, measured on real ARC and
  on held-out separately.
- **N5 — selection among consistent programs.** Requires exempting the target key from OE dedup.
  Measure: held-out delta, ARC delta, and the change in churn (wins/losses spread), since the
  churn reduction is the point.
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
- No neural component. Excluded by design, and nothing above needs one.
