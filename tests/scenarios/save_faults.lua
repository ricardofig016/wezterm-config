-- Step 8b: save faults.
--
-- Two behaviours that the debounce detector must survive:
--   * a window resize (unmaximizing the fresh fallback) changes the window cell
--     size and must be captured;
--   * a forced error inside one tick must log save.tick_failed and must not stop
--     later saves, so a split after the error still writes.
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

local function pane_count(snapshot)
    local count = 0
    for _, tab in ipairs(snapshot.tabs or {}) do
        count = count + #(tab.panes or {})
    end
    return count
end

local function window_key(snapshot)
    if snapshot == nil then
        return "nil"
    end
    local window = snapshot.window or {}
    return string.format("%sx%s", tostring(window.cols), tostring(window.rows))
end

wezterm.on("gui-startup", function(_cmd)
    support.await_window(8, function(_window, tab)
        support.settle(tab, 10, function(infos)
            local instance_id = state.instance_id()
            local state_path = state.path(instance_id)
            add("starter_pane", #infos == 1, "panes=" .. tostring(#infos))

            -- Forward declarations: each step schedules the next one in a timer.
            local await_baseline, resize, await_resize, arm_error, await_error_log, split_after_error

            local baseline_polls = 0
            await_baseline = function()
                baseline_polls = baseline_polls + 1
                local snapshot = state.read(instance_id)
                if snapshot ~= nil then
                    add("baseline_written", true,
                        string.format("window %s after %.1fs", window_key(snapshot),
                            baseline_polls * 0.1))
                    resize(snapshot)
                    return
                end
                if baseline_polls > 120 then
                    add("baseline_written", false, "no baseline state file after 12s")
                    finish()
                    return
                end
                wezterm.time.call_after(0.1, await_baseline)
            end

            -- 1. Unmaximize the fresh fallback. That changes the window cell
            -- grid, so the detector must save the new dimensions and rectangles.
            resize = function(baseline)
                local gui_ok, gui_windows = pcall(wezterm.gui.gui_windows)
                local gui_window = gui_ok and gui_windows and gui_windows[1] or nil
                if gui_window == nil then
                    add("resize_called", false, "no GUI window to restore")
                    finish()
                    return
                end
                local ok, err = pcall(gui_window.restore, gui_window)
                add("resize_called", ok, ok and "window:restore()" or tostring(err))
                await_resize(baseline)
            end

            local resize_polls = 0
            await_resize = function(baseline)
                local body_ok, body_err = pcall(function()
                    resize_polls = resize_polls + 1
                    local snapshot = state.read(instance_id)
                    if snapshot ~= nil and window_key(snapshot) ~= window_key(baseline) then
                        add("resize_captured", true,
                            string.format("%s -> %s after %.1fs", window_key(baseline),
                                window_key(snapshot), resize_polls * 0.1))
                        arm_error()
                        return
                    end
                    if resize_polls > 80 then
                        add("resize_captured", false,
                            string.format("window stayed %s for 8s", window_key(baseline)))
                        finish()
                        return
                    end
                    wezterm.time.call_after(0.1, await_resize)
                end)
                if not body_ok then
                    add("resize_error", false, tostring(body_err))
                    finish()
                end
            end

            -- 2. Force exactly one error inside a tick. save.collect is looked
            -- up on the module table at tick time, so this exercises the real
            -- wrapped tick path. The wrapper restores the real collector on the
            -- next call, so only one tick fails.
            arm_error = function()
                local original = save.collect
                local armed = true
                save.collect = function(window)
                    if armed then
                        armed = false
                        error("forced tick failure for save_faults", 0)
                    end
                    return original(window)
                end
                add("forced_error_armed", true, "next save tick will raise")
                await_error_log()
            end

            local error_polls = 0
            await_error_log = function()
                error_polls = error_polls + 1
                local found, line = support.find_log_event(report_path, "save.tick_failed", "warn")
                if found then
                    add("log_tick_failed", true, line)
                    split_after_error()
                    return
                end
                if error_polls > 60 then
                    add("log_tick_failed", false, "no save.tick_failed line after 6s")
                    finish()
                    return
                end
                wezterm.time.call_after(0.1, await_error_log)
            end

            -- 3. A later layout change must still be written: the reschedule
            -- chain survived the forced error.
            split_after_error = function()
                local before = support.read_text(state_path)
                local current = tab:panes_with_info()
                local root = current[1] and current[1].pane or nil
                if root == nil then
                    add("save_after_error", false, "no pane to split")
                    finish()
                    return
                end
                local ok, child = pcall(root.split, root, { direction = "Bottom", size = 10 })
                add("post_error_split", ok and child ~= nil,
                    ok and "Bottom split, 10 cells" or ("split failed: " .. tostring(child)))

                local polls = 0
                local function await_save()
                    polls = polls + 1
                    local snapshot = state.read(instance_id)
                    local text = support.read_text(state_path)
                    if snapshot ~= nil
                        and pane_count(snapshot) == 2
                        and text ~= nil
                        and text ~= before
                    then
                        add("save_after_error", true,
                            string.format("two-pane save after %.1fs", polls * 0.1))
                        local recovered = false
                        local seen_error = false
                        for _, entry in ipairs(support.log_lines(report_path)) do
                            if entry.event == "save.tick_failed" then
                                seen_error = true
                            elseif entry.event == "save.wrote" and seen_error then
                                recovered = true
                            end
                        end
                        add("log_recovered_after_error", recovered,
                            recovered and "save.wrote appears after save.tick_failed"
                                or "no save.wrote after the forced error")
                        finish()
                        return
                    end
                    if polls > 80 then
                        add("save_after_error", false, "no save after the forced error within 8s")
                        finish()
                        return
                    end
                    wezterm.time.call_after(0.1, await_save)
                end
                wezterm.time.call_after(0.1, await_save)
            end

            wezterm.time.call_after(0.1, await_baseline)
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
