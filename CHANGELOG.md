# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versioning follows [Semantic Versioning](https://semver.org/).

## [9.5.0] — The vault carries its own identity card

Proposal-turned-feature from the same field report that produced 9.4.2:
a vault that has never been connected is a mystery to every command that
needs a remote, and the machine-wide config file is the wrong place to
solve that — it describes the DEVICE, not the vault. So the vault now
describes itself.

### Added

- **Vault identity card: `<vault>/.ob-sync/config`** — after `init` (or
  `ob-sync remote <url>`) the vault's own REMOTE and BRANCH are written
  into a small hidden file inside the vault, in the same KEY=VALUE format
  as the machine config. It is a normal tracked file: the first sync
  commits it, and from then on every clone already knows where it
  belongs — on a second device, `init -y <clone>` and `sync` run without
  asking a single remote question.
- **Self-healing origin** — every locked operation (sync/pull/push/
  quick/backup/restore/repair/init/remote) first re-aligns the vault's
  `origin` with its identity card:
  - `origin` missing → restored from the vault's OWN file (the exact
    field-reported accident — a vault losing its remote — now heals
    itself, and can never heal toward ANOTHER vault's repository).
  - `origin` disagrees with the file → the file wins: it traveled with
    the vault (pulled after a `remote set-url` elsewhere), so it
    expresses the vault's intent; a stale local origin is re-pointed
    with a printed notice.
- **Silent migration** — a legacy vault that has an `origin` but no
  identity card gains one from its own origin on the first locked run.
  Nothing is asked; nothing changes hands.
- **Honest refusal preserved** — a vault with NEITHER origin NOR
  identity card is still refused by sync/quick/push/pull/repair with
  `no_remote` (9.4.2 behavior); `init` remains the place that asks for
  the URL — and now also writes the card.
- **Visibility** — `status` shows an Identity row (human) and a
  `vault_config` object (`--json`); `remote` displays the card next to
  `origin`; `help` documents the new VAULT IDENTITY section.
- **Safety properties** — writes happen ONLY under the lock (read-only
  commands never mutate the vault); the card holds exactly REMOTE and
  BRANCH — never credentials, never device paths; `OBS_REMOTE` still
  outranks everything for the current run and is never rewired by the
  card.
- **Test suite: 28 new checks (section 40)** — identity written by init,
  committed to the remote, present in clones, self-healing origin,
  identity-over-stale-origin rebind, legacy migration, lockstep
  `remote set-url`, honest refusal intact, minimal/credential-free
  card, `status --json` shape, read-only purity.

## [9.4.2] — The config remote stops crossing vault lines

Field report: a user picked a vault that had never been connected to a
remote, ran `repair`, then `quick` — and watched both commands happily
work on a repository that was never chosen for that vault. Diagnosis:
`repair` had cloned ANOTHER vault's repository, swapped its `.git` into
the picked vault, restored the foreign notes, and `quick` then pushed
the picked vault's notes into the foreign repository. Two vaults, one
repo, both histories entangled — without a single confirmation.

Root cause: the config file is machine-wide and stores ONE vault's
remote, but `remote_url()`/`ensure_origin()` trusted it for whatever
vault the session happened to be running (startup picker, menu 19,
`OBS_VAULT`). Since 9.4.0 made multi-vault sessions a first-class flow,
that trust became a cross-sync hazard.

### Fixed

- **Config REMOTE/BRANCH no longer cross vault lines** — a session is
  now bound to its resolved vault (`bind_session_remote`, called at the
  end of every `resolve_vault()` path and by the menu-19 switch):
  precedence is `OBS_REMOTE` > the vault's own `origin` > config file,
  and the config file is consulted only when the session vault IS the
  config-pinned vault (`config_remote_trusted`). A vault without its own
  remote now gets an honest "This vault has no remote configured" from
  sync/quick/push/pull and "No remote repository configured" from
  repair/init — never a silent clone of someone else's repository.
- **`remote_url()` tells the push truth** — the vault's own `origin`
  now outranks the config REMOTE (origin is what `git push` actually
  targets); where they disagreed, `repair` cloned from the config value
  while sync pushed to origin.
- **Menu 19 switch warns** when the picked vault has no remote, naming
  the exact commands that will refuse and how to connect one.
- **Regression guarded both ways**: the legacy "restore a lost origin
  from the config file" behavior still works for the pinned vault (the
  documented post-`repair` path), while the same operation against a
  different vault's session is refused.

### Added

- Test suite section 39: cross-vault contamination blocked (repair and
  quick against a remote-less second vault leave the first vault's
  repository untouched), pinned-vault origin restore still works, and
  `remote` now reports the origin that would actually be pushed to.

## [9.4.1] — Network errors that speak, and stalls that end

Field report: a Termux sync reached the push, "asked for the username",
and then appeared to freeze forever. It had not frozen — every fetch and
push ran with `2>/dev/null`, so git's credential prompt was thrown away
while git sat waiting for an answer nobody could see, and an interactive
run has no watchdog (by design — prompts must be able to block).

### Fixed

- **Swallowed git stderr during sync/pull/push** — interactive runs now
  stream git's stderr, so `Username for '…'` / `Password for '…'`
  prompts are visible and answerable, and `Writing objects` progress
  shows on slow uploads. Machine runs (`--json`, cron) capture stderr
  and print `git said:` with the first lines on failure — the JSON
  document on stdout stays byte-clean (the UI helpers are already
  SILENT_UI-aware).
- **Zombie network transfers** — HTTPS fetch/push now run with
  `http.lowSpeedLimit`/`http.lowSpeedTime` (defaults: 512 bytes/s for
  60s, override via `OBS_NET_LOW_SPEED` / `OBS_NET_LOW_TIME`, `0`
  disables): a dead connection fails in about a minute with an
  actionable message instead of hanging forever. Healthy-but-slow
  uploads keep going; only truly stalled transfers are cut.
- The credential store file is created with `0600` permissions the
  moment the helper is enabled.

## [9.4.0] — A menu that follows your vaults + credentials that stick

Two field reports from daily Termux use drove this release: a second
vault was unreachable from the menu (the config pins exactly one), and
git kept demanding the GitHub token on every single sync even though it
had been typed minutes earlier.

### Added

- **Session vault switcher** — the interactive menu now starts with a
  vault picker whenever more than one vault is known (the pinned vault
  plus everything auto-discovered), preselecting the last-used one.
  New menu option **19) Switch** re-opens the picker at any time;
  typing a full path selects vaults outside the scanned roots. Picking
  a vault re-wires the session to THAT vault's own `origin` and branch,
  so two vaults with two separate remotes can never cross-sync. The
  choice is deliberately session-only: cron jobs, scripts and Tasker
  shortcuts keep hitting the pinned vault until you re-pin with 18)
  Init — the menu prompt now reads `Select an option [0-19]`.
- **Credential helper bootstrap** — `init` now detects an HTTPS remote
  with no configured git credential helper (Termux ships none) and
  offers, with explicit consent, to enable the built-in `store` helper
  so the GitHub Personal Access Token is typed once instead of on every
  sync. SSH and other non-HTTPS remotes return early; non-interactive
  runs (cron, scripts) stay completely silent — no output, no config
  writes.

## [9.3.0] — Repair that tells the truth + Init joins the menu

Field reports from Termux (a vault on Android shared storage whose
`repair` died at the atomic swap) drove both changes: make the failure
honest and recoverable, and put first-time setup where phone users
actually live — the menu.

### Added

- **Menu option 18) Init** — first-time setup is no longer CLI-only.
  The menu walks the same `cmd_init` flow the terminal always had:
  keep or change the vault path, enter the new remote URL, and ob-sync
  either links the existing vault to it (`git init` + additive
  history alignment) or clones a fresh vault when the directory is
  empty. The prompt now reads `Select an option [0-18]`.

### Fixed

- **`repair` survives a `.git` that died as a plain file** — on shared
  storage, interrupted I/O can leave `.git` as a truncated FILE or a
  stale symlink. The old swap refused to rename a directory onto a
  non-directory target and reported a bare "Failed to install repaired
  .git" with the real error swallowed. The corrupt file is now parked
  in the rollback holder with a warning, exactly like a corrupt
  directory, and the repaired repository installs cleanly (repro: the
  suite's file-`.git` scenario, section 38).
- **`repair` falls back to a copy install when the mount refuses
  rename** — some FUSE configurations reject renaming a directory
  into a freshly vacated name. The install now retries as
  `mkdir + cp + HEAD-verified` before giving up, and every failure
  path prints the operating system's own message (`mv said: …` /
  `rollback said: …` / `cp -a said: …`) instead of discarding it
  behind `2>/dev/null`. The rollback and the pre-repair backup still
  cover every path.

## [9.2.3] — The closure audit: honest failures, no dead waits

A second full line-by-line pass over every file (10 review scopes, every
suspicion repro-verified) caught the leftovers. Nothing user-visible was
broken by 9.2.2 — these are the corners only an adversarial audit reaches.

### Fixed

- **Listing timeouts are labeled truthfully again** — `tar_listing_cache`
  collapsed the watchdog's rc 124 into a generic failure, which made
  9.2.2's `extraction_timeout` mapping dead code: a slow/huge archive
  still reported `archive_corrupt`. The human preview, the JSON preview
  and the apply gate all report `extraction_timeout` now.
- **`restore` fails closed on stray arguments** — `restore <target>
  <garbage>` silently ignored the extra positional while the first one
  still drove a destructive restore. Rejected with rc 1, same contract
  as `backup`/`verify`.
- **The interactive backup pick parses base 10** — a zero-padded `010`
  was evaluated as octal and selected backup #8.
- **`doctor` makes exactly one remote call** — an unreachable remote
  burned the network watchdog up to three times (~3 × OBS_GIT_TIMEOUT
  of dead waiting; ~6 minutes at the default on a phone). One
  `ls-remote --symref` now answers reachability, empty-repository
  detection and the default branch, and the default-branch probe only
  runs when the remote actually answered.
- **A corrupted object store fails loudly** — `history` (human and
  `--json`) read `git log`'s exit status through a process substitution,
  which hid it: a corrupted repository silently reported an EMPTY
  history with rc 0. It now reports `history_unreadable` (rc 1) as the
  contract promises.
- **`log` / `log --json` observe, they never write** — `main()` created
  and stamped the activity log before dispatch, so a fresh machine's
  first `log --json` answered with ob-sync's own "invoked" row instead
  of the documented `log_file: null, count: 0` document; and on a
  >1 MiB log the same flow rotated the file first, answering with one
  junk row while the real entries moved to `ob-sync.log.1`. The `log`
  command no longer creates, stamps or rotates anything.
- **`cron install` refuses impossible schedules** — a newline inside the
  schedule expression passed validation (only the first line was read)
  and installed a rogue second job line; `%`, `\` and newlines in the
  schedule are refused outright, and a backslash in the executable/log
  path is refused too (a `\` before the escaped `%` would defeat the
  escaping and break the job silently).
- **Completions: the last global-flag leak** — the command list was laid
  out over multiple lines, and the space-delimited match only saw the
  words that ended a line (`organize`, `menu`): global flags were
  offered after them although the parser rejects them there. The list
  is flattened before matching. The zsh twin's comment now matches its
  behavior.
- **Test suite: zero host side effects** — with `XDG_CONFIG_HOME` set,
  `git config --global` wrote the sandbox identity into the user's real
  XDG git config; `GIT_CONFIG_GLOBAL` now pins every global-config
  access into the sandbox. A latent `set -u` crash in a diagnostics
  message is guarded too.

### Added

- Test section 37: 24 regression assertions covering every fix above
  (timeout labeling via a stalling tar shim, doctor call-counting via a
  git shim, corrupted-object history, fresh-machine log contract,
  >1 MiB rotation behavior, cron schedule refusals, completion matrix).

## [9.2.2] — The line-by-line audit: mobile onboarding, honest JSON & concurrency corners

### Fixed

- **The interactive HTTPS flow no longer fights its own watchdog** —
  `net()` wrapped every remote git call in the 120 s network watchdog,
  including the moments git waits for a human to answer its credential
  prompt. On Termux (GitHub over HTTPS wants a Personal Access Token,
  not the account password) the watchdog killed the live prompt
  mid-typing, which read as "the tool hangs and then exits". When stdin
  is a terminal the watchdog now steps aside; unattended runs (cron,
  scripts, `--json` pipelines) keep the strict timeout. A failed
  fetch/push against an `https://` remote additionally prints
  actionable guidance (PAT as the password, or switch to SSH via
  `ob-sync remote`).
- **`sync`/`pull` no longer lie about an unborn HEAD** — a vault that
  was re-initialized before its first commit made every `rev-list`
  against `HEAD` fail, and every failure was masked to 0: the tool
  reported "Remote has no new commits" / "Already up to date" (and
  `--json` `ok, pulled 0`) forever while the remote content never
  arrived. Both commands now adopt `init`'s materialization path
  (`reset --mixed origin/$BRANCH` + checkout of missing files) and
  report the real pulled count.
- **Rebase conflicts under the apply backend are handled too** — the
  conflict path only recognized `.git/rebase-merge`; with git < 2.26
  (or `rebase.backend=apply`) a conflict stopped in
  `.git/rebase-apply` instead, leaving the repository mid-rebase with
  raw conflict markers and emitting `"code": "rebase_failed",
  "conflicts": 0` instead of the documented `conflict` document. Both
  backends are now detected, listed and aborted cleanly.
- **`organize` no longer orphans referenced attachments with
  non-ASCII names** — the reference extractor only recognizes
  ASCII-ish basenames, so an attachment containing `+ @ # , &` or
  Persian/CJK characters was flagged as an orphan even when referenced
  verbatim — and `--fix` then moved it, silently breaking the note
  links. Files that survive the regex now get a byte-exact fallback
  search across the notes before being declared orphans.
- **A raw control byte in a filename can no longer break the JSON
  contract** — `json_escape` handled only tab/newline/CR; any other
  C0 control byte (legal on ext4) passed through raw and made the
  whole `--json` document unparseable. Every byte below 0x20 (and DEL)
  is now emitted as `\u00XX`.
- **The temp sweeper no longer leaks multi-path registrations** —
  `temp_register` appended only its first argument, so the two-file
  listing cache (names + types) leaked the `tar -tvzf` metadata
  listing on every restore preview. All arguments are registered now.
- **The lock cannot be bulldozed mid-startup anymore** — the window
  between `mkdir` and the pid write produced a pid-less lock dir that
  a concurrent run declared "stale" and removed, letting two mutating
  instances run; a late pid write then clobbered the winner. The pid
  is published atomically (mktemp + rename) and a fresh pid-less dir
  is reported as "starting up" instead of stale.
- **`config_set` refuses newline values** — a vault/remote value
  carrying a newline used to split the config file into phantom keys
  (and truncate later reads). The write fails closed instead.
- **`GIT_DIR` & friends are neutralized at startup** — exported
  `GIT_DIR`/`GIT_WORK_TREE`/`GIT_INDEX_FILE` silently redirected every
  `git -C "$VAULT"` call at a foreign repository, so the safety checks
  policed one repo while git mutated another. They are unset before
  any git call.
- **`desktop/install.sh` survives `curl | bash`** — the same
  `BASH_SOURCE[0]`-is-unset-on-stdin abort the mobile installer had was
  still present in the desktop installer; it now resolves the script
  directory only when it exists.
- **Cron blocks survive `%` and newlines** — cronie truncates a
  command at the first unescaped `%` (quotes do not protect it), so a
  `%` in the executable or log path silently broke the scheduled sync;
  a newline would split the crontab into a rogue extra job. `%` is
  escaped and newlines are refused. `config`'s cron-detection no longer
  dies of SIGPIPE on large crontabs (false "not installed").
- **`log --json` honors its own null contract** — a configured-but-
  missing log file reported a path instead of `null`, and torn
  (crash-truncated) lines reported empty strings; both now emit the
  documented `null` metadata.
- **`history --json` no longer misattributes authors whose name
  contains a tab** — fields are delimited with `%x01`, which git emits
  only as the separator, instead of a tab (legal inside a git ident).
- **Completion stops suggesting rejected flags** — global flags are
  only offered before the command word (every subcommand parser
  rejects them), and `cron status` no longer offers a `--json` the
  parser silently drops.
- **CI hygiene** — the markdownlint action moved to node24 (`v24`,
  silencing the deprecation warning every run printed), every job got
  an explicit `timeout-minutes`, and both workflows declare a
  `concurrency` group (lint supersedes outdated runs; releases never
  cancel each other).

### Tests

- 27 new assertions (292 total): unborn-HEAD integration, apply-backend
  conflict handling, unicode/`+` attachment references (scan and
  `--fix`), control-char JSON parsing, the HTTPS PAT hint, cron `%`
  escaping — plus the clone-pinned-config assertion that could
  previously pass against a stale vault.

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
