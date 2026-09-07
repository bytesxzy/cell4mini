# GABRIEL chat

A popup assistant for the site, in two files and a folder.

```html
<script src="gabriel-chat/brain/brain.js"></script>
<script src="gabriel-chat/gabriel-chat.js"></script>
```

That is the install. Put those two lines before `</body>` on any page you want
it on. It is already wired into `index.html` and `service.html`.

**No external model, no API key, no server, no build step.** Everything runs in
the visitor's browser. Nothing typed into it leaves the page.

## Try it locally

Double-click `gabriel-chat/demo.html`. It works straight off the disk — the
brain is a `.js` file rather than JSON precisely so that `file://` does not hit
a CORS wall.

## How it answers

`build_brain.py` reads the site's pages and writes `brain/brain.js`. The widget
scores every passage against your question two ways and adds them:

- **BM25** — lexical overlap, so an exact word always counts. Words that share
  a four-character stem match too, which is how "worked" finds "work" and
  "pricing" finds "price" without a stemmer that would have to be kept
  identical in Python and JavaScript.
- **Query likelihood** — `gabriel.lm.GabrielLM`, the same sparse log-linear
  model that models ARC programs in `astraarcengine-improved/`, trained here on
  this site's English. In the engine it conditions on a task's signatures and
  models a program; here it conditions on a passage's heading and models that
  passage's words. A passage scores well when the model, conditioned on that
  passage, finds your question's words probable. The trained weights ship as
  they are and the browser runs the real softmax.

The reply is then assembled **from the site's own sentences**, with a link to
the page it came from. It cannot invent a fact, because it has no mechanism for
producing a sentence that is not already published. For a portfolio that is the
right trade: a model that could write freely could also write a price you never
agreed to.

If nothing shares a word with the question, it says so rather than returning
whichever passage the priors happened to like.

## Rebuilding the brain

Run this whenever the site's text changes — otherwise the assistant answers
from the old copy.

```bash
cd gabriel-chat
python3 build_brain.py                              # read the .html next door
python3 build_brain.py --url https://cell4.art/ --crawl 8   # read the live site
```

Python 3.8+, standard library only. The `--url` form fetches the live pages and
follows same-site links, so it works from any machine that can reach the site.

Current brain: 11 passages, 144-word vocabulary, **66 KB**, built in under a
second.

## Reading more of the internet

Two honest limits, so nothing here surprises you later:

1. A page cannot fetch arbitrary third-party sites from the visitor's browser —
   the same-origin policy blocks it, and no amount of JavaScript gets around
   it. What *can* be read live is the site's own pages, because those are same
   origin.
2. There is no external model, by design. The assistant is a retrieval system
   over your content, not a general conversationalist. Ask it about the site
   and it is good; ask it about the weather and it will tell you it only knows
   this site.

To widen what it knows, widen the brain: `--crawl` more pages, or point
`--url` at another page of yours, or write the extra facts into an HTML file in
the folder and rebuild.

## Tuning

```html
<script>
window.GABRIEL_CHAT_CONFIG = {
  title: "CELL4 assistant",
  subtitle: "reads this site · runs in your browser",
  greeting: "Ask me anything about CELL4.",
  suggestions: ["What do you charge?", "Which Roblox games?"]
};
</script>
```

Set that **before** `gabriel-chat.js`. Colours live at the top of
`gabriel-chat.js` in the `CSS` array — `rgba(6,6,6,.58)` for the glass,
`#e33232` and `#ff6347` for the accents, matching the site.

The answer vocabulary — the words a visitor might use that the site never
prints, like "cost" for "pricing" — is the `ALIASES` table in
`build_brain.py`. Add to it and rebuild. Aliases only expand the *question*;
the answer still has to be retrieved from a real passage.

## Files

```
gabriel-chat/
  build_brain.py     reads the site, trains the model, writes the brain
  gabriel-chat.js    the widget: retrieval, answering, glass UI
  demo.html          open this locally to try it
  brain/brain.js     generated -- do not edit by hand
```

The widget mounts in a shadow root, so the site's global `h2` and `a` styles
cannot leak into it and its styles cannot leak out.
