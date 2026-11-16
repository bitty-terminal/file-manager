-- Minimal in-process `bitty` host stub for the file-manager behavior tests.
--
-- This is a test double, not a host implementation: it models only the
-- accepted surface the file-manager uses — Plugin API v1 commands/events/
-- settings/terminal-snapshot/ui-mount plus the RFC-0005 `bitty.fs.list`
-- bridge — with fail-closed capability gates and manifest-declared command/
-- event/settings validation. It performs no I/O, spawns nothing, and never
-- touches the network or the filesystem.
--
-- Directory data is staged explicitly (`options.fs_entries[prefix]` or an
-- `options.fs_entries(prefix, max_entries)` function); a missing backend
-- fails with the host's typed `E_NOT_IMPLEMENTED`, and `options.fs_error`
-- stages a typed denial. Mounted blocks are recorded (`mounts`, `updates`,
-- `ui_blocks`) so specs can assert the host-API call shape.

local MockHost = {}
MockHost.__index = MockHost

local function fail(class, code, message)
  error({ class = class, code = code, message = message }, 0)
end

local DEFAULT_DECLARED_SETTINGS = { root = true, entries = true, width = true }

function MockHost.new(options)
  options = options or {}
  local self = setmetatable({}, MockHost)
  self.plugin_id = options.plugin_id or "bitty-terminal.file-manager"
  self.grants = {}
  for _, name in ipairs(options.grants or {}) do
    self.grants[name] = true
  end
  self.declared_commands = {}
  for _, name in ipairs(options.commands or {}) do
    self.declared_commands[name] = true
  end
  self.declared_events = {}
  for _, name in ipairs(options.events or {}) do
    self.declared_events[name] = true
  end
  self.declared_settings = {}
  for key in pairs(options.settings_declared or DEFAULT_DECLARED_SETTINGS) do
    self.declared_settings[key] = true
  end
  self.settings = options.settings or {}
  self.snapshot_value = options.snapshot
  self.fs_entries = options.fs_entries
  self.fs_files = options.fs_files
  self.fs_error = options.fs_error
  self.fs_read_error = options.fs_read_error
  self.fs_calls = {}
  self.fs_read_calls = {}
  self.commands = {}
  self.subscriptions = {}
  self.mounts = {}
  self.updates = {}
  self.ui_blocks = {}
  self.panel_enabled = options.panel == true
  self.panels = {}
  self.panel_mounts = {}
  self.panel_updates = {}
  self.panel_closes = {}
  self.panel_generation = 1
  self.handle_counter = 0
  self.sequence = 1
  self.bitty = self:build_bitty()
  return self
end

function MockHost:grant(name)
  self.grants[name] = true
end

function MockHost:next_handle()
  self.handle_counter = self.handle_counter + 1
  return self.handle_counter
end

function MockHost:assert_capability(surface, capability)
  if not self.grants[capability] then
    fail("runtime", "E_CAPABILITY_DENIED", surface .. " requires capability " .. capability)
  end
end

function MockHost:build_bitty()
  local self = self
  local bitty = {
    api_version = "1.0.0",
    commands = {
      register = function(def)
        if type(def) ~= "table" or type(def.id) ~= "string" then
          fail("validation", "E_DEF_INVALID", "command definition is invalid")
        end
        if def.title == nil or def.title == "" or type(def.run) ~= "function" then
          fail("validation", "E_DEF_INVALID", "command requires title and run")
        end
        local qualified = self.plugin_id .. ":" .. def.id
        if not self.declared_commands[qualified] then
          fail("validation", "E_COMMAND_UNDECLARED", "command is not reserved in the manifest: " .. qualified)
        end
        if self.commands[qualified] ~= nil then
          fail("validation", "E_COMMAND_DUPLICATE", "duplicate command: " .. qualified)
        end
        self.commands[qualified] = def
        return self:next_handle()
      end,
    },
    events = {
      subscribe = function(name, handler)
        if type(name) ~= "string" or type(handler) ~= "function" then
          fail("validation", "E_DEF_INVALID", "event subscription is invalid")
        end
        if not self.declared_events[name] then
          fail("validation", "E_EVENT_UNDECLARED", "event is not declared in the manifest: " .. name)
        end
        self.subscriptions[#self.subscriptions + 1] = { kind = name, handler = handler }
        return self:next_handle()
      end,
    },
    settings = {
      get = function(key)
        if type(key) ~= "string" then
          fail("validation", "E_SETTINGS_KEY_INVALID", "settings key must be a string")
        end
        if not self.declared_settings[key] then
          fail("validation", "E_SETTINGS_UNDECLARED", "settings key is not declared: " .. key)
        end
        return self.settings[key]
      end,
    },
    terminal = {
      snapshot = function(_opts)
        self:assert_capability("bitty.terminal.snapshot", "terminal.semantic-read")
        if type(self.snapshot_value) ~= "table" then
          fail("runtime", "E_SNAPSHOT_UNAVAILABLE", "no semantic snapshot staged")
        end
        return self.snapshot_value
      end,
    },
    ui = {
      mount = function(slot, component)
        self:assert_capability("bitty.ui.mount", "ui.rich")
        if type(slot) ~= "string" or type(component) ~= "table" or type(component.kind) ~= "string" then
          fail("validation", "E_UI_COMPONENT_INVALID", "component is not a declarative node")
        end
        local handle = self:next_handle()
        self.mounts[#self.mounts + 1] = {
          slot = slot,
          component = component,
          handle = handle,
        }
        self.ui_blocks[handle] = component
        return handle
      end,
      update = function(handle, component)
        self:assert_capability("bitty.ui.update", "ui.rich")
        if type(handle) ~= "number" or type(component) ~= "table" or type(component.kind) ~= "string" then
          fail("validation", "E_UI_COMPONENT_INVALID", "component is not a declarative node")
        end
        if self.ui_blocks[handle] == nil then
          return false
        end
        self.ui_blocks[handle] = component
        self.updates[#self.updates + 1] = { handle = handle, component = component }
        return true
      end,
    },
    fs = {
      list = function(prefix, max_entries)
        self:assert_capability("bitty.fs.list", "fs.read:**")
        self.fs_calls[#self.fs_calls + 1] = { prefix = prefix, max_entries = max_entries }
        if type(self.fs_error) == "table" then
          fail(
            self.fs_error.class or "runtime",
            self.fs_error.code or "E_FS_SCOPE_MISMATCH",
            self.fs_error.message or "fs denied"
          )
        end
        if self.fs_entries == nil then
          fail("runtime", "E_NOT_IMPLEMENTED", "bitty.fs.list")
        end
        if type(self.fs_entries) == "function" then
          return self.fs_entries(prefix, max_entries)
        end
        return self.fs_entries[prefix] or {}
      end,
      read = function(path)
        self:assert_capability("bitty.fs.read", "fs.read:**")
        self.fs_read_calls[#self.fs_read_calls + 1] = path
        if type(self.fs_read_error) == "table" then
          fail(
            self.fs_read_error.class or "runtime",
            self.fs_read_error.code or "E_FS_DENIED",
            self.fs_read_error.message or "fs read denied"
          )
        end
        if self.fs_files == nil then
          fail("runtime", "E_NOT_IMPLEMENTED", "bitty.fs.read")
        end
        if type(self.fs_files) == "function" then
          return self.fs_files(path)
        end
        local file = self.fs_files[path]
        if file == nil then
          fail("runtime", "E_FS_NOT_FOUND", "file not found: " .. tostring(path))
        end
        if type(file) == "string" then
          return { body = file, untrusted = true, redacted = false }
        end
        return file
      end,
    },
  }
  if self.panel_enabled then
    bitty.panel = {
      create = function(spec)
        self:assert_capability("bitty.panel.create", "panel.create")
        if type(spec) ~= "table" or spec.type ~= "rich" then
          fail("validation", "E_DEF_INVALID", "panel.create requires { type = 'rich' }")
        end
        local id = self:next_handle()
        self.panels[id] = { id = id, generation = self.panel_generation, component = nil, open = true }
        return { id = id, generation = self.panel_generation }
      end,
      mount = function(panel_id, component)
        self:assert_capability("bitty.panel.mount", "ui.rich")
        if type(panel_id) ~= "number" or type(component) ~= "table" or type(component.kind) ~= "string" then
          fail("validation", "E_UI_COMPONENT_INVALID", "invalid panel mount")
        end
        local entry = self.panels[panel_id]
        if entry == nil or not entry.open then
          return false
        end
        entry.component = component
        self.panel_mounts[#self.panel_mounts + 1] = { panel_id = panel_id, component = component }
        return true
      end,
      update = function(panel_id, component)
        self:assert_capability("bitty.panel.update", "ui.rich")
        if type(panel_id) ~= "number" or type(component) ~= "table" or type(component.kind) ~= "string" then
          fail("validation", "E_UI_COMPONENT_INVALID", "invalid panel update")
        end
        local entry = self.panels[panel_id]
        if entry == nil or not entry.open then
          return false
        end
        entry.component = component
        self.panel_updates[#self.panel_updates + 1] = { panel_id = panel_id, component = component }
        return true
      end,
      unmount = function(panel_id)
        self:assert_capability("bitty.panel.unmount", "ui.rich")
        local entry = self.panels[panel_id]
        if entry == nil or not entry.open then
          return false
        end
        entry.component = nil
        return true
      end,
      close = function(panel_id)
        self:assert_capability("bitty.panel.close", "panel.focus")
        local entry = self.panels[panel_id]
        if entry == nil or not entry.open then
          return false
        end
        entry.open = false
        entry.component = nil
        self.panel_closes[#self.panel_closes + 1] = panel_id
        return true
      end,
    }
  end
  return bitty
end

function MockHost:publish(kind, payload)
  local delivered = 0
  for _, subscription in ipairs(self.subscriptions) do
    if subscription.kind == kind then
      delivered = delivered + 1
      subscription.handler({
        kind = kind,
        sequence = self.sequence,
        payload = payload or {},
      })
      self.sequence = self.sequence + 1
    end
  end
  return delivered
end

function MockHost:run(command_id, args)
  local qualified = self.plugin_id .. ":" .. command_id
  local def = self.commands[qualified]
  if def == nil then
    fail("validation", "E_COMMAND_UNDECLARED", "command is not registered: " .. qualified)
  end
  return def.run(args or {})
end

return MockHost
