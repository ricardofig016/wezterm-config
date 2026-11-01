-- Second process for tests\scenarios\maximized_roundtrip.lua.
--
-- Lives under support\ so the runner never discovers it. The driver maximized
-- itself, saved through the explicit save path, and wrote .maximized-expected.json
-- with the recorded maximized pixel size. This config evaluates the real entry,
-- lets gui-startup restore that state, then asserts the restored window is
-- maximized and writes .maximized-restore.json for the driver to merge.
--
-- Maximized is checked by pixel size, not by a get_dimensions flag: this build
-- exposes is_full_screen only. The mode_applied log line is the other half of
-- the proof.
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
local expected_path = scenario_dir .. "/.maximized-expected.json"
local restore_report_path = scenario_dir .. "/.maximized-restore.json"
local pid_path = scenario_dir .. "/.maximized-restore.pid"

local PIXEL_TOLERANCE = 8

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

local expected = nil
local expected_text = support.read_text(expected_path)
if expected_text ~= nil then
    local parsed_ok, parsed = pcall(wezterm.json_parse, expected_text)
    if parsed_ok then
        expected = parsed
    end
end
if type(expected) ~= "table"
    or type(expected.pixel_width) ~= "number"
    or type(expected.pixel_height) ~= "number"
then
    add("expected_state", false, "could not read " .. expected_path)
    finish()
    return wezterm.config_builder()
end
add("expected_state", true,
    string.format("pixels=%sx%s mode=%s cols=%s rows=%s",
        tostring(expected.pixel_width), tostring(expected.pixel_height),
        tostring(expected.mode), tostring(expected.cols), tostring(expected.rows)))

-- config_dir is <repo>\tests\scenarios\support, so the repository root is two
-- components above tests\scenarios.
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

-- The log is shared by every process against this state directory. The driver
-- had no saved state, so the only restore.mode_applied line must come from this
-- restore.
local function add_log_checks()
    local count, lines = support.count_log_lines(
        driver_report,
        "event=restore.mode_applied",
        " mode=maximized"
    )
    add("mode_applied_once", count == 1,
        string.format("mode_applied mode=maximized lines=%d%s", count,
            count > 0 and (" :: " .. table.concat(lines, " | ")) or ""))
    support.add_log_absent(add, driver_report, "no_mode_grid_mismatch", {
        "restore.mode_grid_mismatch",
    })
    support.add_log_check(add, driver_report, "restore_done", "restore.done", "info")
end

-- A maximize transition is applied before the splits are replayed, so the
-- layout is not final until restore.done (or restore.failed) reaches the log.
-- Waiting here also keeps this report from racing the restore and reporting a
-- missing restore.done that was merely late.
local function await_restore_complete(timeout_seconds, on_done)
    local deadline = os.time() + (timeout_seconds or 12)
    local function tick()
        local done = support.find_log_event(driver_report, "restore.done")
        local failed = support.find_log_event(driver_report, "restore.failed")
        if done or failed or os.time() >= deadline then
            on_done(done, failed)
            return
        end
        wezterm.time.call_after(0.1, tick)
    end
    tick()
end

wezterm.on("gui-startup", function(_cmd)
    support.await_window(8, function(_window, tab)
        support.settle(tab, 10, function(infos)
            add("restored_pane_count", #infos == 1, "panes=" .. tostring(#infos))
            await_restore_complete(12, function(done, failed)
                add("restore_finished", done,
                    done and "restore.done logged"
                        or (failed and "restore.failed logged" or "no restore.done within 12s"))
                add_log_checks()
                if not done then
                    finish()
                    return
                end

                local gui_window = support.first_gui_window()
                if gui_window == nil then
                    add("restored_geometry", false,
                        "wezterm.gui.gui_windows() returned nothing")
                    finish()
                    return
                end

                support.await_dimensions(gui_window, false, 6, function(dims)
                    local width = tonumber(dims.pixel_width) or -1
                    local height = tonumber(dims.pixel_height) or -1
                    local want_width = tonumber(expected.pixel_width) or -1
                    local want_height = tonumber(expected.pixel_height) or -1
                    local width_ok = math.abs(width - want_width) <= PIXEL_TOLERANCE
                    local height_ok = math.abs(height - want_height) <= PIXEL_TOLERANCE
                    add("restored_not_fullscreen", dims.is_full_screen == false,
                        "is_full_screen=" .. tostring(dims.is_full_screen))
                    add("restored_pixels", width_ok and height_ok,
                        string.format(
                            "restored=%dx%d px recorded maximized=%dx%d px tolerance=%d px",
                            width, height, want_width, want_height, PIXEL_TOLERANCE))
                    finish()
                end, function(message)
                    add("restored_pixels", false, message)
                    finish()
                end)
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
