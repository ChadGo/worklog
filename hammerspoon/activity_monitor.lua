-- Worklog for Hammerspoon
-- Tracks application usage and generates daily summaries

-- Resolve the repo root from this file's own location so the checkout can
-- live anywhere. debug.getinfo gives "@/abs/path/hammerspoon/activity_monitor.lua".
local scriptPath = debug.getinfo(1, "S").source:gsub("^@", "")
local basePath = scriptPath:match("^(.*)/hammerspoon/[^/]+$")
    or (os.getenv("HOME") .. "/Projects/worklog")

-- Load checked-in defaults, then overlay the gitignored per-machine file
-- that install.sh writes (claude_path, gh_path, and any personal overrides).
local config = dofile(basePath .. "/hammerspoon/config.lua")
local localConfigPath = basePath .. "/hammerspoon/config.local.lua"
local localConfigFile = io.open(localConfigPath, "r")
if localConfigFile then
    localConfigFile:close()
    local ok, overrides = pcall(dofile, localConfigPath)
    if ok and type(overrides) == "table" then
        for k, v in pairs(overrides) do config[k] = v end
    else
        hs.notify.new({title = "Worklog", informativeText = "config.local.lua failed to load: " .. tostring(overrides)}):send()
    end
end

config.base_path = config.base_path or basePath

-- Hammerspoon's own PATH is minimal, so a bare "claude" or "gh" usually will
-- not resolve. Fall back to the user's login shell to find the binary.
local function resolveCommand(name)
    local out, ok = hs.execute("command -v " .. name, true)
    if ok and out and out ~= "" then
        return (out:gsub("%s+$", ""))
    end
    return name
end
config.claude_path = config.claude_path or resolveCommand("claude")
config.gh_path = config.gh_path or resolveCommand("gh")

-- Writes use io.open(path, "a"), which silently fails if the directory is
-- missing. logs/ and summaries/ are gitignored, so create them up front.
local function ensureDir(dir)
    hs.execute(string.format("mkdir -p '%s'", dir))
end
ensureDir(config.logs_path or (config.base_path .. "/logs"))
local summariesDir = config.summaries_path or (config.base_path .. "/summaries")
for _, level in ipairs({"daily", "weekly", "monthly", "yearly"}) do
    ensureDir(summariesDir .. "/" .. level)
end

local tracker = dofile(basePath .. "/hammerspoon/activity_tracker.lua")
local logger = dofile(basePath .. "/hammerspoon/activity_logger.lua")
local summary = dofile(basePath .. "/hammerspoon/activity_summary.lua")

-- Initialize components
tracker.init(config)
logger.init(config)
summary.init(config)

-- Hotkeys
hs.hotkey.bind(config.log_hotkey_mods, config.log_hotkey_key, function()
    logger.show()
end)

hs.hotkey.bind(config.summary_hotkey_mods, config.summary_hotkey_key, function()
    summary.generate()
end)

-- Menu bar
local menubar = hs.menubar.new()
local isTracking = true

local function updateMenuIcon()
    if isTracking then
        menubar:setTitle("◉")
    else
        menubar:setTitle("◎")
    end
end

local function buildMenu()
    return {
        {
            title = isTracking and "⏸ Pause Tracking" or "▶ Resume Tracking",
            fn = function()
                if isTracking then
                    tracker.stop()
                    summary.stopAutoSummary()
                    isTracking = false
                else
                    tracker.start()
                    summary.startAutoSummary()
                    isTracking = true
                end
                updateMenuIcon()
            end
        },
        { title = "-" },
        {
            title = "📝 New Log Entry",
            fn = function() logger.show() end
        },
        {
            title = "📊 Generate",
            menu = {
                {title = "Today's Summary", fn = function() summary.generate() end},
                {title = "Summary for Date...", fn = function() summary.showDatePicker() end},
                {title = "This Week", fn = function() summary.generateWeekly() end},
                {title = "This Month", fn = function() summary.generateMonthly() end},
                {title = "This Year", fn = function() summary.generateYearly() end},
                {title = "-"},
                {title = "Regenerate All Daily", fn = function() summary.regenerateAllDaily() end},
                {title = "Regenerate All Weekly", fn = function() summary.regenerateAllWeekly() end},
                {title = "Regenerate All Monthly", fn = function() summary.regenerateAllMonthly() end},
                {title = "Regenerate All Yearly", fn = function() summary.regenerateAllYearly() end},
            }
        },
        { title = "-" },
        {
            title = "📂 Open Today's Log",
            fn = function()
                local path = tracker.getLogPath()
                hs.execute("open '" .. path .. "'")
            end
        },
        {
            title = "📂 Browse Summaries",
            fn = function() summary.showBrowser() end
        },
        {
            title = "📂 Open Logs",
            fn = function()
                hs.execute("open '" .. (config.logs_path or (config.base_path .. "/logs")) .. "'")
            end
        },
        { title = "-" },
        {
            title = "⚙ Edit Instructions",
            fn = function()
                local path = config.base_path .. "/instructions.md"
                hs.execute("open '" .. path .. "'")
            end
        },
    }
end

menubar:setMenu(buildMenu)
updateMenuIcon()

-- Start tracking
tracker.start()
summary.startAutoSummary()

hs.notify.new({
    title = "Worklog",
    informativeText = "Tracking started"
}):send()
