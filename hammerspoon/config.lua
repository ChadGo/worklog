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
    claude_path = os.getenv("HOME") .. "/.local/bin/claude",  -- path to claude CLI
}
