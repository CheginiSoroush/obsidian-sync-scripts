# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versioning follows [Semantic Versioning](https://semver.org/).

## [9.2.1] — A lost scan, preview throughput & lock-routing corners

### Fixed

- **`organize` never reported empty notes** — the 9.2.0 refactor that
  extracted `organize_scan()` for the JSON document accidentally
  dropped the empty-notes pass, so every audit since 9.2.0 answered
  "No empty notes" regardless of the vault (and `empty_notes: []`
  in the document) — while the human report, the help text and the
  JSON contract all still advertised the feature. The scan is back
  with the exact pre-9.2.0 criteria (markdown files with fewer than
  10 bytes of content, `.git`/`.obsidian`/`.trash` excluded), feeding
  both the human view and the `empty_notes[]` array.
- **`restore --list` claimed a checksum verification that never ran** —
  `verify_sidecar` returns success both for a valid sidecar AND for
  "no sidecar at all", so the preview printed
  "Checksum sidecar valid (sha256)" for archives that had none. The
  line is now conditional: archives without a sidecar report
  "No checksum sidecar — stream integrity verified only" instead.
- **`doctor --json` leaked a global** — the default-branch probe
  assigned `default_branch` without `local` (the human twin declared
  it), polluting the environment for everything that ran after it.
- **fsck counting mangled zero** — `$(grep -c … || printf '0')`
  captures grep's printed count (0) AND the fallback's 0 whenever grep
  matches nothing, leaving a two-line `0\n0` in the variable; the
  arithmetic below then tripped a visible
  "syntax error in expression" on stderr whenever fsck failed without
  matching error lines (watchdog trip, hard abort). Counts are now
  assigned first with a plain fallback.
- **`organize` silently dropped positional arguments after `--`** —
  `organize -- --fix` parsed the `--`, ignored what followed and ran
  an innocent scan instead of failing closed like every other stray
  positional. The parser now rejects leftover arguments after the
  separator (same contract as `organize oops`).
- **dispatch lock-routing scanned past `--`** — `restore -- --list`
  (a target literally named `--list` behind the end-of-options
  separator) matched the substring routing check and was sent down
  the lock-free preview path while the parser treated it as a
  destructive apply — a lock bypass for a pathological name. Both the
  restore and organize routing now stop their flag scan at `--`, so
  everything after the separator routes to the locked apply flow.

### Changed — Performance

- **Restore previews decompress the archive twice, not six times.**
  `restore --list`, `--dry-run` and `restore --list --json` used to
  read the same stream up to six times (integrity gate, two tar-slip
  audit passes, member statistics, top-level layout — each with its
  own `tar`). A shared listing cache (`tar_listing_cache`) now holds
  the plain-name and verbose-type listings, decompressed exactly once
  per archive and reused by every consumer, including the apply flow's
  audit (three reads → two). The listing reads also run under
  `OBS_LOCAL_TIMEOUT` now — the same policy `verify` already had — so
  a hung mount cannot freeze a preview either.
- **`organize`'s orphan scan runs one grep, not one per attachment.**
  The references are folded into an associative array keyed on the
  lowercased name (the same case-insensitive whole-name match the
  per-file `grep -iFx` performed), turning the membership check into
  a hash lookup — a vault with hundreds of attachments no longer
  forks hundreds of grep processes on a phone.

### Tests

- New regression coverage: the restored empty-notes scan (fixture
  under 10 bytes, human + `--json`), the no-sidecar preview wording
  (human + document fields), `organize -- --fix` and `restore --
  --list` fail-closed/locked routing, and the `organize --json`
  document shape stays intact with the new scan active.

## [9.2.0] — History & organize join the machine surface

### Added

- **`history --json [n]`** — the vault's commit history becomes a
  document: `commits[{hash, date, author, subject}]` with **full
  SHA-1 hashes** (unambiguous; shorten with `jq` if needed) and
  **ISO 8601 strict dates** — a stable, sortable contract, unlike the
  human view's relative "2 hours ago" strings. Read-only and
  lock-free. A fresh repository (no commits yet) is valid empty data
  (`count: 0`, rc 0, mirroring the human "No commits yet" message);
  rc 1 with code `history_unreadable` is reserved for a repository
  that cannot be read at all. Non-numeric counts keep the pre-9.x
  tolerance of falling back to the default (10), and the request is
  capped at 100 like the human view.
- **`organize --json` (scan) and `organize --fix --json` (cleanup)** —
  the vault audit becomes a document: `scan{notes, attachments,
  other}` counters, the `untitled` / `empty_notes` / `oversized`
  lists (with exact `size_bytes` for oversized files) and the
  `orphans` list. With `--fix` it adds a full **moved-files report**:
  `moved[{from, to}]` for every relocation and
  `skipped[{file, reason}]` for every refusal (`name collision`,
  `already in attachments dir`, `move failed` — the latter two were
  silently swallowed before) — a scripted cleanup can verify its own
  outcome instead of trusting a summary line. Stable error codes:
  `scan_failed`, `attach_dir_create_failed`, plus `lock_busy` (rc 2).
  Both modes accept `-y` as a documented no-op and fail closed on
  unknown flags (same contract as log/verify/health).
- **Scan-only organize no longer takes the PID lock** — `organize`
  without `--fix` is a pure read (same policy as `restore --list`),
  so a report can be produced even while a sync holds the lock;
  `organize --fix` stays serialized. The `history --json` and
  `organize --json` commands are wired into the bash and zsh
  completions, and the README "Machine-Readable Everything" matrix
  grows to fourteen documents across thirteen commands with console
  blocks for both new commands.
- **CI bash-compatibility matrix** — the functional suite now also
  runs in GitHub Actions on bash 4.4 (the support floor) and 5.2
  (Alpine containers with the GNU toolchain and python3), next to the
  ubuntu-latest job.

### Fixed

- **`history` never showed the newest commit**: `git log --pretty
  format:` emits no trailing newline, so the plain `while read`
  parsing loop treated the final (= newest) commit as an unterminated
  line and silently dropped it — every release before 9.2.0 listed
  n−1 commits. The read loops now keep that final line in both human
  and `--json` modes, pinned by dedicated regression assertions
  (machine: first commit hash equals `git rev-parse HEAD`; human: the
  newest short hash and subject appear in the output).

### Tests

- The functional suite grows from 225 to **258 assertions** (sections
  34–35): `history --json` document shape (hash/date/author/subject
  contracts, requested-count handling, non-numeric tolerance, the
  100-cap, unborn-repository and non-repository documents, lock
  freedom) and `organize --json` / `--fix --json` scan counters
  re-computed independently, orphan/collision/already-in-place
  fixtures, disk-state verification of every moved file, fail-closed
  flags, and the live-lock contract (scan succeeds, fix answers
  `lock_busy`). ShellCheck's warning gate is now genuinely clean on
  the full CI file list including the test suite.

## [9.1.0] — Scripted restores & log analytics

### Added

- **Apply-mode `restore --json <target> -y`** — a scripted disaster-recovery
  drill emits ONE stable result document: `result`, `target`, `vault`,
  `archive{name, path, size_bytes, sidecar, sidecar_ok}`,
  `safety_backup`, `previous_vault`, `elapsed_seconds` and
  `error{code, message}` — so a drill can assert its own success
  instead of scraping terminal text. JSON mode never prompts: an
  explicit target and `-y` are required (no implicit "latest" guess),
  and even a failed run reports exactly which archive it was about to
  restore. Every refusal carries a stable machine code:
  `target_required`, `consent_required`, `no_backups`,
  `backup_not_found`, `archive_corrupt`, `checksum_mismatch`,
  `unsafe_archive`, `extraction_failed`, `extraction_timeout`,
  `symlink_detected`, `staging_failed`, `swap_failed`,
  `safety_backup_failed` — plus `lock_busy` (rc 2). The exit-code
  contract mirrors human mode (0 restored, 1 failure, 2 contention).
- **`log --json [n]`** — the activity log becomes a document:
  `entries[{timestamp, source, message}]` parsed from the
  `[timestamp] [source] message` log lines, so automation can tail
  ob-sync's own history with `jq` instead of parsing free text.
  Read-only and lock-free. A missing or disabled log file is valid
  empty data (`log_file: null`, count 0, rc 0 — mirroring the human
  "No log file available"); rc 1 with code `log_unreadable` is
  reserved for an existing-but-unreadable file, and a torn line (crash
  mid-write) degrades to null metadata instead of aborting the
  document.
- README gains a **"Machine-Readable Everything"** matrix — one row
  per `--json` command with its document highlights and failure
  contract (twelve documents across eleven commands) — plus console
  blocks for `log --json` and apply-mode `restore --json`.
- `log --json` offered in the bash and zsh completions; the zsh
  `restore --json` description now mentions the apply-mode result;
  `help`, both completion files and the README command reference
  updated to v9.1.0.

### Fixed

- **Apply-mode `restore --json` bypassed the PID lock**: the dispatch
  routing treated any `restore … --json` as a read-only preview, so a
  scripted restore could run concurrently with a sync. Destructive
  restores are serialized again (only `--list` / `--dry-run` stay
  lock-free), and a contended lock answers with a parseable
  `lock_busy` document (rc 2) instead of leaving stdout empty.
- **Same-second restore swap collision**: consecutive restores aimed
  `mv` at the same `.pre-restore-<timestamp>` name — the swap then
  failed ("Failed to move the current vault aside", target directory
  non-empty) or silently nested the old vault inside the previous
  `.pre-restore-*` directory. The swap now uses make_backup's
  collision suffix loop (`-1`, `-2`, …), and rapid scripted DR drills
  are deterministic. Regression-tested with three consecutive
  restores.
- **`OBS_LOG=""` did not disable logging** as documented:
  `${OBS_LOG:-…}` treated an empty value as unset and kept writing the
  default log file. An explicitly empty `OBS_LOG` now disables logging
  everywhere (writes, rotation and `log --json`'s `log_file: null`).

### Tests

- The functional suite grows from 189 to **225 assertions** (sections
  32–33): `log --json` document shape, requested-count handling,
  non-numeric tolerance, disabled-log contract, unpinned-vault JSON
  purity and lock-freedom; apply-mode `restore --json` consent /
  targeting / empty-dir / checksum / corrupt-stream / tar-slip
  (deterministic python-built symlink archive) / lock-busy / happy-path
  document contracts, global `-y` consent, and the same-second
  collision regression.

## [9.0.0] — Every operational command speaks JSON

### Added

- **`verify --json`** — a backup audit emits one stable document:
  `result`, `backup_dir`, `total` / `passed` / `failed` counters and an
  `archives[]` array with a `{ "name", "status": ok|corrupt,
  "size_bytes", "sidecar", "sidecar_ok": true|false|null }` row per
  stored archive — scheduled audits can alert on the exact corrupt
  archive by name instead of scraping terminal text. A missing sidecar
  is not a failure (`sidecar_ok` is `null`, mirroring the human
  contract); exit codes are unchanged (`0` all verified or nothing to
  verify, `1` any corrupt archive) and the failure code is
  `verification_failed`. Read-only and lock-free — safe to run
  mid-sync.
- **`health --json`** — the deep repository integrity check becomes a
  machine-readable document: always the same seven `checks[]` rows
  (`git`, `repository`, `head`, `object_database`, `safe_state`,
  `remote`, `identity`; stages skipped by an earlier failure are
  reported as `info` "Not checked" rows so dashboards can index them
  positionally) plus a `statistics` block (`commits`, `tracked_files`,
  `git_size_bytes`, `free_space_bytes` — byte-exact, `null` when
  unknown). The exit code mirrors the human contract: warnings already
  fail automation with `result: "error"` + `health_issues`, hard
  failures carry `health_failed`. Read-only and lock-free.
- With this release nine operational commands (status, sync, pull,
  push, quick, backup, verify, health, doctor — plus the existing
  restore --list inventory) offer a machine-readable mode under one
  guarantee: a `--json` command always emits a parseable document on
  stdout.
- `--json` offered for `verify` and `health` in the bash and zsh
  completions; `help`, both completion files and the README command
  reference updated to v9.0.0.
- docs/TROUBLESHOOTING.md: the machine-readable contract table now
  covers all nine `--json` commands, the error-code table gains
  `verification_failed`, `health_failed` and `health_issues`, plus a
  `health --json` jq one-liner and a stale-ref tip.

### Fixed

- **health misreported healthy repositories as corrupted** after a
  user removed (and possibly re-added) their remote: `git remote
  remove` can leave `refs/remotes/origin/HEAD` behind as a broken
  null-sha ref (a git symref-deletion quirk), fsck then exited
  non-zero with "invalid sha1 pointer", and health announced
  "Repository corruption detected" — recommending a needless full
  `repair`. The fsck probe is now a shared helper
  (`fsck_object_db`) used by both report modes: when every fsck error
  names a stale `refs/remotes/*` invalid pointer, health reports a
  precise warning with the surgical fix
  (`git update-ref -d <ref>`), while any real object error still
  fails hard.

### Tests

- Suite grew 166 → 189 assertions (sections 30/31): verify document
  shape (counters, per-archive rows, sidecar semantics), empty-dir
  contract, corrupt-archive error document, legacy `-y` compatibility
  and fail-closed flag validation for both commands; health document
  shape (seven stable rows, statistics), warn contract via a missing
  remote, deterministic stale-ref regression (warn, never corruption,
  in both modes), missing-repository fail contract with "Not checked"
  info rows, lock-freedom, JSON purity with an unpinned vault, and
  unchanged human output for both commands.

## [8.9.0] — Machine-readable backups & diagnostics

### Added

- **`backup --json`** — a manual backup emits one stable, JSON-escaped
  document (`version`, `command`, `result`, `backup` with `name`, `path`,
  `size_bytes`, `sidecar`, `sidecar_ok`, `elapsed_seconds`, `error`), so
  scripted snapshots can verify their own output (checksum included)
  instead of scraping terminal text. Exit codes unchanged (`0` = created,
  `1` = failed, `2` = lock contention); failures carry `backup: null` and
  a stable machine code (`backup_failed`, `vault_missing`, `lock_busy`).
- **`doctor --json`** — the full diagnostic report becomes a
  machine-readable document: every check (platform, tools, storage,
  vault, backup directory, filesystem topology, remote reachability,
  remote default branch, watchdogs, free space) is a
  `{ "name", "status": ok|warn|fail|info, "message" }` row in a
  `checks[]` array, with top-level `platform`, `remote` and
  `default_branch` fields. `result` is `"error"` (and the exit code `1`)
  iff any check failed; warnings keep exit `0`, matching the human
  report. Strictly read-only — it never creates the backup directory,
  so it is safe to run from monitoring jobs.
- `--json` offered for `backup` and `doctor` in the bash and zsh
  completions.
- docs/TROUBLESHOOTING.md: the machine-readable contract table now covers
  all seven `--json` commands, the error-code table gains `lock_busy`
  (with the rc-2 contract explained), plus a lock-aware cron wrapper and
  a `doctor --json` jq one-liner for surfacing warn/fail rows.

### Fixed

- **Lock contention broke the JSON contract**: `sync|pull|push|quick
  --json` while another instance held the lock exited with rc 2 and left
  stdout completely empty — exactly the failure mode the 8.7.0/8.8.0
  environment-guard work eliminated for broken environments. `with_lock`
  now emits a parseable `{"result": "error", "error": {"code":
  "lock_busy", "message": …}}` document in machine mode (and the
  matching `backup` document shape for `backup --json`), so the
  guarantee "a --json command always emits a document on stdout" now
  covers the entire pipeline — environment and lock included. Human
  mode is unchanged.
- Key/value UI lines (`kv`) could leak onto stdout in machine mode (they
  were never covered by `SILENT_UI` because earlier JSON commands did
  not use them) — they are now demoted to the log file like all other
  human UI, keeping `backup --json` output byte-pure JSON.
- `backup` previously ignored every argument silently (the dispatcher
  never forwarded them); flags are now parsed — `--json` works, unknown
  flags fail closed (rc 1) with the same contract as sync/restore/cron,
  and `backup -y` stays a documented no-op for muscle memory.

### Tests

- Suite grew from 141 to **166 assertions**: backup document shape
  (name/path/size/sidecar/sidecar_ok/elapsed), legacy `backup -y`,
  `--bogus` rejection, `vault_missing` and `backup_failed` documents,
  backup JSON purity with an unpinned vault; the lock-contention
  contract for all five locked JSON commands (rc 2 + parseable
  `lock_busy` documents); and the doctor report shape (all check rows,
  statuses, reachable local remote with `default_branch: main`,
  same-filesystem topology warning), its read-only behavior (no backup
  directory creation), graceful missing-vault degradation (warn row,
  rc 0), the unwritable-vault failure contract (fail row, `result:
  "error"`, rc 1) and `--bogus` rejection.

## [8.8.0] — One JSON contract for every operation

### Added

- **`pull --json`, `push --json` and `quick --json`** join `sync --json`:
  all four data operations now emit the same stable, JSON-escaped
  document (`version`, `command`, `result`, `branch`, `remote`, `pulled`,
  `pushed`, `committed_files`, `conflicts`, `backup`, `backup_skipped`,
  `elapsed_seconds`, `error`) — one parser covers every automation hook,
  cron wrapper and CI job. `pull` always reports `pushed: 0`, `push`
  always `pulled: 0`. The exit-code contract is unchanged (`0` = success,
  `1` = failed) and failures keep carrying stable machine codes
  (`git_missing`, `vault_missing`, `repository_unsafe`, `no_remote`,
  `commit_failed`, `fetch_failed`, `conflict`, `rebase_failed`,
  `push_failed`, `backup_failed`).
- **Guaranteed-parseable JSON everywhere**: the environment guards moved
  from the dispatcher into the command wrappers (the pattern `sync`
  introduced in 8.7.0, now shared via `op_env_guard`), so all four
  commands answer with an error document even on a broken environment.
- `quick --json` reports its own verified backup as the operation's
  `backup` with `backup_skipped: false` — previously the quick backup
  would have been hidden behind the internal pre-sync skip flag, and
  scripts would have seen `backup: null` despite a fresh verified
  archive on disk. Even a failing `quick` (unreachable remote) now
  reports both the backup it made and the reason it failed.
- `--json`/`-y` offered for `pull`, `push` and `quick` in the bash and
  zsh completions.
- docs/TROUBLESHOOTING.md: the machine-readable contract table and the
  error-code table now cover all four operations, plus a note that the
  example cron wrapper works unchanged for every `--json` operation.

### Fixed

- A cosmetic blank line from the sync summary leaked onto stdout in
  `sync --json` (and would have done so in `quick --json`) — Python's
  `json.load` tolerated it, but strict parsers should not have to.
  Machine mode now suppresses even whitespace ahead of the document.

### Tests

- Suite grew from 123 to **141 assertions**: shared document-shape
  checks for pull (up-to-date and integrating), push, and quick
  (including the `quick-*` backup contract); legacy `-y` compatibility
  for pull/push; `--bogus` rejection for all three; `vault_missing`
  pull documents; `push_failed` from an unreachable remote; a failing
  quick that still reports its verified backup; and JSON purity with
  an unpinned vault.

## [8.7.0] — Machine-readable sync & storage advice

### Added

- **`sync --json`** — the full sync pipeline (check → backup → commit →
  fetch → rebase → push) emits one stable, JSON-escaped document on
  stdout: `result` (`ok`/`error`), `branch`, `remote`, `pulled`,
  `pushed`, `committed_files`, `conflicts`, `backup` (name or `null`
  when skipped), `backup_skipped`, `elapsed_seconds` and `error`.
  The exit-code contract is unchanged (`0` = synced, `1` = failed), and
  failures are data: every error document carries a stable machine
  `code` (`repository_unsafe`, `no_remote`, `backup_failed`,
  `commit_failed`, `fetch_failed`, `conflict`, `rebase_failed`,
  `push_failed`, `git_missing`, `vault_missing`) plus a one-line
  message, so cron wrappers and CI branch on content instead of
  scraping terminal output.
- **Guaranteed-parseable JSON**: the environment guards for `sync`
  moved from the dispatcher into the command itself, so `sync --json`
  answers with an error document (`git_missing` / `vault_missing`)
  even on a broken environment — machine consumers are never left
  with an empty stdout and only a stderr hint.
- **doctor storage-topology check**: when the backup directory lives
  on the same filesystem as the vault, doctor now warns that a single
  disk failure could destroy both, with the `OBS_BACKUP_DIR` fix
  (filesystem detection via POSIX `df -P`, identical on GNU/BSD).
- `--json` offered for `sync` in the bash and zsh completions.
- docs/TROUBLESHOOTING.md: a "Machine-readable modes" section with the
  full `sync --json` error-code table (meaning + first aid per code)
  and a ready-made jq cron wrapper.

### Fixed

- `ob-sync sync -y` and other pre-8.7.0 argument habits would have
  been rejected by the new strict flag parser (`Unknown option for
  sync: -y`). `-y` is accepted again as the no-op it always was for
  sync, while genuinely unknown flags now fail closed (rc 1) —
  matching the `restore`/`cron` contract — instead of being silently
  ignored like before.
- A conflict during `sync --json` (or any human-mode rebase) printed
  the conflicting file list straight to stdout, which would have
  polluted the JSON document. The list is now logged in machine mode.

### Tests

- Suite grew from 111 to **123 assertions**: the ok-path document
  shape (result/counts/backup/elapsed), `OBS_SKIP_BACKUP=1` reflected
  as a real boolean, legacy `sync -y` compatibility, `--bogus`
  rejection, unreachable-remote → `fetch_failed` document, the
  two-device divergence → `conflict` document (with the local commit
  preserved and a recovery sync), and the missing-vault document
  (parses, rc 1, stable code).

## [8.6.0] — Machine-readable everything (JSON status growth, JSON backups, zsh)

### Added

- **`status --json` grew three sections** — one document now answers
  every dashboard question:
  - `watchdogs`: active network (`OBS_GIT_TIMEOUT`) and local
    (`OBS_LOCAL_TIMEOUT`) timeouts in seconds;
  - `cron`: whether a crontab command exists (`available`), whether an
    ob-sync schedule is installed (`scheduled`), the exact installed
    job line (`job`, JSON-escaped) and the cron log path (`log`);
  - `config`: the config file path, whether it exists and — the classic
    "*why is it syncing THAT folder?*" answer — `vault_source`, reporting
    exactly how the vault was resolved (`environment`, `config file`,
    `auto-detected`, `selected` or `default`).
- **`restore --list --json`** — machine-readable backups. Without a
  target it emits a verified inventory of the whole backup directory
  (name, path, exact `size_bytes`, embedded timestamp, mtime, sidecar
  presence and the real `sidecar_ok` SHA-256 verdict), newest first.
  With a target it runs the full preview pipeline (stream check,
  sidecar checksum, tar-slip member audit) and renders the archive's
  member/file/directory/note counts and top-level layout as JSON.
  Failures are parseable too: a corrupt or unsafe archive returns
  `{ "error": ... }` with exit code `1`, and an empty backup directory
  is valid data (`"count": 0`, exit `0`).
- **zsh completion** (`completions/_ob-sync`) — every command,
  subcommand, schedule preset and flag, mirroring `ob-sync help`.
  Install instructions for plain zsh, oh-my-zsh and Termux are in the
  README.
- bash completion: `--json` offered for `restore`.

### Fixed

- The UI-suppression mode that keeps JSON output pure (introduced for
  `status --json` in 8.5.0) now also covers `restore --list --json`,
  so vault auto-detection notices can never pollute the backup
  inventory on stdout. Covered by a dedicated regression test
  (auto-detected vault, unpinned config, output must parse).
- `cron status` and `status --json` now share one job-line extractor,
  so the human view and the machine view can never disagree about
  what is installed.

### Tests

- Suite grew from 98 to **111 assertions**: JSON shape checks for the
  three new status sections, cron-state mirroring (installed →
  `scheduled: true` + job line; wiped → `false`), inventory and preview
  parsing for `restore --list --json`, the empty-directory contract,
  `--json`-without-`--list` rejection and the corrupt-archive error
  document.
- **Hardened suite bootstrap**: a broken inherited `TMPDIR` (deleted
  directory, full disk, unwritable mount) used to cascade into dozens
  of nonsense assertion failures, because the sandbox was created
  before the environment was sanitized. The suite now fails fast with
  a single clear fatal message naming the offending `TMPDIR`.

## [8.5.0] — Scheduled syncs, config editing & the local watchdog

### Added

- `ob-sync cron` — first-class cron management for scheduled syncs:
  `cron install <schedule> [HH:MM]` writes an idempotent,
  marker-delimited block into the user crontab (presets `15min`,
  `30min`, `hourly`, `daily [HH:MM]`, or any raw 5-field expression),
  so enabling automatic syncing no longer means hand-editing crontabs.
  The managed job pins the absolute ob-sync path and the current
  `PATH` (a cron environment inherits neither), appends output to a
  dedicated cron log, and warns up front when no remote or vault is
  configured yet. `cron status`, `cron show` and `cron uninstall`
  (consent-guarded, `-y` for scripts) complete the set; Termux users
  get a `cronie` / `termux-services` hint when no cron daemon exists.
- `ob-sync edit-conf` — opens the per-machine config file in `$EDITOR`
  (falls back to `VISUAL`, then `vi`), creating a commented starter
  template on first use. Refuses to launch an editor without a
  terminal and points at the file path instead.
- **Local watchdog** (`OBS_LOCAL_TIMEOUT`, default 600 s, `0` disables):
  tar archiving and extraction, SHA-256 hashing and `git fsck` now run
  under a timeout, so a vault or backup directory stranded on a dead
  FUSE/NFS mount can no longer hang a backup, restore or verification
  forever. A watchdog trip is reported as such — not mislabeled as
  corruption.
- Interactive menu: new `16) Cron` and `17) EditConf` entries.
- README ships a real terminal capture of the TUI (`docs/menu.svg`)
  and a "Scheduled Syncs" guide under Automation.
- `tests/run-tests.sh` is now ShellChecked in CI as well, matching the
  local gate.

### Fixed

- **`status --json` was not pure JSON when the vault was auto-detected.**
  With no `OBS_VAULT` and no pinned config (a fresh machine, or a
  dashboard consumer), setup()'s "Auto-detected vault:" info line was
  printed to stdout ahead of the JSON document, breaking every parser.
  User-facing info/warn lines are now suppressed in JSON mode — and
  still written to the log file. Covered by a new regression test.
- Caught during development by the new tests: `ob-sync help` crashed
  with an "unbound variable" error for every user without `$EDITOR`
  set (a `$EDITOR` reference in the new help text expanded under
  `set -u`); `cron uninstall -y` ignored the `-y` flag when it
  followed the subcommand. Both fixed before release; neither
  existed in 8.4.0.

### Changed

- The functional suite grew from 75 to 98 assertions. The cron
  lifecycle is covered end-to-end against a deterministic crontab
  emulator (no real cron daemon, no root, no host crontab access),
  including idempotent replacement, raw expressions, PATH pinning and
  consent refusals.

## [8.4.0] — Safe restore previews & automation hooks

### Fixed

- **Scripted restores silently did nothing — and reported success.**
  `ob-sync restore <target> -y` never parsed the `-y` flag: on a
  non-interactive session the confirmation prompt read EOF, took the
  "Cancelled" path, and still exited `0` — the vault stayed broken while
  cron/Tasker/CI believed the restore had succeeded. Restore now parses
  its own flags, honors `-y` in any position, and actually restores.
- Restore is now **fail-closed** when it cannot ask for consent: a
  non-interactive restore without `-y` refuses with exit `1` and points
  at `-y` / `--dry-run`, instead of silently cancelling with exit `0`.
- **`restore latest` could pick a same-second older backup.** Archives
  are ordered by the timestamp embedded in their filename; for archives
  created within the same second (common: `quick` → `sync` back-to-back)
  the filename was the only tie-breaker, letting an older `pre-sync-*`
  outrank the newer `manual-*`. Full-precision mtime now breaks ties
  (GNU nanoseconds, BSD seconds, graceful fallback), stabilizing both
  `restore latest` and retention pruning. Caught by an intermittently
  failing test run and covered by a new deterministic regression test.
- The functional suite's restore assertion was vacuous (it passed even
  when the restore changed nothing); it now deletes a file first and
  requires it to come back.

### Added

- `ob-sync restore --list [target]` — read-only backup inspection:
  stream + SHA-256 sidecar verification, full tar-slip audit, member
  counts (files/directories/notes), compressed size and the top-level
  layout. Without a target (and without a terminal) it inventories the
  available backups.
- `ob-sync restore --dry-run [target]` — rehearses the entire restore
  pipeline (verify → audit → numbered execution plan) and guarantees
  nothing was modified.
- `ob-sync status --json` — machine-readable status document with a
  stable field shape, JSON-escaped strings, real booleans and `null`
  for unknown values (`git.remote`, `git.last_commit`, `last_sync`).
  Designed for dashboards, cron monitors and `jq` pipelines.
- Bash tab-completion for every command and flag
  (`completions/ob-sync.bash`, also covered by CI's ShellCheck gate).
- The interactive menu grew `13) Diff`, `14) Config` and `15) Remote`
  entries — phone users no longer need the keyboard-heavy CLI for
  read-only insight commands.
- GitHub Release automation (`.github/workflows/release.yml`): a `v*`
  tag push verifies the tag matches the `VERSION` constant, runs the
  full test suite, extracts the matching CHANGELOG section as release
  notes, and publishes the release with the core script + checksum
  attached.

## [8.3.0] — Insight commands & in-repo test suite

### Added

- Three read-only insight commands:
  - `ob-sync diff` — pending working-tree changes with human labels
    (staged / modified / untracked / CONFLICT) and a compact diff stat.
  - `ob-sync history [n]` — the last n vault commits with relative dates
    (handles fresh repositories gracefully).
  - `ob-sync config` — the effective configuration: every value plus
    where it came from (environment / config file / origin), the config
    file contents, and watchdog status. The "why is it syncing THAT
    vault" debugging aid.
- `ob-sync sync` now reports its elapsed time in the final summary.
- The repository ships its own functional test suite
  (`tests/run-tests.sh`): self-contained sandbox with a local bare
  remote, two simulated devices, conflict/corruption/lock/cron
  scenarios — 60 assertions, no network required. Wired into CI as a
  dedicated job alongside ShellCheck and markdownlint.

## [8.2.0] — First-run correctness & bring-your-own remote

### Added

- `ob-sync remote [url]` — shows the effective remote URL or sets a new one,
  persisting it to the per-machine config and updating the vault's `origin`.
- `ob-sync init` now asks for the remote repository URL when nothing is
  configured (environment, config file, or an existing `origin`), so a
  brand-new setup needs zero environment variables.
- The config file now stores `REMOTE` and `BRANCH` alongside `VAULT`;
  cron jobs and non-login shells resolve the exact same settings.
- Installers verify `tar` and a SHA-256 tool and print actionable hints.

### Fixed

- **First sync on an empty remote always failed.** `init` against a fresh
  (commit-less) remote leaves HEAD unborn; `check_repo_safe` treated that
  as corruption, so every subsequent `sync`/`pull`/`push` aborted with
  "Repository still unsafe — run: ob-sync repair". An unborn HEAD is now
  recognized as a legitimate safe state (the same leniency applied in
  `health`), and the fresh-user path `init → sync` works end to end.
- `init` never pinned a freshly *cloned* vault in the config file — only
  pre-existing vaults were pinned, so clones outside the auto-scan roots
  could resolve to the wrong vault in cron shells. Clones are now pinned.
- `git symbolic-ref HEAD` failure inside `init` was silently ignored.
- `organize` counted notes inside `.trash/` as empty notes.
- `doctor` misreported an empty-but-reachable remote as unreachable
  (`ls-remote --exit-code` returns 2 for a repository without refs); the
  default-branch check now runs only when a remote is configured.
- Repair staging tolerated filesystems that refuse permission preservation
  (`cp -a` falls back to `cp -R`).
- Dependency check in `setup` covered `date`, `awk`, `sed`, and `head`
  only implicitly; they are now verified explicitly.
- `repair` clone failure message no longer hides the "empty remote" cause.

### Changed

- **BREAKING:** the built-in default remote (a hard-coded personal
  repository) is gone. `REMOTE` now resolves as `OBS_REMOTE` > config file
  > the vault's `origin`; with none set, `init` prompts and `repair`
  explains exactly what to run.
- Default vault path generalized to `~/Documents/Obsidian`
  (`~/storage/shared/Documents/Obsidian` on Termux) instead of a personal
  directory name.
- `ensure_origin` self-heals: when the URL is known, a missing `origin`
  remote is re-added automatically instead of failing the run.

## [8.1.0] — Vault resolution for real-world machines

### Added

- Persistent per-machine vault config (default: ~/.config/ob-sync/config, override via OBS_CONFIG): ob-sync init now confirms the vault and saves it, so every later run — cron and non-login shells included — resolves the same vault without shell profile exports.
- Vault auto-detection: with no OBS_VAULT and no config, common roots are probed for directories containing .obsidian/; a unique hit is adopted, several hits open an interactive picker.
- Strict resolution precedence (OBS_VAULT > config file > auto-detection > platform default); ob-sync doctor reports which source resolved the vault.

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
- Backup engine: in-function diagnostics must go to stderr — make_backup runs inside command substitution, so the tar-warning notice printed to stdout was captured into the return value and never displayed; now redirected (>&2).
- README: rebase resolution had glued the agent's new hero heading onto the original tagline (MD022) and the tagline's trailing period tripped MD026; resolved to a single tagline, converted from H3 to bold emphasis — semantically a tagline, and MD036 is already off for hero emphasis by design.
- README follow-up: the rebase conflict had been saved with raw markers still embedded — committed and pushed, they rendered as literal text on GitHub (and, as two adjacent headings, were the real cause of the MD022 failures); markers and the redundant short tagline removed, hero block squeezed to one tagline + one subtitle.
- README: agent-redesigned hero kept (alerts, colored mermaid, comparison table — genuinely better), but fixed three markdown-mangled URLs inside code fences that broke copy-paste install commands, and corrected the Temp-Registry wording — SIGKILL cannot be trapped; its artifacts are reclaimed on the next run, not on exit.
- README tail: the MD047 fix over-applied — a stray blank line landed before EOF and tripped MD012 (the linter counts one trailing blank as two); tail normalized to content + exactly one final newline.
- Backup engine: tar stderr is now captured and classified — exit >= 2 fails with the underlying message shown verbatim; exit 1 (warnings, e.g. "file changed as we read it" while the Obsidian app writes workspace.json on-device) is tolerated because the full-stream verification remains the integrity gate.
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
