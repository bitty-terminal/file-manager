-- Bounded file listings for Bitty File Manager (bitty-terminal.file-manager).
--
-- Pure functions with no host dependency. Mirrors the former bundled Rust
-- realization (`bitty-runtime/src/file_manager.rs`, removed by `bitty`
-- CTX-0399): at most `128` entries per directory, names at `128` chars,
-- paths at `4096` bytes, selection at `64`, panel payloads at `8 KiB`.
-- Listings sort deterministically, deduplicate by path, and truncate;
-- filters are case-insensitive substring matches bounded to the listing cap.
--
-- Entries are plain `{ name, path, kind, truncated }` tables. `kind` is one
-- of `file`, `dir`, `symlink`, `other` (presentation only, inferred from
-- the trailing slash when not supplied).

local scope = require("file-manager.scope")

local M = {}

M.MAX_ENTRIES = 128
M.MAX_NAME_CHARS = 128
M.MAX_PATH_BYTES = 4096
M.MAX_SELECTION = 64
M.PAYLOAD_MAX_BYTES = 8192

local function is_entry_table(value)
  return type(value) == "table"
end

local function infer_kind(path, kind)
  if kind == "file" or kind == "dir" or kind == "symlink" or kind == "other" then
    return kind
  end
  if string.sub(path, -1) == "/" then
    return "dir"
  end
  return "file"
end

-- Build one bounded entry from `path`, or `nil` for invalid or
-- out-of-scope paths. Names truncate at a code-point boundary with the
-- `truncated` flag set.
function M.entry_from_path(path, kind)
  if type(path) ~= "string" then
    return nil
  end
  if not scope.is_valid_path(path) then
    return nil
  end
  if not scope.is_within_read_scope(path) then
    return nil
  end
  local raw = scope.file_name(path)
  -- `file_name` returns nil for the scope root; entries never include it.
  -- Re-derive the raw segment here so `truncated` is exact.
  if raw == nil then
    local trimmed = string.gsub(path, "/+$", "")
    if trimmed == "~/projects" then
      return nil
    end
    return nil
  end
  local full = (function()
    local trimmed = string.gsub(path, "/+$", "")
    local name = string.match(trimmed, "([^/]+)$")
    return name or raw
  end)()
  local truncated = scope.char_count(full) > M.MAX_NAME_CHARS
  local name = scope.truncate_name(full)
  return {
    name = name,
    path = path,
    kind = infer_kind(path, kind),
    truncated = truncated,
  }
end

-- Filter and bound a raw `paths` listing to `MAX_ENTRIES` entries, sorted
-- deterministically by path and deduplicated. Pure observation.
function M.list_entries(paths)
  local entries = {}
  local seen = {}
  for _, path in ipairs(paths or {}) do
    local entry = M.entry_from_path(path, nil)
    if entry ~= nil and not seen[entry.path] then
      seen[entry.path] = true
      entries[#entries + 1] = entry
    end
  end
  table.sort(entries, function(a, b)
    return a.path < b.path
  end)
  while #entries > M.MAX_ENTRIES do
    entries[#entries] = nil
  end
  return entries
end

local function contains_plain(haystack, needle)
  return string.find(haystack, needle, 1, true) ~= nil
end

-- Case-insensitive substring filter over entry names and paths, bounded to
-- `MAX_ENTRIES`. The query truncates to `MAX_NAME_CHARS`; an empty query
-- returns the first `MAX_ENTRIES` entries unchanged in order.
function M.filter_entries(entries, query)
  local bounded_query = scope.char_slice(string.lower(query or ""), M.MAX_NAME_CHARS)
  local out = {}
  for _, entry in ipairs(entries or {}) do
    if #out >= M.MAX_ENTRIES then
      break
    end
    if is_entry_table(entry) then
      if
        bounded_query == ""
        or contains_plain(string.lower(entry.name or ""), bounded_query)
        or contains_plain(string.lower(entry.path or ""), bounded_query)
      then
        out[#out + 1] = entry
      end
    end
  end
  return out
end

-- Sort entries by name (then path for stability), deduplicated and bounded
-- to `MAX_ENTRIES`. Pure.
function M.sorted_by_name(entries)
  local out = {}
  local seen = {}
  for _, entry in ipairs(entries or {}) do
    if is_entry_table(entry) and not seen[entry.path] then
      seen[entry.path] = true
      out[#out + 1] = entry
    end
  end
  table.sort(out, function(a, b)
    if a.name ~= b.name then
      return a.name < b.name
    end
    return a.path < b.path
  end)
  while #out > M.MAX_ENTRIES do
    out[#out] = nil
  end
  return out
end

-- Bound a selection to `MAX_SELECTION` entries (the per-subscription bound).
function M.bound_selection(entries)
  local out = {}
  for _, entry in ipairs(entries or {}) do
    if #out >= M.MAX_SELECTION then
      break
    end
    out[#out + 1] = entry
  end
  return out
end

return M
