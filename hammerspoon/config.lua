return {
    polling_interval = 30,            -- fallback polling interval in seconds
    log_hotkey_mods = {"ctrl", "shift"},
    log_hotkey_key = "L",
    summary_hotkey_mods = {"ctrl", "shift"},
    summary_hotkey_key = "S",
    auto_summary_enabled = true,      -- generate summary automatically
    auto_summary_time = "00:00",      -- time to auto-generate (24h format)
    auto_summary_days = {1,2,3,4,5,6,7},  -- every day (generates previous day's summary at midnight)
    base_path = os.getenv("HOME") .. "/Projects/worklog",
    logs_path = nil,       -- defaults to base_path/logs
    summaries_path = nil,  -- defaults to base_path/summaries
    claude_path = os.getenv("HOME") .. "/.local/bin/claude",  -- path to claude CLI
}
