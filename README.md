# Bitty File Manager

Tiled Panel file listing, navigation, and preview presentation for the
[Bitty terminal](https://github.com/bitty-terminal/bitty), served through the
Panel Runtime with host-mediated filesystem access.

- Plugin id: `bitty-terminal.file-manager`
- Lua module: `lua/file-manager/`
- Capabilities: `panel.provider`, `panel.create`, `terminal.semantic-read`,
  `fs.read:~/projects/**`, optional `fs.write:~/projects/**`
- Lazy commands: `bitty-terminal.file-manager:open`, `:preview`, `:rename`
- Lazy events: `terminal.cwd-changed`, `terminal.title-changed`,
  `focus.changed`

This repository is the independent first-party package created by the bundled
plugin split decision (OQ-053, `bitty-plugins-docs`
`product/bundled-plugin-split-decision.md`), owned by `bitty` `CTX-0399`. It
was scaffolded from
[bitty-plugin-template](https://github.com/bitty-terminal/bitty-plugin-template).

## Status

Pre-implementation ecosystem: the plugin package, manifest, and policy are
implemented and tested headlessly; the Bitty host is still landing the
host-mediated filesystem bridge. Nothing here is a compatibility promise
beyond the manifest `[compat]` ranges.

## Layout

| Path                            | Purpose                                                                                          |
| ------------------------------- | ------------------------------------------------------------------------------------------------ |
| `bitty-plugin.toml`             | Static manifest: identity, compatibility, capability requests, and lazy triggers.                |
| `lua/file-manager/init.lua`     | Entry point evaluated once per activation; registers the three file commands and event handlers. |
| `lua/file-manager/scope.lua`    | Host-free filesystem read/write scope checks (`~/projects/**`).                                  |
| `lua/file-manager/listing.lua`  | Host-free bounded file listings, filters, and sorting.                                           |
| `lua/file-manager/scene.lua`    | Declarative `List`/`Text` panel composition.                                                     |
| `tests/`                        | Lua 5.4 behavior suite, LuaLS conformance, and the SDK manifest-lint wrapper.                    |
| `scripts/validate-manifest.mjs` | Transitional manifest check; `bitty-plugin-lint` (R-SDK-2) is authoritative.                     |
| `justfile`                      | Quality gates with pinned tool versions.                                                         |

## Behavior

The plugin keeps the bundled file-manager behavior and bounds (OQ-053 split,
`bitty` CTX-0399; the bundled `file_manager_manifest` plus
`bitty-runtime::file_manager` review implementation are removed from the host):

- pure Lua policy, no spawn: there is no `process.spawn` surface in this
  plugin and no `os.execute`, `io.popen`, or native module (denied by the
  Lua Runtime restricted library); filesystem access is host-mediated;
- path validation fails closed on: empty paths, paths over `4096` bytes,
  null/control characters, paths outside `~/projects/**`, or any `..`
  segment;
- listings truncate deterministically after sorting and deduplication: `128`
  entries per directory, `64` selected items; names at `128` chars, paths at
  `4096` bytes;
- panel observation payloads are bounded to `8 KiB` at the bus admission
  boundary;
- `open` lists bounded entries from explicit args or settings-provided
  candidates, `preview` validates one in-scope path, `rename` validates one
  in-scope pair inside the optional `fs.write` scope (the host mediates the
  actual mutation);
- observation event handlers refresh only the cached snapshot-derived state
  and never touch the filesystem; a denied `terminal.semantic-read`
  propagates instead of serving empty data.

## Capability identity with the bundled realization

The plugin id, capabilities, commands, and events are unchanged from the
former bundled manifest — the split changes no identity. There is no
`ui.rich`-style adapter difference here (unlike the palette split): the
bundled Rust realization already declared exactly this set.

## Known gaps

- **Host filesystem bridge.** The current `bitty` Lua bridge
  (`crates/bitty-lua/src/host.rs`) implements commands, events, settings,
  store, terminal snapshots, notifications, and timers, but not a
  host-mediated `bitty.fs` surface. Listing/preview/rename commands validate
  and shape bounded data in pure Lua; the host performs real-path resolution
  and I/O behind the `fs.read` / optional `fs.write` grants once that surface
  lands. Tracked as a follow-up task in `bitty`.
- **Panel mounting from Lua.** Panel creation for Lua plugins follows the
  `panel.provider`/`panel.create` grant path; command handlers return bounded
  data rows and declarative scenes for the host panel surface.

## Development

Run the same gate CI runs:

```sh
bun install --frozen-lockfile
just check
```

`just check` runs Markdown lint, Prettier format check, the transitional
manifest validator, the pinned Lua parser, and the Lua/LuaLS/SDK-manifest test
suites. `lua5.4` is required for the behavior suite; `lua-language-server` and
`bitty-plugin-lint` are optional and their checks skip with exit 0 when absent.

## Install

An external package is installed from a local checkout with the Bitty CLI:

```sh
bitty plugin install /path/to/file-manager
```

The registry entry in
[bitty-plugins](https://github.com/bitty-terminal/bitty-plugins) points at this
repository; this plugin previously shipped as a bundled (staged, disabled by
default) `bitty-terminal.file-manager`.

## Security

Only `panel.provider`, `panel.create`, `terminal.semantic-read`,
`fs.read:~/projects/**`, and optional `fs.write:~/projects/**` are requested.
There is no spawn authority, no shell interpolation, no raw PTY injection, and
no network, clipboard, or terminal-input authority. Filesystem access goes
through the host-mediated surface only, never through direct Lua I/O (denied
by the Lua Runtime restricted library).
Report vulnerabilities through the process in the umbrella project's security
policy rather than a public issue.
