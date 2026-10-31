-- Second process for tests\scenarios\full_restore.lua.
--
-- Lives under support\ so the runner never discovers it. The driver has already
-- saved a three-pane state and written .expected.json next to its report. This
-- config evaluates the real entry, lets gui-startup restore that state, then
-- compares the live layout with the saved one and writes .restore.json for the
-- driver to merge into the scenario report.
local wezterm = require("wezterm")

local config_dir = (wezterm.config_dir or ""):gsub("\\", "/"):gsub("/+$", "")
-- This file lives in tests\scenarios\support, so support.integration is one
-- directory up, not inside config_dir.
local scenarios_dir = config_dir:gsub("/support$", "")
package.path = scenarios_dir .. "/?.lua;" .. scenarios_dir .. "/?/init.lua;"
    .. config_dir .. "/?.lua;" .. config_dir .. "/?/init.lua;" .. package.path
local support = require("support.integration")

local driver_report = os.getenv("WEZTERM_SESSION_TEST_REPORT") or ""
local scenario_dir = support.dirname(driver_report)
local expected_path = scenario_dir .. "/.expected.json"
local restore_report_path = scenario_dir .. "/.restore.json"
local pid_path = scenario_dir .. "/.restore.pid"

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
    support.write(restore_report_path, checks, { pid = support.pid(), token = "second" })
end

local pid_handle = io.open(pid_path, "w")
if pid_handle then
    pid_handle:write(tostring(wezterm.procinfo.pid()) .. "\n")
    pid_handle:close()
end

local expected_text = support.read_text(expected_path)
local expected = nil
if expected_text ~= nil then
    local parsed_ok, parsed = pcall(wezterm.json_parse, expected_text)
    if parsed_ok then
        expected = parsed
    end
end
if type(expected) ~= "table" or type(expected.state) ~= "table" then
    add("expected_state", false, "could not read " .. expected_path)
    finish()
    return wezterm.config_builder()
end
add("expected_state", true, expected_path)

-- config_dir is <repo>\tests\scenarios\support, so three components up.
local repo_root = scenarios_dir:match("^(.*)/tests/scenarios$")
package.path = repo_root .. "/?.lua;" .. repo_root .. "/?/init.lua;" .. package.path
local loaded, config = pcall(dofile, repo_root .. "/wezterm.lua")
if not loaded then
    add("entry_load", false, "dofile(" .. repo_root .. "/wezterm.lua) failed: " .. tostring(config))
    finish()
    return wezterm.config_builder()
end
add("entry_load", true, "repository entry evaluated from " .. repo_root .. "/wezterm.lua")
config.automatically_reload_config = false

-- A live cwd arrives as a Url; saved cwds are plain paths. Decode both to the
-- same lower-case backslash form, ignoring a trailing separator because
-- WezTerm adds one to some file URLs.
local function normalize_cwd(value)
    if value == nil then
        return nil
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
        return nil
    end
    local text = value
    if text:sub(1, 7):lower() == "file://" then
        text = text:sub(8)
    end
    text = text:gsub("^/([%a]):", "%1:")
    text = text:gsub("/", "\\"):lower()
    text = text:gsub("\\+$", "")
    return text
end

local function pane_id(pane)
    local ok, id = pcall(pane.pane_id, pane)
    if ok then
        return id
    end
    return nil
end

local function rect_key(rect)
    return string.format("%d,%d,%d,%d", rect.left, rect.top, rect.width, rect.height)
end

local function sorted_rects(rects)
    local copy = {}
    for _, rect in ipairs(rects) do
        copy[#copy + 1] = rect
    end
    table.sort(copy, function(a, b)
        if a.top ~= b.top then
            return a.top < b.top
        end
        if a.left ~= b.left then
            return a.left < b.left
        end
        if a.width ~= b.width then
            return a.width < b.width
        end
        return a.height < b.height
    end)
    return copy
end

wezterm.on("gui-startup", function(_cmd)
    support.await_window(10, function(_window, tab)
        support.settle(tab, 10, function(infos)
            local saved = expected.state
            local saved_tab = saved.tabs[1]
            local expected_rects = {}
            for _, pane in ipairs(saved_tab.panes) do
                expected_rects[#expected_rects + 1] = pane.rect
            end
            local live_rects = {}
            for _, info in ipairs(infos) do
                live_rects[#live_rects + 1] = {
                    left = info.left,
                    top = info.top,
                    width = info.width,
                    height = info.height,
                }
            end

            add("pane_count", #live_rects == #expected_rects,
                string.format("live=%d saved=%d", #live_rects, #expected_rects))

            -- Rectangles: exact, zero tolerance, one-to-one.
            local expected_sorted = sorted_rects(expected_rects)
            local live_sorted = sorted_rects(live_rects)
            local rect_mismatch
            for index = 1, math.max(#expected_sorted, #live_sorted) do
                local want = expected_sorted[index]
                local got = live_sorted[index]
                if want == nil or got == nil or rect_key(want) ~= rect_key(got) then
                    rect_mismatch = string.format("pane %d: saved %s live %s", index,
                        want ~= nil and rect_key(want) or "missing",
                        got ~= nil and rect_key(got) or "missing")
                    break
                end
            end
            add("rects_exact", rect_mismatch == nil,
                rect_mismatch or "all rectangles identical")

            -- Per-pane cwd, matched by rectangle.
            local live_by_rect = {}
            for _, info in ipairs(infos) do
                live_by_rect[rect_key({
                    left = info.left,
                    top = info.top,
                    width = info.width,
                    height = info.height,
                })] = info
            end
            local cwd_mismatch, checked_cwds = nil, 0
            for _, pane in ipairs(saved_tab.panes) do
                local info = live_by_rect[rect_key(pane.rect)]
                if info == nil then
                    cwd_mismatch = "no live pane for saved rect " .. rect_key(pane.rect)
                    break
                end
                checked_cwds = checked_cwds + 1
                local live_ok, live_url = pcall(info.pane.get_current_working_dir, info.pane)
                local live_cwd = live_ok and normalize_cwd(live_url) or nil
                if live_cwd ~= normalize_cwd(pane.cwd) then
                    cwd_mismatch = string.format("saved %s live %s", tostring(pane.cwd),
                        tostring(live_cwd))
                    break
                end
            end
            add("panes_cwd", cwd_mismatch == nil,
                cwd_mismatch or (checked_cwds .. " pane(s) match"))

            -- Title.
            local title_ok, live_title = pcall(tab.get_title, tab)
            add("tab_title", title_ok and live_title == saved_tab.title,
                string.format("saved %q live %q", tostring(saved_tab.title),
                    tostring(live_title)))

            -- Window cell size equals the saved bounding box.
            local right, bottom = 0, 0
            for _, rect in ipairs(live_rects) do
                right = math.max(right, rect.left + rect.width)
                bottom = math.max(bottom, rect.top + rect.height)
            end
            add("window_cells",
                right == saved.window.cols and bottom == saved.window.rows,
                string.format("saved %sx%s live %sx%s", tostring(saved.window.cols),
                    tostring(saved.window.rows), right, bottom))

            -- Active pane: the pane the driver activated, matched by rectangle.
            local active_saved = nil
            for _, pane in ipairs(saved_tab.panes) do
                if pane.id == expected.active_id then
                    active_saved = pane
                    break
                end
            end
            local active_live = nil
            for _, info in ipairs(infos) do
                if info.is_active then
                    active_live = info
                    break
                end
            end
            add("active_pane",
                active_saved ~= nil
                    and active_live ~= nil
                    and rect_key(active_saved.rect) == rect_key({
                        left = active_live.left,
                        top = active_live.top,
                        width = active_live.width,
                        height = active_live.height,
                    }),
                string.format("saved active id=%s rect=%s, live active rect=%s",
                    tostring(expected.active_id),
                    active_saved ~= nil and rect_key(active_saved.rect) or "missing",
                    active_live ~= nil
                        and rect_key({
                            left = active_live.left,
                            top = active_live.top,
                            width = active_live.width,
                            height = active_live.height,
                        })
                        or "missing"))

            -- A clean restore stays silent.
            support.add_log_check(add, driver_report, "restore_done", "restore.done", "info")
            support.add_log_absent(add, driver_report, "clean_selfcheck", {
                "selfcheck.drift",
                "selfcheck.failed",
                "selfcheck.status_failed",
                "restore.failed",
                "restore.plan_failed",
            })

            finish()
        end, function(message)
            add("layout_settled", false, message)
            finish()
        end)
    end, function(message)
        add("window_present", false, message)
        finish()
    end)
    return true
end)

return config
