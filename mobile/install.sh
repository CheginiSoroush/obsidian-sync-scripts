#!/usr/bin/env bash
#
# ─────────────────────────────────────────────────────────────────────────────
#   ob-sync — mobile installer (Termux / Android)
#
#   Installs bin/ob-sync into $PREFIX/bin, verifies dependencies and
#   points at the next setup steps. Prefers a local checkout of this
#   repository; falls back to fetching the core from GitHub raw.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/CheginiSoroush/obsidian-sync-scripts/main"

ok()   { printf '\033[92m[ OK ]\033[0m %s\n' "$1"; }
say()  { printf '\033[96m[INFO]\033[0m %s\n' "$1"; }
fail() { printf '\033[91m[FAIL]\033[0m %s\n' "$1" >&2; exit 1; }
warn() { printf '\033[93m[WARN]\033[0m %s\n' "$1" >&2; }

# This installer is Termux-only — desktop users have their own.
[[ -n "${TERMUX_VERSION:-}" && -n "${PREFIX:-}" ]] || {
    fail "Not running under Termux — for Linux/macOS use desktop/install.sh"
}

DEST="$PREFIX/bin"
mkdir -p "$DEST"

# Prefer a local checkout, fall back to a remote download.
# NOTE: under `curl … | bash` the script runs from stdin, where
# BASH_SOURCE[0] is unset — referencing it under `set -u` aborts the
# whole installer on Termux, so only resolve it when it exists.
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fi
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/../bin/ob-sync" ]]; then
    say "Installing from local checkout"
    cp -- "$SCRIPT_DIR/../bin/ob-sync" "$DEST/ob-sync"
else
    command -v curl >/dev/null 2>&1 || fail "curl is required — run: pkg install curl"
    say "Downloading ob-sync from GitHub"
    curl -fsSL "$REPO_RAW/bin/ob-sync" -o "$DEST/ob-sync" \
        || fail "Download failed — check your network connection"
fi

chmod 0755 "$DEST/ob-sync"
[[ -x "$DEST/ob-sync" ]] || fail "Installation incomplete — check $DEST"
ok "Installed: $DEST/ob-sync"

# Dependencies.
if ! command -v git >/dev/null 2>&1; then
    say "Installing git"
    pkg install -y git || fail "Failed to install git"
fi
ok "git is available"

# tar backs every backup; coreutils provides sha256sum for the checksums.
command -v tar >/dev/null 2>&1 \
    || warn "tar not found — run: pkg install tar (required for backups)"
if command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1; then
    ok "SHA-256 hashing is available"
else
    say "Installing coreutils (provides sha256sum)"
    pkg install -y coreutils \
        || warn "Could not install coreutils — backups will lack checksums"
fi

# Storage permission (user action may be required).
if [[ -d "$HOME/storage/shared" ]]; then
    ok "Shared storage is accessible"
else
    say "Storage permission missing — run: termux-setup-storage"
fi

printf '\n'
ok "Setup complete. Next steps:"
printf '   1)  ob-sync doctor\n'
printf '   2)  ob-sync init\n'
printf '   3)  ob-sync\n'

