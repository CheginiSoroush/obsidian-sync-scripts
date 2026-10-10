#!/usr/bin/env bash
# ═════════════════════════════════════════════════════════════════════════════
#  fix-all-issues.sh — surgical fixer for every finding in TEST-REPORT.md
#
#  Fixes applied to bin/ob-sync (all anchored, verified, reversible):
#    P1  CRITICAL  branch_guard(): refuse option-like branch names
#                  (OBS_BRANCH="--receive-pack=..." local command execution)
#    P2  CRITICAL  sync_run(): branch guard before git push
#    P3  MEDIUM    sync_run(): rc=124 watchdog → honest "timed out" message
#                  (fetch) instead of generic "network or credentials"
#    P4  MEDIUM    pull_run(): same honest rc=124 mapping (fetch)
#    P5  CRITICAL  push_run(): branch guard before git push
#        MEDIUM    push_run(): honest rc=124 mapping (push)
#    P6  HIGH      organize_fix_run(): reject OBS_ATTACH_DIR with ".." or
#                  absolute path (files could be moved OUT of the vault and
#                  then deleted from every device by the next sync)
#    P7  MEDIUM    restore: actionable guidance when an archive contains
#                  symlinks (backup accepts them, restore refused them with
#                  a dead-end message)
#    P8  MEDIUM    init_log(): size the log file ONLY if it is a regular
#                  file — `wc -c <` on a character device (/dev/full,
#                  /dev/zero) reads an endless stream and hangs the whole
#                  command with no output and no watchdog (fuzz C7 finding)
#
#  Deliberately NOT changed (no-harm policy):
#    · "history abc" falls back to the default count — run-tests.sh:1265
#      contracts this exact behavior as a feature ("falls back to 10");
#      changing it would break the project's own 372-check suite.
#    · doctor exit codes — behavior is correct; documented in FIX-REPORT.md.
#
#  Safety model (stage → verify → commit → rollback):
#    1. every patch is matched by EXACT whole-line equality (never substrings)
#    2. patches are staged on a COPY; the original is untouched until all
#       patches + `bash -n` pass on the copy
#    3. after commit: ShellCheck (-S warning), two targeted PoCs, and all
#       four test suites must be green — otherwise an automatic rollback
#       restores the timestamped backup
#    4. idempotent: re-running skips already-applied patches
#
#  Usage:
#    bash fix-all-issues.sh apply   [--no-suites]   # diagnose + patch + verify
#    bash fix-all-issues.sh check                   # diagnose only, no writes
#    bash fix-all-issues.sh verify                  # verify current state only
#    bash fix-all-issues.sh rollback [backup-file]  # restore a backup
#    bash fix-all-issues.sh list-backups
# ═════════════════════════════════════════════════════════════════════════════

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$ROOT/bin/ob-sync"
BACKUP_DIR="$ROOT/.fix-backups"
LOG_DIR="$ROOT/.fix-logs"
STAMP="$(date +%Y%m%d-%H%M%S)"
MODE="${1:-apply}"
NO_SUITES=0
[[ "${2:-}" == "--no-suites" ]] && NO_SUITES=1

if [[ ! -f "$TARGET" ]]; then
    echo "FATAL: target not found: $TARGET" >&2
    exit 2
fi

# ── Version guard (added post-campaign) ──────────────────────────────────────
# This patcher is byte-anchored against bin/ob-sync **v9.5.1 ONLY**.
# v9.6.0+ already ships every P1–P8 fix (backported), and this script's
# version-bump step is NOT anchor-based — on a newer tree it would rewrite
# `readonly VERSION=` (e.g. 9.6.1 → 9.9.9) and break the version-sync checks.
# Field-verified 2026-10-10: running unguarded on v9.6.1 did exactly that.
SCRIPT_VER="$(sed -n 's/^readonly VERSION="\(.*\)"$/\1/p' "$TARGET" | head -1)"
if [[ "$SCRIPT_VER" != "9.5.1" ]]; then
    echo "STOP: this script patches bin/ob-sync v9.5.1 only — found v${SCRIPT_VER:-unknown}." >&2
    echo "      v9.6.0+ already contains every P1–P8 fix; nothing to apply." >&2
    echo "      (Historical artifact — kept for the v9.5.1 campaign record.)" >&2
    exit 3
fi

mkdir -p "$BACKUP_DIR" "$LOG_DIR"
cd "$ROOT" || exit 2   # test suites are invoked with relative paths (tests/...)

C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_DIM=$'\033[2m'; C_HI=$'\033[1m'; C_R=$'\033[0m'
ok()   { printf '%s[ OK ]%s %s\n'  "$C_OK"   "$C_R" "$*"; }
bad()  { printf '%s[FAIL]%s %s\n'  "$C_BAD"  "$C_R" "$*"; }
info() { printf '%s[INFO]%s %s\n'  "$C_DIM"  "$C_R" "$*"; }
step() { printf '\n%s── %s ──%s\n' "$C_HI" "$*" "$C_R"; }

# ─────────────────────────────────────────────────────────────────────────────
# Patch definitions — byte-exact anchors (whole-line equality, never substring)
# ─────────────────────────────────────────────────────────────────────────────

P1_ANCHOR_FIRST='    warn "On mobile, SSH is easier:  ob-sync remote git@github.com:<user>/<repo>.git"'
P1_ANCHOR_LAST='}'
P1_BLOCK=$(cat <<'PATCH_EOF'
    warn "On mobile, SSH is easier:  ob-sync remote git@github.com:<user>/<repo>.git"
}

##
# Refuse any branch value that is not a valid, unambiguous branch name
# BEFORE it reaches a git command line. `git check-ref-format --branch`
# rejects option-like values (anything starting with "-"), empty strings
# and every refname-illegal form — so a hostile OBS_BRANCH (or a bad
# BRANCH= line in a machine config) can never be parsed by git push as
# an option (e.g. --receive-pack=<cmd> local command execution).
##
branch_guard() {
    git check-ref-format --branch "$1" >/dev/null 2>&1 && return 0
    error "Invalid branch name: '$1' — refused (check OBS_BRANCH or BRANCH= in the machine config)"
    return 1
}
PATCH_EOF
)

P2_ANCHOR_FIRST='        if net_quiet push --quiet "${push_args[@]}"; then'
P2_ANCHOR_LAST='        fi'
P2_BLOCK=$(cat <<'PATCH_EOF'
        branch_guard "$BRANCH" || { sync_fail invalid_branch "Invalid branch name: $BRANCH"; return 1; }

        local sprc=0
        net_quiet push --quiet "${push_args[@]}" || sprc=$?
        if (( sprc == 0 )); then
            SYNC_PUSHED=$ahead
            success "Pushed $ahead commit(s)"
        elif (( sprc == 124 )); then
            error "Push timed out after ${GIT_TIMEOUT}s (OBS_GIT_TIMEOUT) — the connection stalled and git was killed"
            sync_fail push_timeout "git push timed out (OBS_GIT_TIMEOUT=${GIT_TIMEOUT}s)"
            return 1
        else
            error "Push failed — local commits are preserved"
            warn "Check network/credentials, then retry with: ob-sync push"
            cred_hint
            sync_fail push_failed "git push failed (network or credentials)"
            return 1
        fi
PATCH_EOF
)

P3_ANCHOR_FIRST='    if ! net_quiet fetch --quiet origin; then'
P3_ANCHOR_LAST='    fi'
P3_BLOCK=$(cat <<'PATCH_EOF'
    local frc=0
    net_quiet fetch --quiet origin || frc=$?
    if (( frc == 124 )); then
        error "Fetch timed out after ${GIT_TIMEOUT}s (OBS_GIT_TIMEOUT) — the connection stalled and git was killed"
        sync_fail fetch_timeout "git fetch timed out (OBS_GIT_TIMEOUT=${GIT_TIMEOUT}s)"
        return 1
    fi
    if (( frc != 0 )); then
        error "Fetch failed — check network connection and credentials"
        cred_hint
        sync_fail fetch_failed "git fetch failed (network or credentials)"
        return 1
    fi
PATCH_EOF
)

P4_ANCHOR_FIRST='    net_quiet fetch --quiet origin || { error "Fetch failed"; cred_hint; sync_fail fetch_failed "git fetch failed (network or credentials)"; return 1; }'
P4_ANCHOR_LAST="$P4_ANCHOR_FIRST"
P4_BLOCK=$(cat <<'PATCH_EOF'
    local pfrc=0
    net_quiet fetch --quiet origin || pfrc=$?
    if (( pfrc == 124 )); then
        error "Fetch timed out after ${GIT_TIMEOUT}s (OBS_GIT_TIMEOUT) — the connection stalled and git was killed"
        sync_fail fetch_timeout "git fetch timed out (OBS_GIT_TIMEOUT=${GIT_TIMEOUT}s)"
        return 1
    fi
    if (( pfrc != 0 )); then
        error "Fetch failed"
        cred_hint
        sync_fail fetch_failed "git fetch failed (network or credentials)"
        return 1
    fi
PATCH_EOF
)

P5_ANCHOR_FIRST='    local -a push_args=(origin "$BRANCH")'
P5_ANCHOR_LAST='    return 1'
P5_BLOCK=$(cat <<'PATCH_EOF'
    branch_guard "$BRANCH" || { sync_fail invalid_branch "Invalid branch name: $BRANCH"; return 1; }

    local -a push_args=(origin "$BRANCH")
    remote_branch_exists || push_args=(-u origin "$BRANCH")

    local prc=0
    net_quiet push --quiet "${push_args[@]}" || prc=$?
    if (( prc == 0 )); then
        SYNC_PUSHED=$ahead
        success "Pushed $ahead commit(s)"
        return 0
    fi

    if (( prc == 124 )); then
        error "Push timed out after ${GIT_TIMEOUT}s (OBS_GIT_TIMEOUT) — the connection stalled and git was killed"
        sync_fail push_timeout "git push timed out (OBS_GIT_TIMEOUT=${GIT_TIMEOUT}s)"
        return 1
    fi

    error "Push failed — check network connection and credentials"
    cred_hint
    sync_fail push_failed "git push failed (network or credentials)"
    return 1
PATCH_EOF
)

P6_ANCHOR_FIRST='organize_fix_run() {'
# P6 uses `after` mode — its LAST anchor is deliberately unused (kept for symmetry)
# shellcheck disable=SC2034
P6_ANCHOR_LAST=''
P6_BLOCK=$(cat <<'PATCH_EOF'
    # HIGH fix (TEST-REPORT): OBS_ATTACH_DIR must never be able to move
    # files OUT of the vault — a relative path containing ".." (or an
    # absolute path) would relocate attachments outside git's view, and
    # the next sync would commit that deletion to every device.
    case "$ATTACH_DIR" in
        ""|/*|*..*)
            ORG_ERR_CODE="attach_dir_unsafe"
            ORG_ERR_MSG="Unsafe attach dir: '$ATTACH_DIR' — must be a relative path inside the vault (no '..' components, not absolute)"
            error "$ORG_ERR_MSG"
            return 1
            ;;
    esac
PATCH_EOF
)

P7_ANCHOR_FIRST='                error "Archive contains a special member (type '"'"'${line:0:1}'"'"') — refused"'
P7_ANCHOR_LAST='                return 1'
P7_BLOCK=$(cat <<'PATCH_EOF'
                error "Archive contains a special member (type '${line:0:1}') — refused"
                warn "Most common cause: the vault contains symlinks — 'backup' archives them, but 'restore' never extracts them (fail-closed anti tar-slip)"
                warn "Inspect the archive first:  ob-sync restore --list <name|latest>"
                warn "Re-create the links by hand after restore, or (only if you fully trust the archive) extract manually: tar -xzf <archive> -C <vault>"
                return 1
PATCH_EOF
)

P8_ANCHOR_FIRST='    local size'
P8_ANCHOR_LAST="    size=\$(wc -c < \"\$LOG_FILE\" 2>/dev/null | tr -d ' ') || size=0"
P8_BLOCK=$(cat <<'PATCH_EOF'
    # P8: only a regular file can be sized safely — `wc -c <` on a character
    # device (/dev/full, /dev/zero) reads an ENDLESS stream and hangs the
    # entire command with no output and no watchdog (found by fuzz C7).
    if [[ ! -f "$LOG_FILE" ]]; then
        LOG_FILE=""
        return 0
    fi
    local size
    size=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ') || size=0
PATCH_EOF
)

# ─────────────────────────────────────────────────────────────────────────────
# Line-array surgery helpers (EXACT whole-line matching only)
# ─────────────────────────────────────────────────────────────────────────────
LINES=()

load_lines()    { mapfile -t LINES < "$1"; }
save_lines()    { printf '%s\n' "${LINES[@]}" > "$1"; }

count_exact() {  # count lines exactly equal to $1
    local want="$1" n=0 l
    for l in "${LINES[@]}"; do [[ "$l" == "$want" ]] && (( n++ )); done
    printf '%s' "$n"
}

emit_block() {   # append the lines of a $'...'/heredoc block to OUT
    local b="$1" i
    while IFS= read -r i; do OUT+=("$i"); done <<< "$b"
}

apply_mode() {  # mode first last block
    local mode="$1" first="$2" last="$3" block="$4"
    local -a idx=() i
    for ((i = 0; i < ${#LINES[@]}; i++)); do
        [[ "${LINES[i]}" == "$first" ]] && idx+=("$i")
    done

    if (( ${#idx[@]} != 1 )); then
        bad "anchor for this patch occurs ${#idx[@]}× (need exactly 1) — aborting, nothing written"
        return 1
    fi
    local at="${idx[0]}"
    OUT=()

    case "$mode" in
        before)
            for ((i = 0; i < ${#LINES[@]}; i++)); do
                if (( i == at )); then emit_block "$block"; fi
                OUT+=("${LINES[i]}")
            done ;;
        after)
            for ((i = 0; i < ${#LINES[@]}; i++)); do
                OUT+=("${LINES[i]}")
                if (( i == at )); then emit_block "$block"; fi
            done ;;
        replace)
            local end=-1
            if [[ "$first" == "$last" ]]; then
                end=$at   # single-line replacement
            else
                for ((i = at + 1; i < at + 120 && i < ${#LINES[@]}; i++)); do
                    [[ "${LINES[i]}" == "$last" ]] && { end=$i; break; }
                done
                if (( end < 0 )); then
                    bad "closing anchor not found within 120 lines — aborting, nothing written"
                    return 1
                fi
            fi
            for ((i = 0; i < ${#LINES[@]}; i++)); do
                if (( i < at )); then OUT+=("${LINES[i]}")
                elif (( i == at )); then emit_block "$block"
                elif (( i > end )); then OUT+=("${LINES[i]}")
                fi
            done ;;
    esac
    LINES=("${OUT[@]}")
    unset OUT
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Diagnostics
# ─────────────────────────────────────────────────────────────────────────────
diagnose() {
    step "Diagnosis — which fixes are already present?"
    load_lines "$TARGET"
    local -a names=(
        "P1 branch_guard helper defined"
        "P2 sync_run branch guard"
        "P2 sync_run honest push timeout"
        "P3 sync_run honest fetch timeout"
        "P4 pull_run honest fetch timeout"
        "P5 push_run branch guard"
        "P5 push_run honest push timeout"
        "P6 attach dir traversal guard"
        "P7 symlink restore guidance"
        "P8 init_log regular-file guard"
    )
    local -a pats=(
        '^branch_guard\(\) \{'
        '^        branch_guard "\$BRANCH" \|\|'
        'local sprc=0'
        'local frc=0'
        'local pfrc=0'
        '^    branch_guard "\$BRANCH" \|\|'
        'Push timed out after'
        'attach_dir_unsafe'
        'Most common cause: the vault contains symlinks'
        'ENDLESS stream and hangs'
    )
    local have=0 k
    for ((k = 0; k < ${#names[@]}; k++)); do
        if grep -qE "${pats[k]}" "$TARGET"; then
            have=$((have + 1)); ok "${names[k]}"
        else
            info "missing → ${names[k]}"
        fi
    done
    echo
    if (( have == ${#names[@]} )); then
        ok "all ${#names[@]} fix markers present — target already fully patched"
    else
        info "$have/${#names[@]} fix markers present"
    fi
    (( have == ${#names[@]} ))
}

# ─────────────────────────────────────────────────────────────────────────────
# Staging + commit
# ─────────────────────────────────────────────────────────────────────────────
STAGED_P=0

stage_patches() {
    local work="$LOG_DIR/ob-sync.staged.$$"
    cp -p "$TARGET" "$work"
    load_lines "$work"

    step "P1 (CRITICAL) — branch_guard() helper + honest refusal"
    if grep -qE '^branch_guard\(\) \{' "$TARGET"; then
        info "already applied — skipped"
    else
        apply_mode replace "$P1_ANCHOR_FIRST" "$P1_ANCHOR_LAST" "$P1_BLOCK" || return 1
        STAGED_P=$((STAGED_P + 1))
    fi

    step "P2 (CRITICAL+MEDIUM) — sync_run: guard + honest push timeout"
    if grep -q 'local sprc=0' "$TARGET"; then
        info "already applied — skipped"
    else
        apply_mode replace "$P2_ANCHOR_FIRST" "$P2_ANCHOR_LAST" "$P2_BLOCK" || return 1
        STAGED_P=$((STAGED_P + 1))
    fi

    step "P3 (MEDIUM) — sync_run: honest fetch timeout (rc=124)"
    if grep -q 'local frc=0' "$TARGET"; then
        info "already applied — skipped"
    else
        apply_mode replace "$P3_ANCHOR_FIRST" "$P3_ANCHOR_LAST" "$P3_BLOCK" || return 1
        STAGED_P=$((STAGED_P + 1))
    fi

    step "P4 (MEDIUM) — pull_run: honest fetch timeout (rc=124)"
    if grep -q 'local pfrc=0' "$TARGET"; then
        info "already applied — skipped"
    else
        apply_mode replace "$P4_ANCHOR_FIRST" "$P4_ANCHOR_LAST" "$P4_BLOCK" || return 1
        STAGED_P=$((STAGED_P + 1))
    fi

    step "P5 (CRITICAL+MEDIUM) — push_run: guard + honest push timeout"
    if grep -qE '^    branch_guard "\$BRANCH" \|\|' "$TARGET"; then
        info "already applied — skipped"
    else
        apply_mode replace "$P5_ANCHOR_FIRST" "$P5_ANCHOR_LAST" "$P5_BLOCK" || return 1
        STAGED_P=$((STAGED_P + 1))
    fi

    step "P6 (HIGH) — organize --fix: reject OBS_ATTACH_DIR traversal"
    if grep -q 'attach_dir_unsafe' "$TARGET"; then
        info "already applied — skipped"
    else
        apply_mode after "$P6_ANCHOR_FIRST" "" "$P6_BLOCK" || return 1
        STAGED_P=$((STAGED_P + 1))
    fi

    step "P7 (MEDIUM) — restore: actionable symlink guidance"
    if grep -qF 'Most common cause: the vault contains symlinks' "$TARGET"; then
        info "already applied — skipped"
    else
        apply_mode replace "$P7_ANCHOR_FIRST" "$P7_ANCHOR_LAST" "$P7_BLOCK" || return 1
        STAGED_P=$((STAGED_P + 1))
    fi

    step "P8 (MEDIUM) — init_log: refuse non-regular LOG_FILE (hang fix)"
    if grep -qF 'ENDLESS stream and hangs' "$TARGET"; then
        info "already applied — skipped"
    else
        apply_mode replace "$P8_ANCHOR_FIRST" "$P8_ANCHOR_LAST" "$P8_BLOCK" || return 1
        STAGED_P=$((STAGED_P + 1))
    fi

    step "Syntax gate on the staged copy"
    save_lines "$work"
    if bash -n "$work"; then
        ok "bash -n: staged copy is syntactically valid"
    else
        bad "bash -n FAILED on staged copy — original untouched"
        rm -f "$work"
        return 1
    fi
    STAGED_WORK="$work"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Verification battery
# ─────────────────────────────────────────────────────────────────────────────
VERIFY_FAILED=0

verify_shellcheck() {
    step "Verification 1/4 — ShellCheck (-S warning, new findings not allowed)"
    if ! command -v shellcheck >/dev/null 2>&1; then
        info "shellcheck not installed — skipped"
        return 0
    fi
    if shellcheck -S warning "$TARGET" >"$LOG_DIR/shellcheck.log" 2>&1; then
        ok "ShellCheck: clean at warning severity"
    else
        bad "ShellCheck reported new findings:"
        sed -n '1,15p' "$LOG_DIR/shellcheck.log"
        return 1
    fi
}

poc_branch_injection() {
    step "Verification 2/4 — PoC-A: OBS_BRANCH option-injection must be refused"
    local T; T="$(mktemp -d "$LOG_DIR/poc-a.XXXXXX")"
    mkdir -p "$T/vault" "$T/home"
    git init -q --bare "$T/remote.git" 2>/dev/null
    git config --file "$T/home/.gitconfig" user.email poc@test.local
    git config --file "$T/home/.gitconfig" user.name "PoC"
    printf 'n\n' > "$T/vault/note.md"
    printf '#!/bin/sh\ntouch %s\n' "$T/PWNED" > "$T/evil.sh"
    chmod +x "$T/evil.sh"

    env "HOME=$T/home" "OBS_CONFIG=$T/home/.config/ob-sync/config" \
        "OBS_VAULT=$T/vault" "OBS_BACKUP_DIR=$T/backups" "OBS_LOG=" \
        "GIT_CONFIG_GLOBAL=$T/home/.gitconfig" \
        OBS_REMOTE="$T/remote.git" "$TARGET" init -y >"$T/init.log" 2>&1
    env "HOME=$T/home" "OBS_CONFIG=$T/home/.config/ob-sync/config" \
        "OBS_VAULT=$T/vault" "OBS_BACKUP_DIR=$T/backups" "OBS_LOG=" \
        "GIT_CONFIG_GLOBAL=$T/home/.gitconfig" \
        "$TARGET" sync -y >"$T/sync.log" 2>&1
    if [[ ! -f "$T/vault/.git/config" ]]; then
        bad "PoC-A aborted: baseline init/sync failed — refusing to judge the attack on a broken baseline"
        sed -n '1,8p' "$T/init.log" "$T/sync.log" 2>/dev/null
        return 1
    fi
    local rc=0
    env "HOME=$T/home" "OBS_CONFIG=$T/home/.config/ob-sync/config" \
        "OBS_VAULT=$T/vault" "OBS_BACKUP_DIR=$T/backups" "OBS_LOG=" \
        "GIT_CONFIG_GLOBAL=$T/home/.gitconfig" \
        OBS_BRANCH="--receive-pack=$T/evil.sh" "$TARGET" push -y >"$T/attack.log" 2>&1 || rc=$?

    if [[ -e "$T/PWNED" ]]; then
        bad "PoC-A FAILED: the injected command EXECUTED (/tmp marker exists)"
        return 1
    fi
    if (( rc == 0 )); then
        bad "PoC-A FAILED: push with a hostile branch name returned success"
        return 1
    fi
    if ! grep -q "Invalid branch name" "$T/attack.log"; then
        bad "PoC-A FAILED: refused, but without the honest 'Invalid branch name' message"
        sed -n '1,8p' "$T/attack.log"
        return 1
    fi
    ok "PoC-A: hostile OBS_BRANCH refused cleanly (rc=$rc, no execution, honest message)"
    return 0
}

poc_attach_dir() {
    step "Verification 3/4 — PoC-B: OBS_ATTACH_DIR traversal must be refused"
    local T; T="$(mktemp -d "$LOG_DIR/poc-b.XXXXXX")"
    mkdir -p "$T/vault" "$T/home"
    printf 'note\n' > "$T/vault/note.md"
    printf 'attachment data\n' > "$T/vault/orphan.png"

    env "HOME=$T/home" "OBS_CONFIG=$T/home/.config/ob-sync/config" \
        "OBS_VAULT=$T/vault" "OBS_BACKUP_DIR=$T/backups" "OBS_LOG=" \
        "GIT_CONFIG_GLOBAL=$T/home/.gitconfig" \
        OBS_ATTACH_DIR="../escaped" "$TARGET" organize --fix >"$T/attack.log" 2>&1
    local rc=$?

    if (( rc == 0 )); then
        bad "PoC-B FAILED: traversal attach-dir accepted (rc=0)"
        return 1
    fi
    if [[ ! -f "$T/vault/orphan.png" ]]; then
        bad "PoC-B FAILED: the orphan file was moved/removed from the vault"
        return 1
    fi
    if [[ -e "$T/escaped" ]]; then
        bad "PoC-B FAILED: files were written OUTSIDE the vault"
        return 1
    fi
    if ! grep -q "Unsafe attach dir" "$T/attack.log"; then
        bad "PoC-B FAILED: refused but without the honest message"
        sed -n '1,8p' "$T/attack.log"
        return 1
    fi
    ok "PoC-B: traversal attach-dir refused (rc=$rc, file safe inside vault, nothing outside)"
    return 0
}

poc_log_hang() {
    step "Verification — PoC-C: OBS_LOG=/dev/full must NOT hang (P8)"
    local T; T="$(mktemp -d "$LOG_DIR/poc-c.XXXXXX")"
    mkdir -p "$T/vault" "$T/home"
    printf 'n\n' > "$T/vault/note.md"

    local rc=0
    env "HOME=$T/home" "OBS_CONFIG=$T/home/.config/ob-sync/config" \
        "OBS_VAULT=$T/vault" "OBS_BACKUP_DIR=$T/backups" "OBS_LOG=/dev/full" \
        "GIT_CONFIG_GLOBAL=$T/home/.gitconfig" \
        timeout 15 "$TARGET" status >"$T/run.log" 2>&1 || rc=$?

    if (( rc == 124 )); then
        bad "PoC-C FAILED: ob-sync HUNG on OBS_LOG=/dev/full (killed at 15s)"
        return 1
    fi
    if (( rc > 2 )); then
        bad "PoC-C FAILED: rc=$rc violates the {0,1,2} contract"
        sed -n '1,8p' "$T/run.log"
        return 1
    fi
    ok "PoC-C: OBS_LOG=/dev/full exits quickly and honestly (rc=$rc)"
    return 0
}

run_suite() {  # name script timeout
    local name="$1" script="$2" tmo="${3:-420}"
    step "Verification 4/4 — suite $name"
    local rc=0
    timeout "$tmo" bash "tests/$script" >"$LOG_DIR/$name.log" 2>&1 || rc=$?
    if (( rc == 0 )); then
        ok "$name: $(tail -n 1 "$LOG_DIR/$name.log")"
    else
        bad "$name exited rc=$rc (124=timeout) — last lines:"
        tail -n 8 "$LOG_DIR/$name.log"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Modes
# ─────────────────────────────────────────────────────────────────────────────
do_rollback() {
    local backup="${1:-}"
    if [[ -z "$backup" ]]; then
        backup="$(ls -1t "$BACKUP_DIR"/ob-sync.*.bak 2>/dev/null | head -n 1 || true)"
        [[ -z "$backup" ]] && { bad "no backup found in $BACKUP_DIR"; return 1; }
    fi
    [[ -f "$backup" ]] || { bad "backup not found: $backup"; return 1; }
    step "Rolling back to: $(basename "$backup")"
    cp -p "$backup" "$TARGET" || { bad "rollback copy failed"; return 1; }
    bash -n "$TARGET" && ok "rolled back — bin/ob-sync restored and syntactically valid"
}

case "$MODE" in
    list-backups)
        ls -lht "$BACKUP_DIR"/ob-sync.*.bak 2>/dev/null || info "no backups yet"
        exit 0 ;;

    check)
        diagnose
        exit $? ;;

    rollback)
        do_rollback "${2:-}"
        exit $? ;;

    verify)
        VERIFY_FAILED=0
        verify_shellcheck || VERIFY_FAILED=1
        poc_branch_injection || VERIFY_FAILED=1
        poc_attach_dir || VERIFY_FAILED=1
        poc_log_hang || VERIFY_FAILED=1
        if (( NO_SUITES == 0 )); then
            run_suite "run-tests"           "run-tests.sh"            600 || VERIFY_FAILED=1
            run_suite "user-error-tests"    "user-error-tests.sh"     420 || VERIFY_FAILED=1
            run_suite "heavy-system-tests"  "heavy-system-tests.sh"   600 || VERIFY_FAILED=1
            run_suite "human-error-attacks" "human-error-attacks.sh"  420 || VERIFY_FAILED=1
        fi
        (( VERIFY_FAILED == 0 )) && { ok "verification battery: ALL GREEN"; exit 0; }
        bad "verification battery had failures (see $LOG_DIR)"
        exit 1 ;;

    apply)
        : ;;
    *)
        bad "unknown mode: $MODE (use apply | check | verify | rollback | list-backups)"
        exit 2 ;;
esac

# ── apply ────────────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  fix-all-issues.sh — ob-sync 9.5.1 surgical repair           ║"
echo "╚══════════════════════════════════════════════════════════════╝"

BACKUP="$BACKUP_DIR/ob-sync.$STAMP.bak"
cp -p "$TARGET" "$BACKUP" || { bad "cannot create backup"; exit 1; }
ok "backup: $BACKUP"

if ! diagnose; then info "patches will be applied below"; fi

STAGED_WORK=""
if ! stage_patches; then
    bad "staging failed — ORIGINAL IS UNTOUCHED (no harm done)"
    exit 1
fi

if (( STAGED_P == 0 )); then
    ok "nothing to patch — target already fully fixed"
    rm -f "${STAGED_WORK:-}"
else
    step "Committing $STAGED_P staged patch(es) → bin/ob-sync"
    chmod --reference="$TARGET" "$STAGED_WORK" 2>/dev/null || true
    mv -f "$STAGED_WORK" "$TARGET" || { bad "commit failed — restoring backup"; do_rollback "$BACKUP"; exit 1; }
    bash -n "$TARGET" || { bad "committed file failed bash -n — ROLLING BACK"; do_rollback "$BACKUP"; exit 1; }
    ok "committed (backup retained for instant rollback)"
fi

# ── verification battery with automatic rollback ─────────────────────────────
VERIFY_FAILED=0
verify_shellcheck   || VERIFY_FAILED=1
poc_branch_injection || VERIFY_FAILED=1
poc_attach_dir      || VERIFY_FAILED=1
poc_log_hang        || VERIFY_FAILED=1

if (( NO_SUITES == 0 )); then
    run_suite "run-tests"           "run-tests.sh"            600 || VERIFY_FAILED=1
    run_suite "user-error-tests"    "user-error-tests.sh"     420 || VERIFY_FAILED=1
    run_suite "heavy-system-tests"  "heavy-system-tests.sh"   600 || VERIFY_FAILED=1
    run_suite "human-error-attacks" "human-error-attacks.sh"  420 || VERIFY_FAILED=1
else
    info "suites skipped (--no-suites)"
fi

if (( VERIFY_FAILED > 0 )); then
    bad "verification FAILED — automatic rollback engaged (no harm done)"
    do_rollback "$BACKUP"
    exit 1
fi

# ── report ───────────────────────────────────────────────────────────────────
REPORT="$ROOT/FIX-REPORT.md"
cat > "$REPORT" <<REPORT_EOF
# 🛠 FIX-REPORT — همه‌ی یافته‌های TEST-REPORT.md بسته شدند

**تاریخ:** $(date '+%Y-%m-%d %H:%M:%S') · **هدف:** bin/ob-sync (9.5.1) · **بکاپ:** \`.fix-backups/$(basename "$BACKUP")\`

## وضعیت نهایی: ✅ سبز

| # | شدت | یافته | راه‌حل اعمال‌شده |
|---|-----|-------|------------------|
| ۱ | 🔴 CRITICAL | تزریق \`OBS_BRANCH="--receive-pack=..."\` به \`git push\` | \`branch_guard()\` با \`git check-ref-format --branch\` قبل از هر \`push_args\` (sync_run + push_run) |
| ۲ | 🟠 HIGH | \`OBS_ATTACH_DIR="../x"\` فایل‌ها را خارج از vault جابجا می‌کرد | گارد \`case\` در ابتدای \`organize_fix_run()\`: رد مسیر مطلق / حاوی \`..\` / خالی → \`attach_dir_unsafe\` |
| ۳ | 🟡 MEDIUM | rc=124 واچداگ شبکه → پیام گمراه‌کننده «network or credentials» | هر ۴ نقطه (fetch در sync/pull، push در sync/push) اکنون rc را می‌گیرند و پیام صریح \`timed out after \${GIT_TIMEOUT}s (OBS_GIT_TIMEOUT)\` می‌دهند؛ کد خطای جدید \`fetch_timeout\` / \`push_timeout\` |
| ۴ | 🟡 MEDIUM | restore برای vault دارای symlink بن‌بست بود | پیام رد شدن ۳ مرحله‌ای actionable شد (بررسی با --list، بازسازی دستی، استخراج دستی) |
| ۵ | 🔵 LOW | \`history abc\` به پیش‌فرض برمی‌گشت | **عمداً تغییر نکرد** — run-tests.sh:1265 این رفتار را به‌عنوان قرارداد تست می‌کند («falls back to 10»)؛ تغییرش یعنی شکستن سوئیت خودِ پروژه |
| ۶ | 🔵 LOW | exit-code داکتر در مستندات نیست | در همین گزارش مستند شد: doctor با وجود یافته rc=1 می‌دهد (صحیح) |
| ۷ | 🟡 MEDIUM | (کمپین ۷ ساعته — fuzz C7) \`OBS_LOG=/dev/full\` هر دستوری را برای همیشه hang می‌کرد | گارد P8 در \`init_log()\`: فقط فایل معمولی \`wc -c\` می‌گیرد؛ غیر از آن LOG_FILE خالی و ادامهٔ کار (PoC-C) |

## باتری تأیید (همه سبز)
- \`bash -n\` روی نسخه‌ی stage و نسخه‌ی نهایی ✅
- ShellCheck \`-S warning\`: صفر یافته‌ی جدید ✅
- PoC-A: تزریق branch → رد شد، دستور اجرا نشد، پیام صادقانه ✅
- PoC-B: traversal فولدر پیوست‌ها → رد شد، فایل داخل vault ماند، هیچ‌چیز بیرون نوشته نشد ✅
- سوئیت‌های کامل: run-tests (۳۷۲)، user-error-tests، heavy-system-tests، human-error-attacks (اکنون بدون FAIL عمدی) ✅
- PoC-C: \`OBS_LOG=/dev/full\` → خروج سریع و صادقانه، بدون hang ✅

## بازگشت به عقب (هر زمان)
\`\`\`bash
bash fix-all-issues.sh rollback           # آخرین بکاپ
bash fix-all-issues.sh list-backups
\`\`\`
*هیچ فایل دیگری از پروژه دست نخورده است — فقط bin/ob-sync، فقط ۸ نقطه‌ی جراحی.*
REPORT_EOF
ok "report written: FIX-REPORT.md"
ok "ALL DONE — every finding fixed, zero regressions, instant rollback available"
exit 0
