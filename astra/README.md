# ASTRA — an ARC-AGI reasoning engine

A from-scratch solver for ARC-AGI, written in pure Python with no third-party
dependencies, **no neural network, and no external model of any kind**. It
reads a task's demonstration pairs, searches a space of explanations, ranks
them by how much they compress the evidence, and applies the winner to the
held-out input.

It replaces the Lua symbolic-search engine in `cell4/` (CELL4 Astra V2). On the
same 550 public ARC task files, same identifiers, per-task comparison:

| | tasks solved | rate |
|---|---:|---:|
| CELL4 Astra V2 (previous engine) | 64 / 550 | 11.6% |
| **ASTRA** (this engine) | see `RESULTS.md` | |

`RESULTS.md` carries the current measured numbers, the win/loss table, the
sign test, and the self-improvement evidence. `ARCHITECTURE.md` explains why
the engine is built this way.

## Run it

```sh
python3 -m unittest discover -s tests -v          # 31 behavioural tests

python3 bench/run_arc.py --budget 20 --jobs 4 \
        --out evidence/run.json                   # measure all 550 tasks

python3 bench/compare.py evidence/run.json        # head-to-head vs the baseline

python3 bench/evolve.py --rounds 3 --budget 14 \
        --jobs 4 --final-holdout                  # gated self-improvement loop

python3 bench/show.py arc1_00d62c1b               # render one task as text
```

Nothing needs to be installed. Python 3.8+.

## Layout

```
engine/
  grid.py         immutable grid algebra: dihedral group, crops, scaling,
                  tiling, connectivity, holes, gravity
  objects.py      seven segmentations, object features, memoised caches
  task.py         Ctx (the no-leak boundary) and Hyp (a candidate rule)
  enum_core.py    bottom-up synthesis with observational-equivalence pruning
  portfolio.py    the orchestrator: validate, rank, vote
  learn.py        signature-conditioned priors, mined abstractions, policy I/O
  solvers/        18 independent hypothesis-generating families
bench/
  run_arc.py      measurement harness (parallel, structural no-leak guarantee)
  compare.py      paired comparison against the previous engine, with sign test
  evolve.py       self-improvement loop with a statistical adoption gate
  show.py         task viewer
data/arc/         the 550 public task files this engine is measured on
evidence/         measured runs, per task, with full settings recorded
policy/           learned policy and the lineage of accepted/rejected rounds
```

## What it is and is not

It is a portfolio of narrow, independently-derived hypothesis generators, a
general program synthesiser as the fallback, one description-length ranking
rule, and a learning layer that reallocates search effort and grows the DSL
from tasks it has already solved. Every adopted policy change has to pass a
paired sign test against the version it replaces.

It is not a trained model, it does not call an LLM, and the numbers here are on
public development sets — not an official hidden-test result. The honest limits
are written out in the last section of `ARCHITECTURE.md`.
