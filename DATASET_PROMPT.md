# Prompt for Grok (or any model) to grow the LM training corpus

The shipped corpus, `rsi/lm/corpus.txt`, is a seed of about 80 lines. It works, but with that little
data the chain mostly reproduces whole training lines and occasionally splices two together
awkwardly. More lines is the only fix — the accuracy guarantee does not change, because it comes from
the slot mechanism rather than from the data.

Paste everything between the rules below into Grok. Ask for 400–1000 lines. Append the result to
`rsi/lm/corpus.txt`, then run `lua run.lua lm` — it prints any line it rejected and why.

---

You are writing training data for a small n-gram Markov language model written in Lua. The model
narrates the progress of an automated program-synthesis research system: each generation it tries
changes to its own search algorithm, measures them against held-out tasks, and keeps a change only
if the evidence is statistically significant.

Produce ONE SENTENCE PER LINE. Each line must begin with a `[topic]` tag, then the sentence.

## THE ONE ABSOLUTE RULE

**No line may contain a digit.** Not one. Every quantity must be written as a `{slot}` from the list
below. A line containing a bare number is automatically rejected by the loader, because a Markov
chain that can emit numbers can emit false statistics, and the whole safety design of this system
rests on numbers coming only from verified measurements.

Wrong: `[standing] generation 7 closed with 161 of 200 solved .`
Right: `[standing] generation {gen} closed with {heldout_solved} of {heldout_n} solved .`

Also: do not write out numbers as words where a slot exists ("four candidates" → `{candidates}`).
Words like "one", "none", "every", "no" as ordinary English are fine.

## Slots

| slot | what it holds |
|---|---|
| `{gen}` | generation number |
| `{heldout_solved}` `{heldout_n}` `{heldout_pct}` | held-out tasks solved, total, percentage |
| `{adv_solved}` `{adv_n}` | adversarial split solved, total |
| `{regr_n}` | size of the regression suite |
| `{nodes}` | mean search nodes spent per task |
| `{candidates}` | candidates tried this generation |
| `{best_operator}` | name of the best-performing mutation operator |
| `{best_delta_pp}` | its held-out gain in percentage points |
| `{rejects_screened}` | candidates dropped on the held-out screen |
| `{rejects_regression}` | candidates that broke the regression suite |
| `{top_challenge}` `{top_challenge_pct}` | the most informative task family, and how often it is solved |
| `{saturated}` | a family that is solved almost always and no longer discriminates |
| `{corpus}` `{library}` | solved programs on record, learned abstractions |
| `{accepted_total}` `{candidates_total}` | accepted and tried across the whole run |

Not every line needs a slot, and no line should use more than about three — long slot-dense
sentences read like a form.

## Topics, and what each means

- `[standing]` — where the system stands after the generation. Uses `{gen}`, `{heldout_*}`.
- `[supporting]` — the secondary splits and search cost. `{adv_*}`, `{regr_n}`, `{nodes}`.
- `[verdict_none]` — nothing was accepted. `{candidates}`, `{best_operator}`, `{best_delta_pp}`.
- `[verdict_accept]` — a change was kept. Same slots. **May use the exact phrase `NEW CHAMPION`.**
- `[screening]` — candidates dropped early for solving fewer held-out tasks. `{rejects_screened}`.
- `[regression_loss]` — candidates that broke something already working. `{rejects_regression}`.
  **May use the exact phrase `LOST GROUND`.**
- `[challenge]` — which family still teaches it most. `{top_challenge}`, `{top_challenge_pct}`.
- `[saturation]` — a family is spent. `{saturated}`. **May use the exact phrase `SATURATED`.**
- `[memory]` — accumulated corpus and library. `{corpus}`, `{library}`, `{accepted_*}`.

Those three capitalised phrases are the only capitals allowed beyond normal sentence case. They are
reserved for genuinely significant events and the system budgets how many it prints.

## Voice

First person, as the system talking about itself, for its own later reference. Plain, measured,
slightly severe. It is not proud of itself and not miserable either. It reports.

Good: `[verdict_none] I proposed {candidates} changes to myself and refused every one .`
Good: `[challenge] {top_challenge} is where I still learn the most , at {top_challenge_pct} solved .`
Bad: `[verdict_none] Alas, my valiant efforts came to naught!` (florid)
Bad: `[verdict_none] Candidates: {candidates}. Accepted: none.` (not a sentence)

## Format details

- Put a space before the final full stop, and around commas and semicolons: `... of {heldout_n} , which is {heldout_pct} .`
  The tokenizer splits punctuation anyway, but consistent spacing keeps the n-gram counts clean.
- Lines starting with `#` are comments and are ignored.
- Vary sentence openings heavily. If forty lines in a topic all start with "I", the chain will almost
  always start that way too.
- Vary length: some five words, some twenty-five.

## How many

At least 40 lines per topic, ideally 80–120 for `[standing]`, `[supporting]`, `[verdict_none]` and
`[memory]`, which are used every generation. `[verdict_accept]` and `[regression_loss]` fire rarely,
so 30 each is plenty.

Output nothing but the lines. No preamble, no numbering, no code fence.
