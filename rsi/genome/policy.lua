-- search policy: costs, constants, budgets, strategy (mutable)
return {
  strategy = "probe",       -- "probe" (cost-guided bottom-up + just-in-time learning) | "levelwise" (plain size-based)
  default_cost = 2,         -- integer cost of a primitive application unless overridden in cost{}
  const_cost = 1,
  leaf_cost = 1,
  max_cost = 9,             -- deepest cost level the enumeration will reach
  bank_cap = 350,           -- max distinct programs kept per (type, cost) bucket
  jit = true,               -- Probe-style just-in-time weight learning from partially-correct programs
  jit_rate = 1,             -- cost decrease applied to ops of partially-correct programs (per level)
  jit_min_match = 1,        -- minimum matching examples for a program to count as partial evidence
  coerce_ic = false,        -- let small non-negative ints feed colour slots and colours feed int slots
  consts = { I = { 0, 1, 2, 3 }, C = { 0, 1, 2, 3, 4, 5 } },
  -- Measured flat on this distribution (0.0pp on 300 mixed tasks, 0.0pp on 180 large-value tasks):
  -- the generated values are small and the pool above already covers them, so 86% of tasks derive
  -- nothing. Kept because it is the standard remedy where literals matter (real ARC uses ten colours
  -- and dimensions to 30) and the mutation operators can switch it on if evidence ever appears.
  derived_consts = false,   -- also mine example-invariant literals from the task's own I/O pairs
  derived_const_cap = 8,    -- at most this many, ranked by how much the examples demand them
  derived_const_cost = 1,   -- cost of a derived literal leaf
  cost = {},                -- per-op cost overrides, learned by prior fitting
  cond_cost = {},           -- task-feature bucket -> {op -> cost}, learned task-conditioned priors
  cond_ops = {},            -- task-feature bucket -> {op -> true}, per-bucket enumeration whitelist
  -- Verified on four independent 300-task sets (+6.3, +3.0, +8.3, +6.0 pp; pooled 66.0% -> 71.8%,
  -- 66 wins against 14 losses) while using fewer search nodes. On by default.
  bidirectional = true,     -- build the backward bank and meet the forward enumeration in the middle
  back_frac = 0.25,         -- share of the node budget the backward bank may consume
  back_max_cost = 6,        -- deepest backward chain, in the same cost units as the forward search
  back_after_cost = 3,      -- build it only once forward search past this cost level has failed
  back_cap = 400,           -- max backward entries
  binary_meet = true,       -- deduce one argument of a binary operator from the other
  binary_meet_depth = 2,    -- only from backward entries at most this deep
  binary_meet_cap = 24,     -- cheapest forward candidates offered as the known argument
  -- measured at +0.3pp (1 win, 0 losses, p=0.37) on 300 tasks: real but not evidence, so off
  meet_replay = false,      -- replay the binary meet once the forward bank has grown
  meet_replay_slack = 4,    -- extra cost the replay may spend, since its known argument is deeper
  two_phase = true,         -- try the narrow whitelist first, then fall back to the full operator set
  phase1_frac = 0.5,        -- share of the node budget given to the narrow phase
}
