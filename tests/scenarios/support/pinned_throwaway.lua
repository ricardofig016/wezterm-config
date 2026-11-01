-- Throwaway window for tests\scenarios\pinned_layout_wins.lua.
--
-- Lives under support\ so the runner never discovers it. It launches fresh,
-- restores the pin, then deliberately changes its own layout and waits for the
-- save detector to write a newer session file. That newer file is exactly what
-- used to steal the next restore; the driver keeps it and the third process
-- must ignore it in favour of the pin.
local wezterm = require("wezterm")

local config_dir = (wezterm.config_dir or ""):gsub("\\", "/"):gsub("/+$", "")
local scenarios_dir = config_dir:gsub("/support$", "")
package.path = scenarios_dir .. "/?.lua;" .. scenarios_dir .. "/?/init.lua;"
    .. config_dir .. "/?.lua;" .. config_dir .. "/?/init.lua;" .. package.path
local support = require("support.integration")

local driver_report = os.getenv("WEZTERM_SESSION_TEST_REPORT") or ""
local scenario_dir = support.dirname(driver_report)
local expected_path = scenario_dir .. "/.pin-expected.json"
local throwaway_path = scenario_dir .. "/.throwaway.json"
local pid_path = scenario_dir .. "/.throwaway.pid"

local pid_handle = io.open(pid_path, "w")
if pid_handle then
    pid_handle:write(tostring(wezterm.procinfo.pid()) .. "\n")
    pid_handle:close()
end

local expected = nil
do
    local text = support.read_text(expected_path)
    if text ~= nil then
        local ok, value = pcall(wezterm.json_parse, text)
        if ok and type(value) == "table" and type(value.state) == "table" then
            expected = value
        end
    end
end

local function write_result(ok, error_message, snapshot)
    local result = { ok = ok == true, error = error_message or "" }
    if snapshot ~= nil then
        result.instance_id = snapshot.instance.id
        result.saved_at = snapshot.saved_at
        result.pane_count = 0
        result.panes = {}
        for _, tab in ipairs(snapshot.tabs or {}) do
            for _, pane in ipairs(tab.panes or {}) do
                result.pane_count = result.pane_count + 1
                result.panes[#result.panes + 1] = pane.rect
            end
        end
    end
    local encoded_ok, encoded = pcall(wezterm.json_encode, result)
    if encoded_ok then
        support.write_text(throwaway_path, encoded)
    end
end

if expected == nil then
    write_result(false, "could not read " .. expected_path)
    return wezterm.config_builder()
end

local pinned_at = tonumber(expected.pinned_at) or -1
local pinned_panes = 0
for _, tab in ipairs(expected.state.tabs or {}) do
    pinned_panes = pinned_panes + #(tab.panes or {})
end

-- config_dir is <repo>\tests\scenarios\support.
local repo_root = scenarios_dir:match("^(.*)/tests/scenarios$")
package.path = repo_root .. "/?.lua;" .. repo_root .. "/?/init.lua;" .. package.path
local loaded, config = pcall(dofile, repo_root .. "/wezterm.lua")
if not loaded then
    write_result(false, "entry load failed: " .. tostring(config))
    return wezterm.config_builder()
end
config.automatically_reload_config = false

local state = require("lib.state")

wezterm.on("gui-startup", function(_cmd)
    support.await_window(10, function(_window, tab)
        support.settle(tab, 10, function(infos)
            -- The entry has restored the pin by now. Change this instance's
            -- layout so its own save is visibly different and newer.
            local root = infos[1] and infos[1].pane or nil
            if root == nil then
                write_result(false, "no pane to split")
                return
            end
            local ok, split_err = pcall(root.split, root, {
                direction = "Right",
                size = 25,
            })
            if not ok or split_err == nil then
                write_result(false, "split failed: " .. tostring(split_err))
                return
            end

            local instance_id = state.instance_id()
            local polls = 0
            local function await_save()
                polls = polls + 1
                local snapshot = state.read(instance_id)
                local count = 0
                if snapshot ~= nil then
                    for _, pane_tab in ipairs(snapshot.tabs or {}) do
                        count = count + #(pane_tab.panes or {})
                    end
                end
                if snapshot ~= nil
                    and snapshot.saved_at > pinned_at
                    and count > pinned_panes
                then
                    write_result(true, "", snapshot)
                    return
                end
                if polls > 150 then
                    write_result(false, string.format(
                        "no newer save after 15s (saved_at=%s pinned_at=%s panes=%d pinned=%d)",
                        snapshot ~= nil and tostring(snapshot.saved_at) or "nil",
                        tostring(pinned_at), count, pinned_panes))
                    return
                end
                wezterm.time.call_after(0.1, await_save)
            end
            wezterm.time.call_after(0.1, await_save)
        end, function(message)
            write_result(false, "layout settle failed: " .. tostring(message))
        end)
    end, function(message)
        write_result(false, "window wait failed: " .. tostring(message))
    end)
    return true
end)

return config
