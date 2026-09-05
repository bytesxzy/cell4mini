# CELL4 — where the reasoning actually breaks, and the plan

A standing document. It states the architecture as measured, not as intended, and it is revised
when a measurement contradicts it. Every number here has a command behind it in a night report.

Last revised: night 2 (2026-09-05). Night 2 contradicted two steps of night 1's plan; they are
struck through below rather than quietly deleted.

---

## The system in one paragraph

CELL4 solves ARC-style tasks by **bottom-up program enumeration** over a typed DSL of 105
primitives. It enumerates programs in integer cost order, dedups by observational equivalence on
the training inputs, learns per-op cost priors just-in-time from partially-correct programs
(Probe-style), and meets a backward bank built by inverting the goal through invertible operators.
Around that solver sits a **self-improvement loop**: each generation mutates the genome (op costs,
whitelists, constant pools, learned library, hyperparameters), evaluates the candidate against the
champion on a secret-salted held-out split, and accepts only on a paired bootstrap **and** an exact
sign test. There is no neural network anywhere, by design.

A program is a composition over one input variable `$`. There are no lambdas, no loops, no
let-bindings and no user-defined control flow. This is the single most consequential fact about
the system and night 2 promoted it from a footnote to the centre of the plan.

## The measured state

| | value | where |
| --- | --- | --- |
| Held-out (self-generated families) | 181/260 (69.6%) at production budget | night 1 §1 |
| **Real ARC — ARC-AGI-1 training split** | **39/400 (9.75%)** | night 2 §4 |
| **Real ARC — ARC-AGI-1 evaluation split** | **7/400 (1.75%)** | night 2 §4 |
| **Real ARC — ARC-AGI-2 evaluation split** | **0/120 (0.00%)** | night 2 §4 |
| Real ARC as previously quoted (46/550, 8.36%) | corpus is dominated by the *training* split | night 2 §2, §4 |
| Real ARC as the system reported it before night 1 | 0/20 for 67 generations | instrument defect, fixed night 1 |
| Candidates accepted | **0 of 76** across 73 generations | night 1 §4 |
| Champion genome | still the bootstrap genome, fingerprint `04da6714` | night 2 §1 |
| Learned library | empty (`return {}`) after 6,136 solved programs | still unexplained |
| Unexposed non-hidden primitives available to adopt | **0 of 105** | night 2 §3 |

**Quote the evaluation splits.** The 8.36% figure is the score on the split whose tasks the
corpus is built from and which a DSL designer would have had in front of them. It is not a
generalisation number.

## Where the failures actually are

The two benchmarks fail for different reasons, and conflating them sends the work in the wrong
direction.

| failure mode | held-out (260) | real ARC (400, ARC-AGI-1 train) | what fixes it |
| --- | --- | --- | --- |
| solved | 181 (69.6%) | 39 (9.8%) | — |
| a consistent program was found, but the **wrong** one | 15 (5.8%) | 2 (0.5%) | better **selection** |
| **no** consistent program in reach at any budget | 64 (24.6%) | 359 (89.8%) | more **reach** |

On the evaluation splits the reach column is 98.3% and 100%.

**Lever A — selection.** The search returns the *first* program consistent with the training
examples, and OE dedup keys on the train-output signature so every other consistent program
collapses to one key and is discarded unseen. Bounded upside on held-out: +5.8pp. Night 2 built
the collecting harness for this, caught it under-reporting by 20 tasks against a control, and did
not report numbers. **Unquantified — see night 2 §6.**

**Lever B — reach.** This is where 90–100% of real-ARC failure lives, and night 2 measured what
it would actually take. It splits in two:

- **Vocabulary.** 56.6% of inexpressible tasks might yield to a first-order primitive — but they
  fragment into 54 distinct gaps of which 49 appear in exactly one task each. Best cluster: 6 of
  400 tasks. Against the system's own measurement that 8 unconditional additions cost −2.7pp,
  **no primitive currently justifies its branching cost.**
- **Expressiveness.** 31.9% need iteration or binding — "recolour each object by size rank",
  "stamp this motif at every marker", "apply a rule per region". A further 11.5% need relational
  reasoning over computed references. **No first-order primitive can express any of these.** They
  need the language to grow, not the catalogue.

## Two constraints that govern everything

1. **Genome files on disk shadow the embedded copies.** `genome.load()` reads
   `rsi/genome/*.lua` from disk; `_write_if_missing` writes the embedded copy only when absent.
   **Kernel changes ship; genome changes do not.** Anything touching the DSL, the policy or
   `search.lua` needs a migration path.
2. **The 21 hidden ops are off limits.** They exist so task generators can build targets the
   solver must reach by composition. `genome.load` refuses them (`not o.hidden`), so the boundary
   is enforced in code. Exposing them would move the held-out score without improving any
   reasoning — it would be scoring against the answer key.

## Plan

- **N1 — make the benchmark tell the truth.** *Done, night 1.* Rotating, stratified, digest-keyed
  ARC window. Independently reproduced in night 2 §2, detail for detail.
- **N2 — characterise the out-of-reach tasks.** *Done for 150 of 400, night 2 §5.* Result: the
  gaps do not cluster, and a third of them are not primitive-shaped at all.
- ~~**N3 — the adoption operator.**~~ **Struck.** It presupposed a reservoir of
  implemented-but-unexposed primitives to propose. Night 2 §3 counted the reservoir: it is empty,
  all 105 non-hidden catalogue ops are already in the DSL. The only unexposed ops are the 21
  hidden ones, which must stay that way. Any adoption mechanism must wait until there are newly
  written kernel primitives worth adopting — and N2 says there are not yet.
- ~~**N4 — add primitives, smallest set first, justified by N2's counts.**~~ **Struck as
  premature.** The counts came back and do not support it: best candidate 6/400 tasks, median 1,
  against a measured −2.7pp cost for 8 additions.
- **N2b — finish the survey.** 250 design tasks remain unsurveyed, and the gap clustering stage
  never ran. The conclusion above should rest on 400 tasks, not 150.
- **N3′ — report the evaluation splits.** The loop's external benchmark should be stratified
  across ARC-AGI-1 training / evaluation / ARC-AGI-2 rather than dominated by the training split,
  so the number the system quotes about itself is a generalisation number. Owner decision, since
  it changes what the acceptance clause compares.
- **N4′ — the real fork, and it needs deciding rather than drifting into.** Either:
  (a) keep adding first-order primitives for a long tail worth ~1 task each — cheap per step,
  bounded, and on current evidence roughly break-even; or
  (b) extend the language with bounded iteration over objects or regions — where a third of the
  failures live, but a substantially larger change than anything scoped so far, touching
  `search.lua` (which is genome-shadowed, per constraint 1) and the whole enumeration cost model.
  **The measurements favour (b). Nothing should be built until this is chosen explicitly.**
- **N5 — selection among consistent programs.** Requires exempting the target key from OE dedup;
  harness exists (`bench/search_collect.lua`) and is validated against a control, but the
  measurement is unfinished.
- **Ongoing** — night 1 §6's two acceptance defects need the owner's decision. The first
  (`adversarial_tolerance` finer than the split's resolution) was confirmed in night 2 §7.

## Things that are settled, so they are not re-proposed

- More compute is not the lever (13× budget → +4.4pp; the ~90% out-of-reach figure agrees).
- The acceptance test is not miscalibrated. Mutations are significantly *harmful* on average
  (908 wins vs 987 losses over 76 candidates, binomial p = 5.7e-05). The generator is the
  bottleneck, not the judge.
- Evaluation is bit-deterministic at the production budget, so candidate churn is real
  behavioural change and cannot be averaged away by repeated runs.
- No neural component. Excluded by design, and nothing above needs one.
- **The hidden ops stay hidden.** Not negotiable; it is the only thing keeping the held-out
  benchmark meaningful.
- **A measurement is not a result until something independent agrees with it.** Two nights
  running, a plausible-looking number turned out to be an instrument reading: the 0/20 window in
  night 1, and night 2's own first selection harness. Every harness now ships with a control.
