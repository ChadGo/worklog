#!/bin/bash
set -euo pipefail

# Worklog - Install Script
# Idempotent: safe to run multiple times. Re-run after moving the checkout
# or after installing/upgrading claude or gh to refresh config.local.lua.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

HS_INIT="$HOME/.hammerspoon/init.lua"
HS_LINE="dofile(\"$SCRIPT_DIR/hammerspoon/activity_monitor.lua\")"
LOCAL_CONFIG="$SCRIPT_DIR/hammerspoon/config.local.lua"
LOCAL_INSTRUCTIONS="$SCRIPT_DIR/instructions.local.md"
# Matches the loader line for any checkout, whatever the folder is named.
HOOK_PATTERN='dofile\(.*/hammerspoon/activity_monitor\.lua"\)'

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${GREEN}[OK]${NC}   $1"; }
warn()    { echo -e "${YELLOW}[SKIP]${NC} $1"; }
err()     { echo -e "${RED}[ERR]${NC}  $1"; }
section() { echo -e "\n${GREEN}==>${NC} $1"; }

ERRORS=0

# ------------------------------------------------------------------
section "Checking Homebrew"
# ------------------------------------------------------------------
if command -v brew &>/dev/null; then
    info "Homebrew installed ($(brew --prefix))"
else
    err "Homebrew not found. Install from https://brew.sh"
    ERRORS=$((ERRORS + 1))
fi

# ------------------------------------------------------------------
section "Checking/installing Hammerspoon"
# ------------------------------------------------------------------
if [ -d "/Applications/Hammerspoon.app" ]; then
    info "Hammerspoon installed (/Applications/Hammerspoon.app)"
elif command -v brew &>/dev/null; then
    echo -e "${YELLOW}[INST]${NC} Installing Hammerspoon via Homebrew..."
    if brew install --cask hammerspoon; then
        info "Hammerspoon installed"
    else
        err "Failed to install Hammerspoon. Download from https://www.hammerspoon.org/"
        ERRORS=$((ERRORS + 1))
    fi
else
    err "Hammerspoon not found. Download from https://www.hammerspoon.org/"
    ERRORS=$((ERRORS + 1))
fi

# ------------------------------------------------------------------
section "Checking/installing gh (GitHub CLI)"
# ------------------------------------------------------------------
if command -v gh &>/dev/null; then
    info "gh already installed ($(command -v gh))"
elif command -v brew &>/dev/null; then
    echo -e "${YELLOW}[INST]${NC} Installing gh via Homebrew..."
    if brew install gh; then
        info "gh installed"
    else
        err "Failed to install gh"
        ERRORS=$((ERRORS + 1))
    fi
else
    err "gh not found. Install from https://cli.github.com/"
    ERRORS=$((ERRORS + 1))
fi

# Detect auth — don't log in from the installer, just nudge.
if command -v gh &>/dev/null; then
    if gh auth status &>/dev/null; then
        info "gh is authenticated"
    else
        warn "gh not authenticated — run 'gh auth login' (PR activity will be empty until you do)"
    fi
fi

# ------------------------------------------------------------------
section "Checking Claude Code CLI"
# ------------------------------------------------------------------
# Not installed by this script: the CLI has its own installer and the
# first run must be interactive to sign in.
if command -v claude &>/dev/null; then
    info "claude installed ($(command -v claude))"
    if claude auth status &>/dev/null; then
        info "claude is signed in"
    else
        warn "claude may not be signed in — run 'claude' once in a terminal and complete login"
    fi
else
    err "claude not found. Install with: curl -fsSL https://claude.ai/install.sh | bash"
    err "Then run 'claude' once to sign in, and re-run this script."
    ERRORS=$((ERRORS + 1))
fi

# ------------------------------------------------------------------
section "Checking system tools"
# ------------------------------------------------------------------
for tool in git lsof pgrep; do
    if command -v "$tool" &>/dev/null; then
        info "$tool found ($(command -v "$tool"))"
    else
        err "$tool not found (ships with macOS; check your PATH)"
        ERRORS=$((ERRORS + 1))
    fi
done

# ------------------------------------------------------------------
section "Creating data directories"
# ------------------------------------------------------------------
# logs/ and summaries/ are gitignored, so a fresh clone has neither.
for dir in logs summaries/daily summaries/weekly summaries/monthly summaries/yearly reviews; do
    if [ -d "$SCRIPT_DIR/$dir" ]; then
        info "$dir/ already exists"
    else
        mkdir -p "$SCRIPT_DIR/$dir"
        info "Created $dir/"
    fi
done

# ------------------------------------------------------------------
section "Writing hammerspoon/config.local.lua"
# ------------------------------------------------------------------
# Hammerspoon runs with a minimal PATH, so bake in absolute paths for the
# CLIs. Any other key from config.lua can be overridden in this file too.
CLAUDE_PATH="$(command -v claude 2>/dev/null || true)"
GH_PATH="$(command -v gh 2>/dev/null || true)"

if [ -f "$LOCAL_CONFIG" ]; then
    # Preserve the user's other overrides; just refresh the two CLI paths.
    TMP="$(mktemp)"
    grep -vE '^\s*(claude_path|gh_path)\s*=' "$LOCAL_CONFIG" > "$TMP" || true
    if grep -q '^return {' "$TMP"; then
        # Insert refreshed paths right after the opening brace.
        awk -v c="$CLAUDE_PATH" -v g="$GH_PATH" '
            /^return \{/ && !done {
                print
                if (c != "") print "    claude_path = \"" c "\","
                if (g != "") print "    gh_path = \"" g "\","
                done = 1
                next
            }
            { print }
        ' "$TMP" > "$LOCAL_CONFIG"
        rm -f "$TMP"
        info "Refreshed claude_path/gh_path in config.local.lua (other overrides kept)"
    else
        rm -f "$TMP"
        warn "config.local.lua exists but is not a 'return { ... }' table — leaving it alone"
    fi
else
    {
        echo "-- Per-machine Worklog overrides. Gitignored. Written by install.sh;"
        echo "-- re-run install.sh to refresh the CLI paths. Any key from config.lua"
        echo "-- can be overridden here (e.g. auto_summary_time = \"17:30\")."
        echo "return {"
        [ -n "$CLAUDE_PATH" ] && echo "    claude_path = \"$CLAUDE_PATH\","
        [ -n "$GH_PATH" ] && echo "    gh_path = \"$GH_PATH\","
        echo "}"
    } > "$LOCAL_CONFIG"
    info "Created config.local.lua"
fi
[ -n "$CLAUDE_PATH" ] && info "claude_path = $CLAUDE_PATH" || warn "claude_path not set (claude not found)"
[ -n "$GH_PATH" ] && info "gh_path = $GH_PATH" || warn "gh_path not set (gh not found)"

# ------------------------------------------------------------------
section "Creating instructions.local.md"
# ------------------------------------------------------------------
if [ -f "$LOCAL_INSTRUCTIONS" ]; then
    info "instructions.local.md already exists"
else
    cat > "$LOCAL_INSTRUCTIONS" << 'INSTR'
# Local Custom Instructions (not checked in)

Instructions here are merged with instructions.md.
Use ## All for every summary level, or ## Daily, ## Weekly, ## Monthly, ## Yearly for specific levels.

## All

- Ignore Reddit, Netflix, YouTube, and Spotify activity

### Development tools to fold into the active git project/branch

- **Browser on localhost / localtest.me** — testing the app locally, associate with the most recent git branch
- **Database client (DBeaver, TablePlus, Postico)** — associate with the most recent git project
- **Loom** — recording PR walkthroughs, associate with the most recent git branch/PR

## Daily

## Weekly

## Monthly

## Yearly
INSTR
    info "Created instructions.local.md (edit it to tell the summarizer about your tools)"
fi

# ------------------------------------------------------------------
section "Hooking into ~/.hammerspoon/init.lua"
# ------------------------------------------------------------------
mkdir -p "$(dirname "$HS_INIT")"
touch "$HS_INIT"

if grep -qF "$HS_LINE" "$HS_INIT"; then
    info "init.lua already loads worklog from this checkout"
elif grep -qE "$HOOK_PATTERN" "$HS_INIT"; then
    # A line from an older checkout location (or the old HOME-based form). Replace it.
    TMP="$(mktemp)"
    grep -vE -e "$HOOK_PATTERN" -e '^-- Worklog activity tracker$' "$HS_INIT" > "$TMP" || true
    {
        cat "$TMP"
        echo ""
        echo "-- Worklog activity tracker"
        echo "$HS_LINE"
    } > "$HS_INIT"
    rm -f "$TMP"
    info "Replaced stale worklog line in init.lua with this checkout's path"
else
    {
        echo ""
        echo "-- Worklog activity tracker"
        echo "$HS_LINE"
    } >> "$HS_INIT"
    info "Added worklog loader to $HS_INIT"
fi

# ------------------------------------------------------------------
section "Reloading Hammerspoon"
# ------------------------------------------------------------------
if [ -d "/Applications/Hammerspoon.app" ]; then
    if pgrep -xq Hammerspoon; then
        # The hs CLI only exists if init.lua does require("hs.ipc"). Its exit
        # code is meaningless here: the message port drops as soon as the
        # reload starts, so it reports a transport error on success.
        # The CLI can also hang if Hammerspoon is busy, so cap each call.
        if command -v hs &>/dev/null && perl -e 'alarm 5; exec @ARGV' hs -c 'return 1' &>/dev/null; then
            perl -e 'alarm 5; exec @ARGV' hs -c 'hs.reload()' &>/dev/null || true
            info "Hammerspoon config reloaded"
        else
            osascript -e 'tell application "Hammerspoon" to quit' &>/dev/null || true
            sleep 1
            open -a Hammerspoon
            info "Restarted Hammerspoon to pick up the new config"
        fi
    else
        open -a Hammerspoon
        info "Launched Hammerspoon"
    fi
fi

# ------------------------------------------------------------------
section "Summary"
# ------------------------------------------------------------------
echo ""
if [ "$ERRORS" -gt 0 ]; then
    err "$ERRORS issue(s) found — fix the errors above and re-run install.sh"
    exit 1
fi

info "All dependencies satisfied"
info "Checkout: $SCRIPT_DIR"
info "Config overrides: $LOCAL_CONFIG"
echo ""
echo "Remaining manual steps:"
echo "  1. Grant Hammerspoon Accessibility access the first time it asks"
echo "     (System Settings > Privacy & Security > Accessibility). Without it,"
echo "     window titles are empty and the log is useless."
echo "  2. Look for the ◉ icon in the menu bar and a 'Tracking started' notification."
echo "  3. Press Ctrl+Shift+S after a few minutes to generate a test summary."
echo ""
echo "Edit instructions.local.md to tell the summarizer about your tools and what to ignore."
