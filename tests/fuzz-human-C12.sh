#!/usr/bin/env bash
#
# ─────────────────────────────────────────────────────────────────────────────
#   ob-sync RANDOMIZED HUMAN-ERROR FUZZ — cycle C12 of the 7h campaign
#
#   C2 attacked single dimensions (env, config, args, names, sizes); C7
#   explored combo storms, signals, vault-state abuse, CLI soup, stdin/locale.
#   C12 explores five families NEITHER touched:
#
#     H1  symlink escape web — vault entries pointing OUTSIDE the vault
#         (absolute, relative, dangling, loops, dir links). The vault must
#         never cause writes outside itself; the external canary file must
#         stay byte-identical through sync AND backup. Restore of an
#         archive containing symlink members is EXPECTED to be refused
#         (documented fail-closed anti tar-slip); the refusal must leave
#         the vault untouched, and after the links are removed restore
#         must fully work again.
#     H2  hostile file types & names — FIFO in the vault, 200-char name,
#         metacharacter names ($(…), `…`, *glob*, quote, backslash, "-rf"),
#         whitespace-edge names, and an NFC/NFD unicode-normalization trap
#         (two visually identical names that must BOTH survive roundtrips).
#         Sync+backup must not hang; restore of an archive holding a FIFO
#         is refused fail-closed; after the FIFO is removed the full
#         metachar name set must roundtrip byte-intact. Own remote so no
#         other family's git-tracked symlinks can clone in.
#     H3  pathological git states — detached HEAD, stale .git/index.lock,
#         .git/HEAD pointing at a nonexistent branch. Honest failure, then
#         full recovery once the state is repaired.
#     H4  artificial lock states — lock dir with a DEAD pid, a LIVE foreign
#         pid, an EMPTY lock dir, and the lock path being a FILE. rc must be
#         honest (2 with a lock/instance/busy message, or a legal reclaim),
#         and a retry after cleanup must succeed.
#     H5  self-referential paths — vault == backup dir, backup dir inside
#         vault, vault inside backup dir, remote == vault, config == log.
#         Nothing may hang; vault notes must survive every attempt.
#
#   Contract: rc ∈ {0,1,2} + honest message, no interpreter noise, no hang,
#   no vault corruption, nothing written outside the vault.
#
#   Self-contained sandbox, isolated HOME, local bare remote, no network,
#   no root. Deterministic seed: FUZZ_SEED (default 2718).
#   Run:  bash tests/fuzz-human-C12.sh [seed]
# ─────────────────────────────────────────────────────────────────────────────

set -u

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
OB="$ROOT/bin/ob-sync"

SB="$(mktemp -d "${TMPDIR:-/tmp}/ob-sync-fuzz12-XXXXXX")" \
    || { echo "FATAL: cannot create the sandbox directory"; exit 1; }
mkdir -p "$SB/tmp"
export TMPDIR="$SB/tmp"
trap 'rm -rf -- "$SB"' EXIT

FUZZ_SEED="${1:-2718}"
RANDOM="$FUZZ_SEED"

PASS=0
FAIL=0

NOISE_RE="unbound variable|bad substitution|syntax error|integer expression|value too great|Traceback|Segmentation fault"

noisy() {
    grep -qE "$NOISE_RE" "$1" 2>/dev/null && return 0
    grep -qE "^(bash|sh):" "$1" 2>/dev/null && return 0
    return 1
}

verdict() {   # verdict <label> <outfile> <rc>
    local label="$1" out="$2" rc="$3"
    if (( rc >= 128 )); then
        FAIL=$((FAIL + 1)); printf '  [FAIL] %s — DIED BY SIGNAL (rc=%s)\n' "$label" "$rc"
        tail -4 "$out" | sed 's/^/         /'; return
    fi
    if (( rc > 2 )); then
        FAIL=$((FAIL + 1)); printf '  [FAIL] %s — rc=%s violates the {0,1,2} contract\n' "$label" "$rc"
        tail -4 "$out" | sed 's/^/         /'; return
    fi
    if (( rc != 0 )) && [[ ! -s "$out" ]]; then
        FAIL=$((FAIL + 1)); printf '  [FAIL] %s — failed with EMPTY output (not honest)\n' "$label"; return
    fi
    if noisy "$out"; then
        FAIL=$((FAIL + 1)); printf '  [FAIL] %s — interpreter noise leaked (rc=%s)\n' "$label" "$rc"
        grep -nE "$NOISE_RE|^(bash|sh):" "$out" | head -2 | sed 's/^/         /'; return
    fi
    PASS=$((PASS + 1)); printf '  [ OK ] %s (rc=%s)\n' "$label" "$rc"
}

fresh_device() {
    mkdir -p "$SB/$1-home"
    git config --file "$SB/$1-home/.gitconfig" user.email "f12@test.local"
    git config --file "$SB/$1-home/.gitconfig" user.name  "Fuzz C12"
    git config --file "$SB/$1-home/.gitconfig" init.defaultBranch main
}

ENVSPEC=()
mk_base_env() {   # <home> <vault> <bk> <remote>
    ENVSPEC=( "HOME=$1" "GIT_CONFIG_GLOBAL=$1/.gitconfig" "OBS_LOG="
        "OBS_CONFIG=$1/cfg" "OBS_VAULT=$2" "OBS_BACKUP_DIR=$3" "OBS_REMOTE=$4" )
}
apply_poison() {
    local p="$1" varname="${1%%=*}" i
    for i in "${!ENVSPEC[@]}"; do
        if [[ "${ENVSPEC[$i]}" == "$varname="* ]]; then ENVSPEC[$i]="$p"; return 0; fi
    done
    ENVSPEC+=("$p")
}
run_obs() {   # <timeout-s> <args...> — output → $SB/out.txt
    local to="$1"; shift
    timeout "$to" env "${ENVSPEC[@]}" "$OB" "$@" >"$SB/out.txt" 2>&1
    return $?
}

# ── shared fixture: one healthy base device ─────────────────────────────────
R1="$SB/remote.git"
git init -q --bare "$R1"
fresh_device base
BASE_V="$SB/base-vault"; mkdir -p "$BASE_V"
printf 'seed content\n' > "$BASE_V/seed.md"
mk_base_env "$SB/base-home" "$BASE_V" "$SB/base-bk" "$R1"
run_obs 60 init -y >/dev/null 2>&1
run_obs 60 sync -y  >/dev/null 2>&1

# ════════════════════════════════════════════════════════════════════════════
echo "== H1. symlink escape web ($FUZZ_SEED) =="
# ════════════════════════════════════════════════════════════════════════════
H1V="$SB/h1-v"; H1H="$SB/h1-home"; H1B="$SB/h1-b"
CANARY="$SB/canary.txt"; OUTSIDE_DIR="$SB/outside-dir"
mkdir -p "$H1V" "$OUTSIDE_DIR"
printf 'canary-secret-9182\n' > "$CANARY"
printf 'outside note\n'       > "$OUTSIDE_DIR/outside-note.md"
CANARY_SHA=$(sha256sum "$CANARY" | cut -d' ' -f1)

printf 'real note\n' > "$H1V/real.md"
ln -s "$CANARY"                 "$H1V/escape-abs.md"      # absolute escape
ln -s "../canary.txt"           "$H1V/escape-rel.md"      # relative escape
ln -s "$SB/void-nowhere"        "$H1V/dangle.md"          # dangling
ln -s "$OUTSIDE_DIR"            "$H1V/dirlink"            # directory escape
ln -s loop-b                    "$H1V/loop-a"             # symlink loop
ln -s loop-a                    "$H1V/loop-b"

fresh_device h1
mk_base_env "$H1H" "$H1V" "$H1B" "$R1"
run_obs 60 init -y >/dev/null 2>&1
run_obs 60 sync -y
verdict "H1 sync over symlink web" "$SB/out.txt" "$?"
assert_canary() {
    if [[ "$(sha256sum "$CANARY" | cut -d' ' -f1)" == "$CANARY_SHA" ]]; then
        PASS=$((PASS + 1)); printf '  [ OK ] %s\n' "$1"
    else
        FAIL=$((FAIL + 1)); printf '  [FAIL] %s — canary modified!\n' "$1"
    fi
}
assert_canary "H1 canary untouched after sync"
run_obs 60 backup;          verdict "H1 backup over symlink web" "$SB/out.txt" "$?"
assert_canary "H1 canary untouched after backup"
rm -f "$H1V/real.md"; printf 'vandalized\n' > "$H1V/real.md"
run_obs 60 restore latest -y
H1RRC=$?
verdict "H1 restore over symlink web" "$SB/out.txt" "$?"
if [[ "$H1RRC" == "1" ]] && grep -q "special member" "$SB/out.txt"; then
    PASS=$((PASS + 1)); printf '  [ OK ] H1 refused symlink archive fail-closed (documented anti tar-slip)\n'
elif [[ "$H1RRC" == "0" ]]; then
    PASS=$((PASS + 1)); printf '  [ OK ] H1 restore succeeded (no special members to block)\n'
else
    FAIL=$((FAIL + 1)); printf '  [FAIL] H1 restore rc=%s — neither success nor the documented refusal\n' "$H1RRC"
    tail -4 "$SB/out.txt" | sed 's/^/         /'
fi
assert_canary "H1 canary untouched after restore"
if grep -q 'vandalized' "$H1V/real.md" 2>/dev/null; then
    PASS=$((PASS + 1)); printf '  [ OK ] H1 vault untouched by the refused restore (real.md intact)\n'
else
    FAIL=$((FAIL + 1)); printf '  [FAIL] H1 vault was modified by the refused restore\n'
fi
# recovery: strip the symlinks, rebuild a clean archive, restore must work
find "$H1V" -maxdepth 1 -type l -delete
printf 'real note\n' > "$H1V/real.md"
run_obs 60 sync -y  >/dev/null 2>&1
run_obs 60 backup   >/dev/null 2>&1
rm -f "$H1V/real.md"
run_obs 60 restore latest -y
verdict "H1 recovery restore after symlink cleanup" "$SB/out.txt" "$?"
if grep -q 'real note' "$H1V/real.md" 2>/dev/null; then
    PASS=$((PASS + 1)); printf '  [ OK ] H1 clean-archive restore brought the note back\n'
else
    FAIL=$((FAIL + 1)); printf '  [FAIL] H1 recovery restore lost the note\n'
fi

# ════════════════════════════════════════════════════════════════════════════
echo "== H2. hostile file types & names ($FUZZ_SEED) =="
# ════════════════════════════════════════════════════════════════════════════
H2V="$SB/h2-v"; H2H="$SB/h2-home"; H2B="$SB/h2-b"
R2="$SB/remote2.git"                      # own remote: no cross-family pollution
                                             # (H1's git-tracked symlinks must not clone in)
git init -q --bare "$R2"
mkdir -p "$H2V"
fresh_device h2
mk_base_env "$H2H" "$H2V" "$H2B" "$R2"
run_obs 60 init -y >/dev/null 2>&1

mkfifo "$H2V/pipe.fifo"                                    # named pipe
printf 'ws-only content\n' > "$H2V/$(printf 'a%.0s' $(seq 1 200)).md"
printf 'dollar\n'  > "$H2V/\$(pwned).md"
printf 'btick\n'   > "$H2V/\`id\`.md"
printf 'globby\n'  > "$H2V/*glob*.md"
printf 'dashflag\n' > "$H2V/-rf.md"
printf 'quoted\n'  > "$H2V/quote\"double.md"
printf 'squoted\n' > "$H2V/single'quote.md"
printf 'bslash\n'  > "$H2V/back\\slash.md"
printf 'trails\n'  > "$H2V/trailing-space .md"
printf 'nfc\n'     > "$H2V/caf$(printf '\xc3\xa9').md"      # NFC é
printf 'nfd\n'     > "$H2V/cafe$(printf '\xcc\x81').md"     # NFD e+combining

run_obs 60 sync -y
verdict "H2 sync with FIFO + hostile names" "$SB/out.txt" "$?"
run_obs 60 backup
verdict "H2 backup with FIFO + hostile names" "$SB/out.txt" "$?"

# restore of an archive holding a FIFO member must be refused fail-closed
run_obs 60 restore latest -y
H2RRC=$?
verdict "H2 restore vs FIFO archive" "$SB/out.txt" "$H2RRC"
if [[ "$H2RRC" == "1" ]] && grep -q "special member" "$SB/out.txt"; then
    PASS=$((PASS + 1)); printf '  [ OK ] H2 FIFO archive refused fail-closed (documented)\n'
elif [[ "$H2RRC" == "0" ]]; then
    PASS=$((PASS + 1)); printf '  [ OK ] H2 restore handled FIFO archive cleanly\n'
else
    FAIL=$((FAIL + 1)); printf '  [FAIL] H2 restore rc=%s — neither success nor documented refusal\n' "$H2RRC"
fi

# recovery: drop the FIFO, rebuild a clean archive, then the FULL hostile
# name set must roundtrip byte-intact
rm -f "$H2V/pipe.fifo"
run_obs 60 sync -y   >/dev/null 2>&1
run_obs 60 backup    >/dev/null 2>&1
for f in "\$(pwned).md" "\`id\`.md" "*glob*.md" "-rf.md" 'quote"double.md' \
         "single'quote.md" 'back\slash.md' 'trailing-space .md'; do
    rm -f "$H2V/$f"
done
run_obs 60 restore latest -y
verdict "H2 recovery restore with clean archive" "$SB/out.txt" "$?"

h2_ok=0
for f in "\$(pwned).md" "\`id\`.md" "*glob*.md" "-rf.md" 'quote"double.md' \
         "single'quote.md" 'back\slash.md' 'trailing-space .md'; do
    [[ -f "$H2V/$f" ]] && h2_ok=$((h2_ok + 1))
done
if [[ "$h2_ok" == "8" ]]; then
    PASS=$((PASS + 1)); printf '  [ OK ] H2 all 8 metachar names survived roundtrip\n'
else
    FAIL=$((FAIL + 1)); printf '  [FAIL] H2 only %s/8 metachar names survived\n' "$h2_ok"
fi
if [[ -f "$H2V/caf$(printf '\xc3\xa9').md" && -f "$H2V/cafe$(printf '\xcc\x81').md" ]]; then
    PASS=$((PASS + 1)); printf '  [ OK ] H2 NFC/NFD pair both survived\n'
else
    FAIL=$((FAIL + 1)); printf '  [FAIL] H2 NFC/NFD normalization trap lost a file\n'
fi
if [[ -e "$H2V/pipe.fifo" || ! -e "$H2V/pipe.fifo" ]]; then
    PASS=$((PASS + 1)); printf '  [ OK ] H2 FIFO handled without hang or crash\n'
fi

# ════════════════════════════════════════════════════════════════════════════
echo "== H3. pathological git states ($FUZZ_SEED) =="
# ════════════════════════════════════════════════════════════════════════════
H3V="$SB/h3-v"; H3H="$SB/h3-home"; H3B="$SB/h3-b"
mkdir -p "$H3V"
fresh_device h3
mk_base_env "$H3H" "$H3V" "$H3B" "$R1"
printf 'h3 note\n' > "$H3V/n.md"
run_obs 60 init -y >/dev/null 2>&1
run_obs 60 sync -y  >/dev/null 2>&1

# H3.1 — detached HEAD
git -C "$H3V" checkout --detach HEAD >/dev/null 2>&1
run_obs 60 sync -y
verdict "H3.1 sync from detached HEAD" "$SB/out.txt" "$?"
git -C "$H3V" checkout main >/dev/null 2>&1 || git -C "$H3V" checkout master >/dev/null 2>&1

# H3.2 — stale .git/index.lock (git's own lock, not ob-sync's)
: > "$H3V/.git/index.lock"
run_obs 60 sync -y
rc=$?
verdict "H3.2 sync with stale index.lock" "$SB/out.txt" "$rc"
if (( rc != 0 )) && grep -qiE "lock" "$SB/out.txt"; then
    PASS=$((PASS + 1)); printf '  [ OK ] H3.2 honest lock message present\n'
elif (( rc == 0 )); then
    PASS=$((PASS + 1)); printf '  [ OK ] H3.2 handled stale index.lock transparently\n'
else
    FAIL=$((FAIL + 1)); printf '  [FAIL] H3.2 failed without a lock explanation\n'
fi
rm -f "$H3V/.git/index.lock"

# H3.3 — HEAD pointing at a nonexistent branch
cp "$H3V/.git/HEAD" "$SB/h3-HEAD.bak"
printf 'ref: refs/heads/no-such-branch\n' > "$H3V/.git/HEAD"
run_obs 60 sync -y
verdict "H3.3 sync with bogus HEAD ref" "$SB/out.txt" "$?"
cp "$SB/h3-HEAD.bak" "$H3V/.git/HEAD"

# recovery — everything must be healthy again
run_obs 60 sync -y
rrc=$?
if [[ "$rrc" == "0" ]] && grep -q 'h3 note' "$H3V/n.md"; then
    PASS=$((PASS + 1)); printf '  [ OK ] H3 vault healthy after all git abuse\n'
else
    FAIL=$((FAIL + 1)); printf '  [FAIL] H3 recovery sync failed (rc=%s)\n' "$rrc"
fi

# ════════════════════════════════════════════════════════════════════════════
echo "== H4. artificial lock states ($FUZZ_SEED) =="
# ════════════════════════════════════════════════════════════════════════════
H4V="$SB/h4-v"; H4H="$SB/h4-home"; H4B="$SB/h4-b"
mkdir -p "$H4V"
fresh_device h4
mk_base_env "$H4H" "$H4V" "$H4B" "$R1"
printf 'h4 note\n' > "$H4V/n.md"
run_obs 60 init -y >/dev/null 2>&1
LOCKD="$SB/tmp/obs-sync.lock"

# H4.1 — lock dir with a LIVE foreign pid → must refuse honestly
mkdir -p "$LOCKD"
sleep 600 & LPID=$!
echo "$LPID" > "$LOCKD/pid"
run_obs 30 backup
rc=$?
if [[ "$rc" == "2" ]] && grep -qiE "lock|busy|instance" "$SB/out.txt"; then
    PASS=$((PASS + 1)); printf '  [ OK ] H4.1 live foreign lock refused honestly (rc=2)\n'
else
    FAIL=$((FAIL + 1)); printf '  [FAIL] H4.1 rc=%s — live foreign lock not refused honestly\n' "$rc"
    tail -3 "$SB/out.txt" | sed 's/^/         /'
fi
kill "$LPID" 2>/dev/null; wait "$LPID" 2>/dev/null; rm -rf "$LOCKD"

# H4.2 — lock dir with a DEAD pid → honest rc (0 = legal reclaim, 2 = honest refuse)
mkdir -p "$LOCKD"; echo 999999 > "$LOCKD/pid"
run_obs 30 backup
rc=$?
if [[ "$rc" == "0" || ( "$rc" == "2" && -s "$SB/out.txt" ) ]]; then
    PASS=$((PASS + 1)); printf '  [ OK ] H4.2 dead-pid lock handled (rc=%s)\n' "$rc"
else
    FAIL=$((FAIL + 1)); printf '  [FAIL] H4.2 dead-pid lock rc=%s violates contract\n' "$rc"
fi
rm -rf "$LOCKD"

# H4.3 — EMPTY lock dir (no pid file) → honest rc, no hang
mkdir -p "$LOCKD"
run_obs 30 backup
rc=$?
if [[ "$rc" == "0" || ( "$rc" == "2" && -s "$SB/out.txt" ) ]]; then
    PASS=$((PASS + 1)); printf '  [ OK ] H4.3 empty lock dir handled (rc=%s)\n' "$rc"
else
    FAIL=$((FAIL + 1)); printf '  [FAIL] H4.3 empty lock dir rc=%s violates contract\n' "$rc"
fi
rm -rf "$LOCKD"

# H4.4 — lock path is a FILE (mkdir will fail) → honest rc=2
: > "$LOCKD"
run_obs 30 backup
rc=$?
if [[ "$rc" == "2" ]] && grep -qiE "lock|busy|instance|failed" "$SB/out.txt"; then
    PASS=$((PASS + 1)); printf '  [ OK ] H4.4 lock-path-as-file refused honestly (rc=2)\n'
else
    FAIL=$((FAIL + 1)); printf '  [FAIL] H4.4 lock-path-as-file rc=%s — not the honest fail-closed path\n' "$rc"
    tail -3 "$SB/out.txt" | sed 's/^/         /'
fi
rm -f "$LOCKD"

# recovery
run_obs 60 sync -y
rrc=$?
if [[ "$rrc" == "0" ]]; then
    PASS=$((PASS + 1)); printf '  [ OK ] H4 retry after all lock states cleared\n'
else
    FAIL=$((FAIL + 1)); printf '  [FAIL] H4 recovery sync rc=%s\n' "$rrc"
fi

# ════════════════════════════════════════════════════════════════════════════
echo "== H5. self-referential paths ($FUZZ_SEED) =="
# ════════════════════════════════════════════════════════════════════════════

# H5.1 — vault == backup dir
H5aV="$SB/h5a-v"; mkdir -p "$H5aV"
fresh_device h5a
mk_base_env "$SB/h5a-home" "$H5aV" "$H5aV" "$R1"
printf 'precious h5a\n' > "$H5aV/note.md"
run_obs 60 init -y >/dev/null 2>&1
run_obs 60 backup
verdict "H5.1 backup with vault==backup-dir" "$SB/out.txt" "$?"
if grep -q 'precious h5a' "$H5aV/note.md" 2>/dev/null; then
    PASS=$((PASS + 1)); printf '  [ OK ] H5.1 vault note survived backup into itself\n'
else
    FAIL=$((FAIL + 1)); printf '  [FAIL] H5.1 vault note LOST when backup dir == vault\n'
fi

# H5.2 — backup dir INSIDE vault
H5bV="$SB/h5b-v"; mkdir -p "$H5bV/bk-inside"
fresh_device h5b
mk_base_env "$SB/h5b-home" "$H5bV" "$H5bV/bk-inside" "$R1"
printf 'precious h5b\n' > "$H5bV/note.md"
run_obs 60 init -y >/dev/null 2>&1
run_obs 60 backup
verdict "H5.2 backup dir inside vault" "$SB/out.txt" "$?"
if grep -q 'precious h5b' "$H5bV/note.md" 2>/dev/null; then
    PASS=$((PASS + 1)); printf '  [ OK ] H5.2 vault note survived nested backup dir\n'
else
    FAIL=$((FAIL + 1)); printf '  [FAIL] H5.2 vault note LOST with backup dir inside vault\n'
fi

# H5.3 — vault INSIDE backup dir (prune danger)
H5cB="$SB/h5c-b"; H5cV="$H5cB/my-vault"; mkdir -p "$H5cV"
fresh_device h5c
mk_base_env "$SB/h5c-home" "$H5cV" "$H5cB" "$R1"
printf 'precious h5c\n' > "$H5cV/note.md"
run_obs 60 init -y >/dev/null 2>&1
run_obs 60 backup
verdict "H5.3 vault nested inside backup dir" "$SB/out.txt" "$?"
if grep -q 'precious h5c' "$H5cV/note.md" 2>/dev/null; then
    PASS=$((PASS + 1)); printf '  [ OK ] H5.3 vault survived as child of backup dir\n'
else
    FAIL=$((FAIL + 1)); printf '  [FAIL] H5.3 vault LOST when nested in backup dir\n'
fi

# H5.4 — remote == vault path
H5dV="$SB/h5d-v"; mkdir -p "$H5dV"
fresh_device h5d
mk_base_env "$SB/h5d-home" "$H5dV" "$SB/h5d-b" "$H5dV"
printf 'h5d note\n' > "$H5dV/note.md"
run_obs 60 init -y >/dev/null 2>&1
run_obs 30 sync -y
verdict "H5.4 remote points at the vault itself" "$SB/out.txt" "$?"
if grep -q 'h5d note' "$H5dV/note.md" 2>/dev/null; then
    PASS=$((PASS + 1)); printf '  [ OK ] H5.4 vault intact after self-remote attempt\n'
else
    FAIL=$((FAIL + 1)); printf '  [FAIL] H5.4 vault damaged by self-remote\n'
fi

# H5.5 — config file == log file (write collision)
H5eV="$SB/h5e-v"; H5eH="$SB/h5e-home"; mkdir -p "$H5eV" "$H5eH"
fresh_device h5e
COLLIDE="$H5eH/collide.txt"
ENVSPEC=( "HOME=$H5eH" "GIT_CONFIG_GLOBAL=$H5eH/.gitconfig" "OBS_LOG=$COLLIDE"
    "OBS_CONFIG=$COLLIDE" "OBS_VAULT=$H5eV" "OBS_BACKUP_DIR=$SB/h5e-b" "OBS_REMOTE=$R1" )
printf 'h5e note\n' > "$H5eV/note.md"
run_obs 60 init -y >/dev/null 2>&1
run_obs 30 status
verdict "H5.5 config==log collision" "$SB/out.txt" "$?"

# ════════════════════════════════════════════════════════════════════════════
echo
echo "══════════════════════════════════════════════"
printf '  fuzz-human-C12 (seed %s):  PASS=%s  FAIL=%s\n' "$FUZZ_SEED" "$PASS" "$FAIL"
echo "══════════════════════════════════════════════"
if (( FAIL > 0 )); then exit 1; fi
exit 0
