-- Maximized round trip. Gated behind tests\run.ps1 -WindowModes because it
-- maximizes a real window.
--
-- The driver maximizes itself, waits for the maximized pixel size to stop
-- changing, and calls the explicit save (the Alt+S path) so the state records
-- the window mode. It then records those pixel dimensions and launches a
-- second process with support\maximized_restore.lua, which evaluates the entry
-- against that state and must come back maximized.
--
-- This build has no maximized getter: get_dimensions() reports is_full_screen
-- only. Maximized is therefore asserted by pixel size against the recorded
-- maximized size, within a small tolerance, plus exactly one
-- restore.mode_applied mode=maximized log line. The saved state must say
-- window.mode = "maximized" before the relaunch even starts, so a regression on
-- the save side fails there instead of hiding behind a generous pixel match.
local wezterm = require("wezterm")

local config_dir = (wezterm.config_dir or ""):gsub("\\", "/"):gsub("/+$", "")
package.path = config_dir .. "/?.lua;" .. config_dir .. "/?/init.lua;" .. package.path
local support = require("support.integration")

local report_path = os.getenv("WEZTERM_SESSION_TEST_REPORT") or ""
local token = os.getenv("WEZTERM_SESSION_TEST_TOKEN") or ""

local GUI_PATH = "C:\\Program Files\\WezTerm\\wezterm-gui.exe"

local scenario_dir = support.scenario_dir(report_path)
local expected_path = scenario_dir .. "/.maximized-expected.json"
local restore_report_path = scenario_dir .. "/.maximized-restore.json"
local restore_pid_path = scenario_dir .. "/.maximized-restore.pid"
local owned_pids_path = scenario_dir .. "/.owned-pids"

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
local loaded, config = pcall(dofile, repo_root .. "/wezterm.lua")
if not loaded then
    add("entry_load", false, "dofile(" .. repo_root .. "/wezterm.lua) failed: " .. tostring(config))
    finish()
    return wezterm.config_builder()
end
add("entry_load", true, "repository entry evaluated from " .. repo_root .. "/wezterm.lua")
config.automatically_reload_config = false

local state = require("lib.state")
local save = require("lib.save")

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

local launch_restore, await_restore, stop_restore, finalize

stop_restore = function()
    local pid = tonumber((support.read_text(restore_pid_path) or ""):match("%d+"))
    if pid == nil then
        add("restore_stopped", false, "second pid file missing")
        finish()
        return
    end
    support.write_text(owned_pids_path, tostring(pid) .. "\n")
    pcall(os.execute, string.format("taskkill /PID %d /T /F >nul 2>nul", pid))
    local polls = 0
    local function await_gone()
        polls = polls + 1
        local ok, info = pcall(wezterm.procinfo.get_info_for_pid, pid)
        if ok and info == nil then
            add("restore_stopped", true, string.format("pid %d is gone", pid))
            finalize()
            return
        end
        if polls > 60 then
            add("restore_stopped", false, string.format("pid %d still alive after 6s", pid))
            finish()
            return
        end
        wezterm.time.call_after(0.1, await_gone)
    end
    wezterm.time.call_after(0.1, await_gone)
end

finalize = function()
    local count, lines = support.count_log_lines(
        report_path,
        "event=restore.mode_applied",
        " mode=maximized"
    )
    add("mode_applied_once", count == 1,
        string.format("mode_applied mode=maximized lines=%d%s", count,
            count > 0 and (" :: " .. table.concat(lines, " | ")) or ""))
    support.add_log_absent(add, report_path, "no_mode_grid_mismatch", {
        "restore.mode_grid_mismatch",
    })
    support.add_log_check(add, report_path, "restore_done", "restore.done", "info")
    finish()
end

await_restore = function()
    local polls = 0
    local function check()
        polls = polls + 1
        local parsed = read_json(restore_report_path)
        if parsed ~= nil and type(parsed.checks) == "table" then
            for _, entry in ipairs(parsed.checks) do
                add("restore_" .. tostring(entry.name), entry.ok == true,
                    tostring(entry.detail or ""))
            end
            add("restore_report", parsed.ok == true,
                string.format("%d check(s), ok=%s", #parsed.checks, tostring(parsed.ok)))
            stop_restore()
            return
        end
        if polls > 150 then
            add("restore_report", false,
                "no maximized restore report after 15s (artifacts: " .. scenario_dir .. ")")
            finish()
            return
        end
        wezterm.time.call_after(0.1, check)
    end
    wezterm.time.call_after(0.1, check)
end

launch_restore = function()
    local peer_config = repo_root .. "/tests/scenarios/support/maximized_restore.lua"
    local launched, launch_err = pcall(wezterm.background_child_process, {
        GUI_PATH,
        "--config-file",
        peer_config,
    })
    add("restore_launched", launched,
        launched and ("launched " .. peer_config) or tostring(launch_err))
    if not launched then
        finish()
        return
    end
    await_restore()
end

local function after_maximized(gui_window, dims)
    add("maximized_geometry", true,
        string.format("is_full_screen=false pane/window pixels %sx%s",
            tostring(dims.pixel_width), tostring(dims.pixel_height)))

    local saved_ok, saved_result = pcall(save.save_now, gui_window)
    add("save_called", saved_ok and saved_result == true,
        saved_ok and ("save.save_now returned " .. tostring(saved_result))
            or ("save.save_now failed: " .. tostring(saved_result)))
    if not saved_ok or saved_result ~= true then
        finish()
        return
    end

    local snapshot = state.read(state.instance_id())
    if snapshot == nil then
        add("state_saved", false, "state.read(instance_id) returned nil after save_now")
        finish()
        return
    end
    add("state_saved", true, string.format("saved_at=%s", tostring(snapshot.saved_at)))

    local mode = snapshot.window and snapshot.window.mode
    add("saved_mode", mode == "maximized", "window.mode=" .. tostring(mode))
    if mode ~= "maximized" then
        finish()
        return
    end

    local expected = {
        pixel_width = dims.pixel_width,
        pixel_height = dims.pixel_height,
        mode = mode,
        cols = snapshot.window.cols,
        rows = snapshot.window.rows,
        saved_at = snapshot.saved_at,
    }
    local encoded_ok, encoded = pcall(wezterm.json_encode, expected)
    local wrote = encoded_ok and support.write_text(expected_path, encoded)
    add("expected_written", wrote == true,
        wrote == true and expected_path or tostring(encoded))
    if wrote ~= true then
        finish()
        return
    end

    launch_restore()
end

wezterm.on("gui-startup", function(_cmd)
    support.await_window(8, function(_window, tab)
        support.settle(tab, 10, function(infos)
            add("starter_pane", #infos == 1, "panes=" .. tostring(#infos))
            local gui_window = support.first_gui_window()
            if gui_window == nil then
                add("gui_window", false, "wezterm.gui.gui_windows() returned nothing")
                finish()
                return
            end
            add("gui_window", true, "GuiWindow present")

            local maximize_ok, maximize_err = pcall(gui_window.maximize, gui_window)
            add("maximize_called", maximize_ok,
                maximize_ok and "GuiWindow:maximize()" or tostring(maximize_err))
            if not maximize_ok then
                finish()
                return
            end

            support.await_dimensions(gui_window, false, 8, function(dims)
                after_maximized(gui_window, dims)
            end, function(message)
                add("maximized_geometry", false, message)
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
