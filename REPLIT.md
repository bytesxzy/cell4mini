# Running CELL4 on Replit

Unzip into a blank Replit workspace and press **Run**. `.replit` starts `lua run.lua loop 20`, which
runs one generation, waits 20 seconds, and repeats forever.

## First things to try

```
lua run.lua selftest   # end-to-end check of the external ARC benchmark path (takes a few seconds)
lua run.lua eval       # score the champion on fresh splits without mutating anything
lua run.lua step       # exactly one generation
lua run.lua status     # what has happened so far
```

`eval` is the quickest way to see the engine working. Expect roughly:

```
train         78/100 solved  partial 0.91  nodes 731
heldout      155/200 solved  partial 0.88  nodes 684
adversarial   19/ 32 solved  partial 0.85  nodes 1046
```

A generation takes about 3–5 minutes on Replit's free tier, most of it in `heldout` (200 tasks) and
the candidate evaluations. If that is too slow, lower `heldout_per_family` and `candidates_per_gen`
in `rsi/config.lua`; the trade-off is statistical power, and the README explains why the held-out
split is large rather than the acceptance threshold loose.

## Watching the console

The dashboard is a static page that polls three files the loop writes. In a second shell:

```
cd rsi/www && python3 -m http.server 8080
```

Then open the webview. It shows the champion's held-out rate with a confidence interval, live
per-task progress, and the full lineage with both p-values for every candidate and why it was
rejected.

## Notes specific to Replit

* **Nothing to install.** Pure Lua 5.4, no rocks, no C modules. `replit.nix` pulls in `lua5_4`,
  `curl` (the research fetcher shells out to it) and `python3` (only to serve the console).
* **The research fetcher needs outbound HTTPS.** It pulls ARC-AGI training tasks into the external,
  never-trained-on evaluation set and logs recent arXiv abstracts, every 1.5 hours by default
  (`research_interval` in `rsi/config.lua`). Force one with `lua run.lua research`. Until it has run,
  the console shows `ARC 0/0`, which just means none have been fetched yet.
* **Runtime state** lives in `rsi/state`, `rsi/versions` and `rsi/data`. Deleting `rsi/state` resets
  the run, including the secret held-out salt, so scores before and after are not comparable.
* **One generation at a time.** `rsi/state/.lock` is an atomic `mkdir`; a second `run.lua step`
  refuses rather than interleaving writes into the same lineage. If Replit kills the process
  mid-generation the lock is broken automatically after 30 minutes, or delete it by hand.
* **Always-on** is what this wants if you intend to leave it running; free workspaces sleep, which
  just pauses the loop rather than corrupting anything.
* LuaJIT works too if you prefer it — the code avoids Lua 5.3+ only syntax.
