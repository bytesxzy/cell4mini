"""Assemble robots.html -- one self-contained file, nothing to install.

    python3 build_robots.py --dir /path/with/index.html
    python3 build_robots.py --url https://cell4.art/ --crawl 10

Takes the passages and the trained language model from ``build_brain.py``,
inlines them into ``robots.template.html`` together with
``robots.runtime.js``, and writes ``robots.html``.

One file is the whole point: it can be dropped anywhere, opened by
double-clicking, or pointed at by an ``<iframe>`` with no other paths to get
right.  The page notices when it is inside a frame and fills it instead of
floating a bubble over it.

What it cannot do at build time is read ``/astron/xyz/`` -- that is on the
server.  The page reads it at runtime instead, from the visitor's browser,
where it is same origin.  See ``readLive`` in the runtime.
"""

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import build_brain as bb                                    # noqa: E402


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--url", default="")
    ap.add_argument("--crawl", type=int, default=10)
    ap.add_argument("--dir", default=os.path.dirname(HERE))
    ap.add_argument("--out", default=os.path.join(HERE, "robots.html"))
    ap.add_argument("--seconds", type=float, default=60.0)
    ap.add_argument("--site", default="CELL4")
    ap.add_argument("--sources", default="/astron/xyz/",
                    help="comma-separated paths the page reads live, same origin")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args(argv)

    pages = bb.read_url(a.url, a.crawl) if a.url else bb.read_local(a.dir)
    if not pages:
        print("no pages found", file=sys.stderr)
        return 1
    print("read %d page(s): %s" % (len(pages), ", ".join(p[0] for p in pages)))

    passages = bb.build_passages(pages)
    import math
    df, n, toks = {}, len(passages), []
    for p in passages:
        t = bb.tokenize(p["heading"] + " " + p["text"])
        toks.append(t)
        for w in set(t):
            df[w] = df.get(w, 0) + 1
    idf = {w: round(math.log(1 + (n - c + 0.5) / (c + 0.5)), 4) for w, c in df.items()}

    lm, stats = bb.train_lm(passages, a.seconds, a.quiet)
    print("%d passages · %s" % (n, json.dumps(stats)))

    brain = {
        "site": a.site,
        "built": __import__("time").strftime("%Y-%m-%d"),
        "passages": [{"h": p["heading"], "t": p["text"], "s": p["source"],
                      "g": ["s|head:" + w for w in bb.tokenize(p["heading"])[:4]]
                           or ["s|head:none"]}
                     for p in passages],
        "tokens": [" ".join(t) for t in toks],
        "idf": idf,
        "aliases": bb.ALIASES,
        "stop": sorted(bb.STOP),
        "avgdl": round(sum(len(t) for t in toks) / max(1, n), 2),
        "lm": ({} if lm is None else bb._export_lm(lm)),
        "stats": stats,
    }

    with open(os.path.join(HERE, "robots.template.html"), encoding="utf-8") as fh:
        page = fh.read()
    with open(os.path.join(HERE, "robots.runtime.js"), encoding="utf-8") as fh:
        runtime = fh.read()
    with open(os.path.join(HERE, "robots.sources.js"), encoding="utf-8") as fh:
        sources = fh.read()

    payload = json.dumps(brain, separators=(",", ":"), ensure_ascii=False)
    # </script> inside a string literal would close the block early
    payload = payload.replace("</", "<\\/")
    cfg = ("window.ROBOTS_CONFIG={sources:%s};"
           % json.dumps([s for s in a.sources.split(",") if s.strip()]))

    start = page.index("/*__BRAIN__*/")
    end = page.index("/*__END__*/") + len("/*__END__*/")
    page = page[:start] + payload + page[end:]
    page = page.replace("/*__RUNTIME__*/", cfg + "\n" + sources + "\n" + runtime)

    with open(a.out, "w", encoding="utf-8") as fh:
        fh.write(page)
    print("wrote %s (%.0f KB)" % (a.out, os.path.getsize(a.out) / 1024.0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
