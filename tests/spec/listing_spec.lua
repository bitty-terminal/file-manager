-- Behavior spec for the file-manager bounded listings.
--
-- Run from the package root: `lua5.4 tests/run.lua`.

local M = {}

function M.run(context)
  local tap = context.tap
  local listing = require("file-manager.listing")

  tap.equal(listing.MAX_ENTRIES, 128, "MAX_ENTRIES is 128")
  tap.equal(listing.MAX_NAME_CHARS, 128, "MAX_NAME_CHARS is 128")
  tap.equal(listing.MAX_PATH_BYTES, 4096, "MAX_PATH_BYTES is 4096")
  tap.equal(listing.MAX_SELECTION, 64, "MAX_SELECTION is 64")
  tap.equal(listing.PAYLOAD_MAX_BYTES, 8192, "PAYLOAD_MAX_BYTES is 8 KiB")

  local entry = listing.entry_from_path("~/projects/foo.txt", nil)
  tap.ok(entry ~= nil, "in-scope path builds an entry")
  tap.equal(entry.name, "foo.txt", "entry name is last segment")
  tap.equal(entry.path, "~/projects/foo.txt", "entry path preserved")
  tap.equal(entry.kind, "file", "plain path infers file")
  tap.ok(entry.truncated == false, "short name not truncated")

  local dir = listing.entry_from_path("~/projects/docs/", nil)
  tap.equal(dir.kind, "dir", "trailing slash infers dir")

  tap.equal(listing.entry_from_path("/etc/passwd", nil), nil, "outside scope builds nothing")
  tap.equal(listing.entry_from_path("~/projects", nil), nil, "scope root builds nothing")
  tap.equal(listing.entry_from_path("~/projects/../evil", nil), nil, "traversal builds nothing")

  local long_name = string.rep("b", listing.MAX_NAME_CHARS + 20)
  local truncated = listing.entry_from_path("~/projects/" .. long_name, nil)
  tap.ok(truncated ~= nil, "long name still builds an entry")
  tap.ok(truncated.truncated, "long name flags truncated")
  tap.equal(#truncated.name <= listing.MAX_NAME_CHARS + 4, true, "truncated name near bound")

  local listed = listing.list_entries({
    "~/projects/b",
    "~/projects/a",
    "~/projects/a",
    "/etc/passwd",
    "~/projects/c",
  })
  tap.equal(#listed, 3, "listing dedupes and drops outside scope")
  tap.equal(listed[1].path, "~/projects/a", "listing sorts by path")
  tap.equal(listed[2].path, "~/projects/b", "second sorted")
  tap.equal(listed[3].path, "~/projects/c", "third sorted")

  local many = {}
  for i = 1, 200 do
    many[#many + 1] = "~/projects/file" .. i .. ".txt"
  end
  tap.equal(#listing.list_entries(many), listing.MAX_ENTRIES, "listing bounded at 128")

  local filtered = listing.filter_entries(listed, "b")
  tap.equal(#filtered, 1, "filter matches name substring")
  tap.equal(filtered[1].path, "~/projects/b", "filter keeps match")
  tap.equal(#listing.filter_entries(listed, "B"), 1, "filter is case-insensitive")
  tap.equal(#listing.filter_entries(listed, ""), 3, "empty query returns all")
  tap.equal(#listing.filter_entries(listed, "projects"), 3, "filter matches path substring")

  local long_query = string.rep("a", listing.MAX_NAME_CHARS + 10)
  tap.equal(#listing.filter_entries(listed, long_query), 0, "overlong query truncates and matches nothing")

  local by_name = listing.sorted_by_name({
    { name = "b", path = "~/projects/b", kind = "file", truncated = false },
    { name = "a", path = "~/projects/a", kind = "file", truncated = false },
    { name = "a", path = "~/projects/a", kind = "file", truncated = false },
  })
  tap.equal(#by_name, 2, "sorted_by_name dedupes")
  tap.equal(by_name[1].name, "a", "sorted_by_name sorts by name")

  local many_entries = listing.list_entries(many)
  tap.equal(#listing.bound_selection(many_entries), listing.MAX_SELECTION, "selection bounded at 64")
end

return M
