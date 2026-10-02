# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versioning follows [Semantic Versioning](https://semver.org/).

## [8.0.0] — Platform unification

### Added

- **Single platform-aware core** (`bin/ob-sync`): the separate desktop and
  mobile forks are merged into one script that detects Termux, Linux and
  macOS at runtime and adapts defaults, checks and hints accordingly.
- Portability helpers: SHA-256 via `sha256sum` **or** `shasum` (macOS),
  portable vault-size computation, platform-aware install hints.
- ShellCheck CI gate (warnings and above) for every shell file.
- Rewritten installers: `mobile/install.sh` (Termux) and
  `desktop/install.sh` (Linux/macOS) — local-checkout-first, curl fallback.
- This changelog, a repository `.gitignore`, and expanded docs.

### Changed

- **BREAKING:** the command is now canonically `ob-sync` everywhere
  (previously `obsidian-sync` on desktop and `ob-sync` on mobile).
- Default desktop vault is `~/Documents/<Vault>`; Termux keeps
  `~/storage/shared/Documents/<Vault>`.

### Fixed

- macOS portability: replaced GNU-only `du --exclude`, `stat -c`,
  `sha256sum` and `xargs -r` with portable equivalents.
- CI: ShellCheck pinned to v0.11.0; `hr` now receives explicit arguments (SC2120).
- README: Quick Start block restored after a mis-aimed automated replacement.
- README: banner restored inside a proper code fence (the original misalignment came from missing fences, not fonts), then redesigned as an OB-SYNC wordmark in a centered pre block; live CI status badge, restored badge links, trimmed banner rows.
- Docs linting: .markdownlint.json added — MD033 allow-list documents the sanctioned centered-header HTML (GFM has no centering syntax), MD041 off (centered headers carry no H1 by design), MD013 off (version-skew determinism), MD051 off (emoji variation-selector anchors are a known false-positive zone); output code fences tagged as text; markdownlint job added to CI.
- Docs linting follow-up: MD036 off (hero taglines are standalone emphasis by design); cspell.json project vocabulary (editor-only, not CI); README leading blank line removed.
- Docs linting compliance: blank lines added around CHANGELOG headings and CONTRIBUTING in-list fences (MD022/MD031/MD032 fixed structurally); MD024 set to siblings-only — Added/Changed/Fixed repeat per release section by design (Keep a Changelog).

## [7.3.0] — Hardening pass

### Fixed

- Backup ordering: pruning and `restore latest` now sort by the timestamp
  embedded in filenames. A plain name sort grouped by prefix, letting
  stale `quick-*` backups evict fresh `pre-repair-*` safety backups.
- `restore` audits every archive member before extraction — absolute
  paths, `..` traversal and symlink/special members are refused (tar-slip
  protection), with a post-extraction symlink sweep.

### Added

- Temp-file registry: all runtime temporaries are swept on any exit path,
  including SIGINT/SIGTERM.
- `status` degrades gracefully without git; `health` distinguishes a
  missing git binary from actual repository corruption.

## [7.2.0] — Interactive menu & recovery suite

### Added

- Mobile-friendly interactive menu (default on a TTY), `quick`, `restore`,
  `verify`, `doctor`, `init` and `log` commands; lock released between
  menu operations; network watchdog with configurable timeout; automatic
  git identity fallback; first-time setup that adopts an existing vault.

## [7.0.0] — Engine rewrite

### Fixed

- Repair executed its cleanup before the file-restoration loop, rendering
  restoration dead code; ordering corrected and verified.
- Non-atomic lock acquisition (`mkdir -p`) replaced with atomic `mkdir`.
- Per-archive checksum sidecars replaced an ever-growing shared manifest.

## [6.0.0] — Initial release

- Atomic verified backups, PID-based locking, two-phase repair with
  rollback, conventional commits, terminal-safe colors.
