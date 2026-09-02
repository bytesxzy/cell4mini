-- Cheap task features computed from the training examples only. Used to key the genome's
-- task-conditioned priors (a tabular stand-in for a neural recognition model).
local M = {}

local function rel(b, a)
  if b < a then return "shrink" elseif b > a then return "grow" else return "same" end
end

local function contains(input, in_type, v)
  if in_type == "L" then
    for _, x in ipairs(input) do if x == v then return true end end
    return false
  end
  for r = 1, input.h do for c = 1, input.w do if input[r][c] == v then return true end end end
  return false
end

function M.bucket(task)
  local it, ot = task.in_type, task.out_type
  local key = it .. ">" .. ot
  local ex = task.train
  if (it == "L" and ot == "L") or (it == "G" and ot == "G") then
    local r
    for _, e in ipairs(ex) do
      local a = it == "L" and #e.input or (e.input.h * e.input.w)
      local b = ot == "L" and #e.output or (e.output.h * e.output.w)
      local rr = rel(b, a)
      if r == nil then r = rr elseif r ~= rr then r = "mixed" break end
    end
    key = key .. ":" .. (r or "same")
  elseif ot == "I" or ot == "C" then
    local inside = true
    for _, e in ipairs(ex) do
      if not contains(e.input, it, e.output) then inside = false break end
    end
    key = key .. (inside and ":member" or ":derived")
  end
  return key
end

return M
