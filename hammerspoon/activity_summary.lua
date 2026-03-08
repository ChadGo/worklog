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
    prompt = prompt .. "Include a '## Commits' section that lists all git commits grouped by project. "
    prompt = prompt .. "For each commit, show the short hash and message. If a commit message is long, summarize it briefly. "
    prompt = prompt .. "Use headers and bullet points. Start the document with `# Summary - " .. date .. "`. "
    prompt = prompt .. "Immediately after the title, include a '## TLDR' section with 3-4 sentences summarizing where most time was spent. "
    prompt = prompt .. "Focus on the big picture — e.g. 'Spent most of the day in meetings, with the rest focused on X' or 'Deep work day primarily on X and Y'. "
    prompt = prompt .. "Output ONLY the markdown summary, no preamble or explanation."

    hs.notify.new({
        title = "Worklog",
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
                title = "Worklog",
                informativeText = "Summary saved for " .. date,
                actionButtonTitle = "Open",
                hasActionButton = true,
            }):send()
        else
            local errMsg = stdErr or stdOut or "Unknown error"
            hs.notify.new({
                title = "Worklog",
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

-- Summary browser webview
local browserWebview = nil

function M.showBrowser()
    if browserWebview then
        browserWebview:delete()
        browserWebview = nil
    end

    local summariesDir = getSummariesDir()
    -- List summary files sorted newest first
    local output, status = hs.execute(string.format("ls -1r '%s'/*.md 2>/dev/null", summariesDir))
    local files = {}
    if status and output and output ~= "" then
        for path in output:gmatch("[^\n]+") do
            local filename = path:match("([^/]+)$")
            local date = filename:match("^(%d%d%d%d%-%d%d%-%d%d)%.md$")
            if date then
                -- Read first few lines for a preview
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
                table.insert(files, {date = date, path = path, preview = preview})
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
                .. '<div class="date">%s</div>'
                .. '<div class="preview">%s</div>'
                .. '</a>',
                f.path, f.date, escaped_preview
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
