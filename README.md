# Activity Monitor

A Hammerspoon tool that tracks your computer activity throughout the day and generates markdown summaries using Claude CLI.

## What It Does

- **Automatic tracking** — monitors active application and window title in real time using Hammerspoon's window filter events, with a configurable polling fallback
- **Manual log entries** — hotkey opens a dialog to jot down context, offline work, meetings, or anything else
- **Daily summaries** — generates a markdown summary of your day via Claude CLI, either on demand or automatically at a scheduled time
- **Custom instructions** — tell the summary generator what to ignore, emphasize, or how to organize

## Setup

### Prerequisites

- [Hammerspoon](https://www.hammerspoon.org/) installed
- [Claude CLI](https://docs.anthropic.com/en/docs/claude-cli) installed and configured

### Installation

Add this line to `~/.hammerspoon/init.lua`:

```lua
dofile(os.getenv("HOME") .. "/Projects/activity-monitor/hammerspoon/activity_monitor.lua")
```

Reload Hammerspoon. You should see a `◉` icon in your menu bar and a "Tracking started" notification.

### Verify Claude CLI Path

The default config assumes `claude` is at `/usr/local/bin/claude`. Check with:

```sh
which claude
```

If it's elsewhere, update `claude_path` in `hammerspoon/config.lua`.

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
- Open today's log, logs folder, or summaries folder
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

Summaries are saved to `summaries/YYYY-MM-DD.md`.

## Configuration

Edit `hammerspoon/config.lua` to customize:

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
    base_path = os.getenv("HOME") .. "/Projects/activity-monitor",
    claude_path = "/usr/local/bin/claude",
}
```

After editing, reload Hammerspoon for changes to take effect.

## Custom Instructions

Edit `instructions.md` to guide how summaries are generated. For example:

```markdown
- Ignore Netflix, YouTube, and Spotify activity — this is background music/entertainment
- Group related activities together (e.g., all work on the same project)
- Highlight context switches between different projects
- Note time spent in meetings or communication tools
- Keep the summary concise but capture all meaningful work
```

## File Structure

```
activity-monitor/
├── hammerspoon/
│   ├── activity_monitor.lua    # Main entry point
│   ├── activity_tracker.lua    # Event-driven window tracking
│   ├── activity_logger.lua     # Manual log entry webview dialog
│   ├── activity_summary.lua    # Summary generation via Claude CLI
│   └── config.lua              # All configurable settings
├── logs/                       # Daily activity logs (YYYY-MM-DD.jsonl)
├── summaries/                  # Daily summaries (YYYY-MM-DD.md)
├── instructions.md             # Custom instructions for summaries
└── README.md
```

## Log Format

Daily logs are JSONL files (`logs/YYYY-MM-DD.jsonl`) with one JSON object per line:

```json
{"time":"09:00:15","type":"track","app":"VS Code","bundle_id":"com.microsoft.VSCode","title":"activity-monitor/init.lua","cwd":"~/Projects/activity-monitor"}
{"time":"09:05:45","type":"track","app":"Google Chrome","bundle_id":"com.google.Chrome","title":"GitHub Pull Request #123"}
{"time":"09:12:00","type":"track","app":"Terminal","bundle_id":"com.apple.Terminal","title":"zsh: npm test","cwd":"~/Projects/activity-monitor"}
{"time":"10:30:00","type":"manual","text":"Discussed API design with team in standup"}
{"time":"12:30:00","type":"idle_start","idle_seconds":300}
{"time":"12:45:00","type":"idle_end"}
{"time":"14:00:00","type":"manual","text":"Whiteboard session on caching strategy"}
```
