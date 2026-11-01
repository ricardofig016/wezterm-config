-- Third process for tests\scenarios\pinned_layout_wins.lua.
--
-- Lives under support\ so the runner never discovers it. It launches fresh and
-- must restore the pinned layout even though a newer throwaway session file
-- exists. It checks the exact restore.pinned fields, the restored rectangles and
-- that none of the newer session's rectangles came back.
local wezterm = require("wezterm")

local config_dir = (wezterm.config_dir or ""):gsub("\\", "/"):gsub("/+$", "")
local scenarios_dir = config_dir:gsub("/support$", "")
package.path = scenarios_dir .. "/?.lua;" .. scenarios_dir .. "/?/init.lua;"
    .. config_dir .. "/?.lua;" .. config_dir .. "/?/init.lua;" .. package.path
local support = require("support.integration")

local driver_report = os.getenv("WEZTERM_SESSION_TEST_REPORT") or ""
local scenario_dir = support.dirname(driver_report)
local expected_path = scenario_dir .. "/.pin-expected.json"
local throwaway_path = scenario_dir .. "/.throwaway.json"
local restore_path = scenario_dir .. "/.restore.json"
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
    support.write(restore_path, checks, { pid = support.pid(), token = "restore" })
end

local pid_handle = io.open(pid_path, "w")
if pid_handle then
    pid_handle:write(tostring(wezterm.procinfo.pid()) .. "\n")
    pid_handle:close()
end

local function read_json(path)
    local text = support.read_text(path)
    if text == nil then
        return nil
    end
    local ok, value = pcall(wezterm.json_parse, text)
    if ok and type(value) == "table" then
        return value
    end
    return nil
end

local expected = read_json(expected_path)
local throwaway = read_json(throwaway_path)
if expected == nil or type(expected.state) ~= "table" then
    add("expected_state", false, "could not read " .. expected_path)
    finish()
    return wezterm.config_builder()
end
add("expected_state", true,
    string.format("pinned_at=%s", tostring(expected.pinned_at)))

local pinned_tab = expected.state.tabs[1]
local pinned_rects = {}
for _, pane in ipairs(pinned_tab.panes or {}) do
    pinned_rects[#pinned_rects + 1] = pane.rect
end

-- config_dir is <repo>\tests\scenarios\support.
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

local function rect_key(rect)
    return string.format("%d,%d,%d,%d", rect.left, rect.top, rect.width, rect.height)
end

local function live_rect(info)
    return {
        left = info.left,
        top = info.top,
        width = info.width,
        height = info.height,
    }
end

local function sorted_copy(rects)
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
            local live = {}
            for _, info in ipairs(infos) do
                live[#live + 1] = live_rect(info)
            end
            add("pane_count", #live == #pinned_rects,
                string.format("live=%d pinned=%d", #live, #pinned_rects))

            local expected_sorted = sorted_copy(pinned_rects)
            local live_sorted = sorted_copy(live)
            local mismatch
            for index = 1, math.max(#expected_sorted, #live_sorted) do
                local want = expected_sorted[index]
                local got = live_sorted[index]
                if want == nil or got == nil or rect_key(want) ~= rect_key(got) then
                    mismatch = string.format("pane %d: pinned %s live %s", index,
                        want ~= nil and rect_key(want) or "missing",
                        got ~= nil and rect_key(got) or "missing")
                    break
                end
            end
            add("pinned_rects_exact", mismatch == nil,
                mismatch or "all pinned rectangles restored exactly")

            local title_ok, live_title = pcall(tab.get_title, tab)
            add("pinned_tab_title", title_ok and live_title == pinned_tab.title,
                string.format("pinned %q live %q", tostring(pinned_tab.title),
                    tostring(live_title)))

            -- The newer session's distinctive rectangles must not be present.
            -- Most of the throwaway layout is the pin it restored; only the
            -- panes its own split added are evidence that the newer session
            -- could have stolen the restore.
            local newer_present = false
            local newer_detail = "throwaway report missing"
            if throwaway ~= nil and type(throwaway.panes) == "table" then
                local pinned_keys = {}
                for _, rect in ipairs(pinned_rects) do
                    pinned_keys[rect_key(rect)] = true
                end
                local newer_keys = {}
                local newer_only = 0
                for _, rect in ipairs(throwaway.panes) do
                    if not pinned_keys[rect_key(rect)] then
                        newer_keys[rect_key(rect)] = true
                        newer_only = newer_only + 1
                    end
                end
                if newer_only == 0 then
                    newer_present = true
                    newer_detail = "throwaway layout added no distinct rectangle"
                else
                    for _, rect in ipairs(live) do
                        if newer_keys[rect_key(rect)] then
                            newer_present = true
                            newer_detail = "live rectangle matches the newer session: "
                                .. rect_key(rect)
                            break
                        end
                    end
                    if not newer_present then
                        newer_detail = string.format(
                            "%d newer-only rectangle(s) absent from %d live pane(s)",
                            newer_only, #live)
                    end
                end
            end
            add("newer_rects_absent", not newer_present, newer_detail)

            -- The emission contract is exact: all three fields must be present
            -- and match the pinned state, and a missing field must fail loudly.
            local found, line = support.find_log_event(driver_report, "restore.pinned", "info")
            add("restore_pinned_log", found, found and line or "no restore.pinned log line")
            if found and line ~= nil then
                local pinned_at = tonumber(line:match("pinned_at=(%d+)"))
                local tabs = tonumber(line:match("tabs=(%d+)"))
                local panes = tonumber(line:match("panes=(%d+)"))
                local wanted_panes = #pinned_rects
                local fields_ok = pinned_at == tonumber(expected.pinned_at)
                    and tabs == #expected.state.tabs
                    and panes == wanted_panes
                add("restore_pinned_fields", fields_ok,
                    string.format(
                        "pinned_at=%s tabs=%s panes=%s expected pinned_at=%s tabs=%d panes=%d | %s",
                        tostring(pinned_at), tostring(tabs), tostring(panes),
                        tostring(expected.pinned_at), #expected.state.tabs, wanted_panes, line))
            end

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
