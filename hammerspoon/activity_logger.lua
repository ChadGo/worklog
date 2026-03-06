local M = {}

local config = nil
local webview = nil

function M.init(cfg)
    config = cfg
end

local function getLogPath()
    local date = os.date("%Y-%m-%d")
    return config.base_path .. "/logs/" .. date .. ".md"
end

local function ensureManualSection(path)
    local f = io.open(path, "r")
    if not f then
        -- Create the file with both sections
        local date = os.date("%Y-%m-%d")
        f = io.open(path, "w")
        if f then
            f:write("# Activity Log - " .. date .. "\n\n")
            f:write("## Tracked Activity\n\n")
            f:write("## Manual Entries\n\n")
            f:close()
        end
        return
    end

    local content = f:read("*a")
    f:close()

    if not content:find("## Manual Entries") then
        f = io.open(path, "a")
        if f then
            f:write("\n## Manual Entries\n\n")
            f:close()
        end
    end
end

local function appendManualEntry(text)
    if not text or text == "" then return end

    local path = getLogPath()
    ensureManualSection(path)

    local timestamp = os.date("%H:%M:%S")
    local entry = "- [" .. timestamp .. "] " .. text .. "\n"

    local f = io.open(path, "r")
    if not f then return end
    local content = f:read("*a")
    f:close()

    -- Append after the Manual Entries header
    f = io.open(path, "a")
    if f then
        f:write(entry)
        f:close()
    end
end

local function getHTML()
    return [[
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
    h2 {
        font-size: 14px;
        font-weight: 600;
        color: #ffffff;
        margin-bottom: 12px;
    }
    textarea {
        width: 100%;
        height: 120px;
        background: #2d2d2d;
        border: 1px solid #404040;
        border-radius: 6px;
        color: #cccccc;
        font-family: inherit;
        font-size: 13px;
        padding: 10px;
        resize: none;
        outline: none;
    }
    textarea:focus {
        border-color: #007acc;
    }
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
    <h2>Log Entry</h2>
    <textarea id="entry" placeholder="What are you working on?" autofocus></textarea>
    <div class="buttons">
        <button onclick="cancel()">Cancel</button>
        <button class="primary" onclick="submit()">Save</button>
    </div>
    <script>
        function submit() {
            var text = document.getElementById("entry").value.trim();
            if (text) {
                window.webkit.messageHandlers.hammerspoon.postMessage("submit:" + text);
            }
        }
        function cancel() {
            window.webkit.messageHandlers.hammerspoon.postMessage("cancel");
        }
        document.getElementById("entry").addEventListener("keydown", function(e) {
            if (e.key === "Enter" && e.metaKey) {
                submit();
            } else if (e.key === "Escape") {
                cancel();
            }
        });
    </script>
</body>
</html>
]]
end

function M.show()
    if webview then
        webview:delete()
        webview = nil
    end

    local screen = hs.screen.mainScreen():frame()
    local width = 450
    local height = 230
    local rect = hs.geometry.rect(
        (screen.w - width) / 2,
        (screen.h - height) / 2,
        width,
        height
    )

    webview = hs.webview.new(rect, {
        developerExtrasEnabled = false,
    })

    webview:windowStyle(
        hs.webview.windowMasks.titled |
        hs.webview.windowMasks.closable |
        hs.webview.windowMasks.nonactivating
    )

    webview:windowTitle("Activity Monitor - Log Entry")
    webview:allowTextEntry(true)
    webview:level(hs.drawing.windowLevels.floating)
    webview:darkMode(true)

    local uc = webview:asHSDrawing()

    webview:navigationCallback(function(action, wv, navID, error)
        if action == "didFinish" then
            wv:evaluateJavaScript('document.getElementById("entry").focus()')
        end
    end)

    webview:userContentController():setCallback(function(msg)
        local body = msg.body
        if type(body) == "string" and body:sub(1, 7) == "submit:" then
            local text = body:sub(8)
            appendManualEntry(text)
            hs.notify.new({title = "Activity Monitor", informativeText = "Log entry saved"}):send()
            if webview then
                webview:delete()
                webview = nil
            end
        elseif body == "cancel" then
            if webview then
                webview:delete()
                webview = nil
            end
        end
    end)

    webview:html(getHTML())
    webview:show()
    webview:hswindow():focus()
end

return M
