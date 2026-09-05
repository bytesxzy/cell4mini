--[[ cell4/emit_lua.lua -- tree -> source/execute.lua

main.lua wrote generated code with `io.output(...)` plus bare `io.write` calls
scattered through the classification branches, so emission and understanding
were the same step and neither could be tested alone. Here the tree is already
final; this file only renders it.

Everything is collected into a table and concatenated once. The original made
one syscall per fragment and never closed the stream, which is also why
generated text could interleave with the HTML pass.

Output targets Lua 5.1 syntax so LuaJIT (what run.sh invokes) and 5.4 both
accept it: no goto, no integer division, no bitwise operators.
]]

local M = {}

local Emitter = {}
Emitter.__index = Emitter

local function new_emitter()
  return setmetatable({ out = {}, depth = 0 }, Emitter)
end

function Emitter:line(text)
  self.out[#self.out + 1] = string.rep("  ", self.depth) .. text
end

function Emitter:indent() self.depth = self.depth + 1 end
function Emitter:dedent() self.depth = math.max(0, self.depth - 1) end

--- Safe Lua string literal.
--
-- main.lua wrapped text in `[[ ]]`, which breaks on a payload containing `]]`
-- and silently swallows a leading newline. %q handles both.
local function quote(text)
  return string.format("%q", text or "")
end
M.quote = quote

local function var(slot)
  return "___" .. tostring(slot)
end
M.var = var

--- Render a value that may be a number, a variable reference, or prose.
local function scalar(text)
  text = text or ""
  if tonumber(text) then return text end
  if text:match("^___%d+$") then return text end
  return quote(text)
end

--- A delay must be a number; a non-numeric one would build a shell command
--- from user text, which main.lua did without checking.
local function delay_of(node, diagnostics)
  local n = tonumber(node.delay)
  if not n then
    if diagnostics then
      diagnostics:error(node.line,
        "<SLEEP> needs a number, got " .. quote(tostring(node.delay)))
    end
    return nil
  end
  return n
end

local emit_block

local function emit_node(self, node, diagnostics)
  local op = node.op

  if op == "raw_lua" then
    self:line(node.code)

  elseif op == "while_true" then
    self:line("while true do")
    self:indent(); emit_block(self, node.body, diagnostics); self:dedent()
    self:line("end")

  elseif op == "while_sleep" then
    local n = delay_of(node, diagnostics)
    if n then
      self:line("while os.execute(" .. quote("sleep " .. n) .. ") do")
    else
      self:line("while true do")
    end
    self:indent(); emit_block(self, node.body, diagnostics); self:dedent()
    self:line("end")

  elseif op == "if_stmt" then
    local cond = node.cond
    if cond == "" then
      if diagnostics then
        diagnostics:error(node.line, "<WELL> has no condition")
      end
      cond = "false"
    end
    self:line("if " .. cond .. " then")
    self:indent(); emit_block(self, node.body, diagnostics); self:dedent()
    if node.orelse then
      self:line("else")
      self:indent(); emit_block(self, node.orelse, diagnostics); self:dedent()
    end
    self:line("end")

  elseif op == "for_stmt" then
    self:line("for " .. node.header .. " do")
    self:indent(); emit_block(self, node.body, diagnostics); self:dedent()
    self:line("end")

  elseif op == "func_decl" then
    self:line("local function " .. var(node.slot) .. "(" .. var(node.param) .. ")")
    self:indent(); emit_block(self, node.body, diagnostics); self:dedent()
    self:line("end")

  elseif op == "decl" then
    local name = var(node.slot)
    if node.init == "time" then
      self:line("local " .. name .. " = os.date()")
    elseif node.init == "random" then
      local range = node.range
      if range == "" or not range:match("^[%d%s,%.%-]+$") then
        if diagnostics then
          diagnostics:error(node.line,
            "<GUESS> needs numeric bounds, got " .. quote(range))
        end
        range = "1"
      end
      self:line("local " .. name .. " = math.random(" .. range .. ")")
    elseif node.init == "read_all" then
      self:line("local " .. name .. " = " .. var(node.from) .. ":read(\"*a\")")
    else
      local text = node.text or ""
      if not node.force_string and tonumber(text) then
        self:line("local " .. name .. " = " .. text)
      else
        self:line("local " .. name .. " = " .. quote(text))
      end
    end

  elseif op == "table_decl" then
    self:line("local " .. var(node.slot) .. " = {" .. (node.items or "") .. "}")

  elseif op == "print" or op == "write" then
    local call = (op == "print") and "print" or "io.write"
    if node.form == "time" then
      self:line(call .. "(os.date())")
    elseif node.form == "var" or node.form == "last_decl" then
      self:line(call .. "(" .. var(node.slot) .. ")")
    elseif node.form == "expr" then
      self:line(call .. "(" .. node.text .. ")")
    else
      self:line(call .. "(" .. quote(node.text or "") .. ")")
    end

  elseif op == "sleep" then
    local n = delay_of(node, diagnostics)
    if n then
      self:line("os.execute(" .. quote("sleep " .. n) .. ")")
    end

  elseif op == "file_open" then
    -- assert() so a bad path fails where it happens. main.lua called io.open
    -- unchecked and crashed later on a nil handle.
    self:line("local " .. var(node.slot) .. " = assert(io.open(" ..
      quote(node.path) .. ", \"w\"))")

  elseif op == "file_write" then
    self:line(var(node.slot) .. ":write(" .. scalar(node.text) .. ")")
    if node.close then
      self:line(var(node.slot) .. ":close()")
    end

  elseif op == "file_read" then
    self:line(var(node.slot) .. ":read()")

  elseif op == "file_close" then
    self:line(var(node.slot) .. ":close()")

  else
    if diagnostics then
      diagnostics:error(node.line, "no Lua emitter for '" .. tostring(op) .. "'")
    end
  end
end

emit_block = function(self, body, diagnostics)
  if not body then return end
  for _, node in ipairs(body) do
    emit_node(self, node, diagnostics)
  end
end

--- Render the backend half of a program.
function M.generate(program, diagnostics)
  local self = new_emitter()
  self:line("-- generated by cell4; edits are overwritten on the next compile")
  emit_block(self, program.body, diagnostics)
  return table.concat(self.out, "\n") .. "\n"
end

return M
