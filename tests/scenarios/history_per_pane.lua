-- Step 6 end to end: per-pane history survives a restart.
--
-- The driver creates two tabs, each with a single pane in a different
-- directory and its own title, runs a unique command in each pane, and waits
-- until each pane's PSReadLine history file under the isolated state directory
-- contains only its own command. It saves that layout and launches a second
-- wezterm-gui with support\history_second.lua, which restores the state and
-- asks each restored pane, through its own pane text, for
-- PSConsoleReadLine::GetHistoryItems().
--
-- A live pane loads history on its first prompt, so both processes wait for the
-- prompt before typing, and neither relies on a runtime reload.
local wezterm = require("wezterm")

local config_dir = (wezterm.config_dir or ""):gsub("\\", "/"):gsub("/+$", "")
package.path = config_dir .. "/?.lua;" .. config_dir .. "/?/init.lua;" .. package.path
local support = require("support.integration")

local report_path = os.getenv("WEZTERM_SESSION_TEST_REPORT") or ""
local token = os.getenv("WEZTERM_SESSION_TEST_TOKEN") or ""

local GUI_PATH = "C:\\Program Files\\WezTerm\\wezterm-gui.exe"
local TITLE_ONE = "history-one"
local TITLE_TWO = "history-two"
local COMMAND_ONE = "echo HISTORY-PANE-ONE"
local COMMAND_TWO = "echo HISTORY-PANE-TWO"
local SECOND_CWD = "C:/Windows"

local scenario_dir = support.scenario_dir(report_path)
local expected_path = scenario_dir .. "/.history-expected.json"
local second_report_path = scenario_dir .. "/.history-report.json"
local second_pid_path = scenario_dir .. "/.history.pid"
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

local function pane_id(pane)
    local ok, id = pcall(pane.pane_id, pane)
    if ok then
        return id
    end
    return nil
end

local function pane_text(pane, lines)
    local ok, text = pcall(pane.get_lines_as_text, pane, lines or 120)
    if ok and type(text) == "string" then
        return text
    end
    return nil
end

local function wait_for_text(pane, needle, timeout_seconds, on_ready, on_timeout)
    local deadline = os.time() + timeout_seconds
    local function tick()
        local text = pane_text(pane, 200)
        if text ~= nil and text:find(needle, 1, true) then
            on_ready(text)
            return
        end
        if os.time() >= deadline then
            on_timeout(text or "")
            return
        end
        wezterm.time.call_after(0.2, tick)
    end
    wezterm.time.call_after(0.2, tick)
end

local function history_path(id)
    return state.state_dir() .. "/history/" .. tostring(id) .. ".txt"
end

local function contains(path, needle)
    local text = support.read_text(path)
    return text ~= nil and text:find(needle, 1, true) ~= nil, text
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
            pcall(tab.set_title, tab, TITLE_ONE)
            local id_one = pane_id(root)

            local tab_ok, tab_two, pane_two = pcall(window.spawn_tab, window, {
                cwd = SECOND_CWD,
            })
            if not tab_ok or tab_two == nil or pane_two == nil then
                add("layout_built", false, "spawn_tab failed: " .. tostring(tab_two))
                finish()
                return
            end
            pcall(tab_two.set_title, tab_two, TITLE_TWO)
            local id_two = pane_id(pane_two)
            add("layout_built", true,
                string.format("two tabs, pane %s and pane %s", tostring(id_one), tostring(id_two)))

            local type_commands, wait_for_history, wait_for_save
            local ready = 0
            local function pane_ready()
                ready = ready + 1
                if ready == 2 then
                    type_commands(id_one, id_two, root, pane_two)
                end
            end
            local function not_ready(which, text)
                add("prompts", false,
                    which .. " prompt missing; last text: " .. tostring(text):sub(-200))
                finish()
            end
            wait_for_text(root, "PS ", 12, pane_ready, function(text)
                not_ready("first", text)
            end)
            wait_for_text(pane_two, "PS ", 12, pane_ready, function(text)
                not_ready("second", text)
            end)

            type_commands = function(first_id, second_id, first_pane, second_pane)
                local typed_one = pcall(first_pane.send_text, first_pane, COMMAND_ONE .. "\r")
                local typed_two = pcall(second_pane.send_text, second_pane, COMMAND_TWO .. "\r")
                add("commands_sent", typed_one and typed_two,
                    string.format("%s / %s", COMMAND_ONE, COMMAND_TWO))
                wait_for_history(first_id, second_id)
            end

            local history_polls = 0
            wait_for_history = function(first_id, second_id)
                history_polls = history_polls + 1
                local one_ok, one_text = contains(history_path(first_id), COMMAND_ONE)
                local two_ok, two_text = contains(history_path(second_id), COMMAND_TWO)
                local one_has_two = (one_text or ""):find(COMMAND_TWO, 1, true) ~= nil
                local two_has_one = (two_text or ""):find(COMMAND_ONE, 1, true) ~= nil
                if one_ok and two_ok then
                    add("history_file_one", one_has_two == false,
                        "pane " .. tostring(first_id) .. " history: " .. tostring(one_text))
                    add("history_file_two", two_has_one == false,
                        "pane " .. tostring(second_id) .. " history: " .. tostring(two_text))
                    wait_for_save(first_id, second_id)
                    return
                end
                if history_polls > 50 then
                    add("history_files", false, string.format(
                        "one=%s two=%s one_text=%q two_text=%q",
                        tostring(one_ok), tostring(two_ok),
                        tostring(one_text), tostring(two_text)))
                    finish()
                    return
                end
                wezterm.time.call_after(0.1, function()
                    wait_for_history(first_id, second_id)
                end)
            end

            local instance_id = state.instance_id()
            local saved, await_second, stop_second
            local save_polls = 0
            wait_for_save = function(first_id, second_id)
                save_polls = save_polls + 1
                local snapshot = state.read(instance_id)
                if snapshot ~= nil
                    and type(snapshot.tabs) == "table"
                    and #snapshot.tabs == 2
                    and snapshot.tabs[1].title == TITLE_ONE
                    and snapshot.tabs[2].title == TITLE_TWO
                then
                    saved(snapshot, first_id, second_id)
                    return
                end
                if save_polls > 150 then
                    add("state_saved", false, "no two-tab save after 15s")
                    finish()
                    return
                end
                wezterm.time.call_after(0.1, function()
                    wait_for_save(first_id, second_id)
                end)
            end

            saved = function(snapshot, first_id, second_id)
                add("state_saved", true,
                    string.format("two tabs, %s and %s", TITLE_ONE, TITLE_TWO))
                local expected = {
                    state = snapshot,
                    commands = {
                        [tostring(first_id)] = COMMAND_ONE,
                        [tostring(second_id)] = COMMAND_TWO,
                    },
                }
                local encoded_ok, encoded = pcall(wezterm.json_encode, expected)
                local wrote = encoded_ok and support.write_text(expected_path, encoded)
                add("expected_written", wrote == true,
                    wrote == true and expected_path or tostring(encoded))

                local peer_config = repo_root .. "/tests/scenarios/support/history_second.lua"
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
                            add("restart_" .. tostring(check.name), check.ok == true,
                                tostring(check.detail or ""))
                        end
                        add("second_report", parsed.ok == true,
                            string.format("%d check(s), ok=%s", #parsed.checks,
                                tostring(parsed.ok)))
                        stop_second()
                        return
                    end
                end
                if second_polls > 250 then
                    add("second_report", false,
                        "no history report after 25s (artifacts: " .. scenario_dir .. ")")
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
