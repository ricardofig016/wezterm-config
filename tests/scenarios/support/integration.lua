-- Shared plumbing for real-GUI integration scenarios.
--
-- A scenario is itself the WezTerm config file:
--
--   wezterm-gui.exe --config-file tests\scenarios\<name>.lua
--
-- The runner passes three environment variables to the launched process:
--
--   WEZTERM_SESSION_STATE_DIR    isolated state directory for this scenario
--   WEZTERM_SESSION_TEST_REPORT  where the scenario must write its JSON report
--   WEZTERM_SESSION_TEST_TOKEN   copied into the report so the runner can tell
--                                this launch's report from any other file
--
-- The report is the only pass signal; the runner never inspects the window.
-- Its shape is:
--
--   { "ok": <bool>, "token": <string>, "pid": <number>,
--     "checks": [ { "name": <string>, "ok": <bool>, "detail": <string> } ] }
--
-- Nothing here launches a process or writes state. The scenario owns the
-- in-app assertions; the runner owns process lifetime and the timeout.

local wezterm = require("wezterm")

local M = {}

function M.normalize(path)
    return (tostring(path):gsub("\\", "/"))
end

-- Strip trailing separators, then drop the final component. Kept local to this
-- file so scenarios need no debug library and no repository-relative cwd.
function M.dirname(path)
    local normalized = M.normalize(path):gsub("/+$", "")
    return normalized:match("^(.*)/[^/]+$") or normalized
end

-- config_dir follows --config-file, and scenarios live in
-- <repo>\tests\scenarios, so two levels up is the repository root.
function M.repo_root(config_dir)
    return M.dirname(M.dirname(config_dir))
end

function M.same_path(a, b)
    if a == nil or b == nil then
        return false
    end
    return M.normalize(a):lower() == M.normalize(b):lower()
end

-- Windows process id of the GUI process, or -1 when the API is missing. The
-- runner requires this value to match the pid it launched.
function M.pid()
    local ok, pid = pcall(function()
        return wezterm.procinfo.pid()
    end)
    if ok and type(pid) == "number" then
        return pid
    end
    return -1
end

function M.add(checks, name, ok, detail)
    checks[#checks + 1] = {
        name = tostring(name),
        ok = ok == true,
        detail = detail == nil and "" or tostring(detail),
    }
end

function M.passed(checks)
    for _, check in ipairs(checks) do
        if not check.ok then
            return false
        end
    end
    return true
end

local function quote(value)
    local text = tostring(value)
    local out = {}
    for index = 1, #text do
        local char = text:sub(index, index)
        local byte = text:byte(index)
        if char == '"' then
            out[#out + 1] = '\\"'
        elseif char == "\\" then
            out[#out + 1] = "\\\\"
        elseif char == "\n" then
            out[#out + 1] = "\\n"
        elseif char == "\r" then
            out[#out + 1] = "\\r"
        elseif char == "\t" then
            out[#out + 1] = "\\t"
        elseif byte < 32 then
            out[#out + 1] = string.format("\\u%04x", byte)
        else
            out[#out + 1] = char
        end
    end
    return '"' .. table.concat(out) .. '"'
end

-- Write to a temporary sibling first, then rename, so the runner can never read
-- a half-written report. Windows os.rename refuses an existing destination, so
-- the previous report (if any) is removed first; a direct write is the last
-- resort so the runner still gets a report when rename is unavailable.
function M.write(report_path, checks, extra)
    if type(report_path) ~= "string" or report_path == "" then
        return false, "no report path"
    end

    local parts = {}
    if type(extra) == "table" then
        local keys = {}
        for key in pairs(extra) do
            if key ~= "checks" and key ~= "ok" then
                keys[#keys + 1] = key
            end
        end
        table.sort(keys, function(a, b)
            return tostring(a) < tostring(b)
        end)
        for _, key in ipairs(keys) do
            local value = extra[key]
            local encoded
            if type(value) == "number" or type(value) == "boolean" then
                encoded = tostring(value)
            else
                encoded = quote(value)
            end
            parts[#parts + 1] = quote(key) .. ":" .. encoded
        end
    end

    local check_parts = {}
    for _, check in ipairs(checks) do
        check_parts[#check_parts + 1] = string.format(
            '{"name":%s,"ok":%s,"detail":%s}',
            quote(check.name),
            tostring(check.ok == true),
            quote(check.detail)
        )
    end
    parts[#parts + 1] = '"ok":' .. tostring(M.passed(checks))
    parts[#parts + 1] = '"checks":[' .. table.concat(check_parts, ",") .. "]"
    local body = "{" .. table.concat(parts, ",") .. "}"

    local tmp = report_path .. ".tmp"
    local handle, err = io.open(tmp, "w")
    if not handle then
        return false, "could not open " .. tmp .. ": " .. tostring(err)
    end
    local wrote = pcall(function()
        handle:write(body)
        handle:flush()
        handle:close()
    end)
    if not wrote then
        pcall(function()
            handle:close()
        end)
        return false, "could not write " .. tmp
    end

    os.remove(report_path)
    local renamed, rename_err = os.rename(tmp, report_path)
    if not renamed then
        local direct = io.open(report_path, "w")
        if not direct then
            return false,
                "could not rename or write " .. report_path .. ": " .. tostring(rename_err)
        end
        direct:write(body)
        direct:flush()
        direct:close()
    end
    return true
end
-- ---------------------------------------------------------------------------
-- File, log and window helpers shared by the restore and save scenarios.
-- ---------------------------------------------------------------------------

function M.file_exists(path)
    local handle = io.open(path, "r")
    if handle then
        handle:close()
        return true
    end
    return false
end

function M.read_text(path)
    local handle = io.open(path, "r")
    if not handle then
        return nil
    end
    local data = handle:read("*a")
    handle:close()
    return data
end

function M.write_text(path, body)
    local handle, err = io.open(path, "w")
    if not handle then
        return false, tostring(err)
    end
    local ok, write_err = pcall(function()
        handle:write(body)
        handle:flush()
        handle:close()
    end)
    if not ok then
        pcall(function()
            handle:close()
        end)
        return false, tostring(write_err)
    end
    return true
end

-- The scenario's isolated state directory, derived from the report path the
-- runner passed rather than trusted from the environment.
function M.state_dir(report_path)
    return M.dirname(report_path) .. "/state"
end

function M.scenario_dir(report_path)
    return M.dirname(report_path)
end

function M.sessions_dir(report_path)
    return M.state_dir(report_path) .. "/sessions"
end

-- Names (not paths) of the valid-looking session files, sorted. Validity is the
-- caller's job: this only filters the .json suffix.
function M.session_names(report_path)
    local names = {}
    local ok, entries = pcall(wezterm.read_dir, M.sessions_dir(report_path))
    if not ok or type(entries) ~= "table" then
        return names
    end
    for _, entry in ipairs(entries) do
        local text = tostring(entry)
        local name = text:match("([^\\/]+)$") or text
        if name:sub(-5) == ".json" then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

-- Parse lib\log.lua's one-line format. Returns entries with level, event and
-- the raw line so a failure can quote what the log actually said.
function M.log_lines(report_path)
    local text = M.read_text(M.state_dir(report_path) .. "/session.log")
    local lines = {}
    if text == nil then
        return lines
    end
    for line in text:gmatch("[^\r\n]+") do
        local level = line:match(" level=([%w]+)")
        local event = line:match(" event=([%w_%.]+)")
        if event ~= nil then
            lines[#lines + 1] = { level = level, event = event, line = line }
        end
    end
    return lines
end

function M.find_log_event(report_path, event, level)
    for _, entry in ipairs(M.log_lines(report_path)) do
        if entry.event == event and (level == nil or entry.level == level) then
            return true, entry.line
        end
    end
    return false, "no log line for event " .. tostring(event)
end

function M.add_log_check(add, report_path, name, event, level)
    local found, line = M.find_log_event(report_path, event, level)
    add(name, found, found and line or ("missing event " .. tostring(event)))
end

function M.add_log_absent(add, report_path, name, events)
    local found = {}
    for _, entry in ipairs(M.log_lines(report_path)) do
        for _, event in ipairs(events) do
            if entry.event == event then
                found[#found + 1] = entry.line
            end
        end
    end
    add(name, #found == 0,
        #found == 0 and "none present" or table.concat(found, " | "))
end

function M.pane_signature(panes)
    local parts = {}
    for _, info in ipairs(panes) do
        parts[#parts + 1] = string.format(
            "%s,%s,%s,%s,%s,%s",
            tostring(info.left),
            tostring(info.top),
            tostring(info.width),
            tostring(info.height),
            tostring(info.pixel_width),
            tostring(info.pixel_height)
        )
    end
    return table.concat(parts, ";")
end

-- Poll for the first window and tab, then hand both to on_ready.
function M.await_window(timeout_seconds, on_ready, on_timeout)
    local deadline = os.time() + (timeout_seconds or 8)
    local function tick()
        local ok, windows = pcall(wezterm.mux.all_windows)
        if ok and type(windows) == "table" and #windows > 0 then
            local tabs = windows[1]:tabs()
            if tabs and #tabs > 0 then
                on_ready(windows[1], tabs[1])
                return
            end
        end
        if os.time() >= deadline then
            on_timeout("no window or tab within " .. tostring(timeout_seconds or 8) .. "s")
            return
        end
        wezterm.time.call_after(0.1, tick)
    end
    wezterm.time.call_after(0.1, tick)
end

-- Poll until the pane list is non-empty and identical on two consecutive
-- reads, then hand the settled list to on_ready. A maximized fallback changes
-- the grid after the window first appears, so no scenario may measure the
-- first read.
function M.settle(tab, timeout_seconds, on_ready, on_timeout)
    local deadline = os.time() + (timeout_seconds or 8)
    local last = nil
    local stable = 0
    local function tick()
        local ok, infos = pcall(tab.panes_with_info, tab)
        if not ok then
            on_timeout("tab:panes_with_info() failed: " .. tostring(infos))
            return
        end
        if type(infos) ~= "table" or #infos == 0 then
            if os.time() >= deadline then
                on_timeout("tab has no panes")
                return
            end
            wezterm.time.call_after(0.1, tick)
            return
        end
        local signature = M.pane_signature(infos)
        if signature == last then
            stable = stable + 1
        else
            stable = 0
        end
        last = signature
        if stable >= 2 or os.time() >= deadline then
            on_ready(infos)
            return
        end
        wezterm.time.call_after(0.1, tick)
    end
    wezterm.time.call_after(0.1, tick)
end

M.FALLBACK_COLS = 120
M.FALLBACK_ROWS = 35

-- Chrome (title bar, tab bar, taskbar) sits between the pane and the screen. On
-- this 1920x1200 screen the maximized pane measured 1900x1012, so 250 px of
-- slack accepts the real chrome while rejecting a plain 120x35 window, which
-- leaves about 720x430 px.
M.SCREEN_TOLERANCE_PX = 250

-- Assert the intended fallback shape: exactly one pane at the tab origin, at
-- least the configured 120x35 cells, and pixels within chrome of the primary
-- screen. Returns true when every check passed.
function M.check_maximized_fallback(add, infos)
    local all_ok = true
    add("pane_count", #infos == 1, "panes=" .. tostring(#infos))
    if #infos ~= 1 then
        all_ok = false
    end

    local first = infos[1]
    if first == nil then
        add("first_pane_rect", false, "tab:panes_with_info() returned no panes")
        add("maximized_pixels", false, "tab:panes_with_info() returned no panes")
        return false
    end

    local width = tonumber(first.width) or -1
    local height = tonumber(first.height) or -1
    local cells_ok = first.left == 0
        and first.top == 0
        and width >= M.FALLBACK_COLS
        and height >= M.FALLBACK_ROWS
    add("first_pane_rect", cells_ok,
        string.format("left=%s top=%s width=%s height=%s (expected 0,0 and at least %dx%d)",
            tostring(first.left), tostring(first.top), tostring(width), tostring(height),
            M.FALLBACK_COLS, M.FALLBACK_ROWS))
    if not cells_ok then
        all_ok = false
    end

    local screens_ok, screens = pcall(wezterm.gui.screens)
    local screen = nil
    if screens_ok and type(screens) == "table" then
        screen = screens.main or screens.active or screens[1]
    end
    if type(screen) ~= "table" then
        add("maximized_pixels", false,
            "wezterm.gui.screens() returned no primary screen: " .. tostring(screens))
        return false
    end

    local pixel_width = tonumber(first.pixel_width) or -1
    local pixel_height = tonumber(first.pixel_height) or -1
    local screen_width = tonumber(screen.width) or -1
    local screen_height = tonumber(screen.height) or -1
    local width_slack = screen_width - pixel_width
    local height_slack = screen_height - pixel_height
    local pixels_ok = pixel_width > 0
        and pixel_height > 0
        and width_slack >= 0
        and height_slack >= 0
        and width_slack <= M.SCREEN_TOLERANCE_PX
        and height_slack <= M.SCREEN_TOLERANCE_PX
    add("maximized_pixels", pixels_ok,
        string.format("pane=%dx%d px screen=%dx%d px slack=%dx%d px tolerance=%d px",
            pixel_width, pixel_height, screen_width, screen_height,
            width_slack, height_slack, M.SCREEN_TOLERANCE_PX))
    if not pixels_ok then
        all_ok = false
    end
    return all_ok
end

-- The first GUI window, or nil. GuiWindow owns maximize, toggle_fullscreen and
-- get_dimensions; the mux window used for layout does not.
function M.first_gui_window()
    local ok, windows = pcall(wezterm.gui.gui_windows)
    if ok and type(windows) == "table" and #windows > 0 then
        return windows[1]
    end
    return nil
end

-- window:get_dimensions() as a plain table, or nil. This build reports
-- pixel_width, pixel_height, dpi and is_full_screen; it has no maximized flag.
function M.dimensions(gui_window)
    if gui_window == nil then
        return nil
    end
    local ok, dims = pcall(gui_window.get_dimensions, gui_window)
    if ok and type(dims) == "table" then
        return dims
    end
    return nil
end

-- Poll until get_dimensions() reports want_full_screen and the pixel size has
-- been identical for three consecutive reads, then hand the table to on_ready.
-- A maximize or fullscreen transition changes the grid after the call returns,
-- so no assertion may measure the first read.
function M.await_dimensions(gui_window, want_full_screen, timeout_seconds, on_ready, on_timeout)
    local deadline = os.time() + (timeout_seconds or 8)
    local last_width, last_height, stable = nil, nil, 0
    local function tick()
        local dims = M.dimensions(gui_window)
        local usable = dims ~= nil
            and dims.is_full_screen == want_full_screen
            and type(dims.pixel_width) == "number"
            and type(dims.pixel_height) == "number"
            and dims.pixel_width > 0
            and dims.pixel_height > 0
        if usable then
            if dims.pixel_width == last_width and dims.pixel_height == last_height then
                stable = stable + 1
            else
                stable = 0
            end
            last_width, last_height = dims.pixel_width, dims.pixel_height
            if stable >= 2 then
                on_ready(dims)
                return
            end
        else
            stable = 0
        end
        if os.time() >= deadline then
            on_timeout(string.format(
                "dimensions did not settle (want is_full_screen=%s, last=%sx%s)",
                tostring(want_full_screen), tostring(last_width), tostring(last_height)))
            return
        end
        wezterm.time.call_after(0.1, tick)
    end
    wezterm.time.call_after(0.1, tick)
end

-- Raw session.log lines that contain both plain substrings. Callers pass
-- "event=restore.mode_applied" and " mode=maximized" so a quoted or extra field
-- elsewhere on the line cannot satisfy the match by accident.
function M.count_log_lines(report_path, event_text, field_text)
    local count = 0
    local found = {}
    for _, entry in ipairs(M.log_lines(report_path)) do
        if entry.line:find(event_text, 1, true)
            and (field_text == nil or entry.line:find(field_text, 1, true))
        then
            count = count + 1
            found[#found + 1] = entry.line
        end
    end
    return count, found
end

return M
