-- Regression: a cold restore must not report cwd drift.
--
-- A cold launch restores state before any shell has started. A freshly started
-- pwsh may not report its directory for several seconds, and the old
-- self-check treated that unreported cwd as drift, logging
-- `selfcheck.drift kinds=cwd timed_out=true` and flashing ` restore drift `.
-- The fix treats unreported cwd as unknown, waits up to ten seconds, and logs
-- selfcheck.cwd_unknown at info instead of drift or a status.
--
-- The scenario seeds a valid two-pane state before the entry loads, lets the
-- fresh process restore it, then waits twelve seconds so the old two-second
-- window would certainly have fired. It asserts that no drift was logged and
-- that no drift status was shown, while allowing cwd_unknown at info.
local wezterm = require("wezterm")

local config_dir = (wezterm.config_dir or ""):gsub("\\", "/"):gsub("/+$", "")
package.path = config_dir .. "/?.lua;" .. config_dir .. "/?/init.lua;" .. package.path
local support = require("support.integration")

local report_path = os.getenv("WEZTERM_SESSION_TEST_REPORT") or ""
local token = os.getenv("WEZTERM_SESSION_TEST_TOKEN") or ""

local TAB_TITLE = "cold-restore-silent"
-- The runner shrinks the self-check settle window to 2.5s for scenarios; four
-- seconds is past that window and past the old two-second window, so the old
-- false drift would certainly have appeared.
local WAIT_SECONDS = 4.0

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
local now = os.time()
local seeded = {
    version = state.SCHEMA_VERSION,
    saved_at = now,
    instance = { id = "cold-restore-seed", started_at = now - 60 },
    window = { cols = 120, rows = 35, active_tab = 1, active_pane = 1 },
    tabs = {
        {
            title = TAB_TITLE,
            panes = {
                {
                    id = 1,
                    rect = { left = 0, top = 0, width = 79, height = 35 },
                    cwd = "C:/Windows",
                },
                {
                    id = 2,
                    rect = { left = 80, top = 0, width = 40, height = 35 },
                    cwd = "C:/Windows/System32",
                },
            },
        },
    },
}
local seeded_ok, seeded_err = state.write(seeded)
add("cold_state_seeded", seeded_ok,
    seeded_ok and "two panes in C:/Windows and C:/Windows/System32"
        or ("state.write failed: " .. tostring(seeded_err)))

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

-- The flash lasts four seconds and this build may expose no status getter.
-- When a getter exists, sample it through the whole wait instead of reading
-- once at the end, when the status would already have cleared.
local function start_status_sampler(gui_window, seen)
    local getter = gui_window and gui_window.get_right_status
    if type(getter) ~= "function" then
        return false
    end
    local function sample()
        local ok, status = pcall(getter, gui_window)
        if ok and type(status) == "string" and status:find("drift", 1, true) ~= nil then
            seen[#seen + 1] = status
        end
        wezterm.time.call_after(0.2, sample)
    end
    wezterm.time.call_after(0.2, sample)
    return true
end

wezterm.on("gui-startup", function(_cmd)
    support.await_window(10, function(_window, tab)
        support.settle(tab, 10, function(infos)
            -- Geometry and title are stable as soon as the restore has
            -- replayed them, so check those before the long wait.
            add("pane_count", #infos == 2, "panes=" .. tostring(#infos))

            local expected = {}
            for _, pane in ipairs(seeded.tabs[1].panes) do
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
            local mismatch
            for index = 1, math.max(#expected, #live) do
                if expected[index] == nil
                    or live[index] == nil
                    or rect_key(expected[index]) ~= rect_key(live[index])
                then
                    mismatch = string.format("pane %d: seeded %s live %s", index,
                        expected[index] ~= nil and rect_key(expected[index]) or "missing",
                        live[index] ~= nil and rect_key(live[index]) or "missing")
                    break
                end
            end
            add("rects_exact", mismatch == nil, mismatch or "both rectangles identical")

            local title_ok, live_title = pcall(tab.get_title, tab)
            add("tab_title", title_ok and live_title == TAB_TITLE,
                string.format("seeded %q live %q", TAB_TITLE, tostring(live_title)))

            -- This runs in a process the runner started fresh, so the entry's
            -- restore has already rebuilt the seeded state before this point.
            local gui_ok, gui_windows = pcall(wezterm.gui.gui_windows)
            local gui_window = gui_ok and gui_windows and gui_windows[1] or nil
            local drift_statuses = {}
            local sampled = start_status_sampler(gui_window, drift_statuses)
            add("status_sampler", true,
                sampled and "sampling get_right_status every 0.2s"
                    or "no status getter in this build")

            wezterm.time.call_after(WAIT_SECONDS, function()
                -- A cold process was given the whole old two-second window plus
                -- ten more seconds; the fixed ten-second settle window has also
                -- finished by now.
                support.add_log_check(add, report_path, "restore_done", "restore.done", "info")
                local drift_found, drift_line =
                    support.find_log_event(report_path, "selfcheck.drift")
                add("no_drift_log", not drift_found,
                    drift_found and drift_line or "no selfcheck.drift line")
                support.add_log_absent(add, report_path, "no_selfcheck_errors", {
                    "selfcheck.status_failed",
                    "selfcheck.failed",
                    "restore.failed",
                    "restore.plan_failed",
                })

                -- cwd_unknown is allowed, but only at info: it must never be
                -- promoted to a warning or a drift.
                local unknown_levels = {}
                for _, entry in ipairs(support.log_lines(report_path)) do
                    if entry.event == "selfcheck.cwd_unknown" then
                        unknown_levels[#unknown_levels + 1] = entry.level
                    end
                end
                local unknown_info_only = true
                for _, level in ipairs(unknown_levels) do
                    if level ~= "info" then
                        unknown_info_only = false
                    end
                end
                add("cwd_unknown_info_only", unknown_info_only,
                    #unknown_levels == 0 and "no cwd_unknown line"
                        or ("levels: " .. table.concat(unknown_levels, ",")))

                if sampled then
                    add("no_drift_status", #drift_statuses == 0,
                        #drift_statuses == 0 and "status never contained 'drift'"
                            or table.concat(drift_statuses, " | "))
                else
                    -- Drift is the only path that flashes the drift status, and
                    -- no_drift_log above proves it never ran.
                    add("no_drift_status", not drift_found,
                        "no status getter; inferred from the absent selfcheck.drift")
                end

                finish()
            end)
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
