# Troubleshooting

A quick symptom → fix index first, deep dives after. When in doubt, run
`ob-sync doctor` — it diagnoses the environment — and `ob-sync health`,
which diagnoses the repository.

## Quick index

| Symptom | Most likely fix |
|---|---|
| `Another instance is running (PID: …)` | Wait for it to finish; if the PID is dead, remove `"${TMPDIR:-/tmp}/obs-sync.lock"` |
| `Repository not in a safe state` | Run the operation again — self-healing kicks in. If it persists: `ob-sync repair` |
| `Merge conflict detected` | See [Conflicts](#conflicts) |
| `Fetch failed` / `Push failed` | Network or credentials — see [Authentication](#authentication) |
| `Vault not found: …` | `OBS_VAULT` points nowhere → `ob-sync init` |
| A backup fails `ob-sync verify` | Storage corruption — delete the bad archive; verified ones remain |
| Terminal hangs during network ops | The watchdog needs `timeout` — preinstalled on Termux/Linux; macOS: `brew install coreutils` |
| `Remote default branch is 'master'` | `export OBS_BRANCH=master`, or rename the remote branch |

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
