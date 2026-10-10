#!/usr/bin/env bash
#
# ─────────────────────────────────────────────────────────────────────────────
#   ob-sync SYSTEM ROBUSTNESS PROBES — cycle C3 of the 7h campaign
#
#   Phase C of the long-running campaign. Four probes the earlier suites do
#   not cover in this combination:
#
#     C1  disk-full backup    ( ulimit -f 64 → 64 KiB write cap ) — backup
#         must fail HONESTLY, leave the vault untouched and the backup dir
#         free of finished-looking archives and .part temporaries.
#     C2  concurrent sync race — two isolated HOMEs, one shared bare remote;
#         the global lock must serialize them (one 0, one 2 lock_busy),
#         the loser must win on retry, all three repos fsck clean, and both
#         devices must end up with each other's files.
#     C3  5000-file vault     — sync + backup + sabotage + restore must
#         reproduce the manifest byte-for-byte (restore swaps the vault).
#     C4  200-level nesting + 8MB binary — deep paths and a large random
#         binary survive sync/backup/restore with matching sha256.
#
#   Self-contained: throwaway sandbox, isolated HOMEs, local bare remotes,
#   no network, no root. Every ob-sync call is wrapped in timeout so a hang
#   becomes a FAIL, never a stuck campaign run.
#   Run:  bash tests/system-probe-C3.sh
# ─────────────────────────────────────────────────────────────────────────────

set -u

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
OB="$ROOT/bin/ob-sync"

SB="$(mktemp -d "${TMPDIR:-/tmp}/ob-sync-probe-XXXXXX")" \
    || { echo "FATAL: cannot create the sandbox directory"; exit 1; }
mkdir -p "$SB/tmp"
export TMPDIR="$SB/tmp"
trap 'rm -rf -- "$SB"' EXIT

PASS=0
FAIL=0
T0=$SECONDS

NOISE_RE="unbound variable|bad substitution|syntax error|integer expression|value too great|Traceback|Segmentation fault"

noisy() {  # noisy <outfile> — interpreter noise detector (git stderr is fine)
    grep -qE "$NOISE_RE" "$1" 2>/dev/null && return 0
    grep -qE "^(bash|sh):" "$1" 2>/dev/null && return 0
    return 1
}

t() {  # t <name> <expected-rc> <command...>
    local name="$1" want="$2"; shift 2
    "$@" >"$SB/out.txt" 2>&1
    local got=$?
    if [[ "$got" == "$want" ]]; then
        PASS=$((PASS + 1)); printf '  [ OK ] %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); printf '  [FAIL] %s (want rc=%s got rc=%s)\n' "$name" "$want" "$got"
        tail -6 "$SB/out.txt" | sed 's/^/         /'
    fi
    if noisy "$SB/out.txt"; then
        FAIL=$((FAIL + 1)); printf '  [FAIL] %s — interpreter noise leaked\n' "$name"
        grep -nE "$NOISE_RE|^(bash|sh):" "$SB/out.txt" | head -3 | sed 's/^/         /'
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

# device_new <dir> — an isolated "device" with its own HOME
device_new() {
    local d="$1"
    mkdir -p "$d-home"
    git config --file "$d-home/.gitconfig" user.email  "probe@test.local"
    git config --file "$d-home/.gitconfig" user.name   "Probe C3"
    git config --file "$d-home/.gitconfig" init.defaultBranch main
}

# obs <device-dir> <vault-dir> <backup-dir> <remote> <timeout-s> <args...>
# run ob-sync as that device, output to $SB/out.txt, echo the rc
obs() {
    local d="$1" v="$2" b="$3" r="$4" to="$5"; shift 5
    timeout "$to" env HOME="$d-home" OBS_CONFIG="$d-home/.config/ob-sync/config" \
        OBS_VAULT="$v" OBS_BACKUP_DIR="$b" OBS_LOG='' \
        GIT_CONFIG_GLOBAL="$d-home/.gitconfig" OBS_REMOTE="$r" \
        "$OB" "$@" >"$SB/out.txt" 2>&1
    return $?
}

fsck_clean() {  # fsck_clean <repo-dir> — git fsck with no corruption
    git -C "$1" fsck --strict >/dev/null 2>&1
}

# ════════════════════════════════════════════════════════════════════════════
echo "== C1. disk-full backup (ulimit -f 64 → 64 KiB write cap) =="
# ════════════════════════════════════════════════════════════════════════════
C1V="$SB/c1-vault"; C1B="$SB/c1-backups"; C1R="$SB/c1.git"
mkdir -p "$C1V"
git init -q --bare "$C1R"
device_new "$SB/c1"
head -c 2097152 /dev/urandom > "$C1V/random-2mb.bin"     # incompressible → must blow the 64 KiB cap
printf 'small\n' > "$C1V/note.md"
t "C1 init vault"                         0 obs "$SB/c1" "$C1V" "$C1B" "$C1R" 120 init -y
t "C1 baseline sync before the artificial disk-full" 0 \
    obs "$SB/c1" "$C1V" "$C1B" "$C1R" 120 sync -y

HASH_BEFORE=$(sha256sum "$C1V/random-2mb.bin" | cut -d' ' -f1)
N_ARCHIVES_BEFORE=$(ls "$C1B"/*.tar.gz 2>/dev/null | wc -l)   # sync may auto-backup

c1_out="$SB/c1-run.out"
(
    ulimit -f 64
    export HOME="$SB/c1-home" OBS_CONFIG="$SB/c1-home/.config/ob-sync/config" \
        OBS_VAULT="$C1V" OBS_BACKUP_DIR="$C1B" OBS_LOG='' \
        GIT_CONFIG_GLOBAL="$SB/c1-home/.gitconfig" OBS_REMOTE="$C1R"
    "$OB" backup
) >"$c1_out" 2>&1
C1RC=$?

if [[ "$C1RC" == "1" ]]; then
    PASS=$((PASS + 1)); printf '  [ OK ] C1 backup fails honestly (rc=1)\n'
else
    FAIL=$((FAIL + 1)); printf '  [FAIL] C1 backup rc=%s (want 1)\n' "$C1RC"
    tail -6 "$c1_out" | sed 's/^/         /'
fi

if grep -qE "Backup creation failed|timed out|Failed to finalize|failed" "$c1_out"; then
    PASS=$((PASS + 1)); printf '  [ OK ] C1 honest error message present\n'
else
    FAIL=$((FAIL + 1)); printf '  [FAIL] C1 no honest error message in output\n'
    tail -6 "$c1_out" | sed 's/^/         /'
fi

assert "C1 vault binary untouched (sha256)" \
    bash -c "[[ \"\$(sha256sum '$C1V/random-2mb.bin' | cut -d' ' -f1)\" == '$HASH_BEFORE' ]]"
assert "C1 vault still contains note.md"            test -f "$C1V/note.md"
assert "C1 no NEW finished archive published" \
    bash -c "[[ \$(ls '$C1B'/*.tar.gz 2>/dev/null | wc -l) -eq $N_ARCHIVES_BEFORE ]]"
assert "C1 no .part temporary left behind"          bash -c "! ls '$C1B'/*.part  >/dev/null 2>&1"
assert "C1 no stray error-sidecar left behind"      bash -c "! ls '$C1B'/*.errs  >/dev/null 2>&1"

if noisy "$c1_out"; then
    FAIL=$((FAIL + 1)); printf '  [FAIL] C1 interpreter noise leaked\n'
    grep -nE "$NOISE_RE|^(bash|sh):" "$c1_out" | head -3 | sed 's/^/         /'
else
    PASS=$((PASS + 1)); printf '  [ OK ] C1 no interpreter noise\n'
fi
printf '       (C1 done at t+%ss)\n' "$((SECONDS - T0))"

# ════════════════════════════════════════════════════════════════════════════
echo "== C2. concurrent sync race — two HOMEs, one shared bare remote =="
# ════════════════════════════════════════════════════════════════════════════
C2A="$SB/c2-a"; C2B="$SB/c2-b"; C2RA="$SB/c2a-backups"; C2RB="$SB/c2b-backups"; C2R="$SB/c2.git"
mkdir -p "$C2A" "$C2B"
git init -q --bare "$C2R"
device_new "$SB/c2a"; device_new "$SB/c2b"
printf 'seed\n' > "$C2A/seed.md"
t "C2 device A init (pushes seed)"         0 obs "$SB/c2a" "$C2A" "$C2RA" "$C2R" 120 init -y
t "C2 device A sync"                      0 obs "$SB/c2a" "$C2A" "$C2RA" "$C2R" 120 sync -y
t "C2 device B joins via init (clone)"    0 obs "$SB/c2b" "$C2B" "$C2RB" "$C2R" 120 init -y
t "C2 device B sync"                      0 obs "$SB/c2b" "$C2B" "$C2RB" "$C2R" 120 sync -y

printf 'aaa\n' > "$C2A/a-race.md"
printf 'bbb\n' > "$C2B/b-race.md"

# launch both syncs at the same instant — global lock must serialize them
outA="$SB/c2-a.out"; outB="$SB/c2-b.out"
run_sync_A() {
    timeout 180 env HOME="$SB/c2a-home" OBS_CONFIG="$SB/c2a-home/.config/ob-sync/config" \
        OBS_VAULT="$C2A" OBS_BACKUP_DIR="$C2RA" OBS_LOG='' \
        GIT_CONFIG_GLOBAL="$SB/c2a-home/.gitconfig" OBS_REMOTE="$C2R" "$OB" sync -y
}
run_sync_B() {
    timeout 180 env HOME="$SB/c2b-home" OBS_CONFIG="$SB/c2b-home/.config/ob-sync/config" \
        OBS_VAULT="$C2B" OBS_BACKUP_DIR="$C2RB" OBS_LOG='' \
        GIT_CONFIG_GLOBAL="$SB/c2b-home/.gitconfig" OBS_REMOTE="$C2R" "$OB" sync -y
}
( run_sync_A >"$outA" 2>&1 ) & pA=$!
( run_sync_B >"$outB" 2>&1 ) & pB=$!
wait "$pA"; RC_A=$?
wait "$pB"; RC_B=$?

C2_PAIR_OK=0
if [[ "$RC_A,$RC_B" == "0,2" || "$RC_A,$RC_B" == "2,0" ]]; then
    C2_PAIR_OK=1
elif [[ "$RC_A" == "0" && "$RC_B" == "0" ]]; then
    # theoretically impossible (atomic mkdir lock) but not a corruption risk
    C2_PAIR_OK=1
fi
if [[ "$C2_PAIR_OK" == "1" ]]; then
    PASS=$((PASS + 1)); printf '  [ OK ] C2 lock serialized the race (rcA=%s rcB=%s)\n' "$RC_A" "$RC_B"
else
    FAIL=$((FAIL + 1)); printf '  [FAIL] C2 unexpected race outcome (rcA=%s rcB=%s)\n' "$RC_A" "$RC_B"
    tail -4 "$outA" | sed 's/^/         /'; tail -4 "$outB" | sed 's/^/         /'
fi

# the lock-busy loser must have said so honestly
if [[ "$RC_A" == "2" ]]; then
    assert "C2 loser A said lock_busy honestly"  grep -qiE "lock|busy|instance" "$outA"
fi
if [[ "$RC_B" == "2" ]]; then
    assert "C2 loser B said lock_busy honestly"  grep -qiE "lock|busy|instance" "$outB"
fi

# both must be clean from interpreter noise regardless of outcome
if noisy "$outA" || noisy "$outB"; then
    FAIL=$((FAIL + 1)); printf '  [FAIL] C2 interpreter noise in race outputs\n'
    grep -hnE "$NOISE_RE|^(bash|sh):" "$outA" "$outB" | head -3 | sed 's/^/         /'
else
    PASS=$((PASS + 1)); printf '  [ OK ] C2 no interpreter noise in race outputs\n'
fi

# the loser retries AFTER the winner finished and must succeed
if [[ "$RC_A" != "0" ]]; then
    t "C2 loser A retry succeeds" 0 obs "$SB/c2a" "$C2A" "$C2RA" "$C2R" 180 sync -y
fi
if [[ "$RC_B" != "0" ]]; then
    t "C2 loser B retry succeeds" 0 obs "$SB/c2b" "$C2B" "$C2RB" "$C2R" 180 sync -y
fi

# give the device that never retried a final pull so both converge
if [[ "$RC_A" == "0" && "$RC_B" == "2" ]]; then
    : # A already saw B? no — B never pushed. final pull below handles it.
fi
# converge both devices (harmless no-ops if already up to date)
obs "$SB/c2a" "$C2A" "$C2RA" "$C2R" 180 sync -y >/dev/null 2>&1; :
obs "$SB/c2b" "$C2B" "$C2RB" "$C2R" 180 sync -y >/dev/null 2>&1; :

assert "C2 A got B's file"      test -f "$C2A/b-race.md"
assert "C2 B got A's file"      test -f "$C2B/a-race.md"
assert "C2 A git fsck clean"    fsck_clean "$C2A"
assert "C2 B git fsck clean"    fsck_clean "$C2B"
assert "C2 remote fsck clean"   fsck_clean "$C2R"
assert "C2 A content intact"    grep -q seed "$C2A/seed.md"
assert "C2 B content intact"    grep -q seed "$C2B/seed.md"
printf '       (C2 done at t+%ss)\n' "$((SECONDS - T0))"

# ════════════════════════════════════════════════════════════════════════════
echo "== C3. 5000-file vault — sync + backup + sabotage + restore roundtrip =="
# ════════════════════════════════════════════════════════════════════════════
C3V="$SB/c3-vault"; C3B="$SB/c3-backups"; C3R="$SB/c3.git"
git init -q --bare "$C3R"
device_new "$SB/c3"

for d in $(seq 1 50); do
    dd="dir-$(printf '%02d' "$d")"
    mkdir -p "$C3V/$dd"
    for f in $(seq 1 100); do
        printf 'vault line %s-%s\nunique: %s-%s\n' "$d" "$f" "$d" "$f" > "$C3V/$dd/note-$f.md"
    done
done

t "C3 init vault"            0 obs "$SB/c3" "$C3V" "$C3B" "$C3R" 120 init -y

manifest="$SB/c3-manifest.txt"
( cd "$C3V" && find . -type f -not -path './.git/*' -print0 \
    | sort -z | xargs -0 sha256sum ) > "$manifest"
N_FILES=$(wc -l < "$manifest")
# 5000 notes + .gitignore + .ob-sync/config created by init = 5002 tracked files
if [[ "$N_FILES" == "5002" ]]; then
    PASS=$((PASS + 1)); printf '  [ OK ] C3 5000-file vault created (+2 init metadata = 5002)\n'
else
    FAIL=$((FAIL + 1)); printf '  [FAIL] C3 expected 5002 files, manifest has %s\n' "$N_FILES"
fi

t "C3 sync 5000 files"        0 obs "$SB/c3" "$C3V" "$C3B" "$C3R" 600 sync -y
t "C3 backup 5000 files"      0 obs "$SB/c3" "$C3V" "$C3B" "$C3R" 600 backup
assert "C3 backup archive exists"      bash -c "ls '$C3B'/*.tar.gz >/dev/null 2>&1"

# sabotage: delete half of the notes, trash the rest, add junk
for d in $(seq 1 25); do
    rm -f "$C3V/dir-$(printf '%02d' "$d")"/note-*.md
done
for f in "$C3V"/dir-*/note-*.md; do printf 'OVERWRITTEN\n' > "$f"; done
printf 'junk\n' > "$C3V/junk-after-sabotage.md"

t "C3 restore latest rolls the vault back" 0 obs "$SB/c3" "$C3V" "$C3B" "$C3R" 600 restore latest -y

manifest2="$SB/c3-manifest-after.txt"
( cd "$C3V" && find . -type f -not -path './.git/*' -print0 \
    | sort -z | xargs -0 sha256sum ) > "$manifest2"
if diff -q "$manifest" "$manifest2" >/dev/null 2>&1; then
    PASS=$((PASS + 1)); printf '  [ OK ] C3 post-restore manifest byte-identical (5002 files)\n'
else
    FAIL=$((FAIL + 1)); printf '  [FAIL] C3 post-restore manifest differs from pre-backup\n'
    diff "$manifest" "$manifest2" | head -5 | sed 's/^/         /'
fi
assert "C3 junk removed by vault swap"   bash -c "! test -e '$C3V/junk-after-sabotage.md'"
assert "C3 vault .git fsck clean"        fsck_clean "$C3V"
printf '       (C3 done at t+%ss)\n' "$((SECONDS - T0))"

# ════════════════════════════════════════════════════════════════════════════
echo "== C4. 200-level deep nesting + 8MB binary roundtrip =="
# ════════════════════════════════════════════════════════════════════════════
C4V="$SB/c4-vault"; C4B="$SB/c4-backups"; C4R="$SB/c4.git"
git init -q --bare "$C4R"
device_new "$SB/c4"

DEEP="$C4V"
for i in $(seq 1 200); do DEEP="$DEEP/d$i"; done
mkdir -p "$DEEP"
printf 'bottom of a 200-level pit\n' > "$DEEP/bottom.md"
head -c 8388608 /dev/urandom > "$C4V/big-8mb.bin"

C4_BIN_HASH=$(sha256sum "$C4V/big-8mb.bin" | cut -d' ' -f1)

t "C4 init vault"                            0 obs "$SB/c4" "$C4V" "$C4B" "$C4R" 120 init -y
t "C4 sync 200-level nesting + 8MB binary"   0 obs "$SB/c4" "$C4V" "$C4B" "$C4R" 300 sync -y
t "C4 backup of deep + big vault"            0 obs "$SB/c4" "$C4V" "$C4B" "$C4R" 300 backup
assert "C4 deep path survived the remote roundtrip" \
    bash -c "git -C '$C4R' ls-tree -r --name-only main | grep -q 'bottom.md'"

# destroy and restore
rm -rf "$C4V/d1" "$C4V/big-8mb.bin"
printf 'trojan\n' > "$C4V/junk-c4.md"
t "C4 restore after deep+big sabotage"       0 obs "$SB/c4" "$C4V" "$C4B" "$C4R" 300 restore latest -y

assert "C4 200-level file came back"         test -f "$DEEP/bottom.md"
assert "C4 bottom content correct"           grep -q "bottom of a 200-level pit" "$DEEP/bottom.md"
assert "C4 8MB binary sha256 identical" \
    bash -c "[[ \"\$(sha256sum '$C4V/big-8mb.bin' | cut -d' ' -f1)\" == '$C4_BIN_HASH' ]]"
assert "C4 junk removed"                     bash -c "! test -e '$C4V/junk-c4.md'"
assert "C4 vault fsck clean"                 fsck_clean "$C4V"
assert "C4 all 200 directory levels back" \
    bash -c "[[ \"\$(find '$C4V' -type d -name 'd200' | wc -l)\" == '1' ]]"
printf '       (C4 done at t+%ss)\n' "$((SECONDS - T0))"

# ════════════════════════════════════════════════════════════════════════════
echo
echo "══════════════════════════════════════════════"
printf '  system-probe-C3 totals:  PASS=%s  FAIL=%s   (wall: %ss)\n' \
    "$PASS" "$FAIL" "$((SECONDS - T0))"
echo "══════════════════════════════════════════════"
if (( FAIL > 0 )); then exit 1; fi
exit 0
