-- Program trees: {op=name,args={...}} | {var=true} | {const=v, ty="I"|"C"}
-- Text form: op(a,b) | $ | 3 | #3 (colour constant)
local M = {}

function M.var() return { var = true } end
function M.const(v, ty) return { const = v, ty = ty or "I" } end
function M.node(op, args) return { op = op, args = args } end

function M.to_string(n)
  if n.var then return "$" end
  if n.const ~= nil then return (n.ty == "C" and "#" or "") .. tostring(n.const) end
  local parts = {}
  for i, a in ipairs(n.args) do parts[i] = M.to_string(a) end
  return n.op .. "(" .. table.concat(parts, ",") .. ")"
end

local function parse_at(s, i)
  local c = s:sub(i, i)
  if c == "$" then return M.var(), i + 1 end
  if c == "#" then
    local d = s:match("^%d+", i + 1)
    if not d then error("bad colour const at " .. i) end
    return M.const(tonumber(d), "C"), i + 1 + #d
  end
  local num = s:match("^%-?%d+", i)
  if num then return M.const(tonumber(num), "I"), i + #num end
  local name = s:match("^[%a_][%w_]*", i)
  if not name then error("parse error at " .. i .. " in " .. s) end
  i = i + #name
  if s:sub(i, i) ~= "(" then error("expected ( after " .. name) end
  i = i + 1
  local args = {}
  if s:sub(i, i) == ")" then return M.node(name, args), i + 1 end
  while true do
    local a
    a, i = parse_at(s, i)
    args[#args + 1] = a
    local d = s:sub(i, i)
    if d == ")" then return M.node(name, args), i + 1 end
    if d ~= "," then error("expected , or ) at " .. i .. " in " .. s) end
    i = i + 1
  end
end

function M.parse(s)
  local n, i = parse_at(s:gsub("%s", ""), 1)
  return n
end

-- Compile to a closure over the input using a prim table name -> {f=...}
function M.compile(n, prims)
  if n.var then return function(x) return x end end
  if n.const ~= nil then local v = n.const return function() return v end end
  local p = prims[n.op]
  if not p then error("unknown op " .. n.op) end
  local f = p.f
  local k = #n.args
  local cs = {}
  for i = 1, k do cs[i] = M.compile(n.args[i], prims) end
  if k == 1 then local a = cs[1] return function(x) return f(a(x)) end end
  if k == 2 then local a, b = cs[1], cs[2] return function(x) return f(a(x), b(x)) end end
  if k == 3 then local a, b, c = cs[1], cs[2], cs[3] return function(x) return f(a(x), b(x), c(x)) end end
  return function(x)
    local vals = {}
    for i = 1, k do vals[i] = cs[i](x) end
    return f((table.unpack or unpack)(vals, 1, k))
  end
end

function M.size(n)
  if n.var or n.const ~= nil then return 1 end
  local s = 1
  for _, a in ipairs(n.args) do s = s + M.size(a) end
  return s
end

function M.ops_used(n, acc)
  acc = acc or {}
  if n.op then
    acc[#acc + 1] = n.op
    for _, a in ipairs(n.args) do M.ops_used(a, acc) end
  end
  return acc
end

function M.uses_var(n)
  if n.var then return true end
  if n.const ~= nil then return false end
  for _, a in ipairs(n.args) do if M.uses_var(a) then return true end end
  return false
end

-- all subtrees that are op nodes and contain the input variable
function M.subtrees(n, acc)
  acc = acc or {}
  if n.op then
    if M.uses_var(n) then acc[#acc + 1] = n end
    for _, a in ipairs(n.args) do M.subtrees(a, acc) end
  end
  return acc
end

function M.ret_type(n, prims, in_type)
  if n.var then return in_type end
  if n.const ~= nil then return n.ty end
  local p = prims[n.op]
  return p and p.r or "?"
end

function M.clone(n)
  if n.var then return M.var() end
  if n.const ~= nil then return M.const(n.const, n.ty) end
  local args = {}
  for i, a in ipairs(n.args) do args[i] = M.clone(a) end
  return M.node(n.op, args)
end

return M
