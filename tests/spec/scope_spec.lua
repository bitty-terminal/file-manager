-- Behavior spec for the file-manager read/write scope.
--
-- Run from the package root: `lua5.4 tests/run.lua`.

local M = {}

function M.run(context)
  local tap = context.tap
  local scope = require("file-manager.scope")

  tap.equal(scope.FS_READ_PATTERN, "~/projects/**", "read pattern pins ~/projects/**")
  tap.equal(scope.FS_WRITE_PATTERN, "~/projects/**", "write pattern pins ~/projects/**")
  tap.equal(scope.MAX_PATH_BYTES, 4096, "path bound is 4096")
  tap.equal(scope.MAX_NAME_CHARS, 128, "name bound is 128")

  tap.ok(scope.is_valid_path("~/projects/foo"), "valid path")
  tap.ok(not scope.is_valid_path(""), "empty path invalid")
  tap.ok(not scope.is_valid_path("~/projects/\0evil"), "null byte invalid")
  tap.ok(not scope.is_valid_path("~/projects/foo\7"), "control char invalid")
  local long = "~/projects/" .. string.rep("a", 5000)
  tap.ok(not scope.is_valid_path(long), "overlong path invalid")

  tap.ok(scope.is_within_read_scope("~/projects"), "scope root itself")
  tap.ok(scope.is_within_read_scope("~/projects/"), "scope root with slash")
  tap.ok(scope.is_within_read_scope("~/projects/foo"), "child path")
  tap.ok(scope.is_within_read_scope("~/projects/foo/bar"), "nested path")
  tap.ok(not scope.is_within_read_scope("~/Documents/foo"), "outside root denied")
  tap.ok(not scope.is_within_read_scope("/home/user/projects/foo"), "absolute denied")
  tap.ok(not scope.is_within_read_scope("~/projects/../etc/passwd"), "traversal denied")
  tap.ok(not scope.is_within_read_scope("~/projects/foo/../bar"), "inner traversal denied")
  tap.ok(not scope.is_within_read_scope(""), "empty denied")
  tap.ok(not scope.is_within_read_scope("~/projects/\0evil"), "null denied")

  tap.ok(scope.is_fs_allowed("~/projects/foo"), "fs allows child")
  tap.ok(not scope.is_fs_allowed("/etc/passwd"), "fs denies absolute")
  tap.ok(not scope.is_fs_allowed("~/projects/../secret"), "fs denies traversal")

  tap.ok(scope.is_fs_write_allowed("~/projects/foo/bar"), "write allows child")
  tap.ok(not scope.is_fs_write_allowed("/tmp/evil"), "write denies outside")
  tap.ok(not scope.is_fs_write_allowed("~/projects/../evil"), "write denies traversal")

  tap.ok(scope.validate_read("~/projects/foo") ~= nil, "validate_read admits child")
  tap.ok(scope.validate_read("/etc/passwd") == nil, "validate_read denies outside")
  tap.ok(scope.validate_read("~/projects/../evil") == nil, "validate_read denies traversal")
  tap.ok(scope.validate_write("~/projects/foo") ~= nil, "validate_write admits child")
  tap.ok(scope.validate_write("/tmp/evil") == nil, "validate_write denies outside")

  tap.equal(scope.file_name("~/projects/foo"), "foo", "file name is last segment")
  tap.equal(scope.file_name("~/projects/foo/bar"), "bar", "nested name")
  tap.equal(scope.file_name("~/projects"), nil, "scope root has no name")
  tap.equal(scope.file_name("~/projects/"), nil, "scope root slash has no name")
  tap.equal(scope.file_name("/etc/passwd"), nil, "outside scope has no name")
  local long_name = string.rep("a", scope.MAX_NAME_CHARS + 50)
  local bounded = scope.file_name("~/projects/" .. long_name)
  tap.equal(scope.char_count(bounded), scope.MAX_NAME_CHARS, "long name truncated to bound")

  tap.equal(scope.parent_dir("~/projects/foo/bar"), "~/projects/foo", "parent of nested")
  tap.equal(scope.parent_dir("~/projects/foo"), "~/projects", "parent of child is root")
  tap.equal(scope.parent_dir("~/projects"), nil, "root has no parent")
  tap.equal(scope.parent_dir("/etc/passwd"), nil, "outside scope has no parent")

  tap.ok(scope.is_directory_path("~/projects"), "root is directory")
  tap.ok(scope.is_directory_path("~/projects/"), "root slash is directory")
  tap.ok(scope.is_directory_path("~/projects/foo/"), "trailing slash is directory")
  tap.ok(not scope.is_directory_path("~/projects/foo"), "plain file is not directory")

  tap.ok(scope.is_name_bounded("hello"), "short name bounded")
  tap.ok(not scope.is_name_bounded(long_name), "long name unbounded")
  tap.equal(scope.char_count(scope.truncate_name(long_name)), scope.MAX_NAME_CHARS, "truncate pins bound")
end

return M
