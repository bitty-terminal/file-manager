-- Behavior spec for the file-manager root-parameterized scope.
--
-- Run from the package root: `lua5.4 tests/run.lua`.

local M = {}

function M.run(context)
  local tap = context.tap
  local scope = require("file-manager.scope")

  tap.equal(scope.MAX_PATH_BYTES, 4096, "path bound is 4096")
  tap.equal(scope.MAX_NAME_CHARS, 128, "name bound is 128")

  -- R29 / M-FM-04: the dead hardcoded-prefix helpers are gone.
  tap.equal(scope.is_path_bounded, nil, "dead is_path_bounded removed")
  tap.equal(scope.FS_READ_PATTERN, nil, "hardcoded read prefix removed")
  tap.equal(scope.FS_WRITE_PATTERN, nil, "hardcoded write prefix removed")

  tap.ok(scope.is_valid_path("/srv/git/repo/foo"), "valid path")
  tap.ok(not scope.is_valid_path(""), "empty path invalid")
  tap.ok(not scope.is_valid_path("/srv/git/repo/\0evil"), "null byte invalid")
  tap.ok(not scope.is_valid_path("/srv/git/repo/foo\7"), "control char invalid")
  tap.ok(not scope.is_valid_path("/srv/git/repo/" .. string.rep("a", 5000)), "overlong path invalid")

  tap.equal(scope.trim_trailing_slash("/srv/git/repo/"), "/srv/git/repo", "trailing slash trimmed")
  tap.equal(scope.trim_trailing_slash("/srv/git/repo"), "/srv/git/repo", "no trailing slash unchanged")
  tap.equal(scope.trim_trailing_slash("/"), "/", "all-slash path stays /")

  tap.ok(scope.is_absolute_path("/srv/git/repo"), "slash path absolute")
  tap.ok(scope.is_absolute_path("~/projects/foo"), "tilde path absolute")
  tap.ok(not scope.is_absolute_path("src/lib.rs"), "relative not absolute")
  tap.ok(not scope.is_absolute_path(""), "empty not absolute")

  -- M-FM-04: containment is segment-wise against an arbitrary root.
  tap.ok(scope.is_within_root("/srv/git/repo", "/srv/git/repo"), "root itself within")
  tap.ok(scope.is_within_root("/srv/git/repo", "/srv/git/repo/src/lib.rs"), "arbitrary root child within")
  tap.ok(scope.is_within_root("~/projects/foo", "~/projects/foo/src/lib.rs"), "tilde root child within")
  tap.ok(not scope.is_within_root("/srv/git/repo", "/srv/git/repo2/x"), "sibling prefix rejected")
  tap.ok(not scope.is_within_root("/srv/git/repo", "/srv/git/repo/../evil"), "dotdot escape rejected")
  tap.ok(not scope.is_within_root("/srv/git/repo", "/etc/passwd"), "outside rejected")
  tap.ok(not scope.is_within_root(nil, "/srv/git/repo/x"), "missing root rejected")

  -- M-FM-03: only whole `..` segments deny traversal.
  tap.ok(scope.is_within_root("/srv/git/repo", "/srv/git/repo/a..b"), "a..b admitted")
  tap.ok(scope.is_within_root("/srv/git/repo", "/srv/git/repo/backup..tar.gz"), "backup..tar.gz admitted")
  tap.ok(not scope.is_within_root("/srv/git/repo", "/srv/git/repo/x/../y"), "x/../y rejected")

  tap.equal(scope.join_root("/srv/git/repo", "src/lib.rs"), "/srv/git/repo/src/lib.rs", "relative joins root")
  tap.equal(scope.join_root("~/projects/foo/", "README.md"), "~/projects/foo/README.md", "trailing slash root")
  tap.equal(scope.join_root("/srv/git/repo", "./src/lib.rs"), "/srv/git/repo/src/lib.rs", "dot segment normalizes")
  tap.equal(scope.join_root("/srv/git/repo", "a/../b.txt"), "/srv/git/repo/b.txt", "inner dotdot normalizes")
  tap.equal(scope.join_root("/srv/git/repo", "../evil"), nil, "escaping dotdot rejected")
  tap.equal(scope.join_root("/srv/git/repo", "/etc/passwd"), nil, "absolute rel rejected")
  tap.equal(scope.join_root("/srv/git/repo", "."), nil, "bare dot rejected")
  tap.equal(scope.join_root("../evil", "a"), nil, "traversal root rejected")

  -- resolve: absolute must already be inside; relative is joined.
  tap.equal(scope.resolve("/srv/git/repo", "/srv/git/repo/a.txt"), "/srv/git/repo/a.txt", "absolute inside admitted")
  tap.equal(scope.resolve("/srv/git/repo", "/etc/passwd"), nil, "absolute outside denied")
  tap.equal(scope.resolve("/srv/git/repo", "sub/a.txt"), "/srv/git/repo/sub/a.txt", "relative joined")
  tap.equal(scope.resolve("/srv/git/repo", "x/../y"), "/srv/git/repo/y", "inner dotdot normalizes on resolve")
  tap.equal(scope.resolve("/srv/git/repo", "../y"), nil, "escaping relative denied")
  tap.equal(scope.resolve(nil, "a.txt"), nil, "no root fails closed")

  tap.ok(scope.is_root("/srv/git/repo", "/srv/git/repo"), "root matched")
  tap.ok(scope.is_root("/srv/git/repo", "/srv/git/repo/"), "root with slash matched")
  tap.ok(not scope.is_root("/srv/git/repo", "/srv/git/repo/a"), "child not root")

  tap.ok(scope.validate_read("/srv/git/repo", "/srv/git/repo/a") ~= nil, "validate_read admits child")
  tap.ok(scope.validate_read("/srv/git/repo", "/etc/passwd") == nil, "validate_read denies outside")
  tap.ok(scope.validate_write("/srv/git/repo", "/srv/git/repo/a") ~= nil, "validate_write admits child")
  tap.ok(scope.validate_write(nil, "/srv/git/repo/a") == nil, "validate_write denies without root")

  tap.equal(scope.file_name("/srv/git/repo/foo"), "foo", "file name is last segment")
  tap.equal(scope.file_name("/srv/git/repo/foo/bar"), "bar", "nested name")
  tap.equal(scope.file_name("/srv/git/repo/"), "repo", "trailing slash root has a name")
  tap.equal(scope.file_name("/"), nil, "filesystem root has no name")
  tap.equal(scope.raw_file_name("/srv/git/repo/foo"), "foo", "raw name exact")
  local long_name = string.rep("a", scope.MAX_NAME_CHARS + 50)
  local bounded = scope.file_name("/srv/git/repo/" .. long_name)
  tap.equal(scope.char_count(bounded), scope.MAX_NAME_CHARS, "long name truncated to bound")

  tap.equal(scope.parent_dir("/srv/git/repo", "/srv/git/repo/foo/bar"), "/srv/git/repo/foo", "parent of nested")
  tap.equal(scope.parent_dir("/srv/git/repo", "/srv/git/repo/foo"), "/srv/git/repo", "parent of child is root")
  tap.equal(scope.parent_dir("/srv/git/repo", "/srv/git/repo"), nil, "root has no parent")
  tap.equal(scope.parent_dir("/srv/git/repo", "/etc/passwd"), nil, "outside scope has no parent")

  tap.ok(scope.is_directory_path("/srv/git/repo", "/srv/git/repo"), "root is directory")
  tap.ok(scope.is_directory_path("/srv/git/repo", "/srv/git/repo/"), "root slash is directory")
  tap.ok(scope.is_directory_path("/srv/git/repo", "/srv/git/repo/foo/"), "trailing slash is directory")
  tap.ok(not scope.is_directory_path("/srv/git/repo", "/srv/git/repo/foo"), "plain file is not directory")

  tap.ok(scope.is_name_bounded("hello"), "short name bounded")
  tap.ok(not scope.is_name_bounded(long_name), "long name unbounded")
  tap.equal(scope.char_count(scope.truncate_name(long_name)), scope.MAX_NAME_CHARS, "truncate pins bound")
end

return M
