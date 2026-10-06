# ─────────────────────────────────────────────────────────────────────────────
#   Bash completion for ob-sync
#
#   Install (pick one):
#     system-wide : sudo cp completions/ob-sync.bash \
#                       /etc/bash_completion.d/ob-sync
#     per-user    : mkdir -p ~/.local/share/bash-completion/completions &&
#                   cp completions/ob-sync.bash \
#                      ~/.local/share/bash-completion/completions/ob-sync
#     quick       : source /path/to/ob-sync/completions/ob-sync.bash
#                   (add to ~/.bashrc to make it permanent)
#     Termux      : pkg install bash-completion, then use the "quick" way
#
#   No external dependencies — plain bash programmable completion.
# ─────────────────────────────────────────────────────────────────────────────

_ob_sync() {
    local cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    local commands="sync pull push quick backup restore verify repair organize
                    diff history config cron edit-conf status health doctor init remote menu
                    log help version"
    local global_flags="-y --yes -n --no-color -h --help -v --version"

    # First word: commands and global options.
    if (( COMP_CWORD <= 1 )); then
        local w
        while IFS= read -r w; do
            [[ -n "$w" ]] && COMPREPLY+=("$w")
        done < <(compgen -W "$commands $global_flags" -- "$cur")
        return 0
    fi

    # 'cron' owns its own subcommands — the per-command flags below
    # belong to the top-level commands only ('cron status --json' and
    # friends are dropped by the parser), so under cron complete only
    # the subcommand word itself and the install presets.
    if [[ "${COMP_WORDS[1]}" == "cron" && "$prev" != "cron" && "$prev" != "install" ]]; then
        return 0
    fi

    case "$prev" in
        sync|pull|push|quick|backup|verify|health)
            # machine-readable result for cron wrappers / CI
            local w
            while IFS= read -r w; do
                [[ -n "$w" ]] && COMPREPLY+=("$w")
            done < <(compgen -W "--json --yes" -- "$cur")
            ;;
        restore)
            # modes, consent and the 'latest' shorthand
            local w
            while IFS= read -r w; do
                [[ -n "$w" ]] && COMPREPLY+=("$w")
            done < <(compgen -W "--list --dry-run --json --yes latest" -- "$cur")
            ;;
        status)
            local w
            while IFS= read -r w; do
                [[ -n "$w" ]] && COMPREPLY+=("$w")
            done < <(compgen -W "--json" -- "$cur")
            ;;
        history)
            # machine-readable commit document; numeric arg needs no completion
            local w
            while IFS= read -r w; do
                [[ -n "$w" ]] && COMPREPLY+=("$w")
            done < <(compgen -W "--json" -- "$cur")
            ;;
        log)
            # machine-readable activity document for automation
            local w
            while IFS= read -r w; do
                [[ -n "$w" ]] && COMPREPLY+=("$w")
            done < <(compgen -W "--json" -- "$cur")
            ;;
        doctor)
            local w
            while IFS= read -r w; do
                [[ -n "$w" ]] && COMPREPLY+=("$w")
            done < <(compgen -W "--json" -- "$cur")
            ;;
        organize)
            # --fix is the destructive mode; --json the machine report
            local w
            while IFS= read -r w; do
                [[ -n "$w" ]] && COMPREPLY+=("$w")
            done < <(compgen -W "--fix --json" -- "$cur")
            ;;
        cron)
            local w
            while IFS= read -r w; do
                [[ -n "$w" ]] && COMPREPLY+=("$w")
            done < <(compgen -W "--help status install show uninstall" -- "$cur")
            ;;
        install)
            # only reachable as 'cron install' — schedule presets
            local w
            while IFS= read -r w; do
                [[ -n "$w" ]] && COMPREPLY+=("$w")
            done < <(compgen -W "15min 30min hourly daily" -- "$cur")
            ;;
        remote)
            # a repository URL — no completion
            ;;
        edit-conf)
            # opens an editor — no completion
            ;;
        *)
            # Global flags are only valid BEFORE the command word —
            # main() parses them positionally and every subcommand
            # parser rejects them. Offer them only while no command has
            # been typed yet (e.g. right after another global flag).
            if [[ "$cur" == -* ]]; then
                local w c word cmd_seen=0
                for ((c = 1; c < COMP_CWORD; c++)); do
                    word="${COMP_WORDS[c]}"
                    [[ " $commands " == *" $word "* ]] && { cmd_seen=1; break; }
                done
                if (( ! cmd_seen )); then
                    while IFS= read -r w; do
                        [[ -n "$w" ]] && COMPREPLY+=("$w")
                    done < <(compgen -W "$global_flags" -- "$cur")
                fi
            fi
            ;;
    esac
    return 0
}

complete -F _ob_sync ob-sync
