-- Behavior spec for the host-mediated directory reads.
--
-- Run from the package root: `lua5.4 tests/run.lua`.

local M = {}

local ROOT = "/srv/git/repo"

local function with_bitty(value, fn)
  local previous = _G.bitty
  _G.bitty = value
  local results = table.pack(pcall(fn))
  _G.bitty = previous
  if not results[1] then
    error(results[2], 0)
  end
  return table.unpack(results, 2, results.n)
end

function M.run(context)
  local tap = context.tap
  local directory = require("file-manager.directory")
  local listing = require("file-manager.listing")

  -- No host bridge at all: typed E_FS_UNAVAILABLE, never a crash.
  do
    local entries, err = with_bitty({}, function()
      return directory.list(ROOT)
    end)
    tap.equal(#entries, 0, "missing fs surface yields no entries")
    tap.equal(err.code, "E_FS_UNAVAILABLE", "missing fs surface is typed")
  end

  -- Host denial passes through as the typed code.
  do
    local entries, err = with_bitty({
      fs = {
        list = function()
          error({ class = "runtime", code = "E_FS_SCOPE_MISMATCH", message = "denied" }, 0)
        end,
      },
    }, function()
      return directory.list(ROOT)
    end)
    tap.equal(#entries, 0, "denied listing yields no entries")
    tap.equal(err.code, "E_FS_SCOPE_MISMATCH", "denial code passes through")
    tap.equal(err.class, "runtime", "denial class passes through")
  end

  -- Malformed host result fails closed.
  do
    local entries, err = with_bitty({
      fs = { list = function() return "nope" end },
    }, function()
      return directory.list(ROOT)
    end)
    tap.equal(#entries, 0, "non-table result yields no entries")
    tap.equal(err.code, "E_FS_RESULT_INVALID", "non-table result is typed")
  end

  -- Normalization: full paths and bare names both resolve, directories sort
  -- first, duplicates and out-of-scope entries drop, and the host bound is
  -- forwarded.
  do
    local call = nil
    local entries = with_bitty({
      fs = {
        list = function(prefix, max_entries)
          call = { prefix = prefix, max_entries = max_entries }
          return {
            { name = ROOT .. "/b.txt", kind = "file" },
            { name = "a.txt", kind = "file" },
            { name = "docs", kind = "dir" },
            { name = ROOT .. "/a.txt", kind = "file" },
            { name = "/etc/passwd", kind = "file" },
            { name = "", kind = "file" },
            "not-a-table",
          }
        end,
      },
    }, function()
      local result, err = directory.list(ROOT)
      tap.equal(err, nil, "successful listing has no error")
      return result
    end)
    tap.equal(call.prefix, ROOT, "host sees the scope root")
    tap.equal(call.max_entries, listing.MAX_ENTRIES, "host sees the entry bound")
    tap.equal(#entries, 3, "in-scope entries deduplicate")
    tap.equal(entries[1].name, "docs", "directory sorts first")
    tap.equal(entries[2].name, "a.txt", "files sort by name")
    tap.equal(entries[3].name, "b.txt", "second file sorted")
  end

  -- Long names truncate at the listing name bound.
  do
    local long = string.rep("z", listing.MAX_NAME_CHARS + 20)
    local entries = with_bitty({
      fs = { list = function() return { { name = long, kind = "file" } } end },
    }, function()
      return directory.list(ROOT)
    end)
    tap.equal(#entries, 1, "long name still lists")
    tap.equal(#entries[1].name, listing.MAX_NAME_CHARS, "name bounded")
    tap.equal(entries[1].truncated, true, "long name flags truncation")
  end

  -- The accumulated payload bound bites before the entry count bound.
  do
    local raw = {}
    for index = 1, 100 do
      raw[#raw + 1] = {
        name = string.rep("p", 300) .. index,
        kind = "file",
      }
    end
    local entries = with_bitty({
      fs = { list = function() return raw end },
    }, function()
      return directory.list(ROOT)
    end)
    tap.ok(#entries > 0 and #entries < listing.MAX_ENTRIES, "payload bound bites")
    local bytes = 0
    for _, entry in ipairs(entries) do
      bytes = bytes + #entry.path + #entry.name
    end
    tap.le(bytes, listing.PAYLOAD_MAX_BYTES, "payload stays bounded")
  end

  -- Empty directories are success, not an error.
  do
    local entries, err = with_bitty({
      fs = { list = function() return {} end },
    }, function()
      return directory.list(ROOT)
    end)
    tap.equal(#entries, 0, "empty directory has no entries")
    tap.equal(err, nil, "empty directory is not an error")
  end

  -- Missing root fails closed before the host call.
  do
    local called = false
    local entries, err = with_bitty({
      fs = { list = function() called = true end },
    }, function()
      return directory.list("")
    end)
    tap.equal(#entries, 0, "missing root yields no entries")
    tap.equal(err.code, "E_SCOPE_UNAVAILABLE", "missing root is typed")
    tap.equal(called, false, "missing root never reaches the host")
  end
end

return M
