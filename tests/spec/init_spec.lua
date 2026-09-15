-- Entry-point behavior tests for `file-manager.init` against the mock host.

local MockHost = require("support.mock_host")

local PLUGIN_ID = "bitty-terminal.file-manager"

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

local GRANTS = {
  "panel.provider",
  "panel.create",
  "terminal.semantic-read",
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
  overrides.grants = overrides.grants or GRANTS
  overrides.commands = overrides.commands or COMMANDS
  overrides.events = overrides.events or EVENTS
  overrides.snapshot = overrides.snapshot
    or { title = "file-manager", zones = { { metadata = { cwd = "~/projects/foo" } } } }
  return MockHost.new(overrides)
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

  -- The open command serves bounded, scope-checked entries from explicit args.
  do
    local host = full_host()
    activate(host)
    local entries = host:run("open", {
      paths = { "~/projects/b", "~/projects/a", "/etc/passwd" },
    })
    tap.equal(#entries, 2, "two in-scope entries")
    tap.equal(entries[1].path, "~/projects/a", "entries sorted")
  end

  -- The open command falls back to settings-provided entries (palette-style
  -- adapter: the v1 surface exposes no fs enumeration, so the host or user
  -- supplies the bounded candidate list).
  do
    local host = full_host({
      settings = { entries = { "~/projects/alpha.txt", "~/projects/beta.txt" } },
    })
    activate(host)
    local entries = host:run("open", {})
    tap.equal(#entries, 2, "settings entries served")
  end

  -- Out-of-scope candidates never reach the panel (fail-closed filter).
  do
    local host = full_host()
    activate(host)
    local entries = host:run("open", { paths = { "~/projects/ok.txt", "/etc/passwd" } })
    tap.equal(#entries, 1, "outside-scope candidate dropped")
    tap.equal(entries[1].path, "~/projects/ok.txt", "in-scope candidate kept")
  end

  -- The preview command validates one in-scope path.
  do
    local host = full_host()
    activate(host)
    local entry = host:run("preview", { path = "~/projects/foo.txt" })
    tap.equal(entry.name, "foo.txt", "preview names the file")
    tap.equal(entry.parent, "~/projects", "preview resolves the parent")
  end

  -- Preview outside the read scope fails closed.
  do
    local host = full_host()
    activate(host)
    local ok, err = pcall(function()
      return host:run("preview", { path = "/etc/passwd" })
    end)
    tap.ok(not ok, "out-of-scope preview fails")
    tap.equal(type(err) == "table" and err.code or nil, "E_FS_DENIED", "preview denial code")
  end

  -- The rename command validates one in-scope pair (host mediates the write).
  do
    local host = full_host()
    activate(host)
    local pair = host:run("rename", { src = "~/projects/old.txt", dst = "~/projects/new.txt" })
    tap.equal(pair.src, "~/projects/old.txt", "rename keeps src")
    tap.equal(pair.dst, "~/projects/new.txt", "rename keeps dst")
  end

  -- Rename outside the write scope fails closed.
  do
    local host = full_host()
    activate(host)
    local ok, err = pcall(function()
      return host:run("rename", { src = "~/projects/ok.txt", dst = "/tmp/evil.txt" })
    end)
    tap.ok(not ok, "out-of-scope rename fails")
    tap.equal(type(err) == "table" and err.code or nil, "E_FS_DENIED", "rename denial code")
  end

  -- Denied snapshot capability fails closed instead of serving empty data.
  do
    local host = full_host({ grants = { "panel.provider", "panel.create" } })
    activate(host)
    local ok, err = pcall(function()
      return host:run("open", { paths = { "~/projects/foo" } })
    end)
    tap.ok(not ok, "denied snapshot fails the command")
    tap.equal(type(err) == "table" and err.code or nil, "E_CAPABILITY_DENIED", "denied capability code")
  end

  -- Observation events refresh the cached cwd without touching the fs.
  do
    local host = full_host()
    local plugin = activate(host)
    host.snapshot_value = { title = "moved", zones = { { metadata = { cwd = "~/projects/other" } } } }
    host:publish("terminal.cwd-changed", {})
    tap.equal(plugin.cached_cwd(), "~/projects/other", "cwd cache refreshed")
  end

  -- The plugin never spawns: no process surface exists on the mock host.
  do
    local host = full_host()
    activate(host)
    tap.equal(host.bitty.process, nil, "no spawn surface on the host")
  end
end

return { run = run }
