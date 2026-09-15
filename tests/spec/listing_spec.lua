-- Behavior spec for the file-manager bounded listings.
--
-- Run from the package root: `lua5.4 tests/run.lua`.

local M = {}

function M.run(context)
  local tap = context.tap
  local listing = require("file-manager.listing")

  local ROOT = "/srv/git/repo"

  tap.equal(listing.MAX_ENTRIES, 128, "MAX_ENTRIES is 128")
  tap.equal(listing.MAX_NAME_CHARS, 128, "MAX_NAME_CHARS is 128")
  tap.equal(listing.MAX_PATH_BYTES, 4096, "MAX_PATH_BYTES is 4096")
  tap.equal(listing.MAX_SELECTION, 64, "MAX_SELECTION is 64")
  tap.equal(listing.PAYLOAD_MAX_BYTES, 8192, "PAYLOAD_MAX_BYTES is 8 KiB")

  -- M-FM-04: arbitrary root; absolute and relative candidates resolve.
  local entry = listing.entry_from_path(ROOT .. "/foo.txt", nil, { root = ROOT })
  tap.ok(entry ~= nil, "in-scope path builds an entry")
  tap.equal(entry.name, "foo.txt", "entry name is last segment")
  tap.equal(entry.path, ROOT .. "/foo.txt", "entry path preserved")
  tap.equal(entry.kind, "file", "plain path infers file")
  tap.ok(entry.truncated == false, "short name not truncated")

  local relative = listing.entry_from_path("sub/foo.txt", nil, { root = ROOT })
  tap.equal(relative.path, ROOT .. "/sub/foo.txt", "relative path resolves against root")

  local dir = listing.entry_from_path(ROOT .. "/docs/", nil, { root = ROOT })
  tap.equal(dir.kind, "dir", "trailing slash infers dir")

  tap.equal(listing.entry_from_path("/etc/passwd", nil, { root = ROOT }), nil, "outside scope builds nothing")
  tap.equal(listing.entry_from_path(ROOT, nil, { root = ROOT }), nil, "scope root builds nothing")
  tap.equal(listing.entry_from_path(ROOT .. "/../evil", nil, { root = ROOT }), nil, "traversal builds nothing")
  tap.equal(listing.entry_from_path("a..b", nil, { root = ROOT }).name, "a..b", "a..b name admitted")

  -- M-FM-04: fail closed when no root is available.
  tap.equal(listing.entry_from_path("foo.txt", nil, nil), nil, "no opts builds nothing")
  tap.equal(listing.entry_from_path("foo.txt", nil, {}), nil, "empty opts builds nothing")

  local long_name = string.rep("b", listing.MAX_NAME_CHARS + 20)
  local truncated = listing.entry_from_path(ROOT .. "/" .. long_name, nil, { root = ROOT })
  tap.ok(truncated ~= nil, "long name still builds an entry")
  tap.ok(truncated.truncated, "long name flags truncated")
  tap.equal(#truncated.name <= listing.MAX_NAME_CHARS + 4, true, "truncated name near bound")

  local listed = listing.list_entries({
    ROOT .. "/b",
    ROOT .. "/a",
    ROOT .. "/a",
    "/etc/passwd",
    ROOT .. "/c",
  }, { root = ROOT })
  tap.equal(#listed, 3, "listing dedupes and drops outside scope")
  tap.equal(listed[1].path, ROOT .. "/a", "listing sorts by path")
  tap.equal(listed[2].path, ROOT .. "/b", "second sorted")
  tap.equal(listed[3].path, ROOT .. "/c", "third sorted")

  -- R29: non-table input is empty, not a crash.
  tap.equal(#listing.list_entries("not-a-table", { root = ROOT }), 0, "string input yields empty")
  tap.equal(#listing.list_entries(nil, { root = ROOT }), 0, "nil input yields empty")
  tap.equal(#listing.list_entries(42, { root = ROOT }), 0, "number input yields empty")

  local many = {}
  for i = 1, 200 do
    many[#many + 1] = ROOT .. "/file" .. i .. ".txt"
  end
  tap.equal(#listing.list_entries(many, { root = ROOT }), listing.MAX_ENTRIES, "listing bounded at 128")

  -- R16: the payload byte bound bites before the entry count bound.
  local oversized = {}
  for i = 1, 100 do
    oversized[#oversized + 1] = ROOT .. "/" .. string.rep("a", 300) .. i
  end
  local bounded_bytes = listing.list_entries(oversized, { root = ROOT })
  local total_bytes = 0
  for _, item in ipairs(bounded_bytes) do
    total_bytes = total_bytes + #item.path + #item.name
  end
  tap.ok(#bounded_bytes > 0 and #bounded_bytes < 128, "byte bound bites before count bound")
  tap.ok(total_bytes <= listing.PAYLOAD_MAX_BYTES, "payload bytes stay within the bound")

  local filtered = listing.filter_entries(listed, "b")
  tap.equal(#filtered, 1, "filter matches name substring")
  tap.equal(filtered[1].path, ROOT .. "/b", "filter keeps match")
  tap.equal(#listing.filter_entries(listed, "B"), 1, "filter is case-insensitive")
  tap.equal(#listing.filter_entries(listed, ""), 3, "empty query returns all")
  tap.equal(#listing.filter_entries(listed, "repo"), 3, "filter matches path substring")
  tap.equal(#listing.filter_entries("not-a-table", "b"), 0, "filter guards non-table input")

  local long_query = string.rep("a", listing.MAX_NAME_CHARS + 10)
  tap.equal(#listing.filter_entries(listed, long_query), 0, "overlong query truncates and matches nothing")

  local by_name = listing.sorted_by_name({
    { name = "b", path = ROOT .. "/b", kind = "file", truncated = false },
    { name = "a", path = ROOT .. "/a", kind = "file", truncated = false },
    { name = "a", path = ROOT .. "/a", kind = "file", truncated = false },
  })
  tap.equal(#by_name, 2, "sorted_by_name dedupes")
  tap.equal(by_name[1].name, "a", "sorted_by_name sorts by name")
  tap.equal(#listing.sorted_by_name("nope"), 0, "sorted_by_name guards non-table input")

  local many_entries = listing.list_entries(many, { root = ROOT })
  tap.equal(#listing.bound_selection(many_entries), listing.MAX_SELECTION, "selection bounded at 64")
  tap.equal(#listing.bound_selection(nil), 0, "bound_selection guards non-table input")
end

return M
