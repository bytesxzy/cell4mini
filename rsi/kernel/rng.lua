-- Deterministic PRNG (Park-Miller minimal standard), Lua 5.1/LuaJIT/5.4 safe (no bit ops).
local M = {}
M.__index = M

local function hashstr(s)
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % 2147483647 end
  return h
end

function M.new(seed)
  if type(seed) == "string" then seed = hashstr(seed) end
  seed = math.floor(seed or 1) % 2147483647
  if seed == 0 then seed = 1 end
  return setmetatable({ s = seed }, M)
end

function M:next()
  self.s = (self.s * 16807) % 2147483647
  return self.s
end

function M:float() return (self:next() - 1) / 2147483646 end

function M:int(a, b)
  if b == nil then a, b = 1, a end
  return a + (self:next() % (b - a + 1))
end

function M:pick(t) return t[self:int(#t)] end

function M:shuffle(t)
  for i = #t, 2, -1 do
    local j = self:int(i)
    t[i], t[j] = t[j], t[i]
  end
  return t
end

function M:derive(label) return M.new(hashstr(tostring(self:next()) .. "|" .. tostring(label))) end

M.hash = hashstr
return M
