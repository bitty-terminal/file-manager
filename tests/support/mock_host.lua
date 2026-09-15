-- Minimal in-process `bitty` host stub for the file-manager behavior tests.
--
-- This is a test double, not a host implementation: it models only the
-- accepted surface the file-manager uses — Plugin API v1 commands/events/
-- settings/terminal-snapshot — with fail-closed capability gates and
-- manifest-declared command/event validation. It performs no I/O, spawns
-- nothing, and never touches the network or the filesystem.
--
-- Observation-only (H-FM-02): the plugin requests just
-- `terminal.semantic-read`, so `terminal.snapshot` is the only gated surface.
-- Filesystem access is not wired — there is no `bitty.fs` surface in Plugin
-- API v1 and no `fs.*` grant — so the stub models no filesystem calls; the
-- plugin's root-parameterized scope checks (arbitrary roots, no hardcoded
-- prefix) are the fail-closed boundary under test.

local MockHost = {}
MockHost.__index = MockHost

local function fail(class, code, message)
  error({ class = class, code = code, message = message }, 0)
end

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
  self.settings = options.settings or {}
  self.snapshot_value = options.snapshot
  self.commands = {}
  self.subscriptions = {}
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
  return {
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
  }
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
