"""Bottom-up program synthesis with observational-equivalence pruning.

The op library is *task-parameterised*: colours that occur in the task become
constants, the inferred background becomes the default fill.  Search proceeds
in levels; a program is kept only if the tuple of grids it produces on the
train inputs (and test inputs, which it must also be total on) has not been
produced before.  Two syntactically different programs with identical
behaviour on the evidence are the same hypothesis, so only one survives -- this
is what keeps depth-3 and depth-4 tractable in pure Python.

The library is extensible at runtime: :func:`add_learned_op` installs an
abstraction mined from previously solved tasks (see ``engine/learn.py``), which
is how the engine's search space grows with experience.
"""

import time

from . import grid as G
from . import objects as O

LEARNED = []          # [(name, cost, factory(ctx) -> fn or None)]
OP_BIAS = {}          # op name -> search-order bonus, fitted by engine/learn.py


def add_learned_op(name, cost, factory):
    for i, (n, _c, _f) in enumerate(LEARNED):
        if n == name:
            LEARNED[i] = (name, cost, factory)
            return
    LEARNED.append((name, cost, factory))


def clear_learned():
    del LEARNED[:]


# --------------------------------------------------------------------------
# op library
# --------------------------------------------------------------------------

def unary_ops(ctx, level="full"):
    """Base library plus any abstractions learned from solved tasks."""
    ops = base_unary_ops(ctx, level)
    for name, cost, factory in LEARNED:
        try:
            fn = factory(ctx)
        except Exception:
            fn = None
        if fn is not None:
            ops.append((name, cost, fn))
    return ops


def seed_ops(ctx):
    """Operators too costly to apply at every node.

    They run once, on the raw input, seeding the frontier; the cheap library
    then composes on top of whatever they produce.  Applying a symmetry repair
    to fifteen hundred intermediate states is how a depth-4 search turns into a
    depth-1 search that ran out of time.
    """
    bg = ctx.bg
    pal = sorted(ctx.in_palette | ctx.out_palette)
    ops = [("frame_in", 2.0, (lambda b=bg: lambda g: _frame_in(g, b))()),
           ("frame_all", 2.2, (lambda b=bg: lambda g: _frame_all(g, b))()),
           ("repair", 2.2, (lambda b=bg: lambda g: _repair_op(g, b))()),
           ("complete", 2.4, (lambda b=bg: lambda g: _complete_op(g, b))()),
           ("outline", 2.2, (lambda b=bg: lambda g: _halo_op(g, b, None))()),
           ("connect", 2.2, (lambda b=bg: lambda g: _connect_op(g, b))())]
    for c in pal:
        ops.append(("halo#%d" % c, 2.4,
                    (lambda c, b=bg: lambda g: _halo_op(g, b, c))(c)))
        ops.append(("mark#%d" % c, 2.0,
                    (lambda c, b=bg: lambda g: _mark(g, b, c))(c)))
    return ops


def _frame_in(g, bg):
    from .solvers.regions import _frame_interior
    return _frame_interior(g, bg, "largest")


def _frame_all(g, bg):
    from .solvers.regions import _frame_content
    return _frame_content(g, bg, "largest")


def _mark(g, bg, c):
    from .solvers.regions import _marked_rect
    return _marked_rect(g, bg, c, False)


def base_unary_ops(ctx, level="full"):
    """(name, cost, fn) triples.  ``level`` trades breadth for speed."""
    bg = ctx.bg
    pal = sorted(ctx.in_palette | ctx.out_palette)
    ops = []
    a = ops.append

    for name, f in G.DIHEDRAL[1:]:
        a((name, 1.0, f))
    a(("crop", 1.2, lambda g, b=bg: G.crop_to_content(g, b)))
    a(("dedup", 1.5, G.dedup))
    a(("dedup_r", 1.8, G.dedup_rows))
    a(("dedup_c", 1.8, G.dedup_cols))
    a(("trim", 1.5, lambda g: G.trim_border(g, 1)))
    for w in ("top", "bottom", "left", "right"):
        a(("half_" + w, 1.4, (lambda w: lambda g: G.half(g, w))(w)))
    for i in range(4):
        a(("quad%d" % i, 1.6, (lambda i: lambda g: G.quadrant(g, i))(i)))
    for d in ("down", "up", "left", "right"):
        a(("grav_" + d, 1.8, (lambda d, b=bg: lambda g: G.gravity(g, b, d))(d)))
    a(("motif", 2.0, _motif))
    a(("compress", 2.0, lambda g, b=bg: _compress(g, b)))

    if level != "small":
        for c in pal:
            a(("crop#%d" % c, 1.8, (lambda c: lambda g: G.crop_to_content(g, c))(c)))
        for c in pal:
            a(("fill#%d" % c, 1.8, (lambda c, b=bg: lambda g: G.fill_holes(g, c, b))(c)))
        for c in pal:
            a(("del#%d" % c, 1.6, (lambda c, b=bg: lambda g: G.replace_color(g, c, b))(c)))
        for c in pal:
            a(("keep#%d" % c, 1.8,
               (lambda c, b=bg: lambda g: tuple(tuple(v if v == c else b for v in r) for r in g))(c)))
        a(("upx2", 1.6, lambda g: G.upscale(g, 2, 2)))
        a(("upx3", 1.8, lambda g: G.upscale(g, 3, 3)))
        a(("dnx2", 1.6, lambda g: G.downscale(g, 2, 2)))
        for k in (2, 3):
            a(("nzx%d" % k, 1.9,
               (lambda k, b=bg: lambda g: G.block_reduce_nonbg(g, k, k, b))(k)))
            a(("upx%d_" % k, 1.9, (lambda k: lambda g: G.upscale(g, k, k))(k)))
        a(("dnx3", 1.8, lambda g: G.downscale(g, 3, 3)))
        a(("tile2", 1.8, lambda g: G.tile(g, 2, 2)))
        a(("pad0", 1.8, lambda g: G.pad(g, 1, bg)))
        for dr, dc in ((0, 1), (0, -1), (1, 0), (-1, 0)):
            a(("sh%+d%+d" % (dr, dc), 1.7,
               (lambda dr, dc, b=bg: lambda g: G.translate(g, dr, dc, b))(dr, dc)))
            a(("wr%+d%+d" % (dr, dc), 1.9,
               (lambda dr, dc: lambda g: G.wrap_translate(g, dr, dc))(dr, dc)))
        for c in pal:
            a(("paint#%d" % c, 1.7,
               (lambda c, b=bg: lambda g: tuple(
                   tuple(c if v != b else b for v in r) for r in g))(c)))
        a(("largest8", 2.0, (lambda b=bg: lambda g: _extreme(g, "c8", b, True))()))
        a(("smallest8", 2.0, (lambda b=bg: lambda g: _extreme(g, "c8", b, False))()))
        a(("largest4", 2.2, (lambda b=bg: lambda g: _extreme(g, "c4", b, True))()))
        a(("uniq_shape", 2.4, (lambda b=bg: lambda g: _uniq(g, "c8", b))()))
        a(("mode_color", 2.4, lambda g: ((G.most_common_color(g),),)))
        # Procedural operators.  Depth is expensive; breadth at depth 2 is
        # cheap, and most ARC programs are short over a *rich* library rather
        # than long over a poor one.
        a(("denoise", 2.0, (lambda b=bg: lambda g: _denoise(g, b))()))
        a(("keep_big", 2.2, (lambda b=bg: lambda g: _keep_big(g, b, True))()))
        a(("drop_big", 2.4, (lambda b=bg: lambda g: _keep_big(g, b, False))()))
        a(("bbox_fill", 2.4, (lambda b=bg: lambda g: _bbox_fill(g, b))()))
        a(("sortrows", 2.6, lambda g: tuple(sorted(g))))
        a(("sortcols", 2.6, lambda g: G.transpose(tuple(sorted(G.transpose(g))))))

    return ops


def _repair_op(g, bg):
    from .solvers.symmetry import _repair
    return _repair(g, bg, True)


def _complete_op(g, bg):
    from .solvers.symmetry import _repair_bounded
    return _repair_bounded(g, bg, False, 0.0, 2, 0)


def _denoise(g, bg):
    """Drop every single-cell object."""
    objs = O.segment(g, "c8", bg)
    if not objs or len(objs) > 300:
        return None
    out = [list(r) for r in g]
    hit = False
    for o in objs:
        if o.size == 1:
            for r, c in o.cells:
                out[r][c] = bg
            hit = True
    return tuple(tuple(r) for r in out) if hit else None


def _halo_op(g, bg, color):
    from .solvers.sequence import _halo
    return _halo(g, bg, color, False, False)


def _connect_op(g, bg):
    from .solvers.sequence import _connect
    return _connect(g, bg, None, False)


def _keep_big(g, bg, keep):
    objs = O.segment(g, "c8", bg)
    if len(objs) < 2 or len(objs) > 300:
        return None
    o = O.select_extreme(objs, "size", True)
    if o is None:
        return None
    h, w = G.dims(g)
    if keep:
        out = [[bg] * w for _ in range(h)]
        for r, c in o.cells:
            out[r][c] = g[r][c]
    else:
        out = [list(r) for r in g]
        for r, c in o.cells:
            out[r][c] = bg
    return tuple(tuple(r) for r in out)


def _bbox_fill(g, bg):
    objs = O.segment(g, "c8", bg)
    if not objs or len(objs) > 120:
        return None
    out = [list(r) for r in g]
    for o in objs:
        for r in range(o.r0, o.r1 + 1):
            for c in range(o.c0, o.c1 + 1):
                out[r][c] = o.color
    return tuple(tuple(r) for r in out)


def _compress(g, bg):
    """Drop rows/cols that are entirely background."""
    rows = [r for r in g if any(v != bg for v in r)]
    if not rows:
        return None
    t = G.transpose(tuple(rows))
    cols = [c for c in t if any(v != bg for v in c)]
    if not cols:
        return None
    return G.transpose(tuple(cols))


def _motif(g):
    from .solvers.tiling import _motif as m
    return m(g)


def _extreme(g, seg, bg, biggest):
    objs = O.segment(g, seg, bg)
    if not objs or len(objs) > 200:
        return None
    o = O.select_extreme(objs, "size", biggest)
    return None if o is None else o.filled(bg)


def _uniq(g, seg, bg):
    objs = O.segment(g, seg, bg)
    if not objs or len(objs) > 200:
        return None
    o = O.select_unique_shape(objs)
    return None if o is None else o.filled(bg)


def binary_ops(bg=0):
    """Pairwise combinators.  Parameterised by background: "empty" is not
    always colour 0, and hard-coding it silently breaks every task drawn on a
    coloured field."""
    return (
        ("hcat", 2.0, G.hconcat),
        ("vcat", 2.0, G.vconcat),
        ("and", 2.2, (lambda b: lambda x, y: _log(x, y, "and", b))(bg)),
        ("or", 2.2, (lambda b: lambda x, y: _log(x, y, "or", b))(bg)),
        ("xor", 2.2, (lambda b: lambda x, y: _log(x, y, "xor", b))(bg)),
        ("diff", 2.4, (lambda b: lambda x, y: _log(x, y, "diff", b))(bg)),
        ("over", 2.2, (lambda b: lambda x, y: _log(x, y, "over", b))(bg)),
        ("under", 2.4, (lambda b: lambda x, y: _log(y, x, "over", b))(bg)),
    )


def _log(a, b, op, bg=0):
    if a is None or b is None or G.dims(a) != G.dims(b):
        return None
    out = []
    for ra, rb in zip(a, b):
        row = []
        for x, y in zip(ra, rb):
            fx, fy = x != bg, y != bg
            if op == "and":
                row.append(x if (fx and fy) else bg)
            elif op == "or":
                row.append(x if fx else (y if fy else bg))
            elif op == "xor":
                row.append(bg if (fx == fy) else (x if fx else y))
            elif op == "diff":
                row.append(x if (fx and not fy) else bg)
            else:
                row.append(y if fy else x)
        out.append(tuple(row))
    return tuple(out)


# --------------------------------------------------------------------------
# search
# --------------------------------------------------------------------------

class _Node:
    __slots__ = ("state", "chain", "cost")

    def __init__(self, state, chain, cost):
        self.state = state
        self.chain = chain
        self.cost = cost


def _apply_chain(chain):
    def run(g):
        for f in chain:
            g = f(g)
            if g is None or not G.valid(g):
                return None
        return g
    return run


def search(ctx, depth=3, max_states=1400, deadline=None, level="full",
           use_binary=True, prior=None):
    """Return a list of (name, cost, fn) that reproduce every train output."""
    n_tr = len(ctx.train)
    grids = ctx.inputs + ctx.test_inputs
    target = ctx.outputs
    ops = unary_ops(ctx, level)
    bias = dict(OP_BIAS)
    if prior:
        bias.update(prior)
    if bias:
        ops.sort(key=lambda t: t[1] - bias.get(t[0], 0.0))
    found = []
    seen = {grids: True}
    root = _Node(grids, (), 0.0)
    frontier = [root]
    every = [root]          # every node ever expanded, for the binary layer
    names = {grids: "$"}

    # seed the frontier with the expensive procedural operators, once
    if level != "small":
        for oname, ocost, f in seed_ops(ctx):
            st = []
            ok = True
            for g in grids:
                try:
                    r = f(g)
                except Exception:
                    ok = False
                    break
                if r is None or not isinstance(r, tuple) or not G.valid(r):
                    ok = False
                    break
                st.append(r)
            if not ok:
                continue
            st = tuple(st)
            if st in seen:
                continue
            seen[st] = True
            nn = _Node(st, (f,), ocost)
            names[st] = "%s($)" % oname
            if st[:n_tr] == target:
                found.append((names[st], ocost, _apply_chain(nn.chain)))
                continue
            frontier.append(nn)
            every.append(nn)

    def check(node):
        if node.state[:n_tr] == target:
            found.append((names[node.state], node.cost, _apply_chain(node.chain)))
            return True
        return False

    for _d in range(depth):
        nxt = []
        for node in frontier:
            if deadline and time.time() > deadline:
                return found
            for oname, ocost, f in ops:
                st = []
                ok = True
                for g in node.state:
                    try:
                        r = f(g)
                    except Exception:
                        ok = False
                        break
                    if r is None or not isinstance(r, tuple) or not G.valid(r):
                        ok = False
                        break
                    st.append(r)
                if not ok:
                    continue
                st = tuple(st)
                if st in seen:
                    continue
                seen[st] = True
                nn = _Node(st, node.chain + (f,), node.cost + ocost)
                names[st] = "%s(%s)" % (oname, names[node.state])
                if check(nn):
                    if len(found) >= 6:
                        return found
                    continue
                nxt.append(nn)
                every.append(nn)
                if len(nxt) >= max_states:
                    break
            if len(nxt) >= max_states:
                break
        nxt.sort(key=lambda n: n.cost)
        frontier = nxt[:max_states]
        if not frontier:
            break

    if use_binary and not found:
        # draw the binary pool from every level, not just the last: the useful
        # pairings are usually a shallow view of the grid against a deeper one
        every.sort(key=lambda n: n.cost)
        pool = every[:120]
        bops = binary_ops(ctx.bg)
        for i, na in enumerate(pool):
            if deadline and time.time() > deadline:
                break
            for nb in pool:
                if na is nb:
                    continue
                for oname, ocost, bf in bops:
                    st = []
                    ok = True
                    for x, y in zip(na.state, nb.state):
                        try:
                            r = bf(x, y)
                        except Exception:
                            ok = False
                            break
                        if r is None or not G.valid(r):
                            ok = False
                            break
                        st.append(r)
                    if not ok:
                        continue
                    if tuple(st[:n_tr]) == target:
                        ca, cb = na.chain, nb.chain
                        found.append((
                            "%s(%s,%s)" % (oname, names[na.state], names[nb.state]),
                            na.cost + nb.cost + ocost,
                            _mk_binary(ca, cb, bf)))
                        if len(found) >= 4:
                            return found
    return found


def _mk_binary(ca, cb, bf):
    ra, rb = _apply_chain(ca), _apply_chain(cb)

    def run(g):
        x, y = ra(g), rb(g)
        if x is None or y is None:
            return None
        return bf(x, y)
    return run
