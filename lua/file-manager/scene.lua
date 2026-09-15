-- Panel presentation placeholder for Bitty File Manager.
--
-- M-FM-05: the v1 declarative builders (empty/file_rows/directory/preview/
-- rename) were dead code — init.lua never imported this module, and no
-- accepted Plugin API v1 surface mounts a scene from a command result
-- (`bitty.ui.register_panel` is post-v1.0; `bitty.ui.mount` requires the
-- `ui.rich` capability for slot content, which this plugin does not request).
-- They were removed with no dead code left; directory/preview/rename panel
-- wiring lands in a follow-up once a panel mount surface exists.

return {}
