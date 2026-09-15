-- Regression spec for the deferred file-manager panel presentation.
--
-- Run from the package root: `lua5.4 tests/run.lua`.
--
-- M-FM-05: the v1 declarative builders were dead (init.lua never imported
-- scene) and no accepted Plugin API v1 surface mounts a scene from a command
-- result (`bitty.ui.register_panel` is post-v1.0), so they were removed. This
-- spec pins the module to its intentional empty placeholder, so a builder
-- cannot reappear without the panel mount wiring.

local M = {}

function M.run(context)
  local tap = context.tap
  local scene = require("file-manager.scene")
  tap.equal(type(scene), "table", "scene module loads as a table")
  tap.equal(next(scene), nil, "no dead scene builders remain")
end

return M
