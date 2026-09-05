# CELL4

A self-improving program-synthesis system for ARC-style tasks. Everything is Lua.
There is no neural network, no API key, no external model and no network call
except the research fetch (arXiv metadata and public ARC task files over `curl`).

## The execution contract

    ONE INVOCATION
      -> load the persisted state
      -> run ONE complete generation
      -> persist state, benchmarks, genome, lineage, journal, narrative
      -> derive live.json from what was just committed
      -> EXIT

A later invocation by an **external** scheduler continues from those files.
There is no orchestration loop, no daemon, no sleep-and-repeat, no relaunch and
no process supervision anywhere in this tree. `cell4.lua loop` exists only to
refuse and exit 1, so nobody can resurrect the old always-on behaviour by
habit.

That is a design decision, not a limitation: the system's entire memory lives on
disk, so a process that dies mid-run costs at most the generation it was in.

## Running it

**Replit.** Press Run, or use `luajit cell4.lua step`. For continuous operation
use **Deployments -> Scheduled Deployment** with `luajit cell4.lua step` and
whatever interval you want. Do **not** use a Reserved VM / Always On deployment:
there is nothing here to keep alive.

**cPanel / Namecheap cron.** Use the bundled wrapper, which is one `cd` and one
`exec` — no loop, no background process:

    */30 * * * * /home/USER/cell4/run-once.sh >> /home/USER/cell4/cron.log 2>&1

**Anywhere else.**

    cd /path/to/cell4 && luajit cell4.lua step

The `cd` is not optional. Every path in the program is relative to the working
directory (`rsi/`, `live.json`), so running `luajit /path/to/cell4.lua` from
elsewhere would start a second, empty installation and report generation 1
forever. The program detects exactly that and refuses with a non-zero exit and
the correct command line, instead of quietly resetting.

## Commands

    luajit cell4.lua              one generation (same as `step`)
    luajit cell4.lua step         one generation
    luajit cell4.lua status       generation, totals, recent log
    luajit cell4.lua research     force a research fetch now (takes the same lock)
    luajit cell4.lua eval         evaluate the champion, mutating nothing
    luajit cell4.lua narrate [d]  replay the latest account, a word at a time
    luajit cell4.lua history      print HISTORY.md
    luajit cell4.lua selftest     end-to-end check of the ARC path + narrator audit
    luajit cell4.lua unlock [force]  clear a lock left by a killed generation
    luajit cell4.lua transpile    the original CELL2 transpiler (unrelated to the RSI kernel)
    luajit cell4.lua loop         refuses, exit 1

## What persists, and where

| Path | What it is |
| --- | --- |
| `rsi/state/state.json` | generation counter, totals, corpus window, challenge ranking, narration |
| `rsi/state/bench.json` | secret held-out salt, epochs, regression suite, family variants |
| `rsi/state/lineage.jsonl` | every candidate ever evaluated, with its verdict and evidence |
| `rsi/genome/dsl_base.lua` | the mutable primitive selection |
| `rsi/genome/library.lua` | learned abstractions |
| `rsi/genome/policy.lua` | search costs, constants, budgets, strategy |
| `rsi/genome/search.lua` | the search engine itself |
| `rsi/data/corpus.jsonl` | the durable training record: every visible-split solution |
| `rsi/data/journal.jsonl` | structured events (research, acceptances, rotations) |
| `rsi/data/narrative.jsonl` | the system's own account of each generation |
| `rsi/data/arc/*.json` | downloaded ARC tasks — the external benchmark, never trained on |
| `rsi/data/research/` | fetched paper metadata and the fetch log |
| `rsi/versions/g*/` | genome snapshots per candidate; champions kept forever |
| `rsi/www/`, `JOURNAL.md`, `HISTORY.md` | derived views |
| `live.json` | derived summary of the latest **committed** generation |

The four `rsi/genome/*.lua` files are written on first run only if they are
missing. An accepted improvement overwrites them, and the next invocation loads
the improved genome. Nothing here is reset by the process exiting.

`live.json` is a derived output, never the source of truth. It is written only
after a generation commits, is re-read from `state.json` rather than from
memory, and is left untouched when a generation fails (which also exits
non-zero).

## Concurrency

A single-writer lock (`rsi/state/.lock`, an atomically created directory) stops
two scheduled runs from interleaving writes into `rsi/state`. The holder
refreshes a timestamp inside it as it works, so a lock is treated as stale only
after an hour of *silence*, not after an hour of running — a generation may
legitimately take hours. A run that finds a live lock exits 1 and does nothing;
the scheduler simply tries again later. If a process is killed outright its lock
survives, and `luajit cell4.lua unlock` clears it (it refuses while the
timestamp still looks live; `unlock force` overrides).

## LuaJIT

This build targets LuaJIT 2.1 and also runs unmodified on PUC Lua 5.1, 5.3 and
5.4. Two LuaJIT-specific things are handled explicitly:

* `os.execute` returns an exit-status **number** on LuaJIT and 5.1, and `true` /
  `nil` on 5.2+. Every number is truthy in Lua, including 0, so a bare
  `if os.execute(...)` is always true on LuaJIT. The lock tests both shapes.
* A `count` debug hook is only called from the interpreter — LuaJIT does not
  check hooks inside a compiled trace. The solver's instruction budget is
  therefore enforced by marking the sandboxed call non-compilable for its
  duration; everything else (task generation, evaluation, statistics, JSON,
  serialisation, the narrator) still gets the JIT. Setting
  `CELL4_JIT_SOLVER=1` keeps the JIT on inside the sandbox: faster, but the
  instruction budget stops being enforceable and only the solver's own node and
  wall-clock caps remain.

## Throttling it

Four environment variables lower how much CPU one invocation spends, without
editing this file:

    CELL4_CANDIDATES=1        candidates evaluated per generation (default 4)
    CELL4_SECONDS=1           per-task solver wall clock (default 3)
    CELL4_NODES=800           per-task solver node budget (default 3000)
    CELL4_EXTERNAL_CAP=20     ARC tasks per generation (default 60)

Measured, one generation on one core: defaults ~117s, `CANDIDATES=1 SECONDS=2
NODES=2000` ~76s, `CANDIDATES=1 SECONDS=1 NODES=800` ~10s.

`alpha`, `bootstrap_reps`, the held-out split size and the adversarial tolerance
are deliberately **not** settable this way. Those set the evidential bar;
lowering them would not make the system cheaper, it would make it start
accepting changes the evidence does not support.

Changing `SECONDS` or `NODES` changes what "solved" means, so the budget profile
is part of the champion's cache key: a changed budget forces a full
re-measurement rather than comparing a candidate against a champion scored under
a different budget. The profile is logged, stored in `state.json` and published
in `live.json` as `budget`, because two generations at different budgets are not
directly comparable.

See `NAMECHEAP.md` for shared-hosting deployment and the policy questions it
raises.

## Self-improvement

Each generation loads the current genome, generates candidates with one of
fourteen mutation operators, evaluates champion and candidates on a visible
split, a secret held-out split, a fresh adversarial split, a regression suite of
everything previously solved, and the external ARC set, then applies an
acceptance rule: no regression loss, no external-ARC loss, no adversarial drop
beyond tolerance, and a held-out gain significant under **both** a paired
bootstrap and an exact sign test (or an equal-score win on search efficiency).
Accepted changes are written to `rsi/genome/` and are the champion for the next
invocation.

## Narration

`rsi/kernel/narrator.lua` writes the system's account of each generation. It is
procedural — a sentence bank with multiple phrasings, selected by a seeded PRNG
— and every sentence declares which facts it uses. Those facts are then
recomputed independently from the raw per-task vectors; a sentence whose facts
disagree is struck and reissued with the corrected value, and the correction is
recorded. It cannot state a number it did not measure, and there is no language
model in the loop. Two or three of those lines are committed into `state.json`
and published in `live.json` as `lines`, with `narrated_gen` saying which
generation they belong to.
