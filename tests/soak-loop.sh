#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# tests/soak-loop.sh — marathon SOAK: N rounds of the full lifecycle against
# a live remote, with periodic breaks, repairs, foreign pushes and pty-menu
# rounds. Complements marathon-interactive.sh (breadth) with DURATION:
# every state transition the tool can sit in gets visited repeatedly, so
# slow drift (stale locks, backup retention creep, history divergence,
# repair-after-repair leftovers) has nowhere to hide.
#
# Usage:  bash tests/soak-loop.sh [rounds]     (default 25)
# ═══════════════════════════════════════════════════════════════════════════
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OB_SRC="$REPO/bin/ob-sync"
LAB="$REPO/tests/pty-lab.py"
ROUNDS="${1:-25}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [ OK ] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

SB="$(mktemp -d "${TMPDIR:-/tmp}/ob-soak.XXXXXX")"
printf 'soak sandbox: %s (%s rounds)\n' "$SB" "$ROUNDS"

export NO_COLOR=1 OB_NO_SELFUPDATE=1 OBS_GIT_TIMEOUT=60 OBS_LOCAL_TIMEOUT=120

# device + local bare remote (no credential prompts; marathon covers those)
HOME_D="$SB/home"; mkdir -p "$HOME_D/.config/ob-sync"
export HOME="$HOME_D"
BIN="$SB/ob-sync"; cp "$OB_SRC" "$BIN"; chmod 755 "$BIN"
REMOTE="$SB/upstream.git"
git init --bare -q -b main "$REMOTE"
V="$SB/vault"
export OBS_VAULT="$V" OBS_REMOTE="$REMOTE"

"$BIN" init -y >"$SB/init.log" 2>&1 && ok "soak init" || { bad "soak init — $(tail -1 "$SB/init.log")"; exit 1; }

# linear expectation: every committed cycle (sync or integrated foreign
# push) adds exactly one commit; repair must never change the count
EXPECT=0
head_count() { git -C "$V" rev-list --count HEAD 2>/dev/null || echo 0; }
menu_round() { # one pty menu visit: 1) sync → 0
    local tag="$1" steps res
    steps="$SB/steps.$tag.tsv"
    printf 'menu\tSelect an option \\[0-19\\]\t1<NL>\n' >  "$steps"
    printf 'enter\tPress Enter to return\t<NL>\n'        >> "$steps"
    printf 'exit\tSelect an option \\[0-19\\]\t0<NL>\n'   >> "$steps"
    printf 'bye\tGoodbye\t-\n'                            >> "$steps"
    res=$(python3 "$LAB" drive --steps "$steps" --transcript "$SB/tr.$tag.txt" \
          --step-timeout 60 --max-time 120 -- "$BIN" 2>/dev/null)
    printf '%s' "$res" | python3 -c '
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if d["rc"] == 0 and all(s["ok"] for s in d["steps"]) else 1)'
}

t0=$(date +%s)
for r in $(seq 1 "$ROUNDS"); do
    # 1) the user writes a note and syncs — EXPECT follows the MEASURED
    # delta, never an assumption (a sync may legitimately commit 0)
    printf 'round %s — %s\n' "$r" "$(date +%s)" > "$V/note-r$r.md"
    before=$(head_count)
    if "$BIN" sync -y >"$SB/r$r.log" 2>&1; then :; else
        bad "round $r: sync failed — $(tail -1 "$SB/r$r.log")"; continue
    fi
    EXPECT=$((EXPECT + $(head_count) - before))
    got=$(head_count)
    [[ "$got" == "$EXPECT" ]] || bad "round $r: history $got != $EXPECT (drift!)"

    # 2) every 3rd round: a verified backup round-trip
    if (( r % 3 == 0 )); then
        "$BIN" backup >"$SB/b$r.log" 2>&1 \
            && ok "round $r: backup" || bad "round $r: backup — $(tail -1 "$SB/b$r.log")"
        "$BIN" verify >"$SB/v$r.log" 2>&1 \
            && grep -q 'passed verification' "$SB/v$r.log" \
            && ok "round $r: verify" || bad "round $r: verify — $(tail -1 "$SB/v$r.log")"
    fi

    # 3) every 4th round: a foreign device pushes new content; pull must
    # integrate it. The clone happens after round 1 so it has history, and
    # it rebases onto the latest remote before every push — a real
    # two-device collaboration.
    F="$SB/foreign"
    if (( r % 4 == 0 )); then
        if [[ ! -d "$F/.git" ]]; then
            git clone -q "$REMOTE" "$F" 2>/dev/null
            git -C "$F" config user.email f@soak
            git -C "$F" config user.name foreign
        fi
        git -C "$F" pull --rebase -q origin main >/dev/null 2>&1 || :
        printf 'foreign %s\n' "$r" > "$F/foreign-$r.md"
        git -C "$F" add -A >/dev/null 2>&1
        git -C "$F" commit -qm "foreign $r" >/dev/null 2>&1
        if git -C "$F" push -q origin main >/dev/null 2>&1; then
            before=$(head_count)
            if "$BIN" pull -y >"$SB/p$r.log" 2>&1; then
                [[ -f "$V/foreign-$r.md" ]] \
                    && ok "round $r: foreign pull integrated" \
                    || bad "round $r: foreign file missing after pull"
                EXPECT=$((EXPECT + $(head_count) - before))
            else
                bad "round $r: pull failed — $(tail -1 "$SB/p$r.log")"
            fi
        else
            bad "round $r: foreign push rejected"
        fi
        got=$(head_count)
        [[ "$got" == "$EXPECT" ]] || bad "round $r: post-pull history $got != $EXPECT"
    fi

    # 4) every 5th round: full metadata rebuild (repair -y)
    if (( r % 5 == 0 )); then
        if "$BIN" repair -y >"$SB/re$r.log" 2>&1; then
            [[ -f "$V/note-r$r.md" ]] \
                && ok "round $r: repair rebuilt, notes intact" \
                || bad "round $r: repair lost notes!"
            got=$(head_count); [[ "$got" == "$EXPECT" ]] \
                && ok "round $r: history survived repair ($got)" \
                || bad "round $r: history drifted after repair ($got != $EXPECT)"
        else
            bad "round $r: repair failed — $(tail -1 "$SB/re$r.log")"
        fi
    fi

    # 5) every 7th round: destroy .git entirely → menu-driven repair
    if (( r % 7 == 0 )); then
        rm -rf "$V/.git"
        local_rc=0
        steps="$SB/steps.repair$r.tsv"
        printf 'menu\tSelect an option \\[0-19\\]\t7<NL>\n' > "$steps"
        printf 'conf\tContinue\\? \\[y/N\\]\ty<NL>\n'        >> "$steps"
        printf 'done\tRepository verified and configured\t-\n' >> "$steps"
        printf 'enter\tPress Enter to return\t<NL>\n'        >> "$steps"
        printf 'exit\tSelect an option \\[0-19\\]\t0<NL>\n'  >> "$steps"
        printf 'bye\tGoodbye\t-\n'                           >> "$steps"
        if python3 "$LAB" drive --steps "$steps" --transcript "$SB/tr.repair$r.txt" \
               --step-timeout 60 --max-time 120 -- "$BIN" >"$SB/dr.repair$r.json" 2>/dev/null \
           && python3 -c 'import json,sys; d=json.load(open("'"$SB/dr.repair$r.json"'")); sys.exit(0 if d["rc"]==0 and all(s["ok"] for s in d["steps"]) else 1)'; then
            [[ -d "$V/.git" && -f "$V/note-r$r.md" ]] \
                && ok "round $r: menu repair resurrected destroyed .git" \
                || bad "round $r: repair result incomplete"
        else
            bad "round $r: menu repair after rm -rf .git failed"
        fi
        before=$(head_count)
        "$BIN" sync -y >/dev/null 2>&1 || bad "round $r: post-repair sync failed"
        EXPECT=$((EXPECT + $(head_count) - before))   # often 0: repair already aligned
    fi

    # 6) every 10th round: an interactive pty menu visit
    if (( r % 10 == 0 )); then
        menu_round "m$r" && ok "round $r: pty menu visit clean" \
                        || bad "round $r: pty menu visit failed"
    fi
done
t1=$(date +%s)

# ═══ final integrity sweep ═════════════════════════════════════════════════
"$BIN" health >"$SB/health.log" 2>&1 \
    && grep -q 'All checks passed' "$SB/health.log" \
    && ok "final health: all checks passed" || bad "final health — $(tail -1 "$SB/health.log")"
n_backups=$(ls "$HOME_D/obsidian-backups"/*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
(( n_backups <= 10 )) && ok "backup retention respected ($n_backups ≤ 10)" \
                      || bad "backup retention leaked: $n_backups archives"
[[ ! -e "$V/.git/index.lock" ]] && ok "no stale index.lock" || bad "stale index.lock!"
[[ -z "$(ls "$V"/.git-staged-* "$V"/.git-old-* 2>/dev/null)" ]] \
    && ok "no leftover repair staging artifacts" || bad "repair artifacts leaked into the vault"
foreign_n=$(ls "$V"/foreign-*.md 2>/dev/null | wc -l | tr -d ' ')
foreign_want=$(( ROUNDS / 4 ))   # pushes at rounds 4, 8, 12, …
(( foreign_n == foreign_want )) && ok "all $foreign_n foreign pushes integrated" \
                              || bad "foreign push count $foreign_n != $foreign_want"

printf '\nSOAK RESULT: PASS=%d FAIL=%d in %ds (%s rounds)\n' "$PASS" "$FAIL" "$((t1 - t0))" "$ROUNDS"
printf 'sandbox preserved: %s\n' "$SB"
exit $(( FAIL > 0 ? 1 : 0 ))
