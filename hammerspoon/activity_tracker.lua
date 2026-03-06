local M = {}

local config = nil
local lastEntry = nil
local pollingTimer = nil
local windowFilter = nil

function M.init(cfg)
    config = cfg
end

local function getLogsDir()
    return config.logs_path or (config.base_path .. "/logs")
end

local function getLogPath()
    local date = os.date("%Y-%m-%d")
    return getLogsDir() .. "/" .. date .. ".md"
end

local function ensureLogFile(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return
    end
    local date = os.date("%Y-%m-%d")
    f = io.open(path, "w")
    if f then
        f:write("# Activity Log - " .. date .. "\n\n")
        f:write("## Tracked Activity\n\n")
        f:close()
    end
end

local function logActivity(appName, windowTitle)
    if not appName or appName == "" then return end

    local entry = appName .. " - " .. (windowTitle or "")
    if entry == lastEntry then return end
    lastEntry = entry

    local path = getLogPath()
    ensureLogFile(path)

    local timestamp = os.date("%H:%M:%S")
    local line = "- [" .. timestamp .. "] " .. entry .. "\n"

    -- Read existing content to insert before Manual Entries if it exists
    local f = io.open(path, "r")
    if not f then return end
    local content = f:read("*a")
    f:close()

    local manualPos = content:find("\n## Manual Entries\n")
    if manualPos then
        -- Insert before the Manual Entries section
        local before = content:sub(1, manualPos - 1)
        local after = content:sub(manualPos)
        f = io.open(path, "w")
        if f then
            f:write(before .. line .. after)
            f:close()
        end
    else
        -- Append to end
        f = io.open(path, "a")
        if f then
            f:write(line)
            f:close()
        end
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
