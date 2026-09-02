# CELL4 · recursive self-improvement research loop

An autonomous, LLM-free experimental system that tries to improve its own problem-solving architecture
and only keeps a change when a skeptical evaluation harness finds real evidence for it.

* **Intelligence:** a program-synthesis engine (`rsi/genome/search.lua`) that solves input→output tasks by
  cost-guided bottom-up enumeration with observational equivalence, Probe-style just-in-time cost learning,
  and a growing library of learned abstractions (DreamCoder-style). Written in plain Lua; runs under
  Lua 5.4 or LuaJIT. No external model, no API in the reasoning path.
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
* **Scores go up only when evidence says so, and in this build they did not go up.** The final clean
  run was 12 generations, 48 candidates, every one of the eleven operators exercised, a solution
  corpus of 315, and **zero acceptances**. The champion held 141/200 throughout. The best candidate
  was a task-conditioned prior at +2.0pp (bootstrap p=0.103, sign p=0.145, 6 wins against 2 losses),
  correctly rejected. That is the honest state of the system as delivered: it searches a real space,
  it measures itself against evidence it cannot see in advance, and so far nothing has cleared the
  bar. A system that reported daily gains under this rule would be lying. The lineage table shows
  every candidate, its delta, both p-values and why it failed.

## What to expect when you run it

The acceptance bar is deliberately demanding: on 200 held-out tasks a candidate needs roughly nine
wins against at most one loss to reach p<0.05. Small true effects are invisible at that sample size,
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
