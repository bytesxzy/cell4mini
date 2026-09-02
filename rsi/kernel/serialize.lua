-- Deterministic Lua-source serializer for genome data files.
local M = {}

local function key_str(k)
  if type(k) == "string" and k:match("^[%a_][%w_]*$") then return k end
  return "[" .. string.format("%q", k) .. "]"
end

local function ser(v, indent, out)
  local t = type(v)
  if t == "number" then
    if v == math.floor(v) then out[#out + 1] = string.format("%d", v) else out[#out + 1] = string.format("%.14g", v) end
  elseif t == "string" then out[#out + 1] = string.format("%q", v)
  elseif t == "boolean" then out[#out + 1] = tostring(v)
  elseif t == "table" then
    local n = #v
    local isarr = n > 0
    if isarr then for k in pairs(v) do if type(k) ~= "number" or k > n or k < 1 then isarr = false break end end end
    local pad = string.rep("  ", indent + 1)
    if isarr then
      out[#out + 1] = "{"
      for i = 1, n do
        if i > 1 then out[#out + 1] = ", " end
        ser(v[i], indent + 1, out)
      end
      out[#out + 1] = "}"
    else
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = k end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      out[#out + 1] = "{\n"
      for _, k in ipairs(keys) do
        out[#out + 1] = pad .. key_str(k) .. " = "
        ser(v[k], indent + 1, out)
        out[#out + 1] = ",\n"
      end
      out[#out + 1] = string.rep("  ", indent) .. "}"
    end
  else
    out[#out + 1] = "nil"
  end
end

function M.to_lua(v, header)
  local out = { header and ("-- " .. header .. "\n") or "", "return " }
  ser(v, 0, out)
  out[#out + 1] = "\n"
  return table.concat(out)
end

function M.write(path, v, header)
  local f = assert(io.open(path, "w"))
  f:write(M.to_lua(v, header))
  f:close()
end

return M
