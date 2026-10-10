#!/usr/bin/env bash
#
# ─────────────────────────────────────────────────────────────────────────────
#   ob-sync USER-ERROR resilience tests
#
#   The main suite (run-tests.sh) proves the designed paths. THIS suite
#   attacks the tool the way real users do: hand-edited config files with
#   Windows CRLF endings, values wrapped in quotes, garbage prose pasted
#   into the config, mistyped remote URLs, config paths pointing at
#   directories, deleted vault folders, .ob-sync replaced by a file,
#   double launches. Field experience (9.4.1/9.4.2) says this is where
#   the actual pain comes from.
#
#   The contract under user error:
#     · vault data is never corrupted and never lost,
#     · ob-sync never invents or borrows a remote that belongs to
#       another vault,
#     · every run either succeeds transparently, self-heals from a
#       value that is still correct, or fails HONESTLY with an
#       actionable message — never a hang, never raw bash noise.
#
#   Self-contained like run-tests.sh: throwaway sandbox, no network,
#   no root required, no side effects on the host. Run BOTH suites
#   before every release:
#       bash tests/run-tests.sh && bash tests/user-error-tests.sh
# ─────────────────────────────────────────────────────────────────────────────

set -u

# Hermetic stdin: a hand-run apply script must not be able to feed its
# terminal to ob-sync's [[ -t 0 ]] paths (pickers, consent prompts) while
# the suite is watching — see the longer note in run-tests.sh.
exec 0</dev/null

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
OB="$ROOT/bin/ob-sync"

SB="$(mktemp -d "${TMPDIR:-/tmp}/ob-sync-ue-tests-XXXXXX")" \
    || { echo "FATAL: cannot create the sandbox directory"; exit 1; }
trap 'rm -rf -- "$SB"' EXIT

PASS=0
FAIL=0

# ── assertions ───────────────────────────────────────────────────────────────
CAP="$SB/cap.txt"

run() {  # run <name> <expected-rc> <command...> — captures output for expect_out
    local name="$1" want="$2"; shift 2
    "$@" >"$CAP" 2>&1
    local got=$?
    if [[ "$got" == "$want" ]]; then
        PASS=$((PASS + 1)); printf '  [ OK ] %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); printf '  [FAIL] %s (want rc=%s got rc=%s)\n' "$name" "$want" "$got"
        tail -6 "$CAP" | sed 's/^/         /'
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
expect_out() {  # expect_out <name> <ERE> — greps the LAST captured output
    local name="$1"
    if grep -qE "$2" "$CAP" 2>/dev/null; then
        PASS=$((PASS + 1)); printf '  [ OK ] %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); printf '  [FAIL] %s (pattern not found)\n' "$name"
        tail -8 "$CAP" | sed 's/^/         /'
    fi
}
expect_no_out() {  # expect_no_out <name> <ERE> — pattern must NOT appear
    local name="$1"
    if ! grep -qE "$2" "$CAP" 2>/dev/null; then
        PASS=$((PASS + 1)); printf '  [ OK ] %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); printf '  [FAIL] %s (unwanted pattern found)\n' "$name"
        grep -E "$2" "$CAP" | head -3 | sed 's/^/         /'
    fi
}

# ── sandbox environment ──────────────────────────────────────────────────────
chmod +x "$OB"
mkdir -p "$SB/home" "$SB/tmp"
export HOME="$SB/home"
export TMPDIR="$SB/tmp"
unset XDG_CONFIG_HOME
export GIT_CONFIG_GLOBAL="$SB/home/.gitconfig"
export OBS_BACKUP_DIR="$SB/backups"
export OBS_LOG="$SB/ob.log"
export OBS_GIT_TIMEOUT=30
# Host-vault firewall — same as run-tests.sh (9.5.2 field report #2):
# scenarios that resolve the vault with no pin (A1/A5/A6) must never
# auto-detect a REAL vault living under /media on the host machine.
# Where discovery itself is the subject, the scenario re-points this
# override at its own fixtures (C5/C6/C7).
mkdir -p "$SB/discover-roots"
export OB_DISCOVER_ROOTS="$SB/discover-roots"
# Self-update firewall (9.6.0) — same reasoning as run-tests.sh: the
# suite never touches the network, so the launch-time update check is
# switched off for every scenario below.
export OB_NO_SELFUPDATE=1
# NOTE: OBS_CONFIG / OBS_VAULT / OBS_REMOTE are deliberately NOT exported —
# every scenario below passes its own broken values, exactly like a user
# would. Nothing may leak between scenarios.
LOCKDIR="$SB/tmp/obs-sync.lock"

git config --global user.email test@example.com
git config --global user.name "Test User"
git config --global init.defaultBranch main

bash -n "$OB" || { echo "FATAL: bin/ob-sync has a syntax error"; exit 1; }

echo "== UE-A. machine config file (~/.config/ob-sync/config) under user error =="

# A1 — garbage prose instead of KEY=VALUE lines: the tool must shrug it
# off (unknown lines are ignored by the parser) and never leak bash noise.
printf 'this is not a config\njust some notes REMOTE= oops\n###\n' > "$SB/cfg-garbage"
run "A1 status tolerates garbage config" 0 \
    env OBS_CONFIG="$SB/cfg-garbage" "$OB" status
expect_no_out "A1 no bash parser noise" "read error|unbound|syntax error"

# A2 — CRLF endings (the config was edited on Windows/Android): values
# must parse clean, so the stored remote still works verbatim.
git init -q --bare "$SB/ueA2.git"
mkdir -p "$SB/ueA2-vault"
printf '# crlf config vault\n' > "$SB/ueA2-vault/note.md"
git -C "$SB/ueA2-vault" init -q
git -C "$SB/ueA2-vault" add -A
git -C "$SB/ueA2-vault" commit -qm "crlf config fixture"
printf 'VAULT=%s\r\nREMOTE=%s\r\nBRANCH=main\r\n' "$SB/ueA2-vault" "$SB/ueA2.git" > "$SB/cfg-crlf"
run "A2 sync works with CRLF machine config" 0 \
    env OBS_CONFIG="$SB/cfg-crlf" OBS_VAULT= "$OB" sync -y
assert "A2 origin parsed clean (no CR)" \
    bash -c "[[ \"\$(git -C '$SB/ueA2-vault' remote get-url origin 2>/dev/null)\" == '$SB/ueA2.git' ]]"
assert "A2 the CRLF-configured remote received the vault" \
    bash -c "git -C '$SB/ueA2.git' ls-tree -r --name-only refs/heads/main 2>/dev/null | grep -qF 'note.md'"

# A3 — values wrapped in quotes (copy-paste from a tutorial):
git init -q --bare "$SB/ueA3.git"
mkdir -p "$SB/ueA3-vault"
printf '# quoted config vault\n' > "$SB/ueA3-vault/note.md"
git -C "$SB/ueA3-vault" init -q
git -C "$SB/ueA3-vault" add -A
git -C "$SB/ueA3-vault" commit -qm "quoted config fixture"
printf 'VAULT=%s\nREMOTE="%s"\nBRANCH=main\n' "$SB/ueA3-vault" "$SB/ueA3.git" > "$SB/cfg-quoted"
run "A3 sync works with quoted config values" 0 \
    env OBS_CONFIG="$SB/cfg-quoted" OBS_VAULT= "$OB" sync -y
assert "A3 origin parsed without quotes" \
    bash -c "[[ \"\$(git -C '$SB/ueA3-vault' remote get-url origin 2>/dev/null)\" == '$SB/ueA3.git' ]]"

# A4 — duplicate keys: the FIRST occurrence wins, deterministically.
git init -q --bare "$SB/ueA4a.git"
git init -q --bare "$SB/ueA4b.git"
mkdir -p "$SB/ueA4-vault"
printf '# dup config vault\n' > "$SB/ueA4-vault/note.md"
git -C "$SB/ueA4-vault" init -q
git -C "$SB/ueA4-vault" add -A
git -C "$SB/ueA4-vault" commit -qm "dup config fixture"
printf 'VAULT=%s\nREMOTE=%s\nREMOTE=%s\n' "$SB/ueA4-vault" "$SB/ueA4a.git" "$SB/ueA4b.git" > "$SB/cfg-dup"
run "A4 sync works with duplicate keys" 0 \
    env OBS_CONFIG="$SB/cfg-dup" OBS_VAULT= "$OB" sync -y
assert "A4 first key wins" \
    bash -c "git -C '$SB/ueA4a.git' ls-tree -r --name-only refs/heads/main 2>/dev/null | grep -qF 'note.md'"
assert "A4 second key never used" \
    bash -c "! git -C '$SB/ueA4b.git' rev-parse refs/heads/main >/dev/null 2>&1"

# A5/A6 — empty or missing config: the tool runs as if unconfigured.
: > "$SB/cfg-empty"
run "A5 status tolerates empty config" 0 env OBS_CONFIG="$SB/cfg-empty" "$OB" status
run "A6 status tolerates missing config" 0 env OBS_CONFIG="$SB/cfg-absent" "$OB" status

# A7 — OBS_CONFIG pointing at a DIRECTORY (a mkdir typo): status must not
# spew raw "read error: Is a directory" bash noise.
mkdir -p "$SB/cfg-is-a-dir"
run "A7 status tolerates config-that-is-a-directory" 0 \
    env OBS_CONFIG="$SB/cfg-is-a-dir" "$OB" status
expect_no_out "A7 no raw 'Is a directory' noise" "read error|Is a directory"

# A8 — config VAULT points at a deleted folder: warn + fall through to
# normal resolution, never a crash.
printf 'VAULT=%s\n' "$SB/vanished-vault" > "$SB/cfg-gone"
run "A8 status warns about the vanished vault" 0 \
    env OBS_CONFIG="$SB/cfg-gone" "$OB" status
expect_out "A8 the warning is actionable" "no longer exists"

echo "== UE-B. vault identity card (<vault>/.ob-sync/config) under user error =="

# B1 — card edited with CRLF endings, origin intact: the clean parse must
# keep origin untouched and the run green.
git init -q --bare "$SB/ueB1.git"
mkdir -p "$SB/ueB1-vault"
printf '# b1\n' > "$SB/ueB1-vault/note.md"
env OBS_REMOTE="$SB/ueB1.git" OBS_VAULT="$SB/ueB1-vault" "$OB" init -y >/dev/null 2>&1
sed -i 's/$/\r/' "$SB/ueB1-vault/.ob-sync/config"
run "B1 sync survives a CRLF identity card" 0 \
    env OBS_VAULT="$SB/ueB1-vault" "$OB" sync -y
assert "B1 origin stays clean" \
    bash -c "[[ \"\$(git -C '$SB/ueB1-vault' remote get-url origin 2>/dev/null)\" == '$SB/ueB1.git' ]]"

# B2 — the STUCK state: origin itself was already corrupted by the old
# CRLF bug. The card (parsed clean now) must heal origin back.
git -C "$SB/ueB1-vault" remote set-url origin "$(printf '%s\r' "$SB/ueB1.git")"
run "B2 sync heals a CR-corrupted origin from the card" 0 \
    env OBS_VAULT="$SB/ueB1-vault" "$OB" sync -y
assert "B2 origin healed clean" \
    bash -c "[[ \"\$(git -C '$SB/ueB1-vault' remote get-url origin 2>/dev/null)\" == '$SB/ueB1.git' ]]"

# B3 — quoted REMOTE in the card: parsed clean, origin aligned.
git init -q --bare "$SB/ueB3.git"
mkdir -p "$SB/ueB3-vault"
printf '# b3\n' > "$SB/ueB3-vault/note.md"
env OBS_REMOTE="$SB/ueB3.git" OBS_VAULT="$SB/ueB3-vault" "$OB" init -y >/dev/null 2>&1
printf 'REMOTE="%s"\nBRANCH=main\n' "$SB/ueB3.git" > "$SB/ueB3-vault/.ob-sync/config"
run "B3 sync survives a quoted identity card" 0 \
    env OBS_VAULT="$SB/ueB3-vault" "$OB" sync -y
assert "B3 origin parsed without quotes" \
    bash -c "[[ \"\$(git -C '$SB/ueB3-vault' remote get-url origin 2>/dev/null)\" == '$SB/ueB3.git' ]]"

# B4 — card reduced to garbage (no REMOTE= at all): the vault's own
# origin still resolves, and the first locked run rewrites a valid card.
git init -q --bare "$SB/ueB4.git"
mkdir -p "$SB/ueB4-vault"
printf '# b4\n' > "$SB/ueB4-vault/note.md"
env OBS_REMOTE="$SB/ueB4.git" OBS_VAULT="$SB/ueB4-vault" "$OB" init -y >/dev/null 2>&1
printf 'i deleted the keys here\nrandom text\n' > "$SB/ueB4-vault/.ob-sync/config"
run "B4 sync survives a garbage identity card" 0 \
    env OBS_VAULT="$SB/ueB4-vault" "$OB" sync -y
assert "B4 card rewritten with the real remote" \
    bash -c "grep -F 'REMOTE=$SB/ueB4.git' '$SB/ueB4-vault/.ob-sync/config'"

# B5 — card truncated to an empty file: same self-heal.
: > "$SB/ueB4-vault/.ob-sync/config"
run "B5 sync survives an empty identity card" 0 \
    env OBS_VAULT="$SB/ueB4-vault" "$OB" sync -y
assert "B5 empty card rewritten" \
    bash -c "grep -F 'REMOTE=$SB/ueB4.git' '$SB/ueB4-vault/.ob-sync/config'"

# B6 — extra unknown keys in the card: tolerated, never a parse failure.
printf 'REMOTE=%s\nBRANCH=main\nNOTE=i like this vault\n' "$SB/ueB4.git" > "$SB/ueB4-vault/.ob-sync/config"
run "B6 sync tolerates unknown card keys" 0 \
    env OBS_VAULT="$SB/ueB4-vault" "$OB" sync -y

# B7 — .ob-sync replaced by a FILE: best-effort warn, sync continues.
git init -q --bare "$SB/ueB7.git"
mkdir -p "$SB/ueB7-vault"
printf '# b7\n' > "$SB/ueB7-vault/note.md"
env OBS_REMOTE="$SB/ueB7.git" OBS_VAULT="$SB/ueB7-vault" "$OB" init -y >/dev/null 2>&1
rm -rf "$SB/ueB7-vault/.ob-sync"
printf 'junk' > "$SB/ueB7-vault/.ob-sync"
run "B7 sync survives .ob-sync-as-a-file" 0 \
    env OBS_VAULT="$SB/ueB7-vault" "$OB" sync -y
expect_out "B7 the skip is announced" "Cannot create .*identity not saved"

# B8 — typo'd remote in the card: FAIL HONESTLY, keep the local commit,
# keep the pre-sync backup, and surface git's own words.
git init -q --bare "$SB/ueB8.git"
mkdir -p "$SB/ueB8-vault"
printf '# b8\n' > "$SB/ueB8-vault/note.md"
env OBS_REMOTE="$SB/ueB8.git" OBS_VAULT="$SB/ueB8-vault" "$OB" init -y >/dev/null 2>&1
sed -i "s#REMOTE=.*#REMOTE=$SB/typo-does-not-exist.git#" "$SB/ueB8-vault/.ob-sync/config"
printf 'more work\n' >> "$SB/ueB8-vault/note.md"
run "B8 sync fails honestly on a typo'd remote" 1 \
    env OBS_VAULT="$SB/ueB8-vault" "$OB" sync -y
expect_out "B8 git's own error is surfaced" "git said|does not appear to be a git repository|fetch_failed"
assert "B8 local work survives the failed push" \
    bash -c "git -C '$SB/ueB8-vault' log -1 --format=%s 2>/dev/null | grep -q ."
assert "B8 pre-sync backup still taken" \
    bash -c "ls '$SB/backups'/pre-sync-*.tar.gz >/dev/null 2>&1"

# B9 — the anti-cross-vault guarantee: a user hand-edits 'origin' to a
# FOREIGN repo, but the card still points home. The card travels with
# the vault and expresses the vault's intent — the foreign repo must
# receive NOTHING.
git init -q --bare "$SB/ueB9-mine.git"
git init -q --bare "$SB/ueB9-foreign.git"
mkdir -p "$SB/ueB9-vault"
printf '# b9\n' > "$SB/ueB9-vault/note.md"
env OBS_REMOTE="$SB/ueB9-mine.git" OBS_VAULT="$SB/ueB9-vault" "$OB" init -y >/dev/null 2>&1
git -C "$SB/ueB9-vault" remote set-url origin "$SB/ueB9-foreign.git"
run "B9 sync follows the card, not the hijacked origin" 0 \
    env OBS_VAULT="$SB/ueB9-vault" "$OB" sync -y
assert "B9 origin re-aligned to the card" \
    bash -c "[[ \"\$(git -C '$SB/ueB9-vault' remote get-url origin 2>/dev/null)\" == '$SB/ueB9-mine.git' ]]"
assert "B9 the foreign repo stayed EMPTY" \
    bash -c "! git -C '$SB/ueB9-foreign.git' rev-parse refs/heads/main >/dev/null 2>&1"
assert "B9 the real repo received the vault" \
    bash -c "git -C '$SB/ueB9-mine.git' ls-tree -r --name-only refs/heads/main 2>/dev/null | grep -qF 'note.md'"

# B10 — card says BRANCH=main, vault is checked out on master: the
# CURRENT branch outranks the card; the push lands on master.
git init -q --bare "$SB/ueB10.git"
mkdir -p "$SB/ueB10-vault"
printf '# b10\n' > "$SB/ueB10-vault/note.md"
git -C "$SB/ueB10-vault" init -q -b master
git -C "$SB/ueB10-vault" add -A
git -C "$SB/ueB10-vault" commit -qm "master fixture"
git -C "$SB/ueB10-vault" remote add origin "$SB/ueB10.git"
mkdir -p "$SB/ueB10-vault/.ob-sync"
printf 'REMOTE=%s\nBRANCH=main\n' "$SB/ueB10.git" > "$SB/ueB10-vault/.ob-sync/config"
run "B10 sync respects the checked-out branch" 0 \
    env OBS_VAULT="$SB/ueB10-vault" "$OB" sync -y
assert "B10 pushed to the current branch (master)" \
    bash -c "git -C '$SB/ueB10.git' ls-tree -r --name-only refs/heads/master 2>/dev/null | grep -qF 'note.md'"

# B11 — card present but .git deleted: no fake repo is conjured; the
# tool refuses honestly, names the real problem, and points at repair
# (which CAN rebuild from the card) — never a misleading "unsafe state".
mkdir -p "$SB/ueB11-vault"
printf '# b11\n' > "$SB/ueB11-vault/note.md"
mkdir -p "$SB/ueB11-vault/.ob-sync"
printf 'REMOTE=%s\nBRANCH=main\n' "$SB/ueB10.git" > "$SB/ueB11-vault/.ob-sync/config"
run "B11 quick refuses without .git even with a card" 1 \
    env OBS_VAULT="$SB/ueB11-vault" "$OB" quick -y
expect_out "B11 the diagnosis is honest (no git repository)" "No git repository found"
expect_out "B11 the remedy points at repair/init" "ob-sync repair|ob-sync init"
assert "B11 no .git conjured by quick" bash -c "! test -e '$SB/ueB11-vault/.git'"
assert "B11 the note survives untouched" test -f "$SB/ueB11-vault/note.md"

# B12 — the full self-heal story: the user deleted .git, and repair
# rebuilds the repository from the vault's OWN identity card.
git init -q --bare "$SB/ueB12.git"
mkdir -p "$SB/ueB12-vault"
printf '# b12\n' > "$SB/ueB12-vault/note.md"
env OBS_REMOTE="$SB/ueB12.git" OBS_VAULT="$SB/ueB12-vault" "$OB" init -y >/dev/null 2>&1
env OBS_VAULT="$SB/ueB12-vault" "$OB" sync -y >/dev/null 2>&1
rm -rf "$SB/ueB12-vault/.git"
run "B12 repair rebuilds .git from the identity card" 0 \
    env OBS_VAULT="$SB/ueB12-vault" "$OB" repair -y
assert "B12 origin restored from the card" \
    bash -c "[[ \"\$(git -C '$SB/ueB12-vault' remote get-url origin 2>/dev/null)\" == '$SB/ueB12.git' ]]"
run "B12 sync is green again after the rebuild" 0 \
    env OBS_VAULT="$SB/ueB12-vault" "$OB" sync -y
assert "B12 the note still exists" test -f "$SB/ueB12-vault/note.md"
assert "B12 the remote still holds the vault" \
    bash -c "git -C '$SB/ueB12.git' ls-tree -r --name-only refs/heads/main 2>/dev/null | grep -qF 'note.md'"

echo "== UE-C. environment & concurrency under user error =="

# C1 — OBS_VAULT points nowhere: warn + degrade, never crash.
run "C1 status warns on a nonexistent OBS_VAULT" 0 \
    env OBS_CONFIG="$SB/cfg-absent" OBS_VAULT="$SB/no-such-vault" "$OB" status
expect_out "C1 the warning names the path" "does not exist"

# C2 — sync against a nonexistent vault: honest failure, no bash noise.
run "C2 sync fails honestly on a nonexistent vault" 1 \
    env OBS_CONFIG="$SB/cfg-absent" OBS_VAULT="$SB/no-such-vault" "$OB" sync -y
expect_no_out "C2 no unbound-variable/syntax noise" "unbound variable|syntax error"

# C3 — double launch: a live PID in the lock makes the second run stand
# down; the JSON contract still answers (parseable, lock_busy).
mkdir -p "$LOCKDIR"
printf '%s\n' "$$" > "$LOCKDIR/pid"
run "C3 second instance stands down" 2 \
    env OBS_CONFIG="$SB/cfg-absent" OBS_VAULT="$SB/ueB1-vault" "$OB" sync --json
expect_out "C3 JSON reports lock_busy" "lock_busy"
rm -rf "$LOCKDIR"

# C4 — no OBS_CONFIG at all (user deleted ~/.config/ob-sync): default
# path is derived, status still answers.
run "C4 status works with the config file deleted" 0 \
    env -u OBS_CONFIG "$OB" status

# C5 — discovery override with only garbage roots: no candidates, the
# tool falls back to the default vault path and degrades honestly
# (never a crash, never an invented vault, never bash noise).
run "C5 garbage OB_DISCOVER_ROOTS degrade honestly" 0 \
    env -u OBS_VAULT OBS_CONFIG="$SB/cfg-absent" \
        OB_DISCOVER_ROOTS="/no/such/root::/also/absent" "$OB" status
expect_no_out "C5 no unbound-variable/syntax noise" "unbound variable|syntax error"

# C6 — an override root that is a FILE (not a directory) is skipped.
run "C6 file-valued roots are skipped silently" 0 \
    env -u OBS_VAULT OBS_CONFIG="$SB/cfg-absent" \
        OB_DISCOVER_ROOTS="$SB/ob.log" "$OB" status

# C7 — a real vault under the override root is found and named, and it
# still starts remote-less (no invented remote, ever).
mkdir -p "$SB/ueC7-root/Obsidian/c7/.obsidian"
printf '# c7\n' > "$SB/ueC7-root/Obsidian/c7/note.md"
run "C7 vault on an override root is found" 0 \
    env -u OBS_VAULT OBS_CONFIG="$SB/cfg-absent" \
        OB_DISCOVER_ROOTS="$SB/ueC7-root" "$OB" status
expect_out "C7 the vault is reported as auto-detected" \
    "Auto-detected vault: $SB/ueC7-root/Obsidian/c7"

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
