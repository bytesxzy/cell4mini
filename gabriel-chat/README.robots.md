# robots.html

One file. Drop it anywhere, open it, or iframe it. 193 KB, no dependencies, no
build step at page load, no API key, no server.

```html
<iframe src="robots.html" width="392" height="600"
        style="border:1px solid rgba(0,0,0,.09);border-radius:14px;background:transparent"
        title="CELL4 assistant"></iframe>
```

It notices when it is inside a frame and fills it. Loaded top-level it floats a
launcher bubble in the corner instead, so you can test it standalone before
deciding where it goes.

## What it reads

**At build time** — the site's own pages, turned into passages and a trained
language model, both inlined into the file.

**At runtime, in the visitor's browser** — `/astron/xyz/`. It fetches the
directory, follows the links inside it to `.md`, `.py`, `.js`, `.json`, `.txt`
and `.html` files (14 max, 260 KB each), chunks them, and adds them to what it
can answer from. Markdown splits on its headings; source files split into
45-line blocks under the filename. Results cache for six hours.

Verified against a real directory containing `ARCHITECTURE.md`, `lm.py` and a
README: 24 built-in passages became 81, and "how does the enumerator search
work" was answered out of `ARCHITECTURE.md` with the file named as the source.

Change what it reads:

```html
<script>window.ROBOTS_CONFIG = { sources: ["/astron/xyz/", "/docs/"] };</script>
```

Same origin only. A browser will not let any page fetch a third party's site,
and no amount of JavaScript changes that — which is also why this cannot read
the open internet, only yours.

## Public databases — sixteen, no keys

When the site's own pages cannot answer, the page queries public APIs that take
no key and no account. Nothing to sign up for, nothing to paste into a config.

| | |
| --- | --- |
| **Wikidata** | ~115M structured entities — people, companies, products |
| **Wikipedia** | article intros, full-text search |
| **GLEIF** | the global registry of legal entities: real companies, addresses, status |
| **OpenAlex** | ~250M scholarly works |
| **Crossref** | DOIs and journal metadata |
| **GitHub** | repositories, stars, languages |
| **Stack Overflow** | questions and accepted answers |
| **Hacker News** | discussion threads |
| **Open Library** | books and authors |
| **CoinGecko** | tokens, symbols, market-cap rank |
| **REST Countries** | capitals, populations, currencies |
| **Open-Meteo** | places and coordinates |
| **npm / PyPI** | packages and versions |
| **Datamuse** | definitions and related words |
| **Open Food Facts** | products and ingredients |

**Site first, always.** CELL4's own pages outrank every outside source, so
nothing external can speak over the site about the site. The lookup fires only
when local retrieval finds nothing, when the question says so ("search…",
"look up…"), or when the ◍ button is on. A question is routed to the four most
relevant databases rather than all sixteen — asking everything every time is
slower, ruder to the services, and no better.

Results come back as ordinary passages: ranked by the same BM25 + query
likelihood, cited with a link, labelled with the database they came from, and
available to the learner like anything else.

### Why it checks itself

The constraint is not cost, it is **CORS**. A page may only read an API that
chooses to send `Access-Control-Allow-Origin`, and that choice lives on their
servers — it can change without warning and differ by network.

So no source is trusted. The first failure is recorded, the second disables it
on that device for a day, and the rest carry on. Click **"N databases"** in the
status line (or run `robots.diagnose()` in the console) to probe every source
and get the live verdict from your own browser:

```
8 of 16 public databases answered from this browser just now:
  OK  CoinGecko — 1 result (26ms)
  --  Crossref — blocked or down (13ms)
  OK  Wikidata — 2 results (16ms)
  ...
```

That is real output from the test run. **Run it once after you upload the file**
— it is the only way to know what your visitors' browsers can actually reach,
and it takes five seconds.

### LinkedIn

Not possible, and I would rather say so than ship something that looks like it.
Every LinkedIn API — Marketing, Talent, Sign In with LinkedIn — requires OAuth
plus partner approval; their servers send no CORS headers to a page like this;
and scraping profiles breaches their User Agreement. Anything advertising
"keyless LinkedIn data" is a paid scraper reselling data of contested
provenance behind a key, which is the opposite of what you asked for.

People and companies are served instead by **Wikidata** (notable people and
organisations, structured) and **GLEIF** (the registry of legal entities, with
addresses and ownership) — open by design rather than open by accident.

## How it answers

Two scores, added:

- **BM25** — lexical overlap. Words sharing a four-character stem count too, so
  "worked" reaches "work" without a stemmer that would have to be identical in
  Python and JavaScript.
- **Query likelihood** — `gabriel.lm.GabrielLM`, the sparse log-linear model
  the ARC engine reasons with, trained here on this site's English. It
  conditions on a passage's heading and models that passage's words; a passage
  scores well when it finds your question's words probable. The trained weights
  are in the file and the browser runs the real softmax.

Plus a bonus when a heading covers the whole question, because "What does CELL4
do?" is one word once the stop list has had it, and term frequency alone hands
that to whichever passage repeats "CELL4" most — usually the nav bar.

Replies are assembled from the site's own sentences and cite the file they came
from. It cannot invent a fact. Ask it something the site does not cover and it
says so.

## The part that learns

Every answered question is a labelled example: *these words went with that
passage*. The page takes a gradient step on that passage's own rows of the
language model — the same update rule as the Python trainer — and then applies
the same gate the ARC engine lives by: it re-ranks a held-out set of earlier
questions, and if their mean reciprocal rank got worse, the step is thrown
away. The status line shows the tally (`learned 4/5` = five steps tried, four
kept).

The ↑ / ↓ buttons on each answer are a stronger signal of the same kind: ↑
pushes those words toward that passage, ↓ pushes them away.

This is per-browser, stored in `localStorage`, and never leaves the device —
there is no server for it to leave to. **`export` in the status line downloads
what this browser learned**, which is how it gets back into the trained model:
the deltas are keyed by the same feature names `build_brain.py` writes, so they
can be folded into the shipped weights on the next build. That is the loop
closing — usage on the page improving the model the page ships with.

## Rebuilding

```bash
cd gabriel-chat
python3 build_robots.py --url https://cell4.art/ --crawl 10
python3 build_robots.py --dir /path/to/folder/with/index.html
python3 build_robots.py --sources /astron/xyz/,/docs/
```

Python 3.8+, standard library only. Rebuild whenever the site's text changes —
otherwise it answers from the old copy.

Design tokens are taken from cell4.art's own stylesheet (`--oat`,
`rgba(255,255,255,.58)` glass, `#f0f0f3` ground, `#0a0a0a` accent, 10/14px
radii, Figtree / Space Grotesk / JetBrains Mono) and live at the top of
`robots.template.html`. Light and dark both ship; the ◐ button toggles.

## Files

```
robots.html            the artefact -- this is the only file you deploy
robots.template.html   the shell and the design tokens
robots.runtime.js      retrieval, live reading, federation, learning, UI
robots.sources.js      the sixteen public databases and how to read each
build_robots.py        inlines the brain and the runtime into robots.html
build_brain.py         shared: reads pages, trains the model
```
