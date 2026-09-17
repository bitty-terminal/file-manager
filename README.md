# Bitty File Manager

File listing, navigation, and preview presentation for the
[Bitty terminal](https://github.com/bitty-terminal/bitty), built on the
observed terminal working directory with host-mediated filesystem access.

- Plugin id: `bitty-terminal.file-manager`
- Lua module: `lua/file-manager/`
- Capabilities: `terminal.semantic-read` (read-only cwd/title observation)
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

| Path                                    | Purpose                                                                                                                           |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `bitty-plugin.toml`                     | Static manifest: identity, compatibility, capability requests, and lazy triggers.                                                 |
| `lua/file-manager/init.lua`             | Entry point evaluated once per activation; registers the three file commands and event handlers.                                  |
| `lua/file-manager/scope.lua`            | Host-free root-parameterized scope checks (arbitrary roots; no hardcoded prefix).                                                 |
| `lua/file-manager/listing.lua`          | Host-free bounded file listings, filters, and sorting.                                                                            |
| `lua/file-manager/scene.lua`            | Intentional placeholder for deferred panel presentation (see the M-FM-05 note below).                                             |
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
- least privilege (H-FM-02): the manifest requests only
  `terminal.semantic-read`. The former `panel.provider`, `panel.create`, and
  `fs.read` / `fs.write` requests were phantom authority — no Lua in this
  package calls a panel API or a filesystem entry point — and are removed;
- scope is root-parameterized (M-FM-04): every candidate resolves against a
  caller-supplied `root` (`args.root`, then the `root` setting, then the
  cached terminal cwd) and is admitted only when it equals or nests under that
  root, so arbitrary roots work and any path fails closed when no root is
  available. Validation is segment-wise: only a whole `/`-segment equal to
  `..` is denied, so `a..b` and `backup..tar.gz` are admitted while `x/../y`
  is rejected. A bare `/` root is path-less and names no boundary, so it is
  treated as unavailable: containment admits nothing (not even the root) and
  joins fail closed, keeping the edge canonical (no non-canonical `//foo`);
- path validation additionally fails closed on: empty paths, paths over
  `4096` bytes, and null/control characters;
- listings truncate deterministically after sorting and deduplication: `128`
  entries per directory, `64` selected items; names at `128` chars, paths at
  `4096` bytes; the accumulated listing payload is bounded to `8192` bytes of
  `path` + `name` bytes (R16);
- headless operation (H-FM-01): the semantic snapshot only feeds the cached
  cwd/title and is refreshed behind `pcall`, so a missing focused terminal or
  a denied `terminal.semantic-read` never crashes an operation that does not
  need it. `open`, `preview`, and `rename` work with caller-supplied paths and
  a root; `rename` rejects identical src/dst (raw or resolved) and refuses to
  move the root;
- `open` lists bounded entries from explicit args or settings-provided
  candidates, `preview` resolves one in-scope path, and `rename` validates one
  in-scope pair (the host mediates the actual mutation);
- `preview` derives `kind` and `is_dir` from the original validated input's
  trailing slash, not filesystem metadata. Equivalent relative and absolute
  directory inputs return matching `name`, `path`, `kind`, `truncated`,
  `parent`, and `is_dir` fields; preview result paths omit trailing slashes.
  Scope-root exclusion, path denial, and name bounds still apply. Shared
  resolution and listing behavior are unchanged;
- observation event handlers refresh only the cached snapshot-derived state
  and never touch the filesystem.

## Panel presentation (deferred)

Panel presentation is not wired in v1. The former `lua/file-manager/scene.lua`
declarative builders were dead code — `init.lua` never imported them, and no
accepted Plugin API v1 surface mounts a scene from a command result
(`bitty.ui.register_panel` is post-v1.0; `bitty.ui.mount` requires the
`ui.rich` capability for slot content, which this plugin does not request).
They were removed (M-FM-05) and directory/preview/rename wiring lands in a
follow-up once a panel mount surface exists; `scene.lua` stays as an
intentional empty placeholder so a builder cannot reappear without that
wiring.

## Known gaps

- **Host filesystem bridge.** The current `bitty` Lua bridge
  (`crates/bitty-lua/src/host.rs`) implements commands, events, settings,
  store, terminal snapshots, notifications, and timers, but not a
  host-mediated `bitty.fs` surface. Listing/preview/rename commands validate
  and shape bounded data in pure Lua, and fail closed without a scope root;
  the host performs real-path resolution and I/O once that surface lands and a
  reviewed task re-adds an `fs.*` grant. Tracked as a follow-up task in
  `bitty`.

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

Only `terminal.semantic-read` is requested. There is no panel, filesystem,
spawn, shell interpolation, raw PTY injection, network, clipboard, or
terminal-input authority. Path validation is root-parameterized and
fail-closed, and any future filesystem access goes through a host-mediated
surface only, never through direct Lua I/O (denied by the Lua Runtime
restricted library). Report vulnerabilities through the process in the
umbrella project's security policy rather than a public issue.
