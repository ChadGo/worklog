#!/bin/bash
set -euo pipefail

# Worklog - Uninstall Script
# Removes the Hammerspoon hook and generated config. Keeps logs/ and
# summaries/ unless you say otherwise. Does not uninstall Hammerspoon,
# gh, or claude.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HS_INIT="$HOME/.hammerspoon/init.lua"
LOCAL_CONFIG="$SCRIPT_DIR/hammerspoon/config.local.lua"
# Matches the loader line for any checkout, whatever the folder is named.
HOOK_PATTERN='dofile\(.*/hammerspoon/activity_monitor\.lua"\)'

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[OK]${NC}   $1"; }
warn() { echo -e "${YELLOW}[SKIP]${NC} $1"; }

echo "Uninstalling Worklog..."
echo ""

# Remove the loader line (and its comment) from init.lua
if [ -f "$HS_INIT" ] && grep -qE "$HOOK_PATTERN" "$HS_INIT"; then
    TMP="$(mktemp)"
    grep -vE -e "$HOOK_PATTERN" -e '^-- Worklog activity tracker$' "$HS_INIT" > "$TMP" || true
    mv "$TMP" "$HS_INIT"
    info "Removed worklog loader from $HS_INIT"
    if pgrep -xq Hammerspoon && command -v hs &>/dev/null; then
        hs -c 'hs.reload()' &>/dev/null && info "Hammerspoon config reloaded" || warn "Reload Hammerspoon manually to stop tracking"
    fi
else
    warn "No worklog loader found in $HS_INIT"
fi

# Remove generated config
if [ -f "$LOCAL_CONFIG" ]; then
    rm "$LOCAL_CONFIG"
    info "Removed $LOCAL_CONFIG"
else
    warn "No config.local.lua to remove"
fi

# Optionally remove data
for dir in logs summaries; do
    if [ -d "$SCRIPT_DIR/$dir" ]; then
        echo ""
        read -p "Remove $dir/ (your tracked data)? (y/N) " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "${SCRIPT_DIR:?}/$dir"
            info "Removed $dir/"
        else
            warn "Kept $dir/"
        fi
    fi
done

echo ""
info "Uninstall complete. instructions.local.md was kept; delete it by hand if you don't want it."
