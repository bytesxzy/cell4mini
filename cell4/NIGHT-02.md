# Night 2 — 2026-09-05

Scope: verify night 1 rather than inherit it, execute the standing plan's next step (N2), and
report what the measurements do to the plan. No training was run. No generation was advanced.

Environment: Lua 5.4.6 (no LuaJIT available here; `selftest` and every harness below run under
plain Lua). Build under analysis is the one carried onto this branch from night 1, with
`upstream/` still untouched.

---

## The headline

Two findings, in order of how much they change the plan.

1. **The next step in the standing plan cannot be built.** N3 was "an adoption operator that
   proposes newly-catalogued kernel primitives". There is nothing to adopt: all 105 non-hidden
   catalogue ops are already in the genome's DSL. The pool is empty, mechanically confirmed.

2. **Real ARC ability is 1.75%, not 8.36%, once the corpus is not the training split.**
   The 46/550 figure night 1 correctly rescued from a broken benchmark is measured on a corpus
   whose `arc1_` half is ARC-AGI-1 *training*. On ARC-AGI-1 *evaluation* the same champion, same
   budget, scores 7/400. On ARC-AGI-2 evaluation it scores 0/120.

And one that decides what to do next: the reach failures do not cluster. Across 150 surveyed
tasks the missing capabilities fragment into 87 distinct gaps, and the addressable ones are
almost all singletons. **There is no primitive worth adding on task-count grounds.**

---

## 1. Is this tree actually the production system?

Night 1's numbers are only meaningful here if the local genome is the deployed one. It is:

    $ lua fp.lua
    fingerprint of the on-disk genome: 04da6714
    NIGHT-01 reports champion        : 04da6714
    visible primitives: 105   library entries: 0

Identical. Two consequences worth stating plainly:

- Anything measured on this tree is what the servers would do.
- **The champion is still the bootstrap genome.** 0 acceptances across 73 generations is not
  "the loop is being cautious"; it means the genome has never once changed. The library is
  empty (`return {}`) after 6,136 solved programs, as night 1 recorded.

## 2. Night 1's benchmark forensics, reproduced from scratch

Night 1's central claim was that `load_external` sorted ARC filenames and took a fixed prefix
containing no solvable tasks. Rather than trust it, the corpus was rebuilt independently from
public ARC-AGI data (`arc1_<id>` = ARC-AGI-1, `arc2_<id>` = ARC-AGI-2) and the forensics re-run.

| night 1 claim | this reconstruction |
| --- | --- |
| earliest solvable at sorted position 31 (`arc1_1cf80156`) | position **31**, `arc1_1cf80156` |
| solvable at sorted positions ≤ 50 are exactly {31, 32, 36, 49} | {31, 32, 36, 49} |
| 0 solvable in the first 20 → the reported 0/20 | 0 |
| generation-6 record "4 of 50 right" when cap was 50 | 4 |

Every detail matches. Night 1's diagnosis is confirmed, and as a by-product the corpus is now
pinned: the `arc1_` portion is ARC-AGI-1 training, sorted.

## 3. The adoption pool is empty — N3 as written is impossible

`ops.lua` builds a catalogue via `def(name, f, args, ret, hidden)`; `genome.load` admits a name
only `if o and not o.hidden`. The plan assumed a reservoir of implemented-but-unexposed
primitives for an adoption operator to propose. Counted mechanically (`bench/dump_dsl.lua`):

    catalogue total          : 126
      non-hidden (adoptable) : 105
      hidden (generator-only): 21
    dsl_base.ops entries     : 105
      of which exposed & real: 105

    NON-HIDDEN CATALOGUE OPS *NOT* IN dsl_base (the adoption pool): 0
    dsl_base entries with no usable catalogue backing: 0

**Zero.** `drop_op`/`restore_op` manage runtime removal and restoration within those 105; they
never described a withheld static subset.

### The trap next to it

The only unexposed ops are the 21 marked `hidden = true`: `mode`, `median`, `argmax`,
`sort_by_freq`, `outline`, `row_sums`, `col_sums`, `checker_mask`, `rotate_rows` and the rest.
These exist so the *task generators* can build targets the solver must reach by composition.
Exposing them would raise the held-out score immediately and mean nothing — it would be scoring
against an answer key. `genome.load` refuses them by design, so the boundary is enforced in code
and not merely by convention. **They must stay hidden.** Any future "adoption" mechanism has to
draw on primitives newly written into the kernel, not on this set.

## 4. What the system can actually do on ARC

Same champion, same budget (`nodes=2500 seconds=4`), three splits. `bench/measure_design.lua`.

| split | solved | train-consistent but wrong | no program in reach |
| --- | --- | --- | --- |
| ARC-AGI-1 training (400) — overlaps their corpus | **39 (9.75%)** | 2 (0.50%) | 359 (89.75%) |
| ARC-AGI-1 evaluation (400) | **7 (1.75%)** | 0 (0.00%) | 393 (98.25%) |
| ARC-AGI-2 evaluation (120) | **0 (0.00%)** | 0 (0.00%) | 120 (100.00%) |

The training-split row reproduces night 1's structure closely (their 8.36% / 0.4% / 91.3%),
which is expected — it is largely the same tasks.

The other two rows are the finding. **A 5.6× drop from the training split to the evaluation
split of the same benchmark, and zero on the current-generation benchmark.**

### Checked confounds

- Not a size cutoff. `chk_grid` errors above 30, but **no task in any split has a grid over 30**.
- Difficulty does scale with the drop: mean max grid dimension is 10.5 (train), 13.5 (eval),
  19.4 (ARC-AGI-2). Part of the gap is intrinsic — ARC-AGI-1 evaluation is a documented step up
  in difficulty from training.
- **Not learned overfitting.** ARC is an external benchmark the system never trains on, and the
  genome never changed anyway. There is no mechanism by which the *system* could have fit itself
  to the training split.

*Hypothesis, not a measurement:* the 105 grid/list ops were hand-designed, and ARC-AGI-1 training
is the canonical published split a designer would have had in front of them. The DSL may be fit
to that split by its author rather than by the loop. This is consistent with the numbers but is
not established by them, and it is testable — see Open.

Either way the practical consequence stands: **8.36% is the score on the easy, familiar split.
On unseen ARC this system is at 1.75%, and on ARC-AGI-2 it is at zero.** Any progress claim
should quote the evaluation splits, and the benchmark window should be stratified across them.

## 5. N2: which primitives would bring unsolved tasks into reach?

The plan's N2 asked for counts, not intuition: per candidate primitive, how many unsolved tasks
it would bring within a depth ≤ 3 composition.

150 of the 400 design tasks were surveyed against the full 105-op DSL (the survey was cut short
by a session limit at 150; the remaining 250 are not done). Per task: the transformation rule,
whether the 105 ops can compose to it, and if not the one missing capability.
Raw output: `bench/night02_survey_150tasks.json`.

    surveyed tasks              : 150
    judged expressible          :  32 (21.3%)
    judged NOT expressible      : 113 (75.3%)
    unclear                     :   5 (3.3%)

    distinct missing-capability phrases across the 113: 87

**The gaps do not cluster.** The largest is "periodic pattern completion" at 6 tasks. Classifying
the 113 by whether a first-order operation could express them at all:

| class | tasks | share |
| --- | --- | --- |
| plausibly a first-order primitive | 64 | 56.6% |
| needs **iteration or binding** — no first-order op can express it | 36 | 31.9% |
| needs relational reasoning (two-place, computed references) | 13 | 11.5% |

And the addressable residue is itself almost all singletons:

    the addressable-by-primitive residue is 64 tasks over 54 distinct gaps
    49 of those 54 gaps appear in exactly ONE task each
    largest clusters: periodic pattern completion (6), occlusion repair from
    self-symmetry (3), block-wise aggregate downscale (2), diagonal ray drawing (2),
    marker-selected object extraction (2)

### What this does to N4

N4 was "add primitives, smallest set first, justified by N2's counts". **The counts do not
support it.** The best available primitive covers 6 of 400 tasks (1.5%); the median covers one.
Against that sits the system's own measurement that 8 unconditional library additions cost
−2.7pp, because every extra primitive widens the branching factor at every enumeration level.
Adding primitives one-per-task is, on the system's own evidence, roughly break-even at best.

### The more important half

A third of the inexpressible tasks need something no primitive can provide. The DSL is a
composition over a single variable `$` — no lambdas, no loops, no let-binding, no user-defined
control flow. So "recolour each object by its size rank", "stamp this motif at every marker",
"apply a rule per region" are not missing *operations*, they are missing *language*. The recurring
gap phrases are explicit about it: `per-object rule application`, `stamp a pattern at each marker
cell location`, `per-region rule over a line-partitioned grid`, `per-cell 3x3 neighbourhood rule`.

**The reach bottleneck is substantially an expressiveness bottleneck in the language, not a
vocabulary bottleneck in the catalogue.** That is a different and much larger piece of work than
N4 described, and it should be decided deliberately rather than drifted into.

## 6. Selection among train-consistent programs, and a harness that lied

Night 1 left open: how many distinct consistent programs does a task admit, and does choosing
among them beat first-found? `bench/search_collect.lua` exempts the target key from OE dedup and
collects every consistent program instead of returning the first.

**The first version of this harness produced a clean, publishable-looking result that was wrong.**
A control run of the *unmodified* solver on the same split disagreed with it by 17 tasks
(`bench/control_eval.lua`). `bench/diff_probe.lua` localised the discrepancy:

    both found a program        : 122   (identical program: 122)
    production found, collect NOT: 20   <- collect is WEAKER here
    collect found, production NOT: 0

So the ordering was faithful — on all 122 tasks where both found something, the collected first
program *is* production's returned program — but collect mode found nothing on 20 tasks. Cause:
with no early exit it burns the whole node budget, starving the backward-search phase that
`back_after_cost` gates. The fix is a larger budget for the collecting variant, since enumeration
order is unchanged and first-found stays production-faithful.

That re-run had not finished when this report was written, so **no selection numbers are reported
tonight.** The provisional ones from the unfixed harness are deliberately omitted.

The transferable lesson is the same one that cost 67 generations: a measurement is not a result
until something independent agrees with it.

## 7. A latent defect from night 1 §6, now confirmed

`bench/check_defects.lua`:

    adversarial split size                : 32 tasks
    smallest possible negative delta on it: -1/32 = -0.03125
    configured adversarial_tolerance      : -0.03000
    => ANY single adversarial regression already breaches tolerance.

Confirmed. The documented "may lose up to 3pp" is zero tolerance in practice. Still not shipped —
it changes the evidential bar, which `config.lua` marks as not-to-be-tuned, so it stays the
owner's call.

Incidentally this explains a discrepancy: held-out here is 200 tasks, not night 1's 260, because
the split is 20 per family and this tree has the base 10 families rather than the 13 that had
accrued on the server. Not a defect.

## 8. Open / unverified

- **250 of 400 design tasks are unsurveyed.** The gap distribution above is from 150. The
  direction (long tail, iteration-bound mass) is unlikely to reverse, but the counts will move.
- The survey is LLM judgement, not mechanical proof. "Expressible" was judged, not demonstrated
  by finding the program. Note that 21.3% were judged expressible while the solver actually
  solves 9.75% — that ~11pp gap is either surveyor optimism or genuine search failure on
  in-reach tasks, and it has not been separated.
- The 87-gap fragmentation is an *overcount* of true diversity: the clustering stage that would
  have merged near-duplicate phrasings failed with the session limit. Better merging shrinks the
  gap count but does not change that the largest cluster is 6 tasks.
- Selection numbers, pending the re-run in §6.
- The "DSL fit to ARC-AGI-1 training by its designer" hypothesis in §4 is untested. A cheap test:
  check whether the ops that appear in solutions of training tasks are disproportionately the
  ones a designer would have added for specific published tasks.
- Whether the 550-task server corpus contains ARC-AGI-2 tasks at all, and in what proportion.
  Only the `arc1_` half is pinned.

## 9. Next

Ordered by what the measurements support, and deliberately not by what the previous plan said.

1. **Put the evaluation splits in front of the owner and get a decision on §4.** If unseen-ARC
   ability is 1.75% and 0%, the benchmark the loop optimises against should say so. This is a
   reporting change, and it precedes any capability work.
2. **Finish the survey** (250 remaining) and cluster the gaps properly, so the "no primitive is
   worth adding" conclusion rests on 400 tasks rather than 150.
3. **Decide, explicitly, between two very different projects**: adding first-order primitives for
   a long tail worth ~1 task each, or extending the language with bounded iteration over objects
   or regions, which is where a third of the failures live. The second is the one with the mass
   behind it, and it is a substantially larger change than anything the plan has scoped so far.
4. Finish the selection measurement and settle whether the selection lever is worth anything.
5. Owner decision still outstanding on both night-1 §6 defects.
