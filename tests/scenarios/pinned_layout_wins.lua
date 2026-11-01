-- A pinned layout must win over a newer throwaway session.
--
-- Three processes against one isolated state directory:
--   1. this driver builds a distinctive three-pane layout, pins it with
--      save.pin_now(window), and records the pinned state;
--   2. support\pinned_throwaway.lua launches, restores the pin, then changes its
--      own layout and lets the save detector write a newer session file;
--   3. support\pinned_restore.lua launches and must restore the pin, logging
--      restore.pinned with pinned_at, tabs and panes, and never the newer
--      session's rectangles.
--
-- The driver also asserts that the newer session file still exists afterwards,
-- so the test proves precedence rather than deletion.
local wezterm = require("wezterm")

local config_dir = (wezterm.config_dir or ""):gsub("\\", "/"):gsub("/+$", "")
package.path = config_dir .. "/?.lua;" .. config_dir .. "/?/init.lua;" .. package.path
local support = require("support.integration")

local report_path = os.getenv("WEZTERM_SESSION_TEST_REPORT") or ""
local token = os.getenv("WEZTERM_SESSION_TEST_TOKEN") or ""

local GUI_PATH = "C:\\Program Files\\WezTerm\\wezterm-gui.exe"
local TAB_TITLE = "pinned-layout"

local scenario_dir = support.scenario_dir(report_path)
local expected_path = scenario_dir .. "/.pin-expected.json"
local throwaway_path = scenario_dir .. "/.throwaway.json"
local throwaway_pid_path = scenario_dir .. "/.throwaway.pid"
local restore_path = scenario_dir .. "/.restore.json"
local restore_pid_path = scenario_dir .. "/.restore.pid"
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

local function total_panes(snapshot)
    local count = 0
    for _, tab in ipairs(snapshot.tabs or {}) do
        count = count + #(tab.panes or {})
    end
    return count
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

wezterm.on("gui-startup", function(_cmd)
    support.await_window(10, function(window, tab)
        support.settle(tab, 10, function(infos)
            local root = infos[1] and infos[1].pane or nil
            if root == nil then
                add("layout_built", false, "no starter pane")
                finish()
                return
            end

            local ok_right, right = pcall(root.split, root, {
                direction = "Right",
                size = 60,
            })
            local ok_bottom, bottom = false, nil
            if ok_right and right ~= nil then
                ok_bottom, bottom = pcall(right.split, right, {
                    direction = "Bottom",
                    size = 12,
                })
            end
            if not ok_right or right == nil or not ok_bottom or bottom == nil then
                add("layout_built", false,
                    "split failed: " .. tostring(right) .. " / " .. tostring(bottom))
                finish()
                return
            end
            pcall(tab.set_title, tab, TAB_TITLE)
            add("layout_built", true, "three panes, title " .. TAB_TITLE)

            local gui_ok, gui_windows = pcall(wezterm.gui.gui_windows)
            local gui_window = gui_ok and gui_windows and gui_windows[1] or nil
            if gui_window == nil then
                add("pin_call", false, "no GUI window for save.pin_now")
                finish()
                return
            end
            local pin_ok, pin_result = pcall(save.pin_now, gui_window)
            add("pin_call", pin_ok and pin_result == true,
                pin_ok and ("save.pin_now returned " .. tostring(pin_result))
                    or ("save.pin_now failed: " .. tostring(pin_result)))

            local pinned = state.read_pinned()
            if pinned == nil then
                add("pin_read", false, "state.read_pinned() returned nil after pin_now")
                finish()
                return
            end
            add("pin_read", true,
                string.format("pinned_at=%s tabs=%d panes=%d", tostring(pinned.pinned_at),
                    #pinned.tabs, total_panes(pinned)))
            add("pin_file", support.file_exists(state.pinned_path()),
                state.pinned_path())

            local expected = { state = pinned, pinned_at = pinned.pinned_at }
            local encoded_ok, encoded = pcall(wezterm.json_encode, expected)
            local wrote = encoded_ok and support.write_text(expected_path, encoded)
            add("expected_written", wrote == true,
                wrote == true and expected_path or tostring(encoded))

            local launch_throwaway, await_throwaway, launch_restore, await_restore, stop_peer, finalize

            stop_peer = function(pid, label, next_step)
                if pid == nil then
                    add(label .. "_stopped", false, "pid file missing")
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
                        add(label .. "_stopped", true, string.format("pid %d is gone", pid))
                        next_step()
                        return
                    end
                    if polls > 60 then
                        add(label .. "_stopped", false,
                            string.format("pid %d still alive after 6s", pid))
                        finish()
                        return
                    end
                    wezterm.time.call_after(0.1, await_gone)
                end
                wezterm.time.call_after(0.1, await_gone)
            end

            await_restore = function()
                local polls = 0
                local function check()
                    polls = polls + 1
                    local parsed = read_json(restore_path)
                    if parsed ~= nil and type(parsed.checks) == "table" then
                        for _, entry in ipairs(parsed.checks) do
                            add("restored_" .. tostring(entry.name), entry.ok == true,
                                tostring(entry.detail or ""))
                        end
                        add("restore_report", parsed.ok == true,
                            string.format("%d check(s), ok=%s", #parsed.checks,
                                tostring(parsed.ok)))
                        local pid = tonumber((support.read_text(restore_pid_path) or ""):match("%d+"))
                        stop_peer(pid, "restore", function()
                            finalize()
                        end)
                        return
                    end
                    if polls > 250 then
                        add("restore_report", false,
                            "no restore report after 25s (artifacts: " .. scenario_dir .. ")")
                        finish()
                        return
                    end
                    wezterm.time.call_after(0.1, check)
                end
                wezterm.time.call_after(0.1, check)
            end

            launch_restore = function()
                local peer_config = repo_root .. "/tests/scenarios/support/pinned_restore.lua"
                local launched, launch_err = pcall(wezterm.background_child_process, {
                    GUI_PATH,
                    "--config-file",
                    peer_config,
                })
                add("restore_launched", launched,
                    launched and ("launched " .. peer_config) or tostring(launch_err))
                await_restore()
            end

            await_throwaway = function()
                local polls = 0
                local function check()
                    polls = polls + 1
                    local parsed = read_json(throwaway_path)
                    if parsed ~= nil then
                        add("throwaway_ran", parsed.ok == true,
                            tostring(parsed.error or "ok"))
                        local saved_at = tonumber(parsed.saved_at)
                        add("throwaway_saved_newer",
                            saved_at ~= nil and saved_at > expected.pinned_at,
                            string.format("throwaway saved_at=%s pinned_at=%s",
                                tostring(saved_at), tostring(expected.pinned_at)))
                        local pid = tonumber((support.read_text(throwaway_pid_path) or ""):match("%d+"))
                        stop_peer(pid, "throwaway", function()
                            launch_restore()
                        end)
                        return
                    end
                    if polls > 250 then
                        add("throwaway_ran", false,
                            "no throwaway report after 25s (artifacts: " .. scenario_dir .. ")")
                        finish()
                        return
                    end
                    wezterm.time.call_after(0.1, check)
                end
                wezterm.time.call_after(0.1, check)
            end

            launch_throwaway = function()
                local peer_config = repo_root .. "/tests/scenarios/support/pinned_throwaway.lua"
                local launched, launch_err = pcall(wezterm.background_child_process, {
                    GUI_PATH,
                    "--config-file",
                    peer_config,
                })
                add("throwaway_launched", launched,
                    launched and ("launched " .. peer_config) or tostring(launch_err))
                await_throwaway()
            end

            finalize = function()
                local throwaway = read_json(throwaway_path)
                local newer_kept = false
                local newer_detail = "throwaway report missing"
                if throwaway ~= nil and throwaway.instance_id ~= nil then
                    local newer = state.read(throwaway.instance_id)
                    local file_ok = support.file_exists(state.path(throwaway.instance_id))
                    newer_kept = file_ok and newer ~= nil
                        and newer.saved_at == tonumber(throwaway.saved_at)
                    newer_detail = string.format(
                        "file=%s state=%s saved_at=%s expected=%s",
                        tostring(file_ok), tostring(newer ~= nil),
                        newer ~= nil and tostring(newer.saved_at) or "nil",
                        tostring(throwaway.saved_at))
                end
                add("newer_session_kept", newer_kept, newer_detail)

                local pinned_now = state.read_pinned()
                add("pin_unchanged",
                    pinned_now ~= nil and pinned_now.pinned_at == pinned.pinned_at,
                    string.format("pinned_at=%s expected=%s",
                        pinned_now ~= nil and tostring(pinned_now.pinned_at) or "nil",
                        tostring(pinned.pinned_at)))
                finish()
            end

            launch_throwaway()
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
