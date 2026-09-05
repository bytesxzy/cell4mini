# CELL4 — read this before doing anything

You are probably a nightly scheduled run with no memory of previous nights. Previous nights had
the same problem and it cost real work. Read this file first; it exists so you do not start over.

## The single most important instruction

**Do not start from scratch. Do not re-derive the state from the code.** Substantial verified work
already exists. Find it, read it, continue it. If your task prompt says "improve AI reasoning for
cell4.lua", that work is `cell4/` on the branches listed below — not a blank page.

## What this repository actually contains

Two unrelated things, which has confused past runs:

1. **The repo root is a static website** — `index.html`, `menu.html`, `service.html`, `frame.html`
   plus images. It is the CELL4 team's portfolio site (3D modelling and scripting commissions).
   "CELL4" there is just the team's brand name. Nothing to do with the Lua work.
2. **`cell4/` is the AI reasoning work.** A program-synthesis system that solves ARC-style tasks
   by bottom-up enumeration over a typed DSL of 105 primitives, wrapped in a mutation/acceptance
   loop. Single file, ~6,700 lines, plain Lua. No neural network anywhere, by design.

### An ambiguity that is NOT yet resolved by the owner

One earlier night, finding no `cell4.lua` in git, guessed the target was a **real-time game NPC AI**
(utility-AI + GOAP planner + a bridge to an external training server) and wrote an architecture for
that on branch `claude/festive-meitner-g6rdiz`. That guess is almost certainly wrong — the ARC
system's genome fingerprints identically to the owner's production champion (see below) — but the
owner has been asked and has not confirmed. **If you are about to spend a night building, and the
answer matters, ask rather than guess.**

## Where the work lives (branches — this repo fragments badly)

Every nightly run gets a new random branch and past runs did not find each other. Before starting:

    git ls-remote origin        # see every branch, including other nights' work
    git log --oneline --all -- cell4/

| branch | what is on it |
| --- | --- |
| `claude/festive-meitner-39cd9g` | **Current. Nights 1+2 consolidated. Start here.** |
| `claude/festive-meitner-wt1fas` | Night 1 original (benchmark-bug fix). Superseded by the above. |
| `claude/lua-transpiler-analysis-bul3g8` | Earliest lineage; the full `rsi/` kernel tree |
| `claude/cell4-adversarial-audit-6thmhn` | Deployment hardening, Namecheap/Replit notes |
| `claude/festive-meitner-g6rdiz` | The game-NPC misinterpretation. Do not build on it. |

`main` has **none** of this. If a future run is to find this work automatically, `cell4/` and this
file need to reach `main` — the owner has been asked and has not yet decided.

## Read these, in order

1. `cell4/ARCHITECTURE.md` — the standing plan, revised when a measurement contradicts it.
2. `cell4/NIGHT-02.md` — most recent night; strikes two plan steps.
3. `cell4/NIGHT-01.md` — the benchmark-bug investigation.
4. `cell4/README.md` — how to reproduce every measurement.

## Established facts — verified, do not waste a night re-deriving

- **The champion genome fingerprints `04da6714`**, identical to the owner's production champion.
  A local checkout therefore behaves exactly like the server.
- **The champion has never changed.** 0 candidates accepted across 73 generations. The "self
  improvement" loop has never once improved anything. The learned library is empty after 6,136
  solved programs.
- **Real ARC ability, same champion and budget, by split:**
  ARC-AGI-1 *training* 39/400 (9.75%) · ARC-AGI-1 *evaluation* 7/400 (1.75%) · ARC-AGI-2
  evaluation 0/120 (0.00%). The often-quoted **8.36% is the training-split score** — the corpus's
  `arc1_` half *is* ARC-AGI-1 training. Quote the evaluation splits.
- **~90–100% of real-ARC failures are "no program in reach at any budget."** Not a search-tuning
  problem. More compute does not touch it (13× budget bought +4.4pp).
- **The adoption pool is empty.** All 105 non-hidden catalogue ops are already in the genome DSL.
- **Mutations are significantly harmful on average** (908 wins vs 987 losses, p=5.7e-05). The
  acceptance test is correct to reject them. The generator is the bottleneck, not the judge.

## Traps. Each of these has already cost someone a night

1. **The 21 `hidden = true` ops are off limits.** They exist so task *generators* can build targets
   the solver must reach by composition. `genome.load` refuses them (`not o.hidden`). Exposing them
   raises the held-out score instantly and means nothing — it is scoring against the answer key.
   Every so often this looks like free progress. It is not.
2. **Never trust a measurement without an independent control.** This has now bitten twice: a
   benchmark reported 0% for 67 generations because it sorted filenames and took a fixed prefix
   containing no solvable tasks; and a selection harness produced a clean result that disagreed
   with the unmodified solver by 17 tasks. Both looked entirely plausible. Every harness in
   `cell4/bench/` ships with a control — keep it that way.
3. **Genome files on disk shadow the embedded copies.** `genome.load()` reads `rsi/genome/*.lua`
   from disk; `_write_if_missing` only writes when absent. **Kernel changes ship; genome changes do
   not.** Editing the DSL or `search.lua` inside `cell4.lua` is a no-op on a deployed tree.
4. **Every added primitive widens branching at every enumeration level.** 8 unconditional library
   additions were measured at −2.7pp. A primitive must earn its place.
5. **`rsi/data/`, `rsi/state/`, `rsi/versions/`, `rsi/www/` are live server state** and are
   gitignored. Running `cell4.lua` from the repo root creates a stray `rsi/` — do not commit it.

## The open decision, which needs the owner and not another night of building

The reach failures do **not** cluster. Across 150 surveyed ARC tasks the missing capabilities
fragment into 87 distinct gaps; the largest covers 6 of 400 tasks, and 49 of 54 addressable ones
cover exactly one task each. Meanwhile **a third of inexpressible tasks need iteration or binding
that no first-order primitive can express** — "recolour each object by size rank", "stamp this
motif at every marker". The DSL is a composition over one variable `$` with no lambdas, no loops
and no let-binding.

So the fork is:

- **(a)** keep adding first-order primitives — cheap per step, but worth ~1 task each and on the
  system's own evidence roughly break-even after branching cost; or
- **(b)** extend the *language* with bounded iteration over objects/regions — where the mass of
  failures actually is, but a much larger change touching `search.lua` (genome-shadowed, see trap
  3) and the whole enumeration cost model.

The measurements favour (b). **Nothing should be built until the owner chooses.**

## Owner's standing preferences

- Do not train here. Training runs on the owner's servers. This repo is architecture, analysis and
  measurement only.
- Be genuine about progress. The owner has explicitly asked not to be told things that are not so.
  A night that honestly reports "this step is impossible and here is why" is worth more than a
  night that ships something plausible.
- Be aware of token usage, but do not trade away rigour for it.

## Unfinished, pick this up

- **Selection measurement.** `cell4/bench/measure_selection.lua` + `search_collect.lua` collect
  every train-consistent program instead of only the first. Validated against a control, but the
  full run never finished — collect mode burns its whole budget per task and is slow. Needs a
  bounded re-run. Until then the selection lever's value is unquantified.
- **250 of 400 design tasks unsurveyed**, and the gap-clustering stage never ran (session limit).
  The "no primitive is worth adding" conclusion rests on 150 tasks and should rest on 400.
- **Two acceptance defects** flagged in `NIGHT-01.md` §6 await the owner's decision. The first
  (adversarial tolerance finer than the split's resolution) was confirmed in `NIGHT-02.md` §7.
