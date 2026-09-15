-- Declarative scenes for Bitty File Manager (bitty-terminal.file-manager).
--
-- Pure builders producing Plugin API v1 declarative components only
-- (`Text`, `Row`, `Column`, `List`, depth `16`) for directory listings,
-- file previews, and rename confirmations. No host dependency, no I/O. The
-- host mounts the returned component in the panel surface owned by the
-- `panel.provider` registration; this module never touches PTY bytes, the
-- grid, or the render/input hot paths. Text truncates to the file-name bound
-- (`128`) and preview bodies to the panel payload bound (`8 KiB` roughly
-- expressed as bounded lines).

local listing = require("file-manager.listing")
local scope = require("file-manager.scope")

local M = {}

local function text(value)
  return { kind = "Text", text = value }
end

-- Empty panel placeholder.
function M.empty()
  return { kind = "Column", children = { text("No files.") } }
end

-- Bounded file rows for command results and tests: `{ label, kind }` with
-- labels truncated to the file-name bound plus a directory marker.
function M.file_rows(entries, max_rows)
  local rows = {}
  local limit = max_rows or listing.MAX_SELECTION
  for _, entry in ipairs(entries or {}) do
    if #rows >= limit then
      break
    end
    local label = scope.truncate_name(entry.name or "")
    if entry.kind == "dir" then
      label = label .. "/"
    end
    if entry.truncated then
      label = label .. "…"
    end
    rows[#rows + 1] = { label = label, kind = entry.kind or "file", path = entry.path }
  end
  return rows
end

-- Directory listing as a v1 `List` of `path`-sorted `Text` rows, bounded to
-- the entry cap.
function M.directory(entries)
  local children = {}
  for index, entry in ipairs(entries or {}) do
    if index > listing.MAX_ENTRIES then
      break
    end
    local label = scope.truncate_name(entry.name or "")
    if entry.kind == "dir" then
      label = label .. "/"
    end
    children[#children + 1] = text(label)
  end
  if #children == 0 then
    return M.empty()
  end
  return { kind = "List", children = children }
end

-- File preview as a v1 `Column` of bounded `Text` lines: a header row plus
-- up to `32` preview lines. Bodies beyond the payload bound are cut with an
-- ellipsis marker.
function M.preview(path, lines)
  local name = scope.file_name(path or "") or scope.truncate_name(path or "")
  local children = { text(name) }
  local count = 0
  for _, line in ipairs(lines or {}) do
    if count >= 32 then
      break
    end
    children[#children + 1] = text(scope.truncate_name(tostring(line)))
    count = count + 1
  end
  if #children == 1 then
    children[#children + 1] = text("(empty preview)")
  end
  return { kind = "Column", children = children }
end

-- Rename confirmation as a v1 `Column` of two bounded `Text` rows.
function M.rename(src, dst)
  return {
    kind = "Column",
    children = {
      text(scope.truncate_name(src or "")),
      text(scope.truncate_name(dst or "")),
    },
  }
end

return M
