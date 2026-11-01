-- Fullscreen round trip. Gated behind tests\run.ps1 -WindowModes because it
-- puts a real window into fullscreen mode.
--
-- The driver enters fullscreen, waits for the fullscreen pixel size to stop
-- changing, and calls the explicit save (the Alt+S path) so the state records
-- the window mode. It then launches support\fullscreen_restore.lua, which
-- evaluates the entry against that state, asserts is_full_screen and exactly
-- one restore.mode_applied mode=fullscreen line, and leaves fullscreen before
-- it writes its report. The driver leaves fullscreen on every exit path too, so
-- no test run can leave a fullscreen window covering the desktop.
local wezterm = require("wezterm")

local config_dir = (wezterm.config_dir or ""):gsub("\\", "/"):gsub("/+$", "")
package.path = config_dir .. "/?.lua;" .. config_dir .. "/?/init.lua;" .. package.path
local support = require("support.integration")

local report_path = os.getenv("WEZTERM_SESSION_TEST_REPORT") or ""
local token = os.getenv("WEZTERM_SESSION_TEST_TOKEN") or ""

local GUI_PATH = "C:\\Program Files\\WezTerm\\wezterm-gui.exe"

local scenario_dir = support.scenario_dir(report_path)
local expected_path = scenario_dir .. "/.fullscreen-expected.json"
local restore_report_path = scenario_dir .. "/.fullscreen-restore.json"
local restore_pid_path = scenario_dir .. "/.fullscreen-restore.pid"
local owned_pids_path = scenario_dir .. "/.owned-pids"

local checks = {}
local finished = false
local finishing = false
local gui_window
local left_fullscreen_checked = false

local function add(name, ok, detail)
    support.add(checks, name, ok, detail)
end

local function write_report()
    if finished then
        return
    end
    finished = true
    support.write(report_path, checks, { token = token, pid = support.pid() })
end

-- Toggle back to a normal window only when the window is actually fullscreen.
-- Toggling blindly would put a failed (non-fullscreen) restore into fullscreen
-- and leave it there, which is exactly what this scenario must not do.
local leave_fullscreen_then

local function finish()
    if finished or finishing then
        return
    end
    finishing = true
    leave_fullscreen_then(write_report)
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

-- This build's get_dimensions() reports is_full_screen correctly only when the
-- window was a normal window before the toggle. Toggling from a maximized
-- window covers the screen but keeps is_full_screen false, so the driver first
-- returns the fallback-maximized window to normal and waits until its area is
-- back under save's 85% maximized line.
local MAXIMIZED_AREA_RATIO = 0.85

local function screen_area()
    local ok, screens = pcall(wezterm.gui.screens)
    local screen = ok and type(screens) == "table" and (screens.active or screens.main) or nil
    if type(screen) ~= "table" then
        return nil
    end
    local width = tonumber(screen.width)
    local height = tonumber(screen.height)
    if width == nil or height == nil or width <= 0 or height <= 0 then
        return nil
    end
    return width * height
end

local function await_normal_window(gui, timeout_seconds, on_ready, on_timeout)
    local deadline = os.time() + (timeout_seconds or 6)
    local area = screen_area()
    local last_width, last_height, stable = nil, nil, 0
    local function tick()
        local dims = support.dimensions(gui)
        local coverage = nil
        if dims ~= nil and area ~= nil then
            coverage = (tonumber(dims.pixel_width) or 0) * (tonumber(dims.pixel_height) or 0) / area
        end
        if coverage ~= nil and coverage < MAXIMIZED_AREA_RATIO then
            if dims.pixel_width == last_width and dims.pixel_height == last_height then
                stable = stable + 1
            else
                stable = 0
            end
            last_width, last_height = dims.pixel_width, dims.pixel_height
            if stable >= 1 then
                on_ready(dims)
                return
            end
        else
            stable = 0
        end
        if os.time() >= deadline then
            on_timeout(string.format(
                "window did not return to a normal size (coverage=%s screen_area=%s)",
                tostring(coverage), tostring(area)))
            return
        end
        wezterm.time.call_after(0.1, tick)
    end
    tick()
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

leave_fullscreen_then = function(next_step)
    if left_fullscreen_checked then
        next_step()
        return
    end
    left_fullscreen_checked = true

    local dims = support.dimensions(gui_window)
    if dims == nil or dims.is_full_screen ~= true then
        add("driver_left_fullscreen", true, "driver window was not fullscreen")
        next_step()
        return
    end

    pcall(gui_window.toggle_fullscreen, gui_window)
    local polls = 0
    local function await_normal()
        polls = polls + 1
        local now = support.dimensions(gui_window)
        if now ~= nil and now.is_full_screen == false then
            add("driver_left_fullscreen", true,
                string.format("driver left fullscreen after %.1fs", polls * 0.1))
            next_step()
            return
        end
        if polls > 30 then
            add("driver_left_fullscreen", false,
                "driver window is still fullscreen 3s after toggling")
            next_step()
            return
        end
        wezterm.time.call_after(0.1, await_normal)
    end
    await_normal()
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
        " mode=fullscreen"
    )
    add("mode_applied_once", count == 1,
        string.format("mode_applied mode=fullscreen lines=%d%s", count,
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
            -- The restore process has already left fullscreen and written its
            -- report. Leave ours too before the slower kill sequence.
            leave_fullscreen_then(stop_restore)
            return
        end
        if polls > 150 then
            add("restore_report", false,
                "no fullscreen restore report after 15s (artifacts: " .. scenario_dir .. ")")
            finish()
            return
        end
        wezterm.time.call_after(0.1, check)
    end
    wezterm.time.call_after(0.1, check)
end

launch_restore = function()
    local peer_config = repo_root .. "/tests/scenarios/support/fullscreen_restore.lua"
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

local function after_fullscreen(dims)
    add("fullscreen_geometry", true,
        string.format("is_full_screen=true pixels %sx%s",
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
    add("saved_mode", mode == "fullscreen", "window.mode=" .. tostring(mode))
    if mode ~= "fullscreen" then
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
            gui_window = support.first_gui_window()
            if gui_window == nil then
                add("gui_window", false, "wezterm.gui.gui_windows() returned nothing")
                finish()
                return
            end
            add("gui_window", true, "GuiWindow present")

            local unmax_ok, unmax_err = pcall(gui_window.restore, gui_window)
            add("unmaximize_called", unmax_ok,
                unmax_ok and "GuiWindow:restore()" or tostring(unmax_err))
            if not unmax_ok then
                finish()
                return
            end

            await_normal_window(gui_window, 6, function(dims)
                add("normal_window", true,
                    string.format("normal window pixels %sx%s before fullscreen",
                        tostring(dims.pixel_width), tostring(dims.pixel_height)))

                local toggled, toggle_err = pcall(gui_window.toggle_fullscreen, gui_window)
                add("fullscreen_called", toggled,
                    toggled and "GuiWindow:toggle_fullscreen()" or tostring(toggle_err))
                if not toggled then
                    finish()
                    return
                end

                support.await_dimensions(gui_window, true, 8, function(full_dims)
                    after_fullscreen(full_dims)
                end, function(message)
                    add("fullscreen_geometry", false, message)
                    finish()
                end)
            end, function(message)
                add("normal_window", false, message)
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
