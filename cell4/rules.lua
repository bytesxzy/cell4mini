--[[ cell4/rules.lua -- one row per thing a line can mean.

Each row is a hypothesis. The resolver scores every hypothesis against the
tokens actually found on the line and takes the best one, so meaning no longer
depends on which `if` happened to be written first.

  requires  every one of these tokens must be present, or the rule is out
  forbids   any one of these present and the rule is out
  prefers   present -> small bonus, used to separate rules of equal shape
  bonus     optional function for evidence that is not a bare token
  priority  reserved for escape hatches that must always win

Scoring is `10 * #requires + 2 * #prefers_present + bonus + priority`, so a
more specific rule outranks a more general one by construction. `<LOCAL>
<GUESS>` scores 20 against `<LOCAL>`'s 10 without anybody ordering them.

The `forbids` column is the direct replacement for main.lua's guard chains --
one branch there carried nine `and not Translation:find(...)` clauses, and a
tenth was needed every time a keyword was added.
]]

local Lexer = require("cell4.lexer")

local M = {}

-- ---------------------------------------------------------------------------
-- evidence helpers
-- ---------------------------------------------------------------------------

local ARITHMETIC = "^[%d%s%+%-%*%/%%%^%(%)%.]+$"

--- True when the payload is arithmetic rather than prose.
--
-- main.lua asked `find("+") or find("-") or ...`, which fired on any hyphen in
-- a sentence, and separately asked `find("1") or find("2") or ...`, which made
-- "level 2 complete" numeric. Shape is checked here instead of character
-- presence.
local function is_arithmetic(text)
  if text == "" then return false end
  if not text:match(ARITHMETIC) then return false end
  return text:find("[%+%*%/%%%^]") ~= nil
      or text:find("%d%s*%-%s*%d") ~= nil
end
M.is_arithmetic = is_arithmetic

--- True when the payload is a plain number.
local function is_number(text)
  return tonumber(text) ~= nil
end
M.is_number = is_number

local function payload(scanned)
  return Lexer.payload(scanned)
end

local function value(scanned, name)
  return Lexer.value_of(scanned, name)
end

--- The text a print/write should emit: prefer the keyword's own value, fall
--- back to the whole payload.
local function subject(scanned, name)
  local own = value(scanned, name)
  if own ~= "" then return own end
  return payload(scanned)
end

-- ---------------------------------------------------------------------------
-- rules
-- ---------------------------------------------------------------------------

local rules = {

  -- escape hatch ------------------------------------------------------------
  {
    id = "raw_lua",
    requires = { "LUA" },
    priority = 100, -- must beat every interpretation of the same line
    build = function(s)
      return { op = "raw_lua", code = value(s, "LUA") }
    end,
  },

  -- block structure ---------------------------------------------------------
  {
    id = "while_sleep",
    requires = { "REVIVE", "SLEEP" },
    opens = true,
    build = function(s)
      return { op = "while_sleep", delay = value(s, "SLEEP") }
    end,
  },
  {
    id = "while_true",
    requires = { "REVIVE" },
    forbids = { "SLEEP" },
    opens = true,
    build = function() return { op = "while_true" } end,
  },
  {
    id = "if_stmt",
    requires = { "WELL" },
    opens = true,
    build = function(s)
      return { op = "if_stmt", cond = payload(s) }
    end,
  },
  {
    id = "else_stmt",
    -- Declared in main.lua as `local elses = [[<ELSE>]]`, stripped by every
    -- gsub chain, and never emitted -- so an else-branch silently ran as part
    -- of the if-branch. This row is what makes <ELSE> exist.
    requires = { "ELSE" },
    forbids = { "WELL" },
    reopens = true,
    build = function() return { op = "else_stmt" } end,
  },
  {
    id = "for_stmt",
    requires = { "FOR" },
    opens = true,
    build = function(s)
      return { op = "for_stmt", header = payload(s) }
    end,
  },
  {
    id = "block_end",
    requires = { "DONE" },
    closes = true,
    build = function() return { op = "block_end" } end,
  },

  -- declarations ------------------------------------------------------------
  {
    id = "func_decl",
    requires = { "LOCAL", "FUNCTION" },
    opens = true, -- main.lua opened a function and never closed it
    build = function() return { op = "func_decl" } end,
  },
  {
    id = "local_time",
    requires = { "LOCAL", "TIME" },
    forbids = { "READ", "STATE" },
    build = function() return { op = "decl", init = "time" } end,
  },
  {
    id = "local_random",
    requires = { "LOCAL", "GUESS" },
    forbids = { "READ", "STATE" },
    build = function(s)
      return { op = "decl", init = "random", range = subject(s, "GUESS") }
    end,
  },
  {
    id = "local_read",
    requires = { "LOCAL", "READ" },
    forbids = { "FUNCTION" },
    build = function() return { op = "decl", init = "read_all" } end,
  },
  {
    id = "local_string",
    requires = { "LOCAL", "STRING" },
    forbids = { "READ", "STATE", "PRINT", "WRITE" },
    build = function(s)
      return { op = "decl", init = "literal", text = payload(s), force_string = true }
    end,
  },
  {
    id = "local_plain",
    requires = { "LOCAL" },
    forbids = { "TIME", "GUESS", "READ", "STRING", "FUNCTION", "STATE", "PRINT", "WRITE" },
    build = function(s)
      return { op = "decl", init = "literal", text = payload(s) }
    end,
  },
  {
    id = "table_decl",
    requires = { "BASKET" },
    build = function(s)
      return { op = "table_decl", items = subject(s, "BASKET") }
    end,
  },

  -- output ------------------------------------------------------------------
  {
    id = "print_time",
    requires = { "PRINT", "TIME" },
    forbids = { "LOCAL" },
    build = function() return { op = "print", form = "time" } end,
  },
  {
    id = "print_var",
    requires = { "PRINT", "VAR" },
    forbids = { "LOCAL" },
    build = function(s)
      return { op = "print", form = "var", slot = s.present.VAR.slot }
    end,
  },
  {
    id = "print_decl",
    -- `<LOCAL> <STRING> hi <PRINT>` -- declare, then print the variable.
    requires = { "PRINT", "LOCAL" },
    build = function() return { op = "print", form = "last_decl" } end,
  },
  {
    id = "print_expr",
    requires = { "PRINT" },
    forbids = { "LOCAL", "TIME", "VAR" },
    -- Evidence has to cut both ways. Returning 0 for prose left this tied with
    -- print_text at 10, and the id tie-break then emitted every message
    -- unquoted -- `print(starting up)`, which does not parse.
    bonus = function(s)
      return is_arithmetic(subject(s, "PRINT")) and 6 or -5
    end,
    build = function(s)
      return { op = "print", form = "expr", text = subject(s, "PRINT") }
    end,
  },
  {
    id = "print_text",
    requires = { "PRINT" },
    forbids = { "LOCAL", "TIME", "VAR" },
    build = function(s)
      return { op = "print", form = "text", text = subject(s, "PRINT") }
    end,
  },

  {
    id = "write_time",
    requires = { "WRITE", "TIME" },
    forbids = { "LOCAL", "STATE" },
    build = function() return { op = "write", form = "time" } end,
  },
  {
    id = "write_var",
    requires = { "WRITE", "VAR" },
    forbids = { "LOCAL", "STATE" },
    build = function(s)
      return { op = "write", form = "var", slot = s.present.VAR.slot }
    end,
  },
  {
    id = "write_decl",
    requires = { "WRITE", "LOCAL" },
    forbids = { "STATE" },
    build = function() return { op = "write", form = "last_decl" } end,
  },
  {
    id = "write_expr",
    requires = { "WRITE" },
    forbids = { "LOCAL", "TIME", "VAR", "STATE" },
    bonus = function(s)
      return is_arithmetic(subject(s, "WRITE")) and 6 or -5
    end,
    build = function(s)
      return { op = "write", form = "expr", text = subject(s, "WRITE") }
    end,
  },
  {
    id = "write_text",
    requires = { "WRITE" },
    forbids = { "LOCAL", "TIME", "VAR", "STATE" },
    build = function(s)
      return { op = "write", form = "text", text = subject(s, "WRITE") }
    end,
  },

  -- files -------------------------------------------------------------------
  {
    id = "file_open",
    requires = { "CREATE" },
    forbids = { "STATE", "READ" },
    build = function(s)
      return { op = "file_open", path = subject(s, "CREATE") }
    end,
  },
  {
    id = "file_write",
    requires = { "STATE" },
    build = function(s)
      return {
        op = "file_write",
        text = subject(s, "STATE"),
        close = s.present.CLOSE ~= nil,
      }
    end,
  },
  {
    id = "file_read",
    requires = { "READ" },
    forbids = { "LOCAL" },
    build = function() return { op = "file_read" } end,
  },
  {
    id = "file_close",
    requires = { "CLOSE" },
    forbids = { "STATE" },
    build = function() return { op = "file_close" } end,
  },

  -- misc --------------------------------------------------------------------
  {
    id = "sleep_stmt",
    requires = { "SLEEP" },
    forbids = { "REVIVE" },
    build = function(s)
      return { op = "sleep", delay = subject(s, "SLEEP") }
    end,
  },

  -- frontend ----------------------------------------------------------------
  {
    id = "fe_fill",
    requires = { "FILL" },
    build = function(s)
      return { op = "fe_fill", color = value(s, "FILL") }
    end,
  },
  {
    id = "fe_heading_large",
    requires = { "DISPLAYX" },
    build = function(s)
      return { op = "fe_heading", text = value(s, "DISPLAYX"), size = 15 }
    end,
  },
  {
    id = "fe_heading",
    requires = { "DISPLAY" },
    build = function(s)
      return { op = "fe_heading", text = value(s, "DISPLAY"), size = 12 }
    end,
  },
  {
    id = "fe_image_large",
    requires = { "ATTACHL" },
    build = function(s)
      return { op = "fe_image", src = value(s, "ATTACHL"), w = 240, h = 420,
               align = value(s, "POSITION") }
    end,
  },
  {
    id = "fe_image_medium",
    requires = { "ATTACHX" },
    build = function(s)
      return { op = "fe_image", src = value(s, "ATTACHX"), w = 240, h = 240,
               align = value(s, "POSITION") }
    end,
  },
  {
    id = "fe_image",
    requires = { "ATTACH" },
    build = function(s)
      return { op = "fe_image", src = value(s, "ATTACH"), w = 70, h = 70,
               rounded = true, align = value(s, "POSITION") }
    end,
  },
  {
    id = "fe_iframe_wide",
    requires = { "LINKFRAMEX" },
    build = function(s)
      return { op = "fe_iframe", src = value(s, "LINKFRAMEX"), wide = true,
               align = value(s, "POSITION") }
    end,
  },
  {
    id = "fe_iframe",
    requires = { "LINKFRAME" },
    build = function(s)
      return { op = "fe_iframe", src = value(s, "LINKFRAME"),
               align = value(s, "POSITION") }
    end,
  },
  {
    id = "fe_world",
    requires = { "WORLD" },
    build = function(s)
      return { op = "fe_world", model = value(s, "WORLD") }
    end,
  },
  {
    id = "fe_raw_html",
    requires = { "HTML" },
    priority = 100,
    build = function(s)
      return { op = "fe_raw_html", html = value(s, "HTML") }
    end,
  },
  {
    id = "fe_style",
    -- RGB / POSITION / XY / BRACKET all set presentation on the same span.
    -- main.lua spread these across one condition whose `or` bound looser than
    -- its `and not` guards, so `FILL: #000 POSITION: center` entered the
    -- alignment branch anyway and emitted a stray `text-align:center;'>` with
    -- no opening tag. Collecting them into one node removes the condition.
    requires = { "RGB" },
    build = function(s)
      return { op = "fe_style", color = value(s, "RGB"),
               align = value(s, "POSITION"), scale = value(s, "XY") }
    end,
  },
  {
    id = "fe_style_align",
    requires = { "POSITION" },
    forbids = { "RGB", "ATTACH", "ATTACHX", "ATTACHL", "LINKFRAME", "LINKFRAMEX", "FILL" },
    build = function(s)
      return { op = "fe_style", align = value(s, "POSITION"), scale = value(s, "XY") }
    end,
  },
  {
    id = "fe_style_scale",
    requires = { "XY" },
    forbids = { "RGB", "POSITION" },
    build = function(s)
      return { op = "fe_style", scale = value(s, "XY") }
    end,
  },
  {
    id = "fe_bracket",
    requires = { "BRACKET" },
    forbids = { "RGB", "POSITION", "XY" },
    build = function() return { op = "fe_style" } end,
  },
}

M.rules = rules

-- id -> rule, for diagnostics that name the winner.
M.by_id = {}
for _, r in ipairs(rules) do M.by_id[r.id] = r end

return M
