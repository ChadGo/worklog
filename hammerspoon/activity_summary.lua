local M = {}

local config = nil
local autoSummaryTimer = nil
local wakeWatcher = nil

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

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local function fileExists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

local function getInstructionsPath()
    return config.base_path .. "/instructions.md"
end

local function getLocalInstructionsPath()
    return config.base_path .. "/instructions.local.md"
end

-- Parse a section from instructions.local.md by header name.
-- Returns the lines under "## <section>" up to the next "## " header or EOF.
-- Line-based so that ### subheaders stay inside their section and an empty
-- section returns "" instead of leaking the next header.
local function parseLocalSection(content, section)
    if not content or content == "" then return "" end
    local inSection = false
    local lines = {}
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        local header = line:match("^##%s+(.-)%s*$")
        local isLevel2 = header ~= nil and not line:match("^###")
        if isLevel2 then
            if inSection then break end
            inSection = (header == section)
        elseif inSection then
            lines[#lines + 1] = line
        end
    end
    local text = table.concat(lines, "\n")
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Get combined instructions for a given level (daily, weekly, monthly, yearly)
local function getInstructions(level)
    local base = readFile(getInstructionsPath()) or ""
    local local_content = readFile(getLocalInstructionsPath()) or ""

    local extra = ""
    if local_content ~= "" then
        local all = parseLocalSection(local_content, "All")
        local specific = parseLocalSection(local_content, level:sub(1,1):upper() .. level:sub(2))
        if all ~= "" then extra = all end
        if specific ~= "" then
            extra = extra ~= "" and (extra .. "\n\n" .. specific) or specific
        end
    end

    if extra ~= "" then
        base = base ~= "" and (base .. "\n\n" .. extra) or extra
    end

    return base
end

local function getPromptPath(name)
    return config.base_path .. "/prompts/" .. name .. ".md"
end

-- Load a prompt template and substitute {{key}} placeholders
local function loadPrompt(name, vars)
    local template = readFile(getPromptPath(name))
    if not template then return nil end
    for key, value in pairs(vars) do
        template = template:gsub("{{" .. key .. "}}", function() return value end)
    end
    return template
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

-- Apps/patterns that should be attributed to the most recent git project
local DEV_TOOL_PATTERNS = {
    {app = "Google Chrome", title_pattern = "localtest%.me"},
    {app = "DBeaver"},
    {app = "Loom"},
}

-- Check if a log entry is a dev tool that should be grouped with the last git project
local function isDevTool(app, title)
    for _, pattern in ipairs(DEV_TOOL_PATTERNS) do
        if app == pattern.app then
            if pattern.title_pattern then
                if title and title:match(pattern.title_pattern) then
                    return true
                end
            else
                return true
            end
        end
    end
    return false
end

-- Calculate time spent per project from a JSONL log string
-- Returns a sorted list of {project, seconds}, total tracked seconds, and total active seconds
local function getCommsPath(date)
    return getSummariesDir() .. "/context/" .. date .. ".md"
end

-- Read meetings from the "## Zoom" section of a Slack and Zoom collection.
-- Headings look like "### Eng Roundtable (09:42 to 11:02)" in local 24h time.
-- Returns a sorted list of non-overlapping {name, start, finish} in seconds.
local function parseMeetings(commsContent)
    local meetings = {}
    if not commsContent or commsContent == "" then return meetings end

    local inZoom = false
    for line in (commsContent .. "\n"):gmatch("([^\n]*)\n") do
        if line:match("^##%s") and not line:match("^###") then
            inZoom = line:match("^##%s+Zoom") ~= nil
        elseif inZoom then
            local name, h1, m1, h2, m2 = line:match("^###%s+(.-)%s*%((%d%d?):(%d%d)%s*%S+%s*(%d%d?):(%d%d)%)%s*$")
            if name then
                local start = tonumber(h1) * 3600 + tonumber(m1) * 60
                local finish = tonumber(h2) * 3600 + tonumber(m2) * 60
                if finish > start then
                    table.insert(meetings, {name = name, start = start, finish = finish})
                end
            end
        end
    end

    -- Clip overlaps so no second is counted twice.
    table.sort(meetings, function(a, b) return a.start < b.start end)
    local lastEnd = 0
    local clipped = {}
    for _, m in ipairs(meetings) do
        if m.start < lastEnd then m.start = lastEnd end
        if m.finish > m.start then
            table.insert(clipped, m)
            lastEnd = m.finish
        end
    end
    return clipped
end

local function meetingOverlap(meetings, from, to)
    local total = 0
    for _, m in ipairs(meetings) do
        local o = math.min(to, m.finish) - math.max(from, m.start)
        if o > 0 then total = total + o end
    end
    return total
end

-- Time per project from the activity log. Meetings (from Zoom) take priority:
-- a meeting's whole span counts as meeting time, including idle stretches and
-- time when another window was in front, and that time is removed from
-- whatever app was frontmost.
local function calculateProjectTime(logContent, meetings)
    if not logContent or logContent == "" then return {}, 0, 0 end
    meetings = meetings or {}

    local entries = {}
    local inIdle = false
    local lastGitProject = nil

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
            local title = line:match('"title":"([^"]*)"')
            local project

            if repo then
                repo = repo:gsub("\\/", "/")
                project = repo:match("([^/]+)$") or repo
                lastGitProject = project
            elseif isDevTool(app, title) and lastGitProject then
                -- Attribute dev tools to the most recent git project
                project = lastGitProject
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
    local totalActive = 0

    for i = 1, #entries - 1 do
        local cur = entries[i]
        local nxt = entries[i + 1]

        -- Skip idle entries
        if cur.idle or cur.idle_end then goto nextentry end

        local gap = nxt.time - cur.time
        -- Handle day wraparound
        if gap < 0 then gap = gap + 86400 end
        -- Cap the gap
        if gap > MAX_GAP then gap = MAX_GAP end
        -- Don't count time into idle
        if nxt.idle then
            gap = 0
        end

        -- Time inside a meeting belongs to the meeting, not the frontmost app.
        if gap > 0 and #meetings > 0 then
            gap = gap - meetingOverlap(meetings, cur.time, cur.time + gap)
        end

        totalActive = totalActive + gap

        if cur.project then
            projectTime[cur.project] = (projectTime[cur.project] or 0) + gap
            totalTracked = totalTracked + gap
        end

        ::nextentry::
    end

    for _, m in ipairs(meetings) do
        local key = "Meeting: " .. m.name
        local dur = m.finish - m.start
        projectTime[key] = (projectTime[key] or 0) + dur
        totalTracked = totalTracked + dur
        totalActive = totalActive + dur
    end

    -- Sort by time descending
    local sorted = {}
    for project, secs in pairs(projectTime) do
        table.insert(sorted, {project = project, seconds = secs})
    end
    table.sort(sorted, function(a, b) return a.seconds > b.seconds end)

    return sorted, totalTracked, totalActive
end

-- Format project time data as a readable string
local function formatProjectTime(projectTimes, totalTracked, totalActive)
    if #projectTimes == 0 then return "" end

    local result = ""
    for _, pt in ipairs(projectTimes) do
        local pct = totalTracked > 0 and math.floor(pt.seconds / totalTracked * 100) or 0
        result = result .. string.format("- **%s**: %s (%d%%)\n", pt.project, formatDuration(pt.seconds), pct)
    end
    result = result .. "\n"
    result = result .. "**Total project time**: " .. formatDuration(totalTracked) .. "\n"
    result = result .. "**Total active time**: " .. formatDuration(totalActive or totalTracked) .. "\n"
    return result
end

-- Aggregate project time across multiple dates from their log files
local function aggregateProjectTime(dates)
    local totals = {}
    local grandTotal = 0
    local grandActive = 0

    for _, date in ipairs(dates) do
        local logPath = getLogPath(date)
        local logContent = readFile(logPath)
        if logContent and logContent ~= "" then
            local meetings = parseMeetings(readFile(getCommsPath(date)))
            local projectTimes, totalTracked, totalActive = calculateProjectTime(logContent, meetings)
            grandTotal = grandTotal + totalTracked
            grandActive = grandActive + totalActive
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

    return sorted, grandTotal, grandActive
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

-- Run a prompt through Claude CLI async, writing result to outputPath.
-- onDone (optional) is called once the run finishes, whether it succeeded or not.
local function runClaude(prompt, outputPath, label, onDone)
    hs.notify.new({
        title = "Worklog",
        informativeText = "Generating " .. label .. "..."
    }):send()

    local tmpPath = os.tmpname()
    writeFile(tmpPath, prompt)

    local claudePath = config.claude_path or "claude"
    -- caffeinate -i keeps the Mac from idle-sleeping mid-run. If it sleeps
    -- anyway (lid closed), the CLI prints an error and still exits 0.
    local cmd = string.format(
        "cat '%s' | /usr/bin/caffeinate -i '%s' --print 2>&1; rm -f '%s'",
        tmpPath, claudePath, tmpPath
    )

    hs.task.new("/bin/zsh", function(exitCode, stdOut, stdErr)
        -- Only a markdown document counts as a summary. Anything else (such as
        -- "API Error: Your computer went to sleep mid-response") is a failure,
        -- so no file is written and the next catch-up retries it.
        local out = stdOut or ""
        local startAt = out:find("^#") or out:find("\n#")
        if exitCode == 0 and startAt then
            ensureDir(outputPath:match("(.+)/"))
            writeFile(outputPath, (out:sub(startAt):gsub("^\n", "")))
            hs.notify.new({
                title = "Worklog",
                informativeText = label .. " saved",
                actionButtonTitle = "Open",
                hasActionButton = true,
            }):send()
        else
            local errMsg = (stdErr ~= "" and stdErr) or (out ~= "" and out) or "Unknown error"
            hs.notify.new({
                title = "Worklog",
                informativeText = label .. " failed: " .. errMsg:sub(1, 100)
            }):send()
        end
        if onDone then onDone() end
    end, {"-c", cmd}):start()
end

-- Slack and Zoom collection ------------------------------------------------
--
-- Runs Claude headless with read-only Slack and Zoom connector tools to gather
-- the day's business conversations from Slack channels and Zoom meeting notes.
-- The result is saved to summaries/context/<date>.md and fed into the daily
-- summary prompt. Any failure is non-fatal: the summary runs without it.

local COMMS_ALLOWED_TOOLS = {
    "ToolSearch",
    "mcp__claude_ai_Slack__slack_search_public_and_private",
    "mcp__claude_ai_Slack__slack_search_public",
    "mcp__claude_ai_Slack__slack_search_channels",
    "mcp__claude_ai_Slack__slack_search_users",
    "mcp__claude_ai_Slack__slack_read_thread",
    "mcp__claude_ai_Slack__slack_read_channel",
    "mcp__claude_ai_Slack__slack_read_user_profile",
    "mcp__claude_ai_Zoom_for_Claude__search",
    "mcp__claude_ai_Zoom_for_Claude__search_describe_capabilities",
    "mcp__claude_ai_Zoom_for_Claude__search_meetings",
    "mcp__claude_ai_Zoom_for_Claude__get_meeting_assets",
    "mcp__claude_ai_Zoom_for_Claude__my_notes_get_note_content",
    "mcp__claude_ai_Zoom_for_Claude__recordings_list",
}

-- Belt and braces: nothing outside the allow list runs in --print mode, but
-- deny anything that writes in case a user-level rule ever allows it.
local COMMS_DISALLOWED_TOOLS = {
    "Bash", "Edit", "Write", "NotebookEdit", "WebFetch", "WebSearch", "Agent",
    "mcp__claude_ai_Slack__slack_send_message",
    "mcp__claude_ai_Slack__slack_send_message_draft",
    "mcp__claude_ai_Slack__slack_schedule_message",
    "mcp__claude_ai_Slack__slack_add_reaction",
    "mcp__claude_ai_Slack__slack_create_canvas",
    "mcp__claude_ai_Slack__slack_update_canvas",
    "mcp__claude_ai_Slack__slack_create_conversation",
    "mcp__claude_ai_Slack__slack_create_list",
    "mcp__claude_ai_Slack__slack_update_list",
    "mcp__claude_ai_Slack__slack_add_list_record",
    "mcp__claude_ai_Slack__slack_update_list_record",
    "mcp__claude_ai_Slack__slack_get_file_upload_url",
    "mcp__claude_ai_Slack__slack_complete_file_upload",
    "mcp__claude_ai_Zoom_for_Claude__meeting_create",
    "mcp__claude_ai_Zoom_for_Claude__meeting_update",
    "mcp__claude_ai_Zoom_for_Claude__meeting_delete",
    "mcp__claude_ai_Zoom_for_Claude__in_meeting_control",
    "mcp__claude_ai_Zoom_for_Claude__capabilities_invoke_write",
    "mcp__claude_ai_Zoom_for_Claude__create_new_file_with_markdown",
    "mcp__claude_ai_Zoom_for_Claude__hub_create_file_from_content",
    "mcp__claude_ai_Zoom_for_Claude__canvas_add_file_collaborators",
    "mcp__claude_ai_Zoom_for_Claude__canvas_modify_file_collaborator_role",
    "mcp__claude_ai_Zoom_for_Claude__canvas_remove_file_collaborator",
}

local function shellQuote(str)
    return "'" .. tostring(str):gsub("'", "'\\''") .. "'"
end

-- callback(markdown) on success, callback(nil, reason) otherwise.
local function collectComms(date, instructions, callback)
    if config.comms_enabled == false then
        callback(nil, "disabled")
        return
    end

    local path = getCommsPath(date)

    -- A finished day does not change, so reuse a complete collection. Today is
    -- still in progress, and a collection with an unavailable source is retried.
    if date < os.date("%Y-%m-%d") then
        local cached = readFile(path)
        if cached and cached ~= "" and not cached:find("UNAVAILABLE:", 1, true) then
            callback(cached)
            return
        end
    end

    local prompt = loadPrompt("comms", {
        date = date,
        tz_offset = os.date("%z"),
        instructions = instructions ~= "" and ("## The user's summary instructions\n\nApply these when deciding what is relevant.\n\n" .. instructions) or "",
    })
    if not prompt then
        callback(nil, "missing prompts/comms.md")
        return
    end

    hs.notify.new({title = "Worklog", informativeText = "Collecting Slack and Zoom for " .. date .. "..."}):send()

    local dir = path:match("(.+)/")
    ensureDir(dir)
    local tmpPath = os.tmpname()
    writeFile(tmpPath, prompt)

    local claudePath = config.claude_path or "claude"
    local timeout = tonumber(config.comms_timeout) or 300
    -- Run from the context folder so no project settings or CLAUDE.md load.
    -- perl's alarm caps the run so a hung connector cannot stall the summary.
    local cmd = string.format(
        "cd %s && /usr/bin/caffeinate -i perl -e 'alarm shift; exec @ARGV' %d %s --print --allowedTools %s --disallowedTools %s < %s; rc=$?; rm -f %s; exit $rc",
        shellQuote(dir), timeout, shellQuote(claudePath),
        shellQuote(table.concat(COMMS_ALLOWED_TOOLS, ",")),
        shellQuote(table.concat(COMMS_DISALLOWED_TOOLS, ",")),
        shellQuote(tmpPath), shellQuote(tmpPath)
    )

    hs.task.new("/bin/zsh", function(exitCode, stdOut, stdErr)
        local out = stdOut or ""
        local startAt = out:find("# Communications", 1, true)
        if exitCode == 0 and startAt then
            local content = out:sub(startAt)
            writeFile(path, content)
            callback(content)
        else
            local reason = exitCode == 142 and ("timed out after " .. timeout .. "s")
                or ((stdErr ~= "" and stdErr) or out):gsub("%s+", " "):sub(1, 150)
            if reason == "" then reason = "exit code " .. tostring(exitCode) end
            -- Keep the details next to the context file for troubleshooting.
            writeFile(path:gsub("%.md$", ".error.txt"), string.format(
                "exit code: %s\nreason: %s\n\n--- stderr ---\n%s\n\n--- stdout ---\n%s\n",
                tostring(exitCode), reason, stdErr or "", out))
            callback(nil, reason)
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

-- Exposed so the collection can be run on its own for troubleshooting.
function M.collectComms(date, callback)
    collectComms(date, getInstructions("daily"), callback or function() end)
end

function M.generate(date, onDone)
    date = date or os.date("%Y-%m-%d")
    local function finish()
        if onDone then onDone() end
    end
    local logPath = getLogPath(date)
    local logContent = readFile(logPath)

    if not logContent or logContent == "" then
        hs.notify.new({
            title = "Worklog",
            informativeText = "No activity log found for " .. date
        }):send()
        finish()
        return
    end

    local instructions = getInstructions("daily")
    local instructionsBlock = instructions ~= "" and ("## Custom Instructions\n\n" .. instructions) or ""

    local repos = parseRepos(logContent)

    local gitCommits = getGitCommits(repos, date)
    local commitsBlock = gitCommits ~= "" and ("## Git Commits Made Today\n\n" .. gitCommits .. "\nUse these commits to understand what was actually accomplished in each project. The commit messages provide concrete details about the work done.") or ""

    local prActivity = getPRActivity(repos, date)
    local prBlock = prActivity ~= "" and ("## GitHub PR Activity Today\n\n" .. prActivity .. "\nInclude PR activity in the summary — PRs opened, updated, reviewed, or merged.") or "## GitHub PR Activity Today\n\nNo PR activity found."

    collectComms(date, instructions, function(comms, reason)
        local meetings = parseMeetings(comms)
        local projectTimes, totalTracked, totalActive = calculateProjectTime(logContent, meetings)
        local timeBreakdown = formatProjectTime(projectTimes, totalTracked, totalActive)
        local timeBlock = ""
        if timeBreakdown ~= "" then
            timeBlock = "## Time Breakdown\n\n" .. timeBreakdown
                .. "\nUse this data for the time breakdown in the summary. These are calculated from the log timestamps."
            if #meetings > 0 then
                timeBlock = timeBlock .. " \"Meeting:\" rows use the real meeting times from Zoom. Each meeting's full span counts as meeting time, even when another window was in front, and that time has been removed from the other rows."
            end
        end

        local commsBlock = ""
        if comms then
            commsBlock = "## Slack and Zoom\n\n"
                .. "Business conversations from Slack channels (no direct messages) and Zoom meeting notes for this day, already filtered to work topics.\n"
                .. "Use them to add detail to the matching activities. If a source below says UNAVAILABLE, end the summary with a one-line note saying that source was unavailable.\n\n"
                .. comms
        elseif reason ~= "disabled" then
            commsBlock = "## Slack and Zoom\n\nSlack and Zoom could not be collected for this day (" .. reason .. "). "
                .. "End the summary with a one-line note saying Slack and Zoom were unavailable."
        end

        local prompt = loadPrompt("daily", {
            instructions = instructionsBlock,
            log = logContent,
            time_breakdown = timeBlock,
            git_commits = commitsBlock,
            pr_activity = prBlock,
            comms = commsBlock,
            date = date,
        })

        if not prompt then
            hs.notify.new({title = "Worklog", informativeText = "Missing prompt template: prompts/daily.md"}):send()
            finish()
            return
        end

        runClaude(prompt, getSummaryPath(date), "Summary for " .. date, finish)
    end)
end

function M.generateWeekly(date)
    date = date or os.date("%Y-%m-%d")
    local dates, weekLabel = getWeekDates(date)
    local content = collectDailySummaries(dates)

    if content == "" then
        hs.notify.new({title = "Worklog", informativeText = "No daily summaries found for week of " .. weekLabel}):send()
        return
    end

    local weekTimes, weekTotal, weekActive = aggregateProjectTime(dates)
    local weekTimeStr = formatProjectTime(weekTimes, weekTotal, weekActive)
    local timeBlock = weekTimeStr ~= "" and ("## Weekly Time Breakdown\n\n" .. weekTimeStr .. "\nThese are aggregated from daily activity logs.") or ""

    local instructions = getInstructions("weekly")
    local instructionsBlock = instructions ~= "" and ("## Custom Instructions\n\n" .. instructions) or ""

    local prompt = loadPrompt("weekly", {
        instructions = instructionsBlock,
        content = content,
        time_breakdown = timeBlock,
        start_date = dates[1],
        end_date = dates[5],
    })

    if not prompt then
        hs.notify.new({title = "Worklog", informativeText = "Missing prompt template: prompts/weekly.md"}):send()
        return
    end

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

    local instructions = getInstructions("monthly")
    local instructionsBlock = instructions ~= "" and ("## Custom Instructions\n\n" .. instructions) or ""

    local monthTimes, monthTotal, monthActive = aggregateProjectTime(dates)
    local monthTimeStr = formatProjectTime(monthTimes, monthTotal, monthActive)
    local timeBlock = monthTimeStr ~= "" and ("## Monthly Time Breakdown\n\n" .. monthTimeStr .. "\nThese are aggregated from daily activity logs.") or ""

    local prompt = loadPrompt("monthly", {
        instructions = instructionsBlock,
        content = content,
        time_breakdown = timeBlock,
        year_month = yearMonth,
    })

    if not prompt then
        hs.notify.new({title = "Worklog", informativeText = "Missing prompt template: prompts/monthly.md"}):send()
        return
    end

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

    local instructions = getInstructions("yearly")
    local instructionsBlock = instructions ~= "" and ("## Custom Instructions\n\n" .. instructions) or ""

    local prompt = loadPrompt("yearly", {
        instructions = instructionsBlock,
        content = content,
        year = year,
    })

    if not prompt then
        hs.notify.new({title = "Worklog", informativeText = "Missing prompt template: prompts/yearly.md"}):send()
        return
    end

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

-- Which date the scheduled run should summarize. When the run time is in the
-- midnight hour the date has already rolled over, so summarize yesterday.
local function scheduledSummaryDate(now)
    local cfgHour = tonumber((config.auto_summary_time or "00:00"):match("^(%d+)")) or 0
    local t = os.time({year = now.year, month = now.month, day = now.day, hour = 12})
    if cfgHour == 0 then
        t = os.time({year = now.year, month = now.month, day = now.day - 1, hour = 12})
    end
    return os.date("%Y-%m-%d", t), t
end

-- Generate whatever the scheduled run should have produced and hasn't yet.
-- Uses file existence as the guard, so it is safe to call after a missed run
-- (machine asleep at the scheduled time) without duplicating work.
local function runScheduledSummaries(onDone)
    onDone = onDone or function() end
    local now = os.date("*t")
    local summaryDate, summaryTime = scheduledSummaryDate(now)
    local st = os.date("*t", summaryTime)

    -- Weekly and monthly read the daily summaries, so they start only after
    -- the daily summary (including Slack and Zoom collection) has finished.
    local function runRollups()
        -- Weekly: when the summarized day is a Friday
        if st.wday == 6 then
            local _, weekLabel = getWeekDates(summaryDate)
            if not fileExists(getSummariesDir() .. "/weekly/" .. weekLabel .. ".md") then
                M.generateWeekly(summaryDate)
            end
        end

        -- Monthly: when the summarized day is the last day of its month
        local nextDayMonth = tonumber(os.date("%m", summaryTime + 86400))
        if nextDayMonth ~= st.month then
            local yearMonth = os.date("%Y-%m", summaryTime)
            if not fileExists(getSummariesDir() .. "/monthly/" .. yearMonth .. ".md") then
                hs.timer.doAfter(60, function() M.generateMonthly(yearMonth) end)
            end
        end
        onDone()
    end

    -- Daily
    if fileExists(getLogPath(summaryDate)) and not fileExists(getSummaryPath(summaryDate)) then
        -- If the daily summary failed, hold the rollups so they do not run
        -- without it; the next catch-up retries both.
        M.generate(summaryDate, function()
            if fileExists(getSummaryPath(summaryDate)) then runRollups() else onDone() end
        end)
    else
        runRollups()
    end
end

function M.startAutoSummary()
    if not config.auto_summary_enabled then return end
    M.stopAutoSummary()

    -- Once per day, at or after auto_summary_time, run the scheduled summaries.
    -- "At or after" (rather than exact-minute match) means a run missed while
    -- the machine was asleep happens as soon as it is awake again.
    local ran = {}
    local running = false
    local function check()
        local now = os.date("*t")
        local today = os.date("%Y-%m-%d")
        if ran[today] or running then return end

        local dayEnabled = false
        for _, d in ipairs(config.auto_summary_days or {}) do
            if d == now.wday then dayEnabled = true break end
        end
        if not dayEnabled then return end

        local timeStr = string.format("%02d:%02d", now.hour, now.min)
        if timeStr < (config.auto_summary_time or "00:00") then return end

        ran[today] = true
        running = true
        runScheduledSummaries(function() running = false end)
    end

    autoSummaryTimer = hs.timer.doEvery(60, check)

    -- Timers do not fire while asleep; re-check shortly after waking so the
    -- catch-up does not wait for the next tick.
    wakeWatcher = hs.caffeinate.watcher.new(function(event)
        if event == hs.caffeinate.watcher.systemDidWake then
            -- Retry on every wake: a run that failed (for example because the
            -- Mac slept mid-run) left no file, so it is picked up again here.
            ran = {}
            hs.timer.doAfter(15, check)
        end
    end):start()

    -- Catch up right after (re)load as well
    hs.timer.doAfter(10, check)
end

function M.stopAutoSummary()
    if autoSummaryTimer then
        autoSummaryTimer:stop()
        autoSummaryTimer = nil
    end
    if wakeWatcher then
        wakeWatcher:stop()
        wakeWatcher = nil
    end
end

-- Summary browser webview
local browserWebview = nil
-- Which folders are expanded; kept across opens until Hammerspoon reloads.
local browserOpenFolders = nil

function M.showBrowser()
    if browserWebview then
        browserWebview:delete()
        browserWebview = nil
    end

    local summariesDir = getSummariesDir()

    local categories = {
        {dir = "daily",   label = "Daily"},
        {dir = "weekly",  label = "Weekly"},
        {dir = "monthly", label = "Monthly"},
        {dir = "yearly",  label = "Yearly"},
    }

    local function escapeHtml(s)
        return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&#39;"))
    end

    local function firstPreviewLine(content)
        local lineCount = 0
        for line in content:gmatch("[^\n]+") do
            if lineCount > 0 and line ~= "" and not line:match("^#") then
                return line:sub(1, 120)
            end
            lineCount = lineCount + 1
        end
        return ""
    end

    -- One folder per summary level, each sorted newest first. File names are
    -- ISO dates (YYYY, YYYY-MM, YYYY-MM-DD), so a reverse string sort is a
    -- reverse chronological sort.
    local folders = {}
    local total = 0
    for _, cat in ipairs(categories) do
        local dirPath = summariesDir .. "/" .. cat.dir
        local files = {}
        local output, status = hs.execute(string.format("ls -1 '%s'/*.md 2>/dev/null", dirPath))
        if status and output and output ~= "" then
            for path in output:gmatch("[^\n]+") do
                local name = path:match("([^/]+)%.md$")
                if name then
                    table.insert(files, {name = name, path = path})
                end
            end
        end
        table.sort(files, function(a, b) return a.name > b.name end)
        for _, f in ipairs(files) do
            f.preview = firstPreviewLine(readFile(f.path) or "")
        end
        total = total + #files
        table.insert(folders, {dir = cat.dir, label = cat.label, files = files})
    end

    -- Folders start collapsed so every level is visible at a glance.
    browserOpenFolders = browserOpenFolders or {}

    -- Build HTML
    local items = ""
    if total == 0 then
        items = '<div class="empty">No summaries yet</div>'
    else
        for _, folder in ipairs(folders) do
            local isOpen = browserOpenFolders[folder.dir] and #folder.files > 0
            local latest = folder.files[1] and ("latest " .. folder.files[1].name) or "empty"
            local rows = ""
            for _, f in ipairs(folder.files) do
                rows = rows .. string.format(
                    '<a class="item" href="#" data-path="%s">'
                    .. '<div class="date">%s</div>'
                    .. '<div class="preview">%s</div>'
                    .. '</a>',
                    escapeHtml(f.path), escapeHtml(f.name), escapeHtml(f.preview)
                )
            end
            items = items .. string.format(
                '<div class="folder%s%s" data-dir="%s">'
                .. '<div class="folder-head">'
                .. '<span class="chevron">▸</span>'
                .. '<span class="folder-icon">📁</span>'
                .. '<span class="folder-name">%s</span>'
                .. '<span class="count">%d</span>'
                .. '<span class="latest">%s</span>'
                .. '</div>'
                .. '<div class="folder-body">%s</div>'
                .. '</div>',
                isOpen and " open" or "",
                #folder.files == 0 and " empty-folder" or "",
                folder.dir, folder.label, #folder.files, escapeHtml(latest), rows
            )
        end
    end

    local html = [[
<!DOCTYPE html>
<html>
<head>
<style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    html, body { height: 100%; }
    body {
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
        background: #1e1e1e;
        color: #cccccc;
        padding: 16px;
        -webkit-user-select: none;
        display: flex;
        flex-direction: column;
    }
    h2 { font-size: 14px; font-weight: 600; color: #ffffff; margin-bottom: 12px; }
    .list { overflow-y: auto; flex: 1; }
    .folder { margin-bottom: 6px; }
    .folder-head {
        display: flex;
        align-items: center;
        gap: 8px;
        padding: 8px 10px;
        border-radius: 6px;
        cursor: pointer;
        background: #252526;
        border: 1px solid #333;
    }
    .folder-head:hover { border-color: #007acc; }
    .chevron { font-size: 11px; color: #888; width: 10px; transition: transform 0.15s; }
    .folder.open .chevron { transform: rotate(90deg); }
    .folder-name { font-size: 14px; font-weight: 600; color: #ffffff; }
    .count { font-size: 11px; background: #333; color: #aaa; padding: 1px 7px; border-radius: 10px; }
    .latest { font-size: 11px; color: #777; margin-left: auto; }
    .empty-folder .folder-head { opacity: 0.5; cursor: default; }
    .folder-body { display: none; padding: 6px 0 2px 20px; }
    .folder.open .folder-body { display: block; }
    .item {
        display: block;
        padding: 8px 12px;
        border-radius: 6px;
        text-decoration: none;
        color: #cccccc;
        border: 1px solid #333;
        margin-bottom: 4px;
        cursor: pointer;
    }
    .item:hover { background: #2d2d2d; border-color: #007acc; }
    .date { font-size: 13px; font-weight: 600; color: #ffffff; }
    .preview { font-size: 12px; color: #888; margin-top: 3px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .empty { color: #666; font-size: 13px; padding: 20px 0; text-align: center; }
</style>
</head>
<body>
    <h2>Summaries</h2>
    <div class="list">]] .. items .. [[</div>
    <script>
        function post(msg) {
            window.webkit.messageHandlers.hammerspoon.postMessage(msg);
        }
        document.querySelectorAll(".folder").forEach(function(folder) {
            if (folder.classList.contains("empty-folder")) return;
            folder.querySelector(".folder-head").addEventListener("click", function() {
                var open = folder.classList.toggle("open");
                post("toggle:" + folder.dataset.dir + ":" + (open ? "1" : "0"));
            });
        });
        document.querySelectorAll(".item").forEach(function(item) {
            item.addEventListener("click", function(e) {
                e.preventDefault();
                post("open:" + item.dataset.path);
            });
        });
        document.addEventListener("keydown", function(e) {
            if (e.key === "Escape") post("close");
        });
    </script>
</body>
</html>
]]

    local screen = hs.screen.mainScreen():frame()
    local width = 500
    local height = 520
    local rect = hs.geometry.rect(
        (screen.w - width) / 2,
        (screen.h - height) / 2,
        width,
        height
    )

    local uc = hs.webview.usercontent.new("hammerspoon")
    uc:setCallback(function(msg)
        local body = msg.body
        if type(body) ~= "string" then return end
        if body:sub(1, 5) == "open:" then
            local path = body:sub(6)
            hs.execute("open " .. string.format("%q", path))
            if browserWebview then
                browserWebview:delete()
                browserWebview = nil
            end
        elseif body:sub(1, 7) == "toggle:" then
            local dir, state = body:match("^toggle:([%w_]+):([01])$")
            if dir then
                browserOpenFolders[dir] = (state == "1") or nil
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

-- Date picker dialog for generating a summary for a specific date
local datePickerWebview = nil

function M.showDatePicker()
    if datePickerWebview then
        datePickerWebview:delete()
        datePickerWebview = nil
    end

    local yesterday = os.date("%Y-%m-%d", os.time() - 86400)

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
    input[type="date"] {
        width: 100%;
        background: #2d2d2d;
        border: 1px solid #404040;
        border-radius: 6px;
        color: #cccccc;
        font-family: inherit;
        font-size: 14px;
        padding: 8px 10px;
        outline: none;
        color-scheme: dark;
    }
    input[type="date"]:focus { border-color: #007acc; }
    .buttons {
        display: flex;
        justify-content: flex-end;
        gap: 8px;
        margin-top: 12px;
    }
    button {
        padding: 6px 16px;
        border-radius: 4px;
        border: 1px solid #404040;
        font-size: 13px;
        cursor: pointer;
        background: #2d2d2d;
        color: #cccccc;
    }
    button:hover { background: #3d3d3d; }
    button.primary {
        background: #007acc;
        border-color: #007acc;
        color: #ffffff;
    }
    button.primary:hover { background: #0098ff; }
</style>
</head>
<body>
    <h2>Generate Summary for Date</h2>
    <input type="date" id="datepicker" value="]] .. yesterday .. [[" autofocus>
    <div class="buttons">
        <button onclick="cancel()">Cancel</button>
        <button class="primary" onclick="submit()">Generate</button>
    </div>
    <script>
        function submit() {
            var date = document.getElementById("datepicker").value;
            if (date) {
                window.webkit.messageHandlers.hammerspoon.postMessage("generate:" + date);
            }
        }
        function cancel() {
            window.webkit.messageHandlers.hammerspoon.postMessage("close");
        }
        document.addEventListener("keydown", function(e) {
            if (e.key === "Enter") { submit(); }
            else if (e.key === "Escape") { cancel(); }
        });
    </script>
</body>
</html>
]]

    local screen = hs.screen.mainScreen():frame()
    local width = 350
    local height = 150
    local rect = hs.geometry.rect(
        (screen.w - width) / 2,
        (screen.h - height) / 2,
        width,
        height
    )

    local uc = hs.webview.usercontent.new("hammerspoon")
    uc:setCallback(function(msg)
        local body = msg.body
        if type(body) == "string" and body:sub(1, 9) == "generate:" then
            local date = body:sub(10)
            if datePickerWebview then
                datePickerWebview:delete()
                datePickerWebview = nil
            end
            M.generate(date)
        elseif body == "close" then
            if datePickerWebview then
                datePickerWebview:delete()
                datePickerWebview = nil
            end
        end
    end)

    datePickerWebview = hs.webview.new(rect, {developerExtrasEnabled = false}, uc)
    datePickerWebview:windowStyle(
        hs.webview.windowMasks.titled |
        hs.webview.windowMasks.closable
    )
    datePickerWebview:windowTitle("Worklog - Generate Summary")
    datePickerWebview:allowTextEntry(true)
    datePickerWebview:level(hs.drawing.windowLevels.floating)
    datePickerWebview:darkMode(true)
    datePickerWebview:html(html)
    datePickerWebview:show()
    datePickerWebview:bringToFront(true)
end

return M
