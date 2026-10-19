-- Behavior spec for the file-manager declarative listing scenes.
--
-- Run from the package root: `lua5.4 tests/run.lua`.

local M = {}

local function children(node)
  return type(node) == "table" and type(node.children) == "table" and node.children or {}
end

local function collect(node, predicate, out)
  out = out or {}
  if type(node) ~= "table" then
    return out
  end
  if predicate(node) then
    out[#out + 1] = node
  end
  for _, child in ipairs(children(node)) do
    collect(child, predicate, out)
  end
  return out
end

function M.run(context)
  local tap = context.tap
  local scene = require("file-manager.scene")
  local scope = require("file-manager.scope")
  local listing = require("file-manager.listing")

  tap.equal(scene.MAX_NAME_CHARS, listing.MAX_NAME_CHARS, "scene name bound mirrors listings")
  tap.equal(scene.MAX_VISIBLE_ROWS, 12, "visible rows are bounded")

  local short, truncated = scene.format_name("notes.txt", 20)
  tap.equal(short, "notes.txt", "short name unchanged")
  tap.equal(truncated, false, "short name not truncated")

  local long, long_truncated = scene.format_name(string.rep("a", 40), 20)
  tap.equal(scope.char_count(long), 20, "long name truncates to width")
  tap.equal(long_truncated, true, "long name flags truncation")
  tap.equal(string.sub(long, -3), "…", "truncation keeps an ellipsis")

  local tiny = scene.format_name(string.rep("a", 20), 1)
  tap.equal(scope.char_count(tiny), scene.MIN_NAME_CHARS, "width floor clamps to the minimum")

  -- Empty and error states are non-empty blocks.
  local empty = scene.listing({}, { root = "/srv/repo", width = 40 })
  tap.equal(empty.kind, "Column", "empty listing is a column")
  tap.ok(#children(empty) >= 1, "empty listing is non-empty")
  local empty_text = collect(empty, function(node)
    return node.kind == "Text"
  end)
  tap.ok(#empty_text >= 1, "empty listing carries text")

  local denied = scene.listing({}, {
    root = "/srv/repo",
    width = 40,
    error = { code = "E_FS_SCOPE_MISMATCH", message = "denied" },
  })
  local denied_text = collect(denied, function(node)
    return node.kind == "Text" and type(node.text) == "string"
  end)
  local joined = ""
  for _, node in ipairs(denied_text) do
    joined = joined .. node.text .. "\n"
  end
  tap.ok(string.find(joined, "E_FS_SCOPE_MISMATCH", 1, true) ~= nil, "error code is rendered")

  -- A populated listing carries a header, a bounded List, and click bindings
  -- only for the plugin's existing commands.
  local entries = {
    { name = "docs", path = "/srv/repo/docs", kind = "dir", truncated = false },
    { name = "a.txt", path = "/srv/repo/a.txt", kind = "file", truncated = false },
    { name = "b.txt", path = "/srv/repo/b.txt", kind = "file", truncated = false },
  }
  local component = scene.listing(entries, { root = "/srv/repo", selected = 2, width = 30 })
  tap.equal(component.kind, "Column", "listing is a column")
  local lists = collect(component, function(node)
    return node.kind == "List"
  end)
  tap.equal(#lists, 1, "listing contains one List")
  tap.equal(#children(lists[1]), 3, "list contains every entry")
  local rows = collect(component, function(node)
    return node.kind == "Row"
  end)
  tap.equal(#rows, 3, "one row per entry")
  local click_commands = {}
  for _, node in ipairs(collect(component, function(value)
    return type(value.on_click) == "table"
  end)) do
    click_commands[#click_commands + 1] = node.on_click.command
  end
  local saw_open, saw_preview = false, false
  for _, command in ipairs(click_commands) do
    saw_open = saw_open or command == "open"
    saw_preview = saw_preview or command == "preview"
  end
  tap.ok(saw_open, "directory rows use the open command")
  tap.ok(saw_preview, "file rows use the preview command")

  -- Selection is highlighted on the matching row only.
  local selected_rows = collect(component, function(node)
    return node.kind == "Row" and node.bold == true
  end)
  tap.equal(#selected_rows, 1, "one selected row")

  -- The visible window is bounded and follows the selection.
  local many = {}
  for index = 1, 40 do
    many[#many + 1] = {
      name = string.format("file%02d.txt", index),
      path = "/srv/repo/file" .. index,
      kind = "file",
      truncated = false,
    }
  end
  local windowed = scene.listing(many, {
    root = "/srv/repo",
    selected = 30,
    width = 30,
    max_rows = 5,
  })
  local windowed_rows = collect(windowed, function(node)
    return node.kind == "Row"
  end)
  tap.equal(#windowed_rows, 5, "windowed listing shows max_rows")
  local footer = collect(windowed, function(node)
    return node.kind == "Text" and type(node.text) == "string" and string.find(node.text, "rows", 1, true)
  end)
  tap.equal(#footer, 1, "windowed listing reports the row range")

  local first, last = scene.visible_window(40, 1, 5)
  tap.equal(first, 1, "window starts at one")
  tap.equal(last, 5, "window ends at max_rows")
  local tail_first, tail_last = scene.visible_window(40, 40, 5)
  tap.equal(tail_first, 36, "tail window starts at count-max_rows+1")
  tap.equal(tail_last, 40, "tail window ends at count")
  tap.equal(select(2, scene.visible_window(0, 1, 5)), 0, "empty window is empty")

  -- Preview output is bounded and carries the resolved fields.
  local preview = scene.preview({
    name = string.rep("long", 20),
    path = "/srv/repo/" .. string.rep("long", 20),
    kind = "file",
    parent = "/srv/repo",
  }, { width = 24 })
  tap.equal(preview.kind, "Column", "preview is a column")
  local preview_text = collect(preview, function(node)
    return node.kind == "Text"
  end)
  tap.ok(#preview_text >= 3, "preview carries fields")
  for _, node in ipairs(preview_text) do
    tap.le(scope.char_count(node.text), 24, "preview text respects width")
  end
end

return M
