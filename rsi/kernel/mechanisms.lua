-- The registry of what this system's reasoning is built from, what it tried and threw away, and what
-- it has never had.
--
-- Its purpose is to make the paper feed useful without pretending to comprehension. There is no
-- language model here, so nothing can read a paper and derive a mechanism from it. What the registry
-- makes possible is narrower and still worth having: an abstract can be matched against a declared
-- list of mechanisms, and a paper that touches something in `gaps` is more likely to be worth a
-- human's attention than one describing what is already implemented. That is keyword matching against
-- an explicit gap list. It is not understanding, and the ranking says so on the console.
--
-- The honest value of this file is mostly the second field. `rejected` records mechanisms that were
-- implemented, measured, and found not to pay, with the numbers. Without it the system would happily
-- rediscover and re-propose the same losing ideas, and a reader would have no way to tell an untried
-- idea from a tried one.
local M = {}

M.implemented = {
  { name = "bottom-up enumeration", keys = { "bottom-up", "enumerative synthesis", "enumeration" },
    where = "rsi/genome/search.lua" },
  { name = "observational equivalence", keys = { "observational equivalence", "equivalence reduction" },
    where = "rsi/genome/search.lua: OE dedup on value tuples" },
  { name = "cost-guided search", keys = { "cost-guided", "weighted enumeration", "size-based enumeration" },
    where = "rsi/genome/search.lua: integer cost levels" },
  { name = "just-in-time weight learning", keys = { "just-in-time", "probe", "guided enumeration" },
    where = "rsi/genome/search.lua: partial-match cost decay (Barke et al.)" },
  { name = "library learning", keys = { "library learning", "dreamcoder", "abstraction learning", "compression" },
    where = "rsi/kernel/mutate.lua: library_learn" },
  { name = "anti-unification", keys = { "anti-unification", "antiunification", "stitch", "version space" },
    where = "rsi/kernel/mutate.lua: parameterized_abstraction" },
  { name = "inverse semantics", keys = { "inverse semantics", "witness function", "deductive synthesis", "flashfill", "inverse function" },
    where = "rsi/kernel/inverses.lua" },
  { name = "bidirectional search", keys = { "bidirectional", "meet in the middle", "meet-in-the-middle", "backward search" },
    where = "rsi/genome/search.lua: backward bank" },
  { name = "angelic / component-based synthesis", keys = { "angelic", "component-based synthesis", "argument deduction" },
    where = "rsi/genome/search.lua: binary_meet" },
  { name = "task-conditioned priors", keys = { "recognition model", "conditional prior", "amortized inference", "task embedding" },
    where = "rsi/kernel/mutate.lua: fit_conditional_priors" },
  { name = "algorithm portfolio", keys = { "portfolio", "algorithm selection", "restart strategy" },
    where = "rsi/genome/search.lua: two_phase" },
  { name = "automatic curriculum", keys = { "curriculum", "task generation", "self-play", "procedural generation" },
    where = "rsi/kernel/benchmarks.lua: variant spawning" },
  { name = "grounded natural-language report", keys = { "grounded generation", "data-to-text", "template generation", "faithfulness", "hallucination" },
    where = "rsi/kernel/narrator.lua: procedural, audited, NOT a language model" },
}

-- Measured and discarded. Each entry carries the number that killed it, so it is not re-proposed.
M.rejected = {
  { name = "hard operator whitelist", evidence = "-1.7pp on 300 tasks: 10 wins from the depth it buys, 15 losses from excluding operators the task needed" },
  { name = "unconditional library additions", evidence = "-2.7pp for 8 abstractions; every extra primitive widens branching at every level. Bucket-scoping recovered 2pp of that" },
  { name = "wider constant pool", evidence = "-3.5pp adding integers 4..9" },
  { name = "task-derived constants", evidence = "0.0pp on 300 mixed and 0.0pp on 180 large-value tasks; 86% of tasks derive nothing because generated values are already pooled. Retained but off" },
  { name = "binary meet replay", evidence = "+0.3pp, 1 win 0 losses, p=0.37. Real but not evidence. Off" },
  { name = "deeper cost ceiling", evidence = "max_cost 9 to 24 gave bit-for-bit identical results; the ceiling never binds" },
  { name = "bigger banks", evidence = "bank_cap 350 to 900 and back_cap 400 to 1200 both exactly flat" },
  { name = "more search budget", evidence = "13x the node budget (1500 to 20000) bought only +4.4pp; the remaining failures are reach-limited, not ordering-limited" },
}

-- Never implemented here. This is what the paper feed is ranked against.
M.gaps = {
  { name = "e-graphs / equality saturation", keys = { "e-graph", "egraph", "equality saturation", "rewrite rules" },
    note = "could collapse the redundant forward bank far harder than value-tuple dedup does" },
  { name = "conflict-driven learning", keys = { "conflict-driven", "cdcl", "clause learning", "nogood" },
    note = "the search currently learns nothing from a dead end beyond a cost tweak" },
  { name = "sketch-based synthesis", keys = { "sketch", "hole", "template", "partial program" },
    note = "top-down expansion with holes explores a different order than bottom-up banks" },
  { name = "constraint propagation / SMT", keys = { "smt", "constraint solving", "z3", "satisfiability modulo" },
    note = "would let arguments be solved for rather than enumerated" },
  { name = "type-directed / bidirectional typing", keys = { "type-directed", "bidirectional typing", "refinement type" },
    note = "prune branches that cannot reach the goal type within the remaining budget" },
  { name = "Monte Carlo tree search", keys = { "monte carlo tree", "mcts", "best-first search", "a* search" },
    note = "an ordering policy over the enumeration, which uniform cost levels currently lack" },
  { name = "abstraction refinement", keys = { "abstraction refinement", "cegar", "counterexample-guided" },
    note = "use a failing example to refine the search space rather than restart" },
  { name = "test-time compute scaling", keys = { "test-time", "inference-time", "repeated sampling", "budget forcing" },
    note = "measured here as weak: 13x budget bought 4.4pp, so scaling compute is not the lever" },
  { name = "neural guidance", keys = { "neural guided", "neural-guided", "learned policy", "transformer", "language model" },
    note = "EXCLUDED BY DESIGN: this system uses no learned model, by requirement" },
  { name = "program merging / multi-program", keys = { "program merging", "ensembles of programs", "disjunctive" },
    note = "combine partially-correct programs instead of discarding them" },
}

-- Score a piece of text against the registry. Returns matched gap names, matched implemented names,
-- and an actionability score: a paper touching something absent scores above one describing what is
-- already here. Excluded-by-design gaps score zero.
function M.score(text)
  local lower = text:lower()
  local gaps, known, note = {}, {}, nil
  for _, g in ipairs(M.gaps) do
    for _, k in ipairs(g.keys) do
      if lower:find(k, 1, true) then
        gaps[#gaps + 1] = g.name
        if not note then note = g.note end
        break
      end
    end
  end
  for _, e in ipairs(M.implemented) do
    for _, k in ipairs(e.keys) do
      if lower:find(k, 1, true) then
        known[#known + 1] = e.name
        break
      end
    end
  end
  local excluded = false
  for _, g in ipairs(gaps) do if g == "neural guidance" then excluded = true end end
  local score = 0
  if not excluded then score = 2 * #gaps + (#known > 0 and 1 or 0) end
  return score, gaps, known, note
end

function M.gap_names()
  local out = {}
  for _, g in ipairs(M.gaps) do
    if g.name ~= "neural guidance" then out[#out + 1] = g.name end
  end
  return out
end

return M
