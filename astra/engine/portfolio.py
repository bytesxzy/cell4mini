"""The portfolio orchestrator.

Solvers are independent hypothesis *generators*.  The orchestrator is the only
component that decides anything: it validates every hypothesis against the full
training set, ranks the survivors, and emits at most ``k`` distinct predictions
per test input.

Ranking is a description-length argument, not a heuristic pile:

    score = solver_prior + structural_cost + capacity_penalty - loo_evidence

``structural_cost`` is the size of the program/table the hypothesis carries,
``capacity_penalty`` grows with the number of free parameters it fitted, and
``loo_evidence`` rewards rules that survive holding a training pair out.  A
short rule that still predicts an unseen training pair is the one to trust.
"""

import time

from . import grid as G
from .task import Ctx

# Prior cost per solver family.  Lower means "trust this explanation first".
# These are updated in place by ``learn.apply_priors`` once the engine has
# measured which families actually pay off (see engine/learn.py).
SOLVER_PRIOR = {
    "geometry": 0.0,
    "cellwise": 1.0,
    "partition": 0.0,
    "symmetry": 0.0,
    "objects": 1.5,
    "tiling": 0.5,
    "colormap": 0.0,
    "select": 1.0,
    "compose": 2.5,
    "enumerate": 3.0,
    "sequence": 1.0,
}

_REGISTRY = []

# Set by engine.learn.activate().  When present, its per-signature biases are
# added to SOLVER_PRIOR for the task at hand and its module order is used.
POLICY = None


def register(module):
    _REGISTRY.append(module)


def _load_default():
    if _REGISTRY:
        return
    from .solvers import (analogy, blocks, cascade, cellwise, colormap, compose,
                          enumerate_dsl, geometry, motion, objects_map, objwise,
                          partition, patterns,
                          regions, rewrite, paint, panelabs, panelwise,
                          select, sequence, substitute, symmetry, tiling)
    for m in (geometry, colormap, partition, symmetry, tiling, blocks, select,
              regions, cellwise, objects_map, motion, substitute, sequence,
              paint, patterns, analogy,
              compose, panelabs, panelwise, objwise, rewrite, cascade,
              enumerate_dsl):
        register(m)


class Result:
    __slots__ = ("predictions", "hyps", "elapsed", "n_hyps", "n_fit", "solver",
                 "chosen")

    def __init__(self):
        self.predictions = []     # list (per test input) of list of grids
        self.hyps = []
        self.chosen = []          # (solver, name) behind each top-1 guess
        self.elapsed = 0.0
        self.n_hyps = 0
        self.n_fit = 0
        self.solver = None


def _loo_bonus(mod, ctx, hyp):
    """Refit the generating solver with one train pair withheld.

    A hypothesis family that still reproduces the withheld pair is evidence of
    a real rule rather than a coincidence.  Returns the fraction in [0, 1];
    ``0.0`` also stands for "not enough pairs to judge".
    """
    train = ctx.train
    if len(train) < 3:
        return None                 # too few pairs to judge; stay neutral
    wins = 0
    trials = 0
    for i in range(len(train)):
        sub = train[:i] + train[i + 1:]
        held_in, held_out = train[i]
        try:
            sub_ctx = Ctx([(G.to_list(a), G.to_list(b)) for a, b in sub],
                          [G.to_list(held_in)])
            sub_ctx.deadline = min(ctx.deadline or 1e18, time.time() + 0.7)
            cands = [h for h in mod.generate(sub_ctx) if h.fits(sub)]
        except Exception:
            return None
        trials += 1
        if any(h.apply(held_in) == held_out for h in cands):
            wins += 1
        if ctx.timed_out():
            break
    if not trials:
        return None
    return wins / float(trials)


def solve(train, test_inputs, time_budget=30.0, k=2, loo=True,
          modules=None, collect_all=False):
    """Return a :class:`Result` with up to ``k`` ranked guesses per test input."""
    _load_default()
    mods = modules if modules is not None else _REGISTRY
    t0 = time.time()
    deadline = t0 + time_budget
    ctx = Ctx(train, test_inputs, deadline=deadline)

    # --- learned policy: family bias and module ordering -----------------
    bias = {}
    if POLICY is not None:
        try:
            from .learn import signatures
            sigs = signatures(ctx)
            bias = POLICY.bias_for(sigs)
            ctx.op_prior = POLICY.op_bias
            if POLICY.module_order:
                rank = {f: i for i, f in enumerate(POLICY.module_order)}
                mods = sorted(mods, key=lambda m: (
                    rank.get(getattr(m, "SOLVER", ""), 99),
                    _REGISTRY.index(m) if m in _REGISTRY else 99))
            skip = POLICY.skips_for(sigs)
            if skip:
                kept = [m for m in mods if getattr(m, "SOLVER", "") not in skip]
                if kept:
                    mods = kept
        except Exception:
            bias = {}

    # Two-phase budget.  The specialists are cheap and either fire or do not,
    # so they get a bounded slice; whatever they leave unspent flows to the
    # search modules, which can always use more time.
    fitted = []          # (score, order, hyp, module)
    n_hyps = 0
    order = 0
    phase1 = [m for m in mods if getattr(m, "PHASE", 1) == 1]
    phase2 = [m for m in mods if getattr(m, "PHASE", 1) == 2]
    p1_end = t0 + time_budget * (0.45 if phase2 else 1.0)
    share1 = (p1_end - t0) / max(1, len(phase1))
    ordered = phase1 + phase2
    for mi, mod in enumerate(ordered):
        if time.time() > deadline:
            break
        if getattr(mod, "PHASE", 1) == 1:
            mod_deadline = min(deadline, max(time.time() + share1 * 0.5,
                                             t0 + share1 * (mi + 1)))
        else:
            i2 = phase2.index(mod)
            left = deadline - max(time.time(), p1_end)
            share2 = max(0.5, left / max(1, len(phase2) - i2))
            mod_deadline = min(deadline, time.time() + share2)
        ctx.deadline = mod_deadline
        try:
            hyps = mod.generate(ctx)
        except Exception:
            continue
        fam = getattr(mod, "SOLVER", "")
        prior = SOLVER_PRIOR.get(fam, 2.0) + bias.get(fam, 0.0)
        for hyp in hyps:
            n_hyps += 1
            # validating a large hypothesis batch can itself outrun the budget
            if (n_hyps & 63) == 0 and time.time() > deadline:
                break
            if hyp.fits(ctx.train):
                fitted.append([hyp.cost + prior, order, hyp, mod])
                order += 1
                if len(fitted) > 600:
                    break
    ctx.deadline = deadline

    # leave-one-out evidence for the cheapest few families
    if loo and fitted:
        fitted.sort(key=lambda x: (x[0], x[1]))
        seen_mods = set()
        for rec in fitted[:12]:
            if time.time() > deadline:
                break
            mod = rec[3]
            key = getattr(mod, "SOLVER", "")
            if key in seen_mods:
                continue
            seen_mods.add(key)
            frac = _loo_bonus(mod, ctx, rec[2])
            if frac is None:
                continue
            # Reward families that still explain a withheld pair and *penalise*
            # those that cannot: a rule refitted without one example and then
            # failing on it has no claim on the test input either.
            rec[0] += 1.5 - 4.5 * frac

    fitted.sort(key=lambda x: (x[0], x[1]))

    res = Result()
    res.n_hyps = n_hyps
    res.n_fit = len(fitted)
    res.hyps = [(r[2].solver + ":" + r[2].name, round(r[0], 2)) for r in fitted[:8]]
    if fitted:
        res.solver = fitted[0][2].solver

    # --- task-level invariants -------------------------------------------
    # Properties that hold across every demonstration are evidence about the
    # answer even when no single hypothesis knows them: if every output is the
    # same shape as its input, a prediction that changes the shape is wrong
    # whatever produced it.
    exp_shape = None
    if ctx.const_out_shape:
        exp_shape = ("const", ctx.const_out_shape)
    elif ctx.same_shape:
        exp_shape = ("same", None)
    elif ctx.shape_ratio:
        exp_shape = ("ratio", ctx.shape_ratio)
    elif ctx.inv_shape_ratio:
        exp_shape = ("iratio", ctx.inv_shape_ratio)
    allowed = None
    if not ctx.new_colors:
        allowed = set(ctx.out_palette)

    def _violations(tg, g):
        n = 0
        if exp_shape is not None:
            th, tw = G.dims(tg)
            gh, gw = G.dims(g)
            kind, par = exp_shape
            if kind == "const" and (gh, gw) != par:
                n += 1
            elif kind == "same" and (gh, gw) != (th, tw):
                n += 1
            elif kind == "ratio" and (gh, gw) != (th * par[0], tw * par[1]):
                n += 1
            elif kind == "iratio" and (th % par[0] or tw % par[1]
                                       or (gh, gw) != (th // par[0], tw // par[1])):
                n += 1
        if allowed is not None and not (G.palette(g) <= allowed | G.palette(tg)):
            n += 1
        return n

    preds = []
    pool = fitted[:150]
    for ti in test_inputs:
        tg = G.from_list(ti)
        # Ensemble vote.  Independent solver families that agree on the same
        # answer are far stronger evidence than one family agreeing with
        # itself, so each family contributes once, at its best score.
        best = {}          # grid -> {solver: best score}
        first = {}         # grid -> rank of first producer (stable tiebreak)
        author = {}        # grid -> (solver, name) of its cheapest producer
        for rank, (score, _o, hyp, _m) in enumerate(pool):
            g = hyp.apply(tg)
            if g is None:
                continue
            if g not in author:
                author[g] = (hyp.solver, hyp.name)
            fam = best.setdefault(g, {})
            s = fam.get(hyp.solver)
            if s is None or score < s:
                fam[hyp.solver] = score
            first.setdefault(g, rank)
        scored = []
        for g, fam in best.items():
            weight = sum(2.718281828 ** (-s / 2.0) for s in fam.values())
            weight *= 0.25 ** _violations(tg, g)
            scored.append((-weight, first[g], g))
        scored.sort()
        seen = [g for _w, _r, g in scored]
        res.chosen.append(author.get(seen[0]) if seen else None)
        preds.append(seen if collect_all else seen[:k])
    res.predictions = preds
    res.elapsed = time.time() - t0
    return res
