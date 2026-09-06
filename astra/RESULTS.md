# Measured results

All numbers on this page were produced by the code in this directory, on the
550 public ARC task files in `data/arc/`, in this environment. Nothing is
estimated, extrapolated, or carried over from another machine.

<!--RESULTS-TABLE-->

## How the comparison is made

The previous engine (CELL4 Astra V2) is written in Lua and needs LuaJIT, which
is not available in this container, so its column is **its own recorded
per-task run**, shipped in `evidence/baseline-v2-arc.json` — not a re-run and
not an aggregate rate. The comparison is paired: identical task files,
identical identifiers, a per-task win/loss table, and a one-sided sign test
over the discordant tasks. `bench/compare.py` asserts that the two task-id sets
are identical before it counts anything.

## Scoring rules

- A task counts as solved only when **every** test pair of that task is exact.
  Tasks with two test inputs must get both.
- **top-1** is one attempt per test input. **top-2** is the two attempts
  official ARC-AGI allows. Both are reported; top-1 is the headline.
- Mean cell agreement is recorded per task but is **never** scored — it is a
  diagnostic for finding near misses.
- Solver exceptions are caught, counted, and left in the denominator as
  unsolved. They are not excluded.
- The solver receives train pairs and test *inputs*. Test outputs stay in the
  harness; `engine/task.py`'s `Ctx` has no field that could hold them, and
  `tests/test_engine.py` asserts it.

## Reproducing

```sh
python3 -m unittest discover -s tests -v
python3 bench/run_arc.py --budget 20 --jobs 4 --out evidence/run.json
python3 bench/compare.py evidence/run.json
python3 bench/evolve.py --rounds 3 --budget 14 --jobs 4 --final-holdout
```

Timings vary with the machine; the solved set does not, except where a task
sits near its per-task deadline.

## Honest scope

These are public development sets. Public ARC training tasks informed which
solver families were worth writing, and the fit split participates in policy
selection. The holdout figure is the transfer estimate. Nothing here is an
official ARC-AGI hidden-test result and it should not be read as one.
