-- Capture scenario for the five-pane fixture (step 9a).
--
-- The runner launches this file as the WezTerm config, exactly like smoke:
--
--   wezterm-gui.exe --config-file tests\scenarios\five_pane_capture.lua
--
-- with WEZTERM_SESSION_STATE_DIR, WEZTERM_SESSION_TEST_REPORT and
-- WEZTERM_SESSION_TEST_TOKEN set (see support\integration.lua). It evaluates
-- the repository entry, waits for the fallback window to settle, then drives
-- real pane:split calls into a deliberately unequal five-pane nested layout:
--
--   root 120x35 (or the maximized grid)
--   +-- Bottom, 25 cells on the second side
--   |   +-- Right, 60 cells (top and bottom rows are split at the same line)
--   |   +-- Right, 60 cells
--   |       +-- Bottom, 10 cells
--
-- The result has five panes and three distinct split boundaries: one vertical
-- line shared by the two rows and two horizontal lines. Only after the live
-- tab:panes_with_info() confirms that shape does the scenario write
-- tests\fixtures\five-pane.json with the rectangles, titles and working
-- directories. An existing fixture is never overwritten: this is a one-shot
-- capture tool, and a normal integration run only re-verifies the shape so a
-- stale capture cannot silently pass.
local wezterm = require("wezterm")

local config_dir = (wezterm.config_dir or ""):gsub("\\", "/"):gsub("/+$", "")
package.path = config_dir .. "/?.lua;" .. config_dir .. "/?/init.lua;" .. package.path
local support = require("support.integration")

local report_path = os.getenv("WEZTERM_SESSION_TEST_REPORT") or ""
local token = os.getenv("WEZTERM_SESSION_TEST_TOKEN") or ""

local SPLIT_ROWS = 25
local SPLIT_COLUMNS = 60
local SPLIT_BOTTOM = 10
local EXPECTED_PANES = 5
local EXPECTED_BOUNDARIES = 3

local checks = {}
local finished = false

local function add(name, ok, detail)
    support.add(checks, name, ok, detail)
end

local function finish()
    if finished then
        return
    end
    finished = true
    support.write(report_path, checks, {
        token = token,
        pid = support.pid(),
    })
end

-- JSON helpers for the fixture only. io.open plus a hand-built document keeps
-- the capture independent of any encoder the rest of the suite does not have.
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

local function percent_decode(text)
    return (text:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

-- Same normalization as lib\save.lua: a Url's file_path is decoded but carries
-- the Windows leading slash, and older string forms arrive as file:///C:/...
local function plain_path(value)
    if value == nil then
        return ""
    end
    if type(value) ~= "string" then
        local ok, file_path = pcall(function()
            return value.file_path
        end)
        if ok and type(file_path) == "string" then
            value = file_path
        else
            value = tostring(value)
        end
    end
    if type(value) ~= "string" then
        return ""
    end
    local path = value
    if path:sub(1, 7):lower() == "file://" then
        path = percent_decode(path:sub(8))
    end
    if path:match("^/[%a]:[/\\]") then
        path = path:sub(2)
    end
    return path
end

local function pane_title(pane)
    local ok, title = pcall(pane.get_title, pane)
    if ok and type(title) == "string" then
        return title
    end
    return ""
end

local function pane_cwd(pane)
    local ok, value = pcall(pane.get_current_working_dir, pane)
    if not ok then
        return ""
    end
    return plain_path(value)
end

local function pane_signature(infos)
    local parts = {}
    for _, info in ipairs(infos) do
        parts[#parts + 1] = string.format(
            "%s,%s,%s,%s",
            tostring(info.left),
            tostring(info.top),
            tostring(info.width),
            tostring(info.height)
        )
    end
    return table.concat(parts, ";")
end

local function count_boundaries(infos)
    local max_right, max_bottom = 0, 0
    for _, info in ipairs(infos) do
        max_right = math.max(max_right, info.left + info.width)
        max_bottom = math.max(max_bottom, info.top + info.height)
    end

    local xs, ys = {}, {}
    for _, info in ipairs(infos) do
        local right = info.left + info.width
        local bottom = info.top + info.height
        if right > 0 and right < max_right then
            xs[right] = true
        end
        if bottom > 0 and bottom < max_bottom then
            ys[bottom] = true
        end
    end

    local parts = {}
    for x in pairs(xs) do
        parts[#parts + 1] = "x=" .. tostring(x)
    end
    for y in pairs(ys) do
        parts[#parts + 1] = "y=" .. tostring(y)
    end
    table.sort(parts)
    return #parts, table.concat(parts, " "), max_right, max_bottom
end

-- Deterministic order: top to bottom, then left to right. pane ids are not
-- captured because they differ per launch and restore only needs the geometry,
-- the working directory and the title.
local function ordered(infos)
    local items = {}
    for _, info in ipairs(infos) do
        items[#items + 1] = {
            info = info,
            cwd = pane_cwd(info.pane),
            title = pane_title(info.pane),
        }
    end
    table.sort(items, function(a, b)
        local left = a.info
        local right = b.info
        if left.top ~= right.top then
            return left.top < right.top
        end
        if left.left ~= right.left then
            return left.left < right.left
        end
        if left.width ~= right.width then
            return left.width < right.width
        end
        return left.height < right.height
    end)
    return items
end

local function render_fixture(items, tab_title, cols, rows)
    local lines = {
        "{",
        '  "description": ' .. quote("Five-pane nested layout captured from a live WezTerm window; three distinct split boundaries.") .. ",",
        '  "window": {"cols": ' .. tostring(cols) .. ', "rows": ' .. tostring(rows) .. "},",
        '  "tabs": [',
        "    {",
        '      "title": ' .. quote(tab_title) .. ",",
        '      "panes": [',
    }
    for index, item in ipairs(items) do
        local info = item.info
        local comma = index < #items and "," or ""
        lines[#lines + 1] = string.format(
            '        {"index": %d, "rect": {"left": %d, "top": %d, "width": %d, "height": %d}, "cwd": %s, "title": %s}%s',
            index,
            info.left,
            info.top,
            info.width,
            info.height,
            quote(item.cwd),
            quote(item.title),
            comma
        )
    end
    lines[#lines + 1] = "      ]"
    lines[#lines + 1] = "    }"
    lines[#lines + 1] = "  ]"
    lines[#lines + 1] = "}"
    return table.concat(lines, "\n") .. "\n"
end

local function write_file(path, body)
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

local repo_root = support.repo_root(config_dir)
local fixture_path = repo_root .. "/tests/fixtures/five-pane.json"

-- The scenario must run with the repository entry as its config.
package.path = repo_root .. "/?.lua;" .. repo_root .. "/?/init.lua;" .. package.path
local loaded, config = pcall(dofile, repo_root .. "/wezterm.lua")
if not loaded then
    add("entry_load", false,
        "dofile(" .. repo_root .. "/wezterm.lua) failed: " .. tostring(config))
    finish()
    return wezterm.config_builder()
end
add("entry_load", true, "repository entry evaluated from " .. repo_root .. "/wezterm.lua")
config.automatically_reload_config = false

wezterm.on("gui-startup", function(_cmd)
    local deadline = os.time() + 8
    local announced = false
    local last_signature = nil
    local stable = 0

    -- Split helper: returns the newly created pane (the second side), or nil
    -- and a message.
    local function split(pane, direction, size)
        if pane == nil then
            return nil, "no source pane"
        end
        local ok, result = pcall(pane.split, pane, {
            direction = direction,
            size = size,
        })
        if not ok then
            return nil, tostring(result)
        end
        if result == nil then
            return nil, "pane:split returned nil"
        end
        return result
    end

    local function capture(tab, attempt)
        local ok, infos = pcall(tab.panes_with_info, tab)
        if not ok then
            add("layout_settled", false, "tab:panes_with_info() failed: " .. tostring(infos))
            finish()
            return
        end

        local signature = pane_signature(infos)
        if signature == last_signature then
            stable = stable + 1
        else
            stable = 0
        end
        last_signature = signature
        if stable < 2 and os.time() <= deadline then
            wezterm.time.call_after(0.1, function()
                capture(tab, attempt + 1)
            end)
            return
        end

        local boundary_count, boundary_list, cols, rows = count_boundaries(infos)
        add("pane_count", #infos == EXPECTED_PANES,
            string.format("panes=%d (expected %d)", #infos, EXPECTED_PANES))
        add("split_boundaries", boundary_count == EXPECTED_BOUNDARIES,
            string.format("boundaries=%d [%s] (expected %d)", boundary_count, boundary_list,
                EXPECTED_BOUNDARIES))

        -- A fixture with empty working directories would be a bogus golden for
        -- restore, so it is part of the capture gate, not just a warning.
        local items = ordered(infos)
        local empty_cwds = 0
        for _, item in ipairs(items) do
            if item.cwd == "" then
                empty_cwds = empty_cwds + 1
            end
        end
        add("pane_cwds", empty_cwds == 0,
            string.format("%d of %d pane(s) have an empty working directory", empty_cwds, #items))

        local min_area, max_area = math.huge, 0
        for _, item in ipairs(items) do
            local area = item.info.width * item.info.height
            min_area = math.min(min_area, area)
            max_area = math.max(max_area, area)
        end
        add("unequal_sizes", #items > 1 and min_area < max_area,
            string.format("pane areas %d..%d cells", min_area, max_area))

        if #infos ~= EXPECTED_PANES or boundary_count ~= EXPECTED_BOUNDARIES or empty_cwds > 0 then
            add("fixture_write", false,
                "fixture not written because the live layout failed its capture gate")
            finish()
            return
        end

        local existing = io.open(fixture_path, "r")
        if existing then
            existing:close()
            add("fixture_write", true, "fixture already present, not overwritten: " .. fixture_path)
            finish()
            return
        end

        local tab_ok, tab_title = pcall(tab.get_title, tab)
        if not tab_ok or type(tab_title) ~= "string" then
            tab_title = items[1] and items[1].title or ""
        end
        local body = render_fixture(items, tab_title, cols, rows)
        local wrote, write_err = write_file(fixture_path, body)
        add("fixture_write", wrote,
            wrote and ("wrote " .. fixture_path .. " (" .. #items .. " panes)")
                or ("could not write " .. fixture_path .. ": " .. tostring(write_err)))
        finish()
    end

    local function inspect(attempt)
        if finished then
            return
        end
        local ok, windows = pcall(wezterm.mux.all_windows)
        if not ok then
            add("window_present", false, "wezterm.mux.all_windows() failed: " .. tostring(windows))
            finish()
            return
        end
        windows = windows or {}

        local tab = nil
        if #windows > 0 then
            local tabs = windows[1]:tabs()
            if tabs and #tabs > 0 then
                tab = tabs[1]
            end
        end

        if tab == nil then
            if os.time() > deadline then
                add("window_present", false,
                    string.format("no window or tab after 8s (#windows=%d, poll %d)", #windows,
                        attempt))
                finish()
                return
            end
            wezterm.time.call_after(0.1, function()
                inspect(attempt + 1)
            end)
            return
        end

        if not announced then
            add("window_present", true,
                string.format("window 1, tab 1, after %d poll(s)", attempt))
            announced = true
        end

        -- Wait for the fallback's maximize to stop changing the grid before
        -- splitting, so the numeric split sizes are applied to a stable base.
        local ok_infos, infos = pcall(tab.panes_with_info, tab)
        if not ok_infos then
            add("layout_settled", false, "tab:panes_with_info() failed: " .. tostring(infos))
            finish()
            return
        end
        local signature = pane_signature(infos)
        if signature == last_signature then
            stable = stable + 1
        else
            stable = 0
        end
        last_signature = signature
        if stable < 2 and os.time() <= deadline then
            wezterm.time.call_after(0.1, function()
                inspect(attempt + 1)
            end)
            return
        end

        local root = infos[1] and infos[1].pane or nil
        if root == nil or #infos ~= 1 then
            add("layout_settled", false,
                string.format("expected exactly one starter pane, found %d", #infos))
            finish()
            return
        end
        add("layout_settled", true,
            string.format("starter pane %dx%d cells", infos[1].width, infos[1].height))

        -- Build the unequal nested layout, one real split at a time.
        local bottom, err = split(root, "Bottom", SPLIT_ROWS)
        if bottom == nil then
            add("layout_built", false, "Bottom split failed: " .. tostring(err))
            finish()
            return
        end
        local right_top, right_top_err = split(root, "Right", SPLIT_COLUMNS)
        if right_top == nil then
            add("layout_built", false, "top Right split failed: " .. tostring(right_top_err))
            finish()
            return
        end
        local right_bottom, right_bottom_err = split(bottom, "Right", SPLIT_COLUMNS)
        if right_bottom == nil then
            add("layout_built", false, "bottom Right split failed: " .. tostring(right_bottom_err))
            finish()
            return
        end
        local nested, nested_err = split(right_bottom, "Bottom", SPLIT_BOTTOM)
        if nested == nil then
            add("layout_built", false, "nested Bottom split failed: " .. tostring(nested_err))
            finish()
            return
        end
        add("layout_built", true,
            string.format("splits Bottom=%d, Right=%d, Right=%d, Bottom=%d cells",
                SPLIT_ROWS, SPLIT_COLUMNS, SPLIT_COLUMNS, SPLIT_BOTTOM))

        wezterm.time.call_after(0.1, function()
            capture(tab, attempt + 1)
        end)
    end

    wezterm.time.call_after(0.1, function()
        inspect(1)
    end)
    return true
end)

return config
