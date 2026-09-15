-- Entry point for Bitty File Manager (bitty-terminal.file-manager).
--
-- The host evaluates this file once per plugin activation and owns every
-- resource created here for the lifetime of that generation. Registration
-- calls (`bitty.commands.register`, `bitty.events.subscribe`) are valid only
-- while this file executes.
--
-- Accepted surface: Plugin API v1 Lua Surface RFC (ADR 0009). The single
-- capability requested in `bitty-plugin.toml` is `terminal.semantic-read`
-- (read-only cwd/title observation). H-FM-02: the manifest no longer requests
-- `panel.provider`, `panel.create`, or any `fs.read` / `fs.write` grant —
-- no Lua here calls a panel API or `bitty.fs`, so those were phantom
-- authority; least privilege wins.
--
-- Fail-closed discipline: out-of-scope paths are dropped, operations that
-- cannot resolve a scope root fail closed, and there is no spawn surface in
-- this plugin (`os.execute`, `io.popen`, and native modules are denied by the
-- Lua Runtime restricted library). Filesystem access is host-mediated: this
-- file validates and shapes bounded data rows; the host performs the
-- real-path resolution and I/O.
--
-- H-FM-01: the semantic snapshot is best-effort and only feeds the cached
-- cwd/title. Commands `pcall` the refresh, so a missing focused terminal or a
-- denied `terminal.semantic-read` no longer crashes operations that never use
-- the snapshot; callers supply paths and a root, so every command works
-- headless. The observation event handlers likewise keep the last-known-good
-- value when the snapshot is unavailable.

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

-- M-FM-04: resolve the scope root for one command. Caller-supplied `root`
-- wins, then the `root` setting, then the cached snapshot cwd. `nil` when
-- none is available, which makes every consumer fail closed.
local function resolved_root(args)
  if type(args) == "table" and type(args.root) == "string" and args.root ~= "" then
    return args.root
  end
  local configured = setting("root")
  if type(configured) == "string" and configured ~= "" then
    return configured
  end
  return cache.cwd
end

-- H-FM-01: never let a stale/denied snapshot abort the operation.
local function refresh_cache_safely()
  pcall(refresh_cache)
end

-- Open a bounded listing from explicit args or settings-provided candidates,
-- resolved against the command root. Without any root there is no scope
-- boundary, so the listing is empty rather than unvalidated.
local function open_entries(args)
  refresh_cache_safely()
  local root = resolved_root(args)
  if root == nil then
    return {}
  end
  return listing.list_entries(raw_paths(args), { root = root })
end

-- Validate and shape one in-scope preview entry. Uses the original `path`
-- for the directory marker so a relative `dir/` keeps its trailing slash.
local function preview_entry(args)
  refresh_cache_safely()
  local path = type(args) == "table" and args.path or nil
  if type(path) ~= "string" then
    fail("E_FS_DENIED", "preview requires a string path")
  end
  local root = resolved_root(args)
  if root == nil then
    fail("E_SCOPE_UNAVAILABLE", "preview requires a scope root")
  end
  local candidate = scope.resolve(root, path)
  if candidate == nil then
    fail("E_FS_DENIED", "preview path is outside the scope root")
  end
  local entry = listing.entry_from_path(candidate, nil, { root = root })
  if entry == nil then
    fail("E_FS_DENIED", "preview path is not listable")
  end
  entry.parent = scope.parent_dir(root, candidate)
  entry.is_dir = scope.is_directory_path(root, path)
  return entry
end

-- Validate one user-confirmed rename inside the scope root. L-FM-02: reject
-- identical src/dst (raw or after resolution) and refuse to move the root.
local function rename_pair(args)
  refresh_cache_safely()
  local src = type(args) == "table" and args.src or nil
  local dst = type(args) == "table" and args.dst or nil
  if type(src) ~= "string" or type(dst) ~= "string" then
    fail("E_FS_DENIED", "rename requires string src and dst")
  end
  if src == dst then
    fail("E_FS_DENIED", "rename requires distinct src and dst")
  end
  local root = resolved_root(args)
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

M.open_entries = open_entries
M.preview_entry = preview_entry
M.rename_pair = rename_pair

return M
