#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# tests/marathon-interactive.sh — REAL-PTY interactive marathon for ob-sync
#
# The first suite that drives the tool through a genuine terminal:
#   · a real pty (menu launch, `[[ -t 0 ]]` branches, credential prompts
#     answered on /dev/tty — the exact conditions of the two 9.6.2/9.6.3
#     field reports),
#   · a fake GitHub with Basic-auth (401 → git asks Username/Password),
#   · every menu entry 0–19, hostile menu input, EOF at both prompts,
#   · the full operation set end-to-end against a live remote.
#
# Stdout of the SUITE is the report; the pty transcripts live in
# $MARATHON_SANDBOX/transcripts/ for post-mortem.
#
# Usage:  bash tests/marathon-interactive.sh
# Needs:  bash, git, curl, openssl, python3 (+ pty), git-http-backend
# Self-skips sections whose tools are missing.
# ═══════════════════════════════════════════════════════════════════════════
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OB_SRC="$REPO/bin/ob-sync"
LAB="$REPO/tests/pty-lab.py"

PASS=0
FAIL=0
SKIP=0
SB=""
SERVER_PID=""
GH_PORT=""

ok()   { PASS=$((PASS + 1)); printf '  [ OK ] %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  [SKIP] %s\n' "$1"; }

section() { printf '\n═══ %s ═══\n' "$1"; }

cleanup() {
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
    return 0
}
trap cleanup EXIT

# ── tool inventory ──────────────────────────────────────────────────────────
for t in git curl openssl python3; do
    if ! command -v "$t" >/dev/null 2>&1; then
        printf 'marathon: missing %s — cannot run\n' "$t"
        exit 3
    fi
done
if ! python3 -c 'import pty' 2>/dev/null; then
    printf 'marathon: python3 pty module unavailable — cannot run\n'
    exit 3
fi
HTTP_BACKEND=""
for c in /usr/lib/git-core/git-http-backend /usr/libexec/git-core/git-http-backend; do
    [[ -x "$c" ]] && HTTP_BACKEND="$c" && break
done
if [[ -z "$HTTP_BACKEND" ]]; then
    printf 'marathon: git http-backend not found — cannot run\n'
    exit 3
fi

# ── sandbox ─────────────────────────────────────────────────────────────────
SB="$(mktemp -d "${TMPDIR:-/tmp}/ob-marathon.XXXXXX")"
TR="$SB/transcripts"
mkdir -p "$TR" "$SB/repos"
printf 'marathon sandbox: %s\n' "$SB"

# The copy under test — NEVER the checkout itself (a section exercises
# self-update, which rewrites the binary it runs).
BIN="$SB/bin/ob-sync"
mkdir -p "$SB/bin"
cp "$OB_SRC" "$BIN"
chmod 755 "$BIN"

# Baseline environment for every pty session (sections may add more).
export NO_COLOR=1
export GIT_SSL_NO_VERIFY=1
export OB_NO_SELFUPDATE=1      # sections that test self-update override this
export OBS_GIT_TIMEOUT=60
export OBS_LOCAL_TIMEOUT=120
export OBS_UPDATE_CONNECT_TIMEOUT=3
export OBS_UPDATE_MAX_TIME=10

# ── the fake GitHub ─────────────────────────────────────────────────────────
GH_USER="soroush"
GH_PASS="tok123"
openssl req -x509 -newkey rsa:2048 -keyout "$SB/tls.key" -out "$SB/tls.crt" \
    -days 2 -nodes -subj "/CN=127.0.0.1" >/dev/null 2>&1 || :
TLS_ARGS=()
[[ -f "$SB/tls.crt" ]] && TLS_ARGS=(--tls-cert "$SB/tls.crt" --tls-key "$SB/tls.key")

python3 "$LAB" serve --root "$SB/repos" --user "$GH_USER" --password "$GH_PASS" \
    --ready "$SB/gh.ready" --log "$SB/gh-backend.log" "${TLS_ARGS[@]}" \
    >"$SB/gh.out" 2>"$SB/gh.err" &
SERVER_PID=$!
for _ in $(seq 1 50); do [[ -f "$SB/gh.ready" ]] && break; sleep 0.1; done
if [[ -f "$SB/gh.ready" ]]; then
    GH_PORT="$(cat "$SB/gh.ready")"
    SCHEME="http"; [[ -f "$SB/tls.crt" ]] && SCHEME="https"
    GH_URL="$SCHEME://127.0.0.1:$GH_PORT"
    printf 'fake GitHub: %s (user=%s)\n' "$GH_URL" "$GH_USER"
else
    printf 'marathon: fake GitHub failed to start\n'
    cat "$SB/gh.err" 2>/dev/null
    exit 3
fi

# Seed the upstream repository with one commit.
git init --bare -q -b main "$SB/repos/vault.git"
git -C "$SB/repos/vault.git" config http.receivepack true
git init -q "$SB/seed" 2>/dev/null
(
    cd "$SB/seed" &&
    printf '# Vault\n\nseeded by the marathon suite\n' > README.md &&
    git add . &&
    git -c user.email=m@ara -c user.name=marathon commit -qm "seed" &&
    git push -q "$SB/repos/vault.git" main
) >/dev/null 2>&1

# ═══════════════════════════════════════════════════════════════════════════
# helpers — pty sessions and assertions
# ═══════════════════════════════════════════════════════════════════════════

STEPS=""
new_steps() { STEPS="$SB/steps.$1.tsv"; : > "$STEPS"; }
step() { # name  expect-regex  send
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$STEPS"
}
NL='<NL>'
menu_pick() { step "menu-pick" 'Select an option \[0-19\]' "$1$NL"; }
menu_after() { step "menu-enter" 'Press Enter to return' "$NL"; }

# run_drive <transcript-basename> [argv...]  — STEPS file must be built.
# Sets RC_TESTED (the child's exit code) and DRIVE_MISSING (unanswered steps).
run_drive() {
    local tname="$1"; shift
    DRIVE_MISSING=""
    local out json
    out="$SB/drive.$tname.json"
    # "--" separates driver flags from the command-under-test: ob-sync's own
    # flags (init -y) must never be eaten by the driver's argparse.
    if ! json=$(python3 "$LAB" drive --steps "$STEPS" \
            --transcript "$TR/$tname.txt" \
            --step-timeout 90 --max-time 300 -- "$@" 2>"$SB/drive.$tname.err"); then
        RC_TESTED=999
        DRIVE_MISSING="driver crashed: $(tail -2 "$SB/drive.$tname.err" 2>/dev/null | tr '\n' ' ')"
        return 0
    fi
    RC_TESTED=$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["rc"])')
    DRIVE_MISSING=$(printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
missed = [s["name"] for s in d["steps"] if not s.get("ok")]
if d.get("pending"): missed += d["pending"]
print(" ".join(missed))')
}

assert_steps() { # label transcript
    if [[ -z "$DRIVE_MISSING" ]]; then
        ok "$1: every prompt answered in order"
    else
        bad "$1: unanswered steps → $DRIVE_MISSING"
    fi
}
assert_rc() { # label expected-rc
    if [[ "$RC_TESTED" == "$2" ]]; then
        ok "$1: exit code $2"
    else
        bad "$1: exit code $RC_TESTED (expected $2)"
    fi
}
assert_grep() { # label transcript pattern [min=1]
    local label="$1" file="$2" pat="$3" min="${4:-1}" n
    n=$(grep -Eac -- "$pat" "$file" 2>/dev/null || :)
    n="${n:-0}"
    if (( n >= min )); then
        ok "$label: '$pat' ×$n"
    else
        bad "$label: '$pat' found ×$n (need ≥$min)"
    fi
}
assert_nogrep() { # label transcript pattern
    local label="$1" file="$2" pat="$3" n
    n=$(grep -Eac -- "$pat" "$file" 2>/dev/null || :)
    if (( n == 0 )); then
        ok "$label: absent — '$pat'"
    else
        bad "$label: '$pat' appeared ×$n"
    fi
}

new_device() { # tag  → sets HOME_DIR OBS_CONFIG and EXPORTS an isolated HOME
    HOME_DIR="$SB/home-$1"
    OBS_CONFIG="$HOME_DIR/.config/ob-sync/config"
    mkdir -p "$HOME_DIR/.config/ob-sync"
    # Without this the child inherits the REAL $HOME: it would read the
    # user's actual ob-sync config, write backups into ~/obsidian-backups
    # and pin vaults into the real config file. (Found the hard way.)
    export HOME="$HOME_DIR"
}

# ═══════════════════════════════════════════════════════════════════════════
section "M0 · sanity"
# ═══════════════════════════════════════════════════════════════════════════
if bash -n "$BIN" 2>/dev/null; then ok "M0: copied ob-sync passes bash -n"; else bad "M0: bash -n"; fi
ver=$("$BIN" version 2>/dev/null)
if printf '%s' "$ver" | grep -q 'ob-sync 9\.'; then ok "M0: version reports ($ver)"; else bad "M0: version output"; fi

# ═══════════════════════════════════════════════════════════════════════════
section "M1 · interactive init — every prompt answered (fresh clone over 401-gated remote)"
# ═══════════════════════════════════════════════════════════════════════════
new_device a
V1="$SB/vaults/VaultOne"
export OBS_VAULT="$V1"   # nonexistent on purpose — init must clone into it
new_steps m1
step "warn-nonest"   'does not exist \(yet\)'   '-'
step "use-vault"     'Use this vault\?'         "$NL"        # default Y
step "remote-url"    'Remote URL'               "$GH_URL/vault.git$NL"
step "cred-helper"   'Remember credentials'     "$NL"        # default Y → store
step "git-username"  'Username for'             "$GH_USER$NL"
step "git-password"  'Password for'             "$GH_PASS$NL"
step "setup-done"    'Setup complete'           '-'
run_drive m1 "$BIN" init
assert_rc "M1" 0
assert_steps "M1" "$TR/m1.txt"
assert_grep "M1" "$TR/m1.txt" 'Username for'
assert_grep "M1" "$TR/m1.txt" 'Vault cloned'
if [[ -f "$HOME_DIR/.git-credentials" ]]; then
    ok "M1: credential store file created"
    if [[ "$(stat -c %a "$HOME_DIR/.git-credentials" 2>/dev/null)" == "600" ]]; then
        ok "M1: credential store chmod 600"
    else
        bad "M1: credential store mode is $(stat -c %a "$HOME_DIR/.git-credentials" 2>/dev/null)"
    fi
    grep -q "$GH_USER:$GH_PASS" "$HOME_DIR/.git-credentials" \
        && ok "M1: credentials cached for the fake GitHub" \
        || bad "M1: credential file lacks the login"
else
    bad "M1: ~/.git-credentials missing"
fi
[[ -d "$V1/.git" ]] && ok "M1: vault cloned with .git" || bad "M1: no .git in $V1"
grep -q "^VAULT=" "$OBS_CONFIG" 2>/dev/null && ok "M1: machine config pins VAULT" || bad "M1: config lacks VAULT"
grep -q "^REMOTE=" "$OBS_CONFIG" 2>/dev/null && ok "M1: machine config stores REMOTE" || bad "M1: config lacks REMOTE"
[[ -f "$V1/.ob-sync/config" ]] && ok "M1: vault identity card written" || bad "M1: identity card missing"

# ═══════════════════════════════════════════════════════════════════════════
section "M2 · menu marathon — every interactive entry walked in one session"
# ═══════════════════════════════════════════════════════════════════════════
new_device a   # same device as M1: pinned vault, stored credentials
export OBS_VAULT="$V1"
export EDITOR=true
new_steps m2
menu_pick "14"; menu_after                 # config
menu_pick "15"; menu_after                 # remote show
menu_pick "16"; menu_after                 # cron status (no crontab here)
menu_pick "17"; menu_after                 # edit-conf (EDITOR=true)
menu_pick "9";  menu_after                 # status
menu_pick "10"; menu_after                 # health
menu_pick "11"; menu_after                 # doctor
menu_pick "13"; menu_after                 # diff
menu_pick "4";  menu_after                 # backup
menu_pick "6";  menu_after                 # verify
menu_pick "12"; menu_after                 # quick (backup + sync)
menu_pick "1";  menu_after                 # sync
menu_pick "3";  menu_after                 # push
menu_pick "2";  menu_after                 # pull
menu_pick "5"                              # restore → interactive pick
step "restore-pick"  'Select backup \[1\]' "$NL"
step "restore-ok"    'This will REPLACE'   '-'
step "restore-go"    'Continue\? \[y/N\]'  'y'"$NL"
menu_after
menu_pick "0"
step "goodbye" 'Goodbye' '-'
run_drive m2 "$BIN"
assert_rc "M2" 0
assert_steps "M2" "$TR/m2.txt"
assert_grep "M2" "$TR/m2.txt" 'OBSIDIAN SYNC TOOL' 16
assert_grep "M2" "$TR/m2.txt" 'Goodbye'
assert_grep "M2" "$TR/m2.txt" 'Backup created and verified'
assert_grep "M2" "$TR/m2.txt" 'passed verification'
assert_grep "M2" "$TR/m2.txt" 'Vault restored from:'
assert_grep "M2" "$TR/m2.txt" 'Sync complete — [0-9]+ commit\(s\) in, [0-9]+ commit\(s\) out'
unset OBS_VAULT EDITOR

# ═══════════════════════════════════════════════════════════════════════════
section "M3 · hostile menu input — nothing escapes the choice parser"
# ═══════════════════════════════════════════════════════════════════════════
new_device a
export OBS_VAULT="$V1"
ATTACKS=("20" "-1" "abc" "" "5 5" "05" "999999999999999999999" "۵" "0x10" "1; touch $SB/pwned" "\$(id)" "sync --now" "٠١٢" "$(printf 'A%.0s' $(seq 1 400))" "$(printf 'x\001y')")
# NOTE: a leading-space attack (" 5") is NOT included — bash `read` strips
# IFS whitespace, so it would land on option 5 (Restore) by shell semantics,
# not by an ob-sync flaw. "5 5" keeps an internal space and stays invalid.
new_steps m3
# The driver only sends AFTER its expect matched: the first attack rides
# on the initial menu prompt, every later one on the previous 'Invalid
# choice', and the final gate sends the clean exit.
step "attack-first" 'Select an option \[0-19\]' "${ATTACKS[0]}$NL"
for a in "${ATTACKS[@]:1}"; do
    step "attack" 'Invalid choice' "$a$NL"
done
step "attack-last" 'Invalid choice' '0'$NL
step "goodbye" 'Goodbye' '-'
run_drive m3 "$BIN"
assert_rc "M3" 0
assert_steps "M3" "$TR/m3.txt"
n_att=${#ATTACKS[@]}
assert_grep "M3" "$TR/m3.txt" 'Invalid choice' "$n_att"
if [[ -e "$SB/pwned" ]]; then bad "M3: menu input executed a command!"; else ok "M3: no command execution from menu input"; fi
unset OBS_VAULT

# ═══════════════════════════════════════════════════════════════════════════
section "M4 · EOF at both interactive prompts exits cleanly"
# ═══════════════════════════════════════════════════════════════════════════
new_device a
export OBS_VAULT="$V1"
# M4a — EOF at the main choice
new_steps m4a
step "menu" 'Select an option \[0-19\]' '<EOF>'
run_drive m4a "$BIN"
assert_rc "M4a EOF at menu choice" 0
assert_steps "M4a" "$TR/m4a.txt"
assert_nogrep "M4a" "$TR/m4a.txt" 'Traceback|segmentation'
# M4b — EOF at the post-action "Press Enter"
new_steps m4b
menu_pick "9"
step "eof-enter" 'Press Enter to return' '<EOF>'
run_drive m4b "$BIN"
assert_rc "M4b EOF at Press-Enter" 0
assert_steps "M4b" "$TR/m4b.txt"
unset OBS_VAULT

# ═══════════════════════════════════════════════════════════════════════════
section "M5 · vault picker — the 9.6.2 question asked ONCE (plus Switch edges)"
# ═══════════════════════════════════════════════════════════════════════════
R5="$SB/roots"
VA="$R5/vAlpha"; VB="$R5/vBeta"
for v in "$VA" "$VB"; do mkdir -p "$v/.obsidian"; printf 'note\n' > "$v/n.md"; done
new_device five
unset OBS_VAULT   # discovery must run

# M5a — two vaults, nothing pinned: ONE question, then pinned.
export OB_DISCOVER_ROOTS="$R5"
new_steps m5a
step "pick-once" 'Multiple Obsidian vaults found' '1'"$NL"
step "pinned"    'Pinned as the default vault'    '-'
step "menu"      'Select an option \[0-19\]'      '0'"$NL"
step "goodbye"   'Goodbye'                        '-'
run_drive m5a "$BIN"
assert_rc "M5a" 0
assert_steps "M5a" "$TR/m5a.txt"
assert_grep  "M5a" "$TR/m5a.txt" 'Multiple Obsidian vaults found' 1
assert_nogrep "M5a" "$TR/m5a.txt" 'Multiple vaults available'          # the old second ask
assert_grep  "M5a" "$TR/m5a.txt" 'Multiple Obsidian vaults found' 1    # still exactly once

# M5b — relaunch: zero questions (the pin is remembered).
new_steps m5b
step "menu"    'Select an option \[0-19\]' '0'"$NL"
step "goodbye" 'Goodbye'                   '-'
run_drive m5b "$BIN"
assert_rc "M5b" 0
assert_steps "M5b" "$TR/m5b.txt"
assert_nogrep "M5b" "$TR/m5b.txt" 'Multiple'
assert_nogrep "M5b" "$TR/m5b.txt" 'Select vault'

# M5c — 19) Switch shows the session picker, picks vault 2.
new_steps m5c
menu_pick "19"
step "sw-pick"  'Multiple vaults available' '2'"$NL"
step "sw-warn"  'Vault switched for this session' '-'
step "sw-pause" 'Press Enter to return'     "$NL"   # the switch pauses too
# the redrawn menu header and its prompt share one atomic write; from the
# header's match-end the prompt is still findable — one step does both
step "sw-vault" 'Vault:.*vBeta'             '-'
menu_pick "0"
step "goodbye"  'Goodbye'                   '-'
run_drive m5c "$BIN"
assert_rc "M5c" 0
assert_steps "M5c" "$TR/m5c.txt"

# M5d — 19) typed path that does not exist → honest error, session kept.
new_steps m5d
menu_pick "19"
step "sw-gate"    'Select vault \[1\]'      '/definitely/not/here<NL>'
step "sw-badpath" 'No such directory'       '-'
step "sw-pause"   'Press Enter to return'   "$NL"
step "sw-menu"    'Select an option \[0-19\]' '0'"$NL"
step "goodbye"    'Goodbye'                 '-'
run_drive m5d "$BIN"
assert_rc "M5d" 0
assert_steps "M5d" "$TR/m5d.txt"

# M5e — 19) out-of-range number → Invalid selection, back to menu.
new_steps m5e
menu_pick "19"
step "sw-gate"   'Select vault \[1\]'       '99'"$NL"
step "sw-badnum" 'Invalid selection'        '-'
step "sw-pause"  'Press Enter to return'    "$NL"
step "sw-menu"   'Select an option \[0-19\]' '0'"$NL"
step "goodbye"   'Goodbye'                  '-'
run_drive m5e "$BIN"
assert_rc "M5e" 0
assert_steps "M5e" "$TR/m5e.txt"

# M5f — 19) no candidates at all → full-path offer, empty keeps session.
# A FRESH device: the pinned vault from M5a would otherwise take the
# "Only one vault known" branch instead of the no-candidates branch.
EMPTYROOT="$SB/empty-roots"; mkdir -p "$EMPTYROOT"
new_device five2
export OB_DISCOVER_ROOTS="$EMPTYROOT"
new_steps m5f
menu_pick "19"
step "sw-novault" 'No vault found'          "-"
step "sw-gate"    'Full path \(empty = keep' "$NL"
step "sw-pause"   'Press Enter to return'   "$NL"   # unconditional post-case pause
step "sw-menu"    'Select an option \[0-19\]' '0'"$NL"
step "goodbye"    'Goodbye'                 '-'
run_drive m5f "$BIN"
assert_rc "M5f" 0
assert_steps "M5f" "$TR/m5f.txt"
unset OB_DISCOVER_ROOTS
unset HOME   # M5 section end — later sections pick their own device

# ═══════════════════════════════════════════════════════════════════════════
section "M6 · repair — the 9.6.3 field regression (credential prompt must be answerable)"
# ═══════════════════════════════════════════════════════════════════════════
new_device a
export OBS_VAULT="$V1"

# M6a — stored credentials: repair never prompts, completes.
new_steps m6a
menu_pick "7"
step "rep-confirm"  'Continue\? \[y/N\]' 'y'"$NL"
step "rep-clone"    'Preparing a verified clone' '-'
step "rep-swap"     'Git metadata replaced atomically' '-'
step "rep-done"     'Repository verified and configured' '-'
menu_after
menu_pick "0"
step "goodbye"      'Goodbye' '-'
run_drive m6a "$BIN"
assert_rc "M6a stored-creds repair" 0
assert_steps "M6a" "$TR/m6a.txt"
assert_nogrep "M6a" "$TR/m6a.txt" 'Username for'
unset OBS_VAULT

# M6b — NO credentials, NO helper: repair asks, the answer is read (this is
# exactly the phone report: typed username used to freeze the tool).
new_device b
VB="$SB/vaults/VaultTwo"
export OBS_VAULT="$VB"
export OBS_REMOTE="$GH_URL/vault.git"
new_steps m6b-init
step "git-username" 'Username for' "$GH_USER$NL"
step "git-password" 'Password for' "$GH_PASS$NL"
step "setup-done"   'Setup complete' '-'
run_drive m6b-init "$BIN" init -y
assert_rc "M6b init -y (clone asks, answers)" 0
assert_steps "M6b" "$TR/m6b-init.txt"
# strip every stored trace of the login → repair must re-ask
rm -f "$HOME_DIR/.git-credentials"
git config --global --unset credential.helper >/dev/null 2>&1 || :
rm -rf "$VB/.git"   # the broken-metadata scenario repair exists for
new_steps m6b-rep
menu_pick "7"
step "rep-confirm"  'Continue\? \[y/N\]' 'y'"$NL"
step "git-username" 'Username for'      "$GH_USER$NL"
step "git-password" 'Password for'      "$GH_PASS$NL"
step "rep-swap"     'Git metadata replaced atomically' '-'
step "rep-done"     'Repository verified and configured' '-'
step "rep-offer"    'Remember credentials' "$NL"
step "rep-stored"   'Credentials will be remembered' '-'
menu_after
menu_pick "0"
step "goodbye"      'Goodbye' '-'
run_drive m6b-rep "$BIN"
assert_rc "M6b repair re-asks and survives" 0
assert_steps "M6b" "$TR/m6b-rep.txt"
assert_grep  "M6b" "$TR/m6b-rep.txt" 'Username for'
[[ -d "$VB/.git" ]] && ok "M6b: .git rebuilt" || bad "M6b: .git missing after repair"
unset OBS_VAULT OBS_REMOTE

# M6c — tampered stored credentials: repair -y fails HONESTLY (no lie, no hang).
new_device c
VC="$SB/vaults/VaultThree"
export OBS_VAULT="$VC"
export OBS_REMOTE="$GH_URL/vault.git"
# Pre-seed the credential helper so the NON-interactive init -y can clone
# (no terminal prompts in a scripted run); the password is corrupted after.
printf '%s%s/vault.git%s\n' "https://$GH_USER:$GH_PASS@127.0.0.1:$GH_PORT" "" "" > "$HOME_DIR/.git-credentials"
chmod 600 "$HOME_DIR/.git-credentials"
git config --global credential.helper store
if "$BIN" init -y >"$SB/m6c-init.log" 2>&1; then
    ok "M6c init -y baseline"
else
    skip "M6c init -y baseline failed ($(tail -1 "$SB/m6c-init.log"))"
fi
sed -i "s/$GH_PASS/BADPASS/" "$HOME_DIR/.git-credentials" 2>/dev/null || :
"$BIN" repair -y >"$SB/m6c.log" 2>&1; m6c_rc=$?
if [[ "$m6c_rc" == "1" ]] && grep -q 'Clone failed' "$SB/m6c.log"; then
    ok "M6c bad-credential repair fails honestly (rc=1, Clone failed)"
else
    bad "M6c: rc=$m6c_rc — $(tail -2 "$SB/m6c.log" | tr '\n' ' ')"
fi
unset OBS_VAULT OBS_REMOTE

# ═══════════════════════════════════════════════════════════════════════════
section "M7 · cron — graceful without crontab(1)"
# ═══════════════════════════════════════════════════════════════════════════
if command -v crontab >/dev/null 2>&1; then
    skip "M7: this host HAS crontab — degraded-path asserts apply to crontab-less hosts"
else
    new_device a
    export OBS_VAULT="$V1"
    "$BIN" cron status >"$SB/m7s.log" 2>&1; m7s=$?
    if [[ "$m7s" == "0" ]] && grep -q 'not available' "$SB/m7s.log"; then
        ok "M7: cron status degrades (rc=0, 'not available')"
    else
        bad "M7: cron status rc=$m7s — $(tail -1 "$SB/m7s.log")"
    fi
    "$BIN" cron show >"$SB/m7v.log" 2>&1; m7v=$?
    if [[ "$m7v" == "1" ]]; then ok "M7: cron show honest rc=1 without crontab"
    else bad "M7: cron show rc=$m7v"; fi
    "$BIN" cron install hourly >"$SB/m7i.log" 2>&1; m7i=$?
    if [[ "$m7i" == "1" ]]; then ok "M7: cron install honest rc=1 without crontab"
    else bad "M7: cron install rc=$m7i"; fi
    "$BIN" cron install "99 banana * * ?" >"$SB/m7b.log" 2>&1; m7b=$?
    if [[ "$m7b" == "1" ]] && grep -qi 'invalid\|schedule' "$SB/m7b.log"; then
        ok "M7: garbage schedule rejected"
    else
        bad "M7: garbage schedule rc=$m7b — $(tail -1 "$SB/m7b.log")"
    fi
    unset OBS_VAULT
fi

# ═══════════════════════════════════════════════════════════════════════════
section "M8 · CLI battery — quick contract checks"
# ═══════════════════════════════════════════════════════════════════════════
new_device a
export OBS_VAULT="$V1"
"$BIN" help >/dev/null 2>&1 && ok "M8: help rc=0" || bad "M8: help"
"$BIN" badcmd >/dev/null 2>&1 && bad "M8: unknown command accepted" || ok "M8: unknown command rc=1"
"$BIN" --badflag >/dev/null 2>&1 && bad "M8: unknown option accepted" || ok "M8: unknown option rc=1"
"$BIN" status --json >/dev/null 2>&1 && ok "M8: status --json rc=0" || bad "M8: status --json"
EDITOR="" "$BIN" edit-conf >/dev/null 2>&1 && bad "M8: empty EDITOR accepted" || ok "M8: empty EDITOR refused"
# Non-interactive edit-conf must refuse honestly (the tty path already ran
# inside the M2 menu with EDITOR=true).
EDITOR=true "$BIN" edit-conf >/dev/null 2>&1 && bad "M8: non-tty edit-conf accepted" || ok "M8: non-tty edit-conf refused honestly"
unset OBS_VAULT
# unconfigured device: honest failures, no crash
new_device fresh
"$BIN" diff >/dev/null 2>&1 && bad "M8: diff without vault accepted" || ok "M8: diff without vault rc=1"
"$BIN" sync -y >/dev/null 2>&1 && bad "M8: sync without remote accepted" || ok "M8: sync without remote rc=1"
HJ=$("$BIN" health --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("result","?"))' 2>/dev/null || :)
case "$HJ" in ok|error) ok "M8: health --json answers honestly without vault (result=$HJ)" ;; *) bad "M8: health --json → $HJ" ;; esac

# ═══════════════════════════════════════════════════════════════════════════
section "M9 · soak — 12 consecutive real sync cycles (10 CLI + 2 menu)"
# ═══════════════════════════════════════════════════════════════════════════
new_device nine
export HOME_DIR
R9="$SB/repos/soak.git"
git init --bare -q -b main "$R9"
V9="$SB/soak-vault"
export OBS_VAULT="$V9"
export OBS_REMOTE="$R9"
if "$BIN" init -y >"$SB/m9-init.log" 2>&1; then ok "M9: init against bare remote"; else bad "M9: init — $(tail -1 "$SB/m9-init.log")"; fi
soak_fail=0
for i in $(seq 1 10); do
    printf 'round %s — %s\n' "$i" "$(date +%s)" > "$V9/note-$i.md"
    if ! "$BIN" sync -y >"$SB/m9-r$i.log" 2>&1; then
        soak_fail=$((soak_fail + 1)); bad "M9: sync round $i failed — $(tail -1 "$SB/m9-r$i.log")"
        continue
    fi
    cnt=$(git -C "$V9" rev-list --count HEAD 2>/dev/null || echo 0)
    # the bare remote starts EMPTY: after round i the history holds exactly
    # i commits (each sync adds one; there is no seed commit)
    [[ "$cnt" == "$i" ]] || { soak_fail=$((soak_fail + 1)); bad "M9: round $i commit count $cnt != $i"; }
done
(( soak_fail == 0 )) && ok "M9: 10 CLI sync rounds, history grows every round"
# two menu-driven rounds
for i in 11 12; do
    printf 'menu round %s\n' "$i" > "$V9/note-$i.md"
    new_steps "m9m$i"
    menu_pick "1"
    menu_after
    menu_pick "0"
    step "goodbye" 'Goodbye' '-'
    run_drive "m9m$i" "$BIN"
    cnt=$(git -C "$V9" rev-list --count HEAD 2>/dev/null || echo 0)
    if [[ "$RC_TESTED" == "0" && "$cnt" == "$i" ]]; then
        ok "M9: menu sync round $i committed (history=$cnt)"
    else
        bad "M9: menu round $i rc=$RC_TESTED history=$cnt"
    fi
done
unset OBS_VAULT OBS_REMOTE

# ═══════════════════════════════════════════════════════════════════════════
section "M10 · self-update — upgrade, downgrade refusal, garbage, checkout guard"
# ═══════════════════════════════════════════════════════════════════════════
BIN8="$SB/bin/ob-sync-upd"
cp "$OB_SRC" "$BIN8"; chmod 755 "$BIN8"
# never hardcode the tool's version: read it, test against CUR→NEXT
CUR_VER=$(sed -n 's/^readonly VERSION="\([^"]*\)".*/\1/p' "$OB_SRC")
NEXT_VER=$(awk -F. -v OFS=. '{ $NF = $NF + 1; print }' <<< "$CUR_VER")
mk_payload() { # dir version
    mkdir -p "$1"
    { printf '#!/usr/bin/env bash\nreadonly VERSION="%s"\nprintf "ob-sync %s\\n"\n' "$2" "$2"; } > "$1/ob-sync"
    chmod 755 "$1/ob-sync"
}
# M10a — strictly-newer release upgrades the installed copy
mk_payload "$SB/pnext" "$NEXT_VER"
env -u OB_NO_SELFUPDATE OB_UPDATE_URL="file://$SB/pnext/ob-sync" "$BIN8" update >"$SB/m10a.log" 2>&1; m10a=$?
if [[ "$m10a" == "0" ]] && grep -qF "updated v$CUR_VER → v$NEXT_VER" "$SB/m10a.log" \
   && grep -qF "readonly VERSION=\"$NEXT_VER\"" "$BIN8"; then
    ok "M10a: file:// upgrade v$CUR_VER → v$NEXT_VER applied atomically"
else
    bad "M10a: rc=$m10a — $(tail -1 "$SB/m10a.log")"
fi
# M10b — older release: never downgrade (fresh copy: M10a legitimately
# replaced BIN8 with the 9.6.4 stub — that is self-update WORKING)
BIN8B="$SB/bin/ob-sync-upd-b"
cp "$OB_SRC" "$BIN8B"; chmod 755 "$BIN8B"
mk_payload "$SB/pold" "9.6.0"
env -u OB_NO_SELFUPDATE OB_UPDATE_URL="file://$SB/pold/ob-sync" "$BIN8B" update >"$SB/m10b.log" 2>&1; m10b=$?
if [[ "$m10b" == "0" ]] && grep -q 'up to date' "$SB/m10b.log" \
   && grep -qF "readonly VERSION=\"$CUR_VER\"" "$BIN8B"; then
    ok "M10b: downgrade refused (stays v$CUR_VER)"
else
    bad "M10b: rc=$m10b — $(tail -1 "$SB/m10b.log")"
fi
# M10c — garbage payload: refused, current version kept (fresh copy again)
BIN8C="$SB/bin/ob-sync-upd-c"
cp "$OB_SRC" "$BIN8C"; chmod 755 "$BIN8C"
mkdir -p "$SB/pgarb" && printf 'not a shell script at all\n' > "$SB/pgarb/ob-sync"
env -u OB_NO_SELFUPDATE OB_UPDATE_URL="file://$SB/pgarb/ob-sync" "$BIN8C" update >"$SB/m10c.log" 2>&1; m10c=$?
if [[ "$m10c" == "0" ]] && grep -q 'not a valid ob-sync script' "$SB/m10c.log" \
   && grep -qF "readonly VERSION=\"$CUR_VER\"" "$BIN8C"; then
    ok "M10c: garbage payload rejected"
else
    bad "M10c: rc=$m10c — $(tail -1 "$SB/m10c.log")"
fi
# M10d — a copy inside the git checkout is NEVER overwritten
mk_payload "$SB/p965" "9.6.5"
git_st() { git -C "$REPO" status --porcelain bin/ob-sync 2>/dev/null; }
st_before="$(git_st)"
env -u OB_NO_SELFUPDATE OB_UPDATE_URL="file://$SB/p965/ob-sync" bash "$OB_SRC" update >"$SB/m10d.log" 2>&1; m10d=$?
st_after="$(git_st)"
# the working tree may legitimately carry uncommitted dev changes — the
# contract is only that the UPDATE touched nothing
if [[ "$m10d" == "0" ]] && grep -q 'belongs to a git checkout' "$SB/m10d.log" \
   && [[ "$st_before" == "$st_after" ]]; then
    ok "M10d: checkout copy protected (bin/ob-sync untouched by the update)"
else
    bad "M10d: rc=$m10d — $(tail -1 "$SB/m10d.log")"
fi

# ═══════════════════════════════════════════════════════════════════════════
section "verdict"
# ═══════════════════════════════════════════════════════════════════════════
printf '\nMARATHON RESULT: PASS=%d FAIL=%d SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"
printf 'sandbox preserved: %s\n' "$SB"
(( FAIL == 0 )) || printf '\nFailed sections left transcripts in %s/transcripts/\n' "$SB"
exit $(( FAIL > 0 ? 1 : 0 ))
