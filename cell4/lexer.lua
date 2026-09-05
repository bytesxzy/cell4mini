--[[ cell4/lexer.lua -- one left-to-right scan per line.

What this replaces
------------------
main.lua asked `line:upper():find("<PRINT>")` and then rebuilt the payload with
a ~25-call gsub chain, copy-pasted about thirty times. Two consequences, both
observed in the shipped compiler:

  * the payload was whatever survived the chain, so a keyword the chain forgot
    stayed in the output. `FILL: #000000 POSITION: center` compiled to
    `background-color:#000000 POSITION: center;` because the FILL branch only
    stripped `FILL:`.
  * `FP1:match("^%s*(.-)%s*$")` was called 16 times with the result discarded,
    so the trim never happened and leading blanks reached the generated code:
    a one-word payload arrived as a long-bracket literal with two leading
    spaces still inside it.

The scanner below attributes text to the keyword that introduced it, so every
token carries its own value and each value is trimmed exactly once.
]]

local KW = require("cell4.keywords")

local M = {}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end
M.trim = trim

--- Scan one source line into `{ tokens = {...}, lead = "..." }`.
--
-- Each token is `{ name, value, col }` where `value` is the text between this
-- keyword and the next one. `lead` is any text before the first keyword.
function M.scan(line, lineno)
  local lower = line:lower()
  local n = #line

  local tokens = {}
  local lead = {}
  local current = nil
  local buffer = lead

  local i = 1
  while i <= n do
    local matched = nil

    -- Longest lexeme first (KW.ordered), so DISPLAYX: never matches as DISPLAY:.
    for _, def in ipairs(KW.ordered) do
      local width = #def.lexeme
      if lower:sub(i, i + width - 1) == def.lexeme then
        matched = def
        break
      end
    end

    -- `___12` is a reference to a generated variable. It is recognised here
    -- rather than by substring search because main.lua's `find("___")` also
    -- matched the `____` it explicitly wanted to exclude.
    if not matched then
      local ref = lower:match("^___(%d+)", i)
      if ref then
        if current then
          current.value = trim(table.concat(current.buffer))
          current.buffer = nil
          tokens[#tokens + 1] = current
        end
        current = { name = "VAR", slot = tonumber(ref), col = i, buffer = {} }
        buffer = current.buffer
        i = i + 3 + #ref
        matched = true
      end
    end

    if matched and matched ~= true then
      if current then
        current.value = trim(table.concat(current.buffer))
        current.buffer = nil
        tokens[#tokens + 1] = current
      end
      current = { name = matched.name, kind = matched.kind, col = i, buffer = {} }
      buffer = current.buffer
      i = i + #matched.lexeme
    elseif not matched then
      buffer[#buffer + 1] = line:sub(i, i)
      i = i + 1
    end
  end

  if current then
    current.value = trim(table.concat(current.buffer))
    current.buffer = nil
    tokens[#tokens + 1] = current
  end

  local scanned = {
    lineno = lineno,
    raw = line,
    lead = trim(table.concat(lead)),
    tokens = tokens,
    present = {},
  }
  for _, t in ipairs(tokens) do
    scanned.present[t.name] = t
  end

  return scanned
end

--- Value of the first `name` token, or "".
function M.value_of(scanned, name)
  local t = scanned.present[name]
  return t and t.value or ""
end

--- Every token value joined, for rules that do not care which keyword carried
--- the text. Empty values are skipped so `<LOCAL> <STRING> hi` yields "hi".
function M.payload(scanned)
  local parts = {}
  if scanned.lead ~= "" then parts[#parts + 1] = scanned.lead end
  for _, t in ipairs(scanned.tokens) do
    if t.value and t.value ~= "" then parts[#parts + 1] = t.value end
  end
  return trim(table.concat(parts, " "))
end

--- Split a source string into scanned lines.
function M.scan_all(text)
  local lines = {}
  local lineno = 0
  -- Accepts LF and CRLF; main.lua used io.lines and inherited whatever the
  -- platform gave it, which left \r inside generated string literals.
  for raw in (text .. "\n"):gmatch("(.-)\r?\n") do
    lineno = lineno + 1
    lines[#lines + 1] = M.scan(raw, lineno)
  end
  -- The trailing split always produces one empty line; drop it.
  if #lines > 0 and lines[#lines].raw == "" and #lines[#lines].tokens == 0 then
    lines[#lines] = nil
  end
  return lines
end

return M
