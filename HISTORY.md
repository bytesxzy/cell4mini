# CELL4 history

The system's own account of what happened, newest first.

The wording comes from `rsi/lm/markov.lua`, an n-gram Markov **language model** trained by
counting on `rsi/lm/corpus.txt` and sampled with backoff -- the pre-neural kind of language
model: no network, no gradient, no external service. When no sampled sentence passes
verification, the deterministic template generator in `rsi/kernel/narrator.lua` writes that
sentence instead, and the entry says which produced what.

**No number here comes from the model.** Its vocabulary contains no numerals at all; every
quantity arrives through a slot filled from audited measurements after sampling, and any
sentence carrying a numeral the facts do not contain is discarded and re-drawn. Those facts are
recomputed from the raw results before a sentence is allowed to stand. Where a recomputation
disagreed, the correction is recorded below the entry rather than quietly applied.

Capitals mark events by rule, not for decoration: a result significant under both tests, a
regression loss, a saturated benchmark, a new champion.

## Generation 9 — 2026-09-02 22:10 UTC

*n-gram Markov LM, seed `1788387022:269945:9:0`, 5 sentence(s) sampled and 1 from the template fallback.*

The tally for generation 9 on 78.6% of the 220 tasks I have never been tuned against.
655 nodes deep on average.
Every one of the 4 was parameterized_abstraction at 0.5 points and still failed to convince either test.
Screening is cheap and it took 2 out of the running immediately.
The family with most left to teach me is grid_d3, which I solve 59.4% of the time. *[template]*
I remember 709 solutions and have generalised 0 of them into abstractions.

## Generation 8 — 2026-09-02 22:06 UTC

*n-gram Markov LM, seed `1788386817:381844:8:0`, 6 sentence(s) sampled and 0 from the template fallback.*

I ended generation 8 on 78.6% of the held-out set.
Behind me sat 0 regression tasks stood as a floor, and nothing in the regression suite held 0 tasks behind me and I lost none of them.
Nothing was accepted; strategy_swap came nearest with 1.4 points and it was not enough.
Screening saved the cost of four more splits on 1 candidates lost ground immediately and were not worth evaluating further.
At 59.3% solved.
629 solved programs on record and 0 learned abstractions.

## Generation 7 — 2026-09-02 18:26 UTC

*Template generator only: no LM corpus was available for this entry.*

Generation 7: 173 solved out of 220 held-out tasks (78.6%).
Adversarially I managed 24 of 32; 0 regression tasks stood behind me; the mean task took 655 nodes.
None of the 4 candidates survived, and none even gained.
4 of them solved strictly fewer held-out tasks and were screened out before the other splits were even run.
grid_d3 is where I still learn the most: 59.0% solved, and it still separates one candidate from another.
My corpus stands at 545 solved programs; the library holds 0; across the whole run 0 of 28 candidates were kept.

