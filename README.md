# CELL4 · recursive self-improvement research loop

An autonomous, LLM-free experimental system that tries to improve its own problem-solving architecture
and only keeps a change when a skeptical evaluation harness finds real evidence for it.

* **Intelligence:** a program-synthesis engine (`rsi/genome/search.lua`) that solves input→output tasks
  by **bidirectional** search: a forward bank built by cost-guided bottom-up enumeration with
  observational equivalence and Probe-style just-in-time cost learning, meeting a backward bank built
  by inverting the goal through the operators' inverse semantics (`rsi/kernel/inverses.lua`), plus a
  growing library of learned abstractions (DreamCoder-style). Written in plain Lua; runs under Lua 5.4
  or LuaJIT. No external model, no API in the reasoning path.
* **Self-modification:** the genome (`rsi/genome/`) is mutable source: which primitives are visible, the
  learned library, the search policy (costs, constants, budgets, strategy) and the search code itself.
  Every generation the kernel derives candidates from the champion's own experimental evidence,
  evaluates them, and retains one only if it passes the acceptance rule.
* **Harness (stable kernel, `rsi/kernel/`):** secret-salted held-out tasks, fresh adversarial split with
  hidden operators the DSL does not have, regression suite of everything ever solved, external ARC tasks
  pulled from the internet, paired bootstrap + sign test, overfit detector, efficiency criterion,
  optimisation-pressure tracking with automatic benchmark rotation and harder family variants.
* **Lineage:** every candidate is snapshotted to `rsi/versions/gNNNN_*` with its evidence; verdicts and
  numbers go to `rsi/state/lineage.jsonl` and the console.
* **Orchestrator in your language:** `CELL2` is the top-level loop written in the CELL2 tag language and
  run through `main.lua` (your transpiler, with three small fixes). `<PURE>` is used only for the four
  lines that call into the kernel.

## The reasoning engine

Forward-only enumeration is blind. It spends the node budget on breadth and asks whether anything it
built happens to equal the target, which is exactly the wrong purchase when branching factor is the
measured bottleneck. Two mechanisms replace guessing with deduction:

**Inverse semantics.** For 37 operators, `rsi/kernel/inverses.lua` answers: given a desired output,
what input would produce it? If the target is a 90-degree rotation of something, rotating it back says
precisely what the rest of the program must produce. Candidates are never trusted — the operator is
applied forward and the candidate kept only if it reproduces the output on every training example.
That makes liberal rules safe: `shift_down` is not injective, but shifting back verifies exactly when
nothing fell off the edge. All 37 rules were checked against their forward operator on random inputs;
none ever produced a candidate that survived to be used incorrectly.

**Binary meet.** The plain rules cannot see an outer operator whose second argument is not a constant,
which is the commonest compositional shape here — the input concatenated with a transform of itself, a
grid beside its own mirror, one grid overlaid on another. Taking one argument from what the forward
search can already build makes the other determined. This was justified by measurement first: across
272 solved programs, **98.3% of binary applications have a leaf as the shallower argument and none has
both arguments deep**, so pairing against cheap forward values is where the solutions actually live.

Backward entries are counted against the same node budget as forward ones, so the comparison against a
purely forward search is like for like — and the bidirectional engine wins while spending *fewer*
nodes, not more.

Two implementation details decided the outcome, both discovered by measurement rather than design:

* Built eagerly, the backward bank **lost** 1.7pp. Depth-1 tasks paid for machinery they never needed
  and ran out of wall-clock before the forward search began. It is now built lazily, only after the
  forward search has exhausted every depth-1 program.
* Scanning all ~105 operators per frontier entry dominated the runtime. Operators are now indexed by
  return type, since only a minority are invertible.

### Measured, on task sets never used for tuning

| | forward-only | bidirectional | delta | p (bootstrap / sign) |
|---|---|---|---|---|
| set J (300) | 67.3% | 75.3% | +8.0pp | <0.0001 / <0.0001 |
| set K (300) | 65.3% | 71.3% | +6.0pp | 0.0010 / 0.0015 |
| set L (300) | 69.0% | 77.7% | +8.7pp | <0.0001 / <0.0001 |
| **pooled** | **67.2%** | **74.8%** | **+7.6pp** | 85 wins, 17 losses |

Mean search nodes per task fell from 1072 to 787. On the harness's own secret held-out split the
champion went from 141/200 to 152/200. Binary meet was validated separately against
bidirectional-without-it on four further independent sets (+2.3, +1.7, +1.7, +2.0 pp; 24 wins, 1 loss).

### Round two: what the failures said next

After the bidirectional engine landed, the remaining failures were profiled rather than guessed at.
Two measurements settled the direction:

* **Task-derived constants** (mine example-invariant literals from the I/O pairs, as FlashFill and
  its descendants do) were built and measured at **0.0pp** on 300 mixed tasks and **0.0pp** on 180
  large-value tasks. The reason is specific and checkable: 86% of generated tasks derive nothing,
  because the values in play are small and the global pool already covers them. The code is kept and
  exposed to the mutation operators, defaulted off, because it is the right remedy where literals
  actually matter — real ARC has ten colours and dimensions to 30 — but nothing here justifies it.
* **The remaining failures are reach-limited, not ordering-limited.** Thirteen times the node budget
  (1500 → 20000) buys **+4.4pp**, and 1500 → 3000 buys 0.4pp. Bank capacities are flat in both
  directions. So no amount of better search ordering or more compute is the lever; what is missing is
  the ability to express programs the DSL cannot reach at all.

That is why the work after this point went into the benchmark and research machinery rather than into
more search tricks: the search is close to the ceiling of what this operator set can express, and the
honest next move is to face harder external problems, not to grind the internal ones.

### What was tried and did not work

Reported because the negatives cost as much to establish as the positives, and a list of only
successes would be a sales pitch:

* **Replaying the binary meet against the grown forward bank**: +0.3pp, 1 win, 0 losses, p=0.37. Real
  but not evidence. Shipped off (`meet_replay = false`).
* **Lifting the cost ceiling** (`max_cost` 9 → 24): bit-for-bit identical results. The ceiling never
  binds; the tasks that stop early with budget remaining have exhausted the *reachable value space*,
  meaning they are out of the DSL's reach rather than cut short.
* **Deepening the backward chain** (`back_max_cost` 6 → 9) and **widening the binary meet**
  (`binary_meet_cap` 24 → 64, `binary_meet_depth` 2 → 4): all exactly flat. None of these limits binds.

## Choosing what to be challenged by

`rsi/kernel/challenge.lua` ranks every task family by how much it can still teach, from the system's
own measurements:

* **information** — 4p(1−p) on the solve rate. A family solved 100% or 0% of the time carries no
  information about whether a change helped, because every candidate scores the same on it. This is
  item information from item response theory, in its simplest form.
* **discrimination** — how often candidates actually differ from the champion there. This is the
  count of discordant pairs, which is exactly what the sign test consumes, so it measures the
  benchmark's *power to detect an improvement at all*. A family that never produces a discordant pair
  can never justify an acceptance however hard it looks.
* **headroom** — mean partial credit on the tasks it fails.
* **freshness** — how long since the family last discriminated, which is how saturation shows up
  before the solve rate does.

A family it never solves is **not** a good challenge and ranks low on purpose: difficulty for its own
sake is not the objective, telling improvement from noise is. The four components are measured; the
weights that combine them are a declared convention in `rsi/config.lua`, printed on the console and in
`JOURNAL.md` so they can be argued with. That split is what "unbiased" means here — nothing is scored
by preference, and the one judgement call is shown as one.

The ranking is used, not just displayed: the adversarial split is aimed at whatever currently
discriminates best, and a family that is both nearly always solved and no longer separating
candidates has a harder variant spawned from it immediately, rather than waiting for an acceptance to
trigger a rotation. That is the system going looking for harder work.

## The record it keeps

Three files, answering different questions:

| file | question it answers |
|---|---|
| `rsi/data/corpus.jsonl` | **the training data.** Every task ever solved: family, feature bucket, the program found, the program the generator actually used, and the generation. Every mutation operator learns from this and nothing else. |
| `rsi/data/journal.jsonl` | the milestones: accepted changes with evidence, benchmark rotations, research fetches. |
| `JOURNAL.md` | the same, rendered for a human, regenerated every generation. |
| `rsi/state/lineage.jsonl` | every candidate ever tried and why it was refused. |

The generator's own expression is recorded in the corpus for the reader; the solver is handed
`tasks.solver_view`, which omits it along with the test examples.

## Research, and what it can honestly do

`rsi/kernel/mechanisms.lua` is an explicit registry: what the reasoning is built from, what was
implemented and **measured and discarded** (with the numbers that killed it), and what has never been
built here — e-graphs, conflict-driven learning, sketches, SMT, MCTS, abstraction refinement. arXiv
abstracts are scored against it, and a paper touching a declared gap outranks one restating machinery
that already exists, so the feed is ordered by relevance to what is missing rather than by date.

This is keyword matching against an explicit list. It is **not** comprehension — there is no model
here to read anything — and the console says so in those words. The registry's real value is the
second field: without a record of what was tried and failed, the system would happily re-propose the
same losing ideas and a reader would have no way to tell an untried idea from a tried one.

## What actually improves, and how

One generation (`rsi/kernel/cycle.lua`):

1. If due (default every 1.5 h), fetch research: new ARC-AGI-1/2 training tasks into the external
   evaluation set, and recent arXiv abstracts into `rsi/data/research/` for the human.
2. Build splits: visible (fresh seeds each generation), held-out (secret salt + epoch, never visible
   to the genome), adversarial (fresh each generation, hidden ops, larger inputs), regression, external.
3. Evaluate the champion. Every "solve" requires the found program to be correct on a test example the
   solver never saw, not just the training pairs.
4. Generate candidates with evidence-driven operators (`rsi/kernel/mutate.lua`):
   * **library learning** — repeated subtrees across solved programs become new primitives;
   * **parameterized abstraction** — anti-unification finds subtrees identical except for one
     constant and turns that position into a second parameter, so `sum(row($,1))` and `sum(row($,3))`
     collapse into one two-argument abstraction. Exact repeats are rare in generated tasks;
     "same shape, different constant" is common, so this is where reuse actually lives;
   * **near-miss abstraction** — the same, mined from partially-correct programs;
   * **prior fitting** — frequently used operators get cheaper (evidence showed that making rare
     operators *dearer* costs adversarial performance, so the operator only ever lowers costs);
   * **task-conditioned priors** — a separate cost table per task-feature bucket
     (`rsi/kernel/features.lua`: input/output types plus whether the output grows, shrinks, or is a
     member of the input), a tabular stand-in for a learned recognition model;
   * enumeration reordering, constant tuning, hyperparameter perturbation, bulk and single DSL
     pruning, operator restoration, strategy switch.

   Operator choice is adaptive (Laplace-smoothed acceptance rate), and no operator repeats within a
   generation.
5. Evaluate each candidate on all splits under the same deterministic node budget.
6. Acceptance rule (`decide` in `cycle.lua`), in order: no regression loss → no external ARC loss →
   adversarial drop within tolerance → not an overfit (visible gain without held-out gain) →
   a held-out gain significant under **both** the paired bootstrap and the exact sign test
   (α=0.05 each) **or** equal solves with ≤80% of the search nodes and zero losses.

   The conjunction is not belt-and-braces, it is load-bearing. The first candidate the loop ever
   accepted won 3 held-out tasks and lost 0 out of 200. The bootstrap gave p=0.047, because a
   resample of 200 items almost always contains one of the three wins; the exact sign test gave
   0.125, which is the honest number for three discordant pairs. Taking either test alone admits
   that candidate. The rule now takes both, and that acceptance no longer stands.
7. Retain: write the candidate over `rsi/genome/`, extend the regression suite with the newly solved
   held-out tasks, record which family drove the gain. If one family drives two consecutive acceptances,
   the secret held-out salt rotates and a harder variant of that family is spawned.

The feedback loop is real: learned abstractions and priors change what the search reaches within the
same budget, which changes which programs get solved, which changes the next round's evidence.

## Honest limits

* **No language model = no reading papers.** The research fetcher cannot turn an abstract into a
  mechanism. Hypotheses come from the system's own experiments. This is fundamental to the LLM-free
  design you asked for, not an engineering shortcut.
* **The search code is mutable but not self-rewritten.** Automated operators change the library, priors,
  constants, visible DSL, hyperparameters and strategy flags. Source-level rewrites of `search.lua` are
  something a human or a future operator can do; the kernel will evaluate them the same way.
* **The hyperparameter space is nearly flat, and that is a measured result, not a guess.** An offline
  probe over eleven policy variants (`max_cost`, `bank_cap`, JIT settings, constant pools, leaf cost)
  on 200 tasks found no variant with a significant gain over the default; the two largest movers were
  *losses* (shrinking the integer constant pool cost 7pp). So the system cannot improve by turning
  knobs. Whatever real gains exist have to come from abstraction and from priors, which is why those
  operators got the most work.
* **What was measured about the search, including a claim that failed to replicate.** Offline
  experiments on 300 fresh tasks, each a paired comparison against the champion:

  | change | held-out | nodes/task | reading |
  |---|---|---|---|
  | eleven hyperparameter variants | none better | — | the knob space is flat |
  | 8 learned abstractions added | −2.7pp | 932 | every extra primitive widens branching at every level |
  | same, scoped to their task bucket | −0.7pp | 899 | confirms branching cost is what binds |
  | per-bucket operator whitelist, hard | −1.7pp | 691 | 10 wins from the depth it buys, 15 losses from excluding needed operators |
  | whitelist first, then full fallback | +2.7pp, p=0.016 | 747 | looked like a real win |

  The last row did **not** replicate. Rerun against the live secret held-out split with a fresh
  corpus, the same change scored −0.5pp (wins 4, losses 5, p=0.69). The explanation is mundane and
  worth stating plainly: several variants were tried and the best was reported, so that p=0.016 was
  never corrected for multiple comparisons. This is precisely the failure mode the harness exists to
  catch, and it caught it in the author's own analysis. The honest summary is that the two-phase
  mechanism is *available* and unproven, not that it works.

  What survives from the experiments is the mechanism, not the win: the node budget binds on
  branching factor rather than depth, which is why adding primitives costs and why anything that
  narrows the enumeration is worth trying. `two_phase` and the per-bucket whitelists ship **off**
  (`cond_ops` empty in `rsi/genome/policy.lua`). The champion gains them only by proposing them as a
  candidate and passing the acceptance rule on its own secret split.
* **Abstraction has less to bite on than the literature suggests, and this was measured here.**
  Library learning (DreamCoder) needs a task distribution with recurring structure. Uniformly random
  composition has none: across 99 solved tasks there were 17 multi-operator templates, every one used
  exactly once. The generator was changed to draw depth-2 subexpressions from a motif pool shared by
  every split, which is closer to how real domains look. Reuse improved but stayed thin, for a
  reason worth stating: observational-equivalence bottom-up search returns the *smallest* program
  fitting the examples, which is often not the one the generator used, so the shared structure is
  erased in the solutions the library learner gets to mine. Abstraction operators therefore fire, but
  rarely clear the acceptance bar. That is a property of this search regime, reported rather than
  papered over.
* **Task families are generated by the kernel.** Hidden operators and spawned variants keep the
  distribution moving, and external ARC tasks are real and never trained on, but the space is still a
  typed DSL over lists, integers and small grids.
* **The engine improved; the autonomous loop still has not.** This distinction is the whole point and
  it should not be blurred. The +7.6pp came from an *engineered* change to the search architecture,
  proposed and verified by hand against independent task sets. The self-improvement loop's own
  operators — library learning, abstraction, prior fitting, pruning — have still accepted **nothing**:
  the last clean run was 12 generations, 48 candidates, all eleven operators exercised, a corpus of
  315, zero acceptances, best candidate +2.0pp at p=0.103. So the honest summary is that the harness
  works, the search engine got substantially stronger by ordinary engineering, and genuine *recursive*
  self-improvement — the system finding changes of this size in itself — has not been demonstrated.
  The new mechanisms are exposed to the mutation operators (`bidirectional`, `binary_meet`,
  `back_max_cost`, `back_after_cost` are all perturbable), so the loop can now explore this part of
  the design space too, but no claim is made that it will.

## What to expect when you run it

The champion starts at about 76% on its secret held-out split (was 70.5% before the bidirectional
engine). The acceptance bar is deliberately demanding: on 200 held-out tasks a candidate needs roughly
nine wins against at most one loss to reach p<0.05. Small true effects are invisible at that sample size,
which is why the held-out split is large rather than the threshold loose. Two things change as it
runs on your server that could not happen here: the solution corpus grows into the thousands, which
is what the abstraction operators need, and the research fetcher pulls real ARC-AGI tasks into the
external evaluation (outbound HTTPS was blocked in the environment this was built in, so `ARC 0/0`
in the console simply means none have been fetched yet).

## Run locally

```
lua run.lua step        # one generation
lua run.lua loop 20     # forever
lua run.lua status      # state summary
lua run.lua eval        # evaluate the champion on fresh splits (no mutation)
lua run.lua research    # force a research fetch
lua run.lua selftest    # verify the external ARC benchmark path end to end
lua main.lua            # the CELL2 way: transpiles CELL2 -> source/execute.lua and runs the loop
```

`selftest` writes two ARC-format tasks to a temp directory, loads them through the same code path the
real fetcher feeds, solves them and verifies on their held-out test example. Run it after deploying:
it confirms the external benchmark works before any real ARC data has been fetched. It never writes
to `rsi/data/arc`, so the real benchmark cannot be polluted with synthetic tasks.

Console: open `rsi/www/index.html` from a web server (it polls `state.json`, `progress.json`,
`lineage.jsonl`).

## Deploy on your web server

```
sudo apt-get install -y lua5.4 curl            # or luajit
sudo bash deploy/install.sh /var/www/html/research-<random-string>
```

That copies the project, writes `.htaccess` (no indexing, sources blocked), installs and starts
`cell4-rsi.service` (systemd, restarts on failure, low CPU weight). Console URL:
`https://<host>/research-<random-string>/rsi/www/`. For nginx use `deploy/nginx-snippet.conf` instead
of `.htaccess`. Logs: `journalctl -u cell4-rsi -f`. Runtime state lives in `rsi/state`, `rsi/versions`,
`rsi/data` and is not in git.

Research cadence and every budget/threshold live in `rsi/config.lua`.

Only one generation may run at a time. `rsi/state/.lock` is taken with an atomic `mkdir` and released
at the end of the generation; a second process refuses to start rather than interleave writes into
the same lineage. A lock left behind by a killed process is broken after 30 minutes. This was not
hypothetical during development: three loops ran against one state directory and produced an
acceptance that no single run reproduced.
