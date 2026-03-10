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
    return getSummariesDir() .. "/daily/" .. date .. ".md"
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

-- Parse unique git repos from the JSONL log, returning {display_path, expanded_path} pairs
local function parseRepos(logContent)
    if not logContent or logContent == "" then return {} end

    local repos = {}
    local seen = {}
    local home = os.getenv("HOME") or ""
    for line in logContent:gmatch("[^\n]+") do
        local repo = line:match('"git_repo":"([^"]+)"')
        if repo and not seen[repo] then
            seen[repo] = true
            local expanded = repo:gsub("\\/", "/")
            expanded = expanded:gsub("^~", home)
            table.insert(repos, {display = repo:gsub("\\/", "/"), path = expanded})
        end
    end
    return repos
end

-- Parse a HH:MM:SS time string to seconds since midnight
local function timeToSeconds(timeStr)
    local h, m, s = timeStr:match("(%d+):(%d+):(%d+)")
    if not h then return nil end
    return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
end

-- Format seconds into a human-readable duration
local function formatDuration(secs)
    if secs < 60 then return string.format("%ds", secs) end
    local hours = math.floor(secs / 3600)
    local mins = math.floor((secs % 3600) / 60)
    if hours > 0 then
        return string.format("%dh %dm", hours, mins)
    end
    return string.format("%dm", mins)
end

-- Max gap in seconds before we stop attributing time (e.g., bathroom break)
local MAX_GAP = 600  -- 10 minutes

-- Calculate time spent per project from a JSONL log string
-- Returns a sorted list of {project, seconds} and total tracked seconds
local function calculateProjectTime(logContent)
    if not logContent or logContent == "" then return {}, 0 end

    local entries = {}
    local inIdle = false

    for line in logContent:gmatch("[^\n]+") do
        local time = line:match('"time":"([^"]+)"')
        local entryType = line:match('"type":"([^"]+)"')
        if not time or not entryType then goto nextline end

        local secs = timeToSeconds(time)
        if not secs then goto nextline end

        if entryType == "idle_start" then
            inIdle = true
            table.insert(entries, {time = secs, project = nil, idle = true})
        elseif entryType == "idle_end" then
            inIdle = false
            table.insert(entries, {time = secs, project = nil, idle_end = true})
        elseif entryType == "track" and not inIdle then
            local repo = line:match('"git_repo":"([^"]+)"')
            local app = line:match('"app":"([^"]+)"')
            local project
            if repo then
                repo = repo:gsub("\\/", "/")
                project = repo:match("([^/]+)$") or repo
            else
                project = app or "Unknown"
            end
            table.insert(entries, {time = secs, project = project})
        elseif entryType == "manual" and not inIdle then
            table.insert(entries, {time = secs, project = nil, manual = true})
        end

        ::nextline::
    end

    -- Calculate time per project from consecutive entries
    local projectTime = {}
    local totalTracked = 0

    for i = 1, #entries - 1 do
        local cur = entries[i]
        local nxt = entries[i + 1]

        -- Skip idle entries
        if cur.idle or cur.idle_end or not cur.project then goto nextentry end

        local gap = nxt.time - cur.time
        -- Handle day wraparound
        if gap < 0 then gap = gap + 86400 end
        -- Cap the gap
        if gap > MAX_GAP then gap = MAX_GAP end
        -- Don't count time into idle
        if nxt.idle then
            gap = 0
        end

        projectTime[cur.project] = (projectTime[cur.project] or 0) + gap
        totalTracked = totalTracked + gap

        ::nextentry::
    end

    -- Sort by time descending
    local sorted = {}
    for project, secs in pairs(projectTime) do
        table.insert(sorted, {project = project, seconds = secs})
    end
    table.sort(sorted, function(a, b) return a.seconds > b.seconds end)

    return sorted, totalTracked
end

-- Format project time data as a readable string
local function formatProjectTime(projectTimes, totalTracked)
    if #projectTimes == 0 then return "" end

    local result = "Total tracked: " .. formatDuration(totalTracked) .. "\n\n"
    for _, pt in ipairs(projectTimes) do
        local pct = totalTracked > 0 and math.floor(pt.seconds / totalTracked * 100) or 0
        result = result .. string.format("- **%s**: %s (%d%%)\n", pt.project, formatDuration(pt.seconds), pct)
    end
    return result
end

-- Aggregate project time across multiple dates from their log files
local function aggregateProjectTime(dates)
    local totals = {}
    local grandTotal = 0

    for _, date in ipairs(dates) do
        local logPath = getLogPath(date)
        local logContent = readFile(logPath)
        if logContent and logContent ~= "" then
            local projectTimes, totalTracked = calculateProjectTime(logContent)
            grandTotal = grandTotal + totalTracked
            for _, pt in ipairs(projectTimes) do
                totals[pt.project] = (totals[pt.project] or 0) + pt.seconds
            end
        end
    end

    local sorted = {}
    for project, secs in pairs(totals) do
        table.insert(sorted, {project = project, seconds = secs})
    end
    table.sort(sorted, function(a, b) return a.seconds > b.seconds end)

    return sorted, grandTotal
end

-- Fetch git commits for the given date from each repo
local function getGitCommits(repos, date)
    if #repos == 0 then return "" end

    local result = ""
    for _, repo in ipairs(repos) do
        local cmd = string.format(
            "git -C '%s' log --all --since='%s 00:00:00' --until='%s 23:59:59' --format='%%h %%s' 2>/dev/null",
            repo.path, date, date
        )
        local output, status = hs.execute(cmd)
        if status and output and output ~= "" then
            local repoName = repo.display:match("([^/]+)$") or repo.display
            result = result .. "### " .. repoName .. " (" .. repo.display .. ")\n"
            result = result .. output .. "\n"
        end
    end
    return result
end

-- Fetch GitHub PR activity for the given date from each repo that has a GitHub remote
local function getPRActivity(repos, date)
    if #repos == 0 then return "" end

    local ghPath = config.gh_path or "gh"
    local result = ""

    for _, repo in ipairs(repos) do
        -- Check if repo has a GitHub remote
        local remote, remoteOk = hs.execute(string.format(
            "git -C '%s' remote get-url origin 2>/dev/null", repo.path
        ))
        if not remoteOk or not remote or not remote:match("github") then
            goto continue
        end

        local repoName = repo.display:match("([^/]+)$") or repo.display
        local section = ""

        -- PRs authored, updated today
        local authored, authOk = hs.execute(string.format(
            "%s pr list --repo '%s' --author @me --search 'updated:>=%s' --json number,title,state,url,updatedAt --limit 50 2>/dev/null",
            ghPath, repo.path, date
        ))
        if authOk and authored and authored ~= "" and authored ~= "[]\n" and authored ~= "[]" then
            section = section .. "**Authored:**\n" .. authored .. "\n"
        end

        -- PRs where I was requested as reviewer, updated today
        local reviewed, revOk = hs.execute(string.format(
            "%s pr list --repo '%s' --search 'reviewed-by:@me updated:>=%s' --json number,title,state,url,updatedAt --limit 50 2>/dev/null",
            ghPath, repo.path, date
        ))
        if revOk and reviewed and reviewed ~= "" and reviewed ~= "[]\n" and reviewed ~= "[]" then
            section = section .. "**Reviewed:**\n" .. reviewed .. "\n"
        end

        if section ~= "" then
            result = result .. "### " .. repoName .. " (" .. repo.display .. ")\n" .. section
        end

        ::continue::
    end

    return result
end

local function writeFile(path, content)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(content)
    f:close()
    return true
end

-- Ensure a directory exists, creating it if needed
local function ensureDir(dir)
    hs.execute(string.format("mkdir -p '%s'", dir))
end

-- Run a prompt through Claude CLI async, writing result to outputPath
local function runClaude(prompt, outputPath, label)
    hs.notify.new({
        title = "Worklog",
        informativeText = "Generating " .. label .. "..."
    }):send()

    local tmpPath = os.tmpname()
    writeFile(tmpPath, prompt)

    local claudePath = config.claude_path or "claude"
    local cmd = string.format(
        "cat '%s' | '%s' --print 2>&1; rm -f '%s'",
        tmpPath, claudePath, tmpPath
    )

    hs.task.new("/bin/zsh", function(exitCode, stdOut, stdErr)
        if exitCode == 0 and stdOut and stdOut ~= "" then
            ensureDir(outputPath:match("(.+)/"))
            writeFile(outputPath, stdOut)
            hs.notify.new({
                title = "Worklog",
                informativeText = label .. " saved",
                actionButtonTitle = "Open",
                hasActionButton = true,
            }):send()
        else
            local errMsg = stdErr or stdOut or "Unknown error"
            hs.notify.new({
                title = "Worklog",
                informativeText = label .. " failed: " .. errMsg:sub(1, 100)
            }):send()
        end
    end, {"-c", cmd}):start()
end

-- Collect daily summary contents for a list of date strings
local function collectDailySummaries(dates)
    local summariesDir = getSummariesDir()
    local collected = ""
    for _, date in ipairs(dates) do
        local path = summariesDir .. "/daily/" .. date .. ".md"
        local content = readFile(path)
        if content and content ~= "" then
            collected = collected .. content .. "\n\n---\n\n"
        end
    end
    return collected
end

-- Get all dates in a given ISO week (Mon-Sun) for a reference date
local function getWeekDates(date)
    -- Parse the date
    local y, m, d = date:match("(%d+)-(%d+)-(%d+)")
    local t = os.time({year = tonumber(y), month = tonumber(m), day = tonumber(d)})
    -- os.date wday: 1=Sun, 2=Mon, ..., 7=Sat
    local wday = tonumber(os.date("%w", t)) -- 0=Sun, 1=Mon, ..., 6=Sat
    -- Find Monday of this week
    local mondayOffset = wday == 0 and -6 or (1 - wday)
    local monday = t + mondayOffset * 86400

    local dates = {}
    for i = 0, 6 do
        table.insert(dates, os.date("%Y-%m-%d", monday + i * 86400))
    end
    local friday = os.date("%Y-%m-%d", monday + 4 * 86400)
    return dates, friday  -- returns dates and Friday date as the week label
end

-- Get all dates in a given month
local function getMonthDates(yearMonth)
    local y, m = yearMonth:match("(%d+)-(%d+)")
    y, m = tonumber(y), tonumber(m)
    local dates = {}
    for day = 1, 31 do
        local t = os.time({year = y, month = m, day = day})
        -- Verify we haven't rolled into the next month
        if tonumber(os.date("%m", t)) == m then
            table.insert(dates, os.date("%Y-%m-%d", t))
        end
    end
    return dates
end

-- Get all months in a given year
local function getYearMonths(year)
    local months = {}
    for m = 1, 12 do
        table.insert(months, string.format("%s-%02d", year, m))
    end
    return months
end

function M.generate(date)
    date = date or os.date("%Y-%m-%d")
    local logPath = getLogPath(date)
    local logContent = readFile(logPath)

    if not logContent or logContent == "" then
        hs.notify.new({
            title = "Worklog",
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

    local projectTimes, totalTracked = calculateProjectTime(logContent)
    local timeBreakdown = formatProjectTime(projectTimes, totalTracked)
    if timeBreakdown ~= "" then
        prompt = prompt .. "## Time Breakdown\n\n" .. timeBreakdown .. "\n"
        prompt = prompt .. "Use this data for the time breakdown in the summary. These are calculated from the log timestamps.\n\n"
    end

    local repos = parseRepos(logContent)

    local gitCommits = getGitCommits(repos, date)
    if gitCommits ~= "" then
        prompt = prompt .. "## Git Commits Made Today\n\n" .. gitCommits .. "\n"
        prompt = prompt .. "Use these commits to understand what was actually accomplished in each project. "
        prompt = prompt .. "The commit messages provide concrete details about the work done.\n\n"
    end

    local prActivity = getPRActivity(repos, date)
    if prActivity ~= "" then
        prompt = prompt .. "## GitHub PR Activity Today\n\n" .. prActivity .. "\n"
        prompt = prompt .. "Include PR activity in the summary — PRs opened, updated, reviewed, or merged.\n\n"
    else
        prompt = prompt .. "## GitHub PR Activity Today\n\nNo PR activity found.\n\n"
    end

    prompt = prompt .. "## Task\n\n"
    prompt = prompt .. "Write a concise markdown summary of what was worked on today. "
    prompt = prompt .. "Group related activities together. Include approximate time ranges. "
    prompt = prompt .. "Include a '## Time Breakdown' section showing time per project with percentages. "
    prompt = prompt .. "Include a '## Commits' section that lists all git commits grouped by project. "
    prompt = prompt .. "For each commit, show the short hash and message. If a commit message is long, summarize it briefly. "
    prompt = prompt .. "Use headers and bullet points. Start the document with `# Summary - " .. date .. "`. "
    prompt = prompt .. "Immediately after the title, include a '## TLDR' section with 3-4 sentences summarizing where most time was spent. "
    prompt = prompt .. "Focus on the big picture — e.g. 'Spent most of the day in meetings, with the rest focused on X' or 'Deep work day primarily on X and Y'. "
    prompt = prompt .. "Output ONLY the markdown summary, no preamble or explanation."

    runClaude(prompt, getSummaryPath(date), "Summary for " .. date)
end

function M.generateWeekly(date)
    date = date or os.date("%Y-%m-%d")
    local dates, weekLabel = getWeekDates(date)
    local content = collectDailySummaries(dates)

    if content == "" then
        hs.notify.new({title = "Worklog", informativeText = "No daily summaries found for week of " .. weekLabel}):send()
        return
    end

    local weekTimes, weekTotal = aggregateProjectTime(dates)
    local weekTimeStr = formatProjectTime(weekTimes, weekTotal)

    local instructions = readFile(getInstructionsPath()) or ""
    local prompt = "You are generating a weekly summary from daily work summaries.\n\n"
    if instructions ~= "" then
        prompt = prompt .. "## Custom Instructions\n\n" .. instructions .. "\n\n"
    end
    prompt = prompt .. "## Daily Summaries\n\n" .. content .. "\n"
    if weekTimeStr ~= "" then
        prompt = prompt .. "## Weekly Time Breakdown\n\n" .. weekTimeStr .. "\n"
        prompt = prompt .. "These are aggregated from daily activity logs.\n\n"
    end
    prompt = prompt .. "## Task\n\n"
    prompt = prompt .. "Write a concise weekly summary covering " .. dates[1] .. " through " .. dates[5] .. " (Mon-Fri). "
    prompt = prompt .. "Start with `# Weekly Summary - " .. dates[1] .. " to " .. dates[5] .. "`. "
    prompt = prompt .. "Immediately after the title, include a '## TLDR' with 3-4 sentences on the week's highlights. "
    prompt = prompt .. "Include a '## Time Breakdown' section showing total time per project for the week with percentages. "
    prompt = prompt .. "Then group by project or theme. Highlight key accomplishments, PRs merged, and patterns (e.g. heavy meeting days vs deep work days). "
    prompt = prompt .. "Output ONLY the markdown summary, no preamble or explanation."

    local outputPath = getSummariesDir() .. "/weekly/" .. weekLabel .. ".md"
    runClaude(prompt, outputPath, "Weekly summary " .. weekLabel)
end

function M.generateMonthly(yearMonth)
    yearMonth = yearMonth or os.date("%Y-%m")
    local dates = getMonthDates(yearMonth)
    local content = collectDailySummaries(dates)

    if content == "" then
        hs.notify.new({title = "Worklog", informativeText = "No daily summaries found for " .. yearMonth}):send()
        return
    end

    local instructions = readFile(getInstructionsPath()) or ""
    local prompt = "You are generating a monthly summary from daily work summaries.\n\n"
    if instructions ~= "" then
        prompt = prompt .. "## Custom Instructions\n\n" .. instructions .. "\n\n"
    end

    local monthTimes, monthTotal = aggregateProjectTime(dates)
    local monthTimeStr = formatProjectTime(monthTimes, monthTotal)

    prompt = prompt .. "## Daily Summaries\n\n" .. content .. "\n"
    if monthTimeStr ~= "" then
        prompt = prompt .. "## Monthly Time Breakdown\n\n" .. monthTimeStr .. "\n"
        prompt = prompt .. "These are aggregated from daily activity logs.\n\n"
    end
    prompt = prompt .. "## Task\n\n"
    prompt = prompt .. "Write a concise monthly summary for " .. yearMonth .. ". "
    prompt = prompt .. "Start with `# Monthly Summary - " .. yearMonth .. "`. "
    prompt = prompt .. "Immediately after the title, include a '## TLDR' with 4-5 sentences on the month's highlights. "
    prompt = prompt .. "Include a '## Time Breakdown' section showing total time per project for the month with percentages. "
    prompt = prompt .. "Then organize by project or major theme. Highlight key accomplishments, milestones, and how time was distributed. "
    prompt = prompt .. "Note trends — what took the most time, what was recurring, any shifts in focus. "
    prompt = prompt .. "Output ONLY the markdown summary, no preamble or explanation."

    local outputPath = getSummariesDir() .. "/monthly/" .. yearMonth .. ".md"
    runClaude(prompt, outputPath, "Monthly summary " .. yearMonth)
end

function M.generateYearly(year)
    year = year or os.date("%Y")
    local months = getYearMonths(year)
    local summariesDir = getSummariesDir()
    local content = ""

    for _, ym in ipairs(months) do
        local path = summariesDir .. "/monthly/" .. ym .. ".md"
        local c = readFile(path)
        if c and c ~= "" then
            content = content .. c .. "\n\n---\n\n"
        end
    end

    -- Fall back to daily summaries if no monthly summaries exist
    if content == "" then
        for _, ym in ipairs(months) do
            local dates = getMonthDates(ym)
            content = content .. collectDailySummaries(dates)
        end
    end

    if content == "" then
        hs.notify.new({title = "Worklog", informativeText = "No summaries found for " .. year}):send()
        return
    end

    local instructions = readFile(getInstructionsPath()) or ""
    local prompt = "You are generating a yearly summary from monthly (or daily) work summaries.\n\n"
    if instructions ~= "" then
        prompt = prompt .. "## Custom Instructions\n\n" .. instructions .. "\n\n"
    end
    prompt = prompt .. "## Summaries\n\n" .. content .. "\n"
    prompt = prompt .. "## Task\n\n"
    prompt = prompt .. "Write a yearly summary for " .. year .. ". "
    prompt = prompt .. "Start with `# Yearly Summary - " .. year .. "`. "
    prompt = prompt .. "Immediately after the title, include a '## TLDR' with 5-6 sentences on the year's highlights. "
    prompt = prompt .. "Organize by quarter or major theme. Highlight key projects, accomplishments, and how focus shifted over the year. "
    prompt = prompt .. "Output ONLY the markdown summary, no preamble or explanation."

    local outputPath = summariesDir .. "/yearly/" .. year .. ".md"
    runClaude(prompt, outputPath, "Yearly summary " .. year)
end

-- Scan logs dir for all dates that have log files
local function getAllLogDates()
    local logsDir = getLogsDir()
    local output, status = hs.execute(string.format("ls -1 '%s'/*.jsonl 2>/dev/null", logsDir))
    local dates = {}
    if status and output and output ~= "" then
        for path in output:gmatch("[^\n]+") do
            local date = path:match("(%d%d%d%d%-%d%d%-%d%d)%.jsonl$")
            if date then table.insert(dates, date) end
        end
    end
    table.sort(dates)
    return dates
end

-- Run a list of {fn, args} tasks staggered by delay seconds
local function runStaggered(tasks, delay)
    for i, task in ipairs(tasks) do
        hs.timer.doAfter((i - 1) * delay, function()
            task.fn(task.arg)
        end)
    end
    local total = #tasks
    hs.notify.new({
        title = "Worklog",
        informativeText = string.format("Queued %d summary generation(s), ~%ds apart", total, delay)
    }):send()
end

function M.regenerateAllDaily()
    local dates = getAllLogDates()
    if #dates == 0 then
        hs.notify.new({title = "Worklog", informativeText = "No log files found"}):send()
        return
    end
    local tasks = {}
    for _, date in ipairs(dates) do
        table.insert(tasks, {fn = M.generate, arg = date})
    end
    runStaggered(tasks, 30)
end

function M.regenerateAllWeekly()
    local dates = getAllLogDates()
    if #dates == 0 then
        hs.notify.new({title = "Worklog", informativeText = "No log files found"}):send()
        return
    end
    -- Find unique weeks
    local seen = {}
    local tasks = {}
    for _, date in ipairs(dates) do
        local _, weekLabel = getWeekDates(date)
        if not seen[weekLabel] then
            seen[weekLabel] = true
            table.insert(tasks, {fn = M.generateWeekly, arg = date})
        end
    end
    runStaggered(tasks, 30)
end

function M.regenerateAllMonthly()
    local dates = getAllLogDates()
    if #dates == 0 then
        hs.notify.new({title = "Worklog", informativeText = "No log files found"}):send()
        return
    end
    -- Find unique months
    local seen = {}
    local tasks = {}
    for _, date in ipairs(dates) do
        local ym = date:sub(1, 7)
        if not seen[ym] then
            seen[ym] = true
            table.insert(tasks, {fn = M.generateMonthly, arg = ym})
        end
    end
    runStaggered(tasks, 30)
end

function M.regenerateAllYearly()
    local dates = getAllLogDates()
    if #dates == 0 then
        hs.notify.new({title = "Worklog", informativeText = "No log files found"}):send()
        return
    end
    -- Find unique years
    local seen = {}
    local tasks = {}
    for _, date in ipairs(dates) do
        local y = date:sub(1, 4)
        if not seen[y] then
            seen[y] = true
            table.insert(tasks, {fn = M.generateYearly, arg = y})
        end
    end
    runStaggered(tasks, 30)
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

            -- At midnight, generate for yesterday since the date has rolled over
            local summaryDate = today
            if now.hour == 0 then
                local yesterday = os.time(now) - 86400
                summaryDate = os.date("%Y-%m-%d", yesterday)
            end

            M.generate(summaryDate)

            -- Weekly summary on Saturdays at midnight (end of Friday)
            -- or Fridays if not running at midnight
            local isWeekEnd = (now.hour == 0 and now.wday == 7) or (now.hour ~= 0 and now.wday == 6)
            if isWeekEnd then
                hs.timer.doAfter(120, function() M.generateWeekly(summaryDate) end)
            end

            -- Monthly summary when the previous day was the last day of its month
            local prevDay = os.time(now) - (now.hour == 0 and 86400 or 0)
            local prevMonth = tonumber(os.date("%m", prevDay))
            local nextDay = prevDay + 86400
            local nextMonth = tonumber(os.date("%m", nextDay))
            if prevMonth ~= nextMonth then
                hs.timer.doAfter(180, function() M.generateMonthly(os.date("%Y-%m", prevDay)) end)
            end
        end
    end)
end

function M.stopAutoSummary()
    if autoSummaryTimer then
        autoSummaryTimer:stop()
        autoSummaryTimer = nil
    end
end

-- Summary browser webview
local browserWebview = nil

function M.showBrowser()
    if browserWebview then
        browserWebview:delete()
        browserWebview = nil
    end

    local summariesDir = getSummariesDir()

    -- Scan all subdirectories for summary files
    local categories = {
        {dir = "daily",   label = "Daily"},
        {dir = "weekly",  label = "Weekly"},
        {dir = "monthly", label = "Monthly"},
        {dir = "yearly",  label = "Yearly"},
    }

    local files = {}
    for _, cat in ipairs(categories) do
        local dirPath = summariesDir .. "/" .. cat.dir
        local output, status = hs.execute(string.format("ls -1r '%s'/*.md 2>/dev/null", dirPath))
        if status and output and output ~= "" then
            for path in output:gmatch("[^\n]+") do
                local filename = path:match("([^/]+)$")
                local name = filename:match("^(.+)%.md$")
                if name then
                    local content = readFile(path) or ""
                    local preview = ""
                    local lineCount = 0
                    for line in content:gmatch("[^\n]+") do
                        if lineCount > 0 and line ~= "" and not line:match("^#") then
                            preview = line:sub(1, 120)
                            break
                        end
                        lineCount = lineCount + 1
                    end
                    table.insert(files, {
                        date = name,
                        path = path,
                        preview = preview,
                        label = cat.label,
                    })
                end
            end
        end
    end

    -- Build HTML
    local items = ""
    if #files == 0 then
        items = '<div class="empty">No summaries yet</div>'
    else
        for _, f in ipairs(files) do
            local escaped_preview = f.preview:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
            items = items .. string.format(
                '<a class="item" href="#" onclick="openFile(\'%s\'); return false;">'
                .. '<div class="date"><span class="label">%s</span> %s</div>'
                .. '<div class="preview">%s</div>'
                .. '</a>',
                f.path, f.label, f.date, escaped_preview
            )
        end
    end

    local html = [[
<!DOCTYPE html>
<html>
<head>
<style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
        background: #1e1e1e;
        color: #cccccc;
        padding: 16px;
        -webkit-user-select: none;
    }
    h2 { font-size: 14px; font-weight: 600; color: #ffffff; margin-bottom: 12px; }
    .list { overflow-y: auto; max-height: 350px; }
    .item {
        display: block;
        padding: 10px 12px;
        border-radius: 6px;
        text-decoration: none;
        color: #cccccc;
        border: 1px solid #333;
        margin-bottom: 6px;
        cursor: pointer;
    }
    .item:hover { background: #2d2d2d; border-color: #007acc; }
    .date { font-size: 14px; font-weight: 600; color: #ffffff; }
    .preview { font-size: 12px; color: #888; margin-top: 4px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .label { font-size: 11px; background: #333; color: #aaa; padding: 2px 6px; border-radius: 3px; margin-right: 6px; }
    .empty { color: #666; font-size: 13px; padding: 20px 0; text-align: center; }
</style>
</head>
<body>
    <h2>Summaries</h2>
    <div class="list">]] .. items .. [[</div>
    <script>
        function openFile(path) {
            window.webkit.messageHandlers.hammerspoon.postMessage("open:" + path);
        }
        document.addEventListener("keydown", function(e) {
            if (e.key === "Escape") {
                window.webkit.messageHandlers.hammerspoon.postMessage("close");
            }
        });
    </script>
</body>
</html>
]]

    local screen = hs.screen.mainScreen():frame()
    local width = 500
    local height = 450
    local rect = hs.geometry.rect(
        (screen.w - width) / 2,
        (screen.h - height) / 2,
        width,
        height
    )

    local uc = hs.webview.usercontent.new("hammerspoon")
    uc:setCallback(function(msg)
        local body = msg.body
        if type(body) == "string" and body:sub(1, 5) == "open:" then
            local path = body:sub(6)
            hs.execute("open '" .. path .. "'")
            if browserWebview then
                browserWebview:delete()
                browserWebview = nil
            end
        elseif body == "close" then
            if browserWebview then
                browserWebview:delete()
                browserWebview = nil
            end
        end
    end)

    browserWebview = hs.webview.new(rect, {developerExtrasEnabled = false}, uc)
    browserWebview:windowStyle(
        hs.webview.windowMasks.titled |
        hs.webview.windowMasks.closable
    )
    browserWebview:windowTitle("Worklog - Summaries")
    browserWebview:allowTextEntry(true)
    browserWebview:level(hs.drawing.windowLevels.floating)
    browserWebview:darkMode(true)
    browserWebview:html(html)
    browserWebview:show()
    browserWebview:bringToFront(true)
end

return M
