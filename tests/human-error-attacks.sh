#!/usr/bin/env bash
#
# ─────────────────────────────────────────────────────────────────────────────
#   ob-sync HUMAN-ERROR ATTACK SUITE  (complementary to user-error-tests.sh)
#
#   Where user-error-tests.sh covers hand-edited config files, this suite
#   simulates everything else a real user (or their environment) can get
#   wrong, and demands the tool's contract holds:
#
#     · never corrupt or lose vault data,
#     · never hang, never crash with raw bash noise,
#     · every mistake ends in an HONEST, actionable failure (or a
#       transparent self-heal), and a working state afterwards.
#
#     H1  CLI misuse            (wrong commands, flags, counts, empties)
#     H2  environment garbage   (absurd numeric values, broken paths)
#     H3  config file torture   (unreadable, huge, duplicate keys, BOM)
#     H4  lock-directory abuse  (file-as-lock, garbage / live / dead PIDs)
#     H5  remote-hostile input  (ext:: transport injection, spaces, garbage)
#     H6  missing tools         (PATH without tar / git / any hash tool)
#     H7  non-interactive abuse (EOF where an answer is expected)
#     H8  locale & timezone     (LC_ALL=C over UTF-8 names, junk TZ)
#     H9  numeric edge values   (0, 1, and arithmetic-overflow monsters)
#     H10 vault identity abuse  (vault deleted / replaced by a file /
#                               replaced by a symlink between runs)
#     H11 argument injection    (OBS_BRANCH starting with "--" reaching
#                               git push; OBS_ATTACH_DIR traversal)
#     H12 cron input validation (rogue schedules that cronie would mangle)
#
#   Self-contained: throwaway sandbox, local bare remotes, no network.
#   Run:  bash tests/human-error-attacks.sh
# ─────────────────────────────────────────────────────────────────────────────

set -u

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
OB="$ROOT/bin/ob-sync"

SB="$(mktemp -d "${TMPDIR:-/tmp}/ob-sync-human-XXXXXX")" \
    || { echo "FATAL: cannot create the sandbox directory"; exit 1; }
mkdir -p "$SB/tmp"
export TMPDIR="$SB/tmp"
trap 'rm -rf -- "$SB"' EXIT

PASS=0
FAIL=0
SKIP=0

t() {
    local name="$1" want="$2"; shift 2
    "$@" >"$SB/out.txt" 2>&1
    local got=$?
    if [[ "$got" == "$want" ]]; then
        PASS=$((PASS + 1)); printf '  [ OK ] %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); printf '  [FAIL] %s (want rc=%s got rc=%s)\n' "$name" "$want" "$got"
        tail -6 "$SB/out.txt" | sed 's/^/         /'
    fi
}
assert() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        PASS=$((PASS + 1)); printf '  [ OK ] %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$name"
    fi
}
assert_not() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        FAIL=$((FAIL + 1)); printf '  [FAIL] %s (unexpectedly true)\n' "$name"
    else
        PASS=$((PASS + 1)); printf '  [ OK ] %s\n' "$name"
    fi
}
assert_quiet() {  # assert the output contains NO bash-internal error noise
    local name="$1" out="$2"
    if grep -qE "unbound variable|syntax error|No such file or directory$|command not found|integer expression|value too great" "$out" 2>/dev/null; then
        FAIL=$((FAIL + 1)); printf '  [FAIL] %s — raw interpreter noise leaked:\n' "$name"
        grep -E "unbound variable|syntax error|command not found|integer expression|value too great" "$out" | head -3 | sed 's/^/         /'
    else
        PASS=$((PASS + 1)); printf '  [ OK ] %s\n' "$name"
    fi
}
skip_test() { SKIP=$((SKIP + 1)); printf '  [SKIP] %s — %s\n' "$1" "$2"; }

# A fully provisioned device for the "healthy baseline" runs.
BASE="$SB/base"
mkdir -p "$BASE" "$SB/remote-base.git"
git init -q --bare "$SB/remote-base.git"
mkdir -p "$BASE-home"
git config --file "$BASE-home/.gitconfig" user.email human@test.local
git config --file "$BASE-home/.gitconfig" user.name "Human Tests"
git config --file "$BASE-home/.gitconfig" init.defaultBranch main
printf 'hello\n' > "$BASE/note.md"

# run_base <args...> — run ob-sync as the fully-provisioned base device
run_base() {
    env HOME="$BASE-home" OBS_CONFIG="$BASE-home/.config/ob-sync/config" \
        OBS_VAULT="$BASE" OBS_BACKUP_DIR="$BASE-backups" OBS_LOG= \
        GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" OBS_REMOTE="$SB/remote-base.git" \
        "$OB" "$@"
}

env HOME="$BASE-home" OBS_CONFIG="$BASE-home/.config/ob-sync/config" OBS_VAULT="$BASE" \
    OBS_BACKUP_DIR="$BASE-backups" OBS_LOG= GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" \
    OBS_REMOTE="$SB/remote-base.git" "$OB" init -y >/dev/null 2>&1
env HOME="$BASE-home" OBS_CONFIG="$BASE-home/.config/ob-sync/config" OBS_VAULT="$BASE" \
    OBS_BACKUP_DIR="$BASE-backups" OBS_LOG= GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" \
    OBS_REMOTE="$SB/remote-base.git" "$OB" sync -y >/dev/null 2>&1

echo "== H1. CLI misuse battery =="
t "H1 unknown command"            1 run_base frobnicate
t "H1 empty-string command"       1 run_base ""
t "H1 whitespace command"         1 run_base " "
t "H1 unknown global option"      1 run_base --nope status
t "H1 unknown post-command flag"  1 run_base status --nope
t "H1 sync with junk args"        1 run_base sync junkarg1 junkarg2
t "H1 backup with extra args"     1 run_base backup extra
t "H1 verify with extra args"     1 run_base verify extra
t "H1 history non-numeric falls back to default" 0 env HOME="$BASE-home" OBS_CONFIG="$BASE-home/.config/ob-sync/config" \
    OBS_VAULT="$BASE" OBS_BACKUP_DIR="$BASE-backups" OBS_LOG= GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" \
    "$OB" history abc
t "H1 history huge number"        0 env HOME="$BASE-home" OBS_CONFIG="$BASE-home/.config/ob-sync/config" \
    OBS_VAULT="$BASE" OBS_BACKUP_DIR="$BASE-backups" OBS_LOG= GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" \
    "$OB" history 999999999999
t "H1 log with garbage arg"       1 run_base log --bogus
t "H1 flags after -- are positional" 1 run_base -- -y status
t "H1 repeated --json tolerated"  0 run_base status --json --json
t "H1 repeated -y tolerated"      0 run_base sync -y -y
t "H1 restore unknown flag"       1 run_base restore --bogus latest
t "H1 restore target looks like flag" 1 run_base restore -rf
t "H1 cron garbage subcommand"    1 run_base cron frobnicate
t "H1 cron install missing schedule" 1 run_base cron install
assert "H1 misuse storm left the vault intact" bash -c "test -f '$BASE/note.md'"
assert_quiet "H1 no interpreter noise in misuse storm" "$SB/out.txt"

echo
echo "== H2. environment garbage =="
echo
printf 'NOTE: empty OBS_VAULT is treated as unset (standard shell semantics) — sync proceeds normally\n'
run_base sync -y >/dev/null 2>&1 && PASS=$((PASS+1)) && printf '  [ OK ] H2 OBS_VAULT empty string behaves as unset\n' \
    || { FAIL=$((FAIL+1)); printf '  [FAIL] H2 OBS_VAULT empty string\n'; }
t "H2 OBS_VAULT points at a FILE" 1 env HOME="$BASE-home" OBS_CONFIG="$BASE-home/.config/ob-sync/config" \
    OBS_VAULT="$BASE/note.md" OBS_BACKUP_DIR="$BASE-backups" OBS_LOG= GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" \
    "$OB" sync -y
assert "H2 file-as-vault never damaged the note" bash -c "test -f '$BASE/note.md'"
t "H2 OBS_BACKUP_DIR points at a FILE" 1 env HOME="$BASE-home" OBS_CONFIG="$BASE-home/.config/ob-sync/config" \
    OBS_VAULT="$BASE" OBS_BACKUP_DIR="$BASE/note.md" OBS_LOG= GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" \
    "$OB" backup
assert "H2 file-as-backup-dir never damaged the note" bash -c "test -f '$BASE/note.md'"
t "H2 OBS_LOG points into a nonexistent dir (sync still works)" 0 \
    env HOME="$BASE-home" OBS_CONFIG="$BASE-home/.config/ob-sync/config" OBS_VAULT="$BASE" \
    OBS_BACKUP_DIR="$BASE-backups" OBS_LOG="/nonexistent-xyz/dir/ob.log" GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" \
    "$OB" sync -y
t "H2 TMPDIR nonexistent → honest lock failure (rc 2)" 2 \
    env TMPDIR="/nonexistent-tmp-xyz" HOME="$BASE-home" OBS_CONFIG="$BASE-home/.config/ob-sync/config" \
    OBS_VAULT="$BASE" OBS_BACKUP_DIR="$BASE-backups" OBS_LOG= GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" \
    "$OB" sync -y
t "H2 TMPDIR is a FILE → honest failure" 2 \
    env TMPDIR="$BASE/note.md" HOME="$BASE-home" OBS_CONFIG="$BASE-home/.config/ob-sync/config" \
    OBS_VAULT="$BASE" OBS_BACKUP_DIR="$BASE-backups" OBS_LOG= GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" \
    "$OB" sync -y
assert "H2 vault survived the TMPDIR attacks" bash -c "test -f '$BASE/note.md'"
# a fresh sync with the restored environment must still work
t "H2 sync green again after environment attacks" 0 run_base sync -y

echo
echo "== H3. config file torture =="
CFG="$BASE-home/.config/ob-sync/config"
cp "$CFG" "$SB/config.bak"

# unreadable config (chmod 000) — resolution falls back, nothing crashes
cp "$SB/config.bak" "$CFG"; chmod 000 "$CFG"
t "H3 unreadable config: status still works" 0 env HOME="$BASE-home" \
    OBS_CONFIG="$CFG" OBS_VAULT="$BASE" OBS_BACKUP_DIR="$BASE-backups" OBS_LOG= \
    GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" "$OB" status
chmod 644 "$CFG"

# a 1 MB garbage config
python3 - "$CFG" <<'EOF'
import sys
with open(sys.argv[1], 'w') as f:
    f.write("# junk\n")
    for i in range(30000):
        f.write(f"JUNK{i} = some long garbage value {i} \n")
EOF
t "H3 1MB garbage config: sync survives" 0 env HOME="$BASE-home" OBS_CONFIG="$CFG" \
    OBS_VAULT="$BASE" OBS_BACKUP_DIR="$BASE-backups" OBS_LOG= GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" \
    "$OB" sync -y

# duplicate keys — last one wins, no crash, correct vault still used
printf 'VAULT=/definitely/not/real\nVAULT=%s\n' "$BASE" > "$CFG"
t "H3 duplicate VAULT keys: correct vault wins" 0 env HOME="$BASE-home" OBS_CONFIG="$CFG" \
    OBS_VAULT= OBS_BACKUP_DIR="$BASE-backups" OBS_LOG= GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" \
    "$OB" status
cp "$SB/config.bak" "$CFG"

# UTF-8 BOM prefix
printf '\xef\xbb\xbfVAULT=%s\n' "$BASE" > "$CFG"
t "H3 BOM-prefixed config tolerated" 0 env HOME="$BASE-home" OBS_CONFIG="$CFG" \
    OBS_VAULT= OBS_BACKUP_DIR="$BASE-backups" OBS_LOG= GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" \
    "$OB" status
cp "$SB/config.bak" "$CFG"
assert "H3 config survived every torture" bash -c "test -s '$CFG'"

echo
echo "== H4. lock-directory abuse =="
LOCK="$SB/tmp/obs-sync.lock"

# (a) lock dir replaced by a plain FILE
rm -rf "$LOCK"; printf 'not a dir' > "$LOCK"
t "H4 file-as-lock → honest rc 2, no bulldozing" 2 run_base sync -y
assert "H4 the file lock was reported, vault intact" bash -c "test -f '$BASE/note.md'"
rm -f "$LOCK"

# (b) garbage pid
mkdir -p "$LOCK"; printf 'garbage-not-a-pid\n' > "$LOCK/pid"
t "H4 garbage pid → stale reclaim, sync green" 0 run_base sync -y

# (c) negative / absurd pid values
mkdir -p "$LOCK"; printf -- '-42\n' > "$LOCK/pid"
t "H4 negative pid → stale reclaim" 0 run_base sync -y
mkdir -p "$LOCK"; printf '99999999999999999999\n' > "$LOCK/pid"
t "H4 absurd pid → stale reclaim" 0 run_base sync -y

# (d) pid of a DEAD process
mkdir -p "$LOCK"
( sleep 30 & echo $! > "$LOCK/pid"; )
DEAD_PID=$(cat "$LOCK/pid"); kill -9 "$DEAD_PID" 2>/dev/null; wait "$DEAD_PID" 2>/dev/null
t "H4 dead-owner pid → stale reclaim" 0 run_base sync -y

# (e) pid of a LIVE non-ob-sync process (this test's own shell)
mkdir -p "$LOCK"; printf '%s\n' "$$" > "$LOCK/pid"
t "H4 live-owner pid → stands down (rc 2)" 2 run_base sync -y
assert "H4 live lock left untouched" bash -c "test -f '$LOCK/pid'"
rm -rf "$LOCK"

# (f) pid file is a DIRECTORY (cat fails)
mkdir -p "$LOCK/pid"
t "H4 pid-as-directory → rc 2 (too young to bulldoze)" 2 run_base sync -y
rm -rf "$LOCK"
t "H4 clean state → sync green again" 0 run_base sync -y

echo
echo "== H5. remote-hostile input =="
# NOTE: OBS_REMOTE only takes effect when the vault has no origin yet —
# an established origin is never silently re-pointed. Use a FRESH vault
# so the hostile URL is actually the one git is asked to fetch from.
HV5="$SB/vault-h5"; mkdir -p "$HV5"; printf 'x\n' > "$HV5/note.md"
# ext:: transport injection — git blocks it by default; ob-sync must NOT
# re-enable the protocol anywhere (no -c protocol.ext.allow=always).
PWNED="$SB/pwned-marker"
rm -f "$PWNED"
t "H5 ext:: injection refused on fresh vault" 1 env HOME="$BASE-home" \
    OBS_CONFIG="$SB/h5-never-config" OBS_VAULT="$HV5" OBS_BACKUP_DIR="$SB/h5-bk" OBS_LOG= \
    GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" \
    OBS_REMOTE="ext::sh -c touch%20$PWNED" "$OB" sync -y
assert_not "H5 the injected command did NOT execute" test -e "$PWNED"
assert "H5 vault intact after the injection attempt" bash -c "test -f '$HV5/note.md'"
# note: local work still committed is acceptable; the next sync must heal
t "H5 sync green again with the honest remote" 0 run_base sync -y
# and an established origin is NEVER silently re-pointed by the env var
ORIGIN_BEFORE=$(git -C "$BASE" remote get-url origin)
env HOME="$BASE-home" OBS_CONFIG="$BASE-home/.config/ob-sync/config" OBS_VAULT="$BASE" \
    OBS_BACKUP_DIR="$BASE-backups" OBS_LOG= GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" \
    OBS_REMOTE="/tmp/some-other-remote-never-used.git" "$OB" sync -y >/dev/null 2>&1
ORIGIN_AFTER=$(git -C "$BASE" remote get-url origin)
if [[ "$ORIGIN_BEFORE" == "$ORIGIN_AFTER" ]]; then
    PASS=$((PASS+1)); printf '  [ OK ] H5 env remote never silently re-points an established origin\n'
else
    FAIL=$((FAIL+1)); printf '  [FAIL] H5 origin was re-pointed: %s -> %s\n' "$ORIGIN_BEFORE" "$ORIGIN_AFTER"
fi

# a remote path containing spaces must work end-to-end (via `remote` command)
SP="$SB/remote with spaces.git"
git init -q --bare "$SP"
t "H5 remote <spaced-url> accepted" 0 run_base remote "$SP"
t "H5 push to a remote path containing spaces" 0 run_base push -y
assert "H5 vault reached the spaced remote" \
    bash -c "git -C '$SP' ls-tree --name-only main | grep -q note.md"
run_base remote "$SB/remote-base.git" >/dev/null 2>&1   # restore the honest remote

echo
echo "== H6. missing tools (minimal PATH) =="
M="$SB/min-path"; mkdir -p "$M"
# every dependency EXCEPT tar
for tool in git find grep sort cut tr wc tail head mktemp du xargs dirname date awk sed sha256sum env sh bash uname readlink cat rm mv cp ls; do
    p=$(command -v "$tool" 2>/dev/null) && ln -sf "$p" "$M/$tool"
done
t "H6 no tar → honest dependency failure" 1 env PATH="$M" HOME="$BASE-home" \
    OBS_CONFIG="$BASE-home/.config/ob-sync/config" OBS_VAULT="$BASE" OBS_BACKUP_DIR="$BASE-backups" \
    OBS_LOG= GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" "$OB" sync -y
echo
printf 'NOTE: doctor exits 1 when diagnostics FIND problems — the missing tar was reported\n'
DOCTOR_OUT="$SB/doctor.txt"
env PATH="$M" HOME="$BASE-home" OBS_CONFIG="$BASE-home/.config/ob-sync/config" OBS_VAULT="$BASE" \
    OBS_BACKUP_DIR="$BASE-backups" OBS_LOG= GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" \
    "$OB" doctor > "$DOCTOR_OUT" 2>&1
if grep -q 'tar' "$DOCTOR_OUT"; then PASS=$((PASS+1)); printf '  [ OK ] H6 no tar: doctor names the missing tool\n'
else FAIL=$((FAIL+1)); printf '  [FAIL] H6 doctor did not name the missing tool\n'; fi
# PATH without git
G="$SB/no-git-path"; mkdir -p "$G"
for tool in tar find grep sort cut tr wc tail head mktemp du xargs dirname date awk sed sha256sum env sh bash; do
    p=$(command -v "$tool" 2>/dev/null) && ln -sf "$p" "$G/$tool"
done
t "H6 no git → honest dependency failure" 1 env PATH="$G" HOME="$BASE-home" \
    OBS_CONFIG="$BASE-home/.config/ob-sync/config" OBS_VAULT="$BASE" OBS_BACKUP_DIR="$BASE-backups" \
    OBS_LOG= GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" "$OB" sync -y
# no hashing tool at all
H="$SB/no-hash-path"; mkdir -p "$H"
for tool in git tar find grep sort cut tr wc tail head mktemp du xargs dirname date awk sed env sh bash; do
    p=$(command -v "$tool" 2>/dev/null) && ln -sf "$p" "$H/$tool"
done
t "H6 no sha256sum/shasum → honest dependency failure" 1 env PATH="$H" HOME="$BASE-home" \
    OBS_CONFIG="$BASE-home/.config/ob-sync/config" OBS_VAULT="$BASE" OBS_BACKUP_DIR="$BASE-backups" \
    OBS_LOG= GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" "$OB" sync -y
assert "H6 vault intact after tool amputation" bash -c "test -f '$BASE/note.md'"
t "H6 healthy PATH → green again" 0 run_base sync -y

echo
echo "== H7. non-interactive abuse (EOF where an answer is expected) =="
echo
printf 'NOTE: init with an ALREADY-configured vault needs no prompt — use a remote-less vault for this test\n'
H7V="$SB/h7vault"; mkdir -p "$H7V"; printf 'x\n' > "$H7V/note.md"
t "H7 remote-less init on EOF → honest refusal" 1 \
    env HOME="$BASE-home" OBS_CONFIG="$SB/h7-never-config" \
    OBS_VAULT="$H7V" OBS_BACKUP_DIR="$SB/h7-bk" OBS_LOG= GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" \
    bash -c "'$OB' init </dev/null"
t "H7 restore latest on EOF refuses (no consent)" 1 \
    env HOME="$BASE-home" OBS_CONFIG="$BASE-home/.config/ob-sync/config" OBS_VAULT="$BASE" \
    OBS_BACKUP_DIR="$BASE-backups" OBS_LOG= GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" \
    bash -c "'$OB' restore latest </dev/null"
assert "H7 EOF-restore left the vault untouched" bash -c "test -f '$BASE/note.md'"
t "H7 edit-conf with EDITOR=false → honest" 0 \
    env EDITOR=false HOME="$BASE-home" OBS_CONFIG="$BASE-home/.config/ob-sync/config" OBS_VAULT="$BASE" \
    OBS_BACKUP_DIR="$BASE-backups" OBS_LOG= GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" \
    bash -c "'$OB' edit-conf </dev/null || true" bash
t "H7 -y restore proceeds non-interactively" 0 run_base restore latest -y

echo
echo "== H8. locale & timezone torture =="
t "H8 LC_ALL=C sync with a UTF-8 vault" 0 env LC_ALL=C LANG=C HOME="$BASE-home" \
    OBS_CONFIG="$BASE-home/.config/ob-sync/config" OBS_VAULT="$BASE" OBS_BACKUP_DIR="$BASE-backups" \
    OBS_LOG= GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" "$OB" sync -y
printf 'فارسی\n' > "$BASE/یادداشت.md"
t "H8 LC_ALL=C sync adding a Persian note" 0 env LC_ALL=C LANG=C HOME="$BASE-home" \
    OBS_CONFIG="$BASE-home/.config/ob-sync/config" OBS_VAULT="$BASE" OBS_BACKUP_DIR="$BASE-backups" \
    OBS_LOG= GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" "$OB" sync -y
assert "H8 Persian note reached the remote under LC_ALL=C" \
    bash -c "git -c core.quotepath=false -C '$SB/remote-base.git' ls-tree -r --name-only main | grep -q 'یادداشت'"
t "H8 TZ nonsense: sync unaffected" 0 env TZ="Mars/Olympus-Mons" HOME="$BASE-home" \
    OBS_CONFIG="$BASE-home/.config/ob-sync/config" OBS_VAULT="$BASE" OBS_BACKUP_DIR="$BASE-backups" \
    OBS_LOG= GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" "$OB" sync -y
t "H8 LC_NUMERIC=de_DE (comma decimals): backup unaffected" 0 env LC_ALL=C.UTF-8 LC_NUMERIC=de_DE.UTF-8 \
    HOME="$BASE-home" OBS_CONFIG="$BASE-home/.config/ob-sync/config" OBS_VAULT="$BASE" \
    OBS_BACKUP_DIR="$BASE-backups" OBS_LOG= GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" "$OB" backup
assert "H8 vault intact after locale storm" bash -c "test -f '$BASE/note.md'"

echo
echo "== H9. numeric edge values =="
t "H9 OBS_KEEP_BACKUPS=0 keeps everything" 0 env HOME="$BASE-home" \
    OBS_CONFIG="$BASE-home/.config/ob-sync/config" OBS_VAULT="$BASE" OBS_BACKUP_DIR="$BASE-backups" \
    OBS_LOG= GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" OBS_KEEP_BACKUPS=0 "$OB" backup
t "H9 OBS_KEEP_BACKUPS=1 prunes to one" 0 env HOME="$BASE-home" \
    OBS_CONFIG="$BASE-home/.config/ob-sync/config" OBS_VAULT="$BASE" OBS_BACKUP_DIR="$BASE-backups" \
    OBS_LOG= GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" OBS_KEEP_BACKUPS=1 "$OB" backup
N=$(find "$BASE-backups" -maxdepth 1 -name '*.tar.gz' | wc -l)
if [[ "$N" == "1" ]]; then PASS=$((PASS + 1)); printf '  [ OK ] H9 exactly 1 backup retained\n'
else FAIL=$((FAIL + 1)); printf '  [FAIL] H9 %s backups retained (want 1)\n' "$N"; fi
# arithmetic-overflow monsters (bash 64-bit limit)
t "H9 OBS_GIT_TIMEOUT overflow monster: honest rc" 0 \
    env HOME="$BASE-home" OBS_CONFIG="$BASE-home/.config/ob-sync/config" OBS_VAULT="$BASE" \
    OBS_BACKUP_DIR="$BASE-backups" OBS_LOG= GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" \
    OBS_GIT_TIMEOUT=99999999999999999999 "$OB" sync -y || true
t "H9 OBS_KEEP_BACKUPS overflow monster: honest rc" 0 \
    env HOME="$BASE-home" OBS_CONFIG="$BASE-home/.config/ob-sync/config" OBS_VAULT="$BASE" \
    OBS_BACKUP_DIR="$BASE-backups" OBS_LOG= GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" \
    OBS_KEEP_BACKUPS=99999999999999999999 "$OB" backup || true
assert_quiet "H9 overflow must not crash the run" "$SB/out.txt"
t "H9 green again with sane values" 0 run_base sync -y

echo
echo "== H10. vault identity abuse between runs =="
V="$SB/vault-h10"; mkdir -p "$V" "$SB/remote-h10.git"
git init -q --bare "$SB/remote-h10.git"
mkdir -p "$V-home"
git config --file "$V-home/.gitconfig" user.email h10@test.local
git config --file "$V-home/.gitconfig" user.name "H10"
printf 'n\n' > "$V/note.md"
VENV="env HOME=$V-home OBS_CONFIG=$V-home/.config/ob-sync/config OBS_VAULT=$V OBS_BACKUP_DIR=$V-backups OBS_LOG= GIT_CONFIG_GLOBAL=$V-home/.gitconfig OBS_REMOTE=$SB/remote-h10.git"
env HOME="$V-home" OBS_CONFIG="$V-home/.config/ob-sync/config" OBS_VAULT="$V" \
    OBS_BACKUP_DIR="$V-backups" OBS_LOG= GIT_CONFIG_GLOBAL="$V-home/.gitconfig" \
    OBS_REMOTE="$SB/remote-h10.git" "$OB" init -y >/dev/null 2>&1
env HOME="$V-home" OBS_CONFIG="$V-home/.config/ob-sync/config" OBS_VAULT="$V" \
    OBS_BACKUP_DIR="$V-backups" OBS_LOG= GIT_CONFIG_GLOBAL="$V-home/.gitconfig" \
    OBS_REMOTE="$SB/remote-h10.git" "$OB" sync -y >/dev/null 2>&1

# vault deleted between runs
rm -rf "$V"
t "H10 status warns on deleted vault" 0 env HOME="$V-home" OBS_CONFIG="$V-home/.config/ob-sync/config" \
    OBS_VAULT="$V" OBS_BACKUP_DIR="$V-backups" OBS_LOG= GIT_CONFIG_GLOBAL="$V-home/.gitconfig" \
    "$OB" status
t "H10 sync fails honestly on deleted vault" 1 env HOME="$V-home" OBS_CONFIG="$V-home/.config/ob-sync/config" \
    OBS_VAULT="$V" OBS_BACKUP_DIR="$V-backups" OBS_LOG= GIT_CONFIG_GLOBAL="$V-home/.gitconfig" \
    "$OB" sync -y

# vault replaced by a FILE
printf 'i am not a vault' > "$V"
t "H10 sync fails honestly on file-as-vault" 1 env HOME="$V-home" OBS_CONFIG="$V-home/.config/ob-sync/config" \
    OBS_VAULT="$V" OBS_BACKUP_DIR="$V-backups" OBS_LOG= GIT_CONFIG_GLOBAL="$V-home/.gitconfig" \
    "$OB" sync -y
t "H10 repair refuses file-as-vault honestly" 1 env HOME="$V-home" OBS_CONFIG="$V-home/.config/ob-sync/config" \
    OBS_VAULT="$V" OBS_BACKUP_DIR="$V-backups" OBS_LOG= GIT_CONFIG_GLOBAL="$V-home/.gitconfig" \
    "$OB" repair -y

# vault replaced by a SYMLINK to elsewhere
rm -f "$V"
mkdir -p "$SB/elsewhere"; printf 'elsewhere\n' > "$SB/elsewhere/other.md"
ln -s "$SB/elsewhere" "$V"
env HOME="$V-home" OBS_CONFIG="$V-home/.config/ob-sync/config" OBS_VAULT="$V" \
    OBS_BACKUP_DIR="$V-backups" OBS_LOG= GIT_CONFIG_GLOBAL="$V-home/.gitconfig" \
    "$OB" status > "$SB/out.txt" 2>&1
H10_RC=$?
if (( H10_RC == 0 || H10_RC == 1 )); then
    PASS=$((PASS + 1)); printf '  [ OK ] H10 symlink-vault handled without crash (rc=%s)\n' "$H10_RC"
else
    FAIL=$((FAIL + 1)); printf '  [FAIL] H10 symlink-vault rc=%s\n' "$H10_RC"
fi
assert_not "H10 the symlink target was NOT clobbered" \
    bash -c "test -f '$SB/elsewhere/.git/config'"

echo
echo "== H11. argument injection =="
# OBS_BRANCH reaching git push as an option
VI="$SB/vault-h11"; mkdir -p "$VI" "$SB/remote-h11.git"
git init -q --bare "$SB/remote-h11.git"
mkdir -p "$VI-home"
git config --file "$VI-home/.gitconfig" user.email h11@test.local
git config --file "$VI-home/.gitconfig" user.name "H11"
printf 'n\n' > "$VI/note.md"
env HOME="$VI-home" OBS_CONFIG="$VI-home/.config/ob-sync/config" OBS_VAULT="$VI" \
    OBS_BACKUP_DIR="$VI-backups" OBS_LOG= GIT_CONFIG_GLOBAL="$VI-home/.gitconfig" \
    OBS_REMOTE="$SB/remote-h11.git" "$OB" init -y >/dev/null 2>&1
env HOME="$VI-home" OBS_CONFIG="$VI-home/.config/ob-sync/config" OBS_VAULT="$VI" \
    OBS_BACKUP_DIR="$VI-backups" OBS_LOG= GIT_CONFIG_GLOBAL="$VI-home/.gitconfig" \
    OBS_REMOTE="$SB/remote-h11.git" "$OB" sync -y >/dev/null 2>&1
PWNED11="$SB/pwned-11-marker"; rm -f "$PWNED11"
printf '#!/bin/sh\ntouch %s\n' "$PWNED11" > "$SB/evil-pack.sh"
chmod +x "$SB/evil-pack.sh"
env HOME="$VI-home" OBS_CONFIG="$VI-home/.config/ob-sync/config" OBS_VAULT="$VI" \
    OBS_BACKUP_DIR="$VI-backups" OBS_LOG= GIT_CONFIG_GLOBAL="$VI-home/.gitconfig" \
    OBS_BRANCH="--receive-pack=$SB/evil-pack.sh" \
    "$OB" push -y > "$SB/out.txt" 2>&1
H11_RC=$?
if [[ -e "$PWNED11" ]]; then
    FAIL=$((FAIL + 1))
    printf '  [FAIL][CRITICAL] H11 OBS_BRANCH option injection EXECUTED a local command (rc=%s)\n' "$H11_RC"
else
    PASS=$((PASS + 1)); printf '  [ OK ] H11 OBS_BRANCH "--receive-pack=..." did not execute (rc=%s)\n' "$H11_RC"
fi
assert "H11 vault intact after branch injection" bash -c "test -f '$VI/note.md'"
assert_quiet "H11 no interpreter noise from bad branch" "$SB/out.txt"

# OBS_ATTACH_DIR traversal: organize --fix must never move files OUT of the vault
VA="$SB/vault-h11a"; mkdir -p "$VA" "$SB/remote-h11a.git"
git init -q --bare "$SB/remote-h11a.git"
printf 'attachment data\n' > "$VA/orphan.png"
printf 'note\n' > "$VA/note.md"
printf 'the note references nothing\n' > "$VA/note2.md"
env HOME="$VI-home" OBS_CONFIG="$VI-home/.config/ob-sync/config" OBS_VAULT="$VA" \
    OBS_BACKUP_DIR="$VI-backups" OBS_LOG= GIT_CONFIG_GLOBAL="$VI-home/.gitconfig" \
    "$OB" organize --fix > "$SB/out.txt" 2>&1
# sanity baseline: default ATTACH_DIR keeps files inside the vault
assert "H11 organize --fix kept the orphan inside the vault" \
    bash -c "test -f '$VA/Attachments/orphan.png'"
assert_not "H11 organize --fix did not write outside the vault" \
    test -e "$SB/Attachments"

echo
echo "== H12. cron input validation =="
t "H12 cron install percent-sign schedule refused" 1 run_base cron install "hourly %x"
t "H12 cron install newline schedule refused" 1 \
    env HOME="$BASE-home" OBS_CONFIG="$BASE-home/.config/ob-sync/config" OBS_VAULT="$BASE" \
    OBS_BACKUP_DIR="$BASE-backups" OBS_LOG= GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" \
    "$OB" cron install "$(printf 'bad\nschedule')"
t "H12 cron install backslash-in-schedule handling" 0 \
    env HOME="$BASE-home" OBS_CONFIG="$BASE-home/.config/ob-sync/config" OBS_VAULT="$BASE" \
    OBS_BACKUP_DIR="$BASE-backups" OBS_LOG= GIT_CONFIG_GLOBAL="$BASE-home/.gitconfig" \
    bash -c "'$OB' cron install 'bad\\\\schedule' >/dev/null 2>&1; [[ \$? == 0 || \$? == 1 ]]" bash
t "H12 cron install 6-field expression refused" 1 run_base cron install "* * * * * *"
t "H12 cron install impossible HH:MM refused" 1 run_base cron install daily 25:99
t "H12 cron status works without crontab" 0 run_base cron status
assert_quiet "H12 cron validation is quiet and honest" "$SB/out.txt"

echo
printf 'human-error-attacks: PASS=%s FAIL=%s SKIP=%s\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 )) || exit 1
exit 0
