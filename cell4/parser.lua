--[[ cell4/parser.lua -- resolved lines become a tree, not a running total.

The bug this exists to kill
---------------------------
main.lua discovered block structure with a counter. Pass 1 walked the whole
file writing a `while` header for every <REVIVE> it saw; pass 2 walked it again
writing the bodies; a final loop wrote `endmount` copies of `end`. So this
input:

    <REVIVE>            <PRINT> one     <DONE>
    <REVIVE>            <PRINT> two     <DONE>

compiled to two *nested* loops with both bodies inside them -- the second loop
was never a sibling and "two" ran inside the first loop. Verified against the
shipped compiler before this was written.

A stack fixes it: an opener pushes, <DONE> pops, and statements attach to
whichever frame is on top. Unbalanced blocks are reported with the line that
opened them instead of silently changing the nesting.

The symbol table also lives here. main.lua named variables `___<line number>`
(`RFLevel` was incremented once per source line), so declarations were named
after where they sat in the file and no two runs of an edited file agreed.
Slots are now allocated in declaration order: first declaration is `___1`.
]]

local Lexer = require("cell4.lexer")
local Resolver = require("cell4.resolver")

local M = {}

local function new_state()
  return {
    next_slot = 0,
    last_decl = nil,
    open_file = nil, -- slot of the most recent <CREATE>
    declared = {},   -- slot -> line it was declared on
  }
end

--- Allocate the next variable slot.
local function alloc(state, line)
  state.next_slot = state.next_slot + 1
  state.declared[state.next_slot] = line
  return state.next_slot
end

function M.parse(text, diagnostics)
  local lines = Lexer.scan_all(text)

  local program = {
    body = {},      -- backend statement tree
    document = {},  -- frontend nodes, flat and in source order
    stats = { lines = #lines, resolved = 0, unresolved = 0, low_confidence = 0 },
  }

  local state = new_state()

  -- Frame stack. Each frame knows where new statements go, so <ELSE> can move
  -- the target without the caller knowing anything about if-statements.
  local stack = { { node = nil, target = program.body } }

  local function top()
    return stack[#stack]
  end

  local function emit(node)
    local t = top().target
    t[#t + 1] = node
  end

  for _, scanned in ipairs(lines) do
    local outcome = Resolver.resolve(scanned, diagnostics)

    if not outcome then
      if #scanned.tokens > 0 then
        program.stats.unresolved = program.stats.unresolved + 1
      end
    else
      program.stats.resolved = program.stats.resolved + 1
      if outcome.confidence < Resolver.LOW_CONFIDENCE then
        program.stats.low_confidence = program.stats.low_confidence + 1
      end

      local node = outcome.node
      local rule = outcome.rule

      -- Resolve variable references before anything structural, so a bad
      -- reference is reported even on a line that also opens a block.
      if scanned.present.VAR then
        local slot = scanned.present.VAR.slot
        if not state.declared[slot] then
          local hint = state.next_slot == 0
            and "nothing has been declared yet"
            or ("declared so far: ___1 to ___" .. state.next_slot)
          diagnostics:warning(scanned.lineno,
            "___" .. slot .. " is not declared (" .. hint .. ")")
        end
      end

      if node.op == "decl" then
        if node.init == "read_all" then
          if not state.open_file then
            diagnostics:error(scanned.lineno,
              "<READ> needs a file; <CREATE> must come first")
            node.init, node.text = "literal", ""
          else
            node.from = state.open_file
          end
        end
        node.slot = alloc(state, scanned.lineno)
        state.last_decl = node.slot

      elseif node.op == "table_decl" then
        node.slot = alloc(state, scanned.lineno)
        state.last_decl = node.slot

      elseif node.op == "func_decl" then
        node.slot = alloc(state, scanned.lineno)
        node.param = alloc(state, scanned.lineno)
        state.last_decl = node.slot

      elseif node.op == "file_open" then
        node.slot = alloc(state, scanned.lineno)
        state.open_file = node.slot
      elseif node.op == "file_write" or node.op == "file_read" or node.op == "file_close" then
        if not state.open_file then
          diagnostics:error(scanned.lineno,
            "no file is open here; <CREATE> must come before <STATE>/<READ>/<CLOSE>")
        end
        node.slot = state.open_file
        if node.op == "file_close" or node.close then
          state.open_file = nil
        end
      elseif node.op == "print" or node.op == "write" then
        if node.form == "last_decl" then
          if not state.last_decl then
            diagnostics:error(scanned.lineno,
              "nothing has been declared yet, so there is no variable to output")
            node.form = "text"
            node.text = Lexer.payload(scanned)
          else
            node.slot = state.last_decl
          end
        end
      end

      if rule.closes then
        if #stack == 1 then
          diagnostics:error(scanned.lineno, "<DONE> with no open block")
        else
          table.remove(stack)
        end

      elseif rule.reopens then
        local frame = top()
        if not frame.node or frame.node.op ~= "if_stmt" then
          diagnostics:error(scanned.lineno, "<ELSE> outside an <WELL> block")
        elseif frame.node.orelse then
          diagnostics:error(scanned.lineno, "second <ELSE> in the same block")
        else
          frame.node.orelse = {}
          frame.target = frame.node.orelse
        end

      elseif rule.opens then
        emit(node)
        node.body = {}
        stack[#stack + 1] = { node = node, target = node.body, line = scanned.lineno }

      elseif node.op:sub(1, 3) == "fe_" then
        program.document[#program.document + 1] = node

      else
        emit(node)
      end
    end
  end

  -- main.lua closed whatever the counter said. Naming the unclosed opener is
  -- the difference between "your file is malformed" and silently reshaped code.
  while #stack > 1 do
    local frame = table.remove(stack)
    diagnostics:error(frame.line,
      "block opened here is never closed; add <DONE>")
  end

  program.slots = state.next_slot
  return program
end

return M
