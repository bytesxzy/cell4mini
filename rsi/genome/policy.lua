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
  cost = {},                -- per-op cost overrides, learned by prior fitting
  cond_cost = {},           -- task-feature bucket -> {op -> cost}, learned task-conditioned priors
  cond_ops = {},            -- task-feature bucket -> {op -> true}, per-bucket enumeration whitelist
  two_phase = true,         -- try the narrow whitelist first, then fall back to the full operator set
  phase1_frac = 0.5,        -- share of the node budget given to the narrow phase
}
