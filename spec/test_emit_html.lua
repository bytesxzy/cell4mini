local cell4 = require("cell4")
local A = assert_that

local function html_of(text)
  local r = cell4.compile(text)
  A.truthy(r.ok, "expected a clean compile, got:\n" .. r.diagnostics:format())
  return r.html
end

--- Count non-overlapping occurrences of a literal.
local function count(haystack, needle)
  local n, at = 0, 1
  while true do
    local found = haystack:find(needle, at, true)
    if not found then return n end
    n = n + 1
    at = found + #needle
  end
end

return {

  ["the document is closed exactly once, at the end"] = function()
    -- main.lua leaked append handles, so content flushed after </html>.
    local html = html_of("FILL: #000000\nDISPLAY: hello")
    A.equal(count(html, "</html>"), 1)
    A.equal(count(html, "<body"), 1, "expected exactly one body tag")
    A.truthy(html:find("</html>", 1, true) + #"</html>" >= #html - 1,
      "nothing may follow </html>:\n" .. html)
  end,

  -- The verified precedence bug: FILL: and POSITION: on one line produced
  -- `background-color:#000000 POSITION: center;` plus a stray `'>`.
  ["a fill directive does not swallow the next keyword"] = function()
    local html = html_of("FILL: #000000\nPOSITION: center")
    A.contains(html, "background-color:#000000")
    A.omits(html, "POSITION:")
    A.omits(html, "'>")
  end,

  ["style directives open and close a balanced span"] = function()
    local html = html_of("RGB: #ff0000\nDISPLAY: red text\nRGB: #00ff00\nDISPLAY: green text")
    A.equal(count(html, "<span"), count(html, "</span>"),
      "unbalanced spans:\n" .. html)
  end,

  ["text content is escaped"] = function()
    local html = html_of("DISPLAY: 5 < 6 & \"quoted\"")
    A.contains(html, "&lt;")
    A.contains(html, "&amp;")
    A.omits(html, "<h2 style=\"font-size:12px; font-style:serif;\">5 < 6")
  end,

  ["raw html still passes through"] = function()
    local html = html_of("HTML: <hr id='rule'>")
    A.contains(html, "<hr id='rule'>")
  end,

  ["images carry their size and source"] = function()
    local html = html_of("ATTACH: cell4.png")
    A.contains(html, 'src="cell4.png"')
    A.contains(html, "width:70px")

    local large = html_of("ATTACHL: render.png")
    A.contains(large, "height:420px")
  end,

  ["alignment resolves to a class that the stylesheet defines"] = function()
    local html = html_of("ATTACH: cell4.png POSITION: left")
    A.contains(html, 'class="img-left"')
    A.contains(html, ".img-left")
  end,

  ["an unknown alignment is reported, not silently dropped"] = function()
    local r = cell4.compile("ATTACH: cell4.png POSITION: sideways")
    A.contains(r.diagnostics:format(), "unknown alignment")
  end,

  ["iframes are well formed"] = function()
    -- main.lua emitted scrolling="no"" with a stray quote.
    local html = html_of("LINKFRAMEX: menu.html")
    A.contains(html, "</iframe>")
    A.omits(html, '""')
  end,

  ["css values cannot break out of the style attribute"] = function()
    local html = html_of('FILL: red" onload="alert(1)')
    A.omits(html, "onload=")
  end,

  ["a backend-only program still yields a valid document"] = function()
    local html = html_of("<PRINT> hi")
    A.contains(html, "<!DOCTYPE html>")
    A.contains(html, "</html>")
  end,
}
