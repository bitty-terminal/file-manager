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

-- Least-privilege grants mirroring the manifest: observation, the declarative
-- band block, and the read-only listing bridge.
local GRANTS = {
  "terminal.semantic-read",
  "ui.rich",
  "fs.read:**",
}

local DEFAULT_SNAPSHOT = {
  title = "file-manager",
  width = 80,
  zones = { { metadata = { cwd = ROOT } } },
}

-- `bitty.fs.list` entries carry a path or a bare name; the plugin normalizes
-- both against the scope root.
local DEFAULT_FS = {
  [ROOT] = {
    { name = "b.txt", kind = "file" },
    { name = "a.txt", kind = "file" },
    { name = "docs", kind = "dir" },
  },
}

local function activate(host)
  _G.bitty = host.bitty
  package.loaded["file-manager.init"] = nil
  package.loaded["file-manager.scope"] = nil
  package.loaded["file-manager.listing"] = nil
  package.loaded["file-manager.directory"] = nil
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
    settings_declared = overrides.settings_declared,
    snapshot = DEFAULT_SNAPSHOT,
    fs_entries = overrides.fs_entries,
    fs_error = overrides.fs_error,
  }
  if overrides.snapshot ~= nil then
    options.snapshot = overrides.snapshot
  end
  if overrides.no_snapshot then
    options.snapshot = nil
  end
  if overrides.fs_entries == nil and not overrides.no_fs then
    options.fs_entries = DEFAULT_FS
  end
  if overrides.no_fs then
    options.fs_entries = nil
  end
  return MockHost.new(options)
end

local function children(node)
  return type(node) == "table" and type(node.children) == "table" and node.children or {}
end

local function collect(node, predicate, out)
  out = out or {}
  if type(node) ~= "table" then
    return out
  end
  if predicate(node) then
    out[#out + 1] = node
  end
  for _, child in ipairs(children(node)) do
    collect(child, predicate, out)
  end
  return out
end

local function texts(component)
  local out = {}
  for _, node in ipairs(collect(component, function(value)
    return value.kind == "Text" and type(value.text) == "string"
  end)) do
    out[#out + 1] = node.text
  end
  return table.concat(out, "\n")
end

local function clicks(component)
  local out = {}
  for _, node in ipairs(collect(component, function(value)
    return type(value.on_click) == "table"
  end)) do
    out[#out + 1] = node.on_click
  end
  return out
end

local function first_text(component, needle)
  for _, value in ipairs(collect(component, function(node)
    return node.kind == "Text" and type(node.text) == "string"
  end)) do
    if string.find(value.text, needle, 1, true) then
      return value.text
    end
  end
  return nil
end

local function mounted(host)
  local mount = host.mounts[#host.mounts]
  return mount and mount.component or nil
end

local function run(context)
  local tap = context.tap

  -- Activation registers the three manifest commands and the three declared
  -- observation events, and mounts nothing until a command runs.
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
    tap.equal(#host.mounts, 0, "activation mounts nothing")
  end

  -- Undeclared event fails closed at activation.
  do
    local host = full_host({ events = {} })
    local ok, err = pcall(activate, host)
    tap.ok(not ok, "undeclared event fails activation")
    tap.equal(type(err) == "table" and err.code or nil, "E_EVENT_UNDECLARED", "undeclared event code")
  end

  -- The open command mounts a non-empty listing block on the bottom band and
  -- returns a boolean acknowledgement (no `{}` banner).
  do
    local host = full_host()
    local plugin = activate(host)
    local result = host:run("open", { root = ROOT })
    tap.equal(result, true, "open returns a boolean acknowledgement")
    tap.equal(#host.mounts, 1, "open mounts one block")
    tap.equal(host.mounts[1].slot, "bottom", "listing mounts on the bottom band")
    local component = mounted(host)
    tap.equal(type(component), "table", "mounted component is a table")
    tap.ok(type(component.kind) == "string", "mounted component has a node kind")
    tap.ok(#children(component) > 0, "mounted component is non-empty")
    local state = plugin.listing_state()
    tap.equal(#state.entries, 3, "three host entries normalized")
    tap.equal(state.entries[1].name, "docs", "directories sort first")
    tap.equal(state.entries[2].name, "a.txt", "files sort by name")
    tap.ok(state.handle ~= nil, "listing keeps the block handle")
  end

  -- A second open reuses the block through ui.update instead of mounting
  -- another block.
  do
    local host = full_host()
    activate(host)
    host:run("open", { root = ROOT })
    host:run("open", { root = ROOT, selected = 2 })
    tap.equal(#host.mounts, 1, "second open does not mount a new block")
    tap.equal(#host.updates, 1, "second open updates the existing block")
    tap.equal(host.updates[1].handle, host.mounts[1].handle, "update targets the mounted handle")
  end

  -- Explicit args still take precedence and resolve against the caller root.
  do
    local host = full_host()
    local plugin = activate(host)
    host:run("open", {
      root = ROOT,
      paths = { ROOT .. "/b", ROOT .. "/a", "/etc/passwd" },
    })
    local state = plugin.listing_state()
    tap.equal(#state.entries, 2, "two in-scope entries")
    tap.equal(state.entries[1].path, ROOT .. "/a", "entries sorted")
  end

  -- Settings-provided entries and root are a declared fallback when no host
  -- listing is requested.
  do
    local host = full_host({
      no_snapshot = true,
      settings = { root = ROOT, entries = { "alpha.txt", "beta.txt" } },
    })
    local plugin = activate(host)
    host:run("open", {})
    local state = plugin.listing_state()
    tap.equal(#state.entries, 2, "settings entries served")
    tap.equal(state.entries[1].path, ROOT .. "/alpha.txt", "settings root resolves entries")
  end

  -- The cached snapshot cwd is the fallback root when the caller supplies
  -- none, and the snapshot width bounds display names.
  do
    local host = full_host()
    local plugin = activate(host)
    host:run("open", {})
    local state = plugin.listing_state()
    tap.equal(state.root, ROOT, "snapshot cwd root")
    tap.equal(#state.entries, 3, "snapshot cwd lists")
  end

  -- H-FM-01: no snapshot surface still opens/previews/renames when the caller
  -- supplies a root; a snapshot-denied path must not crash the operation.
  do
    local host = full_host({ no_snapshot = true })
    local plugin = activate(host)
    host:run("open", { root = ROOT, paths = { "b", "a", "/etc/passwd" } })
    local state = plugin.listing_state()
    tap.equal(#state.entries, 2, "headless open works")
    tap.equal(state.entries[1].path, ROOT .. "/a", "headless listing resolves and sorts")
    local entry = host:run("preview", { root = ROOT, path = "a.txt" })
    tap.equal(entry.name, "a.txt", "preview survives denied snapshot")
    local pair = host:run("rename", { root = ROOT, src = "a.txt", dst = "b.txt" })
    tap.equal(pair.dst, ROOT .. "/b.txt", "rename survives denied snapshot")
  end

  -- H-FM-01: a denied terminal.semantic-read must not fail commands that do
  -- not need the snapshot.
  do
    local host = full_host({ grants = { "ui.rich", "fs.read:**" } })
    local plugin = activate(host)
    host:run("open", { root = ROOT, paths = { ROOT .. "/a" } })
    tap.equal(#plugin.listing_state().entries, 1, "open survives denied snapshot")
    local entry = host:run("preview", { root = ROOT, path = "a.txt" })
    tap.equal(entry.name, "a.txt", "preview survives denied snapshot")
    local pair = host:run("rename", { root = ROOT, src = "a.txt", dst = "b.txt" })
    tap.equal(pair.dst, ROOT .. "/b.txt", "rename survives denied snapshot")
  end

  -- M-FM-04: without any root there is no boundary, so open mounts a typed
  -- scope error and preview/rename fail closed.
  do
    local host = full_host({ no_snapshot = true })
    local plugin = activate(host)
    host:run("open", { paths = { ROOT .. "/a" } })
    local state = plugin.listing_state()
    tap.equal(#state.entries, 0, "open without a root is empty")
    tap.equal(state.error.code, "E_SCOPE_UNAVAILABLE", "open without a root is typed")
    tap.ok(first_text(mounted(host), "E_SCOPE_UNAVAILABLE") ~= nil, "typed scope error is mounted")
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

  -- Empty directories mount a non-empty explanatory block.
  do
    local host = full_host({ fs_entries = { [ROOT] = {} } })
    local plugin = activate(host)
    host:run("open", { root = ROOT })
    tap.equal(#plugin.listing_state().entries, 0, "empty directory has no entries")
    tap.ok(first_text(mounted(host), "Empty directory") ~= nil, "empty state is mounted")
  end

  -- Unreadable directories mount a typed error and never crash the command.
  do
    local host = full_host({
      fs_error = { class = "runtime", code = "E_FS_SCOPE_MISMATCH", message = "fs denied for family 'fs'" },
    })
    local plugin = activate(host)
    local ok = pcall(function()
      return host:run("open", { root = ROOT })
    end)
    tap.ok(ok, "unreadable directory does not crash open")
    tap.equal(plugin.listing_state().error.code, "E_FS_SCOPE_MISMATCH", "typed fs error retained")
    tap.ok(first_text(mounted(host), "E_FS_SCOPE_MISMATCH") ~= nil, "typed fs error is mounted")
  end

  -- A host without the fs backend (typed E_NOT_IMPLEMENTED) also degrades to
  -- a mounted error rather than an empty crash.
  do
    local host = full_host({ no_fs = true })
    local plugin = activate(host)
    local ok = pcall(function()
      return host:run("open", { root = ROOT })
    end)
    tap.ok(ok, "missing fs backend does not crash open")
    tap.equal(plugin.listing_state().error.code, "E_NOT_IMPLEMENTED", "missing backend error retained")
  end

  -- Long names truncate to the band width (configured here to keep the test
  -- independent of the snapshot width).
  do
    local long_name = string.rep("x", 60)
    local host = full_host({
      settings = { width = 20 },
      fs_entries = { [ROOT] = { { name = long_name, kind = "file" } } },
    })
    activate(host)
    host:run("open", { root = ROOT })
    local component = mounted(host)
    local name_text = first_text(component, "x")
    tap.ok(name_text ~= nil, "long name is rendered")
    local display = string.sub(name_text or "", 3)
    tap.equal(require("file-manager.scope").char_count(name_text), 20, "row truncates to band width")
    tap.equal(require("file-manager.scope").char_count(display), 18, "name fits after the marker")
    tap.ok(string.find(display, "…", 1, true) ~= nil, "truncation marker is visible")
  end

  -- Click bindings route directories through open and files through preview.
  do
    local host = full_host()
    activate(host)
    host:run("open", { root = ROOT })
    local bindings = clicks(mounted(host))
    tap.ok(#bindings >= 2, "rows carry click bindings")
    local saw_open, saw_preview = false, false
    for _, binding in ipairs(bindings) do
      if binding.command == "open" and binding.args.root == ROOT .. "/docs" then
        saw_open = true
      end
      if binding.command == "preview" and binding.args.path == ROOT .. "/a.txt" then
        saw_preview = true
      end
    end
    tap.ok(saw_open, "directory row opens its root")
    tap.ok(saw_preview, "file row previews its path")
  end

  -- Selection survives preview without an explicit path (keyboard fallback).
  do
    local host = full_host()
    local plugin = activate(host)
    host:run("open", { root = ROOT })
    local entry = host:run("preview", { path = ROOT .. "/b.txt" })
    tap.equal(entry.name, "b.txt", "explicit preview names the file")
    tap.equal(plugin.listing_state().selected, 3, "preview selects the listed row")
    local fallback = host:run("preview", {})
    tap.equal(fallback.name, "b.txt", "preview without a path uses the selection")
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

  -- A denied ui.rich fails the mount with a typed error, never a crash.
  do
    local host = full_host({ grants = { "terminal.semantic-read", "fs.read:**" } })
    activate(host)
    local ok, err = pcall(function()
      return host:run("open", { root = ROOT })
    end)
    tap.ok(not ok, "open without ui.rich fails closed")
    tap.equal(type(err) == "table" and err.code or nil, "E_CAPABILITY_DENIED", "mount denial code")
  end

  -- Only declared settings keys are read.
  do
    local host = full_host({ settings_declared = {} })
    local plugin = activate(host)
    host:run("open", { root = ROOT })
    tap.equal(#plugin.listing_state().entries, 3, "undeclared settings read is swallowed")
  end

  -- The plugin never spawns: no process surface exists on the mock host.
  do
    local host = full_host()
    activate(host)
    tap.equal(host.bitty.process, nil, "no spawn surface on the host")
  end
end

return { run = run }
