"""Drawing rules that need geometry rather than a lookup.

* extend every straight segment to the grid edge;
* complete a rectangle from its corner markers;
* reflect the contents of one side of a separator line onto the other;
* make each object symmetric within its own bounding box.

Each is a genuine construction: no table over local contexts can express
"continue this line until it hits something", because the answer at a cell
depends on structure arbitrarily far away.
"""

from collections import Counter

from .. import grid as G
from .. import objects as O
from ..task import Hyp

SOLVER = "sequence"


def _h(n, f, c):
    return Hyp(n, f, c, SOLVER)


# --- extend segments -------------------------------------------------------

def _extend_lines(g, bg, both, stop):
    bg = G.bg_or(g, bg)
    h, w = G.dims(g)
    out = [list(r) for r in g]
    drawn = False
    for o in O.segment(g, "c8", bg):
        if o.size < 2:
            continue
        if o.height == 1:
            dirs = [(0, 1), (0, -1)]
        elif o.width == 1:
            dirs = [(1, 0), (-1, 0)]
        else:
            continue
        if not o.is_rect():
            continue
        for dr, dc in dirs:
            r = o.r1 if dr > 0 else o.r0
            c = o.c1 if dc > 0 else o.c0
            nr, nc = r + dr, c + dc
            while 0 <= nr < h and 0 <= nc < w:
                if g[nr][nc] != bg:
                    if stop:
                        break
                else:
                    out[nr][nc] = o.color
                    drawn = True
                nr += dr
                nc += dc
            if not both:
                break
    return tuple(tuple(r) for r in out) if drawn else None


# --- rectangle from corners ------------------------------------------------

def _rect_from_corners(g, bg, fill, outline_only):
    bg = G.bg_or(g, bg)
    pts = {}
    for r, row in enumerate(g):
        for c, v in enumerate(row):
            if v != bg:
                pts.setdefault(v, []).append((r, c))
    out = [list(r) for r in g]
    drawn = False
    for v, ps in pts.items():
        if len(ps) not in (2, 4):
            continue
        r0, c0, r1, c1 = G.bbox_of(ps)
        if r1 - r0 < 1 or c1 - c0 < 1:
            continue
        col = v if fill is None else fill
        for r in range(r0, r1 + 1):
            for c in range(c0, c1 + 1):
                edge = r in (r0, r1) or c in (c0, c1)
                if outline_only and not edge:
                    continue
                if g[r][c] == bg:
                    out[r][c] = col
                    drawn = True
    return tuple(tuple(r) for r in out) if drawn else None


# --- reflect across a separator -------------------------------------------

def _axis_lines(g):
    h, w = G.dims(g)
    rows = [r for r in range(h) if len(set(g[r])) == 1]
    t = G.transpose(g)
    cols = [c for c in range(w) if len(set(t[c])) == 1]
    return rows, cols


def _reflect_across(g, bg, use_row, overwrite):
    bg = G.bg_or(g, bg)
    rows, cols = _axis_lines(g)
    idx = rows if use_row else cols
    if len(idx) != 1:
        return None
    a = idx[0]
    h, w = G.dims(g)
    out = [list(r) for r in g]
    drawn = False
    for r in range(h):
        for c in range(w):
            v = g[r][c]
            if v == bg:
                continue
            if use_row:
                nr, nc = 2 * a - r, c
            else:
                nr, nc = r, 2 * a - c
            if 0 <= nr < h and 0 <= nc < w and (r, c) != (nr, nc):
                if overwrite or g[nr][nc] == bg:
                    if out[nr][nc] != v:
                        out[nr][nc] = v
                        drawn = True
    return tuple(tuple(r) for r in out) if drawn else None


# --- connect small objects to a big one -----------------------------------

def _connect_to_anchor(g, bg, seg, anchor_mode):
    """Each satellite aligned with the anchor object grows a line towards it.

    "Aligned" means the satellite's row or column band overlaps the anchor's;
    satellites that are not aligned are deliberately left untouched, which is
    what distinguishes this from a plain ray.
    """
    bg = G.bg_or(g, bg)
    objs = O.segment(g, seg, bg)
    if len(objs) < 2 or len(objs) > 40:
        return None
    if anchor_mode == "largest":
        anchor = max(objs, key=lambda o: (o.size, o.bbox_area))
    else:
        anchor = max(objs, key=lambda o: (o.bbox_area, o.size))
    h, w = G.dims(g)
    out = [list(r) for r in g]
    drawn = False
    for o in objs:
        if o is anchor:
            continue
        v = o.color
        # horizontal alignment
        rows = range(max(o.r0, anchor.r0), min(o.r1, anchor.r1) + 1)
        if rows:
            if o.c0 > anchor.c1:
                span = range(anchor.c1 + 1, o.c0)
            elif o.c1 < anchor.c0:
                span = range(o.c1 + 1, anchor.c0)
            else:
                span = ()
            for r in rows:
                if all(g[r][c] == bg for c in span):
                    for c in span:
                        out[r][c] = v
                        drawn = True
        cols = range(max(o.c0, anchor.c0), min(o.c1, anchor.c1) + 1)
        if cols:
            if o.r0 > anchor.r1:
                span = range(anchor.r1 + 1, o.r0)
            elif o.r1 < anchor.r0:
                span = range(o.r1 + 1, anchor.r0)
            else:
                span = ()
            for c in cols:
                if all(g[r][c] == bg for r in span):
                    for r in span:
                        out[r][c] = v
                        drawn = True
    return tuple(tuple(r) for r in out) if drawn else None


# --- symmetrise each object -----------------------------------------------

def _symmetrise(g, bg, seg, mode):
    bg = G.bg_or(g, bg)
    objs = O.segment(g, seg, bg)
    if not objs or len(objs) > 60:
        return None
    out = [list(r) for r in g]
    drawn = False
    for o in objs:
        p = o.filled(bg)
        variants = [p]
        if mode in ("h", "both"):
            variants.append(G.flip_h(p))
        if mode in ("v", "both"):
            variants.append(G.flip_v(p))
        if mode == "both":
            variants.append(G.rot180(p))
        for var in variants[1:]:
            for r in range(o.height):
                for c in range(o.width):
                    v = var[r][c]
                    if v != bg and out[o.r0 + r][o.c0 + c] == bg:
                        out[o.r0 + r][o.c0 + c] = v
                        drawn = True
    return tuple(tuple(r) for r in out) if drawn else None


_RAY_MODES = ("none", "h", "v", "both")


def _color_rays(g, bg, assign, mode_order):
    """Each colour emits rays in the directions its own colour dictates.

    A single global direction cannot express "dots of this colour draw rows and
    dots of that colour draw columns", which is a whole ARC family on its own.
    Later colours overwrite earlier ones, so the draw order is part of the rule.
    """
    bg = G.bg_or(g, bg)
    h, w = G.dims(g)
    out = [list(r) for r in g]
    src = [(r, c, g[r][c]) for r in range(h) for c in range(w) if g[r][c] != bg]
    if not src or len(src) > 120:
        return None
    drawn = False
    # Draw order is by *direction*, not by colour: where a row line crosses a
    # column line, which one shows through is a property of the two directions.
    for want in mode_order:
        for r, c, v in src:
            mode = assign.get(v, "none")
            if mode != want:
                continue
            if mode in ("h", "both"):
                for cc in range(w):
                    if g[r][cc] == bg:
                        out[r][cc] = v
                        drawn = True
            if mode in ("v", "both"):
                for rr in range(h):
                    if g[rr][c] == bg:
                        out[rr][c] = v
                        drawn = True
    return tuple(tuple(r) for r in out) if drawn else None


def _ray_assignments(colors):
    # 4^k assignments: past three colours this stops being a search and starts
    # being a way to spend the whole budget on one family
    if not colors or len(colors) > 3:
        return []
    out = [{}]
    for col in colors:
        nxt = []
        for base in out:
            for m in _RAY_MODES:
                d = dict(base)
                d[col] = m
                nxt.append(d)
        out = nxt
        if len(out) > 300:
            return out
    return [a for a in out if any(v != "none" for v in a.values())]


def generate(ctx):
    if not ctx.same_shape:
        return []
    res = []
    for bg in ([ctx.bg, None] if ctx.bg_varies else [ctx.bg]):
        res.extend(_rules(ctx, bg))
    return res


def _rules(ctx, bg):
    res = []
    for both in (True, False):
        for stop in (True, False):
            res.append(_h("extend_lines%d%d" % (both, stop),
                          (lambda b, s, bg: lambda g: _extend_lines(g, bg, b, s))(both, stop, bg),
                          4.5))
    for outline in (True, False):
        res.append(_h("rect_corners%d" % outline,
                      (lambda o, bg: lambda g: _rect_from_corners(g, bg, None, o))(outline, bg),
                      4.8))
        for c in sorted(ctx.out_palette):
            res.append(_h("rect_corners%d#%d" % (outline, c),
                          (lambda o, c, bg: lambda g: _rect_from_corners(g, bg, c, o))(outline, c, bg),
                          5.5))
    for use_row in (True, False):
        for ov in (True, False):
            res.append(_h("reflect_%s%d" % ("row" if use_row else "col", ov),
                          (lambda u, o, bg: lambda g: _reflect_across(g, bg, u, o))(use_row, ov, bg),
                          4.5))
    cols = sorted(ctx.in_palette - {bg if bg is not None else -1})
    busiest = max((sum(1 for r in a for v in r if v != G.bg_or(a, bg))
                   for a in ctx.all_inputs), default=0)
    orders = (("v", "both", "h"), ("h", "both", "v"))
    for assign in (_ray_assignments(cols) if busiest <= 40 else []):
        for oi, order in enumerate(orders):
            res.append(_h("rays_%s%d" % ("".join("%d%s" % (k, v[0]) for k, v in
                                                 sorted(assign.items())), oi),
                          (lambda a, o, bg: lambda g: _color_rays(g, bg, a, o))(assign, order, bg),
                          5.5 + 0.2 * sum(1 for v in assign.values() if v != "none")))
    for seg in ("c8", "m8", "c4"):
        for am in ("largest", "bbox"):
            res.append(_h("anchor_%s_%s" % (seg, am),
                          (lambda s, a, bg: lambda g: _connect_to_anchor(g, bg, s, a))(seg, am, bg),
                          4.6))
    for seg in ("c8", "m8"):
        for mode in ("h", "v", "both"):
            res.append(_h("symmetrise_%s_%s" % (seg, mode),
                          (lambda s, m, bg: lambda g: _symmetrise(g, bg, s, m))(seg, mode, bg),
                          5.0))
    return res
