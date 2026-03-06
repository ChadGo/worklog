local M = {}

local config = nil
local lastEntry = nil
local lastEntryTime = 0
local pollingTimer = nil
local windowFilter = nil

-- Minimum seconds between logging entries for the same app
local MIN_INTERVAL_SAME_APP = 5

function M.init(cfg)
    config = cfg
end

-- Normalize a window title by stripping noisy parts (spinners, dimensions, process info)
local function normalizeTitle(title)
    if not title then return "" end
    -- Strip common terminal spinner characters
    title = title:gsub("[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏⠂⠐✳◂▸]", "")
    -- Strip terminal dimension patterns like "162x47" or "82x22"
    title = title:gsub("%d+×%d+", "")
    -- Strip process info patterns like "node ◂ claude" / "caffeinate ◂ claude"
    title = title:gsub("caffeinate[^—]*", "")
    title = title:gsub("node[^—]*", "")
    -- Collapse multiple spaces/dashes
    title = title:gsub("%s+", " ")
    title = title:gsub("[—%-]%s*[—%-]", "—")
    title = title:gsub("^%s+", ""):gsub("%s+$", "")
    -- Strip trailing separators
    title = title:gsub("[—%-]%s*$", "")
    return title
end

local function getLogsDir()
    return config.logs_path or (config.base_path .. "/logs")
end

local function getLogPath()
    local date = os.date("%Y-%m-%d")
    return getLogsDir() .. "/" .. date .. ".jsonl"
end

local function logActivity(appName, windowTitle)
    if not appName or appName == "" then return end

    local normalized = normalizeTitle(windowTitle)
    local entry = appName .. "|" .. normalized
    local now = os.time()

    -- Deduplicate: skip if same normalized entry
    if entry == lastEntry then return end

    -- Throttle: if same app, require minimum interval
    if lastEntry and lastEntry:sub(1, #appName + 1) == appName .. "|" and (now - lastEntryTime) < MIN_INTERVAL_SAME_APP then
        return
    end

    lastEntry = entry
    lastEntryTime = now

    local path = getLogPath()
    local record = hs.json.encode({
        time = os.date("%H:%M:%S"),
        type = "track",
        app = appName,
        title = normalized,
    })

    local f = io.open(path, "a")
    if f then
        f:write(record .. "\n")
        f:close()
    end
end

local function captureCurrentWindow()
    local win = hs.window.focusedWindow()
    if not win then return end
    local app = win:application()
    if not app then return end
    logActivity(app:name(), win:title())
end

local function onWindowEvent(win, appName, event)
    if not win then return end
    local app = win:application()
    if not app then return end
    logActivity(app:name(), win:title())
end

function M.start()
    -- Event-driven tracking
    windowFilter = hs.window.filter.new(true)
    windowFilter:subscribe(hs.window.filter.windowFocused, onWindowEvent)
    windowFilter:subscribe(hs.window.filter.windowTitleChanged, onWindowEvent)

    -- Fallback polling timer
    pollingTimer = hs.timer.doEvery(config.polling_interval, captureCurrentWindow)

    -- Capture immediately
    captureCurrentWindow()
end

function M.stop()
    if windowFilter then
        windowFilter:unsubscribeAll()
        windowFilter = nil
    end
    if pollingTimer then
        pollingTimer:stop()
        pollingTimer = nil
    end
end

function M.getLogPath()
    return getLogPath()
end

return M
