# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **Preview directory metadata (PLUG-APP-010, #14):** derive `kind` and
  `is_dir` together from the original validated input and omit trailing
  slashes from preview result paths. Equivalent relative and absolute
  directory inputs now return consistent six-field presentation metadata,
  without filesystem I/O or changes to shared path resolution or listing.

### Changed

- Describe the manifest scope accurately: `Bounded read-only directory
listing, navigation, and preview for a caller-chosen root`. The previous
  text named only the observed cwd, but M-FM-04 resolves every path against a
  caller-supplied `root` (argument, setting, mounted root, then cached cwd).
- **Root-parameterized scope (M-FM-04, M-FM-03):** removed the hardcoded
  `~/projects/**` prefix. `scope.lua` now mirrors the git-panel model
  (`is_absolute_path`, `is_within_root`, `join_root`, `resolve`), so arbitrary
  roots work, containment is checked segment-wise, and validation fails closed
  when no root is available. `..` is denied only as a whole `/`-segment, so
  `a..b` and `backup..tar.gz` are admitted while `x/../y` is rejected.
- **Bare `/` root (R24 follow-up):** `normalize_root` now treats a path-less
  `/` root (or an all-slash run) as unavailable rather than an allow-all root.
  `is_within_root("/", "/etc/passwd")` stays false, the root no longer contains
  itself, and `join_root("/", "foo")` / `resolve("/", "foo")` fail closed
  instead of emitting the non-canonical `//foo`. The git-panel reference keeps
  the raw `//foo` join; this package deliberately rejects it.
- **Headless commands (H-FM-01):** `open`/`preview`/`rename` refresh the
  semantic snapshot behind `pcall` and proceed with caller-supplied or
  settings-derived paths and root, so a missing focused terminal or a denied
  `terminal.semantic-read` no longer crashes operations that do not use the
  snapshot. Without any root, `open` mounts a typed scope error and
  `preview`/`rename` fail closed with `E_SCOPE_UNAVAILABLE`.
- **Payload byte bound (R16):** `list_entries` now enforces `PAYLOAD_MAX_BYTES`
  (`8192`) as accumulated `path` + `name` bytes instead of only capping the
  entry count.
- **Input hardening (R29, L-FM-01, L-FM-02):** removed the dead
  `is_path_bounded` helper and the hardcoded-prefix constants; `list_entries`
  and the other listing helpers guard non-table input; `rename` rejects
  identical src/dst (raw or resolved) and refuses to move the root; entry
  construction no longer has the dead scope-root branch, and trailing-slash
  normalization is centralized in `scope.trim_trailing_slash`.
- **Docs:** README now describes the read-only capability set, the
  root-parameterized scope, the headless behavior, the mounted listing
  surface, and the payload bound.
- **Manifest gate (R-SDK-2):** `just manifest` now runs the authoritative SDK
  linter `bitty-plugin-lint` (commit-pinned in `package.json` and `bun.lock`)
  and fails closed when the pinned dependency is missing. The transitional
  `scripts/validate-manifest.mjs` and the optional `tests/check-manifest-lint.mjs`
  wrapper are removed, so the SDK lint is the single source of truth, and every
  gate runs offline after one `just install` (`CTX-0004`).

### Removed

- **Phantom panel capabilities (H-FM-02):** `panel.provider` and
  `panel.create`; no Lua in this package calls a panel-provider API, and
  `bitty.ui.mount` is the accepted declarative surface. The former
  `fs.write` request is also gone: the listing is read-only and the host
  mediates mutations.
- **Empty scene placeholder (M-FM-05):** `scene.lua` no longer returns `{}`;
  it now carries the real declarative builders wired to `bitty.ui.mount`
  through `init.lua`.

### Added

- **Listing surface (#29):** `open` now mounts a bounded declarative
  `Text`/`Row`/`Column`/`List` block on the accepted `bottom` band through
  `bitty.ui.mount` and reuses it through `bitty.ui.update`. Directory rows
  navigate with the existing `open` command; file rows select/preview with
  the existing `preview` command. Empty directories and typed host denials
  mount explanatory blocks instead of crashing.
- **Host-mediated directory reads:** `directory.lua` calls `bitty.fs.list`
  under one read-only `[[capabilities.filesystem]]` grant, normalizes and
  bounds host entries, sorts directories first, and converts every denial
  into a typed error value. The manifest also declares `ui.rich` for the
  block.
- **Declared settings:** `[settings]` declares `root` (string), `entries`
  (string array), and `width` (int) so every `bitty.settings.get` read is
  allowed by the CTX-1195 allowlist. The test mock now fails undeclared reads
  closed.
- **SDK pin:** bumped `bitty-plugin-sdk` to `3ea8e58` for the accepted
  `[settings]` manifest schema, and regenerated the vendored LuaLS
  definitions.
- **Contributor and security docs:** new `CONTRIBUTING.md` (ground rules,
  prerequisites, development setup, delivery lifecycle, contributor branches,
  capabilities and privacy, workflow snapshots, reporting) and `SECURITY.md`
  aligned with the canonical `bitty-docs` security corpus, including the
  private advisory channel and a supported-versions table (`CTX-0005`).
- **Repository metadata baseline:** a tracked `.gitattributes` normalizing
  text files to LF and marking binary assets, and a `packageManager` bun pin
  in `package.json` with the lockfile revalidated (`CTX-0005`).
- **GitHub metadata baseline (CI, CodeQL, Dependabot, editorconfig):** added
  `.github/workflows/ci.yml` (job `Quality gates`: SHA-pinned checkout, `just`,
  Bun 1.4.0, Lua 5.4, `just check`; plus a `Lint GitHub Actions workflows`
  actionlint job), `.github/workflows/codeql.yml` (`actions` and
  `javascript-typescript`), `.github/workflows/snapshot-source.yml` (verifies
  the in-repo `refs/heads/carryctx-snapshots` publication against `main`),
  `.github/dependabot.yml`, `.github/codeql/codeql-config.yml`, and a root
  `.editorconfig`. The repository-metadata baseline guide and ADR 0011 are
  **Proposed**; adoption is per repository under this scoped task, not a claim
  that the baseline is accepted.
- **Pinned SDK lint with offline gates:** `bitty-plugin-sdk`
  (`bitty-plugin-lint`, R-SDK-2) and `luaparse` are commit-locked
  devDependencies; `just install` (`bun install --frozen-lockfile`) is the only
  networked gate step and `just deps` fails closed when the dependencies are
  not materialized (`CTX-0004`).
- **Negative-fixture automation (R24):** `just test-negative`
  (`tests/check-manifest-negative.mjs`, wired into `just test`/`just check`)
  rejects every `validator-negative/*.toml` fixture through the authoritative
  `bitty-plugin-lint` (bitty-plugin-sdk, R-SDK-2) and accepts the `base.toml`
  positive control, so the validator cannot silently stop rejecting denied
  manifests. Each required fixture must emit its expected SDK diagnostic code
  and the control must be byte-identical to `bitty-plugin.toml`, so a fixture
  cannot pass by being rejected for the wrong reason or by drifting from the
  shipped manifest shape. The check fails when the fixture directory, the
  control, a required negative fixture, or the pinned linter is missing instead
  of passing vacuously.
- **Initial independent package (OQ-053, `bitty` CTX-0399):**
  `bitty-terminal.file-manager` extracted from the `bitty` bundled-disabled
  catalog into this repository with no identity change (id, commands, events).
  Ships pure-Lua listing/navigation/preview policy (no spawn; fs access
  host-mediated), bounded listings (`128` entries, `64` selection, `128`-char
  names, `4096`-byte paths, `8 KiB` payload), three commands, three observation
  events, and a headless Lua behavior suite.
