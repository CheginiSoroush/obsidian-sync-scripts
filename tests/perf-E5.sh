#!/usr/bin/env bash
#
# ─────────────────────────────────────────────────────────────────────────────
#   ob-sync PERFORMANCE BENCH — phase E of the 7h campaign (reusable)
#
#   Builds a 1200-file vault (40 dirs × 30 notes), then times the three
#   core operations against a local bare remote:
#
#       SYNC      first full synchronization of 1200 files
#       BACKUP    verified tar.gz backup of the synced vault
#       RESTORE   restore latest -y after sabotage (incl. safety copy)
#
#   Output (machine-readable, one per line):
#       SYNC_MS=<n>  BACKUP_MS=<n>  RESTORE_MS=<n>  FILES=1200  PASS=<n>  FAIL=<n>
#
#   The caller (cron agent) stores the first run as baseline in
#   LONGRUN-STATE.json findings[0]; later runs alert at > 3× baseline.
#
#   Self-contained: throwaway sandbox, isolated HOME, local bare remote,
#   no network, no root. Run:  bash tests/perf-E5.sh
# ─────────────────────────────────────────────────────────────────────────────

set -u

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
OB="$ROOT/bin/ob-sync"

SB="$(mktemp -d "${TMPDIR:-/tmp}/ob-sync-perf-XXXXXX")" \
    || { echo "FATAL: cannot create the sandbox directory"; exit 1; }
mkdir -p "$SB/tmp"
export TMPDIR="$SB/tmp"
trap 'rm -rf -- "$SB"' EXIT

PASS=0
FAIL=0

V="$SB/vault"; B="$SB/backups"; R="$SB/remote.git"
mkdir -p "$V"
git init -q --bare "$R"

H="$SB/home"
mkdir -p "$H"
git config --file "$H/.gitconfig" user.email  "perf@test.local"
git config --file "$H/.gitconfig" user.name   "Perf E5"
git config --file "$H/.gitconfig" init.defaultBranch main

obs() {
    timeout 600 env HOME="$H" OBS_CONFIG="$H/.config/ob-sync/config" \
        OBS_VAULT="$V" OBS_BACKUP_DIR="$B" OBS_LOG='' \
        GIT_CONFIG_GLOBAL="$H/.gitconfig" OBS_REMOTE="$R" \
        "$OB" "$@"
}

now_ms() { date +%s%3N; }

# ── build the 1200-file vault ────────────────────────────────────────────────
for d in $(seq 1 40); do
    dd="sec-$(printf '%02d' "$d")"
    mkdir -p "$V/$dd"
    for f in $(seq 1 30); do
        printf '# perf note %s-%s\n\nbody line with unique token %s-%s\n' \
            "$d" "$f" "$d" "$f" > "$V/$dd/note-$f.md"
    done
done
N=$(find "$V" -type f | wc -l)
if [[ "$N" == "1200" ]]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1)); echo "FATAL: expected 1200 files, got $N" >&2; exit 1
fi

# ── time sync (includes init on first run? no — init separately, unmeasured) ─
obs init -y >/dev/null 2>&1 || { echo "FATAL: init failed" >&2; exit 1; }

T0=$(now_ms)
obs sync -y >"$SB/sync.out" 2>&1; SYNC_RC=$?
T1=$(now_ms)
SYNC_MS=$((T1 - T0))

# ── time backup ──────────────────────────────────────────────────────────────
T2=$(now_ms)
obs backup >"$SB/backup.out" 2>&1; BACKUP_RC=$?
T3=$(now_ms)
BACKUP_MS=$((T3 - T2))

# ── sabotage then time restore ───────────────────────────────────────────────
rm -f "$V"/sec-*/note-*.md
printf 'junk\n' > "$V/junk-perf.md"
T4=$(now_ms)
obs restore latest -y >"$SB/restore.out" 2>&1; RESTORE_RC=$?
T5=$(now_ms)
RESTORE_MS=$((T5 - T4))

# ── sanity: rc 0 everywhere + content really came back ───────────────────────
[[ "$SYNC_RC" == "0" ]]    && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); echo "SYNC rc=$SYNC_RC" >&2; }
[[ "$BACKUP_RC" == "0" ]]  && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); echo "BACKUP rc=$BACKUP_RC" >&2; }
[[ "$RESTORE_RC" == "0" ]] && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); echo "RESTORE rc=$RESTORE_RC" >&2; }
[[ -f "$V/sec-01/note-1.md" && -f "$V/sec-40/note-30.md" && ! -e "$V/junk-perf.md" ]] \
    && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); echo "RESTORE content check failed" >&2; }

printf 'SYNC_MS=%s\nBACKUP_MS=%s\nRESTORE_MS=%s\nFILES=1200\nPASS=%s\nFAIL=%s\n' \
    "$SYNC_MS" "$BACKUP_MS" "$RESTORE_MS" "$PASS" "$FAIL"
if (( FAIL > 0 )); then exit 1; fi
exit 0
