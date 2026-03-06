local M = {}

local config = nil
local lastEntry = nil
local lastEntryTime = 0
local wasIdle = false
local pollingTimer = nil
local windowFilter = nil

-- Minimum seconds between logging entries for the same app
local MIN_INTERVAL_SAME_APP = 5
-- Seconds of inactivity before considered idle
local IDLE_THRESHOLD = 300

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

-- Get the deepest child process's working directory for a PID.
-- For terminals, this finds the shell (or command running in it) rather than the terminal app itself.
local function getWorkingDirectory(pid)
    if not pid then return nil end

    -- Find the deepest child process (e.g., terminal -> shell -> running command)
    local deepestPid = pid
    local visited = {}
    while true do
        if visited[deepestPid] then break end
        visited[deepestPid] = true
        local childOutput, childStatus = hs.execute(string.format("pgrep -P %d 2>/dev/null | head -1", deepestPid))
        if childStatus and childOutput and childOutput:match("%d+") then
            deepestPid = tonumber(childOutput:match("%d+"))
        else
            break
        end
    end

    local output, status = hs.execute(string.format("lsof -d cwd -p %d -Fn 2>/dev/null | grep ^n | head -1 | cut -c2-", deepestPid))
    if status and output and output ~= "" then
        return output:gsub("%s+$", "")
    end
    return nil
end

-- Find the git repo root and current branch for a directory
local function getGitInfo(dir)
    if not dir then return nil, nil end
    -- Expand ~ for shell commands
    local expanded = dir:gsub("^~", os.getenv("HOME") or "~")
    local root, rootStatus = hs.execute(string.format("git -C '%s' rev-parse --show-toplevel 2>/dev/null", expanded))
    if not rootStatus or not root or root == "" then return nil, nil end
    root = root:gsub("%s+$", "")

    local branch, branchStatus = hs.execute(string.format("git -C '%s' rev-parse --abbrev-ref HEAD 2>/dev/null", expanded))
    if branchStatus and branch and branch ~= "" then
        branch = branch:gsub("%s+$", "")
    else
        branch = nil
    end

    return root, branch
end

local function appendLog(record)
    local path = getLogPath()
    local line = hs.json.encode(record)
    local f = io.open(path, "a")
    if f then
        f:write(line .. "\n")
        f:close()
    end
end

local function logActivity(appName, bundleID, windowTitle, pid)
    if not appName or appName == "" then return end

    -- Check idle state
    local idleTime = hs.host.idleTime()
    if idleTime >= IDLE_THRESHOLD then
        if not wasIdle then
            wasIdle = true
            appendLog({
                time = os.date("%H:%M:%S"),
                type = "idle_start",
                idle_seconds = math.floor(idleTime),
            })
        end
        return
    end

    if wasIdle then
        wasIdle = false
        appendLog({
            time = os.date("%H:%M:%S"),
            type = "idle_end",
        })
        -- Reset dedup so the current window gets logged after returning
        lastEntry = nil
    end

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

    local record = {
        time = os.date("%H:%M:%S"),
        type = "track",
        app = appName,
        bundle_id = bundleID,
        title = normalized,
    }

    -- Get working directory from the deepest child process
    local cwd = getWorkingDirectory(pid)
    if cwd and cwd ~= "/" then
        local home = os.getenv("HOME")

        -- Check for git repo before shortening
        local gitRoot, gitBranch = getGitInfo(cwd)
        if gitRoot then
            -- Shorten git root path
            if home and gitRoot:sub(1, #home) == home then
                gitRoot = "~" .. gitRoot:sub(#home + 1)
            end
            record.git_repo = gitRoot
            record.git_branch = gitBranch
        end

        -- Shorten cwd
        if home and cwd:sub(1, #home) == home then
            cwd = "~" .. cwd:sub(#home + 1)
        end
        record.cwd = cwd
    end

    appendLog(record)
end

local function captureCurrentWindow()
    local win = hs.window.focusedWindow()
    if not win then return end
    local app = win:application()
    if not app then return end
    logActivity(app:name(), app:bundleID(), win:title(), app:pid())
end

local function onWindowEvent(win, appName, event)
    if not win then return end
    local app = win:application()
    if not app then return end
    logActivity(app:name(), app:bundleID(), win:title(), app:pid())
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
