-- Filesystem read/write scope for Bitty File Manager
-- (bitty-terminal.file-manager).
--
-- Pure functions with no host dependency. Mirrors the former bundled Rust
-- realization (`bitty-runtime/src/file_manager.rs`, removed by `bitty`
-- CTX-0399): paths are bounded to `4096` bytes with no null or control
-- characters, names truncate to `128` chars (the overlay text bound), and
-- the granted scopes are exactly `~/projects/**` for both `read` (listing /
-- preview) and optional `write` (user-confirmed rename/move/copy).
-- Real-path resolution plus symlink/device rejection happen per host policy;
-- any path outside the scope fails closed via `nil` / `false`.
--
-- No spawn, no I/O, no network. Filesystem access is host-mediated: this
-- module only validates, never opens.

local M = {}

M.FS_READ_PATTERN = "~/projects/**"
M.FS_WRITE_PATTERN = "~/projects/**"
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

function M.is_within_read_scope(path)
  if not M.is_valid_path(path) then
    return false
  end
  if path == "~/projects" or path == "~/projects/" then
    return true
  end
  if string.sub(path, 1, 11) ~= "~/projects/" then
    return false
  end
  if string.find(path, "..", 1, true) ~= nil then
    return false
  end
  return true
end

-- Alias for the read-scope check: `candidate` must satisfy
-- `is_within_read_scope`.
function M.is_fs_allowed(candidate)
  return M.is_within_read_scope(candidate)
end

-- Optional write scope for user-confirmed mutations. The baseline glob is
-- identical to read; the host grant decides whether mutation proceeds.
function M.is_fs_write_allowed(candidate)
  return M.is_within_read_scope(candidate)
end

-- Whether `path` fits the name/path presentation bounds.
function M.is_path_bounded(path)
  if type(path) ~= "string" then
    return false
  end
  if #path > M.MAX_PATH_BYTES then
    return false
  end
  local count = 0
  local index = 1
  while index <= #path do
    local byte = string.byte(path, index)
    if byte < 0x80 or byte >= 0xC0 then
      count = count + 1
    end
    index = index + 1
  end
  return count <= M.MAX_NAME_CHARS * 4
end

local function raw_name(path)
  if not M.is_within_read_scope(path) then
    return nil
  end
  local trimmed = string.gsub(path, "/+$", "")
  if trimmed == "~/projects" then
    return nil
  end
  local name = string.match(trimmed, "([^/]+)$")
  if name == nil or name == "" then
    return nil
  end
  if string.find(name, "..", 1, true) ~= nil then
    return nil
  end
  for index = 1, #name do
    local byte = string.byte(name, index)
    if byte == 0 or byte < 32 or byte == 127 then
      return nil
    end
  end
  return name
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

-- Last path segment bounded to `MAX_NAME_CHARS`, or `nil` for the scope
-- root, out-of-scope paths, and empty names.
function M.file_name(path)
  local raw = raw_name(path)
  if raw == nil then
    return nil
  end
  return char_slice(raw, M.MAX_NAME_CHARS)
end

-- Parent directory, or `nil` for the scope root and invalid paths.
function M.parent_dir(path)
  if not M.is_within_read_scope(path) then
    return nil
  end
  local trimmed = string.gsub(path, "/+$", "")
  if trimmed == "~/projects" then
    return nil
  end
  local parent = string.match(trimmed, "^(.*)/[^/]+$")
  if parent == nil or parent == "" then
    return nil
  end
  if parent ~= "~/projects" and not M.is_within_read_scope(parent) then
    return nil
  end
  return parent
end

-- Whether `path` presents as a directory (trailing `/` in scope, or the
-- scope root itself).
function M.is_directory_path(path)
  if type(path) ~= "string" then
    return false
  end
  if path == "~/projects" or path == "~/projects/" then
    return true
  end
  if string.sub(path, -1) == "/" then
    local trimmed = string.gsub(path, "/+$", "")
    return M.is_within_read_scope(trimmed)
  end
  return false
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

-- Validated read scope, or `nil` when outside the grant (fail-closed).
function M.validate_read(path)
  if M.is_within_read_scope(path) then
    return path
  end
  return nil
end

-- Validated write scope, or `nil` when outside the grant (fail-closed).
-- The host grant decides whether the mutation proceeds; this check alone
-- never authorizes a write.
function M.validate_write(path)
  if M.is_fs_write_allowed(path) then
    return path
  end
  return nil
end

M.char_count = char_count
M.char_slice = char_slice

return M
