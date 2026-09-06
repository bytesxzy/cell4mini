"""Learned per-object translations.

"Everything red moves two down, everything blue moves one left" is a rule about
objects that no pixel rule and no in-place object edit can express: the object
survives, unchanged, somewhere else. We recover the displacement by matching
each input object to the output object with the same patch, then learn a table
from an object property to its displacement.

Matching is by exact patch, which is deliberately strict: if the shape changed
too, this is not the family that should be explaining the task.
"""

from collections import Counter

from .. import grid as G
from .. import objects as O
from ..task import Hyp

SOLVER = "objects"

_SEGS = ("c8", "m8", "c4")
_KEYS = ("color", "size", "shape", "dims", "all")


def _h(n, f, c):
    return Hyp(n, f, c, SOLVER)


def _key_of(o, kind):
    if kind == "color":
        return o.color
    if kind == "size":
        return o.size
    if kind == "shape":
        return o.mask
    if kind == "dims":
        return (o.height, o.width)
    return 0


def _match(ins, outs):
    """Pair input objects with output objects carrying the identical patch."""
    pool = {}
    for p in outs:
        pool.setdefault(p.patch, []).append(p)
    pairs = []
    for o in ins:
        cands = pool.get(o.patch)
        if not cands:
            return None
        # nearest surviving copy, so that a shape appearing twice does not
        # produce a nonsensical cross-assignment
        best = min(cands, key=lambda p: abs(p.r0 - o.r0) + abs(p.c0 - o.c0))
        cands.remove(best)
        if not cands:
            pool.pop(o.patch, None)
        pairs.append((o, best))
    return pairs


def _fit(ctx, seg, kind, bg):
    table = {}
    n = 0
    moved = False
    for a, b in ctx.train:
        if G.dims(a) != G.dims(b):
            return None
        abg = G.bg_or(a, bg)
        ins = O.segment(a, seg, abg)
        outs = O.segment(b, seg, abg)
        if not ins or len(ins) > 30 or len(ins) != len(outs):
            return None
        pairs = _match(ins, outs)
        if pairs is None:
            return None
        for o, p in pairs:
            d = (p.r0 - o.r0, p.c0 - o.c0)
            if d != (0, 0):
                moved = True
            k = _key_of(o, kind)
            prev = table.get(k)
            if prev is None:
                table[k] = d
            elif prev != d:
                return None
            n += 1
    if not moved or not table or len(table) * 2 > n:
        return None
    return table


def _apply(g, seg, kind, table, bg):
    bg = G.bg_or(g, bg)
    objs = O.segment(g, seg, bg)
    if not objs or len(objs) > 30:
        return None
    h, w = G.dims(g)
    out = [[bg] * w for _ in range(h)]
    for o in objs:
        d = table.get(_key_of(o, kind))
        if d is None:
            return None
        for r, c in o.cells:
            nr, nc = r + d[0], c + d[1]
            if not (0 <= nr < h and 0 <= nc < w):
                return None
            out[nr][nc] = g[r][c]
    return tuple(tuple(r) for r in out)


def generate(ctx):
    if not ctx.same_shape:
        return []
    res = []
    for bg in ([ctx.bg, None] if ctx.bg_varies else [ctx.bg]):
        for seg in _SEGS:
            if ctx.timed_out():
                break
            for kind in _KEYS:
                try:
                    t = _fit(ctx, seg, kind, bg)
                except Exception:
                    t = None
                if t is None:
                    continue
                res.append(_h("move_%s_by_%s" % (seg, kind),
                              (lambda s, k, t, b:
                               lambda g: _apply(g, s, k, t, b))(seg, kind, t, bg),
                              4.0 + 0.1 * len(t)))
    return res
