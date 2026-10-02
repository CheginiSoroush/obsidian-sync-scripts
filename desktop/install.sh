#!/usr/bin/env bash
#
# ─────────────────────────────────────────────────────────────────────────────
#   ob-sync — desktop installer (Linux & macOS)
#
#   Installs bin/ob-sync into ~/.local/bin, checks bash/git availability
#   and helps with PATH configuration. Prefers a local checkout of this
#   repository; falls back to fetching the core from GitHub raw.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/CheginiSoroush/obsidian-sync-scripts/main"

ok()   { printf '\033[92m[ OK ]\033[0m %s\n' "$1"; }
say()  { printf '\033[96m[INFO]\033[0m %s\n' "$1"; }
warn() { printf '\033[93m[WARN]\033[0m %s\n' "$1"; }
fail() { printf '\033[91m[FAIL]\033[0m %s\n' "$1" >&2; exit 1; }

DEST="$HOME/.local/bin"
mkdir -p "$DEST"

# Prefer a local checkout, fall back to a remote download.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -f "$SCRIPT_DIR/../bin/ob-sync" ]]; then
    say "Installing from local checkout"
    cp -- "$SCRIPT_DIR/../bin/ob-sync" "$DEST/ob-sync"
else
    if command -v curl >/dev/null 2>&1; then
        say "Downloading ob-sync from GitHub"
        curl -fsSL "$REPO_RAW/bin/ob-sync" -o "$DEST/ob-sync" \
            || fail "Download failed — check your network connection"
    elif command -v wget >/dev/null 2>&1; then
        say "Downloading ob-sync from GitHub"
        wget -qO "$DEST/ob-sync" "$REPO_RAW/bin/ob-sync" \
            || fail "Download failed — check your network connection"
    else
        fail "Need curl or wget — install one and retry"
    fi
fi

chmod 0755 "$DEST/ob-sync"
ok "Installed: $DEST/ob-sync"

# bash 4+ is required by the core script.
if (( BASH_VERSINFO[0] < 4 )); then
    warn "System bash is ${BASH_VERSION} — the core script needs bash >= 4"
    if [[ "${OSTYPE:-}" == darwin* ]]; then
        say "Fix: brew install bash   (upgrade before running ob-sync)"
    else
        say "Install bash >= 4 with your package manager before running ob-sync"
    fi
fi

# git is required for everything except the read-only commands.
if command -v git >/dev/null 2>&1; then
    ok "git is available"
elif [[ "${OSTYPE:-}" == darwin* ]]; then
    warn "git not found — install with: xcode-select --install"
else
    warn "git not found — install it with your package manager"
fi

# ~/.local/bin is not on PATH by default everywhere.
if [[ ":$PATH:" != *":$DEST:"* ]]; then
    warn "$DEST is not on your PATH"
    if [[ "${SHELL:-}" == *zsh ]]; then
        say 'Add it:  echo '\''export PATH="$HOME/.local/bin:$PATH"'\'' >> ~/.zshrc'
    else
        say 'Add it:  echo '\''export PATH="$HOME/.local/bin:$PATH"'\'' >> ~/.bashrc'
    fi
else
    ok "$DEST is on your PATH"
fi

printf '\n'
ok "Setup complete. Next steps:"
printf '   1)  ob-sync doctor\n'
printf '   2)  ob-sync init\n'
printf '   3)  ob-sync sync\n'
