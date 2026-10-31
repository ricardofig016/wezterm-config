-- Step 8b (held until the divider fix): full restore parity.
--
-- The driver builds a three-pane nested layout in three different directories,
-- sets a custom tab title, activates a specific pane, and lets the real save
-- detector write it. It then launches a second wezterm-gui with
-- support\full_restore_second.lua, which evaluates the entry, restores that
-- state, compares the live result with the saved one and writes its own report
-- next to this scenario's report. The driver merges those checks into its own.
--
-- The second process is declared to the runner through .owned-pids and is also
-- killed explicitly here, so no GUI outlives the scenario.
local wezterm = require("wezterm")

local config_dir = (wezterm.config_dir or ""):gsub("\\", "/"):gsub("/+$", "")
package.path = config_dir .. "/?.lua;" .. config_dir .. "/?/init.lua;" .. package.path
local support = require("support.integration")

local report_path = os.getenv("WEZTERM_SESSION_TEST_REPORT") or ""
local token = os.getenv("WEZTERM_SESSION_TEST_TOKEN") or ""

local GUI_PATH = "C:\\Program Files\\WezTerm\\wezterm-gui.exe"
local TAB_TITLE = "restore-parity"
local SECOND_CWD = "C:/Windows"
local THIRD_CWD = "C:/Windows/System32"

local scenario_dir = support.scenario_dir(report_path)
local expected_path = scenario_dir .. "/.expected.json"
local second_report_path = scenario_dir .. "/.restore.json"
local second_pid_path = scenario_dir .. "/.restore.pid"
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

local function normalize_cwd(value)
    if value == nil then
        return nil
    end
    local text = tostring(value)
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

local function pane_count(snapshot)
    local count = 0
    for _, tab in ipairs(snapshot.tabs or {}) do
        count = count + #(tab.panes or {})
    end
    return count
end

local function cwds(snapshot)
    local values = {}
    for _, tab in ipairs(snapshot.tabs or {}) do
        for _, pane in ipairs(tab.panes or {}) do
            values[#values + 1] = normalize_cwd(pane.cwd)
        end
    end
    return values
end

local function distinct(values)
    local seen, count = {}, 0
    for _, value in ipairs(values) do
        if not seen[value] then
            seen[value] = true
            count = count + 1
        end
    end
    return count
end

wezterm.on("gui-startup", function(_cmd)
    support.await_window(8, function(_window, tab)
        support.settle(tab, 10, function(infos)
            add("starter_pane", #infos == 1, "panes=" .. tostring(#infos))
            local root = infos[1] and infos[1].pane or nil
            if root == nil then
                add("layout_built", false, "no pane to split")
                finish()
                return
            end

            local ok_right, right = pcall(root.split, root, {
                direction = "Right",
                size = 60,
                cwd = SECOND_CWD,
            })
            local ok_bottom, bottom = nil, nil
            if ok_right and right ~= nil then
                ok_bottom, bottom = pcall(right.split, right, {
                    direction = "Bottom",
                    size = 15,
                    cwd = THIRD_CWD,
                })
            end
            if not ok_right or right == nil or not ok_bottom or bottom == nil then
                add("layout_built", false,
                    "split failed: " .. tostring(right) .. " / " .. tostring(bottom))
                finish()
                return
            end
            local titled = pcall(tab.set_title, tab, TAB_TITLE)
            add("layout_built", titled, "three panes, title " .. TAB_TITLE)

            -- Activate the middle pane (the one created by the first split) so
            -- the saved active pane is not simply the last one.
            local activated = pcall(right.activate, right)
            add("pane_activated", activated, "activated the " .. SECOND_CWD .. " pane")

            local instance_id = state.instance_id()
            local saved, await_second, stop_second
            local polls = 0
            local function await_save()
                polls = polls + 1
                local snapshot = state.read(instance_id)
                if snapshot ~= nil
                    and pane_count(snapshot) == 3
                    and snapshot.tabs[1] ~= nil
                    and snapshot.tabs[1].title == TAB_TITLE
                then
                    saved(snapshot)
                    return
                end
                if polls > 150 then
                    add("state_saved", false,
                        "no three-pane save with the custom title after 15s")
                    finish()
                    return
                end
                wezterm.time.call_after(0.1, await_save)
            end

            saved = function(snapshot)
                add("state_saved", true,
                    string.format("three panes, title %q, saved_at=%d",
                        tostring(snapshot.tabs[1].title), snapshot.saved_at))
                add("three_distinct_cwds", distinct(cwds(snapshot)) == 3,
                    table.concat(cwds(snapshot), " | "))

                -- The state schema says the active pane is a pane id; this is
                -- the contract the restore side consumes.
                local active_id = pane_id(right)
                add("active_pane_recorded", snapshot.window.active_pane == active_id,
                    string.format("window.active_pane=%s activated pane id=%s",
                        tostring(snapshot.window.active_pane), tostring(active_id)))

                local expected = { state = snapshot, active_id = active_id }
                local encoded_ok, encoded = pcall(wezterm.json_encode, expected)
                local wrote = encoded_ok and support.write_text(expected_path, encoded)
                add("expected_written", wrote == true,
                    wrote == true and expected_path or tostring(encoded))

                local peer_config = repo_root .. "/tests/scenarios/support/full_restore_second.lua"
                local launched, launch_err = pcall(wezterm.background_child_process, {
                    GUI_PATH,
                    "--config-file",
                    peer_config,
                })
                add("second_launched", launched,
                    launched and ("launched " .. peer_config) or tostring(launch_err))
                await_second()
            end

            local second_polls = 0
            await_second = function()
                second_polls = second_polls + 1
                local text = support.read_text(second_report_path)
                if text ~= nil then
                    local parsed_ok, parsed = pcall(wezterm.json_parse, text)
                    if parsed_ok and type(parsed) == "table" and type(parsed.checks) == "table" then
                        for _, check in ipairs(parsed.checks) do
                            add("restore_" .. tostring(check.name), check.ok == true,
                                tostring(check.detail or ""))
                        end
                        add("second_report", parsed.ok == true,
                            string.format("%d check(s), ok=%s",
                                #parsed.checks, tostring(parsed.ok)))
                        stop_second()
                        return
                    end
                end
                if second_polls > 200 then
                    add("second_report", false,
                        "no restore report after 20s (artifacts: " .. scenario_dir .. ")")
                    finish()
                    return
                end
                wezterm.time.call_after(0.1, await_second)
            end

            stop_second = function()
                local pid = tonumber((support.read_text(second_pid_path) or ""):match("%d+"))
                if pid == nil then
                    add("second_stopped", false, "second pid file missing")
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
                        add("second_stopped", true, string.format("pid %d is gone", pid))
                        finish()
                        return
                    end
                    if polls > 60 then
                        add("second_stopped", false,
                            string.format("pid %d still alive after 6s", pid))
                        finish()
                        return
                    end
                    wezterm.time.call_after(0.1, await_gone)
                end
                wezterm.time.call_after(0.1, await_gone)
            end

            wezterm.time.call_after(0.1, await_save)
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
