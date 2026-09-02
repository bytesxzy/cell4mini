-- Kernel configuration (stable). Budgets are in solver nodes (deterministic), with hard instruction/time caps.
return {
  root = "rsi",
  -- evaluation splits: tasks per family
  train_per_family = 10,       -- visible split: mutation operators may learn from its solutions
  heldout_per_family = 20,     -- secret-salted split: drives acceptance; the genome never sees its seeds.
                               -- Sized for statistical power: a paired test on 120 items with ~8 discordant
                               -- pairs cannot detect a true 3pp gain, so the bar stays high and n grows instead.
  adversarial_per_family = 8,  -- fresh every generation, hidden-op / larger-size families only
  adversarial_families = { "list_hidden", "list_wide", "grid_hidden", "grid_wide" },
  regression_cap = 160,        -- most recent N held-out tasks solved by accepted champions
  external_cap = 60,           -- ARC tasks evaluated per generation (external benchmark, never trained on)
  -- per-task solver budgets
  nodes = 3000,
  instructions = 60000000,
  seconds = 3,
  external_nodes = 2500,
  external_seconds = 4,
  -- acceptance
  bootstrap_reps = 3000,
  alpha = 0.05,
  adversarial_tolerance = -0.03, -- candidate may not lose more than this on the adversarial split
  overfit_gap = 0.10,           -- train gain minus held-out gain above this (with no held-out gain) = overfit
  efficiency_ratio = 0.80,      -- accept equal-score candidates only if they use <= 80% of the nodes
  candidates_per_gen = 4,
  -- benchmark management
  pressure_limit = 2,           -- same family drives 2 consecutive acceptances -> rotate secret split + spawn variant
  -- Challenge ranking (rsi/kernel/challenge.lua). The four components are measured; these weights
  -- are a declared convention, shown on the console and in JOURNAL.md so they can be argued with.
  challenge_weights = { information = 0.40, discrimination = 0.35, headroom = 0.15, freshness = 0.10 },
  saturation_solve_floor = 0.92, -- solved at least this often ...
  saturation_disc_floor = 0.05,  -- ... AND no longer separating candidates = spent, spawn a variant
  adversarial_from_ranking = true, -- point the adversarial split at whatever discriminates best
  -- research cadence (seconds)
  research_interval = 5400,     -- 1.5 h
  arc_per_fetch = 25,
  arxiv_max = 30,
  -- Queries aimed at the gaps declared in rsi/kernel/mechanisms.lua, not at machinery already built.
  arxiv_queries = {
    'all:"program synthesis"',
    'all:"ARC-AGI" OR all:"abstraction and reasoning corpus"',
    'all:"equality saturation" OR all:"e-graph"',
    'all:"sketch" AND all:"synthesis"',
    'all:"conflict-driven" OR all:"counterexample-guided"',
    'all:"type-directed" AND all:"synthesis"',
    'all:"library learning" OR all:"anti-unification"',
  },
}
