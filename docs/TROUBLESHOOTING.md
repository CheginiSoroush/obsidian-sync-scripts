# Troubleshooting

A quick symptom → fix index first, deep dives after. When in doubt, run
`ob-sync doctor` — it diagnoses the environment — and `ob-sync health`,
which diagnoses the repository.

## Quick index

| Symptom | Most likely fix |
| --- | --- |
| `Another instance is running (PID: …)` | Wait for it to finish; if the PID is dead, remove `"${TMPDIR:-/tmp}/obs-sync.lock"` |
| `Repository not in a safe state` | Run the operation again — self-healing kicks in. If it persists: `ob-sync repair` |
| `Merge conflict detected` | See [Conflicts](#conflicts) |
| `Fetch failed` / `Push failed` | Network or credentials — see [Authentication](#authentication) |
| `Vault not found: …` | `OBS_VAULT` points nowhere → `ob-sync init` |
| ob-sync syncs a different vault than my editor has open | Run `ob-sync doctor` — it reports the resolution source; pin the right one via `ob-sync init` |
| A backup fails `ob-sync verify` | Storage corruption — delete the bad archive; verified ones remain |
| Terminal hangs during network ops | The watchdog needs `timeout` — preinstalled on Termux/Linux; macOS: `brew install coreutils` |
| `Remote default branch is 'master'` | `export OBS_BRANCH=master`, or rename the remote branch |
| `sync --json` output is empty or not parseable | stdout always carries the document — check stderr for the human error; see [Machine-readable modes](#machine-readable-modes---json) |
| Another ob-sync instance is running (rc 2) | wait for it to finish; JSON modes still answer with a parseable `lock_busy` document |

## The lock

`ob-sync` serializes every mutating operation with a PID-based lock. If the
process dies, the lock survives but its PID is dead — the next run detects
this via `kill -0` and reclaims it automatically. Manual removal is almost
never needed:

```bash
rm -rf "${TMPDIR:-/tmp}/obs-sync.lock"
```

## Not in a safe state

This means an interrupted rebase/merge, or a stale `index.lock`. The next
`sync`/`pull`/`push` attempts automatic recovery (aborting the operation,
removing the lock only when no live git process owns the vault). If recovery
fails, `ob-sync repair` rebuilds the metadata from the remote — your files
are never touched.

## Conflicts

When the same note changed on two devices, the rebase is aborted cleanly:

- The conflicting files are listed — nothing is merged, nothing is lost.
- Fix the note on one device (or in any editor), sync that device, then
  sync the other.

```bash
ob-sync status   # see how far ahead/behind you are
ob-sync sync     # retry after resolving
```

## Authentication

For **private** repositories, authenticate once; the credential is cached
by git itself:

```bash
git config --global credential.helper store
git ls-remote https://github.com/you/private-vault.git   # enter your PAT once
```

`ob-sync doctor` probes the remote and prints exactly this hint when it
cannot reach it.

## Machine-readable modes (`--json`)

Thirteen commands own stdout exclusively when `--json` is passed, in every
environment — auto-detected vaults, stale locks and missing vaults included:

| Command | Success | Failure |
| --- | --- | --- |
| `status --json` | full status document, rc 0 | n/a (always rc 0) |
| `sync --json` | `{ "result": "ok", … }`, rc 0 | `{ "result": "error", "error": { "code", "message" } }`, rc 1 |
| `pull --json` / `push --json` / `quick --json` | the same document shape with `command` set accordingly, rc 0 | the same error shape, rc 1 |
| `backup --json` | backup result document (name, size, sidecar state), rc 0 | `{ "backup": null, "error": … }`, rc 1 |
| `restore --list --json` | inventory / preview document, rc 0 | `{ "error": … }`, rc 1 |
| `restore --json <target> -y` | apply result document (archive, safety_backup, previous_vault, elapsed), rc 0 | `{ "result": "error", "error": { "code", "message" } }`, rc 1; lock contention → `lock_busy`, rc 2 |
| `verify --json` | per-archive audit rows + total/passed/failed, rc 0 | `archives[]` names the corrupt rows, `error.code` = `verification_failed`, rc 1 |
| `health --json` | checks-array report + statistics, rc 0 | warnings → `health_issues` rc 1; hard failure → `health_failed` rc 1 |
| `doctor --json` | checks-array report, rc 0 (warnings stay rc 0) | `"result": "error"` when any check failed, rc 1 |
| `log --json [n]` | activity document (`entries[{timestamp, source, message}]`), rc 0 — a missing log is valid empty data | `{ "error": { "code": "log_unreadable", … } }`, rc 1 (existing file unreadable) |
| `history --json [n]` | commit document (`commits[{hash, date, author, subject}]`), rc 0 — a fresh repo is valid empty data | `{ "error": { "code": "history_unreadable", … } }`, rc 1 (repository unreadable) |
| `organize --json [--fix]` | audit document (scan counters, untitled/empty/oversized, orphans; with `--fix`: `moved`/`skipped` rows), rc 0 | `{ "result": "error", "error": { "code", … } }`, rc 1 (`scan_failed`, `attach_dir_create_failed`); lock contention → `lock_busy`, rc 2 |

One document shape for all four data operations: a single parser covers
every automation hook. `pull` always reports `pushed: 0`, `push` always
`pulled: 0`, and `quick` reports its own verified backup as the
operation's `backup` — even when the sync part then fails.

Human-readable diagnostics are never mixed into the document — they go to
**stderr** and the log file, so `ob-sync sync --json 2>>sync.err` gives you
both a parseable result and an audit trail.

Stable error codes for all four data operations, `backup --json`,
`restore --json` (apply mode), `verify --json`, `health --json`,
`log --json`, `history --json` and `organize --json`
(branch on the code, not the message):

| Code | Meaning | First aid |
| --- | --- | --- |
| `git_missing` | git is not installed | `ob-sync doctor` prints the install hint |
| `vault_missing` | vault path does not exist | `ob-sync init` |
| `lock_busy` | another ob-sync instance holds the lock (rc 2) | wait for the other run; check `ob-sync log` |
| `repository_unsafe` | interrupted git state | rerun (self-heals) or `ob-sync repair` |
| `no_remote` | origin not configured | `ob-sync remote <url>` |
| `backup_failed` | pre-sync or manual backup failed | check disk space; `ob-sync doctor` |
| `commit_failed` | could not commit local changes | `ob-sync doctor`, check vault permissions |
| `fetch_failed` | network or credentials | see [Authentication](#authentication) |
| `conflict` | same note changed on two devices | see [Conflicts](#conflicts) |
| `rebase_failed` | rebase failed without a conflict | `ob-sync repair` |
| `push_failed` | network or credentials, commits preserved | retry `ob-sync push` |
| `verification_failed` | `verify --json` found a corrupt archive | `jq -r '.archives[] \| select(.status == "corrupt") \| .name'` names it; `ob-sync repair` rebuilds, backups stay untouched |
| `target_required` | `restore --json` (apply) ran without a target — JSON mode never guesses | pass `'latest'`, an archive name or a path |
| `consent_required` | `restore --json` (apply) ran without `-y` — JSON mode cannot prompt | add `-y` (before or after the command) |
| `no_backups` | the backup directory is empty | create one: `ob-sync backup` |
| `backup_not_found` | the requested restore target does not exist | `ob-sync restore --list --json` lists what is available |
| `archive_corrupt` | the archive stream failed a full read | delete the archive; `ob-sync verify` names the damaged ones |
| `checksum_mismatch` | the SHA-256 sidecar does not match the archive | delete the archive; the sidecar protects you from a tampered restore |
| `unsafe_archive` | a member failed the tar-slip audit (absolute path, `..`, symlink/special) | do **not** extract this archive; inspect with `tar -tvzf` |
| `extraction_failed` / `extraction_timeout` | tar could not extract (disk full, hung storage, watchdog trip) | check free space; tune `OBS_LOCAL_TIMEOUT` |
| `symlink_detected` | a symlink appeared during extraction (defence in depth) | the vault was untouched — inspect the archive |
| `swap_failed` | the atomic vault swap failed | nothing was replaced; check permissions on the vault's parent directory |
| `safety_backup_failed` | the pre-restore safety backup failed | nothing was replaced; check disk space, then `ob-sync doctor` |
| `log_unreadable` | `log --json` found the log file but could not read it | check permissions on `$OBS_LOG` |
| `history_unreadable` | `history --json` could not read the repository (not a repo, or corrupt) | `ob-sync repair`; a repo without commits is valid empty data instead |
| `scan_failed` | `organize --json` could not create its scan temporary | check `$TMPDIR` free space and permissions |
| `attach_dir_create_failed` | `organize --fix` could not create the attachments folder | check permissions on the vault directory |
| `health_failed` | `health --json` found a hard integrity failure | run `ob-sync health` for the human report; `ob-sync repair` |
| `health_issues` | `health --json` found warnings only (missing remote/identity, unsafe state, stale ref) | check the `checks[]` rows — each message carries the fix |

Example cron wrapper:

```bash
if out=$(ob-sync sync --json); then
    printf 'synced: %s in, %s out\n' \
        "$(jq -r .pulled <<<"$out")" "$(jq -r .pushed <<<"$out")"
else
    code=$(jq -r .error.code <<<"$out")
    echo "sync failed: $code" >&2
    [[ "$code" == "conflict" ]] && notify-send "Vault conflict needs you"
fi
```

The same wrapper works unchanged for `pull --json`, `push --json`,
`quick --json` and `backup --json` — the `command` field tells you which
operation produced the document. Even a contended lock (rc 2, another
instance running) now answers with a parseable document:

```bash
out=$(ob-sync sync --json); rc=$?
if (( rc == 2 )); then
    echo "skipped: $(jq -r .error.message <<<"$out")"   # lock_busy
elif (( rc != 0 )); then
    echo "sync failed: $(jq -r .error.code <<<"$out")" >&2
fi
```

`doctor --json` reports every diagnostic as a `{ "name", "status",
"message" }` row (`ok` / `warn` / `fail` / `info`): `result` is `"error"`
and the exit code `1` iff any check failed, while warnings keep exit `0`.
It is strictly read-only (it never creates the backup directory), so it is
safe to run from monitoring jobs:

```bash
ob-sync doctor --json | jq -r '.checks[] | select(.status == "warn" or .status == "fail") | "\(.status): \(.name)"'
```

`health --json` is the repository-integrity counterpart: always the same
seven rows (`git`, `repository`, `head`, `object_database`, `safe_state`,
`remote`, `identity` — stages skipped by an earlier failure become `info`
"Not checked" rows) plus a `statistics` block (commits, tracked files,
`.git` size, free space). Warnings already exit `1` with code
`health_issues` — exactly like the human report's "N issue(s) detected".
It is read-only and never takes the PID lock, so monitoring can audit a
vault mid-sync:

```bash
ob-sync health --json | jq -r '"result: " + .result, (.checks[] | "\(.status): \(.name)")'
```

> [!TIP]
> `health` reports a stale `refs/remotes/origin/HEAD` (left behind by
> `git remote remove`) as a **warning with a surgical fix** —
> `git update-ref -d refs/remotes/origin/HEAD` — never as "corruption".
> Only real object-database errors recommend `ob-sync repair`.

## Repair walkthrough

`ob-sync repair` is safe by construction:

1. A fresh clone is created and fsck-verified — nothing local is touched.
2. A verified full backup of the current vault is taken.
3. The new `.git` is staged *inside* the vault, then installed with an
   atomic same-filesystem rename; any failure rolls the original back.
4. Remote files missing locally are restored — additively, never
   overwriting local edits.

## Restore walkthrough

```bash
ob-sync verify            # audit every archive first
ob-sync restore           # interactive picker (newest first)
ob-sync restore latest    # or the newest verified backup directly
```

Before replacing anything, `restore` takes a safety backup of the current
vault, verifies the target archive's checksum, and audits every archive
member for path traversal (tar-slip protection). The previous vault is kept
next to the new one until you delete it manually.

Scripted DR drills get the same pipeline as data: `ob-sync restore --json
latest -y` returns a result document (`result`, `archive`,
`safety_backup`, `previous_vault`, `elapsed_seconds`, `error{code,
message}`) that a drill can assert on instead of scraping terminal text —
see the error-code table above for the stable refusal codes.

## macOS notes

- **bash 4+**: `brew install bash`, then run `ob-sync` with it.
- **Network watchdog**: `brew install coreutils` (provides `timeout`),
  otherwise remote operations run without a timeout.
- Hashing uses `shasum` automatically when `sha256sum` is absent.

## Getting diagnostics

```bash
ob-sync doctor   # environment: platform, tools, storage, remote, watchdog
ob-sync health   # repository: HEAD, fsck, state, config, statistics
ob-sync log 50   # the last 50 log entries
```
