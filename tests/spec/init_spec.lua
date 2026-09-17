-- Entry-point behavior tests for `file-manager.init` against the mock host.

local MockHost = require("support.mock_host")

local PLUGIN_ID = "bitty-terminal.file-manager"
local ROOT = "/srv/git/repo"

local COMMANDS = {
  PLUGIN_ID .. ":open",
  PLUGIN_ID .. ":preview",
  PLUGIN_ID .. ":rename",
}

local EVENTS = {
  "terminal.cwd-changed",
  "terminal.title-changed",
  "focus.changed",
}

-- H-FM-02: the manifest requests `terminal.semantic-read` only; the grants
-- mirror that least-privilege set.
local GRANTS = {
  "terminal.semantic-read",
}

local DEFAULT_SNAPSHOT = {
  title = "file-manager",
  zones = { { metadata = { cwd = ROOT } } },
}

local function activate(host)
  _G.bitty = host.bitty
  package.loaded["file-manager.init"] = nil
  package.loaded["file-manager.scope"] = nil
  package.loaded["file-manager.listing"] = nil
  package.loaded["file-manager.scene"] = nil
  return require("file-manager.init")
end

local function full_host(overrides)
  overrides = overrides or {}
  local options = {
    plugin_id = PLUGIN_ID,
    grants = overrides.grants or GRANTS,
    commands = COMMANDS,
    events = overrides.events or EVENTS,
    settings = overrides.settings,
    snapshot = DEFAULT_SNAPSHOT,
  }
  if overrides.snapshot ~= nil then
    options.snapshot = overrides.snapshot
  end
  if overrides.no_snapshot then
    options.snapshot = nil
  end
  return MockHost.new(options)
end

local function run(context)
  local tap = context.tap

  -- Activation registers the three manifest commands and the three declared
  -- observation events.
  do
    local host = full_host()
    activate(host)
    for _, qualified in ipairs(COMMANDS) do
      tap.ok(host.commands[qualified] ~= nil, "registered " .. qualified)
    end
    tap.equal(#host.subscriptions, 3, "three subscriptions")
    for _, kind in ipairs(EVENTS) do
      local found = false
      for _, subscription in ipairs(host.subscriptions) do
        if subscription.kind == kind then
          found = true
        end
      end
      tap.ok(found, "subscribed " .. kind)
    end
  end

  -- Undeclared event fails closed at activation.
  do
    local host = full_host({ events = {} })
    local ok, err = pcall(activate, host)
    tap.ok(not ok, "undeclared event fails activation")
    tap.equal(type(err) == "table" and err.code or nil, "E_EVENT_UNDECLARED", "undeclared event code")
  end

  -- The open command serves bounded, scope-checked entries from explicit args
  -- resolved against the caller-supplied root.
  do
    local host = full_host()
    activate(host)
    local entries = host:run("open", {
      root = ROOT,
      paths = { ROOT .. "/b", ROOT .. "/a", "/etc/passwd" },
    })
    tap.equal(#entries, 2, "two in-scope entries")
    tap.equal(entries[1].path, ROOT .. "/a", "entries sorted")
  end

  -- The open command falls back to settings-provided entries and root
  -- (palette-style adapter: the v1 surface exposes no fs enumeration, so the
  -- host or user supplies the bounded candidate list).
  do
    local host = full_host({
      no_snapshot = true,
      settings = { root = ROOT, entries = { "alpha.txt", "beta.txt" } },
    })
    activate(host)
    local entries = host:run("open", {})
    tap.equal(#entries, 2, "settings entries served")
    tap.equal(entries[1].path, ROOT .. "/alpha.txt", "settings root resolves entries")
  end

  -- The cached snapshot cwd is the fallback root when the caller supplies
  -- none.
  do
    local host = full_host()
    activate(host)
    local entries = host:run("open", { paths = { "a.txt" } })
    tap.equal(#entries, 1, "snapshot cwd root resolves entries")
    tap.equal(entries[1].path, ROOT .. "/a.txt", "snapshot root path")
  end

  -- H-FM-01: no snapshot surface still opens/previews/renames when the caller
  -- supplies a root; a snapshot-denied path must not crash the operation.
  do
    local host = full_host({ no_snapshot = true })
    activate(host)
    local entries = host:run("open", { root = ROOT, paths = { "b", "a", "/etc/passwd" } })
    tap.equal(#entries, 2, "headless open works")
    tap.equal(entries[1].path, ROOT .. "/a", "headless listing resolves and sorts")
  end

  -- H-FM-01: a denied terminal.semantic-read must not fail commands that do
  -- not need the snapshot.
  do
    local host = full_host({ grants = {} })
    activate(host)
    local entries = host:run("open", { root = ROOT, paths = { ROOT .. "/a" } })
    tap.equal(#entries, 1, "open survives denied snapshot")
    local entry = host:run("preview", { root = ROOT, path = "a.txt" })
    tap.equal(entry.name, "a.txt", "preview survives denied snapshot")
    local pair = host:run("rename", { root = ROOT, src = "a.txt", dst = "b.txt" })
    tap.equal(pair.dst, ROOT .. "/b.txt", "rename survives denied snapshot")
  end

  -- M-FM-04: without any root there is no boundary, so open serves nothing
  -- and preview/rename fail closed.
  do
    local host = full_host({ no_snapshot = true })
    activate(host)
    local entries = host:run("open", { paths = { ROOT .. "/a" } })
    tap.equal(#entries, 0, "open without a root is empty")
    local ok, err = pcall(function()
      return host:run("preview", { path = "a.txt" })
    end)
    tap.ok(not ok, "preview without a root fails closed")
    tap.equal(type(err) == "table" and err.code or nil, "E_SCOPE_UNAVAILABLE", "preview no-root code")
    local ok2, err2 = pcall(function()
      return host:run("rename", { src = "a.txt", dst = "b.txt" })
    end)
    tap.ok(not ok2, "rename without a root fails closed")
    tap.equal(type(err2) == "table" and err2.code or nil, "E_SCOPE_UNAVAILABLE", "rename no-root code")
  end

  -- The preview command validates one in-scope path and resolves parent and
  -- directory presentation.
  do
    local host = full_host({ no_snapshot = true })
    activate(host)
    local entry = host:run("preview", { root = ROOT, path = "sub/foo.txt" })
    tap.equal(entry.name, "foo.txt", "preview names the file")
    tap.equal(entry.parent, ROOT .. "/sub", "preview resolves the parent")
    tap.equal(entry.is_dir, false, "plain file is not a directory")
    local listing = require("file-manager.listing")
    local fields = { "name", "path", "kind", "truncated", "parent", "is_dir" }
    local long_name = string.rep("é", listing.MAX_NAME_CHARS + 1)
    local cases = {
      { path = "docs/", name = "docs", parent = ROOT, is_dir = true },
      { path = "sub/docs///", name = "docs", parent = ROOT .. "/sub", is_dir = true },
      { path = "sub/foo.txt", name = "foo.txt", parent = ROOT .. "/sub", is_dir = false },
      { path = "docs", name = "docs", parent = ROOT, is_dir = false },
      {
        path = long_name .. "/",
        name = string.rep("é", listing.MAX_NAME_CHARS),
        parent = ROOT,
        is_dir = true,
        truncated = true,
      },
    }
    for _, case in ipairs(cases) do
      local relative = host:run("preview", { root = ROOT, path = case.path })
      local absolute = host:run("preview", { root = ROOT, path = ROOT .. "/" .. case.path })
      local expected = {
        name = case.name,
        path = ROOT .. "/" .. string.gsub(case.path, "/+$", ""),
        kind = case.is_dir and "dir" or "file",
        truncated = case.truncated or false,
        parent = case.parent,
        is_dir = case.is_dir,
      }
      for _, field in ipairs(fields) do
        tap.equal(relative[field], expected[field], "relative preview " .. case.path .. " " .. field)
        tap.equal(absolute[field], expected[field], "absolute preview " .. case.path .. " " .. field)
        tap.equal(relative[field], absolute[field], "equivalent preview " .. case.path .. " " .. field)
      end
    end
    for _, path in ipairs({ ROOT, ROOT .. "/", ".", "./", "../docs/", ROOT .. "/../docs/" }) do
      local ok, err = pcall(function()
        return host:run("preview", { root = ROOT, path = path })
      end)
      tap.ok(not ok, "preview rejects root or traversal " .. path)
      tap.equal(type(err) == "table" and err.code or nil, "E_FS_DENIED", "preview rejection code")
    end
  end

  -- Preview outside the root fails closed.
  do
    local host = full_host()
    activate(host)
    local ok, err = pcall(function()
      return host:run("preview", { root = ROOT, path = "/etc/passwd" })
    end)
    tap.ok(not ok, "out-of-scope preview fails")
    tap.equal(type(err) == "table" and err.code or nil, "E_FS_DENIED", "preview denial code")
  end

  -- The rename command resolves one in-scope pair (host mediates the write).
  do
    local host = full_host()
    activate(host)
    local pair = host:run("rename", { root = ROOT, src = "old.txt", dst = "sub/new.txt" })
    tap.equal(pair.src, ROOT .. "/old.txt", "rename resolves src")
    tap.equal(pair.dst, ROOT .. "/sub/new.txt", "rename resolves dst")
    tap.equal(pair.name, "new.txt", "rename names the dst")
  end

  -- L-FM-02: identical src/dst (raw or after resolution) is rejected.
  do
    local host = full_host()
    activate(host)
    local ok, err = pcall(function()
      return host:run("rename", { root = ROOT, src = "a.txt", dst = "a.txt" })
    end)
    tap.ok(not ok, "rename rejects raw src==dst")
    tap.equal(type(err) == "table" and err.code or nil, "E_FS_DENIED", "raw src==dst code")
    local ok2, err2 = pcall(function()
      return host:run("rename", { root = ROOT, src = "x/../a.txt", dst = "a.txt" })
    end)
    tap.ok(not ok2, "rename rejects resolved src==dst")
    tap.equal(type(err2) == "table" and err2.code or nil, "E_FS_DENIED", "resolved src==dst code")
  end

  -- L-FM-02: renaming the scope root is refused.
  do
    local host = full_host()
    activate(host)
    local ok, err = pcall(function()
      return host:run("rename", { root = ROOT, src = ROOT, dst = "moved" })
    end)
    tap.ok(not ok, "rename refuses the root")
    tap.equal(type(err) == "table" and err.code or nil, "E_FS_DENIED", "root rename code")
  end

  -- Rename outside the root fails closed.
  do
    local host = full_host()
    activate(host)
    local ok, err = pcall(function()
      return host:run("rename", { root = ROOT, src = "ok.txt", dst = "/tmp/evil.txt" })
    end)
    tap.ok(not ok, "out-of-scope rename fails")
    tap.equal(type(err) == "table" and err.code or nil, "E_FS_DENIED", "rename denial code")
  end

  -- Observation events refresh the cached cwd without touching the fs.
  do
    local host = full_host()
    local plugin = activate(host)
    host.snapshot_value = { title = "moved", zones = { { metadata = { cwd = ROOT .. "/other" } } } }
    host:publish("terminal.cwd-changed", {})
    tap.equal(plugin.cached_cwd(), ROOT .. "/other", "cwd cache refreshed")
  end

  -- The plugin never spawns: no process surface exists on the mock host.
  do
    local host = full_host()
    activate(host)
    tap.equal(host.bitty.process, nil, "no spawn surface on the host")
  end
end

return { run = run }
