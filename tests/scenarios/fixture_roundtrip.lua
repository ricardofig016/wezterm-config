-- Step 9b: push the captured five-pane fixture through save and restore.
--
-- The fixture is the captured live geometry, one-cell gutters included. This
-- scenario turns it into version 1 state, writes that state through the real
-- writer (the save half), lets the entry restore it, and compares every live
-- rectangle with the fixture at zero cells of tolerance. A window created at
-- the saved 190x46 cells is large enough on this screen; the plan models the
-- gutters, so the capture must come back exactly.
local wezterm = require("wezterm")

local config_dir = (wezterm.config_dir or ""):gsub("\\", "/"):gsub("/+$", "")
package.path = config_dir .. "/?.lua;" .. config_dir .. "/?/init.lua;" .. package.path
local support = require("support.integration")

local report_path = os.getenv("WEZTERM_SESSION_TEST_REPORT") or ""
local token = os.getenv("WEZTERM_SESSION_TEST_TOKEN") or ""

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
    support.write(report_path, checks, { token = token, pid = support.pid() })
end

local repo_root = support.repo_root(config_dir)
package.path = repo_root .. "/?.lua;" .. repo_root .. "/?/init.lua;" .. package.path

local state = require("lib.state")

local fixture_path = repo_root .. "/tests/fixtures/five-pane.json"
local fixture_text = support.read_text(fixture_path)
local fixture = nil
if fixture_text ~= nil then
    local parsed_ok, parsed = pcall(wezterm.json_parse, fixture_text)
    if parsed_ok and type(parsed) == "table" then
        fixture = parsed
    end
end

local seeded = false
if fixture ~= nil and type(fixture.tabs) == "table" and fixture.tabs[1] ~= nil then
    local now = os.time()
    local snapshot = {
        version = state.SCHEMA_VERSION,
        saved_at = now,
        instance = { id = "fixture-roundtrip", started_at = now - 60 },
        window = {
            cols = fixture.window.cols,
            rows = fixture.window.rows,
            active_tab = 1,
            active_pane = 101,
        },
        tabs = {
            {
                title = fixture.tabs[1].title,
                panes = {},
            },
        },
    }
    for index, pane in ipairs(fixture.tabs[1].panes) do
        snapshot.tabs[1].panes[index] = {
            id = 100 + index,
            rect = pane.rect,
            cwd = pane.cwd,
        }
    end
    local wrote, err = state.write(snapshot)
    seeded = wrote == true
    add("fixture_state_written", seeded,
        seeded and ("saved " .. #snapshot.tabs[1].panes .. " fixture panes")
            or ("state.write failed: " .. tostring(err)))
else
    add("fixture_read", false, "could not read " .. fixture_path)
end

if not seeded then
    finish()
    return wezterm.config_builder()
end

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
            local expected = {}
            for _, pane in ipairs(fixture.tabs[1].panes) do
                expected[#expected + 1] = pane.rect
            end
            local live = {}
            for _, info in ipairs(infos) do
                live[#live + 1] = {
                    left = info.left,
                    top = info.top,
                    width = info.width,
                    height = info.height,
                }
            end

            add("pane_count", #live == #expected,
                string.format("live=%d fixture=%d", #live, #expected))

            local expected_sorted = sorted_copy(expected)
            local live_sorted = sorted_copy(live)
            local mismatch
            for index = 1, math.max(#expected_sorted, #live_sorted) do
                local want = expected_sorted[index]
                local got = live_sorted[index]
                if want == nil or got == nil or rect_key(want) ~= rect_key(got) then
                    mismatch = string.format("pane %d: fixture %s live %s", index,
                        want ~= nil and rect_key(want) or "missing",
                        got ~= nil and rect_key(got) or "missing")
                    break
                end
            end
            add("rects_exact", mismatch == nil, mismatch or "all five rectangles identical")

            local right, bottom = 0, 0
            for _, rect in ipairs(live) do
                right = math.max(right, rect.left + rect.width)
                bottom = math.max(bottom, rect.top + rect.height)
            end
            add("window_cells",
                right == fixture.window.cols and bottom == fixture.window.rows,
                string.format("fixture %sx%s live %sx%s", tostring(fixture.window.cols),
                    tostring(fixture.window.rows), right, bottom))

            support.add_log_check(add, report_path, "restore_done", "restore.done", "info")
            support.add_log_absent(add, report_path, "no_restore_failure", {
                "restore.failed",
                "restore.plan_failed",
                "restore.spawn_failed",
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
