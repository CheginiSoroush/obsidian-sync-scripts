
<div align="center">

<pre>
 ██████╗  ██████╗           ███████╗ ██╗   ██╗ ███╗   ██╗  ██████╗
██╔═══██╗ ██╔══██╗          ██╔════╝ ╚██╗ ██╔╝ ████╗  ██║ ██╔════╝
██║   ██║ ██████╔╝ ███████╗ ███████╗  ╚████╔╝  ██╔██╗ ██║ ██║
██║   ██║ ██╔══██╗ ╚══════╝ ╚════██║   ╚██╔╝   ██║╚██╗██║ ██║
╚██████╔╝ ██████╔╝          ███████║    ██║    ██║ ╚████║ ╚██████╗
 ╚═════╝  ╚═════╝           ╚══════╝    ╚═╝    ╚═╝  ╚═══╝  ╚═════╝
</pre>

**⚡ Enterprise-grade Obsidian ↔ GitHub sync — from your phone, your laptop, your anything.**

*One script. Three platforms. Zero extra dependencies. Nine layers of defense.*

[![Version](https://img.shields.io/badge/version-8.0.0-00B4D8?style=for-the-badge&logo=semver&logoColor=white)](CHANGELOG.md)
[![License: MIT](https://img.shields.io/badge/license-MIT-00C896?style=for-the-badge)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Linux%20%7C%20macOS-3DDC84?style=for-the-badge&logo=android&logoColor=white)](#-quick-start)
[![Shell](https://img.shields.io/badge/shell-Bash%204%2B-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Lint](https://img.shields.io/github/actions/workflow/status/CheginiSoroush/obsidian-sync-scripts/lint.yml?style=for-the-badge&logo=githubactions&logoColor=white&label=ShellCheck)](https://github.com/CheginiSoroush/obsidian-sync-scripts/actions/workflows/lint.yml)

<p align="center">
  <a href="#-quick-start">🚀 Quick Start</a> •
  <a href="#-the-interactive-menu">📱 Interactive TUI</a> •
  <a href="#️-command-reference">⌨️ CLI Reference</a> •
  <a href="#️-the-9-layers-of-defense">🛡️ 9-Layer Defense</a> •
  <a href="#-disaster-recovery-playbook">🚑 Recovery Playbook</a> •
  <a href="#-faq">❓ FAQ</a>
</p>

---

*“Your notes deserve better than hoping the sync works.”*

</div>

<br>

## 🔥 The Problem

You take notes on your phone and your laptop. You version them with Git.
Between those two facts lives a hellscape: mobile networks that die mid-push, Android killing background processes whenever it feels like it, shared storage with no `exec` bits — and one interrupted `git pull` away from a week of lost thoughts.

Most people give up and hope. **You don't have to.**

**`ob-sync`** is a single, self-contained Bash script that turns your terminal into a battle-hardened sync engine for your Obsidian vault — engineered specifically for the hostile environment of Android shared storage, and equally at home on Linux and macOS.

| 💀 Without `ob-sync` | 🛡️ With `ob-sync` |
| :--- | :--- |
| Interrupted `git pull` leaves your vault in rebase limbo | **Self-healing Git** aborts broken states & clears stale locks automatically |
| Network drops mid-push and hangs the terminal forever | **Network Watchdog** enforces strict timeouts on every remote call |
| Corrupted `.git` folder means manual surgery or lost notes | **Two-Phase Repair** atomically rebuilds metadata while preserving local files |
| No safety net before destructive Git operations | **SHA-256 Verified Backups** run before *any* mutation touches your vault |

> [!IMPORTANT]
> **Core Philosophy:** *No half-finished files. No silent data loss. No cryptic errors. Ever.*

---

## 🚀 Quick Start

### 📱 Android (Termux)

```bash
pkg install curl
curl -fsSL https://raw.githubusercontent.com/CheginiSoroush/obsidian-sync-scripts/main/mobile/install.sh | bash

ob-sync doctor     # 1. Verify the environment
ob-sync init       # 2. Clone or adopt your vault
ob-sync            # 3. Open the interactive menu
```

### 🖥️ Linux & macOS

```bash
git clone https://github.com/CheginiSoroush/obsidian-sync-scripts.git
cd obsidian-sync-scripts
./desktop/install.sh

ob-sync doctor && ob-sync init && ob-sync sync
```

> [!WARNING]
> Piping installers into `bash` is convenient but blind. If you prefer to inspect before executing, review [`mobile/install.sh`](mobile/install.sh) or [`desktop/install.sh`](desktop/install.sh) first, or use the `git clone` method above.

### ✨ What a Successful Sync Looks Like

```text
$ ob-sync sync

  Full Synchronization
  ────────────────────────────────────────────────────────
  [1] Checking repository state
  [ OK ] Repository is in a safe state
  [2] Creating pre-sync backup
  [ OK ] Backup: pre-sync-20250612-143207.tar.gz
  [3] Committing local changes
  [ OK ] Committed 3 changed file(s)
  [4] Fetching remote state
  [5] Rebasing onto origin/main (2 remote commit(s))
  [ OK ] Integrated 2 remote commit(s)
  [6] Pushing to origin/main
  [ OK ] Pushed 1 commit(s)

  [ OK ] Sync complete — 2 commit(s) in, 1 commit(s) out
```

---

## 📱 The Interactive Menu

Run `ob-sync` with no arguments. On a phone keyboard, typing subcommands is friction — **this menu is the whole point:**

```text
$ ob-sync

  ──────────────────────────────────────────
     OBSIDIAN SYNC TOOL  ·  v8.0.0
  ──────────────────────────────────────────

  Vault:   /storage/emulated/0/Documents/Soroush
  Branch:  main
  Changes: 3
  Last:    2025-06-12 14:32:07

  MENU
  ------------------------------------------

  1) Sync      backup + rebase + push
  2) Pull      integrate remote changes
  3) Push      publish local changes
  4) Backup    create a verified backup
  5) Restore   roll back from a backup
  6) Verify    check backup integrity
  7) Repair    rebuild git metadata
  8) Organize  audit notes & attachments
  9) Status    vault overview
  10) Health   git integrity check
  11) Doctor   diagnose environment
  12) Quick    backup + sync, one shot
  0) Exit      quit the tool

  ------------------------------------------

  Select an option [0-12]:
```

> [!TIP]
> **Error-proof by design:** Operations never kill your interactive session, and the PID lock is cleanly released between actions — press `1` five times in a row if you like.

---

## 🧠 How It Works

Every `ob-sync sync` execution walks through a deterministic, fault-tolerant state machine:

```mermaid
flowchart TD
    A(["⚡ ob-sync sync"]) --> B["🔒 Acquire Exclusive PID Lock"]
    B --> C{"Repository Safe?"}
    C -- "No" --> D["🩹 Auto-Heal: Abort rebase/merge,<br/>clear stale locks"]
    D --> C
    C -- "Yes" --> E["📦 Verified Backup<br/>archive → test-read → SHA-256 → atomic rename"]
    E --> F["💾 Stage & Commit Local Changes"]
    F --> G["🌐 Fetch Origin (with Network Watchdog)"]
    G --> H{"Behind Remote?"}
    H -- "Yes" --> I["🔄 Rebase onto Origin"]
    I -- "Conflict" --> J["⛔ Abort Cleanly & List Culprits<br/>(Local state untouched)"]
    H -- "No" --> K{"Ahead of Remote?"}
    I -- "Clean" --> K
    K -- "Yes" --> L["🚀 Push to Origin"]
    L --> M(["✅ Sync Complete"])
    K -- "No" --> M
    J --> N(["⚠️ Halted — Data 100% Safe"])

    classDef startEnd fill:#00B4D8,stroke:#0077B6,stroke-width:2px,color:#fff,font-weight:bold
    classDef success fill:#00C896,stroke:#008F6B,stroke-width:2px,color:#fff,font-weight:bold
    classDef danger fill:#EF476F,stroke:#B8254B,stroke-width:2px,color:#fff,font-weight:bold
    classDef warn fill:#FFB703,stroke:#FB8500,stroke-width:2px,color:#000,font-weight:bold
    classDef step fill:#1E293B,stroke:#475569,stroke-width:1px,color:#F8FAFC

    class A startEnd
    class M success
    class J,N danger
    class C,H,K,D warn
    class B,E,F,G,I,L step
```

---

## 🛡️ The 9 Layers of Defense

Between you and data loss stand nine independent walls — and the very first one is a timestamped, checksummed backup taken before *anything* else happens.

| Layer | Mechanism | What It Guarantees |
| :---: | :--- | :--- |
| **01** | **PID Locking** | Two instances can never touch the vault simultaneously; dead PIDs are automatically reclaimed. |
| **02** | **Verified Backups** | An archive only counts if the full stream reads back cleanly *and* its SHA-256 checksum is recorded. |
| **03** | **Atomic Publishing** | Backups write to `.part` files and rename atomically — a crash never leaves a half-written archive. |
| **04** | **Network Watchdog** | Every remote Git call runs under a configurable timeout so hung connections never freeze your vault. |
| **05** | **Self-Healing Git** | Interrupted rebases, unfinished merges, and stale `.lock` files are recovered automatically. |
| **06** | **Two-Phase Repair** | Replacement `.git` is cloned, `fsck`-verified, and staged *before* anything moves — with instant rollback. |
| **07** | **Tar-Slip Guardian** | `restore` audits every archive member prior to extraction — absolute paths, `..` traversal, and symlinks are refused. |
| **08** | **Temp Registry** | Every runtime temporary file is tracked and swept on *any* exit path — including `Ctrl+C`; artifacts leaked by an uncatchable `SIGKILL` are reclaimed on the next run. |
| **09** | **Additive-Only Restore** | Remote files are only ever *added* when missing during recovery; your local edits always win. |

---

## ⌨️ Command Reference

### 🔄 Synchronization & Workflow

| Command | Description |
| :--- | :--- |
| `ob-sync` | Launches the **Interactive Menu** (or runs a full sync when invoked non-interactively / via cron) |
| `ob-sync sync` | Full pipeline: `check` → `backup` → `commit` → `fetch` → `rebase` → `push` |
| `ob-sync quick` | Creates one verified backup + runs full sync in a single shot |
| `ob-sync pull` | Commits local changes, then integrates remote commits |
| `ob-sync push` | Commits local changes, then publishes to remote |

### 📦 Backup, Restore & Repair

| Command | Description |
| :--- | :--- |
| `ob-sync backup` | Creates and SHA-256 verifies a full vault backup archive |
| `ob-sync restore [target]` | Rolls back from an audited backup (`latest`, filename, or custom path) |
| `ob-sync verify` | Audits the cryptographic integrity of **every** stored backup |
| `ob-sync repair` | Atomically rebuilds `.git` metadata from remote while preserving all local files |

### 🩺 Diagnostics & Vault Hygiene

| Command | Description |
| :--- | :--- |
| `ob-sync organize [--fix]` | Audits empty notes, large files & orphaned attachments (`--fix` relocates orphans) |
| `ob-sync doctor` | Diagnoses platform compatibility, required tools, storage permissions, remote & watchdog |
| `ob-sync status` | Displays a clean overview of vault branch, pending changes, and sync state |
| `ob-sync health` | Runs a deep `git fsck` and repository integrity check |
| `ob-sync init` | Interactive first-time setup to clone a remote vault or adopt an existing folder |
| `ob-sync log [n]` | Shows recent sync and commit activity (defaults to last `n` entries) |

**Global Flags & Exit Codes:**

* **Flags:** `-y, --yes` (Auto-confirm) · `-n, --no-color` (Plain output) · `-h, --help` · `-v, --version`
* **Exit Codes:** `0` Success · `1` Operational Failure · `2` Lock Contention (Another instance is running)

---

## ⚙️ Configuration

Zero config files to manage. Everything is overridable via environment variables:

| Variable | Default | Description |
| :--- | :--- | :--- |
| `OBS_VAULT` | `~/storage/shared/Documents/<vault>` *(Termux)*<br>`~/Documents/<vault>` *(Desktop)* | Path to your Obsidian vault |
| `OBS_REMOTE` | *(See script header)* | Git remote repository URL |
| `OBS_BRANCH` | `main` | Tracked Git branch |
| `OBS_BACKUP_DIR` | `~/obsidian-backups` | Directory where `.tar.gz` backups and checksums are stored |
| `OBS_KEEP_BACKUPS` | `10` | Number of rolling backups to retain (`0` = keep everything) |
| `OBS_LOG` | `~/ob-sync.log` | Log file path (set `""` to disable logging) |
| `OBS_GIT_TIMEOUT` | `120` | Network watchdog timeout in seconds (`0` disables) |
| `OBS_SKIP_BACKUP` | `0` | Set to `1` to skip the pre-sync safety backup |
| `OBS_ATTACH_DIR` | `Attachments` | Target folder when running `ob-sync organize --fix` |

**Example — Fast Unattended Sync:**

```bash
OBS_SKIP_BACKUP=1 OBS_GIT_TIMEOUT=300 ob-sync sync
```

---

## 🚑 Disaster Recovery Playbook

When things go sideways, don't panic — run the matching command:

| Symptom / Scenario | Command to Run | What Happens |
| :--- | :--- | :--- |
| *"Repository not in a safe state"* | `ob-sync sync` | Auto-heals interrupted rebases/merges and clears dead locks |
| Sync keeps failing mysteriously | `ob-sync health` | Runs deep Git object & index diagnostics |
| `.git` directory is corrupted | `ob-sync repair` | Re-clones `.git` in staging, verifies it, and swaps it in safely |
| *"I want my notes from this morning"* | `ob-sync restore latest` | Verifies checksum & tar-slip safety, then restores your latest snapshot |
| Suspect a damaged backup archive | `ob-sync verify` | Tests stream decompression & SHA-256 hashes across all backups |
| Something feels off in the environment | `ob-sync doctor` | Checks Bash version, coreutils, storage permissions, and SSH/PAT auth |
| **Total Catastrophe** | `tar -xzf <backup>.tar.gz` | Backups are standard `.tar.gz` archives — extract them anywhere, anytime |

📖 **Need deeper diagnostics?** Check out the full [Troubleshooting Guide](docs/TROUBLESHOOTING.md).

---

## 🤖 Automation

Exit codes are strict, documented, and stable. When invoked non-interactively (no TTY), plain `ob-sync` **automatically defaults to a full sync** — drop it into any scheduler and it just works:

```bash
# Termux Cron (pkg install cronie) — Sync every 30 minutes
*/30 * * * * ob-sync sync >> ~/ob-sync-cron.log 2>&1
```

---

## 🗂️ Repository Architecture

```text
obsidian-sync-scripts/
├── bin/
│   └── ob-sync               # The entire engine: one platform-aware Bash script
├── mobile/
│   └── install.sh            # Termux environment setup & installer
├── desktop/
│   └── install.sh            # Linux / macOS installer
├── docs/
│   └── TROUBLESHOOTING.md    # Symptom index + deep-dive recovery guides
└── .github/
    └── workflows/            # CI pipeline — strict ShellCheck gate on every push/PR
```

**One Core, Three Platforms:** The script detects Termux, Linux, or macOS at runtime and adapts defaults, filesystem checks, and recovery hints automatically. Platform quirks (BSD vs. GNU userland) are isolated behind clean portability helpers — never split into messy forks.

---

## ❓ FAQ

<details>
<summary><b>🔒 Is my data actually safe?</b></summary>
<br>

Yes. Every mutating operation starts with a **verified backup** — test-read and SHA-256 checksummed — before anything else happens. File operations use atomic `.part` renames. Restores audit every archive member before extraction. The architecture assumes failure will happen and plans around it.
</details>

<details>
<summary><b>🔑 How do I sync a private GitHub repository?</b></summary>
<br>

Configure Git's credential store and authenticate once with your Personal Access Token (PAT):

```bash
git config --global credential.helper store
git ls-remote https://github.com/you/private-vault.git   # Enter your PAT once
```

`ob-sync doctor` will print this exact hint if it detects an unreachable remote.
</details>

<details>
<summary><b>📱 What happens if Android kills Termux mid-sync?</b></summary>
<br>

That is the exact scenario `ob-sync` was built for:

1. On the next run, the PID lock detects the dead process ID and reclaims itself.
2. Any half-written backup exists only as a `.part` file and is automatically swept.
3. Any interrupted rebase or merge is cleanly auto-aborted before syncing resumes.

</details>

<details>
<summary><b>🍎 What are the macOS requirements?</b></summary>
<br>

Run `brew install bash coreutils` to cover the two macOS gaps (Bash 4+ and the `timeout` watchdog utility). Everything else — SHA-256 hashing via `shasum`, portable file sizes, and BSD flags — is handled automatically.
</details>

<details>
<summary><b>🧩 Why not just use the community Obsidian Git plugin?</b></summary>
<br>

You absolutely can — and they coexist peacefully on the same vault! `ob-sync` exists for when you want:

* Background or cron syncs **without opening Obsidian**
* Hardened resilience on **Android shared storage**
* Cryptographically **verified `.tar.gz` backups** outside Git history
* An atomic **`.git` repair tool** when mobile crashes corrupt your repo

</details>

---

## 🤝 Contributing & License

Contributions, bug reports, and edge-case battle stories are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) first — our ShellCheck CI gate and strict portability rules keep this codebase boring in the best possible way.

Released under the **[MIT License](LICENSE)**.

<br>

<div align="center">

---

**Made with 🖤 for everyone whose best ideas arrive far from a keyboard.**

⭐ **If `ob-sync` saved your vault, a star on GitHub is the best thank-you there is.** ⭐

<br>

[⬆️ Back to Top](#readme-top)

</div>