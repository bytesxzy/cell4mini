-- search engine (mutable): cost-guided bottom-up enumeration with observational equivalence.
-- Mechanisms: bottom-up enumeration by integer cost with OE dedup (Udupa et al. / TRANSIT style),
-- Probe-style just-in-time cost learning from partially-correct programs (Barke et al. 2020),
-- learned library primitives enter as ordinary unary ops (DreamCoder-style reuse).
local M = {}

function M.solve(task, ctx)
  local prims, order = ctx.dsl.prims, ctx.dsl.order
  local policy = ctx.policy
  local sig, equal, P = ctx.sig, ctx.equal, ctx.program
  local train = task.train
  local n = #train
  local inputs, targets = {}, {}
  for i = 1, n do inputs[i] = train[i].input targets[i] = train[i].output end
  local in_type, out_type = task.in_type, task.out_type
  local budget, deadline = ctx.budget, ctx.deadline
  local clock = os.clock

  local cost = {}
  for _, name in ipairs(order) do cost[name] = policy.cost[name] or policy.default_cost end

  local bank, seen = {}, {}
  local function bucket(ty, c)
    local b = bank[ty]
    if not b then b = {} bank[ty] = b end
    local l = b[c]
    if not l then l = {} b[c] = l end
    return l
  end

  local nodes, best_matches, best_node = 0, 0, nil
  local level_partials = {}

  local function type_matches(ty)
    return ty == out_type or (out_type == "C" and ty == "I") or (out_type == "I" and ty == "C")
  end

  -- returns solution node if all train examples match
  local function consider(ty, c, node, outs)
    local parts = {}
    for i = 1, n do parts[i] = sig(outs[i]) end
    local key = ty .. "|" .. table.concat(parts, ";")
    if seen[key] then return nil end
    seen[key] = true
    nodes = nodes + 1
    local l = bucket(ty, c)
    if #l < policy.bank_cap then
      local entry = { node = node, outs = outs }
      l[#l + 1] = entry
      -- optional int<->colour sharing: small non-negative ints may feed colour slots and vice versa
      if policy.coerce_ic and (ty == "I" or ty == "C") then
        local other = ty == "I" and "C" or "I"
        local fits = true
        if other == "C" then
          for i = 1, n do local v = outs[i] if v < 0 or v > 9 or v ~= math.floor(v) then fits = false break end end
        end
        if fits then
          local l2 = bucket(other, c)
          if #l2 < policy.bank_cap then l2[#l2 + 1] = entry end
        end
      end
    end
    if type_matches(ty) then
      local m = 0
      for i = 1, n do if equal(outs[i], targets[i]) then m = m + 1 end end
      if m == n then return node end
      if m > best_matches then best_matches, best_node = m, node end
      if m >= policy.jit_min_match then level_partials[#level_partials + 1] = node end
    end
    return nil
  end

  -- leaves
  do
    local outs = {}
    for i = 1, n do outs[i] = inputs[i] end
    consider(in_type, policy.leaf_cost, P.var(), outs)
    for ty, list in pairs(policy.consts) do
      for _, v in ipairs(list) do
        local o = {}
        for i = 1, n do o[i] = v end
        local s = consider(ty, policy.const_cost, P.const(v, ty), o)
        if s then return { program = s, nodes = nodes, partial = 1 } end
      end
    end
  end

  local function apply1(f, a)
    local outs = {}
    for i = 1, n do outs[i] = f(a.outs[i]) end
    return outs
  end
  local function apply2(f, a, b)
    local outs = {}
    for i = 1, n do outs[i] = f(a.outs[i], b.outs[i]) end
    return outs
  end
  local function apply3(f, a, b, c)
    local outs = {}
    for i = 1, n do outs[i] = f(a.outs[i], b.outs[i], c.outs[i]) end
    return outs
  end

  local function exhausted()
    if nodes >= budget then return true end
    if nodes % 64 == 0 and clock() > deadline then return true end
    return false
  end

  for C = 2, policy.max_cost do
    level_partials = {}
    for _, name in ipairs(order) do
      local p = prims[name]
      local w = cost[name]
      local R = C - w
      local k = #p.t
      if R >= k then
        local f, t = p.f, p.t
        if k == 1 then
          local A = bank[t[1]] and bank[t[1]][R]
          if A then
            for ai = 1, #A do
              local a = A[ai]
              local ok, outs = pcall(apply1, f, a)
              if ok then
                local s = consider(p.r, C, P.node(name, { a.node }), outs)
                if s then return { program = s, nodes = nodes, partial = 1 } end
              end
              if exhausted() then return { program = nil, nodes = nodes, partial = best_matches / n, best_partial = best_node } end
            end
          end
        elseif k == 2 then
          for c1 = 1, R - 1 do
            local c2 = R - c1
            local A = bank[t[1]] and bank[t[1]][c1]
            local B = bank[t[2]] and bank[t[2]][c2]
            if A and B then
              for ai = 1, #A do
                local a = A[ai]
                for bi = 1, #B do
                  local b = B[bi]
                  local ok, outs = pcall(apply2, f, a, b)
                  if ok then
                    local s = consider(p.r, C, P.node(name, { a.node, b.node }), outs)
                    if s then return { program = s, nodes = nodes, partial = 1 } end
                  end
                  if exhausted() then return { program = nil, nodes = nodes, partial = best_matches / n, best_partial = best_node } end
                end
              end
            end
          end
        elseif k == 3 then
          for c1 = 1, R - 2 do
            for c2 = 1, R - 1 - c1 do
              local c3 = R - c1 - c2
              local A = bank[t[1]] and bank[t[1]][c1]
              local B = bank[t[2]] and bank[t[2]][c2]
              local Cc = bank[t[3]] and bank[t[3]][c3]
              if A and B and Cc then
                for ai = 1, #A do
                  for bi = 1, #B do
                    for ci = 1, #Cc do
                      local a, b, c = A[ai], B[bi], Cc[ci]
                      local ok, outs = pcall(apply3, f, a, b, c)
                      if ok then
                        local s = consider(p.r, C, P.node(name, { a.node, b.node, c.node }), outs)
                        if s then return { program = s, nodes = nodes, partial = 1 } end
                      end
                      if exhausted() then return { program = nil, nodes = nodes, partial = best_matches / n, best_partial = best_node } end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
    -- just-in-time learning: ops appearing in partially-correct programs become cheaper for later levels
    if policy.jit and policy.strategy == "probe" and #level_partials > 0 then
      local touched = {}
      for _, node in ipairs(level_partials) do
        for _, op in ipairs(P.ops_used(node)) do touched[op] = true end
      end
      for op in pairs(touched) do cost[op] = math.max(1, cost[op] - policy.jit_rate) end
    end
  end
  return { program = nil, nodes = nodes, partial = best_matches / n, best_partial = best_node }
end

return M
