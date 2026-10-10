#!/usr/bin/env bash
#
# ─────────────────────────────────────────────────────────────────────────────
#   ob-sync RANDOMIZED HUMAN-ERROR FUZZ  — cycle C2 of the 7h campaign
#
#   Unlike human-error-attacks.sh (hand-designed attacks), this suite
#   RANDOMIZES inputs on every dimension and demands the same contract:
#
#     · never corrupt or lose vault data,
#     · never hang, never die by signal, never leak interpreter noise,
#     · every failure is honest (rc ∈ {0,1,2} + a non-empty message),
#     · hostile filenames survive a full two-device sync roundtrip.
#
#     F1  env garbage storm     (random OBS_* × random garbage × random cmd)
#     F2  config file torture   (urandom bytes, dirs, symlinks, huge, BOM)
#     F3  CLI arg fuzz          (random flag/command soup, EOF stdin)
#     F4  hostile filename      (emoji/RTL/newline/quote/$()/180-char …)
#         roundtrip             (device A → bare remote → device B → back)
#     F5  empty & oversized     (0-byte, whitespace-only, 1MB, 100k lines)
#
#   Self-contained: throwaway sandbox, isolated HOMEs, local bare remote,
#   no network, no root. Deterministic seed via FUZZ_SEED (default 20261010).
#   Run:  bash tests/fuzz-human-C2.sh [seed]
# ─────────────────────────────────────────────────────────────────────────────

set -u

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
OB="$ROOT/bin/ob-sync"

SB="$(mktemp -d "${TMPDIR:-/tmp}/ob-sync-fuzz-XXXXXX")" \
    || { echo "FATAL: cannot create the sandbox directory"; exit 1; }
mkdir -p "$SB/tmp"
export TMPDIR="$SB/tmp"
trap 'rm -rf -- "$SB"' EXIT

FUZZ_SEED="${1:-20261010}"
RANDOM="$FUZZ_SEED"

PASS=0
FAIL=0
NOISE_RE="unbound variable|bad substitution|syntax error|integer expression|value too great|Traceback|Segmentation fault"

# interpreter-noise / crash detector: raw `bash:`/`sh:` lines, bash-internal
# messages, tracebacks, segfaults. git's own stderr (fatal:/warning:) is NOT
# noise — the tool is required to surface it.
noisy() {
    local out="$1"
    grep -qE "$NOISE_RE" "$out" 2>/dev/null && return 0
    grep -qE "^(bash|sh):" "$out" 2>/dev/null && return 0
    return 1
}

# evaluate <label> <outfile> <rc> — the fuzz verdict for one round
verdict() {
    local label="$1" out="$2" rc="$3"
    if (( rc >= 128 )); then
        FAIL=$((FAIL + 1)); printf '  [FAIL] %s — DIED BY SIGNAL (rc=%s)\n' "$label" "$rc"
        tail -6 "$out" | sed 's/^/         /'; return
    fi
    if (( rc == 124 || rc == 126 || rc == 127 )); then
        FAIL=$((FAIL + 1)); printf '  [FAIL] %s — hang/exec anomaly (rc=%s)\n' "$label" "$rc"
        tail -6 "$out" | sed 's/^/         /'; return
    fi
    if (( rc > 2 )); then
        FAIL=$((FAIL + 1)); printf '  [FAIL] %s — unexpected rc=%s (contract: 0/1/2)\n' "$label" "$rc"
        tail -6 "$out" | sed 's/^/         /'; return
    fi
    if noisy "$out"; then
        FAIL=$((FAIL + 1)); printf '  [FAIL] %s — interpreter noise leaked (rc=%s)\n' "$label" "$rc"
        grep -E "$NOISE_RE|^(bash|sh):" "$out" | head -3 | sed 's/^/         /'; return
    fi
    if (( rc != 0 )) && [[ ! -s "$out" ]]; then
        FAIL=$((FAIL + 1)); printf '  [FAIL] %s — silent failure (rc=%s, empty output)\n' "$label" "$rc"
        return
    fi
    PASS=$((PASS + 1)); printf '  [ OK ] %s (rc=%s)\n' "$label" "$rc"
}

# ob <home> [K=V overrides...] -- <args...>  — run one instrumented round
ob() {
    local h="$1"; shift
    local -a pre=()
    while [[ "${1:-}" != "--" ]]; do pre+=("$1"); shift; done
    shift
    timeout 30 env HOME="$h" OBS_CONFIG="$h/.config/ob-sync/config" \
        GIT_CONFIG_GLOBAL="$h/.gitconfig" OBS_LOG= "${pre[@]}" \
        "$OB" "$@" </dev/null
}

vault_ok() {  # the base vault must never lose its note or its git sanity
    [[ -f "$BASE/note.md" ]] && git -C "$BASE" fsck >/dev/null 2>&1
}

printf 'ob-sync fuzz-human-C2 — seed=%s (reproduce with: bash tests/fuzz-human-C2.sh %s)\n' "$FUZZ_SEED" "$FUZZ_SEED"

# ── provisioned base device ──────────────────────────────────────────────────
BASE="$SB/base"
mkdir -p "$BASE" "$BASE-home" "$SB/remote-base.git"
git init -q --bare "$SB/remote-base.git"
git config --file "$BASE-home/.gitconfig" user.email fuzz@test.local
git config --file "$BASE-home/.gitconfig" user.name "Fuzz C2"
git config --file "$BASE-home/.gitconfig" init.defaultBranch main
printf 'hello\n' > "$BASE/note.md"
ob "$BASE-home" OBS_VAULT="$BASE" OBS_BACKUP_DIR="$BASE-backups" \
    OBS_REMOTE="$SB/remote-base.git" -- init -y >/dev/null 2>&1
ob "$BASE-home" OBS_VAULT="$BASE" OBS_BACKUP_DIR="$BASE-backups" \
    OBS_REMOTE="$SB/remote-base.git" -- sync -y >/dev/null 2>&1

# ═══ F1. env garbage storm ═══════════════════════════════════════════════════
echo
echo "== F1. env garbage storm (40 rounds) =="
GARBLE_VARS=(OBS_VAULT OBS_BACKUP_DIR OBS_CONFIG OBS_LOG OBS_BRANCH OBS_ATTACH_DIR
             OBS_KEEP_BACKUPS OBS_GIT_TIMEOUT OBS_LOCAL_TIMEOUT OBS_SKIP_BACKUP
             OBS_REMOTE OBS_NET_LOW_SPEED OBS_NET_LOW_TIME TMPDIR)
GARBLE_VALUES=(
    $'\x01\x02ctl-char'   'tab	inside'          $'new\nline'
    'emoji-🚀🔥'          'فارسی/مسیر'           '../../traversal'
    '/absolute/path'      'file:///dev/null'     '%s%s%s%n'
    '$(id)'               '`id`'                 ';rm -rf /;'
    '*'                   '?'                    '- --flag'
    '99999999999999999999999999' '-1'            '0'
    ''                    'ünïcödé'              "quote'and\"double"
    "$(printf 'X%.0s' {1..5000})"
)
CMDS=(status "status --json" doctor history log backup verify organize "cron status")
for i in $(seq 1 40); do
    v="${GARBLE_VARS[RANDOM % ${#GARBLE_VARS[@]}]}"
    g="${GARBLE_VALUES[RANDOM % ${#GARBLE_VALUES[@]}]}"
    c="${CMDS[RANDOM % ${#CMDS[@]}]}"
    # shellcheck disable=SC2086
    ob "$BASE-home" "$v=$g" \
        OBS_VAULT="$BASE" OBS_BACKUP_DIR="$BASE-backups" \
        OBS_REMOTE="$SB/remote-base.git" -- $c >"$SB/out.txt" 2>&1
    rc=$?
    verdict "F1.$i $v=$(printf '%q' "$g" | head -c 48) :: $c" "$SB/out.txt" "$rc"
done
vault_ok && { PASS=$((PASS+1)); printf '  [ OK ] F1 base vault intact + fsck clean\n'; } \
    || { FAIL=$((FAIL+1)); printf '  [FAIL] F1 base vault corrupted\n'; }

# ═══ F2. config file torture ═════════════════════════════════════════════════
echo
echo "== F2. config file torture (12 rounds) =="
CFG="$SB/cfg-home/.config/ob-sync/config"
mkdir -p "$SB/cfg-home/.config/ob-sync"
mkcfg() { printf '%s' "$1" > "$CFG"; }
round_cfg() {  # round_cfg <label>
    ob "$SB/cfg-home" OBS_VAULT="$BASE" OBS_BACKUP_DIR="$BASE-backups" \
        OBS_REMOTE="$SB/remote-base.git" -- status >"$SB/out.txt" 2>&1
    verdict "F2.$1" "$SB/out.txt" "$?"
}
mkcfg '';                                              round_cfg "empty config"
head -c 65536 /dev/urandom > "$CFG";                   round_cfg "64KB urandom"
mkcfg $'\xef\xbb\xbfBRANCH=main\nREMOTE=x\n';          round_cfg "BOM prefix"
mkcfg 'REMOTE=a
REMOTE=b
REMOTE=c
BRANCH=1
BRANCH=2';                                             round_cfg "duplicate keys"
mkcfg '=value
KEY=
= = =
====';                                                 round_cfg "malformed k=v"
mkcfg "$(printf 'Y%.0s' {1..2000000})";                round_cfg "2MB single line"
mkcfg $'BRANCH=$(id)\nREMOTE=`id`';                    round_cfg "command-substitution keys"
mkdir -p "$CFG";                                       round_cfg "config is a directory"
ln -sf "$SB/nowhere" "$CFG";                           round_cfg "config is a dangling symlink"
mkcfg $'REMOTE=/tmp/x\n\x00\x01\x02binary';            round_cfg "embedded control bytes"
mkcfg 'REMOTE=a'; printf '\tno-newline-at-eof' >> "$CFG"; round_cfg "no trailing newline"
chmod 000 "$SB/cfg-home/.config/ob-sync" 2>/dev/null;  round_cfg "config dir unreadable"
chmod 755 "$SB/cfg-home/.config/ob-sync" 2>/dev/null
vault_ok && { PASS=$((PASS+1)); printf '  [ OK ] F2 base vault intact + fsck clean\n'; } \
    || { FAIL=$((FAIL+1)); printf '  [FAIL] F2 base vault corrupted\n'; }

# ═══ F3. CLI argument fuzz ═══════════════════════════════════════════════════
echo
echo "== F3. CLI argument fuzz (36 rounds) =="
TOK=(status backup verify history log organize doctor remote config cron
     restore sync init "status --json" -y --nope -- "" -x extra "-"
     "latest" "origin" "junk\$(id)" "🚀")
for i in $(seq 1 36); do
    n=$((1 + RANDOM % 3))
    args=()
    for ((j = 0; j < n; j++)); do args+=("${TOK[RANDOM % ${#TOK[@]}]}"); done
    ob "$BASE-home" OBS_VAULT="$BASE" OBS_BACKUP_DIR="$BASE-backups" \
        OBS_REMOTE="$SB/remote-base.git" -- "${args[@]}" >"$SB/out.txt" 2>&1
    verdict "F3.$i ob-sync $(printf '%q ' "${args[@]}" | head -c 60)" "$SB/out.txt" "$?"
done
vault_ok && { PASS=$((PASS+1)); printf '  [ OK ] F3 base vault intact + fsck clean\n'; } \
    || { FAIL=$((FAIL+1)); printf '  [FAIL] F3 base vault corrupted\n'; }

# ═══ F4. hostile filename two-device roundtrip ═══════════════════════════════
echo
echo "== F4. hostile filename roundtrip (12 files × 2 directions) =="
VA="$SB/vault-a"; VB="$SB/vault-b"
HA="$SB/a-home";  HB="$SB/b-home"
mkdir -p "$VA" "$VB" "$HA" "$HB" "$SB/remote-f4.git"
git init -q --bare "$SB/remote-f4.git"
for h in HA HB; do
    hh="$SB/${h,,}-home"
    git config --file "$hh/.gitconfig" user.email "f4-$h@test.local"
    git config --file "$hh/.gitconfig" user.name "F4 $h"
done
printf 'base note\n' > "$VA/note.md"
ob "$HA" OBS_VAULT="$VA" OBS_BACKUP_DIR="$VA-backups" OBS_REMOTE="$SB/remote-f4.git" -- init -y >/dev/null 2>&1
ob "$HA" OBS_VAULT="$VA" OBS_BACKUP_DIR="$VA-backups" OBS_REMOTE="$SB/remote-f4.git" -- sync -y >/dev/null 2>&1
ob "$HB" OBS_VAULT="$VB" OBS_BACKUP_DIR="$VB-backups" OBS_REMOTE="$SB/remote-f4.git" -- init -y >/dev/null 2>&1

F4_NAMES=(
    'emoji-🚀🔥.md'
    'فارسی-یادداشت.md'
    "quote'and\"double.md"
    'dollar\$(id).md'
    'backtick\`id\`.md'
    $'new\nline.md'
    $'tab\there.md'
    $'سطر\nفارسی.md'
    'space name.md'
    'semi;colon|pipe&.md'
    "$(printf 'L%.0s' {1..180}).md"
    '..dots-leading.md'
)
idx=0
for name in "${F4_NAMES[@]}"; do
    idx=$((idx + 1))
    printf 'content %s — seed %s\n' "$idx" "$FUZZ_SEED" > "$VA/$name"
done
ob "$HA" OBS_VAULT="$VA" OBS_BACKUP_DIR="$VA-backups" OBS_REMOTE="$SB/remote-f4.git" -- sync -y >"$SB/out.txt" 2>&1
verdict "F4.a sync device-A with ${#F4_NAMES[@]} hostile names" "$SB/out.txt" "$?"
ob "$HB" OBS_VAULT="$VB" OBS_BACKUP_DIR="$VB-backups" OBS_REMOTE="$SB/remote-f4.git" -- sync -y >"$SB/out.txt" 2>&1
verdict "F4.b device-B pulls all hostile names" "$SB/out.txt" "$?"

mismatch=0
for name in "${F4_NAMES[@]}"; do
    if ! cmp -s "$VA/$name" "$VB/$name"; then
        mismatch=$((mismatch + 1))
        printf '         [MISMATCH] %q\n' "$name"
    fi
done
if (( mismatch == 0 )); then
    PASS=$((PASS+1)); printf '  [ OK ] F4.c A→B byte-identical for all %s hostile names\n' "${#F4_NAMES[@]}"
else
    FAIL=$((FAIL+1)); printf '  [FAIL] F4.c %s name(s) mismatched after A→B\n' "$mismatch"
fi

# reverse direction: device B edits, device A pulls
idx=0
for name in "${F4_NAMES[@]}"; do
    idx=$((idx + 1))
    if (( idx % 2 == 0 )); then printf 'B-edit %s\n' "$name" > "$VB/$name"; fi
done
ob "$HB" OBS_VAULT="$VB" OBS_BACKUP_DIR="$VB-backups" OBS_REMOTE="$SB/remote-f4.git" -- sync -y >"$SB/out.txt" 2>&1
verdict "F4.d device-B pushes edits" "$SB/out.txt" "$?"
ob "$HA" OBS_VAULT="$VA" OBS_BACKUP_DIR="$VA-backups" OBS_REMOTE="$SB/remote-f4.git" -- sync -y >"$SB/out.txt" 2>&1
verdict "F4.e device-A pulls edits" "$SB/out.txt" "$?"

mismatch=0
idx=0
for name in "${F4_NAMES[@]}"; do
    idx=$((idx + 1))
    if (( idx % 2 == 0 )); then
        cmp -s "$VA/$name" "$VB/$name" || { mismatch=$((mismatch+1)); printf '         [MISMATCH-B-edit] %q\n' "$name"; }
    fi
done
if (( mismatch == 0 )); then
    PASS=$((PASS+1)); printf '  [ OK ] F4.f B→A byte-identical for edited files\n'
else
    FAIL=$((FAIL+1)); printf '  [FAIL] F4.f %s edited file(s) mismatched\n' "$mismatch"
fi
for v in "$VA" "$VB"; do
    git -C "$v" fsck >/dev/null 2>&1 \
        && { PASS=$((PASS+1)); printf '  [ OK ] F4 fsck clean: %s\n' "$v"; } \
        || { FAIL=$((FAIL+1)); printf '  [FAIL] F4 fsck: %s\n' "$v"; }
done

# ═══ F5. empty & oversized inputs ════════════════════════════════════════════
echo
echo "== F5. empty & oversized inputs (8 checks) =="
: > "$VA/empty.md"
printf '   \n\t\n  \n' > "$VA/whitespace-only.md"
{ for i in $(seq 1 100000); do printf 'line %s of a very long note\n' "$i"; done; } > "$VA/100k-lines.md"
head -c 1048576 /dev/urandom > "$VA/1mb-binary.bin"
ob "$HA" OBS_VAULT="$VA" OBS_BACKUP_DIR="$VA-backups" OBS_REMOTE="$SB/remote-f4.git" -- sync -y >"$SB/out.txt" 2>&1
verdict "F5.a sync with empty/whitespace/100k-line/1MB files" "$SB/out.txt" "$?"
ob "$HB" OBS_VAULT="$VB" OBS_BACKUP_DIR="$VB-backups" OBS_REMOTE="$SB/remote-f4.git" -- sync -y >"$SB/out.txt" 2>&1
verdict "F5.b device-B pulls them" "$SB/out.txt" "$?"
cmp -s "$VA/empty.md" "$VB/empty.md" \
    && { PASS=$((PASS+1)); printf '  [ OK ] F5.c 0-byte file roundtrip identical\n'; } \
    || { FAIL=$((FAIL+1)); printf '  [FAIL] F5.c 0-byte file mismatch\n'; }
cmp -s "$VA/100k-lines.md" "$VB/100k-lines.md" \
    && { PASS=$((PASS+1)); printf '  [ OK ] F5.d 100k-line file roundtrip identical\n'; } \
    || { FAIL=$((FAIL+1)); printf '  [FAIL] F5.d 100k-line file mismatch\n'; }
sha_a=$(sha256sum "$VA/1mb-binary.bin" | cut -d' ' -f1)
sha_b=$(sha256sum "$VB/1mb-binary.bin" | cut -d' ' -f1)
[[ "$sha_a" == "$sha_b" ]] \
    && { PASS=$((PASS+1)); printf '  [ OK ] F5.e 1MB binary sha256 identical\n'; } \
    || { FAIL=$((FAIL+1)); printf '  [FAIL] F5.e 1MB binary sha256 differs\n'; }
# fresh empty vault (zero files) must still init+sync honestly
VZ="$SB/vault-zero"; HZ="$SB/z-home"; mkdir -p "$VZ" "$HZ"
git config --file "$HZ/.gitconfig" user.email z@test.local
git config --file "$HZ/.gitconfig" user.name "F5 zero"
ob "$HZ" OBS_VAULT="$VZ" OBS_BACKUP_DIR="$VZ-backups" OBS_REMOTE="$SB/remote-f4.git" -- init -y >"$SB/out.txt" 2>&1
verdict "F5.f init on a completely empty vault" "$SB/out.txt" "$?"
ob "$HZ" OBS_VAULT="$VZ" OBS_BACKUP_DIR="$VZ-backups" OBS_REMOTE="$SB/remote-f4.git" -- sync -y >"$SB/out.txt" 2>&1
verdict "F5.g sync on a completely empty vault" "$SB/out.txt" "$?"

# ── verdict ──────────────────────────────────────────────────────────────────
echo
printf 'fuzz-human-C2 (seed=%s): PASS=%s FAIL=%s\n' "$FUZZ_SEED" "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
exit 0
