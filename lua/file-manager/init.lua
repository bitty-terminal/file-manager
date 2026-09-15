-- Entry point for Bitty File Manager (bitty-terminal.file-manager).
--
-- The host evaluates this file once per plugin activation and owns every
-- resource created here for the lifetime of that generation. Registration
-- calls (`bitty.commands.register`, `bitty.events.subscribe`) are valid only
-- while this file executes.
--
-- Accepted surface: Plugin API v1 Lua Surface RFC (ADR 0009). Capabilities
-- requested in `bitty-plugin.toml` are `panel.provider` (tiled panel
-- factory), `panel.create` (panel instantiation),
-- `terminal.semantic-read` (read-only cwd/title observation), plus
-- `fs.read:~/projects/**` (directory listing/preview) and optional
-- `fs.write:~/projects/**` (user-confirmed rename/move/copy). The
-- identifiers are unchanged from the former bundled Rust realization
-- (`bitty` CTX-0399); the split changes no identity.
--
-- Fail-closed discipline: a denied `terminal.semantic-read` propagates
-- instead of serving empty data, out-of-scope paths are dropped, write
-- operations without the `fs.write` scope fail closed, and there is no
-- spawn surface in this plugin (`os.execute`, `io.popen`, and native
-- modules are denied by the Lua Runtime restricted library). Filesystem
-- access is host-mediated: this file validates and shapes bounded data rows
-- and declarative scenes for the host panel surface; the host performs the
-- real-path resolution and I/O. Observation event handlers refresh only the
-- cached snapshot-derived state and never touch the filesystem, keeping the
-- last-known-good value when the snapshot is unavailable.

local scope = require("file-manager.scope")
local listing = require("file-manager.listing")

local M = {}

M.COMMANDS = { "open", "preview", "rename" }
M.EVENTS = { "terminal.cwd-changed", "terminal.title-changed", "focus.changed" }

local cache = {
  cwd = nil,
  title = nil,
}

local function fail(code, message)
  error({ class = "runtime", code = code, message = message }, 0)
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

-- Refresh the cached snapshot-derived state. Called directly by commands
-- (a denied snapshot propagates fail-closed) and behind `pcall` by event
-- handlers (last-known-good survives a denied or slow snapshot).
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

local function raw_paths(args)
  if type(args) == "table" and type(args.paths) == "table" then
    return args.paths
  end
  local entries = setting("entries")
  if type(entries) == "table" then
    return entries
  end
  return {}
end

local function open_entries(args)
  refresh_cache()
  return listing.list_entries(raw_paths(args))
end

local function preview_entry(args)
  refresh_cache()
  local path = type(args) == "table" and args.path or nil
  if type(path) ~= "string" then
    fail("E_FS_DENIED", "preview requires a string path")
  end
  if scope.validate_read(path) == nil then
    fail("E_FS_DENIED", "preview path is outside the fs.read scope")
  end
  local entry = listing.entry_from_path(path, nil)
  if entry == nil then
    fail("E_FS_DENIED", "preview path is not listable")
  end
  entry.parent = scope.parent_dir(path)
  entry.is_dir = scope.is_directory_path(path)
  return entry
end

local function rename_pair(args)
  refresh_cache()
  local src = type(args) == "table" and args.src or nil
  local dst = type(args) == "table" and args.dst or nil
  if type(src) ~= "string" or type(dst) ~= "string" then
    fail("E_FS_DENIED", "rename requires string src and dst")
  end
  if scope.validate_write(src) == nil then
    fail("E_FS_DENIED", "rename src is outside the fs.write scope")
  end
  if scope.validate_write(dst) == nil then
    fail("E_FS_DENIED", "rename dst is outside the fs.write scope")
  end
  return { src = src, dst = dst, name = scope.file_name(dst) }
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
  description = "Validate one user-confirmed rename inside the fs.write scope.",
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

M.open_entries = open_entries
M.preview_entry = preview_entry
M.rename_pair = rename_pair

return M
