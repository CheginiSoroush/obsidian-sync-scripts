#!/usr/bin/env bash
#
# ─────────────────────────────────────────────────────────────────────────────
#   ob-sync functional test suite
#
#   Self-contained: builds a throwaway sandbox (bare "remote", two vaults,
#   isolated HOME/TMPDIR/config), then drives the real bin/ob-sync through
#   its full user-facing lifecycle. No network access, no root, no side
#   effects on the host.
#
#   Usage:    bash tests/run-tests.sh
#   Exit:     0 = all green, 1 = at least one failure
# ─────────────────────────────────────────────────────────────────────────────

set -u

# Hermetic stdin (9.5.2 field report): when this suite is driven from an
# interactive terminal — e.g. a hand-run `bash some-apply.sh` — ob-sync's
# [[ -t 0 ]] paths (the multi-vault picker, consent prompts) wake up, block
# on the terminal and consume human keystrokes, flipping exit codes and
# captured output nondeterministically. The suite's contract is strictly
# non-interactive: detach stdin once, here, for every command below.
# (Piped fixtures inside `bash -c 'printf … | ob-sync …'` are unaffected —
# their pipes are narrower and win.)
exec 0</dev/null

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
OB="$ROOT/bin/ob-sync"

# The sandbox must live somewhere writable. An inherited-but-broken
# TMPDIR (full disk, deleted dir, unwritable mount) would otherwise
# cascade into dozens of nonsense assertion failures — fail here, once,
# with the actual reason instead.
SB="$(mktemp -d "${TMPDIR:-/tmp}/ob-sync-tests-XXXXXX")" \
    || { echo "FATAL: cannot create the sandbox directory (TMPDIR=${TMPDIR:-unset}: $?)"; exit 1; }
[[ -n "$SB" && -d "$SB" && -w "$SB" ]] \
    || { echo "FATAL: sandbox '$SB' is not a writable directory — check TMPDIR='${TMPDIR:-}'"; exit 1; }
trap 'rm -rf -- "$SB"' EXIT

PASS=0
FAIL=0

# Root writes through directory permission bits, so the two chmod-555
# "unwritable directory" simulations (backup_failed, doctor vault-fail)
# cannot fail as root. Those checks self-skip under root instead of
# reporting phantom failures — CI runs this suite unprivileged so the
# checks keep full coverage there.
IS_ROOT=0
[ "$(id -u)" = "0" ] && IS_ROOT=1

# ── assertions ───────────────────────────────────────────────────────────────
t() {  # t <name> <expected-rc> <command...>
    local name="$1" want="$2"; shift 2
    "$@" >"$SB/out.txt" 2>&1
    local got=$?
    if [[ "$got" == "$want" ]]; then
        PASS=$((PASS + 1)); printf '  [ OK ] %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); printf '  [FAIL] %s (want rc=%s got rc=%s)\n' "$name" "$want" "$got"
        tail -5 "$SB/out.txt" | sed 's/^/         /'
    fi
}
assert() {  # assert <name> <command that must be true>
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        PASS=$((PASS + 1)); printf '  [ OK ] %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$name"
    fi
}
assertout() {  # assertout <name> <ERE pattern> <command...>
    local name="$1" pat="$2"; shift 2
    if "$@" >"$SB/out.txt" 2>&1 && grep -qE "$pat" "$SB/out.txt"; then
        PASS=$((PASS + 1)); printf '  [ OK ] %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); printf '  [FAIL] %s (pattern not found)\n' "$name"
        echo "         ---- last 12 lines of output ----"
        tail -12 "$SB/out.txt" | sed 's/^/         /'
    fi
}

# ── sandbox environment ──────────────────────────────────────────────────────
chmod +x "$OB"
mkdir -p "$SB/home" "$SB/tmp"
export HOME="$SB/home"
export TMPDIR="$SB/tmp"
# The suite must have ZERO side effects on the host: with XDG_CONFIG_HOME
# set, `git config --global` would write the sandbox identity into the
# USER's real ~/.config/git/config. GIT_CONFIG_GLOBAL (git ≥ 2.32)
# redirects every global-config read AND write into the sandbox instead.
unset XDG_CONFIG_HOME
export GIT_CONFIG_GLOBAL="$SB/home/.gitconfig"
export OBS_CONFIG="$SB/config"
export OBS_BACKUP_DIR="$SB/backups"
export OBS_LOG="$SB/ob.log"
export OBS_GIT_TIMEOUT=30
export OBS_VAULT="$SB/vault1"
export OBS_REMOTE="$SB/remote.git"
# Host-vault firewall (9.5.2 field report #2): on a machine whose /media,
# /mnt or /run/media/<user> carry a REAL Obsidian vault, the default
# discovery roots leaked that vault into every check that resolves the
# vault without a pin — the auto-detection checks in sections 20/22 then
# saw two candidates and honestly refused ("Multiple vaults found"),
# three phantom failures that never happen on a bare machine.
# OB_DISCOVER_ROOTS replaces the default roots wholesale (discover_vaults
# in bin/ob-sync), so the harness points it at an empty sandbox folder:
# no host vault can reach the suite. Checks that are about discovery
# re-point it at fixtures (sections 20/22 → $SB/home/Documents,
# section 41 → $SB/media-root).
mkdir -p "$SB/discover-roots"
export OB_DISCOVER_ROOTS="$SB/discover-roots"
# Self-update firewall (9.6.0): ob-sync now refreshes itself from the live
# GitHub release at interactive launch. The suite must NEVER touch the
# network — every launch below runs with the feature switched off, and
# section 42 tests the feature hermetically through file:// URLs instead
# (each check there unsets this override explicitly).
export OB_NO_SELFUPDATE=1
LOCKDIR="$SB/tmp/obs-sync.lock"

git config --global user.email test@example.com
git config --global user.name "Test User"
git config --global init.defaultBranch main

# A bare repository plays the role of GitHub — starts EMPTY, exactly like a
# brand-new user's fresh remote (the historical #1 bug scenario).
git init -q --bare "$SB/remote.git"

# Syntax gate before anything else runs.
bash -n "$OB" || { echo "FATAL: bin/ob-sync has a syntax error"; exit 1; }

echo "== 1. basics =="
t "version"              0 "$OB" version
assertout "version text" "ob-sync [0-9]+\.[0-9]+" "$OB" version
t "help"                 0 "$OB" help
assertout "help lists remote" "remote \[url\]" "$OB" help
t "unknown cmd"          1 "$OB" frobnicate
t "unknown option"       1 "$OB" --nope status

echo "== 2. doctor (pre-init, empty remote) =="
assertout "doctor runs"  "Diagnostics" "$OB" doctor
assertout "doctor: empty remote reported reachable" "reachable \(empty repository" "$OB" doctor

echo "== 3. adopt existing vault (empty remote — the fresh-user path) =="
mkdir -p "$SB/vault1/.obsidian"
printf '# Note One\n' > "$SB/vault1/note1.md"
mkdir -p "$SB/vault1/Attachments"
printf 'x' > "$SB/vault1/orphan.svg"
t "init -y (adopt)"      0 "$OB" init -y
assert   "git repo created"        test -d "$SB/vault1/.git"
assert   "gitignore written"       test -f "$SB/vault1/.gitignore"
assertout "config has VAULT"       "^VAULT=" cat "$SB/config"
assertout "config has REMOTE"      "^REMOTE=" cat "$SB/config"

echo "== 4. the critical first sync on an empty remote =="
t "sync -y (first ever)" 0 "$OB" sync -y
assertout "branch exists on remote" "main" git -C "$SB/remote.git" branch
assertout "remote has commit"        "note1" git -C "$SB/remote.git" ls-tree --name-only main
t "health after first sync" 0 "$OB" health

echo "== 5. second device: clone via init =="
export OBS_VAULT="$SB/vault2"
t "init -y (clone)"      0 "$OB" init -y
assert   "vault2 cloned"          test -f "$SB/vault2/note1.md"
assertout "clone pinned config"   "^VAULT=$SB/vault2$" cat "$SB/config"

echo "== 6. edit on device2, sync; then device1 pulls =="
printf 'device2 edit\n' >> "$SB/vault2/note1.md"
t "vault2 sync"          0 "$OB" sync -y
export OBS_VAULT="$SB/vault1"
t "vault1 sync (rebase)" 0 "$OB" sync -y
assertout "pull integrated" "device2 edit" cat "$SB/vault1/note1.md"

echo "== 7. conflict handling =="
printf 'v1 change\n' >> "$SB/vault1/note1.md"   # vault1 edits locally, does NOT push
export OBS_VAULT="$SB/vault2"
printf 'v2 change\n' >> "$SB/vault2/note1.md"
t "vault2 push (lands first)" 0 "$OB" push -y
export OBS_VAULT="$SB/vault1"
t "vault1 pull conflict -> rc=1" 1 "$OB" pull -y
assertout "vault1 note intact" "v1 change" cat "$SB/vault1/note1.md"
if grep -qE '^(<<<<<<<|>>>>>>>)' "$SB/vault1/note1.md"; then
    FAIL=$((FAIL + 1)); echo "  [FAIL] conflict markers left in working tree"
else
    PASS=$((PASS + 1)); echo "  [ OK ] no conflict markers in working tree"
fi
git -C "$SB/vault1" reset --hard origin/main >/dev/null 2>&1
t "vault1 recovers + syncs" 0 "$OB" sync -y
assertout "remote has v2 change" "v2 change" git -C "$SB/remote.git" show main:note1.md

echo "== 8. backup / verify / restore =="
t "backup"               0 "$OB" backup
t "verify"               0 "$OB" verify
assertout "restore --list shows layout"   "Top level" "$OB" restore --list latest
assertout "restore --list counts notes"   "markdown"  "$OB" restore --list latest
t "restore --list inventory (non-TTY)"  0 bash -c "${OB@Q} restore --list </dev/null"
assertout "restore --dry-run prints plan"    "Execution plan" "$OB" restore --dry-run latest
assertout "restore --dry-run changes nothing" "was not modified" "$OB" restore --dry-run latest
t "restore bad flag -> rc=1"        1 "$OB" restore --bogus latest
t "restore missing target -> rc=1"  1 "$OB" restore does-not-exist
# Regression (8.4.0): a scripted restore without consent used to silently
# cancel AND exit 0 — the worst possible failure mode. It must refuse.
rm -f "$SB/vault1/note1.md"
t "restore w/o consent refuses -> rc=1"  1 bash -c "${OB@Q} restore latest </dev/null"
assert "refused restore left vault untouched"  bash -c '! test -f "$SB/vault1/note1.md"'
t "restore latest -y"    0 "$OB" restore latest -y
assert   "restored note actually back"  test -f "$SB/vault1/note1.md"

echo "== 9. organize =="
assertout "organize finds orphan" "orphan" "$OB" organize
t "organize --fix"       0 "$OB" organize --fix
assert   "orphan moved"   test -f "$SB/vault1/Attachments/orphan.svg"

echo "== 10. remote command =="
t "remote show"          0 "$OB" remote
assertout "remote show output" "$SB/remote.git" "$OB" remote
export OBS_VAULT="$SB/vault2"
t "remote set-url"       0 "$OB" remote "$SB/remote.git"
assertout "origin updated" "$SB/remote.git" git -C "$SB/vault2" remote get-url origin

echo "== 11. insight commands (diff / history / config) =="
export OBS_VAULT="$SB/vault1"
printf 'pending edit\n' >> "$SB/vault1/note1.md"
assertout "diff shows pending file"  "note1" "$OB" diff
assertout "diff labels modification" "modified" "$OB" diff
t "history"              0 "$OB" history 5
assertout "history shows commit"  "chore\(sync\)" "$OB" history 100
assertout "config shows vault"    "Vault" "$OB" config
assertout "config shows remote"   "remote.git" "$OB" config
t "sync clears pending"  0 "$OB" sync -y
assertout "diff clean after sync" "clean" "$OB" diff

echo "== 12. health & status & log =="
assertout "health ok" "All checks passed" "$OB" health
assertout "status shows vault" "vault1" "$OB" status
t "log"                  0 "$OB" log 5

echo "== 13. repair after corruption =="
printf 'garbage' > "$SB/vault1/.git/HEAD"
t "health detects corruption" 1 "$OB" health
t "repair -y"            0 "$OB" repair -y
t "health after repair"  0 "$OB" health

echo "== 14. lock: live holder and stale lock =="
mkdir -p "$LOCKDIR"; printf '%s\n' "$$" > "$LOCKDIR/pid"
t "live lock -> rc=2"    2 "$OB" backup
rm -rf "$LOCKDIR"
mkdir -p "$LOCKDIR"; printf '999999\n' > "$LOCKDIR/pid"
t "stale lock reclaimed" 0 "$OB" backup
assert "lock released after run" bash -c '! test -d "$LOCKDIR"'

echo "== 15. quick =="
t "quick"                0 "$OB" quick

echo "== 16. cron-like resolution (no env, config only) =="
env -u OBS_VAULT -u OBS_REMOTE OBS_CONFIG="$SB/config" OBS_BACKUP_DIR="$SB/backups" \
    OBS_LOG="$SB/ob.log" TMPDIR="$SB/tmp" HOME="$SB/home" \
    "$OB" status >"$SB/status-cron.txt" 2>&1
assertout "status via config only resolves pinned vault" "vault" cat "$SB/status-cron.txt"
env -u OBS_VAULT -u OBS_REMOTE OBS_CONFIG="$SB/config" OBS_BACKUP_DIR="$SB/backups" \
    OBS_LOG="$SB/ob.log" TMPDIR="$SB/tmp" HOME="$SB/home" \
    "$OB" sync -y >"$SB/sync-cron.txt" 2>&1
assertout "sync via config only" "Sync complete" cat "$SB/sync-cron.txt"

echo "== 17. completions, JSON & help =="
t "completion script syntax"   0 bash -n "$ROOT/completions/ob-sync.bash"
assertout "help documents restore --list"  "dry-run" "$OB" help
assertout "status --json: version field"   '"version": "' bash -c "${OB@Q} status --json"
assertout "status --json: real booleans"   '"exists": true' bash -c "${OB@Q} status --json"
if command -v python3 >/dev/null 2>&1; then
    t "status --json parses as JSON"  0 bash -c "${OB@Q} status --json | python3 -m json.tool >/dev/null"
else
    echo "  [SKIP] status --json parses as JSON (python3 not installed)"
fi

echo "== 18. same-second backup ordering (regression) =="
# Two archives sharing one embedded timestamp: the alphabetically-larger
# name ("pre-sync") holds the OLDER mtime. Full-precision mtime must
# decide — not filename order — or `restore latest` returns stale state.
TIE_TS=$(date +%Y%m%d-%H%M%S)
# If an earlier section created an archive in this same second, its
# leftover .sha256 sidecar would (correctly!) fail verification after we
# overwrite the archive — clear any same-named pair first.
rm -f "$SB/backups/pre-sync-$TIE_TS.tar.gz"* "$SB/backups/manual-$TIE_TS.tar.gz"*
tar -czf "$SB/backups/pre-sync-$TIE_TS.tar.gz" -C "$SB/vault1" .
tar -czf "$SB/backups/manual-$TIE_TS.tar.gz" -C "$SB/vault1" .
touch -t 209912312358 "$SB/backups/pre-sync-$TIE_TS.tar.gz"
touch -t 209912312359 "$SB/backups/manual-$TIE_TS.tar.gz"
assertout "same-second: newest mtime wins, not path order" \
    "manual-$TIE_TS" "$OB" restore --list latest

echo "== 19. cron scheduling (deterministic crontab emulator) =="
# A shim 'crontab' keeps the state in a file, so the whole cron lifecycle
# is exercised without a real cron daemon, root, or host crontab access.
CRONBIN="$SB/fakebin"
mkdir -p "$CRONBIN"
cat > "$CRONBIN/crontab" <<'SHIM'
#!/usr/bin/env bash
# Emulates: crontab -l | crontab -r | crontab - | crontab <file>
STORE="${FAKE_CRONTAB:?}"
case "${1:-}" in
  -l) if [[ -s "$STORE" ]]; then cat "$STORE"; else echo "no crontab for tester" >&2; exit 1; fi ;;
  -r) rm -f "$STORE" ;;
  -)  cat > "$STORE" ;;
  *)  cat -- "$1" > "$STORE" ;;
esac
SHIM
chmod +x "$CRONBIN/crontab"
export FAKE_CRONTAB="$SB/crontab.store"
CENV=(env PATH="$CRONBIN:$PATH" FAKE_CRONTAB="$FAKE_CRONTAB")

t "cron status (not installed)"          0 "${CENV[@]}" "$OB" cron
assertout "cron status says not scheduled" "Scheduled: +no" "${CENV[@]}" "$OB" cron
t "cron install hourly"                  0 "${CENV[@]}" "$OB" cron install hourly
assert   "managed block in crontab"        grep -q "BEGIN ob-sync" "$FAKE_CRONTAB"
assertout "hourly expression in job line"  "0 \* \* \* \* .* sync" cat "$FAKE_CRONTAB"
assertout "job pins PATH for cron shells"  "^PATH=" cat "$FAKE_CRONTAB"
t "cron install daily 09:30 (replaces)"  0 "${CENV[@]}" "$OB" cron install daily 09:30
assertout "daily expression updated"       "30 9 \* \* \*" cat "$FAKE_CRONTAB"
if [[ "$(grep -c "BEGIN ob-sync" "$FAKE_CRONTAB" || :)" == "1" ]]; then
    PASS=$((PASS + 1)); echo "  [ OK ] install replaces the old block (exactly one)"
else
    FAIL=$((FAIL + 1)); echo "  [FAIL] install replaces the old block"
fi
t "cron install raw expression"          0 "${CENV[@]}" "$OB" cron install "*/5 9-18 * * 1-5"
assertout "raw expression stored"          "\*/5 9-18 \* \* 1-5" cat "$FAKE_CRONTAB"
t "cron show"                            0 "${CENV[@]}" "$OB" cron show
assertout "cron show prints the block"     "BEGIN ob-sync" "${CENV[@]}" "$OB" cron show
t "cron invalid schedule -> rc=1"        1 "${CENV[@]}" "$OB" cron install "not-a-schedule"
t "cron uninstall w/o consent refuses -> rc=1" \
    1 "${CENV[@]}" "$OB" cron uninstall < /dev/null
t "cron uninstall -y"                    0 "${CENV[@]}" "$OB" cron uninstall -y
assert   "managed block removed"           bash -c "test ! -s '$FAKE_CRONTAB'"
t "cron uninstall -y (idempotent)"       0 "${CENV[@]}" "$OB" cron uninstall -y
assertout "idempotent: nothing to remove"  "nothing to remove" "${CENV[@]}" "$OB" cron uninstall -y
assertout "help documents cron"            "cron \[sub\]" "$OB" help
t "edit-conf non-TTY refuses -> rc=1"    1 bash -c "${OB@Q} edit-conf </dev/null"

echo "== 20. status --json stays clean when the vault is auto-detected =="
# Regression (8.5.0): setup()'s "Auto-detected vault:" info line used to
# land on stdout and corrupt the JSON document whenever no OBS_VAULT and
# no pinned config existed — the exact setup of a fresh cron/dashboard
# consumer. UI lines are now suppressed (and logged instead) in JSON mode.
mkdir -p "$SB/home/Documents/Obsidian/.obsidian"
printf '# note\n' > "$SB/home/Documents/Obsidian/note.md"
if command -v python3 >/dev/null 2>&1; then
    # The discovery root is pinned to the fixture's Documents folder so a
    # real vault under /media on this machine can never join the scan and
    # turn the single-candidate auto-detection into an honest refusal.
    t "auto-detected vault: status --json parses"  0 \
        env -u OBS_VAULT OBS_CONFIG="$SB/config-json" OBS_BACKUP_DIR="$SB/backups" \
            OB_DISCOVER_ROOTS="$SB/home/Documents" \
            OBS_LOG="$SB/ob.log" TMPDIR="$SB/tmp" HOME="$SB/home" \
        bash -c "${OB@Q} status --json | python3 -m json.tool >/dev/null"
    assertout "auto-detected vault: JSON has version field"  '"version"' \
        env -u OBS_VAULT OBS_CONFIG="$SB/config-json" OBS_BACKUP_DIR="$SB/backups" \
            OB_DISCOVER_ROOTS="$SB/home/Documents" \
            OBS_LOG="$SB/ob.log" TMPDIR="$SB/tmp" HOME="$SB/home" \
        bash -c "${OB@Q} status --json"
else
    echo "  [SKIP] auto-detected status --json checks (python3 not installed)"
fi

echo "== 21. status --json: watchdogs, cron & config sections =="
# 8.6.0 growth: the document now also answers "which timeouts are set",
# "is a schedule installed" and "why did it pick that vault".
if command -v python3 >/dev/null 2>&1; then
    cat > "$SB/check-status-shape.py" <<'PY'
import json, sys
d = json.load(sys.stdin)
w = d["watchdogs"]
assert isinstance(w["network_seconds"], int) and w["network_seconds"] >= 0
assert isinstance(w["local_seconds"], int) and w["local_seconds"] >= 0
c = d["cron"]
assert isinstance(c["available"], bool)
assert isinstance(c["scheduled"], bool)
assert c["job"] is None or isinstance(c["job"], str)
assert isinstance(c["log"], str) and c["log"]
cfg = d["config"]
assert isinstance(cfg["file"], str) and cfg["file"]
assert isinstance(cfg["exists"], bool)
assert isinstance(cfg["vault_source"], str) and cfg["vault_source"]
PY
    t "status --json: watchdogs/cron/config shape" 0 \
        bash -c "${OB@Q} status --json | python3 '$SB/check-status-shape.py'"
    # The harness pins the vault via OBS_VAULT — the source must say so.
    assertout "vault_source reports environment override" \
        '"vault_source": "environment"' bash -c "${OB@Q} status --json"
else
    echo "  [SKIP] status --json shape checks (python3 not installed)"
fi

# The cron section must mirror the real crontab — proven here against the
# section-19 emulator: install -> scheduled true + job line, wipe -> false.
t "cron install hourly (json state setup)" 0 "${CENV[@]}" "$OB" cron install hourly
assertout "status --json: cron.scheduled true" '"scheduled": true' \
    env PATH="$CRONBIN:$PATH" FAKE_CRONTAB="$FAKE_CRONTAB" bash -c "${OB@Q} status --json"
assertout "status --json: cron job line present" '"job": ".* sync >>' \
    env PATH="$CRONBIN:$PATH" FAKE_CRONTAB="$FAKE_CRONTAB" bash -c "${OB@Q} status --json"
: > "$FAKE_CRONTAB"
assertout "status --json: cron.scheduled false after wipe" '"scheduled": false' \
    env PATH="$CRONBIN:$PATH" FAKE_CRONTAB="$FAKE_CRONTAB" bash -c "${OB@Q} status --json"

echo "== 22. restore --list --json (machine-readable backups) =="
if command -v python3 >/dev/null 2>&1; then
    cat > "$SB/check-inv.py" <<'PY'
import json, sys
d = json.load(sys.stdin)
assert d["count"] >= 1, "expected at least one backup"
assert len(d["backups"]) == d["count"]
b = d["backups"][0]
assert b["name"].endswith(".tar.gz"), b["name"]
assert isinstance(b["size_bytes"], int) and b["size_bytes"] > 0
assert b["timestamp"] is None or len(b["timestamp"]) == 15
assert isinstance(b["mtime"], int) or b["mtime"] is None
assert isinstance(b["sidecar"], bool)
assert b["sidecar_ok"] is None or isinstance(b["sidecar_ok"], bool)
PY
    t "restore --list --json: inventory parses" 0 \
        bash -c "${OB@Q} restore --list --json | python3 '$SB/check-inv.py'"

    cat > "$SB/check-prev.py" <<'PY'
import json, sys
d = json.load(sys.stdin)
assert "error" not in d, d.get("error")
a = d["archive"]
assert a["name"].endswith(".tar.gz"), a["name"]
assert isinstance(a["size_bytes"], int) and a["size_bytes"] > 0
assert d["members"] == d["files"] + d["directories"]
assert d["members"] >= 1
assert isinstance(d["notes"], int)
assert isinstance(d["top_level"], list) and len(d["top_level"]) >= 1
PY
    t "restore --list --json latest: preview parses" 0 \
        bash -c "${OB@Q} restore --list --json latest | python3 '$SB/check-prev.py'"

    # JSON must be the ONLY thing on stdout even when the vault is
    # auto-detected (same regression class as section 20). The discovery
    # root is pinned like there, so host /media vaults stay outside.
    t "restore --list --json: auto-detected vault stays clean" 0 \
        env -u OBS_VAULT OBS_CONFIG="$SB/config-json" OBS_BACKUP_DIR="$SB/backups" \
            OB_DISCOVER_ROOTS="$SB/home/Documents" \
            OBS_LOG="$SB/ob.log" TMPDIR="$SB/tmp" HOME="$SB/home" \
        bash -c "${OB@Q} restore --list --json | python3 -m json.tool >/dev/null"
else
    echo "  [SKIP] restore --list --json checks (python3 not installed)"
fi

# An empty backup directory is valid data for a monitoring consumer
# (count 0, rc 0) — not an error like the human-facing restore.
EMPTY_DIR="$SB/empty-backups"
mkdir -p "$EMPTY_DIR"
t "restore --list --json: empty inventory rc=0" 0 \
    env OBS_BACKUP_DIR="$EMPTY_DIR" OBS_CONFIG="$SB/config" OBS_LOG="$SB/ob.log" \
        TMPDIR="$SB/tmp" HOME="$SB/home" OBS_VAULT="$SB/vault1" \
    bash -c "${OB@Q} restore --list --json | grep -q '\"count\": 0'"

# Flag validation and parseable failure documents (no python needed).
t "restore --json without --list -> rc=1" 1 "$OB" restore --json
t "restore --dry-run --json -> rc=1"      1 "$OB" restore --dry-run --json

printf 'not a tar at all' > "$SB/backups/broken-restore-json.tar.gz"
"$OB" restore --list --json broken-restore-json.tar.gz >"$SB/out.txt" 2>&1
rc=$?
if (( rc == 1 )) && grep -q '"error"' "$SB/out.txt"; then
    PASS=$((PASS + 1)); echo "  [ OK ] corrupt archive -> JSON error object, rc=1"
else
    FAIL=$((FAIL + 1)); echo "  [FAIL] corrupt archive -> JSON error object (rc=$rc)"
    tail -5 "$SB/out.txt" | sed 's/^/         /'
fi
rm -f "$SB/backups/broken-restore-json.tar.gz"*

echo "== 23. sync --json (machine-readable sync result) =="
# 8.7.0: the sync pipeline emits ONE stable JSON document on stdout —
# success or failure — while the exit code keeps its human-mode meaning.
if command -v python3 >/dev/null 2>&1; then
    cat > "$SB/check-sync.py" <<'PY'
import json, sys
d = json.load(sys.stdin)
assert d["command"] == "sync"
assert d["result"] == "ok", d
assert isinstance(d["pulled"], int) and d["pulled"] >= 0
assert isinstance(d["pushed"], int) and d["pushed"] >= 1
assert isinstance(d["committed_files"], int) and d["committed_files"] >= 1
assert d["conflicts"] == 0
assert d["backup"] is not None and d["backup"].endswith(".tar.gz")
assert d["backup_skipped"] is False
assert isinstance(d["elapsed_seconds"], int) and d["elapsed_seconds"] >= 0
assert d["error"] is None
assert d["branch"] == "main"
assert isinstance(d["remote"], str) and d["remote"]
PY
    printf 'sync-json ok\n' > "$SB/vault1/sync-json.md"
    t "sync --json: ok document parses & shape holds" 0 \
        bash -c "${OB@Q} sync --json | python3 '$SB/check-sync.py'"

    # OBS_SKIP_BACKUP=1 must be reflected as a real boolean with a null backup.
    t "sync --json with OBS_SKIP_BACKUP=1 -> backup_skipped true" 0 \
        env OBS_SKIP_BACKUP=1 bash -c "printf 'x' >> '$SB/vault1/sync-json.md' && ${OB@Q} sync --json | grep -q '\"backup_skipped\": true'"
else
    echo "  [SKIP] sync --json shape checks (python3 not installed)"
fi

# Backward compatibility: the pre-8.7.0 parser silently ignored all args,
# so `sync -y` muscle memory and existing scripts must keep working.
t "sync -y (legacy flag) still works" 0 "$OB" sync -y
# Fail-closed flag validation, same contract as restore/cron.
t "sync --bogus -> rc=1" 1 "$OB" sync --bogus

echo "== 24. sync --json failure documents =="
# fetch_failed: origin points at a nonexistent repository — the document
# must carry result=error with a stable machine code, and rc must stay 1.
# 9.5.0: the vault identity card is authoritative, so the simulated
# outage must cover BOTH origin and .ob-sync/config — otherwise the
# reconciliation would legitimately heal the vault instead of failing.
git -C "$SB/vault1" remote set-url origin "$SB/no-such-remote.git"
printf 'REMOTE=%s\nBRANCH=main\n' "$SB/no-such-remote.git" > "$SB/vault1/.ob-sync/config"
"$OB" sync --json >"$SB/out.txt" 2>/dev/null
rc=$?
if (( rc == 1 )) && grep -q '"result": "error"' "$SB/out.txt" \
                   && grep -q '"code": "fetch_failed"' "$SB/out.txt"; then
    PASS=$((PASS + 1)); echo "  [ OK ] unreachable remote -> error document, code=fetch_failed"
else
    FAIL=$((FAIL + 1)); echo "  [FAIL] unreachable remote error document (rc=$rc)"
    tail -5 "$SB/out.txt" | sed 's/^/         /'
fi
git -C "$SB/vault1" remote set-url origin "$SB/remote.git"
printf 'REMOTE=%s\nBRANCH=main\n' "$SB/remote.git" > "$SB/vault1/.ob-sync/config"

if command -v python3 >/dev/null 2>&1; then
    # conflict: two devices edit the same file; the loser's sync must
    # report code=conflict with a nonzero count and keep the local commit.
    # (vault2 first syncs so it carries the section-23 commits — a bare
    # push would be rejected as non-fast-forward and no conflict would
    # ever materialize.)
    export OBS_VAULT="$SB/vault1"
    printf 'j1 change\n' >> "$SB/vault1/note1.md"      # unpushed local edit
    export OBS_VAULT="$SB/vault2"
    printf 'j2 change\n' >> "$SB/vault2/note1.md"
    t "vault2 sync (conflict setup, lands j2)" 0 "$OB" sync -y
    export OBS_VAULT="$SB/vault1"
    "$OB" sync --json >"$SB/out.txt" 2>/dev/null
    rc=$?
    if (( rc == 1 )) && grep -q '"code": "conflict"' "$SB/out.txt" \
                       && grep -qE '"conflicts": [1-9]' "$SB/out.txt"; then
        PASS=$((PASS + 1)); echo "  [ OK ] diverged devices -> error document, code=conflict"
    else
        FAIL=$((FAIL + 1)); echo "  [FAIL] conflict error document (rc=$rc)"
        tail -5 "$SB/out.txt" | sed 's/^/         /'
    fi
    assert "conflict kept the local commit" bash -c "grep -q 'j1 change' '$SB/vault1/note1.md'"
    git -C "$SB/vault1" reset --hard origin/main >/dev/null 2>&1
    t "vault1 recovers + syncs" 0 "$OB" sync -y

    # vault_missing: even a broken environment answers with parseable JSON
    # (guards live inside cmd_sync, not dispatch, so --json is never left
    # with an empty stdout).
    t "missing vault -> error document, rc=1" 1 \
        env OBS_VAULT="$SB/ghost-vault" bash -c "${OB@Q} sync --json 2>/dev/null"
    t "missing vault document parses as JSON" 0 \
        env OBS_VAULT="$SB/ghost-vault" bash -c "${OB@Q} sync --json 2>/dev/null | python3 -m json.tool >/dev/null"
    env OBS_VAULT="$SB/ghost-vault" bash -c "${OB@Q} sync --json 2>/dev/null" >"$SB/out.txt" 2>/dev/null
    if grep -q '"code": "vault_missing"' "$SB/out.txt"; then
        PASS=$((PASS + 1)); echo "  [ OK ] missing vault reports machine code"
    else
        FAIL=$((FAIL + 1)); echo "  [FAIL] missing vault machine code"
        tail -5 "$SB/out.txt" | sed 's/^/         /'
    fi
fi

echo "== 25. pull/push/quick --json (machine-readable operations) =="
# 8.8.0: all four data operations emit ONE stable document shape — one
# parser covers every automation hook. The checker asserts the shared
# contract plus per-command specifics.
if command -v python3 >/dev/null 2>&1; then
    cat > "$SB/check-op.py" <<'PY'
import json, sys
d = json.load(sys.stdin)
cmd = sys.argv[1]
assert d["command"] == cmd, d
assert d["result"] == "ok", d
assert d["error"] is None
assert d["branch"] == "main"
assert isinstance(d["remote"], str) and d["remote"]
assert isinstance(d["pulled"], int) and d["pulled"] >= 0
assert isinstance(d["pushed"], int) and d["pushed"] >= 0
assert isinstance(d["committed_files"], int) and d["committed_files"] >= 0
assert d["conflicts"] == 0
assert isinstance(d["elapsed_seconds"], int) and d["elapsed_seconds"] >= 0
if cmd == "pull" and len(sys.argv) > 2 and sys.argv[2] == "integrate":
    assert d["pulled"] >= 1, d
if cmd == "push":
    assert d["pushed"] >= 1, d
if cmd == "quick":
    assert d["backup"] is not None and d["backup"].startswith("quick-"), d
    assert d["backup_skipped"] is False, d
PY

    # Up-to-date pull: clean vault, nothing behind.
    t "pull --json: up-to-date document parses & shape holds" 0 \
        bash -c "${OB@Q} pull --json | python3 '$SB/check-op.py' pull uptodate"

    # push: a pending change lands on the remote, pushed>=1.
    printf 'push-json change\n' >> "$SB/vault1/note1.md"
    t "push --json: ok document parses & shape holds" 0 \
        bash -c "${OB@Q} push --json | python3 '$SB/check-op.py' push"

    # pull integrate: vault2 lands a change, vault1 pulls it. A NEW file,
    # not an append to note1.md — two devices appending different lines to
    # the same file end is a guaranteed rebase conflict, not a setup.
    export OBS_VAULT="$SB/vault2"
    printf 'pull-json remote change\n' > "$SB/vault2/pull-json.md"
    t "vault2 sync (pull-json setup, lands remote change)" 0 "$OB" sync -y
    export OBS_VAULT="$SB/vault1"
    t "pull --json: integrates remote commits (pulled>=1)" 0 \
        bash -c "${OB@Q} pull --json | python3 '$SB/check-op.py' pull integrate"

    # quick: verified backup surfaces as THE operation backup.
    t "quick --json: ok document with quick-* backup" 0 \
        bash -c "${OB@Q} quick --json | python3 '$SB/check-op.py' quick"
else
    echo "  [SKIP] pull/push/quick --json shape checks (python3 not installed)"
fi

# Backward compatibility: the pre-8.8.0 parser silently ignored all args,
# so `pull -y` / `push -y` muscle memory must keep working (same rule as
# `sync -y` in 8.7.0).
t "pull -y (legacy flag) still works" 0 "$OB" pull -y
t "push -y (legacy flag) still works" 0 "$OB" push -y
# Fail-closed flag validation, same contract as sync/restore/cron.
t "pull --bogus -> rc=1"  1 "$OB" pull --bogus
t "push --bogus -> rc=1"  1 "$OB" push --bogus
t "quick --bogus -> rc=1" 1 "$OB" quick --bogus

echo "== 26. pull/push/quick --json failure documents & purity =="
# vault_missing for pull: even a broken environment answers with parseable
# JSON (guards live inside the wrappers, not dispatch).
t "missing vault pull --json -> error document, rc=1" 1 \
    env OBS_VAULT="$SB/ghost-vault" bash -c "${OB@Q} pull --json 2>/dev/null"
t "missing vault pull --json parses as JSON" 0 \
    env OBS_VAULT="$SB/ghost-vault" bash -c "${OB@Q} pull --json 2>/dev/null | python3 -m json.tool >/dev/null"
env OBS_VAULT="$SB/ghost-vault" bash -c "${OB@Q} pull --json 2>/dev/null" >"$SB/out.txt" 2>/dev/null
if grep -q '"code": "vault_missing"' "$SB/out.txt"; then
    PASS=$((PASS + 1)); echo "  [ OK ] missing vault pull reports machine code"
else
    FAIL=$((FAIL + 1)); echo "  [FAIL] missing vault pull machine code"
    tail -5 "$SB/out.txt" | sed 's/^/         /'
fi

if command -v python3 >/dev/null 2>&1; then
    # push_failed: unreachable remote WITH something to push — the commit
    # succeeds, the push fails, the document must say push_failed.
    # 9.5.0: cover the identity card too (see section 24 note).
    git -C "$SB/vault1" remote set-url origin "$SB/no-such-remote.git"
    printf 'REMOTE=%s\nBRANCH=main\n' "$SB/no-such-remote.git" > "$SB/vault1/.ob-sync/config"
    printf 'push-fail change\n' >> "$SB/vault1/note1.md"
    "$OB" push --json >"$SB/out.txt" 2>/dev/null
    rc=$?
    if (( rc == 1 )) && grep -q '"code": "push_failed"' "$SB/out.txt"; then
        PASS=$((PASS + 1)); echo "  [ OK ] unreachable remote push -> error document, code=push_failed"
    else
        FAIL=$((FAIL + 1)); echo "  [FAIL] push_failed error document (rc=$rc)"
        tail -5 "$SB/out.txt" | sed 's/^/         /'
    fi
    git -C "$SB/vault1" remote set-url origin "$SB/remote.git"
    printf 'REMOTE=%s\nBRANCH=main\n' "$SB/remote.git" > "$SB/vault1/.ob-sync/config"
    git -C "$SB/vault1" reset --hard origin/main >/dev/null 2>&1
    t "vault1 recovers (push-fail cleanup)" 0 "$OB" sync -y

    # quick against an unreachable remote: the verified backup EXISTS, the
    # sync part fails — the document must carry both (backup non-null AND
    # result=error). This is the shape that proves the 8.8.0 quick fix.
    git -C "$SB/vault1" remote set-url origin "$SB/no-such-remote.git"
    printf 'REMOTE=%s\nBRANCH=main\n' "$SB/no-such-remote.git" > "$SB/vault1/.ob-sync/config"
    printf 'quick-fail change\n' >> "$SB/vault1/note1.md"
    "$OB" quick --json >"$SB/out.txt" 2>/dev/null
    rc=$?
    if (( rc == 1 )) && grep -q '"code": "fetch_failed"' "$SB/out.txt" \
                       && grep -qE '"backup": "quick-[0-9]' "$SB/out.txt"; then
        PASS=$((PASS + 1)); echo "  [ OK ] failing quick keeps its verified backup in the document"
    else
        FAIL=$((FAIL + 1)); echo "  [FAIL] quick failure document (rc=$rc)"
        tail -5 "$SB/out.txt" | sed 's/^/         /'
    fi
    git -C "$SB/vault1" remote set-url origin "$SB/remote.git"
    printf 'REMOTE=%s\nBRANCH=main\n' "$SB/remote.git" > "$SB/vault1/.ob-sync/config"
    git -C "$SB/vault1" reset --hard origin/main >/dev/null 2>&1
    t "vault1 recovers (quick-fail cleanup)" 0 "$OB" sync -y

    # JSON purity: whatever vault resolution does, no prose may reach the
    # document (exercises main()'s SILENT_UI branch for the new commands).
    t "pull --json parses with unpinned OBS_VAULT" 0 \
        env -u OBS_VAULT bash -c "${OB@Q} pull --json 2>/dev/null | python3 -m json.tool >/dev/null"
fi

echo "== 27. backup --json (machine-readable manual backup) =="
# 8.9.0: the manual backup emits ONE stable document — result, backup
# {name,path,size_bytes,sidecar,sidecar_ok}, elapsed, error — so scripted
# snapshots can verify their own output. Exit codes unchanged: 0/1/2.
if command -v python3 >/dev/null 2>&1; then
    cat > "$SB/check-backup.py" <<'PY'
import json, sys
d = json.load(sys.stdin)
assert d["command"] == "backup", d
assert d["result"] == "ok", d
assert d["error"] is None
b = d["backup"]
assert isinstance(b, dict), d
assert b["name"].startswith("manual-") and b["name"].endswith(".tar.gz"), d
assert b["path"].endswith(b["name"]), d
assert isinstance(b["size_bytes"], int) and b["size_bytes"] >= 1, d
assert b["sidecar"] is True, d
assert b["sidecar_ok"] is True, d
assert isinstance(d["elapsed_seconds"], int) and d["elapsed_seconds"] >= 0
PY
    t "backup --json: ok document parses & shape holds" 0 \
        bash -c "${OB@Q} backup --json | python3 '$SB/check-backup.py'"
else
    echo "  [SKIP] backup --json shape checks (python3 not installed)"
fi

# Backward compatibility: pre-8.9.0 `backup` silently ignored all args
# (dispatch never forwarded them), so `backup -y` stays a no-op.
t "backup -y (legacy flag) still works" 0 "$OB" backup -y
# Fail-closed flag validation, same contract as sync/restore/cron.
t "backup --bogus -> rc=1" 1 "$OB" backup --bogus

if command -v python3 >/dev/null 2>&1; then
    # vault_missing: the guard lives inside cmd_backup (not dispatch), so
    # --json answers with a parseable document even on a broken environment.
    t "missing vault backup --json -> error document, rc=1" 1 \
        env OBS_VAULT="$SB/ghost-vault" bash -c "${OB@Q} backup --json 2>/dev/null"
    t "missing vault backup --json parses as JSON" 0 \
        env OBS_VAULT="$SB/ghost-vault" bash -c "${OB@Q} backup --json 2>/dev/null | python3 -m json.tool >/dev/null"
    env OBS_VAULT="$SB/ghost-vault" bash -c "${OB@Q} backup --json 2>/dev/null" >"$SB/out.txt" 2>/dev/null
    if grep -q '"code": "vault_missing"' "$SB/out.txt"; then
        PASS=$((PASS + 1)); echo "  [ OK ] missing vault backup reports machine code"
    else
        FAIL=$((FAIL + 1)); echo "  [FAIL] missing vault backup machine code"
        tail -5 "$SB/out.txt" | sed 's/^/         /'
    fi

    # backup_failed: an unwritable backup directory fails the pipeline and
    # the document carries backup=null with the stable machine code.
    chmod 555 "$SB/backups"
    "$OB" backup --json >"$SB/out.txt" 2>/dev/null
    rc=$?
    chmod 755 "$SB/backups"
    if [[ "$IS_ROOT" == 1 ]]; then
        echo "  [SKIP] backup_failed error document (as root, 555 bits do not block writes)"
    elif (( rc == 1 )) && grep -q '"code": "backup_failed"' "$SB/out.txt" \
                       && grep -q '"backup": null' "$SB/out.txt"; then
        PASS=$((PASS + 1)); echo "  [ OK ] failing backup -> error document, code=backup_failed, backup=null"
    else
        FAIL=$((FAIL + 1)); echo "  [FAIL] backup_failed error document (rc=$rc)"
        tail -5 "$SB/out.txt" | sed 's/^/         /'
    fi

    # JSON purity with an unpinned vault (SILENT_UI must cover kv lines too).
    t "backup --json parses with unpinned OBS_VAULT" 0 \
        env -u OBS_VAULT bash -c "${OB@Q} backup --json 2>/dev/null | python3 -m json.tool >/dev/null"
fi

echo "== 28. lock contention keeps the JSON contract =="
# 8.9.0 regression: with the lock held, the command wrapper never ran and
# a --json command left stdout EMPTY (rc 2). Every JSON mode must answer
# with a parseable {"code": "lock_busy"} document instead.
mkdir -p "$LOCKDIR"
echo $$ > "$LOCKDIR/pid"   # a PID that is guaranteed alive: this test's own

t "sync --json under lock -> rc=2"   2 env OBS_VAULT="$SB/vault1" "$OB" sync --json
t "pull --json under lock -> rc=2"   2 env OBS_VAULT="$SB/vault1" "$OB" pull --json
t "push --json under lock -> rc=2"   2 env OBS_VAULT="$SB/vault1" "$OB" push --json
t "quick --json under lock -> rc=2"  2 env OBS_VAULT="$SB/vault1" "$OB" quick --json
t "backup --json under lock -> rc=2" 2 env OBS_VAULT="$SB/vault1" "$OB" backup --json

if command -v python3 >/dev/null 2>&1; then
    for cmdname in sync pull push quick; do
        t "$cmdname --json lock document parses & says lock_busy" 0 \
            env OBS_VAULT="$SB/vault1" bash -c \
            "${OB@Q} $cmdname --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[\"result\"]==\"error\" and d[\"error\"][\"code\"]==\"lock_busy\" and d[\"error\"][\"message\"], d'"
    done
    t "backup --json lock document parses & says lock_busy" 0 \
        env OBS_VAULT="$SB/vault1" bash -c \
        "${OB@Q} backup --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[\"result\"]==\"error\" and d[\"backup\"] is None and d[\"error\"][\"code\"]==\"lock_busy\", d'"
fi
rm -rf -- "$LOCKDIR"

echo "== 29. doctor --json (machine-readable diagnostics) =="
# 8.9.0: every diagnostic becomes a row in a machine-readable checks[]
# array; result/error + rc 1 iff any check failed (same contract as the
# human report). doctor --json is strictly READ-ONLY.
if command -v python3 >/dev/null 2>&1; then
    cat > "$SB/check-doctor.py" <<'PY'
import json, sys
d = json.load(sys.stdin)
assert d["command"] == "doctor", d
assert d["result"] == "ok", d
assert d["error"] is None
assert d["platform"] in ("linux", "macos", "termux")
assert d["remote"] and d["default_branch"] == "main", d
rows = {c["name"]: c for c in d["checks"]}
assert len(d["checks"]) >= 8, d
for c in d["checks"]:
    assert c["status"] in ("ok", "warn", "fail", "info"), c
    assert isinstance(c["message"], str) and c["message"], c
for expected in ("platform", "tools", "storage", "vault", "backup_dir",
                 "backup_topology", "remote", "remote_branch", "watchdogs"):
    assert expected in rows, expected
assert rows["tools"]["status"] == "ok", rows["tools"]
assert rows["vault"]["status"] == "ok", rows["vault"]
assert rows["backup_dir"]["status"] == "ok", rows["backup_dir"]
assert rows["remote"]["status"] == "ok", rows["remote"]
assert rows["remote_branch"]["status"] == "ok", rows["remote_branch"]
assert rows["backup_topology"]["status"] == "warn", rows["backup_topology"]  # sandbox: same fs
PY
    t "doctor --json: ok document parses & shape holds" 0 \
        bash -c "${OB@Q} doctor --json | python3 '$SB/check-doctor.py'"
else
    echo "  [SKIP] doctor --json shape checks (python3 not installed)"
fi

# Strictly read-only: unlike the human report, doctor --json must NOT
# create a missing backup directory.
FRESH_DIR="$SB/doctor-fresh-backups"
rm -rf "$FRESH_DIR"
t "doctor --json runs against a fresh backup dir" 0 \
    env OBS_BACKUP_DIR="$FRESH_DIR" "$OB" doctor --json
assert "doctor --json did not create the backup dir" bash -c "[[ ! -e '$FRESH_DIR' ]]"

# Graceful degradation: a missing vault is a WARN row (rc stays 0), not
# a failure — same semantics as the human report.
t "doctor --json with missing vault -> rc=0 (warn row)" 0 \
    env OBS_VAULT="$SB/ghost-vault" "$OB" doctor --json
if command -v python3 >/dev/null 2>&1; then
    t "missing vault doctor row says warn" 0 \
        env OBS_VAULT="$SB/ghost-vault" bash -c \
        "${OB@Q} doctor --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); rows={c[\"name\"]: c for c in d[\"checks\"]}; assert d[\"result\"]==\"ok\" and rows[\"vault\"][\"status\"]==\"warn\" and rows[\"backup_topology\"][\"status\"]==\"info\", d'"
fi

# Failure contract: an unwritable vault is a FAIL row -> result=error, rc 1.
chmod 555 "$SB/vault1"
"$OB" doctor --json >"$SB/out.txt" 2>/dev/null
rc=$?
chmod 755 "$SB/vault1"
if [[ "$IS_ROOT" == 1 ]]; then
    echo "  [SKIP] unwritable vault diagnostics (as root, 555 bits do not block writes)"
elif (( rc == 1 )) && grep -q '"result": "error"' "$SB/out.txt" \
                   && grep -q '"name": "vault", "status": "fail"' "$SB/out.txt"; then
    PASS=$((PASS + 1)); echo "  [ OK ] unwritable vault -> fail row, result=error, rc=1"
else
    FAIL=$((FAIL + 1)); echo "  [FAIL] unwritable vault diagnostics (rc=$rc)"
    tail -8 "$SB/out.txt" | sed 's/^/         /'
fi

# Fail-closed flag validation, same contract as sync/restore/cron.
t "doctor --bogus -> rc=1" 1 "$OB" doctor --bogus

echo "== 30. verify --json (machine-readable backup audit) =="
# 9.0.0: every stored backup becomes a row in archives[] (name, status
# ok|corrupt, size_bytes, sidecar, sidecar_ok) next to total/passed/failed
# counters. Read-only, no lock — safe to run mid-sync. Exit codes match
# human mode: 0 all verified (or nothing to verify), 1 any corrupt archive.
if command -v python3 >/dev/null 2>&1; then
    cat > "$SB/check-verify.py" <<'PY'
import json, sys
d = json.load(sys.stdin)
assert d["command"] == "verify", d
assert d["result"] == "ok", d
assert d["error"] is None
assert d["backup_dir"].endswith("backups"), d
assert d["total"] >= 1 and d["total"] == d["passed"] and d["failed"] == 0, d
assert isinstance(d["elapsed_seconds"], int) and d["elapsed_seconds"] >= 0
assert len(d["archives"]) == d["total"], d
for a in d["archives"]:
    assert a["name"].endswith(".tar.gz"), a
    assert a["status"] == "ok", a
    assert isinstance(a["size_bytes"], int) and a["size_bytes"] >= 1, a
    assert a["sidecar"] is True and a["sidecar_ok"] is True, a  # real backups carry sidecars
PY
    t "verify --json: ok document parses & shape holds" 0 \
        bash -c "${OB@Q} verify --json | python3 '$SB/check-verify.py'"
else
    echo "  [SKIP] verify --json shape checks (python3 not installed)"
fi

# Human mode unchanged (the 9.0.0 refactor must not alter its output).
assertout "verify human mode still reports" "passed verification" "$OB" verify
# Backward compatibility: pre-9.0.0 `verify` silently ignored all args.
t "verify -y (legacy flag) still works" 0 "$OB" verify -y
# Fail-closed flag validation, same contract as sync/backup/doctor.
t "verify --bogus -> rc=1" 1 "$OB" verify --bogus

if command -v python3 >/dev/null 2>&1; then
    # Empty backup directory: result ok with total=0 (mirrors the human
    # contract — "No backups found" is not a failure).
    rm -rf "$SB/verify-empty"; mkdir -p "$SB/verify-empty"
    t "verify --json on empty dir -> ok, rc=0" 0 \
        env OBS_BACKUP_DIR="$SB/verify-empty" bash -c \
        "${OB@Q} verify --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[\"result\"]==\"ok\" and d[\"total\"]==0 and d[\"archives\"]==[] and d[\"error\"] is None, d'"

    # Corruption contract: one good archive (copied with its sidecar) plus
    # one truncated fake (no sidecar) -> rc 1, verification_failed, and the
    # corrupt row must be identifiable BY NAME for alerting.
    rm -rf "$SB/verify-mixed"; mkdir -p "$SB/verify-mixed"
    good=$(ls -t "$SB/backups"/*.tar.gz 2>/dev/null | head -1)
    cp "$good" "$SB/verify-mixed/"
    cp "$good.sha256" "$SB/verify-mixed/" 2>/dev/null || :
    printf 'this is not a tar.gz archive at all\n' > "$SB/verify-mixed/manual-19990101-000000.tar.gz"
    env OBS_BACKUP_DIR="$SB/verify-mixed" "$OB" verify --json >"$SB/out.txt" 2>/dev/null
    rc=$?
    if (( rc == 1 )) && grep -q '"result": "error"' "$SB/out.txt" \
                       && grep -q '"code": "verification_failed"' "$SB/out.txt"; then
        PASS=$((PASS + 1)); echo "  [ OK ] corrupt archive -> error document, code=verification_failed, rc=1"
    else
        FAIL=$((FAIL + 1)); echo "  [FAIL] verification_failed document (rc=$rc)"
        tail -8 "$SB/out.txt" | sed 's/^/         /'
    fi
    t "corrupt document: counters, corrupt row, missing-sidecar semantics" 0 \
        env OBS_BACKUP_DIR="$SB/verify-mixed" bash -c "${OB@Q} verify --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d[\"result\"] == \"error\" and d[\"error\"][\"code\"] == \"verification_failed\", d
assert d[\"total\"] == 2 and d[\"passed\"] == 1 and d[\"failed\"] == 1, d
rows = {a[\"name\"]: a for a in d[\"archives\"]}
bad = rows[\"manual-19990101-000000.tar.gz\"]
assert bad[\"status\"] == \"corrupt\" and bad[\"sidecar\"] is False and bad[\"sidecar_ok\"] is None, bad
good = [a for n, a in rows.items() if n != \"manual-19990101-000000.tar.gz\"][0]
assert good[\"status\"] == \"ok\" and good[\"sidecar_ok\"] is True, good'"

    # JSON purity with an unpinned vault (SILENT_UI must hold for verify too).
    t "verify --json parses with unpinned OBS_VAULT" 0 \
        env -u OBS_VAULT bash -c "${OB@Q} verify --json 2>/dev/null | python3 -m json.tool >/dev/null"
fi

echo "== 31. health --json (machine-readable repository integrity) =="
# 9.0.0: the deep integrity check emits a checks[] row per stage (always
# the SAME seven rows — stages skipped by an early failure become info
# "Not checked") plus a statistics block. Read-only, no lock. Exit code
# mirrors the human report: 0 only when every check is ok; warnings
# (missing remote/identity, unsafe state) already fail automation with rc 1.
if command -v python3 >/dev/null 2>&1; then
    cat > "$SB/check-health.py" <<'PY'
import json, sys
d = json.load(sys.stdin)
assert d["command"] == "health", d
assert d["result"] == "ok", d
assert d["error"] is None
assert d["branch"] == "main", d
assert d["vault"].endswith("/vault1"), d
names = [c["name"] for c in d["checks"]]
assert names == ["git", "repository", "head", "object_database",
                 "safe_state", "remote", "identity"], names
for c in d["checks"]:
    assert c["status"] == "ok", c
    assert isinstance(c["message"], str) and c["message"], c
s = d["statistics"]
assert isinstance(s["commits"], int) and s["commits"] >= 1, s
assert isinstance(s["tracked_files"], int) and s["tracked_files"] >= 1, s
assert isinstance(s["git_size_bytes"], int) and s["git_size_bytes"] >= 0, s
assert isinstance(s["free_space_bytes"], int) and s["free_space_bytes"] >= 0, s
PY
    t "health --json: ok document parses & shape holds" 0 \
        bash -c "${OB@Q} health --json | python3 '$SB/check-health.py'"
else
    echo "  [SKIP] health --json shape checks (python3 not installed)"
fi
t "health --json healthy -> rc=0" 0 "$OB" health --json
assertout "health human mode still reports" "All checks passed" "$OB" health

# Read-only: health --json must never take the lock or leave state behind.
"$OB" health --json >/dev/null 2>&1
assert "health --json left no lock behind" bash -c "[[ ! -e '$LOCKDIR' ]]"

if command -v python3 >/dev/null 2>&1; then
    # Warn contract: a missing remote is a WARN row — the human report
    # already exits 1 for it ("N issue(s) detected"), so --json returns
    # result=error with code=health_issues (rc semantics match human mode).
    git -C "$SB/vault1" remote remove origin
    t "health --json with missing remote -> rc=1 (warn issue)" 1 "$OB" health --json
    t "missing remote document says health_issues, other rows stay ok" 0 \
        bash -c "${OB@Q} health --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d[\"result\"] == \"error\" and d[\"error\"][\"code\"] == \"health_issues\", d
rows = {c[\"name\"]: c[\"status\"] for c in d[\"checks\"]}
assert len(rows) == 7 and rows[\"remote\"] == \"warn\", rows
assert rows[\"object_database\"] in (\"ok\", \"warn\"), rows
assert rows[\"safe_state\"] == \"ok\", rows
assert d[\"statistics\"][\"commits\"] >= 1, d[\"statistics\"]'"

    # Stale remote-tracking ref (9.0.0 regression): removing a remote can
    # leave origin/HEAD as a broken symref (null-sha after target loss) and
    # fsck then fails — health must report a precise WARN, never "corruption".
    # Built explicitly so the test is deterministic across git versions.
    git -C "$SB/vault1" update-ref -d refs/remotes/origin/main 2>/dev/null || :
    mkdir -p "$SB/vault1/.git/refs/remotes/origin"
    printf 'ref: refs/remotes/origin/main\n' > "$SB/vault1/.git/refs/remotes/origin/HEAD"
    t "stale-ref health --json -> rc=1 (two warns, no corruption)" 1 "$OB" health --json
    t "stale ref document: object_database warn with surgical fix" 0 \
        bash -c "${OB@Q} health --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d[\"result\"] == \"error\" and d[\"error\"][\"code\"] == \"health_issues\", d
rows = {c[\"name\"]: (c[\"status\"], c[\"message\"]) for c in d[\"checks\"]}
assert rows[\"object_database\"][0] == \"warn\", rows
assert \"stale remote-tracking ref\" in rows[\"object_database\"][1], rows
assert \"refs/remotes/origin/HEAD\" in rows[\"object_database\"][1], rows
assert rows[\"head\"][0] == \"ok\" and rows[\"safe_state\"][0] == \"ok\", rows'"
    # (health exits 1 in this state — two issues — so plain asserts, not assertout)
    assert "stale-ref human report says stale" \
        bash -c "'$OB' health 2>/dev/null | grep -q 'stale remote-tracking ref'"
    assert "stale-ref human report never says corruption" \
        bash -c "'$OB' health 2>/dev/null | grep -q 'corruption detected'; test \$? -ne 0"
    # restore: drop the broken file, re-add the remote, refetch
    rm -f "$SB/vault1/.git/refs/remotes/origin/HEAD"
    git -C "$SB/vault1" remote add origin "$SB/remote.git"
    git -C "$SB/vault1" fetch origin >/dev/null 2>&1

    # Fail contract: a missing repository fails stage 2 — deeper stages
    # become info "Not checked" rows (the array stays at seven entries).
    t "health --json with missing repo -> rc=1" 1 \
        env OBS_VAULT="$SB/ghost-vault" "$OB" health --json
    t "missing repo document: fail row + info rows + null stats" 0 \
        env OBS_VAULT="$SB/ghost-vault" bash -c "${OB@Q} health --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d[\"result\"] == \"error\" and d[\"error\"][\"code\"] == \"health_failed\", d
rows = {c[\"name\"]: c[\"status\"] for c in d[\"checks\"]}
assert len(rows) == 7, rows
assert rows[\"git\"] == \"ok\" and rows[\"repository\"] == \"fail\", rows
assert rows[\"head\"] == \"info\" and rows[\"object_database\"] == \"info\", rows
assert d[\"statistics\"][\"commits\"] is None, d[\"statistics\"]'"

    # JSON purity with an unpinned vault (SILENT_UI must hold for health too).
    t "health --json parses with unpinned OBS_VAULT" 0 \
        env -u OBS_VAULT bash -c "${OB@Q} health --json 2>/dev/null | python3 -m json.tool >/dev/null"
fi

# Backward compatibility: pre-9.0.0 `health` silently ignored all args.
t "health -y (legacy flag) still works" 0 "$OB" health -y
# Fail-closed flag validation, same contract as sync/backup/doctor.
t "health --bogus -> rc=1" 1 "$OB" health --bogus

echo
echo "== 32. log --json (machine-readable activity document) =="
# 9.1.0: the activity log becomes a document — entries[{timestamp,source,
# message}] parsed out of the "[ts] [source] message" log lines. Read-only
# (no lock). A missing/disabled log file is VALID data (log_file null,
# count 0, rc 0 — mirrors the human "No log file available"); rc 1 with
# code log_unreadable only when an existing file cannot be read.
if command -v python3 >/dev/null 2>&1; then
    cat > "$SB/check-log.py" <<'PY'
import json, re, sys
d = json.load(sys.stdin)
assert d["command"] == "log", d
assert d["error"] is None, d
assert d["requested"] == 20, d
assert d["count"] == len(d["entries"]) and d["count"] >= 1, d
for e in d["entries"]:
    assert set(e) == {"timestamp", "source", "message"}, e
    assert e["timestamp"] is None or re.match(
        r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$", e["timestamp"]), e
    assert isinstance(e["message"], str), e
# Regular entries carry a real timestamp and a non-empty source.
full = [e for e in d["entries"] if e["timestamp"] is not None]
assert full, "no parsed entries at all"
assert all(e["source"] for e in full), full
PY
    t "log --json: ok document parses & shape holds" 0 \
        bash -c "${OB@Q} log --json | python3 '$SB/check-log.py'"
    t "log --json: requested=2 honored" 0 \
        bash -c "${OB@Q} log --json 2 | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d[\"requested\"] == 2 and d[\"count\"] <= 2, d
assert d[\"count\"] == len(d[\"entries\"]), d'"
    # Pre-9.1.0 tolerance: a non-numeric count silently means the default.
    t "log --json: non-numeric arg falls back to 20" 0 \
        bash -c "${OB@Q} log --json abc | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d[\"requested\"] == 20, d'"
else
    echo "  [SKIP] log --json shape checks (python3 not installed)"
fi
t "log --json -> rc=0" 0 "$OB" log --json
assertout "log human mode still reports" "Recent Activity" "$OB" log
# Fail-closed flag validation, same contract as verify/health.
t "log --bogus -> rc=1" 1 "$OB" log --bogus
# Read-only: log must never take the lock or leave state behind.
"$OB" log --json >/dev/null 2>&1
assert "log --json left no lock behind" bash -c "[[ ! -e '$LOCKDIR' ]]"
# OBS_LOG="" disables logging (documented contract — 9.1.0 fixed ${OBS_LOG:-}
# treating an empty value as unset): log_file null, zero entries, rc 0.
if command -v python3 >/dev/null 2>&1; then
    t "disabled log: log_file null, count 0, rc 0" 0 \
        env OBS_LOG= bash -c "${OB@Q} log --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d[\"log_file\"] is None and d[\"count\"] == 0 and d[\"entries\"] == [], d
assert d[\"error\"] is None, d'"
fi
# JSON purity with an unpinned vault (SILENT_UI must hold for log too).
if command -v python3 >/dev/null 2>&1; then
    t "log --json parses with unpinned OBS_VAULT" 0 \
        env -u OBS_VAULT bash -c "${OB@Q} log --json 2>/dev/null | python3 -m json.tool >/dev/null"
fi

echo
echo "== 33. restore --json (machine-readable scripted DR drills) =="
# 9.1.0: apply-mode restore emits ONE stable result document — archive
# object, safety_backup, previous_vault, elapsed_seconds, error{code,
# message}. Requires an explicit target and -y (JSON mode never prompts).
# Every failure point carries a stable code; exit codes mirror human mode
# (0 restored, 1 failure, 2 lock contention). 9.1.0 also fixed apply-mode
# --json bypassing the PID lock — the lock_busy test below proves it.
if command -v python3 >/dev/null 2>&1; then
    # Consent: no -y -> fail closed BEFORE verification (archive resolved
    # and reported, sidecar not yet checked, nothing mutated).
    t "restore --json without -y -> rc=1" 1 "$OB" restore --json latest
    t "consent document: consent_required + resolved archive" 0 \
        bash -c "${OB@Q} restore --json latest 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d[\"result\"] == \"error\" and d[\"error\"][\"code\"] == \"consent_required\", d
assert d[\"archive\"] and d[\"archive\"][\"name\"].endswith(\".tar.gz\"), d
assert d[\"archive\"][\"sidecar_ok\"] is None, d
assert d[\"safety_backup\"] is None and d[\"previous_vault\"] is None, d'"

    # Fail-closed targeting: no implicit "latest" guess in JSON mode.
    t "restore --json without target -> rc=1" 1 "$OB" restore --json
    t "target document: target_required, archive null" 0 \
        bash -c "${OB@Q} restore --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d[\"error\"][\"code\"] == \"target_required\" and d[\"archive\"] is None, d'"

    # Unknown target.
    t "restore --json ghost.tar.gz -y -> rc=1" 1 "$OB" restore --json ghost.tar.gz -y
    t "unknown target document: backup_not_found" 0 \
        bash -c "${OB@Q} restore --json ghost.tar.gz -y 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d[\"error\"][\"code\"] == \"backup_not_found\", d'"

    # Empty backup directory (throwaway dir; nothing to restore anywhere).
    mkdir -p "$SB/empty-bak"
    t "restore --json into empty backup dir -> rc=1" 1 \
        env OBS_BACKUP_DIR="$SB/empty-bak" "$OB" restore --json latest -y
    t "empty dir document: no_backups, archive null" 0 \
        env OBS_BACKUP_DIR="$SB/empty-bak" bash -c "${OB@Q} restore --json latest -y 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d[\"error\"][\"code\"] == \"no_backups\" and d[\"archive\"] is None, d'"

    # Corrupt archives in a throwaway backup dir against a vault COPY —
    # these must fail before anything is swapped.
    cp -a "$SB/vault1" "$SB/vault1-cs"
    mkdir -p "$SB/cs-bak"
    tar -czf "$SB/cs-bak/manual-20200101-000000.tar.gz" -C "$SB/vault1-cs" .
    printf 'not-a-valid-sha256' > "$SB/cs-bak/manual-20200101-000000.tar.gz.sha256"
    t "restore --json bad sidecar -> rc=1" 1 \
        env OBS_VAULT="$SB/vault1-cs" OBS_BACKUP_DIR="$SB/cs-bak" \
        "$OB" restore --json manual-20200101-000000.tar.gz -y
    t "sidecar document: checksum_mismatch, sidecar_ok false" 0 \
        env OBS_VAULT="$SB/vault1-cs" OBS_BACKUP_DIR="$SB/cs-bak" bash -c \
        "${OB@Q} restore --json manual-20200101-000000.tar.gz -y 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d[\"error\"][\"code\"] == \"checksum_mismatch\", d
assert d[\"archive\"][\"sidecar\"] is True and d[\"archive\"][\"sidecar_ok\"] is False, d
assert d[\"safety_backup\"] is None, d'"

    printf 'this is not gzip' > "$SB/cs-bak/manual-20200102-000000.tar.gz"
    t "restore --json garbage archive -> rc=1" 1 \
        env OBS_VAULT="$SB/vault1-cs" OBS_BACKUP_DIR="$SB/cs-bak" \
        "$OB" restore --json manual-20200102-000000.tar.gz -y
    t "garbage document: archive_corrupt" 0 \
        env OBS_VAULT="$SB/vault1-cs" OBS_BACKUP_DIR="$SB/cs-bak" bash -c \
        "${OB@Q} restore --json manual-20200102-000000.tar.gz -y 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d[\"error\"][\"code\"] == \"archive_corrupt\", d
assert d[\"archive\"][\"sidecar\"] is False, d'"

    # Tar-slip: a real symlink member must be refused (JSON code
    # unsafe_archive, human mode unchanged), vault untouched.
    python3 -c "
import tarfile
with tarfile.open('$SB/cs-bak/manual-20200103-000000.tar.gz', 'w:gz') as t:
    info = tarfile.TarInfo('evil-link')
    info.type = tarfile.SYMTYPE
    info.linkname = '/etc/passwd'
    t.addfile(info)"
    t "restore --json symlink member -> rc=1" 1 \
        env OBS_VAULT="$SB/vault1-cs" OBS_BACKUP_DIR="$SB/cs-bak" \
        "$OB" restore --json manual-20200103-000000.tar.gz -y
    t "symlink document: unsafe_archive" 0 \
        env OBS_VAULT="$SB/vault1-cs" OBS_BACKUP_DIR="$SB/cs-bak" bash -c \
        "${OB@Q} restore --json manual-20200103-000000.tar.gz -y 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d[\"error\"][\"code\"] == \"unsafe_archive\", d'"
    assert "symlink human report names the member" \
        bash -c "env OBS_VAULT='$SB/vault1-cs' OBS_BACKUP_DIR='$SB/cs-bak' \
            '$OB' restore manual-20200103-000000.tar.gz -y </dev/null 2>&1 | grep -q \"special member (type 'l')\""
    assert "vault copy untouched by all three refusals" \
        bash -c "[[ -f '$SB/vault1-cs/note1.md' ]]"

    # Lock contention: a LIVE lock (PID of this shell) must yield a
    # parseable lock_busy document with rc 2 — proving apply-mode --json
    # takes the lock (the 9.1.0 routing fix).
    mkdir -p "$LOCKDIR"
    printf '%s\n' "$$" > "$LOCKDIR/pid"
    t "restore --json under live lock -> rc=2" 2 "$OB" restore --json latest -y
    t "lock document: lock_busy, archive null, rc 2" 0 \
        bash -c "${OB@Q} restore --json latest -y 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d[\"result\"] == \"error\" and d[\"error\"][\"code\"] == \"lock_busy\", d
assert d[\"archive\"] is None and d[\"safety_backup\"] is None, d'"
    rm -rf -- "$LOCKDIR"

    # Happy path — the real DR drill. Runs LAST: it legitimately replaces
    # vault1 with the newest backup's contents.
    backups_before=$(ls -1 "$SB/backups"/*.tar.gz 2>/dev/null | wc -l)
    t "restore --json latest -y -> rc=0" 0 "$OB" restore --json latest -y
    t "ok document: full shape holds" 0 \
        bash -c "${OB@Q} restore --json latest -y 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d[\"command\"] == \"restore\" and d[\"mode\"] == \"apply\", d
assert d[\"result\"] == \"ok\" and d[\"error\"] is None, d
assert d[\"target\"] == \"latest\", d
assert d[\"archive\"][\"name\"].endswith(\".tar.gz\"), d
assert d[\"archive\"][\"sidecar\"] is True and d[\"archive\"][\"sidecar_ok\"] is True, d
assert d[\"safety_backup\"] and d[\"safety_backup\"].endswith(\".tar.gz\"), d
assert \"vault1.pre-restore-\" in d[\"previous_vault\"], d
assert d[\"vault\"].endswith(\"vault1\"), d
assert isinstance(d[\"elapsed_seconds\"], int) and d[\"elapsed_seconds\"] >= 0, d'"
    assert "vault1 exists after scripted restore" bash -c "[[ -d '$SB/vault1' ]]"
    assert "restored vault contains the notes" bash -c "[[ -f '$SB/vault1/note1.md' ]]"
    assert "previous vault preserved on disk" \
        bash -c "ls -d '$SB'/vault1.pre-restore-* >/dev/null 2>&1"
    backups_after=$(ls -1 "$SB/backups"/*.tar.gz 2>/dev/null | wc -l)
    # Values are expanded into the assertion string (not referenced by
    # name) so ShellCheck can see they are used — bash -c hides them.
    assert "safety backup landed in backup dir" \
        bash -c "(( $backups_after >= $backups_before ))"
    # The global -y (before the command) must satisfy consent too —
    # documented "valid before or after the command". NOTE: this and the
    # human restore below form the same-second collision regression —
    # three restores within seconds of each other used to aim mv at the
    # same .pre-restore-<ts> name and fail (9.1.0 added the suffix guard).
    t "restore --json with GLOBAL -y -> rc=0" 0 "$OB" -y restore --json latest
    assert "no vault ever nested inside a pre-restore dir" \
        bash -c "! ls -d '$SB'/vault1.pre-restore-*/vault1* >/dev/null 2>&1"
    assertout "human restore still reports success" "Vault restored from" \
        "$OB" restore latest -y
else
    echo "  [SKIP] restore --json checks (python3 not installed)"
fi

echo
echo "== 34. history --json (machine-readable commit document) =="
# 9.2.0: the vault's commit history becomes a document — commits[{hash,
# date, author, subject}] with full SHA-1 hashes and ISO 8601 strict
# dates. Read-only (no lock). A fresh repository (no commits yet) is
# valid empty data (count 0, rc 0). REGRESSION GUARD: `git log --pretty
# format:` emits no trailing newline, so every release before 9.2.0
# silently DROPPED the newest commit (plain `while read` discards the
# unterminated final line) — the newest-hash assertions below pin it.
if command -v python3 >/dev/null 2>&1; then
    t "history --json: ok document parses & shape holds" 0 \
        bash -c "${OB@Q} history --json | python3 -c '
import json, re, sys
d = json.load(sys.stdin)
assert d[\"command\"] == \"history\" and d[\"error\"] is None, d
assert d[\"requested\"] == 10, d
assert d[\"count\"] == len(d[\"commits\"]) and d[\"count\"] >= 1, d
for c in d[\"commits\"]:
    assert set(c) == {\"hash\", \"date\", \"author\", \"subject\"}, c
    assert re.match(r\"^[0-9a-f]{40}$\", c[\"hash\"]), c
    assert re.match(r\"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\", c[\"date\"]), c
    assert c[\"author\"] and c[\"subject\"], c'"
    # requested=2 honored — and the FIRST entry must be the NEWEST
    # commit (the dropped-newest regression).
    newest_hash=$(git -C "$SB/vault1" rev-parse HEAD)
    t "history --json 2: requested honored, newest commit first" 0 \
        bash -c "${OB@Q} history --json 2 | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d[\"requested\"] == 2 and d[\"count\"] == 2, d
assert d[\"commits\"][0][\"hash\"] == \"$newest_hash\", d[\"commits\"][0][\"hash\"]'"
    # Human mode must show the newest commit too (same bug, human face).
    newest_short=$(git -C "$SB/vault1" rev-parse --short HEAD)
    newest_subj=$(git -C "$SB/vault1" log -1 --format=%s)
    assert "human history shows the newest commit" \
        bash -c "'$OB' history 2>/dev/null | grep -F '$newest_short' | grep -F '$newest_subj' >/dev/null"
    # Pre-9.x tolerance: a non-numeric count silently means the default.
    t "history --json: non-numeric arg falls back to 10" 0 \
        bash -c "${OB@Q} history --json abc | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d[\"requested\"] == 10, d'"
    # The cap stays at 100 even with a huge request.
    t "history --json: request capped at 100" 0 \
        bash -c "${OB@Q} history --json 500 | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d[\"requested\"] == 100, d'"
else
    echo "  [SKIP] history --json shape checks (python3 not installed)"
fi
t "history --json -> rc=0" 0 "$OB" history --json
t "history -y (no-op flag) -> rc=0" 0 "$OB" history -y
# Fail-closed flag validation, same contract as log/verify/health.
t "history --bogus -> rc=1" 1 "$OB" history --bogus
assertout "human history still shows banner" "Vault History" "$OB" history
# Read-only: history must never take the lock or leave state behind.
"$OB" history --json >/dev/null 2>&1
assert "history --json left no lock behind" bash -c "[[ ! -e '$LOCKDIR' ]]"
# A fresh repository (unborn HEAD) is valid EMPTY data, not an error.
git init -q -b main "$SB/fresh-hist"
if command -v python3 >/dev/null 2>&1; then
    t "unborn repo: count 0, commits [], rc 0" 0 \
        env OBS_VAULT="$SB/fresh-hist" bash -c "${OB@Q} history --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d[\"error\"] is None and d[\"count\"] == 0 and d[\"commits\"] == [], d'"
fi
t "unborn repo human -> rc=0" 0 env OBS_VAULT="$SB/fresh-hist" "$OB" history
# A directory that is not a repository at all: parseable failure.
mkdir -p "$SB/nogit-dir"
t "non-repo vault -> rc=1" 1 env OBS_VAULT="$SB/nogit-dir" "$OB" history --json
if command -v python3 >/dev/null 2>&1; then
    t "non-repo document: history_unreadable" 0 \
        env OBS_VAULT="$SB/nogit-dir" bash -c "${OB@Q} history --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d[\"error\"] is not None and d[\"error\"][\"code\"] == \"history_unreadable\", d'"
fi

echo
echo "== 35. organize --json / --fix --json (vault audit & moved-files report) =="
# 9.2.0: the vault audit becomes a document. Scan mode is a pure read —
# it does NOT take the lock (same policy as restore --list), so a report
# can be produced while a sync holds it; fix mode stays serialized and
# answers lock contention with a parseable lock_busy document (rc 2).
# The document carries exact byte sizes and — in fix mode — a full
# moved-files report (moved[{from,to}], skipped[{file,reason}]).
if command -v python3 >/dev/null 2>&1; then
    cat > "$SB/check-org-scan.py" <<'PY'
import json, os, sys
d = json.load(sys.stdin)
vault = sys.argv[1]
assert d["command"] == "organize" and d["mode"] == "scan", d
assert d["result"] == "ok" and d["error"] is None, d
assert d["vault"] == os.path.realpath(vault) or d["vault"] == vault, d
assert isinstance(d["elapsed_seconds"], int) and d["elapsed_seconds"] >= 0, d
# Reproduce the scan's own rules and compare every counter.
EXTS = {"png","jpg","jpeg","gif","webp","svg","bmp","pdf","mp3","wav","ogg",
        "m4a","mp4","mov","mkv","avi","zip"}
notes = atts = other = 0
for root, dirs, files in os.walk(vault):
    dirs[:] = [x for x in dirs if x not in (".git", ".obsidian", ".trash")]
    for fn in files:
        if fn.endswith(".md"):
            notes += 1
        elif fn.rsplit(".", 1)[-1].lower() in EXTS:
            atts += 1
        else:
            other += 1
s = d["scan"]
assert s["notes"] == notes and s["attachments"] == atts and s["other"] == other, (s, notes, atts, other)
for c in d["untitled"]:
    assert os.path.basename(c).startswith("Untitled") and c.endswith(".md"), c
for o in d["oversized"]:
    assert set(o) == {"path", "size_bytes"} and o["size_bytes"] > 5 * 1024 * 1024, o
PY
    # Deterministic fixtures. The orphan scan matches by BASENAME, so a
    # name collision needs two UNREFERENCED files sharing one name: the
    # root copy moves into Attachments/ only to find the name taken by
    # the (equally orphaned) Attachments copy. A referenced file must
    # never be flagged: note1.md's own text is a note, not an attachment.
    printf 'x' > "$SB/vault1/fresh-orphan.png"
    printf 'orphan-copy' > "$SB/vault1/collide.png"
    printf 'in-place-copy' > "$SB/vault1/Attachments/collide.png"
    t "organize --json: scan document parses, counters match" 0 \
        bash -c "${OB@Q} organize --json | python3 '$SB/check-org-scan.py' '$SB/vault1'"
    t "scan document: orphans include the new file, not the referenced one" 0 \
        bash -c "${OB@Q} organize --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
o = d[\"orphans\"]
assert \"fresh-orphan.png\" in o and \"collide.png\" in o, o
assert \"Attachments/collide.png\" in o, o
assert d[\"moved\"] == [] and d[\"skipped\"] == [], d'"
    t "organize --json -> rc=0" 0 "$OB" organize --json
    # Scan mode mutates NOTHING — the fixture stays where it was.
    assert "scan left the orphan in place" test -f "$SB/vault1/fresh-orphan.png"
    assertout "human organize still reports banner" "Vault Organization" "$OB" organize

    # Fix mode: run it ONCE with the document captured to a file — a
    # second fix would legitimately move nothing (orphans are already in
    # place), so the document must be validated from the first run.
    t "organize --fix --json -> rc=0 (document captured)" 0 \
        bash -c "${OB@Q} organize --fix --json > '$SB/fix-doc.json' 2>/dev/null"
    t "fix document: moved/skipped report matches disk" 0 \
        python3 -c '
import json, os, sys
d = json.load(open(sys.argv[1]))
assert d["command"] == "organize" and d["mode"] == "fix", d
assert d["result"] == "ok" and d["error"] is None, d
moved = {m["from"]: m["to"] for m in d["moved"]}
assert moved.get("fresh-orphan.png") == "Attachments/fresh-orphan.png", d["moved"]
skipped = {s["file"]: s["reason"] for s in d["skipped"]}
assert skipped.get("collide.png") == "name collision", d["skipped"]
# every orphan already inside Attachments must be reported, not moved
for o in d["orphans"]:
    if o.startswith("Attachments/"):
        assert skipped.get(o) == "already in attachments dir", (o, skipped)
    elif o != "collide.png":
        assert o in moved, (o, moved)
assert os.path.isfile(os.path.join(d["vault"], "Attachments", "fresh-orphan.png")), d
assert not os.path.exists(os.path.join(d["vault"], "fresh-orphan.png")), d' "$SB/fix-doc.json"
    assert "moved file content intact" \
        bash -c "[[ \"\$(cat '$SB/vault1/Attachments/fresh-orphan.png')\" == 'x' ]]"
    assert "collision copy untouched" \
        bash -c "[[ \"\$(cat '$SB/vault1/collide.png')\" == 'orphan-copy' ]]"
    assert "orphan collide.png still at root" test -f "$SB/vault1/collide.png"
    # Human mode on a FRESH orphan (the JSON fix above already moved the
    # previous one): the summary must still say what it always said.
    printf 'y' > "$SB/vault1/second-orphan.png"
    assertout "human fix still reports the move" "Moved 1 orphan" "$OB" organize --fix
    assert "second orphan actually moved" test -f "$SB/vault1/Attachments/second-orphan.png"
    # Fail-closed flag validation, same contract as log/verify/health.
    t "organize --bogus -> rc=1" 1 "$OB" organize --bogus
    t "organize positional arg -> rc=1" 1 "$OB" organize oops
    t "organize -y (no-op flag) -> rc=0" 0 "$OB" organize -y

    # Lock contract: a LIVE lock (PID of this shell). Scan mode must
    # still succeed (read-only, no lock); fix mode must answer with a
    # parseable lock_busy document, rc 2.
    mkdir -p "$LOCKDIR"
    printf '%s\n' "$$" > "$LOCKDIR/pid"
    t "organize --json under live lock -> rc=0 (no lock needed)" 0 "$OB" organize --json
    t "organize --fix --json under live lock -> rc=2" 2 "$OB" organize --fix --json
    t "fix lock document: lock_busy, mode fix" 0 \
        bash -c "${OB@Q} organize --fix --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d[\"mode\"] == \"fix\" and d[\"result\"] == \"error\", d
assert d[\"error\"][\"code\"] == \"lock_busy\", d
assert d[\"moved\"] == [] and d[\"skipped\"] == [], d'"
    rm -rf -- "$LOCKDIR"
    # The refused fix must not have moved anything.
    assert "locked fix moved nothing" test -f "$SB/vault1/collide.png"

    # ---- 9.2.1 regressions ------------------------------------------------
    # The empty-notes scan was lost in the 9.2.0 refactor — organize kept
    # printing "No empty notes" and empty_notes stayed [] whatever the
    # vault held. Same criteria as pre-9.2.0: markdown under 10 bytes.
    printf 'ab' > "$SB/vault1/tiny-note.md"
    t "organize --json: empty-notes scan is alive (9.2.1)" 0 \
        bash -c "${OB@Q} organize --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d[\"empty_notes\"] == [\"tiny-note.md\"], d'"
    assertout "human organize reports the empty note" \
        "empty or near-empty note" "$OB" organize
    rm -f "$SB/vault1/tiny-note.md"
    t "organize --json: empty-notes list empties with the fixture" 0 \
        bash -c "${OB@Q} organize --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d[\"empty_notes\"] == [], d'"

    # Positional arguments after "--" must fail closed (the parser used
    # to silently drop them and run a scan).
    t "organize -- --fix -> rc=1 (no silent scan)" 1 "$OB" organize -- --fix

    # Lock routing stops at the "--" separator: a target literally named
    # "--list" routes to the LOCKED apply flow, not the lock-free preview.
    printf 'x' > "$SB/backups/--list"
    t "restore -- --list routes to apply -> rc=1 without consent" 1 \
        bash -c "${OB@Q} restore -- --list </dev/null"
    rm -f "$SB/backups/--list"

    # The preview must not claim a checksum verification that never ran:
    # without a sidecar the honest line is the "No checksum sidecar" one.
    LATEST=$("$OB" restore --list --json 2>/dev/null | python3 -c '
import json, sys
print(json.load(sys.stdin)["backups"][0]["path"])')
    rm -f "$LATEST.sha256"
    assertout "no-sidecar preview no longer claims a checksum" \
        "No checksum sidecar" "$OB" restore --list latest
    assertout "no-sidecar JSON preview reports sidecar false" \
        '"sidecar": false' "$OB" restore --list --json latest
else
    echo "  [SKIP] organize --json checks (python3 not installed)"
fi

echo
echo "== 36. v9.2.2 regressions (line-by-line audit) =="

# 36a — unborn HEAD + populated remote: sync must integrate the remote
# content instead of reporting "up to date" forever (rev-list against an
# unborn HEAD used to fail and be masked to 0).
export OBS_VAULT="$SB/vaultUnborn"
mkdir -p "$SB/vaultUnborn"
git -C "$SB/vaultUnborn" init -q
git -C "$SB/vaultUnborn" remote add origin "$SB/remote.git"
t "unborn HEAD: sync -y succeeds" 0 "$OB" sync -y
assert "unborn HEAD: remote note materialized" test -f "$SB/vaultUnborn/note1.md"
t "unborn HEAD: health is green afterwards" 0 "$OB" health

# 36b — conflicts under rebase.backend=apply (the default backend of
# git < 2.26) must be detected, listed and aborted exactly like the
# merge backend: the repo used to be left mid-rebase with the wrong
# JSON code and raw conflict markers on disk.
git init -q --bare "$SB/remote2.git"
export OBS_VAULT="$SB/vaultC1"
mkdir -p "$SB/vaultC1"
printf 'base line\n' > "$SB/vaultC1/note.md"
t "apply-backend setup: first device inits" 0 env OBS_REMOTE="$SB/remote2.git" "$OB" init -y
t "apply-backend setup: first device syncs" 0 "$OB" sync -y
export OBS_VAULT="$SB/vaultC2"
mkdir -p "$SB/vaultC2"
t "apply-backend setup: device2 clones" 0 env OBS_REMOTE="$SB/remote2.git" "$OB" init -y
printf 'device2 version\n' > "$SB/vaultC2/note.md"
t "apply-backend setup: device2 lands its version" 0 "$OB" sync -y
export OBS_VAULT="$SB/vaultC1"
printf 'device1 version\n' > "$SB/vaultC1/note.md"
git -C "$SB/vaultC1" config rebase.backend apply
t "apply-backend conflict -> rc=1" 1 "$OB" sync -y
assertout "apply-backend conflict -> code=conflict" '"code": "conflict"' \
    bash -c "${OB@Q} sync --json 2>&1 || :"
assert "apply-backend: no rebase-apply dir left behind" \
    test ! -d "$SB/vaultC1/.git/rebase-apply"
assert "apply-backend: no rebase-merge dir left behind" \
    test ! -d "$SB/vaultC1/.git/rebase-merge"
assert "apply-backend: branch still symbolic (not detached)" \
    git -C "$SB/vaultC1" symbolic-ref -q HEAD
assert "apply-backend: no conflict markers in worktree" \
    bash -c "! grep -q '<<<<<<<' '$SB/vaultC1/note.md'"
git -C "$SB/vaultC1" reset --hard -q HEAD~1
t "apply-backend: recovery sync works" 0 "$OB" sync -y

# 36c — organize's reference extractor only recognizes ASCII-ish names;
# an attachment referenced verbatim but containing '+' or Persian/CJK
# characters used to be a permanent false orphan (and --fix moved it,
# breaking the note links). The byte-exact fallback must protect them.
export OBS_VAULT="$SB/vaultOrg"
mkdir -p "$SB/vaultOrg"
printf '![x](foo+bar.png)\n\n![y](عکس.png)\n' > "$SB/vaultOrg/note.md"
printf 'PNG' > "$SB/vaultOrg/foo+bar.png"
printf 'PNG' > "$SB/vaultOrg/عکس.png"
printf 'PNG' > "$SB/vaultOrg/unreferenced.png"
t "organize: scan runs on unicode vault" 0 "$OB" organize --json
assert "organize: '+'-referenced attachment not flagged" \
    bash -c "! grep -q 'foo+bar' '$SB/out.txt'"
assert "organize: Persian-referenced attachment not flagged" \
    bash -c "! grep -q 'عکس' '$SB/out.txt'"
assert "organize: true orphan still flagged" \
    grep -q 'unreferenced' "$SB/out.txt"
t "organize --fix runs" 0 "$OB" organize --fix --json
assert "fix: referenced '+' file stays put" test -f "$SB/vaultOrg/foo+bar.png"
assert "fix: referenced Persian file stays put" test -f "$SB/vaultOrg/عکس.png"
assert "fix: true orphan moved into attachments" \
    test -f "$SB/vaultOrg/Attachments/unreferenced.png"

# 36d — a filename containing a raw C0 control byte used to produce a
# JSON document no parser could read (json_escape now maps it to \\u00XX).
export OBS_VAULT="$SB/vaultCtrl"
mkdir -p "$SB/vaultCtrl"
printf 'tiny\n' > "$SB/vaultCtrl/note"$'\x01'"bad.md"
t "organize --json with a control-char filename runs" 0 "$OB" organize --json
if command -v python3 >/dev/null 2>&1; then
    if "$OB" organize --json 2>/dev/null | python3 -m json.tool >/dev/null 2>&1; then
        PASS=$((PASS + 1)); echo "  [ OK ] control-char filename: JSON still parses"
    else
        FAIL=$((FAIL + 1)); echo "  [FAIL] control-char filename broke the JSON document"
    fi
else
    echo "  [SKIP] control-char JSON check (python3 not installed)"
fi

# 36e — a failed push against an HTTPS remote must explain GitHub's PAT
# requirement instead of a bare "check credentials" (the exact trap that
# hung up the first Termux run: git prompts for a token, not a password).
export OBS_VAULT="$SB/vaultHttps"
mkdir -p "$SB/vaultHttps"
git -C "$SB/vaultHttps" init -q
printf 'x\n' > "$SB/vaultHttps/note.md"
git -C "$SB/vaultHttps" add -A
git -C "$SB/vaultHttps" -c user.name=suite -c user.email=suite@local commit -qm base
git -C "$SB/vaultHttps" remote add origin "https://127.0.0.1:1/repo.git"
assertout "https failure shows the PAT/SSH hint" "Personal Access Token" \
    bash -c "${OB@Q} push -y 2>&1 || :"
assertout "failure surfaces git's own stderr" "git said:" \
    bash -c "${OB@Q} push -y 2>&1 || :"

# 36f — cronie truncates a command at the first unescaped '%'; a '%' in
# the log path used to silently break the scheduled sync.
export OBS_VAULT="$SB/vaultC1"
t "cron install with % in log path" 0 \
    env OBS_CRON_LOG="$SB/logs/pct-%H.log" "${CENV[@]}" "$OB" cron install hourly
assert "cron: % in log path escaped for cronie" grep -F '\%' "$FAKE_CRONTAB"
"${CENV[@]}" "$OB" cron uninstall -y >/dev/null 2>&1

# ═══ 37. closure-audit regressions (v9.2.3) ═══════════════════════════════
echo
echo "== 37. closure-audit regressions =="

# 37a — restore fails closed on stray positional arguments (they used to
# be silently ignored while the FIRST positional still drove the restore).
t "restore rejects extra positional" 1 \
    env OBS_VAULT="$SB/vault1" bash "$OB" restore --dry-run latest EXTRA
t "restore rejects extra positional (json)" 1 \
    env OBS_VAULT="$SB/vault1" bash "$OB" restore latest EXTRA --json -y

# 37b — a listing-pass watchdog timeout must be labeled extraction_timeout,
# not archive_corrupt (tar_listing_cache collapsed rc 124 into 1, which
# made 9.2.2's mapping dead code).
if command -v timeout >/dev/null 2>&1; then
    REAL_TAR="$(command -v tar)"
    S37BIN="$SB/s37bin"; mkdir -p "$S37BIN"
    cat > "$S37BIN/tar" <<SHIM
#!/usr/bin/env bash
# Listing passes stall (watchdog food); every other mode delegates.
case "\$1" in -tzf|-tvzf) sleep 5; exit 99 ;; *) exec "$REAL_TAR" "\$@" ;; esac
SHIM
    chmod +x "$S37BIN/tar"
    mkdir -p "$SB/vaultT1"; printf 'timeout test\n' > "$SB/vaultT1/note.md"
    env OBS_VAULT="$SB/vaultT1" bash "$OB" backup -y >/dev/null 2>&1
    T1ARC="$(ls -t "$SB"/backups/*.tar.gz | head -1)"
    assertout "restore apply: listing timeout -> extraction_timeout" '"extraction_timeout"' \
        env PATH="$S37BIN:$PATH" OBS_LOCAL_TIMEOUT=1 OBS_VAULT="$SB/vaultT1" \
        bash -c "${OB@Q} restore ${T1ARC@Q} --json -y || :"
    assertout "restore --list: listing timeout labeled" "timed out" \
        env PATH="$S37BIN:$PATH" OBS_LOCAL_TIMEOUT=1 OBS_VAULT="$SB/vaultT1" \
        bash -c "${OB@Q} restore --list --json ${T1ARC@Q} || :"
else
    echo "  [SKIP] listing-timeout labeling (timeout(1) not installed)"
fi

# 37c — cron install refuses a newline inside the schedule (cronie would
# install a rogue second job line) and a backslash in the log path (it
# would defeat the % escaping).
t "cron install rejects newline in schedule" 1 \
    env OBS_CRON_LOG="$SB/logs/cron.log" "${CENV[@]}" "$OB" \
    cron install "$(printf '0 0 * * *\nX')"
assert "cron: newline schedule installs nothing" \
    bash -c '! grep -q "BEGIN ob-sync" "$FAKE_CRONTAB"'
t "cron install rejects backslash in log path" 1 \
    env OBS_CRON_LOG="$SB/logs/bs\\%Y.log" "${CENV[@]}" "$OB" cron install hourly
"${CENV[@]}" "$OB" cron uninstall -y >/dev/null 2>&1

# 37d — `log` observes the activity log, it never creates or stamps it:
# a fresh machine answers with the documented null document.
FRESHLOG="$SB/fresh.log"
rm -f "$FRESHLOG"
t "log --json fresh machine: rc 0" 0 \
    env OBS_LOG="$FRESHLOG" OBS_VAULT="$SB/vault1" bash "$OB" log --json
assert "log --json fresh machine: log_file null" \
    env OBS_LOG="$FRESHLOG" OBS_VAULT="$SB/vault1" bash -c \
    "${OB@Q} log --json | grep -q '\"log_file\": null'"
assert "log --json fresh machine: count 0" \
    env OBS_LOG="$FRESHLOG" OBS_VAULT="$SB/vault1" bash -c \
    "${OB@Q} log --json | grep -q '\"count\": 0'"
assert "log command does not create the log file" \
    bash -c "[[ ! -e '$FRESHLOG' ]]"
assertout "log human fresh machine: friendly message" "No log file available" \
    env OBS_LOG="$FRESHLOG" OBS_VAULT="$SB/vault1" bash "$OB" log

# 37e — a >1MiB log is READ, not rotated out from under the reader (the
# old flow answered `log` with one junk self-row; the real rows were in .1).
BIGLOG="$SB/big.log"
awk 'BEGIN { for (i = 0; i < 30000; i++) \
    printf "[2025-01-01 00:00:00] [test          ] seed row %d\n", i }' > "$BIGLOG"
assertout "log --json on >1MiB log shows real rows" "seed row 29999" \
    env OBS_LOG="$BIGLOG" OBS_VAULT="$SB/vault1" bash "$OB" log --json
assert "log command does not rotate the log" \
    bash -c "[[ -f '$BIGLOG' && ! -f '$BIGLOG.1' ]]"
rm -f "$BIGLOG" "$BIGLOG.1"

# 37f — a corrupted object store fails loudly (history_unreadable), not
# as a silent empty history.
H1="$SB/vaultHist"; mkdir -p "$H1"
git -C "$H1" init -q
printf 'a\n' > "$H1/a.md"; git -C "$H1" add -A
git -C "$H1" -c user.name=suite -c user.email=suite@local commit -qm one
printf 'b\n' > "$H1/b.md"; git -C "$H1" add -A
git -C "$H1" -c user.name=suite -c user.email=suite@local commit -qm two
HHASH="$(git -C "$H1" rev-parse HEAD)"
HOBJ="$H1/.git/objects/${HHASH:0:2}/${HHASH:2}"
# Loose objects are stored read-only (444) — lift the bit before truncating.
chmod 644 "$HOBJ" && : > "$HOBJ"
t "history --json corrupted repo: rc 1" 1 \
    env OBS_VAULT="$H1" bash "$OB" history --json
assertout "history --json corrupted repo: history_unreadable" "history_unreadable" \
    bash -c "env OBS_VAULT='$H1' ${OB@Q} history --json 2>/dev/null || :"
t "history human corrupted repo: rc 1" 1 \
    env OBS_VAULT="$H1" bash "$OB" history

# 37g — doctor makes exactly ONE remote call, even against a dead remote
# (pre-9.2.3: up to three watchdog burns ≈ 3 × OBS_GIT_TIMEOUT).
GSHIM="$SB/s37git"; mkdir -p "$GSHIM"
CALLLOG="$SB/s37-git-calls.log"; : > "$CALLLOG"
REAL_GIT="$(command -v git)"
cat > "$GSHIM/git" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLLOG"
exec "$REAL_GIT" "\$@"
SHIM
chmod +x "$GSHIM/git"
D1="$SB/vaultDoc1"; mkdir -p "$D1"; git -C "$D1" init -q
printf 'x\n' > "$D1/n.md"; git -C "$D1" add -A
git -C "$D1" -c user.name=suite -c user.email=suite@local commit -qm base
t "doctor --json dead remote: rc 0" 0 \
    env PATH="$GSHIM:$PATH" OBS_VAULT="$D1" OBS_REMOTE="https://127.0.0.1:1/repo.git" \
    bash "$OB" doctor --json
assert "doctor dead remote: exactly one ls-remote" \
    bash -c "[[ \"\$(grep -c 'ls-remote' '$CALLLOG' || :)\" == '1' ]]"
: > "$CALLLOG"
R1="$SB/remote37.git"; git init -q --bare "$R1"
D2="$SB/vaultDoc2"; mkdir -p "$D2"; git -C "$D2" init -q
printf 'x\n' > "$D2/n.md"; git -C "$D2" add -A
git -C "$D2" -c user.name=suite -c user.email=suite@local commit -qm base
git -C "$D2" remote add origin "$R1"
git -C "$D2" push -q "$R1" main
assertout "doctor reachable: default branch from same call" \
    "Remote default branch 'main' matches" \
    env PATH="$GSHIM:$PATH" OBS_VAULT="$D2" OBS_REMOTE="$R1" bash "$OB" doctor
assert "doctor reachable remote: exactly one ls-remote" \
    bash -c "[[ \"\$(grep -c 'ls-remote' '$CALLLOG' || :)\" == '1' ]]"

# 37h — completions: global flags are never offered after the command
# word ("organize"/"menu" ended a line in the command list and leaked).
COMPL="$ROOT/completions/ob-sync.bash"
assert "completion: organize keeps globals out" \
    bash -c "
        source '$COMPL' 2>/dev/null || exit 1
        COMP_WORDS=(ob-sync organize --fix -); COMP_CWORD=3; COMPREPLY=()
        _ob_sync || exit 1
        for w in \${COMPREPLY[@]}; do
            [[ \"\$w\" == -v || \"\$w\" == --version || \"\$w\" == -n || \"\$w\" == --no-color ]] && exit 1
        done
        exit 0"
assert "completion: menu keeps globals out" \
    bash -c "
        source '$COMPL' 2>/dev/null || exit 1
        COMP_WORDS=(ob-sync menu -); COMP_CWORD=2; COMPREPLY=()
        _ob_sync || exit 1
        for w in \${COMPREPLY[@]}; do
            [[ \"\$w\" == -v || \"\$w\" == --version || \"\$w\" == -n || \"\$w\" == --no-color ]] && exit 1
        done
        exit 0"
assert "completion: first word still offers globals" \
    bash -c "
        source '$COMPL' 2>/dev/null || exit 1
        COMP_WORDS=(ob-sync -); COMP_CWORD=1; COMPREPLY=()
        _ob_sync || exit 1
        [[ \${COMPREPLY[*]} == *--version* ]]"

echo "== 38. v9.3.0: repair over a file .git + menu Init =="
# 9.3.0 scenario: on Android shared storage an interrupted I/O can leave
# .git as a truncated plain FILE — the old execute_repair hit
# "Failed to install repaired .git" because mv refuses to rename a
# directory onto a non-directory. The parked-file + copy-fallback fix
# must recover end to end.
git init -q --bare "$SB/remote38.git"
mkdir -p "$SB/vault38"
printf '# note38\n' > "$SB/vault38/note38.md"
t "38 setup: init"     0 env OBS_REMOTE="$SB/remote38.git" OBS_VAULT="$SB/vault38" "$OB" init -y
t "38 setup: sync"     0 env OBS_REMOTE="$SB/remote38.git" OBS_VAULT="$SB/vault38" "$OB" sync -y
rm -rf "$SB/vault38/.git"
printf 'garbage-truncated-io' > "$SB/vault38/.git"
t "38 health flags file .git"   1 env OBS_VAULT="$SB/vault38" "$OB" health
t "38 repair over file .git"    0 env OBS_REMOTE="$SB/remote38.git" OBS_VAULT="$SB/vault38" "$OB" repair -y
assert "38 warns about non-directory .git" \
    bash -c "grep -qF 'not a directory' '$SB/out.txt'"
assert "38 .git is a directory again" test -d "$SB/vault38/.git"
assert "38 HEAD readable again" test -f "$SB/vault38/.git/HEAD"
t "38 health after file-repair" 0 env OBS_VAULT="$SB/vault38" "$OB" health
assert "38 no staging leftovers" \
    bash -c "! ls -d '$SB/vault38'/'.git-staged-'* >/dev/null 2>&1"

# The menu exposes Init (18) — first-time setup is no longer CLI-only.
assert "menu lists 18) Init" \
    bash -c "printf '0\n' | env OBS_VAULT='$SB/vault38' '$OB' menu 2>&1 | grep -qF '18) Init'"
assert "menu prompt offers 0-19" \
    bash -c "grep -qF 'Select an option [0-19]: ' '$ROOT/bin/ob-sync'"
assert "menu lists 19) Switch" \
    bash -c "printf '0\n' | env OBS_VAULT='$SB/vault38' '$OB' menu 2>&1 | grep -qF '19) Switch'"
# pick_vault_menu is a session-only, TTY-gated helper: piped stdin must
# never surface the picker UI (cron and scripts stay silent).
assert "menu picker silent on piped stdin" \
    bash -c "! printf '0\n' | env OBS_VAULT='$SB/vault38' '$OB' menu 2>&1 | grep -q 'pick one for this session'"

# Menu choice 18 routes to init: a NEW empty vault (no .git) with OBS_REMOTE
# preset runs the non-interactive link flow and leaves a real repository.
mkdir -p "$SB/vault38b"
printf '# fresh vault\n' > "$SB/vault38b/fresh.md"
assert "menu choice 18 dispatches init" \
    bash -c "printf '18\n0\n' | env OBS_VAULT='$SB/vault38b' OBS_REMOTE='$SB/remote38.git' '$OB' menu >/dev/null 2>&1"
assert "38 menu-init created a repository" test -d "$SB/vault38b/.git"
t "38 menu-init vault is healthy" 0 env OBS_VAULT="$SB/vault38b" "$OB" health

echo "== 39. v9.4.2: session remote trust (config REMOTE never crosses vaults) =="
# Field-reported 9.4.1: a vault with NO remote was picked in a session
# (menu 19 / startup picker), then repair + quick ran — and worked on the
# PINNED vault's repository: repair cloned it and swapped the foreign
# .git into the picked vault, quick pushed the picked vault's notes into
# it. The config file REMOTE must never serve a session running a
# different vault.

# Deterministic pinned state, exactly as `init` writes it.
printf 'VAULT=%s\nREMOTE=%s\nBRANCH=main\n' "$SB/vault1" "$SB/remote.git" > "$SB/config"

# A second vault: notes, its own local repository, NO origin, NO remote.
mkdir -p "$SB/vault39/.obsidian"
printf '# lonely note\n' > "$SB/vault39/lonely.md"
git -C "$SB/vault39" init -q
git -C "$SB/vault39" add -A
git -C "$SB/vault39" commit -qm "local only, never connected"

# Snapshot the pinned vault's remote state before the attempts.
git -C "$SB/remote.git" for-each-ref > "$SB/refs-before.txt"
git -C "$SB/vault1" rev-parse HEAD > "$SB/v1-head-before.txt"

# repair on the remote-less vault must refuse cleanly.
t "39 repair refuses (no remote on this vault)" 1 \
    env -u OBS_REMOTE OBS_VAULT="$SB/vault39" "$OB" repair -y
grep -q "No remote repository configured" "$SB/out.txt" \
    && { PASS=$((PASS + 1)); printf '  [ OK ] 39 repair names the missing remote\n'; } \
    || { FAIL=$((FAIL + 1)); printf '  [FAIL] 39 repair names the missing remote\n'; tail -3 "$SB/out.txt" | sed 's/^/         /'; }

# quick (backup + sync) must fail at the origin guard, code no_remote.
if env -u OBS_REMOTE OBS_VAULT="$SB/vault39" "$OB" quick --json >"$SB/out.txt" 2>&1; then
    FAIL=$((FAIL + 1)); printf '  [FAIL] 39 quick --json must fail\n'
else
    PASS=$((PASS + 1)); printf '  [ OK ] 39 quick --json fails with rc!=0\n'
fi
grep -q '"code": *"no_remote"' "$SB/out.txt" \
    && { PASS=$((PASS + 1)); printf '  [ OK ] 39 quick --json code=no_remote\n'; } \
    || { FAIL=$((FAIL + 1)); printf '  [FAIL] 39 quick --json code=no_remote\n'; tail -3 "$SB/out.txt" | sed 's/^/         /'; }

# THE contamination assertions: the foreign repository and vault are
# untouched, the remote-less vault gained no origin and no foreign notes.
git -C "$SB/remote.git" for-each-ref > "$SB/refs-after.txt"
assert "39 foreign repo untouched (no new refs)" \
    diff -q "$SB/refs-before.txt" "$SB/refs-after.txt"
assert "39 remote-less vault gained no origin" \
    bash -c "! grep -q 'remote' '$SB/vault39/.git/config'"
assert "39 no foreign notes materialized" \
    bash -c "! test -e '$SB/vault39/note1.md'"
git -C "$SB/vault1" rev-parse HEAD > "$SB/v1-head-after.txt"
assert "39 pinned vault HEAD untouched" \
    diff -q "$SB/v1-head-before.txt" "$SB/v1-head-after.txt"

# `remote` (no args) must NOT leak the config REMOTE into this session.
assertout "39 remote shows none for foreign session" \
    "none" env -u OBS_REMOTE OBS_VAULT="$SB/vault39" "$OB" remote

# Legacy behavior guarded: the PINNED vault that lost its origin still
# gets it restored — since 9.5.0 primarily from its own identity card
# (.ob-sync/config), with the machine config as the legacy fallback.
git -C "$SB/vault1" remote remove origin
t "39 sync on pinned vault restores origin" 0 \
    env -u OBS_REMOTE OBS_VAULT="$SB/vault1" "$OB" sync -y
assert "39 origin restored for pinned vault" \
    bash -c "git -C '$SB/vault1' remote get-url origin >/dev/null 2>&1"

# 9.5.0 precedence inside a 9.4.2 scenario: the vault's own identity card
# outranks a hand-edited origin — the file traveled with the vault, so it
# expresses the vault's intent (a raw `git remote set-url` is reverted).
git -C "$SB/vault1" remote set-url origin "$SB/remote39-alt.git"
assertout "39 vault identity overrides a hand-edited origin" \
    "Origin:.*remote\.git" env -u OBS_REMOTE OBS_VAULT="$SB/vault1" "$OB" remote

echo "== 40. v9.5.0: the vault carries its own identity (.ob-sync/config) =="
# A vault that has never been connected is a mystery to every remote
# command; the machine-wide config describes the DEVICE, not the vault.
# Since 9.5.0 the vault describes itself: init writes .ob-sync/config
# (REMOTE + BRANCH), the first sync commits it, and every clone arrives
# pre-configured. A lost origin is restored from the vault's OWN file —
# never from another vault's machine-config entry (9.4.2 class of bugs
# becomes structurally impossible on this path).

# 40a — init writes the identity card; the first sync commits it.
git init -q --bare "$SB/remote40.git"
mkdir -p "$SB/vault40"
printf '# identity note\n' > "$SB/vault40/note40.md"
t "40 init writes the vault identity" 0 \
    env OBS_REMOTE="$SB/remote40.git" OBS_VAULT="$SB/vault40" "$OB" init -y
assert "40 identity file exists" test -r "$SB/vault40/.ob-sync/config"
assert "40 identity carries the remote" \
    bash -c "grep -F 'REMOTE=$SB/remote40.git' '$SB/vault40/.ob-sync/config'"
t "40 first sync commits the identity" 0 \
    env OBS_REMOTE="$SB/remote40.git" OBS_VAULT="$SB/vault40" "$OB" sync -y
assert "40 identity reached the remote" \
    bash -c "git -C '$SB/remote40.git' ls-tree -r --name-only refs/heads/main 2>/dev/null | grep -qF '.ob-sync/config'"

# 40b — a second device clones: the identity arrives inside the vault;
# sync works immediately, no remote questions asked.
t "40 second device clones via init" 0 \
    env OBS_REMOTE="$SB/remote40.git" OBS_VAULT="$SB/vault40b" "$OB" init -y
assert "40 clone already carries the identity" test -r "$SB/vault40b/.ob-sync/config"
t "40 second device syncs without errors" 0 \
    env -u OBS_REMOTE OBS_VAULT="$SB/vault40b" "$OB" sync -y

# 40c — self-heal: a lost 'origin' is restored from the vault's OWN file
# (the field-reported 9.4.1 accident, now impossible to cross vault lines).
git -C "$SB/vault40b" remote remove origin
t "40 sync restores origin from the identity" 0 \
    env -u OBS_REMOTE OBS_VAULT="$SB/vault40b" "$OB" sync -y
assert "40 origin restored and correct" \
    bash -c "git -C '$SB/vault40b' remote get-url origin 2>/dev/null | grep -F '$SB/remote40.git'"

# 40d — the identity wins over a stale origin: it traveled with the vault.
git init -q --bare "$SB/remote40-alt.git"
printf 'REMOTE=%s\nBRANCH=main\n' "$SB/remote40-alt.git" > "$SB/vault40b/.ob-sync/config"
t "40 sync follows the identity to its remote" 0 \
    env -u OBS_REMOTE OBS_VAULT="$SB/vault40b" "$OB" sync -y
assert "40 origin re-pointed to the identity remote" \
    bash -c "git -C '$SB/vault40b' remote get-url origin 2>/dev/null | grep -F '$SB/remote40-alt.git'"
assert "40 the new remote received the vault" \
    bash -c "git -C '$SB/remote40-alt.git' ls-tree -r --name-only refs/heads/main 2>/dev/null | grep -qF 'note40.md'"

# 40e — migration: a legacy vault (origin, no identity) gains the card on
# its first locked run — silently, from its own origin.
git init -q --bare "$SB/remote40c.git"
mkdir -p "$SB/vault40c"
printf '# legacy vault\n' > "$SB/vault40c/legacy.md"
git -C "$SB/vault40c" init -q
git -C "$SB/vault40c" remote add origin "$SB/remote40c.git"
t "40 legacy vault first sync" 0 \
    env -u OBS_REMOTE OBS_VAULT="$SB/vault40c" "$OB" sync -y
assert "40 legacy vault migrated to .ob-sync" test -r "$SB/vault40c/.ob-sync/config"
assert "40 migration recorded the origin" \
    bash -c "grep -F 'REMOTE=$SB/remote40c.git' '$SB/vault40c/.ob-sync/config'"

# 40f — `ob-sync remote <url>` keeps origin and the identity in lockstep.
git init -q --bare "$SB/remote40d.git"
t "40 remote set-url succeeds" 0 env OBS_VAULT="$SB/vault40c" "$OB" remote "$SB/remote40d.git"
assert "40 remote set-url updates the identity" \
    bash -c "grep -F 'REMOTE=$SB/remote40d.git' '$SB/vault40c/.ob-sync/config'"
assert "40 origin matches the identity" \
    bash -c "git -C '$SB/vault40c' remote get-url origin 2>/dev/null | grep -F '$SB/remote40d.git'"

# 40g — a vault with NEITHER origin NOR identity still refuses honestly
# (9.4.2 behavior intact) and never gains an invented identity.
t "40 remote-less vault still refuses" 1 env -u OBS_REMOTE OBS_VAULT="$SB/vault39" "$OB" quick -y
assert "40 no identity invented for the remote-less vault" \
    bash -c "! test -e '$SB/vault39/.ob-sync'"

# 40h — the card is minimal: exactly REMOTE + BRANCH, never secrets.
assert "40 identity holds exactly REMOTE and BRANCH" \
    bash -c "test \"\$(grep -cE '^(REMOTE|BRANCH)=' '$SB/vault40/.ob-sync/config')\" = 2"
assert "40 identity never contains credentials" \
    bash -c "! grep -qiE 'ghp_|github_pat_|password|token=' '$SB/vault40/.ob-sync/config'"

# 40i — status surfaces the identity, human and machine-readable.
assertout "40 status shows the identity row" "ob-sync/config" \
    env OBS_VAULT="$SB/vault40" "$OB" status
if command -v python3 >/dev/null 2>&1; then
    t "40 status --json parses with the identity section" 0 \
        bash -c "env OBS_VAULT='$SB/vault40' '$OB' status --json 2>/dev/null | python3 -m json.tool >/dev/null"
    t "40 status --json exposes the identity remote" 0 \
        bash -c "env OBS_VAULT='$SB/vault40' '$OB' status --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
vc = d[\"vault_config\"]
assert vc[\"present\"] is True, vc
assert vc[\"remote\"].endswith(\"remote40.git\"), vc'"

# 40j — read-only commands never write the identity (migration is a
# locked-run behavior, not a side effect of looking around).
rm -rf "$SB/vault40c/.ob-sync"
env OBS_VAULT="$SB/vault40c" "$OB" status >/dev/null 2>&1 || :
assert "40 status never writes the identity" bash -c "! test -e '$SB/vault40c/.ob-sync'"
fi

echo "== 41. vault discovery reaches mounted drives (9.5.2) =="

# 41a — OB_DISCOVER_ROOTS replaces the default roots entirely: a vault
# under a fake mounted-media tree is auto-detected with no OBS_VAULT
# and no config VAULT (the field-reported /media/<user>/… case).
mkdir -p "$SB/media-root/shared/Obsidian/media-vault/.obsidian"
printf '# media vault\n' > "$SB/media-root/shared/Obsidian/media-vault/note41.md"
: > "$SB/cfg41"
t "41 vault under a media root is auto-detected" 0 \
    env -u OBS_VAULT OBS_CONFIG="$SB/cfg41" OB_DISCOVER_ROOTS="$SB/media-root" "$OB" status
assert "41 the media vault is the one detected" \
    bash -c "grep -qF 'Auto-detected vault: $SB/media-root/shared/Obsidian/media-vault' '$SB/out.txt'"

# 41b — two vaults under the override root, non-TTY: still an honest
# refusal (never a silent pick, never a crash).
mkdir -p "$SB/media-root/Obsidian/second/.obsidian"
t "41 two media vaults refuse honestly without a TTY" 1 \
    env -u OBS_VAULT OBS_CONFIG="$SB/cfg41" OB_DISCOVER_ROOTS="$SB/media-root" "$OB" status
assert "41 the refusal explains itself" \
    grep -q "Multiple vaults found" "$SB/out.txt"

# 41c — garbage roots (missing dirs, empty entries): discovery yields
# nothing, the tool degrades to the default vault path without noise.
t "41 garbage roots degrade to the default vault" 0 \
    env -u OBS_VAULT OBS_CONFIG="$SB/cfg41" OB_DISCOVER_ROOTS="/no/such/root::/also/absent" "$OB" status
assert "41 no unbound-variable noise on garbage roots" \
    bash -c "! grep -qE 'unbound variable|syntax error' '$SB/out.txt'"

# 41d — the switcher contract, at source level (the TTY prompts are
# exercised by the pty smoke tests of the release checklist).
assert "41 switcher offers a typed path with one vault" \
    grep -q "type a full vault path" "$OB"
assert "41 discovery probes the mountpoints" \
    bash -c "grep -q '/run/media' '$OB' && grep -q '\"/mnt\"' '$OB'"
assert "41 OB_DISCOVER_ROOTS override exists" \
    grep -q "OB_DISCOVER_ROOTS" "$OB"
assert "41 non-vault directories need confirmation" \
    grep -q "it may not be an Obsidian vault" "$OB"
assert "41 wrong typed paths are named honestly" \
    grep -q "No such directory" "$OB"

echo "== 42. self-update (9.6.0) =="
# Hermetic by construction: the "release" is a local file:// URL, the
# "offline network" is port 1 on localhost (connection refused — curl exit
# 7, the same code a dead Wi-Fi link produces), and every installed copy
# lives OUTSIDE any git work tree, exactly like ~/.local/bin. The harness
# itself runs with OB_NO_SELFUPDATE=1 (see the firewall above); each check
# here unsets it explicitly. The TTY gate is forced with
# OB_FORCE_UPDATE_CHECK=1 because the suite's stdout is always a pipe.
#
# curl is the ONE real dependency of this section: every scenario drives
# the actual curl binary. On a machine without curl — slim containers,
# minimal Termux installs — those scenarios would report phantom
# failures, so they self-skip the same way the root-write checks do:
# counted as passed, printed honestly as SKIP. CI installs curl
# explicitly (lint.yml), so the gate keeps full coverage there.
if command -v curl >/dev/null 2>&1; then
mkdir -p "$SB/rel" "$SB/norepo"
cp "$OB" "$SB/rel/ob-sync"
cp "$OB" "$SB/norepo/obinst"

# 42a — an up-to-date release changes nothing and stays silent on a
# non-TTY launch (cron/pipes must never see update chatter).
t "42 up-to-date release: no action, rc=0" 0 \
    env -u OB_NO_SELFUPDATE OB_FORCE_UPDATE_CHECK=1 \
        OB_UPDATE_URL="file://$SB/rel/ob-sync" "$SB/norepo/obinst" version
assert "42 up-to-date: installed file untouched" \
    grep -q 'readonly VERSION="9.6.1"' "$SB/norepo/obinst"
assert "42 up-to-date: silent on a piped launch" \
    bash -c "! grep -qE 'up to date|updated v|update check' '$SB/out.txt'"

# 42b — the offline path: refuse nothing, crash nothing, say it plainly.
t "42 offline launch continues with the current version" 0 \
    env -u OB_NO_SELFUPDATE OB_FORCE_UPDATE_CHECK=1 \
        OB_UPDATE_URL="http://127.0.0.1:1/ob-sync" "$SB/norepo/obinst" version
assert "42 offline: the bilingual notice is shown" \
    bash -c "grep -qF 'اینترنت خاموشه' '$SB/out.txt'"
assert "42 offline: the actual command still ran" \
    bash -c "grep -qE 'ob-sync 9\\.6\\.1' '$SB/out.txt'"

# 42c — the kill-switch: OB_NO_SELFUPDATE=1 must silence the feature
# completely, even against a forced check and an unreachable URL.
t "42 kill-switch silences the check completely" 0 \
    env OB_NO_SELFUPDATE=1 OB_FORCE_UPDATE_CHECK=1 \
        OB_UPDATE_URL="http://127.0.0.1:1/ob-sync" "$SB/norepo/obinst" version
assert "42 kill-switch: no notice, no network touched" \
    bash -c "! grep -qF 'اینترنت خاموشه' '$SB/out.txt'"

# 42d — a newer release: replace the installed copy and restart ON the
# new code (exec, same command line — 'update first, then run').
sed 's/^readonly VERSION="9\.6\.1"/readonly VERSION="9.9.9"/' "$OB" > "$SB/rel/ob-sync"
t "42 newer release replaces the installed copy and re-execs" 0 \
    env -u OB_NO_SELFUPDATE OB_FORCE_UPDATE_CHECK=1 \
        OB_UPDATE_URL="file://$SB/rel/ob-sync" "$SB/norepo/obinst" version
assert "42 update: the installed file carries the new version" \
    grep -q 'readonly VERSION="9.9.9"' "$SB/norepo/obinst"
assert "42 update: the run restarted on the new code" \
    bash -c "grep -qE 'ob-sync 9\\.9\\.9' '$SB/out.txt'"
assert "42 update: the swap is announced" \
    bash -c "grep -q 'updated v9.6.1' '$SB/out.txt'"

# 42e — a payload that is not a runnable ob-sync is refused, loudly,
# and the current version survives. (The fake passes bash -n — the
# embedded VERSION check is what catches it, exactly the point.)
printf '#!/bin/sh\necho nope\n' > "$SB/rel/ob-sync"
cp "$OB" "$SB/norepo/obinst2"
t "42 invalid release is refused, current version kept" 0 \
    env -u OB_NO_SELFUPDATE OB_FORCE_UPDATE_CHECK=1 \
        OB_UPDATE_URL="file://$SB/rel/ob-sync" "$SB/norepo/obinst2" version
assert "42 invalid release: honest refusal message" \
    bash -c "grep -q 'not a valid ob-sync' '$SB/out.txt'"
assert "42 invalid release: installed copy untouched" \
    grep -q 'readonly VERSION="9.6.1"' "$SB/norepo/obinst2"

# 42f — a copy inside a git checkout is NEVER overwritten (that would
# dirty the user's tree): advisory only, naming the new version.
cp "$OB" "$SB/rel/ob-sync"
sed -i 's/^readonly VERSION="9\.6\.1"/readonly VERSION="9.9.9"/' "$SB/rel/ob-sync"
t "42 git-checkout copy is protected from overwrite" 0 \
    env -u OB_NO_SELFUPDATE OB_FORCE_UPDATE_CHECK=1 \
        OB_UPDATE_URL="file://$SB/rel/ob-sync" "$OB" version
assert "42 checkout guard: the repo file is untouched" \
    grep -q 'readonly VERSION="9.6.1"' "$OB"
assert "42 checkout guard: advisory names the checkout" \
    bash -c "grep -q 'git checkout' '$SB/out.txt'"

# 42g — the explicit `update` command forces the check WITHOUT a TTY
# (and without OB_FORCE_UPDATE_CHECK), reports and returns — no exec.
cp "$OB" "$SB/norepo/obinst3"
t "42 'update' command forces the check, no TTY needed" 0 \
    env -u OB_NO_SELFUPDATE OB_UPDATE_URL="file://$SB/rel/ob-sync" "$SB/norepo/obinst3" update
assert "42 update cmd: installed copy carries the new version" \
    grep -q 'readonly VERSION="9.9.9"' "$SB/norepo/obinst3"
assert "42 update cmd: reports done" \
    bash -c "grep -q 'updated v9.6.1' '$SB/out.txt'"

# 42h — running NEWER than the release (dev build): nothing to do, said
# honestly. obinst now carries 9.9.9; the release file is reset to 9.6.1.
cp "$OB" "$SB/rel/ob-sync"
t "42 newer dev build than the release: up-to-date, no downgrade" 0 \
    env -u OB_NO_SELFUPDATE OB_UPDATE_URL="file://$SB/rel/ob-sync" "$SB/norepo/obinst" update
assert "42 dev build: kept on the newer version" \
    grep -q 'readonly VERSION="9.9.9"' "$SB/norepo/obinst"
assert "42 dev build: the no-op is announced" \
    bash -c "grep -q 'up to date' '$SB/out.txt'"

# 42i — --json runs are machine documents: the check is skipped
# entirely, even when forced and a newer release sits one URL away.
cp "$OB" "$SB/norepo/obinst4"
t "42 --json runs skip the check (pure document)" 0 \
    env -u OB_NO_SELFUPDATE OB_FORCE_UPDATE_CHECK=1 \
        OB_UPDATE_URL="file://$SB/rel/ob-sync" "$SB/norepo/obinst4" status --json
assert "42 --json: no update chatter in the document" \
    bash -c "! grep -qE 'up to date|updated v|update check' '$SB/out.txt'"
assert "42 --json: no install happened" \
    grep -q 'readonly VERSION="9.6.1"' "$SB/norepo/obinst4"

# 42j — cron/pipes (no TTY, no force) never trigger a check at all.
cp "$OB" "$SB/norepo/obinst5"
t "42 non-interactive run skips the check silently" 0 \
    env -u OB_NO_SELFUPDATE OB_UPDATE_URL="file://$SB/rel/ob-sync" "$SB/norepo/obinst5" version
assert "42 non-interactive: no download, no chatter" \
    bash -c "! grep -qE 'up to date|updated v|update check' '$SB/out.txt'"
assert "42 non-interactive: installed copy untouched" \
    grep -q 'readonly VERSION="9.6.1"' "$SB/norepo/obinst5"
else
    echo "  [SKIP] 42a–42j self-update scenarios (30 checks — curl is not"
    echo "         installed; the launch-time check silently degrades without it)"
    PASS=$((PASS + 30))
fi

# 42k — source-level contract of the feature (no curl needed).
assert "42 OB_NO_SELFUPDATE knob exists" \
    bash -c "grep -q 'OB_NO_SELFUPDATE' '$OB'"
assert "42 the release URL is the asset itself (no API)" \
    bash -c "grep -q 'releases/latest/download/ob-sync' '$OB'"
assert "42 the offline notice names the outage in English too" \
    bash -c "grep -q 'network unreachable; running the current version' '$OB'"

echo "== 43. hardening backports (9.6.1) =="
# Three field-found defects (branch-arg injection via OBS_BRANCH, vault
# escape via OBS_ATTACH_DIR, init_log hang on a character-device OBS_LOG)
# were fixed surgically in 9.6.1. Each check re-runs the original PoC in
# the hermetic sandbox and demands the SAFE outcome.

# 43 setup — a dedicated device with its own bare remote.
git init -q --bare "$SB/remote43.git"
git -C "$SB/remote43.git" symbolic-ref HEAD refs/heads/main
mkdir -p "$SB/vault43"
git -C "$SB/vault43" init -q
git -C "$SB/vault43" config user.email tester@local
git -C "$SB/vault43" config user.name tester
printf '# v43\n' > "$SB/vault43/note.md"
git -C "$SB/vault43" add . && git -C "$SB/vault43" commit -qm "v43 seed"
env OBS_REMOTE="$SB/remote43.git" OBS_VAULT="$SB/vault43" "$OB" init -y >/dev/null 2>&1
printf 'x\n' >> "$SB/vault43/note.md"
git -C "$SB/vault43" add . && git -C "$SB/vault43" commit -qm "v43 change"

# 43a — a hostile OBS_BRANCH must be refused BEFORE git ever parses it
# (9.5.x passed it straight into `git push`, so --receive-pack=<cmd>
# executed an arbitrary local command).
printf '#!/bin/sh\ntouch "%s/pwned43"\n' "$SB" > "$SB/pwned43.sh"
chmod +x "$SB/pwned43.sh"
rm -f "$SB/pwned43"
t "43 hostile OBS_BRANCH refused (no git execution)" 1 \
    env OBS_VAULT="$SB/vault43" OBS_BRANCH="--receive-pack=$SB/pwned43.sh" "$OB" push
assert "43 hostile branch: honest error names the refusal" \
    grep -q "Invalid branch name" "$SB/out.txt"
assert "43 hostile branch: injected helper never executed" \
    bash -c "[[ ! -e '$SB/pwned43' ]]"

# 43b — OBS_ATTACH_DIR with ".." (or an absolute path) must be rejected:
# the move would place attachments OUTSIDE the vault and the next sync
# would commit that deletion to every device.
printf 'orphan\n' > "$SB/vault43/orphan-43.png"
t "43 attach-dir traversal refused" 1 \
    env OBS_VAULT="$SB/vault43" OBS_ATTACH_DIR="../escaped43" "$OB" organize --fix
assert "43 attach-dir: honest error names the refusal" \
    grep -q "Unsafe attach dir" "$SB/out.txt"
assert "43 attach-dir: nothing left the vault" \
    bash -c "[[ ! -e '$SB/escaped43' ]]"

# 43c — OBS_LOG pointing at a character device must degrade to stdout,
# never hang: `wc -c <` on /dev/full or /dev/zero reads an endless
# zero-byte stream (found by the 7-hour fuzz campaign, fixed as P8).
if command -v timeout >/dev/null 2>&1 && [[ -e /dev/full || -e /dev/zero ]]; then
    chardev=/dev/full; [[ -e "$chardev" ]] || chardev=/dev/zero
    t "43 char-device OBS_LOG cannot hang the run" 0 \
        timeout 5 env OBS_LOG="$chardev" OBS_VAULT="$SB/vault43" "$OB" status
else
    echo "  [SKIP] 43 char-device log check (no timeout(1) or no char device)"
    PASS=$((PASS + 1))
fi

# 43d — source-level contract (no runtime needed).
assert "43 branch_guard gates git with check-ref-format" \
    bash -c "grep -q 'check-ref-format --branch' '$OB'"
assert "43 init_log only sizes regular files" \
    bash -c "grep -q 'P8: only a regular file can be sized safely' '$OB'"

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
