-- Bounded file listings for Bitty File Manager (bitty-terminal.file-manager).
--
-- Pure functions with no host dependency. At most `MAX_ENTRIES` (128)
-- entries per listing, names at `MAX_NAME_CHARS` (128), paths at
-- `MAX_PATH_BYTES` (4096), selection at `MAX_SELECTION` (64), and the total
-- listing payload at `PAYLOAD_MAX_BYTES` (8192) of accumulated `path` +
-- `name` bytes (R16). Listings sort deterministically, deduplicate by path,
-- and truncate; filters are case-insensitive substring matches bounded to
-- the listing cap.
--
-- M-FM-04: entries are resolved against a caller-supplied `{ root = ... }`
-- (arbitrary roots; no hardcoded prefix) and fail closed when no root is
-- available. Entries are plain `{ name, path, kind, truncated }` tables.
-- `kind` is one of `file`, `dir`, `symlink`, `other` (presentation only,
-- inferred from the trailing slash when not supplied).

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

local function root_from_opts(opts)
  if type(opts) == "table" and type(opts.root) == "string" and opts.root ~= "" then
    return opts.root
  end
  return nil
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

-- Build one bounded entry from `path` resolved against `opts.root`, or `nil`
-- for invalid/out-of-scope paths, the root itself, and a missing root
-- (fail-closed). Names truncate at a code-point boundary with the
-- `truncated` flag set.
function M.entry_from_path(path, kind, opts)
  local root = root_from_opts(opts)
  if type(path) ~= "string" or root == nil then
    return nil
  end
  if not scope.is_valid_path(path) then
    return nil
  end
  local candidate = scope.resolve(root, path)
  if candidate == nil or scope.is_root(root, candidate) then
    return nil
  end
  local raw = scope.raw_file_name(candidate)
  if raw == nil then
    return nil
  end
  local truncated = scope.char_count(raw) > M.MAX_NAME_CHARS
  return {
    name = scope.truncate_name(raw),
    path = candidate,
    kind = infer_kind(path, kind),
    truncated = truncated,
  }
end

-- Filter and bound a raw `paths` listing to `MAX_ENTRIES` entries, within
-- `PAYLOAD_MAX_BYTES` of accumulated path+name bytes, sorted by path and
-- deduplicated. Non-table input yields an empty listing (R29). Pure.
function M.list_entries(paths, opts)
  if type(paths) ~= "table" then
    return {}
  end
  local entries = {}
  local seen = {}
  local payload_bytes = 0
  for _, path in ipairs(paths) do
    local entry = M.entry_from_path(path, nil, opts)
    if entry ~= nil and not seen[entry.path] then
      seen[entry.path] = true
      local entry_bytes = #entry.path + #entry.name
      if payload_bytes + entry_bytes > M.PAYLOAD_MAX_BYTES then
        break
      end
      payload_bytes = payload_bytes + entry_bytes
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
-- returns the first `MAX_ENTRIES` entries unchanged in order. Non-table
-- input yields an empty listing.
function M.filter_entries(entries, query)
  if type(entries) ~= "table" then
    return {}
  end
  local bounded_query = scope.char_slice(string.lower(query or ""), M.MAX_NAME_CHARS)
  local out = {}
  for _, entry in ipairs(entries) do
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
-- to `MAX_ENTRIES`. Non-table input yields an empty listing. Pure.
function M.sorted_by_name(entries)
  if type(entries) ~= "table" then
    return {}
  end
  local out = {}
  local seen = {}
  for _, entry in ipairs(entries) do
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
  if type(entries) ~= "table" then
    return {}
  end
  local out = {}
  for _, entry in ipairs(entries) do
    if #out >= M.MAX_SELECTION then
      break
    end
    out[#out + 1] = entry
  end
  return out
end

return M
