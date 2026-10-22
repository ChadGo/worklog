-- Worklog defaults. Checked in; do not put machine-specific paths here.
--
-- Per-machine overrides go in hammerspoon/config.local.lua (gitignored).
-- install.sh writes that file with claude_path and gh_path resolved for
-- your machine. Any key below can be overridden there, e.g.
--
--   return {
--       claude_path = "/opt/homebrew/bin/claude",
--       auto_summary_time = "17:30",
--   }
return {
    polling_interval = 30,            -- fallback polling interval in seconds
    log_hotkey_mods = {"ctrl", "shift"},
    log_hotkey_key = "L",
    summary_hotkey_mods = {"ctrl", "shift"},
    summary_hotkey_key = "S",
    auto_summary_enabled = true,      -- generate summary automatically
    auto_summary_time = "00:00",      -- time to auto-generate (24h format)
    auto_summary_days = {1,2,3,4,5,6,7},  -- days of week (1=Sun ... 7=Sat); default every day, generating the previous day's summary at midnight
    base_path = nil,       -- defaults to the directory this repo is checked out in
    logs_path = nil,       -- defaults to base_path/logs
    summaries_path = nil,  -- defaults to base_path/summaries
    claude_path = nil,     -- path to the claude CLI; defaults to `command -v claude` in your login shell
    gh_path = nil,         -- path to the gh CLI; defaults to `command -v gh` in your login shell
}
