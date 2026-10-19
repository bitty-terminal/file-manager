-- Entry point for Bitty File Manager (bitty-terminal.file-manager).
--
-- The host evaluates this file once per plugin activation and owns every
-- resource created here for the lifetime of that generation. Registration
-- calls (`bitty.commands.register`, `bitty.events.subscribe`) are valid only
-- while this file executes.
--
-- Accepted surface: Plugin API v1 Lua Surface RFC (ADR 0009) for commands,
-- events, settings, terminal observation, and `bitty.ui.mount`/`update`.
-- Directory enumeration rides the Core RFC-0005 `bitty.fs.list` bridge under
-- the manifest's read-only `[[capabilities.filesystem]]` grant; `ui.rich`
-- gates the declarative band block. Both requests are least-privilege: read
-- only, no write, no spawn, no network, no clipboard, no terminal input.
--
-- Fail-closed discipline: out-of-scope paths are dropped, operations that
-- cannot resolve a scope root fail closed, and there is no spawn surface in
-- this plugin (`os.execute`, `io.popen`, and native modules are denied by the
-- Lua Runtime restricted library). Filesystem access is host-mediated:
-- `directory.lua` calls `bitty.fs.list` and turns every denial into a typed
-- error value; `scene.lua` shapes the declarative listing block.
--
-- H-FM-01: the semantic snapshot is best-effort and only feeds the cached
-- cwd/title and the default band width. Commands `pcall` the refresh, so a
-- missing focused terminal or a denied `terminal.semantic-read` no longer
-- crashes operations that never use the snapshot; callers supply paths and a
-- root, so every command works headless. The observation event handlers
-- likewise keep the last-known-good value when the snapshot is unavailable.

local directory = require("file-manager.directory")
local listing = require("file-manager.listing")
local scene = require("file-manager.scene")
local scope = require("file-manager.scope")

local M = {}

M.COMMANDS = { "open", "preview", "rename" }
M.EVENTS = { "terminal.cwd-changed", "terminal.title-changed", "focus.changed" }
M.SLOT = "bottom"

local cache = {
  cwd = nil,
  title = nil,
}

-- Mounted presentation state. One block handle is reused through
-- `bitty.ui.update`; the entry list stays bounded by `listing.lua`.
local view = {
  handle = nil,
  root = nil,
  entries = {},
  selected = 1,
  error = nil,
}

local function fail(code, message)
  error({ class = "runtime", code = code, message = message }, 0)
end

local function typed_error(value, fallback_code)
  if type(value) == "table" and type(value.code) == "string" and value.code ~= "" then
    return {
      class = type(value.class) == "string" and value.class or "runtime",
      code = value.code,
      message = tostring(value.message or ""),
    }
  end
  return {
    class = "runtime",
    code = fallback_code or "E_UI_UNAVAILABLE",
    message = tostring(value),
  }
end

-- Read-only semantic snapshot. Errors propagate: a denied
-- `terminal.semantic-read` must fail closed rather than serve empty data.
local function snapshot()
  if bitty.terminal == nil or type(bitty.terminal.snapshot) ~= "function" then
    fail("E_SNAPSHOT_UNAVAILABLE", "host has no terminal.snapshot surface")
  end
  local value = bitty.terminal.snapshot({ scope = "semantic" })
  if type(value) ~= "table" then
    fail("E_SNAPSHOT_UNAVAILABLE", "semantic snapshot is not a table")
  end
  return value
end

-- Refresh the cached snapshot-derived state. Called directly behind `pcall`
-- by commands (H-FM-01: a denied or absent snapshot must not fail an
-- operation that does not need it) and by event handlers (last-known-good
-- survives a denied or slow snapshot).
--
-- The cwd comes from semantic-zone metadata newest-first (Plugin API v1
-- Lua Surface RFC: the snapshot carries no top-level `cwd`; zones without
-- shell integration simply contribute none), mirroring the git-panel
-- package. The title is the snapshot `title`.
local function snapshot_cwd(snap)
  local zones = snap.zones
  if type(zones) ~= "table" then
    return nil
  end
  for index = #zones, 1, -1 do
    local zone = zones[index]
    if type(zone) == "table" and type(zone.metadata) == "table" then
      local cwd = zone.metadata.cwd
      if type(cwd) == "string" and cwd ~= "" then
        return cwd
      end
    end
  end
  return nil
end

local function refresh_cache()
  local snap = snapshot()
  local cwd = snapshot_cwd(snap)
  if cwd ~= nil then
    cache.cwd = cwd
  end
  if type(snap.title) == "string" then
    cache.title = snap.title
  end
  return cache.cwd
end

function M.cached_cwd()
  return cache.cwd
end

local function setting(name)
  if bitty.settings == nil or type(bitty.settings.get) ~= "function" then
    return nil
  end
  local ok, value = pcall(bitty.settings.get, name)
  if ok then
    return value
  end
  return nil
end

local function setting_int(name)
  local value = setting(name)
  if type(value) == "number" and value == math.floor(value) then
    return value
  end
  return nil
end

-- Settings-provided candidate paths (declared `string-array`). Table-shaped
-- settings are not part of the accepted schema, so this is the only settings
-- listing source besides `root`.
local function configured_paths()
  local entries = setting("entries")
  if type(entries) == "table" and #entries > 0 then
    return entries
  end
  return nil
end

local function raw_paths(args)
  if type(args) == "table" and type(args.paths) == "table" and #args.paths > 0 then
    return args.paths
  end
  return configured_paths()
end

-- M-FM-04: resolve the scope root for one command. Caller-supplied `root`
-- wins, then the `root` setting, then the caller fallback (the mounted
-- listing root), then the cached snapshot cwd. `nil` when none is available,
-- which makes every consumer fail closed.
local function resolved_root(args, fallback)
  if type(args) == "table" and type(args.root) == "string" and args.root ~= "" then
    return args.root
  end
  local configured = setting("root")
  if type(configured) == "string" and configured ~= "" then
    return configured
  end
  if type(fallback) == "string" and fallback ~= "" then
    return fallback
  end
  return cache.cwd
end

-- H-FM-01: never let a stale/denied snapshot abort the operation.
local function refresh_cache_safely()
  pcall(refresh_cache)
end

-- Band width: the `width` setting wins, then the semantic snapshot width,
-- then a compact default. The marker/padding budget is subtracted before the
-- name bound is passed to the scene.
local function band_width()
  local configured = setting_int("width")
  if configured ~= nil and configured > 0 then
    return configured
  end
  local ok, snap = pcall(snapshot)
  if ok and type(snap) == "table" and type(snap.width) == "number" and snap.width > 0 then
    return math.floor(snap.width)
  end
  return scene.DEFAULT_NAME_CHARS + scene.MARKER_CHARS
end

local function name_width()
  return band_width() - scene.MARKER_CHARS
end

-- Mount or update the bounded declarative block. A stale/foreign handle falls
-- back to a fresh mount; a denied `ui.rich` raises the host's typed error.
local function mount_component(component)
  local ui = bitty.ui
  if type(ui) ~= "table" or type(ui.mount) ~= "function" then
    return false, typed_error(nil, "E_UI_UNAVAILABLE")
  end
  if view.handle ~= nil and type(ui.update) == "function" then
    local ok, updated = pcall(ui.update, view.handle, component)
    if ok and updated == true then
      return true, nil
    end
    view.handle = nil
  end
  local ok, handle = pcall(ui.mount, M.SLOT, component)
  if not ok then
    return false, typed_error(handle)
  end
  if type(handle) ~= "number" then
    return false, typed_error(nil, "E_UI_UNAVAILABLE")
  end
  view.handle = handle
  return true, nil
end

local function render()
  local component = scene.listing(view.entries, {
    root = view.root,
    selected = view.selected,
    error = view.error,
    width = band_width(),
    name_width = name_width(),
  })
  local ok, err = mount_component(component)
  if not ok then
    error(err, 0)
  end
  return true
end

local function clamp_selection(count, selected)
  if count <= 0 then
    return 1
  end
  selected = math.floor(tonumber(selected) or 1)
  if selected < 1 then
    return 1
  end
  if selected > count then
    return count
  end
  return selected
end

local function selected_index(args, count, root_changed)
  local selected = nil
  if type(args) == "table" then
    if type(args.selected) == "number" then
      selected = args.selected
    elseif type(args.delta) == "number" then
      selected = view.selected + args.delta
    end
  end
  if root_changed and type(args) == "table" and type(args.selected) ~= "number" then
    selected = 1
  end
  if selected == nil then
    selected = view.selected
  end
  return clamp_selection(count, selected)
end

-- Open a bounded listing from the observed cwd (host-mediated `fs.list`) or
-- from explicit settings/args candidates. The mounted block is the primary
-- surface; `true` suppresses the boolean-acknowledgement banner.
local function open_entries(args)
  args = args or {}
  refresh_cache_safely()
  local root = resolved_root(args, nil)
  local root_changed = root ~= view.root
  view.root = root

  local entries = {}
  local list_error = nil
  local paths = raw_paths(args)
  if root == nil then
    list_error = directory.error(
      directory.ERROR_SCOPE_UNAVAILABLE,
      "no scope root is available",
      "validation"
    )
  elseif paths ~= nil then
    entries = listing.list_entries(paths, { root = root })
  else
    entries, list_error = directory.list(root, { max_entries = listing.MAX_ENTRIES })
  end

  view.entries = entries
  view.error = list_error
  view.selected = selected_index(args, #entries, root_changed)
  return render()
end

-- Resolve one preview entry. Without `path`, the currently selected listing
-- row is used, so the existing `preview` command also works from a keyboard
-- binding. The listing re-renders with the selection highlighted.
local function preview_entry(args)
  args = args or {}
  refresh_cache_safely()
  local path = type(args.path) == "string" and args.path or nil
  if path == nil then
    local selected = view.entries[view.selected]
    if type(selected) == "table" then
      path = selected.path
    end
  end
  if type(path) ~= "string" then
    fail("E_FS_DENIED", "preview requires a selected or explicit path")
  end
  local root = resolved_root(args, view.root)
  if root == nil then
    fail("E_SCOPE_UNAVAILABLE", "preview requires a scope root")
  end
  local candidate = scope.resolve(root, path)
  if candidate == nil then
    fail("E_FS_DENIED", "preview path is outside the scope root")
  end
  local is_dir = scope.is_directory_path(root, path)
  local entry = listing.entry_from_path(candidate, is_dir and "dir" or "file", { root = root })
  if entry == nil then
    fail("E_FS_DENIED", "preview path is not listable")
    return nil
  end
  entry.path = scope.trim_trailing_slash(candidate)
  entry.parent = scope.parent_dir(root, candidate)
  entry.is_dir = is_dir

  for index, listed in ipairs(view.entries) do
    if listed.path == entry.path then
      view.selected = index
      break
    end
  end
  render()
  return entry
end

-- Validate one user-confirmed rename inside the scope root. L-FM-02: reject
-- identical src/dst (raw or after resolution) and refuse to move the root.
local function rename_pair(args)
  args = args or {}
  refresh_cache_safely()
  local src = type(args.src) == "string" and args.src or nil
  local dst = type(args.dst) == "string" and args.dst or nil
  if type(src) ~= "string" or type(dst) ~= "string" then
    fail("E_FS_DENIED", "rename requires string src and dst")
  end
  if src == dst then
    fail("E_FS_DENIED", "rename requires distinct src and dst")
  end
  local root = resolved_root(args, view.root)
  if root == nil then
    fail("E_SCOPE_UNAVAILABLE", "rename requires a scope root")
  end
  local src_candidate = scope.resolve(root, src)
  local dst_candidate = scope.resolve(root, dst)
  if src_candidate == nil or scope.validate_write(root, src_candidate) == nil then
    fail("E_FS_DENIED", "rename src is outside the scope root")
  end
  if dst_candidate == nil or scope.validate_write(root, dst_candidate) == nil then
    fail("E_FS_DENIED", "rename dst is outside the scope root")
  end
  if scope.is_root(root, src_candidate) then
    fail("E_FS_DENIED", "rename cannot move the scope root")
  end
  if src_candidate == dst_candidate then
    fail("E_FS_DENIED", "rename requires distinct src and dst")
  end
  return { src = src_candidate, dst = dst_candidate, name = scope.file_name(dst_candidate) }
end

bitty.commands.register({
  id = "open",
  title = "File Manager: open",
  description = "Open the file manager with the bounded directory listing.",
  run = function(args)
    return open_entries(args or {})
  end,
})

bitty.commands.register({
  id = "preview",
  title = "File Manager: preview",
  description = "Show the bounded preview entry for one in-scope path.",
  run = function(args)
    return preview_entry(args or {})
  end,
})

bitty.commands.register({
  id = "rename",
  title = "File Manager: rename",
  description = "Validate one user-confirmed rename inside the scope root.",
  run = function(args)
    return rename_pair(args or {})
  end,
})

-- Observation handlers refresh only the cached snapshot-derived state and
-- never touch the filesystem: a slow or denied snapshot cannot stall event
-- dispatch, and the last-known-good value survives.
bitty.events.subscribe("terminal.cwd-changed", function(_event)
  pcall(refresh_cache)
end)

bitty.events.subscribe("terminal.title-changed", function(_event)
  pcall(refresh_cache)
end)

bitty.events.subscribe("focus.changed", function(_event)
  pcall(refresh_cache)
end)

function M.listing_state()
  return {
    root = view.root,
    entries = view.entries,
    selected = view.selected,
    error = view.error,
    handle = view.handle,
  }
end

M.open_entries = open_entries
M.preview_entry = preview_entry
M.rename_pair = rename_pair

return M
