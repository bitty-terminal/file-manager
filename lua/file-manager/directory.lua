-- Bounded directory reads for Bitty File Manager (bitty-terminal.file-manager).
--
-- Directory enumeration goes through the host-mediated `bitty.fs.list`
-- bridge (read-class: it rides the manifest `[[capabilities.filesystem]]`
-- read grant). The plugin never opens, scans, or stats a path itself: this
-- module validates and bounds the host result and turns every failure into a
-- typed value instead of raising into the command dispatcher.
--
-- `bitty.fs` is the Core RFC-0005 bridge beyond the generated Plugin API v1
-- LuaLS surface (the generated surface still records `fs` as a separate
-- capability path), so the one access below disables the undefined-field
-- diagnostic with that provenance instead of editing generated definitions.
--
-- Results are bounded exactly like `listing.lua`: at most `MAX_ENTRIES`
-- entries, names at `MAX_NAME_CHARS` chars, paths at `MAX_PATH_BYTES` bytes,
-- and `PAYLOAD_MAX_BYTES` of accumulated `path` + `name` bytes. Entries sort
-- directories first, then by name and path, so the mounted band is stable.

local listing = require("file-manager.listing")
local scope = require("file-manager.scope")

local M = {}

M.MAX_MESSAGE_CHARS = 160

M.ERROR_FS_UNAVAILABLE = "E_FS_UNAVAILABLE"
M.ERROR_FS_RESULT = "E_FS_RESULT_INVALID"
M.ERROR_SCOPE_UNAVAILABLE = "E_SCOPE_UNAVAILABLE"

-- Build one bounded typed error value. Denials carry the host code and a
-- bounded message; they never carry file contents.
function M.error(code, message, class)
  return {
    class = class or "runtime",
    code = code or M.ERROR_FS_UNAVAILABLE,
    message = scope.char_slice(tostring(message or ""), M.MAX_MESSAGE_CHARS),
  }
end

-- Convert an arbitrary caught value into the typed error shape. Host denials
-- already raise `{ class, code, message }` tables; anything else is reported
-- as the fallback code so the UI path never sees `nil` or a raw string.
function M.error_from(value, fallback_code)
  if type(value) == "table" and type(value.code) == "string" and value.code ~= "" then
    return M.error(value.code, value.message or "", value.class)
  end
  return M.error(fallback_code or M.ERROR_FS_UNAVAILABLE, value)
end

-- The host list function, or `nil` when the surface is absent. `bitty.fs` is
-- always present on a current host, but a host without an fs backend answers
-- with a typed `E_NOT_IMPLEMENTED` from the call itself.
local function fs_list()
  if type(bitty) ~= "table" then
    return nil
  end
  ---@diagnostic disable-next-line: undefined-field
  local fs = bitty.fs
  if type(fs) ~= "table" or type(fs.list) ~= "function" then
    return nil
  end
  return fs.list
end

function M.available()
  return fs_list() ~= nil
end

-- Normalize one host entry. `entry.name` is documented as the entry path on
-- the RFC-0005 listing page but callers also supply a bare basename, so both
-- shapes resolve against `root` before the shared scope/listing bounds run.
local function normalize_entry(raw, root)
  if type(raw) ~= "table" then
    return nil
  end
  local name = raw.name
  if type(name) ~= "string" or name == "" then
    return nil
  end
  local path
  if scope.is_absolute_path(name) then
    path = name
  else
    path = scope.join_root(root, name)
  end
  if path == nil then
    return nil
  end
  local kind = raw.kind
  if kind ~= "file" and kind ~= "dir" and kind ~= "symlink" and kind ~= "other" then
    kind = nil
  end
  return listing.entry_from_path(path, kind, { root = root })
end

-- Normalize, deduplicate, bound, and sort a host listing. Non-table input
-- yields an empty listing (R29); out-of-scope and malformed entries are
-- dropped silently, matching the host's silent-skip listing policy.
function M.normalize(entries, root)
  if type(entries) ~= "table" then
    return {}
  end
  local out = {}
  local seen = {}
  local payload_bytes = 0
  for _, raw in ipairs(entries) do
    if #out >= listing.MAX_ENTRIES then
      break
    end
    local entry = normalize_entry(raw, root)
    if entry ~= nil and not seen[entry.path] then
      local entry_bytes = #entry.path + #entry.name
      if payload_bytes + entry_bytes > listing.PAYLOAD_MAX_BYTES then
        break
      end
      seen[entry.path] = true
      payload_bytes = payload_bytes + entry_bytes
      out[#out + 1] = entry
    end
  end
  table.sort(out, function(a, b)
    if a.kind ~= b.kind then
      return a.kind == "dir"
    end
    if a.name ~= b.name then
      return a.name < b.name
    end
    return a.path < b.path
  end)
  return out
end

-- List one directory through the host bridge.
--
-- Returns `entries, nil` on success (including an empty directory) and
-- `{}, typed_error` when the host denies the read, has no fs backend, or
-- returns a malformed page. Never raises: commands can mount the typed error
-- without crashing the dispatcher.
function M.list(root, opts)
  opts = opts or {}
  if type(root) ~= "string" or root == "" then
    return {}, M.error(M.ERROR_SCOPE_UNAVAILABLE, "a scope root is required", "validation")
  end
  local list = fs_list()
  if list == nil then
    return {}, M.error(M.ERROR_FS_UNAVAILABLE, "host has no bitty.fs.list surface")
  end
  local max_entries = opts.max_entries or listing.MAX_ENTRIES
  if type(max_entries) ~= "number" then
    max_entries = listing.MAX_ENTRIES
  end
  max_entries = math.floor(max_entries)
  if max_entries < 1 then
    max_entries = 1
  end
  if max_entries > listing.MAX_ENTRIES then
    max_entries = listing.MAX_ENTRIES
  end
  local ok, result = pcall(list, root, max_entries)
  if not ok then
    return {}, M.error_from(result)
  end
  if type(result) ~= "table" then
    return {}, M.error(M.ERROR_FS_RESULT, "bitty.fs.list did not return a table")
  end
  return M.normalize(result, root), nil
end

return M
