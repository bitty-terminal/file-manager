-- Filesystem scope for Bitty File Manager (bitty-terminal.file-manager).
--
-- Pure functions with no host dependency. Paths are bounded to
-- `MAX_PATH_BYTES` (4096) with no null or control characters; names truncate
-- to `MAX_NAME_CHARS` (128, the overlay text bound).
--
-- M-FM-04: the former hardcoded `~/projects/**` grant prefix is gone. Scope
-- validation is root-parameterized and segment-wise, mirroring the
-- `bitty-terminal.git-panel` scope module: a candidate is admitted only when
-- it equals or nests under a caller-supplied root, so arbitrary roots work
-- (not just one fixed prefix), and every path fails closed when no root is
-- available. `..` is rejected only as a whole `/`-segment, so names that
-- merely contain two dots (`a..b`, `backup..tar.gz`) stay admitted while
-- `x/../y` traversal stays denied.
--
-- No spawn, no I/O, no network. Filesystem access is host-mediated: this
-- module only validates, never opens.

local M = {}

M.MAX_PATH_BYTES = 4096
M.MAX_NAME_CHARS = 128

function M.is_valid_path(path)
  if type(path) ~= "string" then
    return false
  end
  if #path == 0 or #path > M.MAX_PATH_BYTES then
    return false
  end
  for index = 1, #path do
    local byte = string.byte(path, index)
    if byte == 0 or byte < 32 or byte == 127 then
      return false
    end
  end
  return true
end

-- Strip trailing `/` runs; a path that is all slashes normalizes to `/`.
-- Central normalization shared by root detection, name extraction, and
-- directory presentation (R29), so those checks cannot drift.
function M.trim_trailing_slash(path)
  if type(path) ~= "string" then
    return path
  end
  local trimmed = string.gsub(path, "/+$", "")
  if trimmed == "" then
    return "/"
  end
  return trimmed
end

-- True for host-absolute paths (`/...`, `~/...`). Everything else is
-- root-relative and resolves against the caller-supplied root.
function M.is_absolute_path(path)
  if type(path) ~= "string" or path == "" then
    return false
  end
  local first = string.sub(path, 1, 1)
  return first == "/" or first == "~"
end

-- Root without trailing slashes, or `nil` fail-closed when invalid or
-- carrying a `..` segment.
function M.normalize_root(root)
  if not M.is_valid_path(root) then
    return nil
  end
  local base = M.trim_trailing_slash(root)
  for segment in string.gmatch(base, "[^/]+") do
    if segment == ".." then
      return nil
    end
  end
  return base
end

-- True when `candidate` equals `root` or nests strictly under it. The
-- boundary is segment-wise (`root .. "/"`), so a sibling such as `<root>2/x`
-- never prefix-matches, and any `..` segment fails closed.
function M.is_within_root(root, candidate)
  if not M.is_valid_path(candidate) then
    return false
  end
  local base = M.normalize_root(root)
  if base == nil then
    return false
  end
  if candidate == base then
    return true
  end
  if string.sub(candidate, 1, #base) ~= base then
    return false
  end
  if string.sub(candidate, #base + 1, #base + 1) ~= "/" then
    return false
  end
  for segment in string.gmatch(candidate, "[^/]+") do
    if segment == ".." then
      return false
    end
  end
  return true
end

-- True when `candidate` is the root itself (trailing slashes ignored).
function M.is_root(root, candidate)
  if not M.is_valid_path(candidate) then
    return false
  end
  local base = M.normalize_root(root)
  if base == nil then
    return false
  end
  return M.trim_trailing_slash(candidate) == base
end

-- Join root-relative `rel` onto `root`. Returns the joined path, or `nil`
-- fail-closed when either side is invalid, `rel` is absolute, or `..` would
-- escape `root` (`.` segments normalize away). A `rel` resolving to the root
-- itself also yields `nil`: a listing entry must name a path under the root.
function M.join_root(root, rel)
  if not M.is_valid_path(rel) then
    return nil
  end
  if M.is_absolute_path(rel) then
    return nil
  end
  local base = M.normalize_root(root)
  if base == nil then
    return nil
  end
  local parts = {}
  for segment in string.gmatch(rel, "[^/]+") do
    if segment == "." then
      -- normalize away
    elseif segment == ".." then
      if #parts == 0 then
        return nil
      end
      parts[#parts] = nil
    else
      parts[#parts + 1] = segment
    end
  end
  if #parts == 0 then
    return nil
  end
  local joined = base .. "/" .. table.concat(parts, "/")
  if not M.is_valid_path(joined) then
    return nil
  end
  return joined
end

-- Resolve caller-supplied `path` against `root`: an absolute path is
-- admitted only when already inside `root`; a relative path is joined onto
-- `root`. Returns the host-absolute candidate, or `nil` (fail-closed) when
-- no root is available or the path escapes it.
function M.resolve(root, path)
  if not M.is_valid_path(path) then
    return nil
  end
  if M.is_absolute_path(path) then
    if M.is_within_root(root, path) then
      return path
    end
    return nil
  end
  return M.join_root(root, path)
end

local function char_count(text)
  if utf8 ~= nil and utf8.len ~= nil then
    local count = utf8.len(text)
    if type(count) == "number" then
      return count
    end
  end
  local count = 0
  local index = 1
  while index <= #text do
    local byte = string.byte(text, index)
    if byte < 0x80 or byte >= 0xC0 then
      count = count + 1
    end
    index = index + 1
  end
  return count
end

local function char_slice(text, max)
  if max <= 0 then
    return ""
  end
  if char_count(text) <= max then
    return text
  end
  if utf8 ~= nil and utf8.offset ~= nil then
    local offset = utf8.offset(text, max + 1)
    if offset ~= nil then
      return string.sub(text, 1, offset - 1)
    end
  end
  local count = 0
  local index = 1
  while index <= #text do
    local byte = string.byte(text, index)
    if byte < 0x80 or byte >= 0xC0 then
      count = count + 1
      if count > max then
        return string.sub(text, 1, index - 1)
      end
    end
    index = index + 1
  end
  return text
end

-- Unbounded last path segment, or `nil` for invalid paths and path-less
-- roots (`/`, `~`). Root-relative: callers compare against a root.
function M.raw_file_name(path)
  if not M.is_valid_path(path) then
    return nil
  end
  local trimmed = M.trim_trailing_slash(path)
  if trimmed == "/" then
    return nil
  end
  local name = string.match(trimmed, "([^/]+)$")
  if name == nil or name == "" then
    return nil
  end
  return name
end

-- Last path segment bounded to `MAX_NAME_CHARS`, or `nil` for invalid paths
-- and path-less roots.
function M.file_name(path)
  local raw = M.raw_file_name(path)
  if raw == nil then
    return nil
  end
  return char_slice(raw, M.MAX_NAME_CHARS)
end

-- Parent directory within `root`, or `nil` for the root itself, invalid
-- paths, and parents that leave the root.
function M.parent_dir(root, path)
  if not M.is_within_root(root, path) then
    return nil
  end
  local base = M.normalize_root(root)
  local trimmed = M.trim_trailing_slash(path)
  if trimmed == base then
    return nil
  end
  local parent = string.match(trimmed, "^(.*)/[^/]+$")
  if parent == nil or parent == "" then
    return nil
  end
  if not M.is_within_root(root, parent) then
    return nil
  end
  return parent
end

-- Whether `path` (absolute or root-relative) presents as a directory: a
-- trailing `/` inside `root`, or the root itself.
function M.is_directory_path(root, path)
  local candidate = M.resolve(root, path)
  if candidate == nil then
    return false
  end
  if string.sub(path, -1) == "/" then
    return true
  end
  return M.is_root(root, candidate)
end

-- Truncate display text to the file-name bound at a code-point boundary.
function M.truncate_name(text)
  return char_slice(text or "", M.MAX_NAME_CHARS)
end

-- Whether display text fits the file-name bound.
function M.is_name_bounded(text)
  if type(text) ~= "string" then
    return false
  end
  return char_count(text) <= M.MAX_NAME_CHARS
end

-- Validated read scope, or `nil` when outside the root (fail-closed).
function M.validate_read(root, path)
  if M.is_within_root(root, path) then
    return path
  end
  return nil
end

-- Validated write scope, or `nil` when outside the root (fail-closed). The
-- host grant decides whether the mutation proceeds; this check alone never
-- authorizes a write.
function M.validate_write(root, path)
  return M.validate_read(root, path)
end

M.char_count = char_count
M.char_slice = char_slice

return M
