"""Build the chatbot's brain from the site's own pages.

    python3 build_brain.py                          # read the .html next door
    python3 build_brain.py --url https://cell4.art/ # read the live site
    python3 build_brain.py --url https://cell4.art/ --crawl 8

What comes out is ``brain/brain.js``, a single file the widget loads with a
plain ``<script>`` tag -- deliberately not JSON, because a JSON ``fetch()`` is
blocked by CORS when you open an HTML file straight off your disk, and this has
to work by double-clicking as well as on the server.

Three things go into it:

1. **Passages.**  Every page is split into (heading, text) chunks with a source
   URL, so an answer can always point at where it came from.
2. **Retrieval statistics.**  Document frequencies for BM25 scoring.
3. **The language model.**  ``gabriel.lm.GabrielLM`` -- the same class that
   models ARC programs in the engine, the same sparse log-linear maths -- is
   trained here on the site's English instead.  In the engine it conditions on
   a task's signatures and models a program; here it conditions on a passage's
   heading and models that passage's words.  Its weights ship to the browser as
   they are (the vocabulary is small enough that this is tens of kilobytes),
   and the widget runs the real softmax, not an approximation of it.

   What the widget does with it is *query likelihood*, the classic
   language-model approach to retrieval: a passage scores well for a question
   when the model, conditioned on that passage's heading, finds the question's
   words probable.  That is what lets "how much do you charge" reach a passage
   that never says "charge".

Nothing here or in the widget calls an external model.  There is no API key and
no inference server: the browser does BM25, expands the query with the
association table, and ranks passages.  It answers with the site's own
sentences, which is also why it cannot invent a fact.
"""

import argparse
import html
import json
import math
import os
import re
import sys
import urllib.request
from html.parser import HTMLParser

HERE = os.path.dirname(os.path.abspath(__file__))
ASTRA = os.path.join(os.path.dirname(HERE), "astraarcengine-improved", "astra")

STOP = set("""a an and are as at be been being but by for from had has have he her his i
if in is it its me my no not of on or our so than that the their them then there these
they this to too was we were what when where which who will with would you your
do does did doing done can could should shall may might must will would
get got go going come came make made take took taken give gave want wants wanted
need needs know knows tell tells say says see seen look looking
how why whom whose about into over under again very much many more most
any each some such only own same also here there just even still back
im ive id ok okay yes yeah yep nope please thanks thank hi hello hey yo
u ur ya pls plz thx lol guys guy stuff thing things
""".split())

HEADING_TAGS = {"h1", "h2", "h3", "h4", "title"}
SKIP_TAGS = {"script", "style"}


class Page(HTMLParser):
    """Pull (heading, text) chunks and link facts out of one HTML page."""

    def __init__(self, source):
        super().__init__(convert_charrefs=True)
        self.source = source
        self.chunks = []
        self.links = []
        self._skip = 0
        self._heading = ""
        self._in_heading = False
        self._buf = []
        self._href = None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag in SKIP_TAGS:
            self._skip += 1
        elif tag in HEADING_TAGS:
            self._flush()
            self._in_heading = True
            self._buf = []
        elif tag == "br":
            self._buf.append(" ")
        elif tag == "a" and a.get("href"):
            self._href = a["href"]
        elif tag == "img" and a.get("alt"):
            self._buf.append(" " + a["alt"] + " ")
        elif tag in ("iframe", "video") and a.get("src"):
            pass

    def handle_endtag(self, tag):
        if tag in SKIP_TAGS and self._skip:
            self._skip -= 1
        elif tag in HEADING_TAGS and self._in_heading:
            text = _clean(" ".join(self._buf))
            self._in_heading = False
            self._buf = []
            if text:
                self._heading = text
                self.chunks.append({"heading": text, "text": text,
                                    "source": self.source, "kind": "heading"})
        elif tag == "a":
            self._href = None

    def handle_data(self, data):
        if self._skip:
            return
        text = data.strip()
        if not text:
            return
        if self._in_heading:
            self._buf.append(text)
            return
        if self._href and len(text) < 80:
            self.links.append((text, self._href))
        self.chunks.append({"heading": self._heading, "text": _clean(text),
                            "source": self.source, "kind": "text"})

    def _flush(self):
        self._buf = []


def _clean(s):
    s = html.unescape(s)
    s = re.sub(r"\s+", " ", s).strip()
    return s


def tokenize(text):
    return [w for w in re.findall(r"[a-z0-9][a-z0-9'+#.-]*", text.lower())
            if w not in STOP and len(w) > 1]


def read_local(directory):
    out = []
    for name in sorted(os.listdir(directory)):
        if name.endswith(".html"):
            with open(os.path.join(directory, name), encoding="utf-8",
                      errors="replace") as fh:
                out.append((name, fh.read()))
    return out


def read_url(url, crawl=1, timeout=20):
    """Fetch the page, and optionally same-site pages it links to."""
    seen, queue, out = set(), [url], []
    base = url.rstrip("/")
    while queue and len(out) < max(1, crawl):
        u = queue.pop(0)
        if u in seen:
            continue
        seen.add(u)
        try:
            req = urllib.request.Request(u, headers={"User-Agent": "gabriel-chat/1.0"})
            with urllib.request.urlopen(req, timeout=timeout) as fh:
                body = fh.read().decode("utf-8", "replace")
        except Exception as exc:                   # offline, 404, blocked
            print("  skip %s (%s)" % (u, type(exc).__name__), file=sys.stderr)
            continue
        out.append((u, body))
        for href in re.findall(r'(?:href|src)=["\']([^"\']+\.html)["\']', body):
            if href.startswith("http"):
                nxt = href
            else:
                nxt = base + "/" + href.lstrip("./")
            if nxt.startswith(base) and nxt not in seen:
                queue.append(nxt)
    return out


def build_passages(pages, min_words=3):
    """Merge stray text nodes into passages of a few sentences each."""
    passages, current = [], None
    for source, body in pages:
        p = Page(source)
        try:
            p.feed(body)
        except Exception:
            pass
        for ch in p.chunks:
            if ch["kind"] == "heading":
                if current:
                    passages.append(current)
                current = {"heading": ch["heading"], "text": "",
                           "source": source}
                continue
            if current is None:
                current = {"heading": "", "text": "", "source": source}
            if len(current["text"]) > 700 and re.search(r"[.!?]\s*$", current["text"]):
                passages.append(current)
                current = {"heading": current["heading"], "text": "",
                           "source": source}
            current["text"] = (current["text"] + " " + ch["text"]).strip()
        if current:
            passages.append(current)
            current = None
        for text, href in p.links:
            passages.append({"heading": "Link", "source": source,
                             "text": "%s: %s" % (text, href)})
    out = []
    for p in passages:
        p["text"] = _clean(p["text"])
        if len(p["text"].split()) < min_words and p["heading"]:
            p["text"] = p["heading"]
        if len(p["text"].split()) >= min_words:
            out.append(p)
    # This page makes every line its own <h2>, so a section arrives as a run of
    # heading-only passages: the introducer ("Direct recognition for work
    # from:") and then its items, each isolated and each individually useless as
    # an answer.  Regroup them the way the page reads -- a heading ending in a
    # colon opens a section, and the headings after it are its content.
    grouped, run = [], []

    def close_run():
        if not run:
            return
        head = run[0]["heading"]
        body = " ".join(r["text"] for r in run)
        grouped.append({"heading": head, "text": body, "source": run[0]["source"]})
        del run[:]

    for p in out:
        heading_only = p["heading"] and p["text"] == p["heading"]
        if not heading_only:
            close_run()
            grouped.append(p)
            continue
        if run and (run[0]["heading"].rstrip().endswith(":") is False
                    and p["heading"].rstrip().endswith(":")):
            close_run()
        elif run and (run[0]["source"] != p["source"] or len(run) >= 4):
            close_run()
        run.append(p)
    close_run()
    out = grouped

    # drop duplicates, keeping the first occurrence
    seen, uniq = set(), []
    for p in out:
        key = (p["heading"], p["text"])
        if key in seen:
            continue
        seen.add(key)
        uniq.append(p)
    return uniq


def train_lm(passages, seconds, quiet=False):
    """Train gabriel.lm.GabrielLM on the site's English, then distil it.

    The engine models programs conditioned on a task's signatures; here the
    same model conditions on the passage's heading and models the sentence.
    Same class, same features, same training loop -- a different corpus.
    """
    sys.path.insert(0, ASTRA)
    from gabriel.lm import GabrielLM

    examples = []
    for p in passages:
        body = tokenize(p["text"])
        if len(body) < 2:
            continue
        sigs = ["head:" + w for w in tokenize(p["heading"])[:4]] or ["head:none"]
        examples.append({"sigs": sigs, "body": body + ["<eos>"], "weight": 1.0})
    if not examples:
        return None, {}, {"examples": 0}

    lm = GabrielLM()
    lm.build_vocab(examples)
    dev = examples[::7] or examples
    stats = lm.train(examples, epochs=25, max_seconds=seconds, dev=dev,
                     patience=3, verbose=not quiet)

    return lm, stats


def _export_lm(lm, prune=0.02):
    """Ship only the feature rows the browser scores with.

    The widget builds one document model per passage -- the bias row plus that
    passage's heading rows -- and asks how probable the question's words are
    under it.  The bigram rows (``1|x``, ``2|x|y``) are what the model needs to
    *generate* text and are never consulted for that, so they stay behind: it
    is the difference between an 800 KB payload and a 60 KB one.
    """
    rows = lm.to_dict(prune=prune)["weights"]
    keep = {f: {t: round(v, 3) for t, v in row.items()}
            for f, row in rows.items()
            if f == "b" or f.startswith("s|head:")}
    return {"vocab": lm.vocab, "unigram": {k: round(v, 1) for k, v in
                                           lm.unigram.items()}, "w": keep}


# Words a visitor is likely to use that a site is unlikely to print.  This is a
# vocabulary bridge, not a set of answers: every alias expands the *query*, and
# the reply still has to be retrieved from a real passage.
ALIASES = {
    "cost": ["price", "pricing", "charge", "usd"],
    "charge": ["price", "pricing", "cost", "usd"],
    "expensive": ["price", "pricing", "cost"],
    "cheap": ["price", "pricing", "cost"],
    "quote": ["price", "pricing", "negotiable"],
    "rate": ["price", "pricing"],
    "pay": ["payments", "paypal", "crypto", "cashapp"],
    "payment": ["payments", "paypal", "crypto", "cashapp"],
    "contact": ["discord", "username", "zeropleasure"],
    "touch": ["discord", "username", "contacts"],
    "message": ["discord", "username", "contacts"],
    "talk": ["discord", "username", "contacts"],
    "reach": ["discord", "username", "contacts"],
    "email": ["discord", "username", "contacts"],
    "dm": ["discord", "username", "contacts"],
    "hire": ["service", "commissioning", "price"],
    "commission": ["commissioning", "price", "service"],
    "portfolio": ["cell4", "wip"],
    "about": ["cell4", "portfolio", "team"],
    "who": ["team", "managers", "developers"],
    "clients": ["recognition", "jetbrains", "popg", "technologies"],
    "worked": ["work", "recognition", "contributions"],
    "experience": ["recognition", "work", "contributions"],
    "games": ["game", "roblox", "contributions"],
    "roblox": ["contributions", "game"],
    "model": ["modeling", "3d"],
    "modelling": ["modeling", "3d"],
    "blender": ["modeling", "3d"],
    "crypto": ["token", "web3", "payments"],
    "web3": ["token", "marketing", "management"],
}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--url", default="", help="read the live site instead")
    ap.add_argument("--crawl", type=int, default=6,
                    help="how many same-site pages to follow from --url")
    ap.add_argument("--dir", default=os.path.dirname(HERE),
                    help="directory of .html files to read (default: the repo)")
    ap.add_argument("--out", default=os.path.join(HERE, "brain", "brain.js"))
    ap.add_argument("--seconds", type=float, default=45.0)
    ap.add_argument("--site", default="CELL4")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args(argv)

    if a.url:
        print("reading %s (up to %d pages)" % (a.url, a.crawl))
        pages = read_url(a.url, a.crawl)
    else:
        print("reading %s" % a.dir)
        pages = read_local(a.dir)
    if not pages:
        print("no pages found", file=sys.stderr)
        return 1
    print("  %d page(s): %s" % (len(pages), ", ".join(p[0] for p in pages)))

    passages = build_passages(pages)
    print("  %d passages" % len(passages))

    df, n = {}, len(passages)
    toks = []
    for p in passages:
        t = tokenize(p["heading"] + " " + p["text"])
        toks.append(t)
        for w in set(t):
            df[w] = df.get(w, 0) + 1
    idf = {w: round(math.log(1 + (n - c + 0.5) / (c + 0.5)), 4)
           for w, c in df.items()}

    lm, stats = train_lm(passages, a.seconds, a.quiet)
    print("  language model: %s" % json.dumps(stats))

    brain = {
        "site": a.site,
        "built": __import__("time").strftime("%Y-%m-%d"),
        "passages": [{"h": p["heading"], "t": p["text"], "s": p["source"],
                      "g": ["s|head:" + w for w in tokenize(p["heading"])[:4]]
                           or ["s|head:none"]}
                     for p in passages],
        "tokens": [" ".join(t) for t in toks],
        "idf": idf,
        "aliases": ALIASES,
        "stop": sorted(STOP),
        "lm": ({} if lm is None else _export_lm(lm)),
        "avgdl": round(sum(len(t) for t in toks) / max(1, n), 2),
        "stats": stats,
    }
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    payload = json.dumps(brain, separators=(",", ":"), ensure_ascii=False)
    with open(a.out, "w", encoding="utf-8") as fh:
        fh.write("/* Generated by build_brain.py -- do not edit by hand. */\n")
        fh.write("window.GABRIEL_BRAIN = " + payload + ";\n")
    print("wrote %s (%.0f KB)" % (a.out, os.path.getsize(a.out) / 1024.0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
