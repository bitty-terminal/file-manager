-- Declarative listing scenes for Bitty File Manager (bitty-terminal.file-manager).
--
-- Accepted Plugin API v1 UI surface: `bitty.ui.mount` / `bitty.ui.update`
-- accept only `Text`, `Row`, `Column`, and `List` nodes. This module is pure
-- (no host access): it shapes bounded scene tables from already-validated
-- entries, truncates display names to the hosted band width, and attaches
-- `on_click` bindings to the plugin's existing `open` and `preview` commands.
--
-- Bounds: names truncate at the band width (and never beyond the listing
-- `MAX_NAME_CHARS`), the band shows at most `MAX_VISIBLE_ROWS` rows, and every
-- text field is sliced at a code-point boundary. Empty and denied listings
-- still produce a non-empty explanatory block, so `ui.mount` is never called
-- with an empty component.

local listing = require("file-manager.listing")
local scope = require("file-manager.scope")

local M = {}

M.ELLIPSIS = "…"
M.DEFAULT_NAME_CHARS = 32
M.MIN_NAME_CHARS = 8
M.MAX_NAME_CHARS = listing.MAX_NAME_CHARS
M.MAX_VISIBLE_ROWS = 12
M.SELECTED_FG = "accent"
M.DIRECTORY_MARKER = "▸ "
M.FILE_MARKER = "  "
M.MARKER_CHARS = 2

-- Clamp an integer-ish width into the accepted display range.
local function bounded_width(width)
  local value = tonumber(width)
  if value == nil then
    value = M.DEFAULT_NAME_CHARS
  end
  value = math.floor(value)
  if value < M.MIN_NAME_CHARS then
    value = M.MIN_NAME_CHARS
  end
  if value > M.MAX_NAME_CHARS then
    value = M.MAX_NAME_CHARS
  end
  return value
end

-- Truncate one display name to `width` code points with a trailing ellipsis.
-- Returns `text, truncated`; the result never exceeds `width`.
function M.format_name(name, width)
  if type(name) ~= "string" then
    name = ""
  end
  width = bounded_width(width)
  if scope.char_count(name) <= width then
    return name, false
  end
  if width <= 1 then
    return scope.char_slice(M.ELLIPSIS, width), true
  end
  return scope.char_slice(name, width - 1) .. M.ELLIPSIS, true
end

local function text(content, opts)
  opts = opts or {}
  local max_chars = opts.max_chars or M.MAX_NAME_CHARS
  return {
    kind = "Text",
    text = scope.char_slice(tostring(content or ""), max_chars),
    fg = opts.fg,
    bg = opts.bg,
    bold = opts.bold,
    on_click = opts.on_click,
  }
end

-- One clickable row. Directories navigate through the existing `open`
-- command; files select/preview through the existing `preview` command.
function M.entry_row(entry, opts)
  opts = opts or {}
  local name, truncated = M.format_name(entry.name, opts.name_width)
  local is_dir = entry.kind == "dir"
  local marker = is_dir and M.DIRECTORY_MARKER or M.FILE_MARKER
  local selected = opts.selected == true
  local on_click = nil
  if type(entry.path) == "string" and entry.path ~= "" then
    if is_dir then
      on_click = { command = "open", args = { root = entry.path, selected = 1 } }
    else
      on_click = { command = "preview", args = { path = entry.path } }
    end
  end
  local label = { kind = "Text", text = marker .. name }
  label.fg = selected and M.SELECTED_FG or nil
  label.bold = selected or nil
  label.on_click = on_click
  local row = { kind = "Row", children = { label } }
  row.fg = selected and M.SELECTED_FG or nil
  row.bold = selected or nil
  row.on_click = on_click
  return row, truncated
end

-- Visible window around `selected`: keeps the band bounded while letting
-- navigation reach every entry.
function M.visible_window(count, selected, max_rows)
  max_rows = math.floor(tonumber(max_rows) or M.MAX_VISIBLE_ROWS)
  if max_rows < 1 then
    max_rows = 1
  end
  if count <= 0 then
    return 1, 0
  end
  selected = math.floor(tonumber(selected) or 1)
  if selected < 1 then
    selected = 1
  end
  if selected > count then
    selected = count
  end
  if count <= max_rows then
    return 1, count
  end
  local first = selected - math.floor(max_rows / 2)
  if first < 1 then
    first = 1
  end
  local last = first + max_rows - 1
  if last > count then
    last = count
    first = last - max_rows + 1
  end
  return first, last
end

function M.empty(root, opts)
  opts = opts or {}
  return {
    kind = "Column",
    children = {
      text("Empty directory", { bold = true, max_chars = M.DEFAULT_NAME_CHARS }),
      text(root or "", { max_chars = opts.width or M.DEFAULT_NAME_CHARS }),
    },
  }
end

-- Typed error block. The command returns normally; the band explains why the
-- listing is unavailable instead of dispatching a crash.
function M.error(err, root, opts)
  opts = opts or {}
  local code = type(err) == "table" and err.code or "E_FS_UNAVAILABLE"
  local message = type(err) == "table" and err.message or tostring(err)
  return {
    kind = "Column",
    children = {
      text("File manager unavailable", { bold = true, max_chars = M.DEFAULT_NAME_CHARS }),
      text(code .. ": " .. tostring(message or ""), { max_chars = opts.width or M.DEFAULT_NAME_CHARS + 16 }),
      text(root or "", { max_chars = opts.width or M.DEFAULT_NAME_CHARS }),
    },
  }
end

-- Build the mounted listing. Always returns a non-empty `Column` or `List`.
function M.listing(entries, opts)
  opts = opts or {}
  local root = opts.root or ""
  local width = bounded_width(opts.width)
  local name_width = bounded_width(opts.name_width or (width - M.MARKER_CHARS))
  if opts.error ~= nil then
    return M.error(opts.error, root, { width = width })
  end
  if type(entries) ~= "table" or #entries == 0 then
    return M.empty(root, { width = width })
  end

  local selected = opts.selected or 1
  local first, last = M.visible_window(#entries, selected, opts.max_rows)
  local children = {
    text("File Manager: " .. tostring(root), { bold = true, max_chars = width }),
  }
  local rows = {}
  local any_truncated = false
  for index = first, last do
    local entry = entries[index]
    local row, truncated = M.entry_row(entry, {
      name_width = name_width,
      selected = index == selected,
    })
    any_truncated = any_truncated or truncated
    rows[#rows + 1] = row
  end
  children[#children + 1] = { kind = "List", children = rows }

  local noun = #entries == 1 and "entry" or "entries"
  local footer = string.format("%d %s", #entries, noun)
  if any_truncated then
    footer = footer .. " · names truncated"
  end
  if last > first or #entries > (last - first + 1) then
    footer = footer .. string.format(" · rows %d-%d", first, last)
  end
  children[#children + 1] = text(footer, { max_chars = width })
  return { kind = "Column", children = children }
end

-- Bounded preview scene for one selected entry.
function M.preview(entry, opts)
  opts = opts or {}
  local width = bounded_width(opts.width)
  local name = M.format_name(entry.name, width)
  local kind = entry.kind or "file"
  local parent = entry.parent or ""
  return {
    kind = "Column",
    children = {
      text("Preview: " .. name, { bold = true, max_chars = width }),
      text("kind: " .. kind, { max_chars = width }),
      text("path: " .. tostring(entry.path or ""), { max_chars = width }),
      text("parent: " .. tostring(parent), { max_chars = width }),
    },
  }
end

return M
