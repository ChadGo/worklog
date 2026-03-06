-- Activity Monitor for Hammerspoon
-- Tracks application usage and generates daily summaries

local basePath = os.getenv("HOME") .. "/Projects/activity-monitor"
local config = dofile(basePath .. "/hammerspoon/config.lua")

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
            title = "📊 Generate Summary",
            fn = function() summary.generate() end
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
            title = "📂 Open Summaries",
            fn = function()
                hs.execute("open '" .. config.base_path .. "/summaries'")
            end
        },
        {
            title = "📂 Open Logs",
            fn = function()
                hs.execute("open '" .. config.base_path .. "/logs'")
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
    title = "Activity Monitor",
    informativeText = "Tracking started"
}):send()
