# CELL4 — reasoning work

Nightly architecture work on the CELL4 program-synthesis system. No training happens here;
training runs on the owner's servers. This directory holds the analysis, the patches, and the
measured evidence for each change.

## Layout

| Path | What it is |
| --- | --- |
| `upstream/` | The build as received, unmodified. The baseline every measurement is taken against. |
| `upstream/cell4.lua` | The system: 6,742 lines, single file, kernel modules via `package.preload`. |
| `bench/` | Measurement harnesses. These only read; they never mutate `rsi/` state. |
| `NIGHT-01.md` … | One report per night: what was measured, what changed, what is still unknown. |

`upstream/rsi/data/`, `rsi/state/`, `rsi/versions/` and `rsi/www/` are **not** committed
(see `.gitignore`) — they are the live training state and belong on the servers. The harnesses
in `bench/` expect them to be present, so run them from a working copy of the server tree.

## Ground rules for this work

1. **Nothing is claimed that was not measured.** Every number in a night report came from a
   command that was actually run on this machine, and the command is quoted so it can be re-run.
2. **The baseline is re-measured, not assumed.** `upstream/` is never edited.
3. **Patches are tested before they are reported**, at the *production* budget from
   `upstream/run-once.sh` (`CELL4_NODES=800 CELL4_SECONDS=1 CELL4_EXTERNAL_CAP=20`), not at the
   more generous config defaults — otherwise the result would not describe the running system.
4. **Uncertainty is written down.** A night report has an "Open / unverified" section, and things
   go in it rather than being rounded up into claims.

## Running the harnesses

Both need `luajit` (2.1) and a working copy of the server tree with `rsi/` populated:

    cp -r /path/to/server/cell4 ./work && cd ./work
    cp /path/to/repo/cell4/bench/*.lua .

    luajit measure_arc.lua [cap] [nodes] [seconds]     # score the champion on the ARC corpus
    luajit test_window.lua [cap] [gens] [nodes] [secs] # fixed vs rotating external window

Neither runs `cell4.lua step`, so neither advances a generation, does network research, or
touches `rsi/state/`.

## Reproducing the night-2 measurements

The ARC corpus is not committed (`rsi/data/` is server state). To rebuild it from public sources:

    git clone --depth 1 https://github.com/fchollet/ARC-AGI.git      v1
    git clone --depth 1 https://github.com/arcprize/ARC-AGI-2.git    v2

Copy each task to `rsi/data/arc/` named `arc1_<id>.json` (ARC-AGI-1) or `arc2_<id>.json`
(ARC-AGI-2), keeping the original ARC JSON shape. Night 2 verified this reconstruction against
night 1's forensics exactly: `arc1_1cf80156` lands at sorted position 31 and the solvable tasks
at positions <= 50 are {31, 32, 36, 49}, both as recorded on the server.

    lua bench/dump_dsl.lua                       # catalogue vs genome DSL; the adoption pool
    lua bench/measure_design.lua <split> 2500 4  # score a split, decomposed by failure mode
    lua bench/control_eval.lua 800 1             # unmodified solver, for use as a control
    lua bench/diff_probe.lua                     # does a patched search agree with production?
    lua bench/check_defects.lua                  # acceptance-rule arithmetic

`bench/search_collect.lua` is a measurement-only variant of the search that exempts the target
key from OE dedup so every train-consistent program is collected instead of only the first. It is
not for production: with no early exit it consumes the whole node budget and starves the backward
phase, so it needs a larger budget than production to see what production sees.

Rule of thumb this repo now enforces: **every harness ships with a control.** Both nights so far
have produced a plausible number that turned out to be an instrument reading.
