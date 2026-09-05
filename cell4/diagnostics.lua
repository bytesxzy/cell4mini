--[[ cell4/diagnostics.lua -- errors that name a line instead of a silent wrong answer.

main.lua had no diagnostic channel at all. When it could not classify a line it
fell through every branch and emitted nothing, so a typo became missing code
rather than a message. `unnecessary_output` was the only reporting, and it was
hardwired to false.

Severity meanings:
  error   -- output would be wrong; the compile is not trustworthy
  warning -- output is probably not what was meant, compile continues
  note    -- informational (low-confidence pick, unused construct)
]]

local M = {}

local Bag = {}
Bag.__index = Bag

function M.new()
  return setmetatable({ items = {} }, Bag)
end

local function add(self, severity, lineno, message, extra)
  local item = {
    severity = severity,
    line = lineno,
    message = message,
  }
  if extra then
    for k, v in pairs(extra) do item[k] = v end
  end
  self.items[#self.items + 1] = item
  return item
end

function Bag:error(lineno, message, extra)   return add(self, "error", lineno, message, extra) end
function Bag:warning(lineno, message, extra) return add(self, "warning", lineno, message, extra) end
function Bag:note(lineno, message, extra)    return add(self, "note", lineno, message, extra) end

function Bag:count(severity)
  local n = 0
  for _, it in ipairs(self.items) do
    if it.severity == severity then n = n + 1 end
  end
  return n
end

function Bag:has_errors()
  return self:count("error") > 0
end

--- Human-readable report, one finding per line, sorted by source line.
function Bag:format()
  local sorted = {}
  for i, it in ipairs(self.items) do sorted[i] = it end
  table.sort(sorted, function(a, b)
    if a.line ~= b.line then return (a.line or 0) < (b.line or 0) end
    return a.severity < b.severity
  end)

  local out = {}
  for _, it in ipairs(sorted) do
    local where = it.line and ("line " .. it.line) or "input"
    out[#out + 1] = string.format("%s: %s: %s", where, it.severity, it.message)
  end
  return table.concat(out, "\n")
end

return M
