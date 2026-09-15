-- Behavior spec for the file-manager declarative scenes.
--
-- Run from the package root: `lua5.4 tests/run.lua`.

local M = {}

local function kinds(node, out)
  out = out or {}
  if type(node) ~= "table" then
    return out
  end
  if type(node.kind) == "string" then
    out[#out + 1] = node.kind
  end
  if type(node.children) == "table" then
    for _, child in ipairs(node.children) do
      kinds(child, out)
    end
  end
  return out
end

local function only_v1(node)
  for _, kind in ipairs(kinds(node)) do
    if kind ~= "Text" and kind ~= "Row" and kind ~= "Column" and kind ~= "List" then
      return false
    end
  end
  return true
end

function M.run(context)
  local tap = context.tap
  local scene = require("file-manager.scene")

  tap.ok(only_v1(scene.empty()), "empty uses v1 nodes only")

  local entries = {
    { name = "bar.rs", path = "~/projects/bar.rs", kind = "file", truncated = false },
    { name = "docs", path = "~/projects/docs/", kind = "dir", truncated = false },
  }
  tap.ok(only_v1(scene.directory(entries)), "directory uses v1 nodes only")

  local rows = scene.file_rows(entries, 64)
  tap.equal(#rows, 2, "two file rows")
  tap.equal(rows[2].label, "docs/", "directory marker suffixed")

  local preview = scene.preview("~/projects/foo.txt", { "line one", "line two" })
  tap.ok(only_v1(preview), "preview uses v1 nodes only")
  tap.equal(preview.kind, "Column", "preview is a column")

  local rename = scene.rename("~/projects/old.txt", "~/projects/new.txt")
  tap.ok(only_v1(rename), "rename uses v1 nodes only")
  tap.equal(rename.kind, "Column", "rename is a column")
  tap.equal(#rename.children, 2, "rename shows src and dst")

  local long = string.rep("c", 200)
  local truncated = scene.file_rows(
    { { name = long, path = "~/projects/" .. long, kind = "file", truncated = true } },
    64
  )
  tap.ok(#truncated[1].label <= 128 + 8, "long file label truncated near bound")

  local empty_dir = scene.directory({})
  tap.equal(empty_dir.kind, "Column", "empty directory falls back to placeholder")
end

return M
