-- Dwindle panel lifecycle, Nautilus/Yazi-style scene, and `panel.input`
-- navigation tests for `file-manager`.

local MockHost = require("support.mock_host")

local PLUGIN_ID = "bitty-terminal.file-manager"
local ROOT = "/srv/git/repo"

local COMMANDS = {
  PLUGIN_ID .. ":open",
  PLUGIN_ID .. ":close",
  PLUGIN_ID .. ":preview",
  PLUGIN_ID .. ":rename",
}

local EVENTS = {
  "terminal.cwd-changed",
  "terminal.title-changed",
  "focus.changed",
  "panel.input",
}

local GRANTS = {
  "terminal.semantic-read",
  "ui.rich",
  "panel.create",
  "panel.focus",
  "fs.read:**",
}

local DEFAULT_SNAPSHOT = {
  title = "file-manager",
  width = 80,
  zones = { { metadata = { cwd = ROOT } } },
}

local DEFAULT_FS = {
  [ROOT] = {
    { name = ".gitkeep", kind = "file", size = 0 },
    { name = "docs", kind = "dir" },
    { name = "a.txt", kind = "file", size = 42 },
    { name = "b.txt", kind = "file", size = 1536 },
    { name = "link", kind = "symlink" },
  },
  [ROOT .. "/docs"] = {
    { name = "guide.md", kind = "file", size = 128 },
  },
}

local DEFAULT_FILES = {
  [ROOT .. "/a.txt"] = "hello world\nsecond line",
  [ROOT .. "/b.txt"] = "line one\nline two",
  [ROOT .. "/docs/guide.md"] = "# Guide\nWelcome!",
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

local function panel_host(overrides)
  overrides = overrides or {}
  return MockHost.new({
    plugin_id = PLUGIN_ID,
    grants = overrides.grants or GRANTS,
    commands = COMMANDS,
    events = overrides.events or EVENTS,
    settings = overrides.settings,
    snapshot = overrides.snapshot or DEFAULT_SNAPSHOT,
    fs_entries = overrides.fs_entries or DEFAULT_FS,
    fs_files = overrides.fs_files or DEFAULT_FILES,
    fs_read_error = overrides.fs_read_error,
    panel = true,
  })
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

local function all_text(component)
  local out = {}
  for _, node in ipairs(collect(component, function(value)
    return value.kind == "Text" and type(value.text) == "string"
  end)) do
    out[#out + 1] = node.text
  end
  return table.concat(out, "\n")
end

local function send_key(host, panel_id, key, opts)
  opts = opts or {}
  host:publish("panel.input", {
    panel_id = panel_id,
    kind = "key",
    key = key,
    text = opts.text or (#key == 1 and key or ""),
    ctrl = opts.ctrl or false,
    alt = opts.alt or false,
    shift = opts.shift or false,
    super = opts.super or false,
  })
end

local function run(context)
  local tap = context.tap

  -- 1. Panel create/mount/update/close lifecycle.
  do
    local host = panel_host()
    local plugin = activate(host)
    tap.equal(host:run("open", { root = ROOT }), true, "panel open returns true")
    tap.equal(#host.mounts, 0, "panel mode does not use ui.mount")
    tap.equal(#host.panel_mounts, 1, "panel mode mounts once")
    local panel_id = plugin.listing_state().panel_id
    tap.ok(type(panel_id) == "number", "panel_id is recorded")
    tap.equal(plugin.listing_state().visible, true, "panel is visible")

    -- Second open updates the existing panel_id.
    host:run("open", { root = ROOT, selected = 2 })
    tap.equal(#host.panel_mounts, 1, "second open does not remount")
    tap.equal(#host.panel_updates, 1, "second open updates existing panel")
    tap.equal(host.panel_updates[1].panel_id, panel_id, "update targets same panel_id")

    -- Close closes the panel and is idempotent.
    local closed = plugin.close_listing()
    tap.equal(closed.changed, true, "close reports changed=true")
    tap.equal(closed.panel_id, panel_id, "close returns closed panel_id")
    tap.equal(#host.panel_closes, 1, "panel.close called once")
    tap.equal(plugin.listing_state().panel_id, nil, "panel_id cleared after close")
    tap.equal(plugin.listing_state().visible, false, "visible=false after close")

    local again = plugin.close_listing()
    tap.equal(again.changed, false, "second close is idempotent")
    tap.equal(#host.panel_closes, 1, "second close makes no host call")

    -- Stale panel_id self-heals on next open.
    host:run("open", { root = ROOT })
    local new_id = plugin.listing_state().panel_id
    tap.ok(new_id ~= panel_id, "reopen creates a fresh panel")
    host.panels[new_id].open = false
    host:run("open", { root = ROOT })
    tap.ok(plugin.listing_state().panel_id ~= new_id, "stale panel_id self-heals")
  end

  -- 2. Capability denials fail closed on panel.create / panel.focus.
  do
    local host = panel_host({ grants = { "ui.rich", "fs.read:**", "panel.focus" } })
    activate(host)
    local ok, err = pcall(function()
      return host:run("open", { root = ROOT })
    end)
    tap.ok(not ok, "open without panel.create fails closed")
    tap.equal(type(err) == "table" and err.code or nil, "E_CAPABILITY_DENIED", "panel.create denial code")
  end
  do
    local host = panel_host({ grants = { "ui.rich", "fs.read:**", "panel.create" } })
    local plugin = activate(host)
    host:run("open", { root = ROOT })
    local ok, err = pcall(function()
      return plugin.close_listing()
    end)
    tap.ok(not ok, "close without panel.focus fails closed")
    tap.equal(type(err) == "table" and err.code or nil, "E_CAPABILITY_DENIED", "panel.focus denial code")
  end

  -- 3. Nautilus/Yazi-style scene: header, badges, sizes, split preview.
  do
    local host = panel_host()
    local plugin = activate(host)
    host:run("open", { root = ROOT })
    local panel_id = plugin.listing_state().panel_id
    local component = host.panels[panel_id].component
    local rendered = all_text(component)

    -- Hidden files are filtered by default (4 visible: docs, a.txt, b.txt, link).
    tap.equal(#plugin.listing_state().entries, 4, "hidden file excluded by default")
    tap.ok(string.find(rendered, ROOT, 1, true) ~= nil, "header shows root path")
    tap.ok(string.find(rendered, "4 items", 1, true) ~= nil, "header shows item count")
    tap.ok(string.find(rendered, "[hidden: off]", 1, true) ~= nil, "header shows hidden indicator")
    tap.ok(string.find(rendered, "[DIR]", 1, true) ~= nil, "row shows [DIR] badge")
    tap.ok(string.find(rendered, "[FILE]", 1, true) ~= nil, "row shows [FILE] badge")
    tap.ok(string.find(rendered, "[LINK]", 1, true) ~= nil, "row shows [LINK] badge")
    tap.ok(string.find(rendered, "42B", 1, true) ~= nil, "row shows formatted byte size")
    tap.ok(string.find(rendered, "1.5K", 1, true) ~= nil, "row shows formatted KB size")
    -- First entry is `docs` (dir), so preview pane shows Directory summary.
    tap.ok(string.find(rendered, "Directory (1 item)", 1, true) ~= nil, "preview shows dir summary")
    tap.ok(string.find(rendered, "guide.md", 1, true) ~= nil, "preview lists dir child")

    -- Move to `a.txt` (index 2) and verify live file preview via bitty.fs.read.
    send_key(host, panel_id, "j")
    tap.equal(plugin.listing_state().selected, 2, "j moves selection to a.txt")
    local updated_text = all_text(host.panels[panel_id].component)
    tap.ok(string.find(updated_text, "hello world", 1, true) ~= nil, "preview shows file contents")
    tap.ok(string.find(updated_text, "second line", 1, true) ~= nil, "preview shows second line")
  end

  -- 4. Keyboard & wheel navigation (`panel.input`).
  do
    local host = panel_host()
    local plugin = activate(host)
    host:run("open", { root = ROOT })
    local panel_id = plugin.listing_state().panel_id

    -- Foreign panel_id is ignored.
    send_key(host, panel_id + 999, "j")
    tap.equal(plugin.listing_state().selected, 1, "foreign panel_id ignored")

    -- Modified keys are ignored.
    send_key(host, panel_id, "j", { ctrl = true })
    tap.equal(plugin.listing_state().selected, 1, "ctrl+j ignored")

    -- Down / Up / wheel navigation.
    send_key(host, panel_id, "Down")
    tap.equal(plugin.listing_state().selected, 2, "Down moves to 2")
    host:publish("panel.input", { panel_id = panel_id, kind = "wheel", delta = "down" })
    tap.equal(plugin.listing_state().selected, 3, "wheel down moves to 3")
    host:publish("panel.input", { panel_id = panel_id, kind = "wheel", delta = "-1" })
    tap.equal(plugin.listing_state().selected, 2, "wheel -1 moves up to 2")
    send_key(host, panel_id, "k")
    tap.equal(plugin.listing_state().selected, 1, "k moves up to 1")

    -- Enter on directory (`docs` at index 1) navigates into subdirectory.
    send_key(host, panel_id, "Enter")
    tap.equal(plugin.listing_state().root, ROOT .. "/docs", "Enter enters selected directory")
    tap.equal(#plugin.listing_state().entries, 1, "subdirectory has 1 entry")

    -- Backspace returns to parent (`ROOT`), and stops at `base_root`.
    send_key(host, panel_id, "Backspace")
    tap.equal(plugin.listing_state().root, ROOT, "Backspace returns to parent")
    send_key(host, panel_id, "h")
    tap.equal(plugin.listing_state().root, ROOT, "h cannot escape base_root")

    -- `l` enters directory, `Left` returns to parent.
    send_key(host, panel_id, "l")
    tap.equal(plugin.listing_state().root, ROOT .. "/docs", "l enters directory")
    send_key(host, panel_id, "Left")
    tap.equal(plugin.listing_state().root, ROOT, "Left returns to parent")

    -- `.` toggles hidden files.
    send_key(host, panel_id, ".")
    tap.equal(plugin.listing_state().show_hidden, true, ". enables hidden files")
    tap.equal(#plugin.listing_state().entries, 5, "dotfile .gitkeep is now visible")
    send_key(host, panel_id, ".")
    tap.equal(plugin.listing_state().show_hidden, false, ". disables hidden files")
    tap.equal(#plugin.listing_state().entries, 4, "dotfile hidden again")

    -- `r` refreshes current directory.
    local calls_before = #host.fs_calls
    send_key(host, panel_id, "r")
    tap.ok(#host.fs_calls > calls_before, "r refreshes directory via bitty.fs.list")

    -- `q` closes the panel.
    send_key(host, panel_id, "q")
    tap.equal(plugin.listing_state().visible, false, "q closes the panel")
    tap.equal(plugin.listing_state().panel_id, nil, "q clears panel_id")
  end

  -- 5. File preview degrades gracefully when bitty.fs.read fails.
  do
    local host = panel_host({
      fs_read_error = { class = "runtime", code = "E_FS_DENIED", message = "denied" },
    })
    local plugin = activate(host)
    host:run("open", { root = ROOT, selected = 2 })
    local panel_id = plugin.listing_state().panel_id
    local rendered = all_text(host.panels[panel_id].component)
    tap.ok(string.find(rendered, "E_FS_DENIED", 1, true) ~= nil, "preview shows typed fs.read error")
  end
end

return { run = run }
