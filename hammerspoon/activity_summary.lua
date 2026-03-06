local M = {}

local config = nil
local autoSummaryTimer = nil

function M.init(cfg)
    config = cfg
end

local function getLogsDir()
    return config.logs_path or (config.base_path .. "/logs")
end

local function getSummariesDir()
    return config.summaries_path or (config.base_path .. "/summaries")
end

local function getLogPath(date)
    date = date or os.date("%Y-%m-%d")
    return getLogsDir() .. "/" .. date .. ".jsonl"
end

local function getSummaryPath(date)
    date = date or os.date("%Y-%m-%d")
    return getSummariesDir() .. "/" .. date .. ".md"
end

local function getInstructionsPath()
    return config.base_path .. "/instructions.md"
end

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local function writeFile(path, content)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(content)
    f:close()
    return true
end

function M.generate(date)
    date = date or os.date("%Y-%m-%d")
    local logPath = getLogPath(date)
    local logContent = readFile(logPath)

    if not logContent or logContent == "" then
        hs.notify.new({
            title = "Activity Monitor",
            informativeText = "No activity log found for " .. date
        }):send()
        return
    end

    local instructions = readFile(getInstructionsPath()) or ""

    local prompt = "You are summarizing a day's computer activity log into a concise markdown summary.\n\n"
    prompt = prompt .. "The log is in JSONL format. Each line is a JSON object with these fields:\n"
    prompt = prompt .. '- type "track": automatic window tracking with "time", "app", "bundle_id", "title", and optionally "cwd" (working directory), "git_repo" (project root), "git_branch" (current branch)\n'
    prompt = prompt .. '- type "manual": user-written log entry with "time", "text"\n'
    prompt = prompt .. '- type "idle_start": user went idle, with "idle_seconds"\n'
    prompt = prompt .. '- type "idle_end": user returned from idle\n'
    prompt = prompt .. 'The "cwd" field indicates the working directory. "git_repo" and "git_branch" indicate the project and branch being worked on. Use these to group activities by project.\n\n'

    if instructions ~= "" then
        prompt = prompt .. "## Custom Instructions\n\n" .. instructions .. "\n\n"
    end

    prompt = prompt .. "## Activity Log\n\n```\n" .. logContent .. "```\n\n"
    prompt = prompt .. "## Task\n\n"
    prompt = prompt .. "Write a concise markdown summary of what was worked on today. "
    prompt = prompt .. "Group related activities together. Include approximate time ranges. "
    prompt = prompt .. "Use headers and bullet points. Start the document with `# Summary - " .. date .. "`. "
    prompt = prompt .. "Output ONLY the markdown summary, no preamble or explanation."

    hs.notify.new({
        title = "Activity Monitor",
        informativeText = "Generating summary for " .. date .. "..."
    }):send()

    -- Write prompt to a temp file to avoid shell escaping issues
    local tmpPath = os.tmpname()
    writeFile(tmpPath, prompt)

    local claudePath = config.claude_path or "claude"
    local summaryPath = getSummaryPath(date)
    local cmd = string.format(
        "cat '%s' | '%s' --print 2>&1; rm -f '%s'",
        tmpPath, claudePath, tmpPath
    )

    -- Run async to avoid blocking Hammerspoon
    hs.task.new("/bin/zsh", function(exitCode, stdOut, stdErr)
        if exitCode == 0 and stdOut and stdOut ~= "" then
            writeFile(summaryPath, stdOut)
            hs.notify.new({
                title = "Activity Monitor",
                informativeText = "Summary saved for " .. date,
                actionButtonTitle = "Open",
                hasActionButton = true,
            }):send()
        else
            local errMsg = stdErr or stdOut or "Unknown error"
            hs.notify.new({
                title = "Activity Monitor",
                informativeText = "Summary generation failed: " .. errMsg:sub(1, 100)
            }):send()
        end
    end, {"-c", cmd}):start()
end

function M.startAutoSummary()
    if not config.auto_summary_enabled then return end
    if autoSummaryTimer then
        autoSummaryTimer:stop()
    end

    -- Check every 60 seconds if it's time to generate
    local generated = {}
    autoSummaryTimer = hs.timer.doEvery(60, function()
        local now = os.date("*t")
        local today = os.date("%Y-%m-%d")
        local timeStr = string.format("%02d:%02d", now.hour, now.min)

        -- Check if today is an enabled day
        local dayEnabled = false
        for _, d in ipairs(config.auto_summary_days or {}) do
            if d == now.wday then
                dayEnabled = true
                break
            end
        end

        if dayEnabled and timeStr == config.auto_summary_time and not generated[today] then
            generated[today] = true
            M.generate(today)
        end
    end)
end

function M.stopAutoSummary()
    if autoSummaryTimer then
        autoSummaryTimer:stop()
        autoSummaryTimer = nil
    end
end

return M
