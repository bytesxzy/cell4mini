"""Task representation, solver context and the no-leak boundary.

Every solver receives a :class:`Ctx`.  A ``Ctx`` is constructed from the train
pairs and the *inputs* of the test pairs only -- test outputs are never placed
on it, so a solver physically cannot read the answer it is being scored on.
The harness holds the answers and does the comparison.
"""

from collections import Counter

from . import grid as G


class Ctx:
    """Read-only view of a task, plus memoised shared analysis."""

    def __init__(self, train, test_inputs, deadline=None, budget=None):
        self.train = tuple((G.from_list(a), G.from_list(b)) for a, b in train)
        self.test_inputs = tuple(G.from_list(t) for t in test_inputs)
        self.deadline = deadline
        self.budget = budget
        self._cache = {}

    # -- convenience ------------------------------------------------------
    @property
    def inputs(self):
        return tuple(a for a, _ in self.train)

    @property
    def outputs(self):
        return tuple(b for _, b in self.train)

    @property
    def all_inputs(self):
        return self.inputs + self.test_inputs

    def memo(self, key, fn):
        if key not in self._cache:
            self._cache[key] = fn()
        return self._cache[key]

    # -- shared analysis --------------------------------------------------
    @property
    def same_shape(self):
        return self.memo("same_shape", lambda: all(
            G.dims(a) == G.dims(b) for a, b in self.train))

    @property
    def const_out_shape(self):
        def f():
            ds = {G.dims(b) for _, b in self.train}
            return ds.pop() if len(ds) == 1 else None
        return self.memo("cshape", f)

    @property
    def shape_ratio(self):
        """(ky, kx) when every output is an integer multiple of its input."""
        def f():
            rs = set()
            for a, b in self.train:
                ah, aw = G.dims(a)
                bh, bw = G.dims(b)
                if bh % ah or bw % aw:
                    return None
                rs.add((bh // ah, bw // aw))
            return rs.pop() if len(rs) == 1 else None
        return self.memo("ratio", f)

    @property
    def inv_shape_ratio(self):
        def f():
            rs = set()
            for a, b in self.train:
                ah, aw = G.dims(a)
                bh, bw = G.dims(b)
                if ah % bh or aw % bw:
                    return None
                rs.add((ah // bh, aw // bw))
            return rs.pop() if len(rs) == 1 else None
        return self.memo("iratio", f)

    @property
    def bg(self):
        """Background colour shared by the whole task (best guess)."""
        def f():
            cands = Counter()
            for a, b in self.train:
                cands[G.background(a)] += 1
            if 0 in cands:
                return 0
            return cands.most_common(1)[0][0]
        return self.memo("bg", f)

    @property
    def bg_varies(self):
        """True when the grids do not share one background colour.

        Several ARC tasks draw each example on a different coloured field.  A
        single task-level background is then wrong for most of them, and every
        object-level rule silently segments the wrong thing.  Solvers respond
        by also offering ``bg=None`` variants, which resolve the background per
        grid at call time.
        """
        return self.memo("bgvar", lambda: len(
            {G.background(a) for a in self.all_inputs}) > 1)

    @property
    def in_palette(self):
        return self.memo("inpal", lambda: set().union(
            *[G.palette(a) for a in self.all_inputs]))

    @property
    def out_palette(self):
        return self.memo("outpal", lambda: set().union(
            *[G.palette(b) for b in self.outputs]))

    @property
    def new_colors(self):
        return self.out_palette - self.in_palette

    @property
    def dropped_colors(self):
        return set().union(*[G.palette(a) for a in self.inputs]) - self.out_palette

    def timed_out(self):
        if self.deadline is None:
            return False
        import time
        return time.time() > self.deadline


class Hyp:
    """A candidate rule: a total function from an input grid to an output."""

    __slots__ = ("name", "fn", "cost", "solver")

    def __init__(self, name, fn, cost=10.0, solver=""):
        self.name = name
        self.fn = fn
        self.cost = cost
        self.solver = solver

    def apply(self, g):
        try:
            r = self.fn(g)
        except Exception:
            return None
        if r is None:
            return None
        if not isinstance(r, tuple):
            try:
                r = G.from_list(r)
            except Exception:
                return None
        return r if G.valid(r) else None

    def fits(self, train):
        for a, b in train:
            if self.apply(a) != b:
                return False
        return True

    def __repr__(self):
        return "<%s %s c=%.1f>" % (self.solver, self.name, self.cost)


def load_task(path):
    import json
    with open(path) as fh:
        d = json.load(fh)
    return d
