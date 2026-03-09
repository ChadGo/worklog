# Worklog

A Hammerspoon tool that tracks your computer activity throughout the day and generates markdown summaries using Claude CLI. Summaries include git commits, GitHub PR activity, and a TLDR overview.

## What It Does

- **Automatic tracking** — monitors active application, window title, working directory, and git repo/branch in real time
- **Manual log entries** — hotkey opens a dialog to jot down context, meetings, or anything window titles don't capture
- **Daily summaries** — generates a markdown summary via Claude CLI with a TLDR, activity breakdown, git commits, and PR activity
- **Summary browser** — browse and open past summaries from the menu bar
- **Custom instructions** — tell the summary generator what to ignore, emphasize, or how to organize

## Setup

### Prerequisites

- [Hammerspoon](https://www.hammerspoon.org/) installed
- [Claude CLI](https://docs.anthropic.com/en/docs/claude-cli) installed and configured
- [GitHub CLI](https://cli.github.com/) (`gh`) installed and authenticated (for PR activity)

### Installation

1. Clone or copy this repo to `~/Projects/worklog`

2. Add this line to `~/.hammerspoon/init.lua`:

```lua
dofile(os.getenv("HOME") .. "/Projects/worklog/hammerspoon/activity_monitor.lua")
```

3. Verify the Claude CLI path matches your system:

```sh
which claude
```

If it differs from `~/.local/bin/claude`, update `claude_path` in `hammerspoon/config.lua`.

4. Reload Hammerspoon. You should see a `◉` icon in your menu bar and a "Tracking started" notification.

## Usage

### Hotkeys

| Shortcut | Action |
|---|---|
| `Ctrl+Shift+L` | Open manual log entry dialog |
| `Ctrl+Shift+S` | Generate summary for today |

### Menu Bar

Click the `◉` icon in the menu bar for:

- Pause/resume tracking
- New log entry
- Generate summary
- Browse summaries
- Open today's log or logs folder
- Edit custom instructions

### Manual Log Entries

Press `Ctrl+Shift+L` to open a dialog. Type what you're working on and press **Save** or `Cmd+Enter`. Press **Cancel** or `Escape` to dismiss.

Use this for:
- Context that window titles don't capture ("discussing API design with team")
- Offline activities ("whiteboard session on architecture")
- Notes to yourself ("switched to working on the billing bug")

### Summaries

**Manual:** Press `Ctrl+Shift+S` or use the menu bar to generate a summary anytime.

**Automatic:** By default, a summary is generated at 5:30 PM on weekdays. Configure this in `config.lua`.

Summaries are saved to `summaries/YYYY-MM-DD.md` and include:
- **TLDR** — 3-4 sentence overview of how time was spent
- **Activity breakdown** — grouped by project with time ranges
- **Commits** — git commits from all active repos that day
- **PR activity** — GitHub PRs authored or reviewed

### Summary Browser

Use the menu bar "Browse Summaries" option to open a list of all past summaries. Click any entry to open it.

## Configuration

Edit `hammerspoon/config.lua`:

```lua
return {
    polling_interval = 30,            -- fallback polling interval in seconds
    log_hotkey_mods = {"ctrl", "shift"},
    log_hotkey_key = "L",
    summary_hotkey_mods = {"ctrl", "shift"},
    summary_hotkey_key = "S",
    auto_summary_enabled = true,      -- generate summary automatically
    auto_summary_time = "17:30",      -- time to auto-generate (24h format)
    auto_summary_days = {2,3,4,5,6},  -- days of week (1=Sun, 2=Mon, ..., 7=Sat)
    base_path = os.getenv("HOME") .. "/Projects/worklog",
    claude_path = os.getenv("HOME") .. "/.local/bin/claude",
}
```

After editing, reload Hammerspoon for changes to take effect.

## Custom Instructions

Edit `instructions.md` to guide how summaries are generated. For example:

```markdown
- Ignore Netflix, YouTube, and Spotify activity
- Group related activities together
- Highlight context switches between different projects
- Note time spent in meetings or communication tools
- Keep the summary concise but capture all meaningful work
```

## File Structure

```
worklog/
├── hammerspoon/
│   ├── activity_monitor.lua    # Main entry point
│   ├── activity_tracker.lua    # Event-driven window tracking
│   ├── activity_logger.lua     # Manual log entry webview dialog
│   ├── activity_summary.lua    # Summary generation and browser
│   └── config.lua              # All configurable settings
├── logs/                       # Daily activity logs (YYYY-MM-DD.jsonl)
├── summaries/                  # Daily summaries (YYYY-MM-DD.md)
├── instructions.md             # Custom instructions for summaries
└── README.md
```

## Log Format

Daily logs are JSONL files (`logs/YYYY-MM-DD.jsonl`) with one JSON object per line:

```json
{"time":"09:00:15","type":"track","app":"VS Code","bundle_id":"com.microsoft.VSCode","title":"worklog/init.lua","cwd":"~/Projects/worklog","git_repo":"~/Projects/worklog","git_branch":"main"}
{"time":"09:05:45","type":"track","app":"Google Chrome","bundle_id":"com.google.Chrome","title":"GitHub Pull Request #123"}
{"time":"10:30:00","type":"manual","text":"Discussed API design with team in standup"}
{"time":"12:30:00","type":"idle_start","idle_seconds":300}
{"time":"12:45:00","type":"idle_end"}
```
