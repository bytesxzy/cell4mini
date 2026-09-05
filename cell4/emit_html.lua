--[[ cell4/emit_html.lua -- tree -> source/testing.html

Three things main.lua's frontend pass did that this does not.

1. It opened `io.open(UIDirectory,"a")` thirteen times and closed it five, so
   the remaining handles flushed whenever the collector got to them. Compiling
   `FILL: #000000 POSITION: center` produced the document terminator *before*
   the content:

       <!DOCTYPE html>...<body></body></html>text-align:center;'><body style=...

   Here the document is assembled in memory and written once.

2. It emitted fragments like `text-align:center;'>` with no opening tag, and a
   second `<body>` in the middle of the document. Style directives now open a
   span that is always closed, so the output is balanced whatever the input.

3. It interpolated payloads straight into markup. A caption containing `<` cut
   the page short. Text is escaped; raw markup still has HTML: for that.
]]

local M = {}

local ESCAPES = {
  ["&"] = "&amp;",
  ["<"] = "&lt;",
  [">"] = "&gt;",
  ['"'] = "&quot;",
  ["'"] = "&#39;",
}

local function escape(text)
  return (tostring(text or ""):gsub("[&<>\"']", ESCAPES))
end
M.escape = escape

--- CSS values reach a style attribute, so anything that could close the
--- attribute or start a new declaration is dropped rather than escaped.
local function css_value(text)
  return (tostring(text or ""):gsub("[^%w%s#%%%(%),%.%-_]", ""))
end
M.css_value = css_value

local function js_string(text)
  return (tostring(text or "")
    :gsub("\\", "\\\\")
    :gsub("'", "\\'")
    :gsub("\n", "\\n"))
end

local ALIGNMENTS = {
  middle = true, center = true, left = true, right = true, top = true, bottom = true,
}

--- main.lua wrote class='img-left' and friends but never shipped a stylesheet
--- defining them, so every alignment was a no-op.
local STYLESHEET = [[
    body { margin: 0; }
    .img-middle, .img-center { display: block; margin: 0 auto; }
    .img-left   { display: block; margin-right: auto; }
    .img-right  { display: block; margin-left: auto; }
    .img-top    { vertical-align: top; }
    .img-bottom { vertical-align: bottom; }
    .frame-middle, .frame-center { display: block; margin: 0 auto; }
    .frame-left  { display: block; margin-right: auto; }
    .frame-right { display: block; margin-left: auto; }
]]

local Doc = {}
Doc.__index = Doc

local function new_doc()
  return setmetatable({ parts = {}, span_open = false, background = nil }, Doc)
end

function Doc:add(text)
  self.parts[#self.parts + 1] = text
end

function Doc:close_span()
  if self.span_open then
    self:add("</span>")
    self.span_open = false
  end
end

function Doc:open_span(css)
  self:close_span()
  if css ~= "" then
    self:add("<span style=\"" .. css .. "\">")
    self.span_open = true
  end
end

local function alignment_class(prefix, align, diagnostics, line)
  align = (align or ""):lower():match("^%s*(%S*)")
  if not align or align == "" then return nil end
  if not ALIGNMENTS[align] then
    if diagnostics then
      diagnostics:warning(line, "unknown alignment '" .. align ..
        "'; expected one of middle/center/left/right/top/bottom")
    end
    return nil
  end
  return prefix .. "-" .. align
end

local function emit_node(doc, node, diagnostics)
  local op = node.op

  if op == "fe_fill" then
    -- Sets the body attribute instead of opening a second <body> mid-document.
    doc.background = css_value(node.color)

  elseif op == "fe_heading" then
    doc:add(string.format(
      "<h2 style=\"font-size:%dpx; font-style:serif;\">%s</h2>",
      node.size, escape(node.text)))

  elseif op == "fe_image" then
    if node.src == "" then
      diagnostics:warning(node.line, "image directive has no source path")
    end
    local class = alignment_class("img", node.align, diagnostics, node.line)
    local style = string.format("width:%dpx; height:%dpx;", node.w, node.h)
    if node.rounded then style = style .. " border-radius:2.5px;" end
    if not class then style = "display:block; margin:0 auto; " .. style end
    doc:add(string.format("<img src=\"%s\" alt=\"\"%s style=\"%s\">",
      escape(node.src),
      class and (" class=\"" .. class .. "\"") or "",
      style))

  elseif op == "fe_iframe" then
    if node.src == "" then
      diagnostics:warning(node.line, "iframe directive has no source path")
    end
    local class = alignment_class("frame", node.align, diagnostics, node.line)
    local style = node.wide
      and "border-radius:20px; display:block; margin:0; width:100%; height:125%;"
      or  "display:block; margin:0 auto; width:15%; height:15%;"
    doc:add(string.format(
      "<iframe src=\"%s\"%s style=\"%s\" frameborder=\"0\" scrolling=\"no\"></iframe>",
      escape(node.src),
      class and (" class=\"" .. class .. "\"") or "",
      style))

  elseif op == "fe_style" then
    local css = {}
    if node.color and node.color ~= "" then
      css[#css + 1] = "color:" .. css_value(node.color) .. ";"
    end
    if node.align and node.align ~= "" then
      local a = node.align:lower():match("^%s*(%S*)")
      if a == "middle" then a = "center" end
      if a == "center" or a == "left" or a == "right" then
        css[#css + 1] = "text-align:" .. a .. ";"
      elseif a ~= "" then
        diagnostics:warning(node.line,
          "text alignment '" .. a .. "' is not one of center/left/right")
      end
    end
    if node.scale and node.scale ~= "" then
      local n = tonumber(node.scale)
      if n then
        css[#css + 1] = "transform:scale(" .. n .. "); display:inline-block;"
      else
        diagnostics:warning(node.line,
          "XY: needs a number, got '" .. node.scale .. "'")
      end
    end
    doc:open_span(table.concat(css, " "))

  elseif op == "fe_raw_html" then
    doc:add(node.html)

  elseif op == "fe_world" then
    if node.model == "" then
      diagnostics:warning(node.line, "WORLD: has no model path")
    end
    -- main.lua built two FBXLoaders and added the model to the scene twice,
    -- once untextured and once textured. One load, one add.
    doc:add(table.concat({
      '<div id="cell4-world"></div>',
      '<script src="https://cdnjs.cloudflare.com/ajax/libs/three.js/r128/three.min.js"></script>',
      '<script src="https://cdn.jsdelivr.net/npm/three@0.128.0/examples/js/loaders/FBXLoader.js"></script>',
      '<script>',
      '(function () {',
      '  var scene = new THREE.Scene();',
      '  var camera = new THREE.PerspectiveCamera(75, window.innerWidth / window.innerHeight, 0.1, 1000);',
      '  var renderer = new THREE.WebGLRenderer({ alpha: true });',
      '  renderer.setSize(window.innerWidth, window.innerHeight);',
      '  document.getElementById("cell4-world").appendChild(renderer.domElement);',
      '  camera.position.set(5, 5, 5);',
      '  scene.add(new THREE.AmbientLight(0xcdd1b4, 1));',
      '  var key = new THREE.DirectionalLight(0xcdd1b4, 1.5);',
      '  key.position.set(3.5, 4, 2.5);',
      '  scene.add(key);',
      '  var texture = new THREE.TextureLoader().load("WorldSpace/Texture/maptexture.png");',
      "  new THREE.FBXLoader().load('" .. js_string(node.model) .. "', function (fbx) {",
      '    fbx.traverse(function (child) {',
      '      if (child.isMesh) { child.material.map = texture; child.material.needsUpdate = true; }',
      '    });',
      '    scene.add(fbx);',
      '  });',
      '  (function animate() {',
      '    requestAnimationFrame(animate);',
      '    renderer.render(scene, camera);',
      '  })();',
      '  window.addEventListener("resize", function () {',
      '    renderer.setSize(window.innerWidth, window.innerHeight);',
      '    camera.aspect = window.innerWidth / window.innerHeight;',
      '    camera.updateProjectionMatrix();',
      '  });',
      '}());',
      '</script>',
    }, "\n"))

  else
    diagnostics:error(node.line, "no HTML emitter for '" .. tostring(op) .. "'")
  end
end

--- Render the frontend half of a program.
function M.generate(program, diagnostics)
  local doc = new_doc()

  for _, node in ipairs(program.document) do
    emit_node(doc, node, diagnostics)
  end
  doc:close_span()

  local body_attr = doc.background
    and (" style=\"background-color:" .. doc.background .. "\"")
    or ""

  return table.concat({
    "<!DOCTYPE html>",
    "<html lang=\"en\">",
    "<head>",
    "<meta charset=\"UTF-8\">",
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
    "<title>Generated</title>",
    "<style>",
    STYLESHEET,
    "</style>",
    "</head>",
    "<body" .. body_attr .. ">",
    table.concat(doc.parts, "\n"),
    "</body>",
    "</html>",
    "",
  }, "\n")
end

return M
