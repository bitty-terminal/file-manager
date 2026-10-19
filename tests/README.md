# File-manager test harness

Headless checks for the `lua/file-manager/**` implementation. `just check`
(`lint` + `fmt-check` + `manifest` + `lua` + `test`) runs them locally and in
CI; the individual suites are also available directly.

## Prerequisites

- `lua5.4` (plugin VM baseline per ADR 0005) — required for behavior tests;
  CI installs it from the Ubuntu archive before `just check`.
- `bun` — runs the wrapper scripts and `just install`, which materializes the
  pinned devDependencies (including the SDK linter used by `just manifest`).
- `lua-language-server` (optional) — LuaLS conformance; the check skips with
  exit 0 when it is unavailable (CI does not install it).

## Commands

```sh
just test            # lua5.4 runner + LuaLS check + negative-fixture check

# Behavior tests: scope, listings, directory reads, scenes, lifecycle,
# capabilities.
just test-lua

# LuaLS conformance against the vendored Plugin API v1 definitions
# (LUA_LANGUAGE_SERVER=/path/to/server overrides discovery).
just test-luals

# Negative manifest fixtures (R24): every `validator-negative/*.toml` must be
# rejected by the pinned SDK linter with its expected diagnostic code;
# `base.toml` must be byte-identical to `bitty-plugin.toml`. Fails closed when
# the fixture set, control, or linter is missing.
just test-negative
```

## Layout

| Path                            | Purpose                                                                                                                               |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `run.lua`                       | Plain-Lua runner; exits non-zero on assertion failure.                                                                                |
| `support/tap.lua`               | Assertion helper (no external test framework).                                                                                        |
| `support/mock_host.lua`         | Fail-closed in-process `bitty` stub modeling the used surface (commands, events, settings, snapshot, UI mount/update, `fs.list`).     |
| `spec/scope_spec.lua`           | Root-parameterized scope unit tests (arbitrary roots; no hardcoded prefix).                                                           |
| `spec/listing_spec.lua`         | Bounded file listing/filter/sort unit tests.                                                                                          |
| `spec/directory_spec.lua`       | Host-mediated directory-read normalization, bounds, empty state, and typed denials.                                                   |
| `spec/scene_spec.lua`           | Declarative listing/preview builders: truncation, empty/error states, click bindings, bounded rows.                                   |
| `spec/init_spec.lua`            | Entry-point behavior against the mock host, including the non-empty `mount` smoke assertion.                                          |
| `lua-defs/bitty.d.lua`          | Vendored LuaLS definitions from bitty-plugin-sdk (origin/main `3ea8e58`).                                                             |
| `lua-defs/negative-fixture.lua` | Excluded-surface fixture that LuaLS must reject.                                                                                      |
| `check-lua-luals.mjs`           | Positive/negative LuaLS workspace check.                                                                                              |
| `check-manifest-negative.mjs`   | Rejects each `validator-negative/*.toml` fixture with its expected `bitty-plugin-lint` diagnostic; asserts `base.toml` byte-identity. |

## Known gaps

- The SDK mock host is a TypeScript test double; a Lua-facing adapter able to
  execute `init.lua` against it is a separate tooling task
  (`bitty-plugin-sdk` `docs/mock-host.md`, "Lua execution").
  `support/mock_host.lua` is this repository's bounded stand-in.
- The `bitty.fs` host bridge surface is present and the plugin consumes
  `bitty.fs.list`, but the checked-out Bitty 0.0.24 runtime does not yet wire
  an fs backend (`PluginServices` leaves `E_NOT_IMPLEMENTED`). The mock host
  stages entries explicitly, so the plugin-side normalization, bounds, and
  typed-denial paths are fully exercised; live enumeration depends on the
  runtime backend landing.
- CI installs `lua5.4` but not `lua-language-server`, so the LuaLS wrapper
  reports `skipped` (exit 0) in CI; install it locally, or pin it into the
  workflow later, for full conformance coverage. The manifest linter is a
  commit-pinned devDependency (`just install`), so `just manifest` and
  `just test-negative` run it everywhere.
