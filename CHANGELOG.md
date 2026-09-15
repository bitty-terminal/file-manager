# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Initial independent package (OQ-053, `bitty` CTX-0399):**
  `bitty-terminal.file-manager` extracted from the `bitty` bundled-disabled
  catalog into this repository with no identity change (id, capabilities,
  commands, events). Ships pure-Lua listing/navigation/preview policy
  (no spawn; fs access host-mediated), bounded listings (`128` entries,
  `64` selection, `128`-char names, `4096`-byte paths, `8 KiB` payload),
  the `~/projects/**` read scope plus optional `~/projects/**` write scope,
  three commands, three observation events, and a headless Lua behavior
  suite (115 assertions).
