# CELL4 history

The system's own account of what happened, newest first. Written by
`rsi/kernel/narrator.lua`, which is a procedural generator over audited measurements -- **not a
language model**: there is no network, no training on text, no external call, and it cannot
state anything that is not a measured number. Phrasing varies; content does not.

Every sentence declares the facts it uses, and those facts are recomputed from the raw results
before the sentence is allowed to stand. Where a recomputation disagreed, the correction is
recorded below the entry rather than quietly applied.

Capitals mark events by rule, not for decoration: a result significant under both tests, a
regression loss, a saturated benchmark, a new champion.

## Generation 7 — 2026-09-02 18:26 UTC

Generation 7: 173 solved out of 220 held-out tasks (78.6%).
Adversarially I managed 24 of 32; 0 regression tasks stood behind me; the mean task took 655 nodes.
None of the 4 candidates survived, and none even gained.
4 of them solved strictly fewer held-out tasks and were screened out before the other splits were even run.
grid_d3 is where I still learn the most: 59.0% solved, and it still separates one candidate from another.
My corpus stands at 545 solved programs; the library holds 0; across the whole run 0 of 28 candidates were kept.

