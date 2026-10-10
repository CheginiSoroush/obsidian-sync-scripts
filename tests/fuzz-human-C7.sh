#!/usr/bin/env bash
#
# ─────────────────────────────────────────────────────────────────────────────
#   ob-sync RANDOMIZED HUMAN-ERROR FUZZ — cycle C7 of the 7h campaign
#
#   fuzz-human-C2.sh attacked single dimensions (env, config, args, names,
#   sizes). C7 explores the dimensions C2 did NOT:
#
#     G1  combo storm        — hostile env × corrupt config × hostile CLI
#                            all at once (interaction bugs live here)
#     G2  signal interrupt   — SIGTERM/SIGINT at a random moment during
#                            sync; must exit, release the lock (or leave
#                            a reclaimable one), stay quiet, recover
#     G3  vault state abuse  — vault is a file, .git is a file/dangling
#                            symlink, .ob-sync points at /dev/null,
#                            read-only vault / read-only backup dir
#     G4  repeated &         — -y -y --json --json, `restore latest latest`,
#         contradictory CLI  — -- then garbage, flags before the command
#     G5  stdin flood &      — endless stdin into prompt-hungry commands,
#         locale/TZ poison   — invalid LC_ALL, C locale with UTF-8 names,
#                            absurd TZ values
#
#   Contract unchanged: rc ∈ {0,1,2} + honest message, no interpreter
#   noise, no hang, no vault corruption. For G2 the signal death IS the
#   expected outcome — the checks are: quiet exit + reusable lock + recovery.
#
#   Self-contained sandbox, isolated HOME, local bare remote, no network,
#   no root. Deterministic seed: FUZZ_SEED (default 42; second pass 31337).
#   Run:  bash tests/fuzz-human-C7.sh [seed]
# ─────────────────────────────────────────────────────────────────────────────

set -u

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
OB="$ROOT/bin/ob-sync"

SB="$(mktemp -d "${TMPDIR:-/tmp}/ob-sync-fuzz7-XXXXXX")" \
    || { echo "FATAL: cannot create the sandbox directory"; exit 1; }
mkdir -p "$SB/tmp"
export TMPDIR="$SB/tmp"
trap 'rm -rf -- "$SB"' EXIT

FUZZ_SEED="${1:-42}"
RANDOM="$FUZZ_SEED"

PASS=0
FAIL=0

NOISE_RE="unbound variable|bad substitution|syntax error|integer expression|value too great|Traceback|Segmentation fault"

noisy() {
    grep -qE "$NOISE_RE" "$1" 2>/dev/null && return 0
    grep -qE "^(bash|sh):" "$1" 2>/dev/null && return 0
    return 1
}

# noisy_ex <outfile> — like noisy() but tolerates the setlocale warning that
# the bash BINARY itself prints at startup for an invalid LC_ALL (it fires
# before ob-sync's first line of code; every bash program on earth emits it;
# recorded as a LOW observation, not a code defect).
noisy_ex() {
    grep -qE "$NOISE_RE" "$1" 2>/dev/null && return 0
    grep -E "^(bash|sh):" "$1" 2>/dev/null | grep -vE '^bash: warning: setlocale' | grep -q . && return 0
    return 1
}

# verdict <label> <outfile> <rc> — standard fuzz contract for one run
verdict() {
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

# fresh_device <name> — isolated HOME + gitconfig
fresh_device() {
    mkdir -p "$SB/$1-home"
    git config --file "$SB/$1-home/.gitconfig" user.email "f7@test.local"
    git config --file "$SB/$1-home/.gitconfig" user.name  "Fuzz C7"
    git config --file "$SB/$1-home/.gitconfig" init.defaultBranch main
}

# ── env assembly: explicit, no double-write ambiguity ────────────────────────
ENVSPEC=()

# mk_base_env <home> <vault> <bk> <remote> — the standard isolated device
mk_base_env() {
    ENVSPEC=( "HOME=$1" "GIT_CONFIG_GLOBAL=$1/.gitconfig" "OBS_LOG="
        "OBS_CONFIG=$1/cfg" "OBS_VAULT=$2" "OBS_BACKUP_DIR=$3" "OBS_REMOTE=$4" )
}

# apply_poison "VAR=value" — REPLACE the variable if present, else append
apply_poison() {
    local p="$1"
    local varname="${p%%=*}"
    local i
    for i in "${!ENVSPEC[@]}"; do
        if [[ "${ENVSPEC[$i]}" == "$varname="* ]]; then
            ENVSPEC[$i]="$p"
            return 0
        fi
    done
    ENVSPEC+=("$p")
    return 0
}

# run_obs <timeout-s> <args...> — run ob-sync with ENVSPEC, output → out.txt
run_obs() {
    local to="$1"; shift
    timeout "$to" env "${ENVSPEC[@]}" "$OB" "$@" >"$SB/out.txt" 2>&1
    return $?
}

# ── shared fixtures ──────────────────────────────────────────────────────────
R1="$SB/remote.git"
git init -q --bare "$R1"
fresh_device base
BASE_V="$SB/base-vault"; mkdir -p "$BASE_V"
printf 'seed content\n' > "$BASE_V/seed.md"
mk_base_env "$SB/base-home" "$BASE_V" "$SB/base-bk" "$R1"
run_obs 60 init -y >/dev/null 2>&1
run_obs 60 sync -y >/dev/null 2>&1

ENV_POISONS=( "OBS_BRANCH=-garbage" "OBS_ATTACH_DIR=.." "OBS_GIT_TIMEOUT=abc"
    "OBS_GIT_TIMEOUT=-5" "OBS_KEEP_BACKUPS=99999999999999999999" "OBS_KEEP_BACKUPS=0x10"
    "OBS_VERBOSE=$(printf 'a%.0s' {1..2000})" "OBS_REMOTE=git://127.0.0.1:1/x"
    "OBS_REMOTE=ext::sh -c touch% /tmp/pwned-c7" "OBS_VAULT=" "OBS_BACKUP_DIR=.."
    "OBS_CONFIG=/dev/null" "OBS_LOCAL_TIMEOUT=banana" "OBS_LOG=/dev/full" )

CFG_POISONS=( "urandom" "dir" "empty" "bom" "garbage-keys" "huge" )

# ════════════════════════════════════════════════════════════════════════════
echo "== G1. combo storm — hostile env × corrupt config × hostile CLI ($FUZZ_SEED) =="
# ════════════════════════════════════════════════════════════════════════════
for i in $(seq 1 20); do
    DV="$SB/g1-v-$i"; DH="$SB/g1-h-$i"; DB="$SB/g1-b-$i"
    mkdir -p "$DV" "$DH"          # $DH holds the poisoned config file
    fresh_device "g1-h-$i"
    printf 'note %s\n' "$i" > "$DV/n.md"

    # corrupt the config file for this device
    cfgp="${CFG_POISONS[RANDOM % ${#CFG_POISONS[@]}]}"
    case "$cfgp" in
        urandom)      head -c 512 /dev/urandom > "$DH/cfg";;
        dir)          mkdir -p "$DH/cfg";;
        empty)        : > "$DH/cfg";;
        bom)          printf '\xef\xbb\xbfOBS_GIT_TIMEOUT=9\n' > "$DH/cfg";;
        garbage-keys) printf '=== broken\n\xff\xfe not a key\nOBS_KEEP=\n' > "$DH/cfg";;
        huge)         head -c 100000 /dev/zero | tr '\0' 'x' > "$DH/cfg";;
    esac

    mk_base_env "$DH" "$DV" "$DB" "$R1"
    poison="${ENV_POISONS[RANDOM % ${#ENV_POISONS[@]}]}"
    apply_poison "$poison"
    CMDS=( sync backup status doctor history organize verify prune restore )
    cmd="${CMDS[RANDOM % ${#CMDS[@]}]}"
    if [[ "$cmd" == "restore" ]]; then
        run_obs 30 restore latest
    else
        run_obs 30 "$cmd" --json
    fi
    verdict "G1[$i] $cmd under combo poison" "$SB/out.txt" "$?"
done

# ════════════════════════════════════════════════════════════════════════════
echo "== G2. signal interrupt — SIGTERM/SIGINT mid-operation ($FUZZ_SEED) =="
# ════════════════════════════════════════════════════════════════════════════
for i in $(seq 1 12); do
    DV="$SB/g2-v-$i"; DH="$SB/g2-h-$i"; DB="$SB/g2-b-$i"
    mkdir -p "$DV" "$DB"
    fresh_device "g2-h-$i"
    for f in $(seq 1 200); do printf 'g2 %s %s\n' "$i" "$f" > "$DV/n-$f.md"; done

    sig="TERM"; (( RANDOM % 2 == 0 )) && sig="INT"
    delay=$(( RANDOM % 3 ))          # 0..2 s

    mk_base_env "$DH" "$DV" "$DB" "$R1"
    run_obs 60 init -y >/dev/null 2>&1

    ( timeout 30 env "${ENVSPEC[@]}" "$OB" sync -y >"$SB/out.txt" 2>&1 ) &
    pid=$!
    sleep "$delay" 2>/dev/null || sleep 1
    kill -"$sig" "$pid" 2>/dev/null
    wait "$pid"; rc=$?

    # contract for interrupted runs: quiet death, then a lock that a retry
    # can either reuse or reclaim; then recovery must succeed.
    G2_FAIL=0
    if noisy "$SB/out.txt"; then
        FAIL=$((FAIL + 1)); printf '  [FAIL] G2[%s] noise after SIG%s (rc=%s)\n' "$i" "$sig" "$rc"
        grep -nE "$NOISE_RE|^(bash|sh):" "$SB/out.txt" | head -2 | sed 's/^/         /'
        G2_FAIL=1
    fi
    # give the EXIT handler a beat to sweep the lock
    sleep 2
    if [[ -d "$SB/tmp/obs-sync.lock" ]]; then
        lockpid=$(cat "$SB/tmp/obs-sync.lock/pid" 2>/dev/null || :)
        if [[ -z "$lockpid" ]] || ! kill -0 "$lockpid" 2>/dev/null; then
            rm -rf "$SB/tmp/obs-sync.lock"     # stale reclaim — legal path
        fi
    fi
    run_obs 120 sync -y
    rrc=$?
    if [[ "$rrc" == "0" ]]; then
        PASS=$((PASS + 1))
        if (( G2_FAIL == 0 )); then
            printf '  [ OK ] G2[%s] SIG%s at t+%ss (rc=%s) → recovery sync OK\n' "$i" "$sig" "$delay" "$rc"
        fi
    else
        FAIL=$((FAIL + 1)); printf '  [FAIL] G2[%s] recovery sync failed after SIG%s (rc=%s → %s)\n' "$i" "$sig" "$rc" "$rrc"
        tail -4 "$SB/out.txt" | sed 's/^/         /'
    fi
done

# ════════════════════════════════════════════════════════════════════════════
echo "== G3. vault state abuse ($FUZZ_SEED) =="
# ════════════════════════════════════════════════════════════════════════════
mkdev() { fresh_device "$1"; mkdir -p "$SB/$1-v"; }

# G3.1 — vault is a plain FILE
mkdev g3a; : > "$SB/g3a-v"
mk_base_env "$SB/g3a-home" "$SB/g3a-v" "$SB/g3a-b" "$R1"
run_obs 30 sync -y
verdict "G3.1 vault-is-a-file sync refused honestly" "$SB/out.txt" "$?"

# G3.2 — .git is a plain FILE inside an otherwise normal vault
mkdev g3b; printf 'x\n' > "$SB/g3b-v/n.md"; printf 'not a gitdir\n' > "$SB/g3b-v/.git"
mk_base_env "$SB/g3b-home" "$SB/g3b-v" "$SB/g3b-b" "$R1"
run_obs 30 sync -y
verdict "G3.2 .git-is-a-file sync refused honestly" "$SB/out.txt" "$?"

# G3.3 — .git is a DANGLING SYMLINK
mkdev g3c; printf 'x\n' > "$SB/g3c-v/n.md"; ln -s "$SB/nowhere-at-all" "$SB/g3c-v/.git"
mk_base_env "$SB/g3c-home" "$SB/g3c-v" "$SB/g3c-b" "$R1"
run_obs 30 sync -y
verdict "G3.3 .git-dangling-symlink refused honestly" "$SB/out.txt" "$?"

# G3.4 — .ob-sync/config replaced by /dev/null after a good init
mkdev g3d; printf 'x\n' > "$SB/g3d-v/n.md"
mk_base_env "$SB/g3d-home" "$SB/g3d-v" "$SB/g3d-b" "$R1"
run_obs 60 init -y >/dev/null 2>&1
ln -sf /dev/null "$SB/g3d-v/.ob-sync/config"
run_obs 30 status
verdict "G3.4 .ob-sync/config=/dev/null status" "$SB/out.txt" "$?"

# G3.5 — read-only VAULT → sync must fail honestly, not corrupt
mkdev g3e; printf 'x\n' > "$SB/g3e-v/n.md"
mk_base_env "$SB/g3e-home" "$SB/g3e-v" "$SB/g3e-b" "$R1"
run_obs 60 init -y >/dev/null 2>&1
chmod -R a-w "$SB/g3e-v"
run_obs 30 sync -y
rc=$?
chmod -R u+w "$SB/g3e-v"   # let the content check run
verdict "G3.5 read-only vault sync honest failure" "$SB/out.txt" "$rc"
if grep -q 'x' "$SB/g3e-v/n.md" 2>/dev/null; then
    PASS=$((PASS + 1)); printf '  [ OK ] G3.5 vault content survived the read-only attempt\n'
else
    FAIL=$((FAIL + 1)); printf '  [FAIL] G3.5 vault content lost\n'
fi

# G3.6 — read-only BACKUP DIR → backup must fail honestly
mkdev g3f; printf 'x\n' > "$SB/g3f-v/n.md"
mkdir -p "$SB/g3f-b"; chmod a-w "$SB/g3f-b"
mk_base_env "$SB/g3f-home" "$SB/g3f-v" "$SB/g3f-b" "$R1"
run_obs 60 init -y >/dev/null 2>&1
run_obs 30 backup
rc=$?
chmod u+w "$SB/g3f-b"
verdict "G3.6 read-only backup dir honest failure" "$SB/out.txt" "$rc"

# G3.7 — backup dir is a FILE
mkdev g3g; printf 'x\n' > "$SB/g3g-v/n.md"; : > "$SB/g3g-b"
mk_base_env "$SB/g3g-home" "$SB/g3g-v" "$SB/g3g-b" "$R1"
run_obs 30 backup
verdict "G3.7 backup-dir-is-a-file refused honestly" "$SB/out.txt" "$?"

# G3.8 — remote is a FILE
mkdev g3h; printf 'x\n' > "$SB/g3h-v/n.md"; : > "$SB/g3h-remote"
mk_base_env "$SB/g3h-home" "$SB/g3h-v" "$SB/g3h-b" "$SB/g3h-remote"
run_obs 30 sync -y
verdict "G3.8 remote-is-a-file refused honestly" "$SB/out.txt" "$?"

# ════════════════════════════════════════════════════════════════════════════
echo "== G4. repeated & contradictory CLI soup ($FUZZ_SEED) =="
# ════════════════════════════════════════════════════════════════════════════
mkdev g4; printf 'x\n' > "$SB/g4-v/n.md"
mk_base_env "$SB/g4-home" "$SB/g4-v" "$SB/g4-b" "$R1"
run_obs 60 init -y >/dev/null 2>&1

G4_CASES=(
  "sync -y -y -y"
  "status --json --json --json"
  "backup --json extra-arg"
  "restore latest latest"
  "sync -- -y"
  "-y sync"
  "--json sync"
  "sync -y --json -y --json"
  "doctor -y --json extra"
  "history 5 abc 10"
  "prune --keep 3 --keep 7 -y"
  "verify extra extra extra"
)
idx=0
for case in "${G4_CASES[@]}"; do
    idx=$((idx + 1))
    # deliberate word splitting: the soup IS the test
    # shellcheck disable=SC2086
    timeout 30 env "${ENVSPEC[@]}" "$OB" $case >"$SB/out.txt" 2>&1
    verdict "G4[$idx] ob-sync $case" "$SB/out.txt" "$?"
done

# vault must still be healthy after the soup
run_obs 60 sync -y
rrc=$?
if [[ "$rrc" == "0" ]] && grep -q 'x' "$SB/g4-v/n.md"; then
    PASS=$((PASS + 1)); printf '  [ OK ] G4 vault healthy after all CLI soup\n'
else
    FAIL=$((FAIL + 1)); printf '  [FAIL] G4 vault unhealthy after CLI soup (rc=%s)\n' "$rrc"
fi

# ════════════════════════════════════════════════════════════════════════════
echo "== G5. stdin flood & locale/TZ poison ($FUZZ_SEED) =="
# ════════════════════════════════════════════════════════════════════════════
mkdev g5; printf 'x\n' > "$SB/g5-v/n.md"
mk_base_env "$SB/g5-home" "$SB/g5-v" "$SB/g5-b" "$R1"
run_obs 60 init -y >/dev/null 2>&1

# G5.1 — endless stdin into a prompt-hungry command (no -y)
( yes "garbage" | timeout 30 env "${ENVSPEC[@]}" "$OB" prune >"$SB/out.txt" 2>&1 )
verdict "G5.1 endless-stdin prune" "$SB/out.txt" "$?"

# G5.2 — endless EOF into restore without confirmation
( yes "" | timeout 30 env "${ENVSPEC[@]}" "$OB" restore latest >"$SB/out.txt" 2>&1 )
verdict "G5.2 endless-EOF restore (no -y)" "$SB/out.txt" "$?"

# G5.3 — invalid locale
mk_base_env "$SB/g5-home" "$SB/g5-v" "$SB/g5-b" "$R1"
apply_poison "LC_ALL=xx_YY.INVALID"
apply_poison "LANG=xx_YY.INVALID"
run_obs 30 sync -y
rc=$?
if noisy_ex "$SB/out.txt"; then
    FAIL=$((FAIL + 1)); printf '  [FAIL] G5.3 invalid locale sync — real interpreter noise (rc=%s)\n' "$rc"
    grep -nE "$NOISE_RE|^(bash|sh):" "$SB/out.txt" | head -2 | sed 's/^/         /'
elif [[ "$rc" -le 2 ]]; then
    PASS=$((PASS + 1)); printf '  [ OK ] G5.3 invalid locale sync (rc=%s; only the bash setlocale startup warning)\n' "$rc"
else
    FAIL=$((FAIL + 1)); printf '  [FAIL] G5.3 invalid locale sync — rc=%s violates contract\n' "$rc"
fi

# G5.4 — C locale + UTF-8 filenames must round-trip
printf 'utf8\n' > "$SB/g5-v/نوت یادداشت 📝.md"
apply_poison "LC_ALL=C"
apply_poison "LANG=C"
run_obs 30 sync -y
verdict "G5.4 LC_ALL=C with UTF-8 names sync" "$SB/out.txt" "$?"
if git -c core.quotepath=false -C "$R1" ls-tree -r --name-only main | grep -q 'یادداشت'; then
    PASS=$((PASS + 1)); printf '  [ OK ] G5.4 UTF-8 name survived to remote under LC_ALL=C\n'
else
    FAIL=$((FAIL + 1)); printf '  [FAIL] G5.4 UTF-8 name lost under LC_ALL=C\n'
fi

# G5.5 — absurd TZ values × 3
mk_base_env "$SB/g5-home" "$SB/g5-v" "$SB/g5-b" "$R1"
for tz in "Invalid/Zone" "Etc/GMT+99" "UTC-14:99:99"; do
    apply_poison "TZ=$tz"
    run_obs 30 history
    verdict "G5.5 TZ=$tz history" "$SB/out.txt" "$?"
done

# ════════════════════════════════════════════════════════════════════════════
echo
echo "══════════════════════════════════════════════"
printf '  fuzz-human-C7 (seed %s):  PASS=%s  FAIL=%s\n' "$FUZZ_SEED" "$PASS" "$FAIL"
echo "══════════════════════════════════════════════"
if (( FAIL > 0 )); then exit 1; fi
exit 0
