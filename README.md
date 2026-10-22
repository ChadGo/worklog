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

- macOS with [Homebrew](https://brew.sh)
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and signed in. The installer checks for it but does not install it, because the first run has to be interactive:

```sh
curl -fsSL https://claude.ai/install.sh | bash
claude   # sign in once, then exit
```

Hammerspoon and the GitHub CLI (`gh`) are installed by the script if missing.

### Installation

1. Clone this repo anywhere you like (the location is detected at runtime):

```sh
git clone <repo-url> ~/Projects/worklog
cd ~/Projects/worklog
```

2. Run the installer. It is idempotent; re-run it any time.

```sh
./install.sh
```

It will:

- install Hammerspoon and `gh` via Homebrew if they are missing
- check that `claude` and `gh` are signed in and tell you if not
- create the gitignored `logs/` and `summaries/` folders
- write `hammerspoon/config.local.lua` with the absolute paths to `claude` and `gh`
- create a starter `instructions.local.md` for your personal rules
- add the loader line to `~/.hammerspoon/init.lua` and reload Hammerspoon

3. Grant Hammerspoon **Accessibility** access when macOS asks (System Settings > Privacy & Security > Accessibility). Without it, window titles come back empty and the log is useless.

4. Look for the `◉` icon in your menu bar and a "Tracking started" notification. After a few minutes, press `Ctrl+Shift+S` to generate a test summary.

To remove the Hammerspoon hook and generated config, run `./uninstall.sh`. It asks before touching `logs/` or `summaries/`.

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

**Automatic:** By default, the previous day's summary is generated at midnight every day. If the Mac is asleep at that time, it runs as soon as the Mac is awake again (weekly and monthly summaries catch up the same way). Configure the time and days in `config.lua`.

Summaries are saved to `summaries/YYYY-MM-DD.md` and include:
- **TLDR** — 3-4 sentence overview of how time was spent
- **Activity breakdown** — grouped by project with time ranges
- **Commits** — git commits from all active repos that day
- **PR activity** — GitHub PRs authored or reviewed

### Summary Browser

Use the menu bar "Browse Summaries" option to open a list of all past summaries. Click any entry to open it.

## Configuration

Defaults live in `hammerspoon/config.lua` and are checked in. Do not edit that file for personal settings. Put overrides in `hammerspoon/config.local.lua` (gitignored, created by `install.sh`). Any key from the defaults can be overridden there:

```lua
return {
    claude_path = "/opt/homebrew/bin/claude",  -- written by install.sh
    gh_path = "/opt/homebrew/bin/gh",          -- written by install.sh
    auto_summary_time = "17:30",
    auto_summary_days = {2,3,4,5,6},           -- weekdays only
}
```

Available keys and their defaults:

| Key | Default | Notes |
|---|---|---|
| `polling_interval` | `30` | Fallback polling interval in seconds |
| `log_hotkey_mods`, `log_hotkey_key` | `{"ctrl","shift"}`, `"L"` | Manual log entry hotkey |
| `summary_hotkey_mods`, `summary_hotkey_key` | `{"ctrl","shift"}`, `"S"` | Generate today's summary |
| `auto_summary_enabled` | `true` | Generate summaries automatically |
| `auto_summary_time` | `"00:00"` | 24h time; at midnight it summarizes the previous day |
| `auto_summary_days` | `{1,2,3,4,5,6,7}` | 1=Sun ... 7=Sat |
| `base_path` | repo checkout dir | Detected from the script's own location |
| `logs_path` | `base_path/logs` | |
| `summaries_path` | `base_path/summaries` | |
| `claude_path` | `command -v claude` | Resolved in your login shell at startup if unset |
| `gh_path` | `command -v gh` | Resolved in your login shell at startup if unset |

Hammerspoon runs with a minimal `PATH`, which is why the CLI paths are baked in as absolute paths rather than left as bare commands.

After editing, reload Hammerspoon (menu bar icon > Reload Config) for changes to take effect. Re-run `./install.sh` after upgrading or moving `claude` or `gh` to refresh the paths.

## Custom Instructions

Two files guide how summaries are generated. Both are merged into every prompt.

- `instructions.md` is checked in and shared. Keep it generic.
- `instructions.local.md` is gitignored and yours. Put your tools, ticket prefixes, and what to ignore here. Use a `## All` section for every summary level, or `## Daily`, `## Weekly`, `## Monthly`, `## Yearly` for one level. `###` subheaders inside a section are fine.

Example `instructions.local.md`:

```markdown
## All

- Ignore Reddit, Netflix, YouTube, and Spotify activity

### Development tools to fold into the active git project/branch

- **Browser on localtest.me** — testing locally, associate with the most recent git branch
- **DBeaver** — database access, associate with the most recent git project
- **Loom** — recording PR walkthroughs, associate with the most recent branch/PR

## Weekly

- Call out which days had no commits
```

## Performance Reviews

Drafts live in `reviews/` (gitignored, like `logs/` and `summaries/`). One file per cycle, e.g.
`reviews/h1-2026-self-review.md`.

Structure each draft so it survives being picked up weeks later:

- One `##` section per review question, with the final answer in a blockquote.
- A **Supporting facts** block under each answer listing the evidence and where it came from.
- A note on anything deliberately left out, and why.
- A final checklist for form fields that aren't free text (ratings, radio buttons).

### Where the evidence comes from

| Question type | Source |
|---|---|
| What shipped | `gh pr list --author "@me" --state merged --search "merged:START..END"` |
| Review load | `gh search prs --reviewed-by "@me" --created START..END` |
| What you worked on | `summaries/daily/*.md` — the `## TLDR` section of each |
| Themes over time | `summaries/monthly/*.md` and `summaries/weekly/*.md` |
| Time and pace | `logs/*.jsonl` — sum durations between `track` events |
| AI tool usage | `~/.claude/history.jsonl` — every prompt, with timestamps |

### Gotchas

These cost real time to discover. Read them before trusting a number.

- **Don't count mentions in summaries as usage.** The summaries are generated prose, so word
  frequency measures how the summarizer phrased things, not what happened. Go to `logs/` or
  `~/.claude/history.jsonl` instead.
- **`~/.claude/projects/*/*.jsonl` only retains about 30 days.** Session counts from it look like
  an adoption curve and are really just retention. `~/.claude/history.jsonl` goes back much
  further and is the honest record.
- **Terminal app-time is not AI tool usage.** Switching from one terminal to another shows up as a
  dramatic jump in app-time while actual Claude usage is flat. Claude runs *inside* whatever
  terminal or editor is in use.
- **Evening hours overstate pressure if you flex your schedule.** Finishing up after dinner by
  choice looks identical in the logs to being forced to. Weekend days worked are the more honest
  signal, since those don't flex away.
- **`summaries/daily/` has gaps.** Missing days are usually tooling or auth failures, not days
  off. Check `logs/` for the same date before concluding nothing happened.

### Useful one-liners

```sh
# TLDRs for a date range
for f in summaries/daily/2026-0[456]-*.md; do
  echo "### $f"; awk '/^## TLDR/{f=1;next}/^## /{f=0}f' "$f"
done

# Merged PRs per month
gh pr list --repo ORG/REPO --author "@me" --state merged --limit 400 \
  --search "merged:2026-04-01..2026-09-30" --json mergedAt \
  --jq '.[].mergedAt[0:7]' | sort | uniq -c

# Claude prompts per month
python3 -c "
import json,collections,datetime
c=collections.Counter()
for l in open('$HOME/.claude/history.jsonl',errors='ignore'):
    try: t=json.loads(l)['timestamp']
    except: continue
    c[datetime.datetime.fromtimestamp(t/1000).strftime('%Y-%m')]+=1
[print(m,c[m]) for m in sorted(c)]"
```

## File Structure

```
worklog/
├── install.sh                  # Idempotent setup (deps, dirs, config.local.lua, init.lua hook)
├── uninstall.sh                # Remove the hook and generated config
├── hammerspoon/
│   ├── activity_monitor.lua    # Main entry point; resolves paths, loads config, creates dirs
│   ├── activity_tracker.lua    # Event-driven window tracking
│   ├── activity_logger.lua     # Manual log entry webview dialog
│   ├── activity_summary.lua    # Summary generation and browser
│   ├── config.lua              # Checked-in defaults
│   └── config.local.lua        # Per-machine overrides (gitignored, written by install.sh)
├── prompts/                    # Summary prompt templates (daily, weekly, monthly, yearly)
├── logs/                       # Daily activity logs (YYYY-MM-DD.jsonl, gitignored)
├── summaries/                  # daily/, weekly/, monthly/, yearly/ (gitignored)
├── reviews/                    # Performance review drafts (gitignored)
├── instructions.md             # Shared summary instructions (checked in)
├── instructions.local.md       # Your personal summary instructions (gitignored)
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
