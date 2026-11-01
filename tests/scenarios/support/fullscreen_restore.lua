-- Second process for tests\scenarios\fullscreen_roundtrip.lua.
--
-- Lives under support\ so the runner never discovers it. The driver entered
-- fullscreen, saved through the explicit save path, and wrote
-- .fullscreen-expected.json with the recorded fullscreen pixel size. This config
-- evaluates the real entry, lets gui-startup restore that state, asserts that
-- the restored window is fullscreen, then leaves fullscreen before writing its
-- report so nothing is left covering the desktop.
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
local expected_path = scenario_dir .. "/.fullscreen-expected.json"
local restore_report_path = scenario_dir .. "/.fullscreen-restore.json"
local pid_path = scenario_dir .. "/.fullscreen-restore.pid"

local PIXEL_TOLERANCE = 8

local checks = {}
local finished = false
local finishing = false
local gui_window

local function add(name, ok, detail)
    support.add(checks, name, ok, detail)
end

local function write_report()
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
if type(expected) ~= "table" then
    add("expected_state", false, "could not read " .. expected_path)
    write_report()
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
    write_report()
    return wezterm.config_builder()
end
add("entry_load", true, "repository entry evaluated from " .. repo_root .. "/wezterm.lua")
config.automatically_reload_config = false

-- The driver had no saved state, so the only restore.mode_applied line must
-- come from this restore.
local function add_log_checks()
    local count, lines = support.count_log_lines(
        driver_report,
        "event=restore.mode_applied",
        " mode=fullscreen"
    )
    add("mode_applied_once", count == 1,
        string.format("mode_applied mode=fullscreen lines=%d%s", count,
            count > 0 and (" :: " .. table.concat(lines, " | ")) or ""))
    support.add_log_absent(add, driver_report, "no_mode_grid_mismatch", {
        "restore.mode_grid_mismatch",
    })
    support.add_log_check(add, driver_report, "restore_done", "restore.done", "info")
end

-- Toggle out only when fullscreen is actually on. A failed restore is already
-- a normal window, and toggling it would put the test into fullscreen instead of
-- taking it out.
local function leave_fullscreen_then(next_step)
    if finishing then
        return
    end
    finishing = true

    local dims = support.dimensions(gui_window)
    if dims == nil or dims.is_full_screen ~= true then
        add("left_fullscreen", true, "restored window was not fullscreen, nothing to leave")
        next_step()
        return
    end

    pcall(gui_window.toggle_fullscreen, gui_window)
    local polls = 0
    local function await_normal()
        polls = polls + 1
        local now = support.dimensions(gui_window)
        if now ~= nil and now.is_full_screen == false then
            add("left_fullscreen", true,
                string.format("left fullscreen after %.1fs", polls * 0.1))
            next_step()
            return
        end
        if polls > 30 then
            add("left_fullscreen", false,
                "restored window is still fullscreen 3s after toggling")
            next_step()
            return
        end
        wezterm.time.call_after(0.1, await_normal)
    end
    await_normal()
end

local function finish()
    leave_fullscreen_then(write_report)
end

-- A fullscreen transition is applied before the splits are replayed, so the
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

                gui_window = support.first_gui_window()
                if gui_window == nil then
                    add("restored_fullscreen", false,
                        "wezterm.gui.gui_windows() returned nothing")
                    finish()
                    return
                end

                support.await_dimensions(gui_window, true, 6, function(dims)
                    add("restored_fullscreen", dims.is_full_screen == true,
                        "is_full_screen=" .. tostring(dims.is_full_screen))
                    local width = tonumber(dims.pixel_width) or -1
                    local height = tonumber(dims.pixel_height) or -1
                    local want_width = tonumber(expected.pixel_width) or -1
                    local want_height = tonumber(expected.pixel_height) or -1
                    add("restored_pixels",
                        math.abs(width - want_width) <= PIXEL_TOLERANCE
                            and math.abs(height - want_height) <= PIXEL_TOLERANCE,
                        string.format(
                            "restored=%dx%d px recorded fullscreen=%dx%d px tolerance=%d px",
                            width, height, want_width, want_height, PIXEL_TOLERANCE))
                    finish()
                end, function(message)
                    add("restored_fullscreen", false, message)
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
