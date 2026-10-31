-- Step 8b: two concurrent instances.
--
-- The scenario launches a second wezterm-gui with support\peer_instance.lua as
-- its config, against the same isolated state directory. Each instance must
-- write its own session file, neither may overwrite the other, and
-- state.read_latest() must return the more recently saved one.
--
-- The peer is tracked two ways: it is a child of this process, which the
-- runner's descendant scan kills, and its pid is written to .owned-pids, which
-- the runner also accepts when the pid is a new wezterm-gui process. The
-- scenario still kills it explicitly and confirms it is gone.
local wezterm = require("wezterm")

local config_dir = (wezterm.config_dir or ""):gsub("\\", "/"):gsub("/+$", "")
package.path = config_dir .. "/?.lua;" .. config_dir .. "/?/init.lua;" .. package.path
local support = require("support.integration")

local report_path = os.getenv("WEZTERM_SESSION_TEST_REPORT") or ""
local token = os.getenv("WEZTERM_SESSION_TEST_TOKEN") or ""

local GUI_PATH = "C:\\Program Files\\WezTerm\\wezterm-gui.exe"

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
local peer_pid_path = support.state_dir(report_path) .. "/peer.pid"
local owned_pids_path = support.scenario_dir(report_path) .. "/.owned-pids"

local function pane_count(snapshot)
    local count = 0
    for _, tab in ipairs(snapshot.tabs or {}) do
        count = count + #(tab.panes or {})
    end
    return count
end

-- Every session file on disk that parses and validates, newest first.
local function valid_sessions()
    local values = {}
    for _, name in ipairs(support.session_names(report_path)) do
        local id = name:sub(1, -6)
        local snapshot = state.read(id)
        if snapshot ~= nil then
            values[#values + 1] = { id = id, snapshot = snapshot }
        end
    end
    table.sort(values, function(a, b)
        return a.snapshot.saved_at > b.snapshot.saved_at
    end)
    return values
end

wezterm.on("gui-startup", function(_cmd)
    local peer_launched = false
    local active_tab = nil
    -- Forward declarations: the steps below schedule each other from timers, so
    -- every callee has to be in scope before its caller is defined.
    local await_peer_pid, await_two_sessions, observe, split_main, kill_peer

    support.await_window(8, function(_window, tab)
        support.settle(tab, 10, function(infos)
            add("starter_pane", #infos == 1, "panes=" .. tostring(#infos))
            active_tab = tab

            if peer_launched then
                return
            end
            peer_launched = true

            local peer_config = repo_root .. "/tests/scenarios/support/peer_instance.lua"
            local launched, launch_err = pcall(wezterm.background_child_process, {
                GUI_PATH,
                "--config-file",
                peer_config,
            })
            add("peer_launched", launched,
                launched and ("launched " .. peer_config) or tostring(launch_err))
            await_peer_pid()
        end, function(message)
            add("layout_settled", false, message)
            finish()
        end)
    end, function(message)
        add("window_present", false, message)
        finish()
    end)

    -- The peer records its own pid; verify it is a live wezterm-gui before this
    -- run agrees to track it, then hand it to the runner for guaranteed cleanup.
    local pid_polls = 0
    await_peer_pid = function()
        pid_polls = pid_polls + 1
        local pid = tonumber((support.read_text(peer_pid_path) or ""):match("%d+"))
        local info = nil
        if pid ~= nil then
            local ok, value = pcall(wezterm.procinfo.get_info_for_pid, pid)
            if ok then
                info = value
            end
        end
        if pid ~= nil and info ~= nil then
            local executable = tostring(info.executable or info.name or "")
            add("peer_running", executable:lower():find("wezterm%-gui", 1) ~= nil,
                string.format("pid=%d executable=%s", pid, executable))
            add("peer_declared_for_cleanup",
                support.write_text(owned_pids_path, tostring(pid) .. "\n"),
                "wrote " .. owned_pids_path)
            await_two_sessions(pid)
            return
        end
        if pid_polls > 80 then
            add("peer_running", false,
                "peer.pid never described a live process after 8s")
            finish()
            return
        end
        wezterm.time.call_after(0.1, await_peer_pid)
    end

    -- Wait until both instance files exist and validate.
    local session_polls = 0
    await_two_sessions = function(peer_pid)
        session_polls = session_polls + 1
        local values = valid_sessions()
        if #values >= 2 then
            local ids = {}
            for _, item in ipairs(values) do
                ids[#ids + 1] = item.id
            end
            add("two_session_files", true, table.concat(ids, ", "))
            observe(peer_pid, values)
            return
        end
        if session_polls > 150 then
            add("two_session_files", false,
                string.format("only %d valid session file(s) after 15s", #values))
            finish()
            return
        end
        wezterm.time.call_after(0.1, await_two_sessions)
    end

    observe = function(peer_pid, values)
        local main_id = state.instance_id()
        local main_entry, peer_entry = nil, nil
        for _, item in ipairs(values) do
            if item.id == main_id then
                main_entry = item
            else
                peer_entry = item
            end
        end
        if main_entry == nil or peer_entry == nil then
            add("instances_distinct", false,
                string.format("main=%s peer=%s expected two different instance ids",
                    tostring(main_id), tostring(peer_pid)))
            finish()
            return
        end
        add("instances_distinct", main_entry.id ~= peer_entry.id,
            string.format("main=%s peer=%s", main_entry.id, peer_entry.id))

        local main_text = support.read_text(state.path(main_entry.id))
        local peer_text = support.read_text(state.path(peer_entry.id))
        local peer_saved_at = peer_entry.snapshot.saved_at

        -- Neither instance may overwrite the other's file while both are idle.
        wezterm.time.call_after(1.5, function()
            add("no_overwrite_idle",
                support.read_text(state.path(main_entry.id)) == main_text
                    and support.read_text(state.path(peer_entry.id)) == peer_text,
                "both session files unchanged over 1.5 idle seconds")

            -- Wait until a later wall-clock second so the main instance's next
            -- save is strictly newer than the peer's, then change the layout.
            local second_polls = 0
            local function await_later_second()
                second_polls = second_polls + 1
                if os.time() > peer_saved_at or second_polls > 30 then
                    split_main(main_entry, peer_entry, peer_text, peer_saved_at)
                    return
                end
                wezterm.time.call_after(0.2, await_later_second)
            end
            await_later_second()
        end)
    end

    split_main = function(main_entry, peer_entry, peer_text, peer_saved_at)
        local current = active_tab:panes_with_info()
        local root = current[1] and current[1].pane or nil
        if root == nil then
            add("main_split", false, "no pane to split")
            finish()
            return
        end
        local ok, child = pcall(root.split, root, { direction = "Right", size = 40 })
        add("main_split", ok and child ~= nil,
            ok and "Right split, 40 cells" or ("split failed: " .. tostring(child)))

        local polls = 0
        local function await_newer_save()
            polls = polls + 1
            local main_now = state.read(main_entry.id)
            if main_now ~= nil
                and main_now.saved_at > peer_saved_at
                and pane_count(main_now) == 2
            then
                add("main_saved_later", true,
                    string.format("saved_at=%d peer_saved_at=%d after %.1fs",
                        main_now.saved_at, peer_saved_at, polls * 0.1))
                local latest = state.read_latest()
                add("read_latest_newest",
                    latest ~= nil and latest.instance.id == main_entry.id,
                    latest == nil and "read_latest returned nil"
                        or string.format("read_latest picked %s, expected %s",
                            tostring(latest.instance.id), main_entry.id))
                add("peer_not_overwritten",
                    support.read_text(state.path(peer_entry.id)) == peer_text,
                    "peer file unchanged after the main instance saved")
                kill_peer(peer_saved_at)
                return
            end
            if polls > 80 then
                add("main_saved_later", false, "no newer two-pane save after 8s")
                finish()
                return
            end
            wezterm.time.call_after(0.1, await_newer_save)
        end
        wezterm.time.call_after(0.1, await_newer_save)
    end

    kill_peer = function(peer_saved_at)
        local pid = tonumber((support.read_text(peer_pid_path) or ""):match("%d+"))
        if pid == nil then
            add("peer_stopped", false, "peer.pid disappeared before cleanup")
            finish()
            return
        end
        pcall(os.execute, string.format("taskkill /PID %d /T /F >nul 2>nul", pid))
        local polls = 0
        local function await_gone()
            polls = polls + 1
            local ok, info = pcall(wezterm.procinfo.get_info_for_pid, pid)
            if ok and info == nil then
                add("peer_stopped", true, string.format("pid %d is gone", pid))
                finish()
                return
            end
            if polls > 60 then
                add("peer_stopped", false,
                    string.format("pid %d still alive after 6s", pid))
                finish()
                return
            end
            wezterm.time.call_after(0.1, await_gone)
        end
        wezterm.time.call_after(0.1, await_gone)
    end
end)

return config
