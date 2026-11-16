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
M.MAX_PANEL_ROWS = 20
M.MAX_PREVIEW_LINES = 12
M.DEFAULT_PREVIEW_WIDTH = 48
M.SELECTED_FG = "accent"
M.DIRECTORY_MARKER = "▸ "
M.FILE_MARKER = "  "
M.MARKER_CHARS = 2

local KIND_BADGES = {
  dir = "[DIR]",
  file = "[FILE]",
  symlink = "[LINK]",
  other = "[OTHER]",
}

function M.kind_badge(kind)
  return KIND_BADGES[kind] or KIND_BADGES.file
end

function M.format_size(bytes)
  if type(bytes) ~= "number" or bytes < 0 then
    return nil
  end
  bytes = math.floor(bytes)
  if bytes < 1024 then
    return string.format("%dB", bytes)
  end
  if bytes < 1024 * 1024 then
    return string.format("%.1fK", bytes / 1024)
  end
  return string.format("%.1fM", bytes / (1024 * 1024))
end

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
  local row_children = {}
  if opts.show_badge then
    row_children[#row_children + 1] = {
      kind = "Text",
      text = M.kind_badge(entry.kind) .. " ",
      fg = selected and M.SELECTED_FG or nil,
      bold = selected or nil,
      on_click = on_click,
    }
  end
  row_children[#row_children + 1] = label
  local size_text = M.format_size(entry.size)
  if size_text ~= nil then
    row_children[#row_children + 1] = {
      kind = "Text",
      text = " " .. size_text,
      fg = selected and M.SELECTED_FG or nil,
      bold = selected or nil,
      on_click = on_click,
    }
  end
  local row = { kind = "Row", children = row_children }
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

-- Hidden block. Plugin API v1 has no `ui.unmount` (bitty#3106), so closing the
-- listing reuses the mounted handle with this component: one empty `Text`
-- child reserves no band row. (The DevTools live view hides its blocks with a
-- bare empty `Text` rather than a wrapper `Column`; the visible effect is the
-- same, the node shape is not.)
function M.hidden()
  return { kind = "Column", children = { text("") } }
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

-- Header bar for panel mode: breadcrumb/path, item count, hidden indicator,
-- and optional status/error banner.
function M.header_bar(opts)
  opts = opts or {}
  local width = bounded_width(opts.width)
  local count = math.floor(tonumber(opts.count) or 0)
  local noun = count == 1 and "item" or "items"
  local hidden_label = opts.show_hidden and "[hidden: on]" or "[hidden: off]"
  local root_text = tostring(opts.root or "(no root)")
  local children = {
    {
      kind = "Row",
      children = {
        text(root_text, { bold = true, fg = M.SELECTED_FG, max_chars = width }),
        text(" · " .. string.format("%d %s", count, noun), { max_chars = 24 }),
        text(" · " .. hidden_label, { max_chars = 20 }),
      },
    },
  }
  if type(opts.error) == "table" then
    local code = tostring(opts.error.code or "E_FS_UNAVAILABLE")
    local message = tostring(opts.error.message or "")
    children[#children + 1] = text("Error: " .. code .. ": " .. message, {
      bold = true,
      max_chars = width + 24,
    })
  elseif type(opts.status) == "string" and opts.status ~= "" then
    children[#children + 1] = text(opts.status, { max_chars = width + 24 })
  end
  return { kind = "Column", children = children }
end

-- Right-hand split preview pane inside the Dwindle panel.
function M.preview_pane(selected_entry, preview_data, opts)
  opts = opts or {}
  local preview_width = bounded_width(opts.preview_width or M.DEFAULT_PREVIEW_WIDTH)
  if type(selected_entry) ~= "table" then
    return {
      kind = "Column",
      children = {
        text("Preview", { bold = true, max_chars = preview_width }),
        text("No entry selected", { max_chars = preview_width }),
      },
    }
  end

  local badge = M.kind_badge(selected_entry.kind)
  local title_name = M.format_name(selected_entry.name, preview_width)
  local children = {
    text(badge .. " " .. title_name, { bold = true, fg = M.SELECTED_FG, max_chars = preview_width }),
    text(tostring(selected_entry.path or ""), { max_chars = preview_width }),
  }
  local size_text = M.format_size(selected_entry.size)
  if size_text ~= nil then
    children[#children + 1] = text("size: " .. size_text, { max_chars = preview_width })
  end

  if selected_entry.kind == "dir" then
    if type(preview_data) == "table" and type(preview_data.entries) == "table" then
      local dir_entries = preview_data.entries
      local noun = #dir_entries == 1 and "item" or "items"
      children[#children + 1] = text(string.format("Directory (%d %s)", #dir_entries, noun), {
        bold = true,
        max_chars = preview_width,
      })
      if #dir_entries == 0 then
        children[#children + 1] = text("(empty directory)", { max_chars = preview_width })
      else
        local limit = math.min(#dir_entries, M.MAX_PREVIEW_LINES)
        for index = 1, limit do
          local child = dir_entries[index]
          children[#children + 1] = text(
            M.kind_badge(child.kind) .. " " .. tostring(child.name or ""),
            { max_chars = preview_width }
          )
        end
        if #dir_entries > limit then
          children[#children + 1] = text(string.format("… +%d more", #dir_entries - limit), {
            max_chars = preview_width,
          })
        end
      end
    elseif type(preview_data) == "table" and type(preview_data.error) == "table" then
      children[#children + 1] = text(
        tostring(preview_data.error.code or "E_FS_UNAVAILABLE")
          .. ": "
          .. tostring(preview_data.error.message or ""),
        { max_chars = preview_width }
      )
    else
      children[#children + 1] = text("Directory", { max_chars = preview_width })
    end
  else
    if type(preview_data) == "table" and type(preview_data.lines) == "table" then
      local lines = preview_data.lines
      if #lines == 0 then
        children[#children + 1] = text("(empty file)", { max_chars = preview_width })
      else
        local limit = math.min(#lines, M.MAX_PREVIEW_LINES)
        for index = 1, limit do
          children[#children + 1] = text(lines[index], { max_chars = preview_width })
        end
        if preview_data.truncated or #lines > limit then
          children[#children + 1] = text("… (truncated)", { max_chars = preview_width })
        end
      end
    elseif type(preview_data) == "table" and type(preview_data.error) == "table" then
      children[#children + 1] = text(
        tostring(preview_data.error.code or "E_FS_UNAVAILABLE")
          .. ": "
          .. tostring(preview_data.error.message or ""),
        { max_chars = preview_width }
      )
    else
      children[#children + 1] = text("No file preview available", { max_chars = preview_width })
    end
  end

  return { kind = "Column", children = children }
end

-- Nautilus / Dolphin / Yazi-style Dwindle panel scene with header bar,
-- entry list with type badges & selection highlight, and live split preview.
function M.panel(entries, opts)
  opts = opts or {}
  entries = type(entries) == "table" and entries or {}
  local root = opts.root or ""
  local width = bounded_width(opts.width)
  local name_width = bounded_width(opts.name_width or (width - M.MARKER_CHARS))
  local max_rows = opts.max_rows or M.MAX_PANEL_ROWS
  local selected = opts.selected or 1
  if selected < 1 then
    selected = 1
  end
  if #entries > 0 and selected > #entries then
    selected = #entries
  end

  local header = M.header_bar({
    root = root,
    count = #entries,
    show_hidden = opts.show_hidden == true,
    error = opts.error,
    status = opts.status,
    width = width,
  })

  local left_pane
  local first, last = M.visible_window(#entries, selected, max_rows)
  if opts.error ~= nil and #entries == 0 then
    left_pane = M.error(opts.error, root, { width = width })
  elseif #entries == 0 then
    left_pane = M.empty(root, { width = width })
  else
    local rows = {}
    for index = first, last do
      local entry = entries[index]
      local row = M.entry_row(entry, {
        name_width = name_width,
        selected = index == selected,
        show_badge = true,
      })
      rows[#rows + 1] = row
    end
    left_pane = { kind = "Column", children = { { kind = "List", children = rows } } }
  end

  local selected_entry = #entries > 0 and entries[selected] or nil
  local right_pane = M.preview_pane(selected_entry, opts.preview, {
    preview_width = opts.preview_width or M.DEFAULT_PREVIEW_WIDTH,
  })

  local footer_text = "j/k:move  Enter/l:open  h/Bs:up  .:hidden  r:refresh  q:close"
  if #entries > 0 and (last > first or #entries > (last - first + 1)) then
    footer_text = string.format("rows %d-%d/%d · %s", first, last, #entries, footer_text)
  end

  return {
    kind = "Column",
    children = {
      header,
      {
        kind = "Row",
        children = {
          left_pane,
          right_pane,
        },
      },
      text(footer_text, { max_chars = width + M.DEFAULT_PREVIEW_WIDTH }),
    },
  }
end

return M
