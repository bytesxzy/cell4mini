-- Hard execution limits for untrusted candidate code: VM instruction budget + error isolation.
local M = {}

local BUDGET_ERR = "SANDBOX_BUDGET"

-- Run fn(...) with at most `instructions` VM instructions. Returns ok, result_or_error, exhausted.
function M.run(instructions, fn, ...)
  local step = 1000
  local remaining = math.floor(instructions / step)
  local exhausted = false
  local function hook()
    remaining = remaining - 1
    if remaining <= 0 then
      exhausted = true
      error(BUDGET_ERR, 0)
    end
  end
  debug.sethook(hook, "", step)
  local res = { pcall(fn, ...) }
  debug.sethook()
  local ok = res[1]
  if not ok then return false, res[2], exhausted end
  return true, res[2], false
end

M.BUDGET_ERR = BUDGET_ERR
return M
