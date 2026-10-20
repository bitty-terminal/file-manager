# Bitty File Manager

File listing, navigation, and preview presentation for the
[Bitty terminal](https://github.com/bitty-terminal/bitty), built on the
observed terminal working directory with host-mediated filesystem access.

- Plugin id: `bitty-terminal.file-manager`
- Lua module: `lua/file-manager/`
- Capabilities: `terminal.semantic-read` (read-only cwd/title observation),
  `ui.rich` (declarative listing block), and read-only `fs.read:**`
  (`bitty.fs.list` directory enumeration)
- Lazy commands: `bitty-terminal.file-manager:open`, `:preview`, `:rename`
- Lazy events: `terminal.cwd-changed`, `terminal.title-changed`,
  `focus.changed`
- Settings: `root`, `entries`, `width` (declared in `[settings]`)

This repository is the independent first-party package created by the bundled
plugin split decision (OQ-053, `bitty-plugins-docs`
`product/bundled-plugin-split-decision.md`), owned by `bitty` `CTX-0399`. It
was scaffolded from
[bitty-plugin-template](https://github.com/bitty-terminal/bitty-plugin-template).

## Overview

Bitty File Manager lists directory entries in a bounded band over the observed
terminal working directory and supports keyboard navigation and preview.
Directory enumeration goes through the host-mediated `bitty.fs.list` bridge;
the plugin validates and shapes the result, never calling Lua I/O directly.
It requests read-only authority only, and `rename` validates one pair while the
host mediates any mutation. Presentation is a declarative band block; there is
no process, network, or terminal-input surface.

## Install

Prerequisites: Bitty `>=0.0.24,<0.1` and Plugin API `^1.0` (from
`bitty-plugin.toml` `[compat]`).

```sh
bitty plugin install https://github.com/bitty-terminal/file-manager.git
bitty plugin enable bitty-terminal.file-manager
bitty plugin list   # confirm state and grants
```

From a local checkout:

```sh
bitty plugin install ./file-manager --yes
bitty plugin enable bitty-terminal.file-manager
```

`bitty plugin list` confirms activation: the entry must be enabled and show
`terminal.semantic-read`, `ui.rich`, and the read-only filesystem grant. A
disabled entry carries a `disabled_reason`; see
[Troubleshooting](#troubleshooting).

## Commands

| Command                               | What it does                                                                                         | Arguments                                                           | Default keybinding |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- | ------------------ |
| `bitty-terminal.file-manager:open`    | Mount or update the bounded directory listing for the scope root and select one row.                 | `root` (string), `paths` (array of strings), `selected` (integer)   | None               |
| `bitty-terminal.file-manager:preview` | Show the bounded preview entry for one in-scope path, or for the selected row when `path` is absent. | `path` (string, optional), `root` (string)                          | None               |
| `bitty-terminal.file-manager:rename`  | Validate one user-confirmed rename inside the scope root; the host performs the mutation.            | `src` (string, required), `dst` (string, required), `root` (string) | None               |

`open` reads the host listing unless `paths` (or the `entries` setting) supplies
bounded candidate paths. `preview` without `path` uses the current selection,
so it is the command to bind to a key.

## Configuration

Settings are declared in `bitty-plugin.toml` `[settings]` and resolved from
`$XDG_CONFIG_HOME/bitty/plugins/bitty-terminal.file-manager.lua`. Every key is
user-owned; the plugin never writes settings.

| Key       | Type         | Default | Description                                                                                                                     | Applies         |
| --------- | ------------ | ------- | ------------------------------------------------------------------------------------------------------------------------------- | --------------- |
| `root`    | string       | `""`    | Optional scope root. Empty uses the mounted listing root, then the observed terminal cwd; a bare `/` is treated as unavailable. | Next activation |
| `entries` | string array | `[]`    | Optional bounded candidate paths for `open`. When non-empty they replace the host listing; paths still resolve against `root`.  | Next activation |
| `width`   | integer      | `0`     | Band width in cells for name truncation. `0` derives the width from the semantic snapshot.                                      | Next activation |

```lua
-- $XDG_CONFIG_HOME/bitty/plugins/bitty-terminal.file-manager.lua
return {
  root = "/srv/project",
  entries = { "src", "tests", "README.md" },
  width = 0,
}
```

The host resolves settings at activation and pins them to the generation, so
edit the file and reopen Bitty to apply a change. Wrong-typed values are
ignored; a missing or unavailable root fails closed instead of listing an
unbounded path.

## Keybindings

The plugin installs no keyboard bindings. Directory rows carry `open` click
bindings and file rows carry `preview` click bindings. Bind a command yourself
in `$XDG_CONFIG_HOME/bitty/init.lua`; user mappings keep precedence:

```lua
return {
  keymaps = {
    {
      chord = "ctrl+alt+f",
      action = "bitty-terminal.file-manager:open",
      context = "global",
    },
    {
      chord = "ctrl+alt+p",
      action = "bitty-terminal.file-manager:preview",
      context = "global",
    },
  },
}
```

## Troubleshooting

| Symptom / error           | Meaning                                                                                                                                                                                                          | What to do                                                                                                                                                          |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `E_INCOMPATIBLE`          | The host application or Plugin API version is outside `[compat]`; the plugin disables with no partial activation.                                                                                                | Upgrade Bitty or install a file-manager revision whose ranges admit your host. Do not edit the manifest ranges.                                                     |
| `E_SETTINGS_UNDECLARED`   | The plugin read a settings key absent from `[settings]`. This is a plugin defect.                                                                                                                                | All three keys are declared; if it still appears, report it with `bitty plugin info bitty-terminal.file-manager` and run `bitty --safe` meanwhile.                  |
| Capability denied         | `E_CAPABILITY_DENIED` (class `runtime`): without `terminal.semantic-read` there is no observed cwd or snapshot width; without `ui.rich` no band mounts; without the read filesystem grant the listing is denied. | Reinstall and approve the grants, or inspect granted versus requested capabilities with `bitty plugin list`. Supply `root` explicitly if cwd observation is denied. |
| `E_NOT_IMPLEMENTED` block | The host runtime has not wired the `bitty.fs.list` backend yet; the band shows the typed error instead of crashing.                                                                                              | Use explicit `paths` or the `entries` setting, or upgrade Bitty when the backend ships.                                                                             |
| `E_SCOPE_UNAVAILABLE`     | No scope root is available (no `root` argument, no `root` setting, no mounted root, and no observed cwd).                                                                                                        | Set `root`, pass `root` in the command, or focus a terminal whose cwd is observable.                                                                                |
| `E_FS_DENIED`             | A path is outside the scope root, empty, over 4096 bytes, contains control characters, or a rename pair is invalid.                                                                                              | Use a path equal to or nested under the root; source and destination must differ and neither may be the root itself.                                                |
| `E_FS_SCOPE_MISMATCH`     | The host rejected the requested prefix against its own scope or sensitive-path policy.                                                                                                                           | Choose a prefix the host policy permits; the plugin never retries or escalates.                                                                                     |
| `E_SPAWN_FAILED`          | Not applicable: this plugin spawns no process and opens no socket.                                                                                                                                               | —                                                                                                                                                                   |

## Status

The plugin package, manifest, listing surface, and policy are implemented and
tested headlessly. The Bitty host is still landing the backend for the
host-mediated `bitty.fs.list` bridge, so a live host may mount a typed
`E_NOT_IMPLEMENTED` block until that lands; explicit args/settings entries
still render. Nothing here is a compatibility promise beyond the manifest
`[compat]` ranges.

## Layout

| Path                                    | Purpose                                                                                                                           |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `bitty-plugin.toml`                     | Static manifest: identity, compatibility, capability requests, declared settings, and lazy triggers.                              |
| `lua/file-manager/init.lua`             | Entry point evaluated once per activation; registers the three file commands, mounts/updates the listing block, and wires events. |
| `lua/file-manager/scope.lua`            | Host-free root-parameterized scope checks (arbitrary roots; no hardcoded prefix).                                                 |
| `lua/file-manager/listing.lua`          | Host-free bounded file listings, filters, and sorting.                                                                            |
| `lua/file-manager/directory.lua`        | Host-mediated `bitty.fs.list` reads: normalize, bound, sort, and turn denials into typed errors.                                  |
| `lua/file-manager/scene.lua`            | Pure declarative `Text`/`Row`/`Column`/`List` builders for the listing, empty state, typed error state, and preview.              |
| `tests/`                                | Lua 5.4 behavior suite, LuaLS conformance, and the SDK-lint negative-fixture check.                                               |
| `validator-negative/`                   | Manifest fixtures the SDK linter must reject with expected diagnostics; `base.toml` is the byte-identical accepted control (R24). |
| `justfile`                              | Quality gates; `just install` materializes the pinned dev dependencies.                                                           |
| `.github/workflows/ci.yml`              | CI quality gate with a read-only token and SHA-pinned actions.                                                                    |
| `.github/workflows/codeql.yml`          | CodeQL analysis (`actions`, `javascript-typescript`).                                                                             |
| `.github/workflows/snapshot-source.yml` | CarryCtx snapshot staleness gate (push to `main`/`carryctx-snapshots`).                                                           |
| `.github/dependabot.yml`                | Weekly grouped updates for pinned GitHub Actions and npm dev dependencies.                                                        |

## Behavior

The plugin keeps the bundled file-manager bounds (OQ-053 split, `bitty`
CTX-0399; the bundled `file_manager_manifest` plus
`bitty-runtime::file_manager` review implementation are removed from the host):

- pure Lua policy, no spawn: there is no `process.spawn` surface in this
  plugin and no `os.execute`, `io.popen`, or native module (denied by the
  Lua Runtime restricted library); filesystem access is host-mediated;
- least privilege (H-FM-02): the manifest requests three read-only
  authorities, each exercised by code: `terminal.semantic-read` for the
  cwd/title observation, `ui.rich` for the declarative listing block, and the
  `[[capabilities.filesystem]]` read grant for `bitty.fs.list`. There is no
  `fs.write`, process, network, clipboard, or terminal-input request. `list`
  is read-class in the RFC-0005 bridge, so the listing cannot mutate the
  filesystem;
- scope is root-parameterized (M-FM-04): every candidate resolves against a
  caller-supplied `root` (`args.root`, then the `root` setting, then the
  mounted listing root, then the cached terminal cwd) and is admitted only
  when it equals or nests under that root, so arbitrary roots work and any
  path fails closed when no root is available. Validation is segment-wise:
  only a whole `/`-segment equal to `..` is denied, so `a..b` and
  `backup..tar.gz` are admitted while `x/../y` is rejected. A bare `/` root is
  path-less and names no boundary, so it is treated as unavailable;
- path validation additionally fails closed on empty paths, paths over `4096`
  bytes, and null/control characters; listings truncate deterministically
  after sorting and deduplication at `128` entries, `128`-char names,
  `4096`-byte paths, and `8192` accumulated `path` + `name` bytes (R16);
- headless operation (H-FM-01): the semantic snapshot only feeds the cached
  cwd/title and default band width and is refreshed behind `pcall`, so a
  missing focused terminal or a denied `terminal.semantic-read` never crashes
  an operation that does not need it. `open`, `preview`, and `rename` work
  with caller-supplied paths and a root; `rename` rejects identical src/dst
  (raw or resolved) and refuses to move the root;
- `preview` derives `kind` and `is_dir` from the original validated input's
  trailing slash, not filesystem metadata; observation event handlers refresh
  only the cached state and never touch the filesystem.

## Listing surface

`open` mounts one bounded declarative block on the accepted `bottom` band
through `bitty.ui.mount`, then reuses it with `bitty.ui.update`:

- the cwd comes from the semantic snapshot (newest zone with `metadata.cwd`)
  unless `args.root` or the declared `root` setting overrides it;
- entries come from `bitty.fs.list` through `directory.lua`, bounded exactly
  like the pure listing module (128 entries, 128-char names, 4096-byte paths,
  8192 payload bytes), sorted directories first, then by name;
- display names truncate at the hosted band width (`width` setting, else the
  snapshot width) with an ellipsis; the band shows at most 12 rows and follows
  the selection window;
- empty directories mount an "Empty directory" block; unreadable or
  unavailable directories mount the typed host code (for example
  `E_FS_SCOPE_MISMATCH` or `E_NOT_IMPLEMENTED`) instead of crashing;
- directory rows carry an `open` click binding for navigation and file rows
  carry a `preview` click binding. `preview` also works without a path and
  uses the selected row, so the existing command works from a keyboard
  binding; `open` is the navigation entry point;
- `open` returns `true` (a boolean acknowledgement, not a `{}` table) so the
  mounted block is the user-visible surface and dispatch does not raise a
  banner.

## Known gaps

- **Host filesystem backend.** `bitty.fs.list` is the accepted RFC-0005
  host bridge and the plugin consumes it, but the checked-out Bitty 0.0.24
  runtime does not yet wire an fs backend (`PluginServices` leaves the default
  `E_NOT_IMPLEMENTED` implementation). On such a host the listing mounts a
  typed `E_NOT_IMPLEMENTED` block; it becomes usable as soon as the runtime
  wires the bridge. `open` with explicit `args.paths` or the declared
  `entries` setting still renders a listing without the backend.
- **Band-only presentation.** The block mounts on `bottom`; `left`/`right`
  vertical bands and a dedicated panel provider are not hosted in this
  release.
- **Rename presentation.** `rename` validates the pair only; the host still
  mediates the mutation and the listing does not auto-refresh after it.

## Development

Prerequisites: `just`, `bun`, and `lua5.4` for the behavior suite. CI
(`.github/workflows/ci.yml`, job `Quality gates`) pins Bun 1.4.0, installs Lua
5.4, and runs `just check`; a separate `Lint GitHub Actions workflows` job runs
actionlint, and CodeQL analyzes `actions` and `javascript-typescript`.

Run the same gate CI runs:

```sh
just install   # bun install --frozen-lockfile; the only networked step
just check
```

`just check` runs Markdown lint, Prettier format check, the authoritative SDK
manifest linter (`bitty-plugin-lint`, commit-pinned in `package.json` and
`bun.lock`), the pinned Lua parser, and the Lua/LuaLS/negative-fixture test
suites. `lua5.4` is required for the behavior suite; `lua-language-server` is
the only optional tool and its check skips with exit 0 when absent.
`just test-negative` (R24) rejects every `validator-negative/*.toml` fixture
through the SDK linter and accepts the `base.toml` control, failing when the
fixture set or the pinned linter is missing rather than passing vacuously.

## Security

The manifest requests only read-only authority: `terminal.semantic-read`
(cwd/title observation), `ui.rich` (declarative listing block), and one
`[[capabilities.filesystem]]` read grant for `bitty.fs.list` (directory names
and kinds, never file bytes). There is no `fs.write`, spawn, shell
interpolation, raw PTY injection, network, clipboard, or terminal-input
authority. Path validation is root-parameterized and fail-closed; the host
applies its scope, sensitive-path, secret, and budget gates to every listed
prefix. Filesystem access never goes through direct Lua I/O (denied by the Lua
Runtime restricted library). Report vulnerabilities through the process in the
umbrella project's security policy rather than a public issue.
