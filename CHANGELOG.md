# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

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
  snapshot. Without any root, `open` is empty and `preview`/`rename` fail
  closed with `E_SCOPE_UNAVAILABLE`.
- **Payload byte bound (R16):** `list_entries` now enforces `PAYLOAD_MAX_BYTES`
  (`8192`) as accumulated `path` + `name` bytes instead of only capping the
  entry count.
- **Input hardening (R29, L-FM-01, L-FM-02):** removed the dead
  `is_path_bounded` helper and the hardcoded-prefix constants; `list_entries`
  and the other listing helpers guard non-table input; `rename` rejects
  identical src/dst (raw or resolved) and refuses to move the root; entry
  construction no longer has the dead scope-root branch, and trailing-slash
  normalization is centralized in `scope.trim_trailing_slash`.
- **Docs:** README now describes the observation-only capability set, the
  root-parameterized scope, the headless behavior, and the payload bound.

### Removed

- **Phantom capabilities (H-FM-02):** `panel.provider`, `panel.create`, and the
  `[[capabilities.filesystem]]` `read` / `write` requests. No Lua in this
  package exercised a panel API and there is no `bitty.fs` surface in Plugin
  API v1, so the manifest now requests only `terminal.semantic-read`.
- **Dead scene builders (M-FM-05):** the `lua/file-manager/scene.lua`
  declarative builders were never imported and no accepted v1 surface mounts a
  scene from a command result; they were removed, leaving an intentional empty
  placeholder with a future-intent pointer.

### Added

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
- **Negative-fixture automation (R24):** `just test-negative`
  (`tests/check-manifest-negative.mjs`, wired into `just test`/`just check`)
  rejects every `validator-negative/*.toml` fixture through
  `scripts/validate-manifest.mjs` and accepts the `base.toml` positive control,
  so the validator cannot silently stop rejecting denied manifests. The check
  fails when the fixture directory, the control, or a required negative fixture
  is missing instead of passing vacuously.
- **Initial independent package (OQ-053, `bitty` CTX-0399):**
  `bitty-terminal.file-manager` extracted from the `bitty` bundled-disabled
  catalog into this repository with no identity change (id, commands, events).
  Ships pure-Lua listing/navigation/preview policy (no spawn; fs access
  host-mediated), bounded listings (`128` entries, `64` selection, `128`-char
  names, `4096`-byte paths, `8 KiB` payload), three commands, three observation
  events, and a headless Lua behavior suite.
