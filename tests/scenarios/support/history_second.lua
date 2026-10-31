-- Second process for tests\scenarios\history_per_pane.lua.
--
-- Lives under support\ so the runner never discovers it. It evaluates the real
-- entry, lets gui-startup restore the two-tab state the driver saved, then asks
-- each restored pane for its PSReadLine history through pane:get_lines_as_text
-- and asserts that the pane only has its own commands.
local wezterm = require("wezterm")

local config_dir = (wezterm.config_dir or ""):gsub("\\", "/"):gsub("/+$", "")
local scenarios_dir = config_dir:gsub("/support$", "")
package.path = scenarios_dir .. "/?.lua;" .. scenarios_dir .. "/?/init.lua;"
    .. config_dir .. "/?.lua;" .. config_dir .. "/?/init.lua;" .. package.path
local support = require("support.integration")

local driver_report = os.getenv("WEZTERM_SESSION_TEST_REPORT") or ""
local scenario_dir = support.dirname(driver_report)
local expected_path = scenario_dir .. "/.history-expected.json"
local history_report_path = scenario_dir .. "/.history-report.json"
local pid_path = scenario_dir .. "/.history.pid"

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
    support.write(history_report_path, checks, { pid = support.pid(), token = "second" })
end

local pid_handle = io.open(pid_path, "w")
if pid_handle then
    pid_handle:write(tostring(wezterm.procinfo.pid()) .. "\n")
    pid_handle:close()
end

local expected_text = support.read_text(expected_path)
local expected = nil
if expected_text ~= nil then
    local parsed_ok, parsed = pcall(wezterm.json_parse, expected_text)
    if parsed_ok and type(parsed) == "table" then
        expected = parsed
    end
end
if expected == nil or type(expected.state) ~= "table" then
    add("expected_state", false, "could not read " .. expected_path)
    finish()
    return wezterm.config_builder()
end
add("expected_state", true, expected_path)

-- config_dir is <repo>\tests\scenarios\support.
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

local state = require("lib.state")

local function pane_id(pane)
    local ok, id = pcall(pane.pane_id, pane)
    if ok then
        return id
    end
    return nil
end

local function pane_text(pane, lines)
    local ok, text = pcall(pane.get_lines_as_text, pane, lines or 400)
    if ok and type(text) == "string" then
        return text
    end
    return nil
end

local function wait_for_text(pane, needle, timeout_seconds, on_ready, on_timeout)
    local deadline = os.time() + timeout_seconds
    local function tick()
        local text = pane_text(pane, 400)
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

-- The query builds its markers at runtime so the echoed command does not
-- contain the contiguous strings we search for in the output.
local QUERY = "$m='HISTPROBE'; $i='HIST'+'ITEM'; Write-Output ($m+'-BEGIN'); "
    .. "[Microsoft.PowerShell.PSConsoleReadLine]::GetHistoryItems() | "
    .. "ForEach-Object { ($i+':') + $_.CommandLine }; Write-Output ($m+'-END')"

local function items_from(text)
    local last_begin = nil
    local position = 1
    while true do
        local found = text:find("HISTPROBE-BEGIN", position, true)
        if found == nil then
            break
        end
        last_begin = found
        position = found + 1
    end
    if last_begin == nil then
        return nil
    end
    local after = text:sub(last_begin)
    local items = {}
    for line in after:gmatch("[^\r\n]+") do
        local item = line:match("HISTITEM:(.*)$")
        if item ~= nil then
            items[#items + 1] = item
        end
    end
    return items
end

local function list_contains(items, needle)
    for _, item in ipairs(items or {}) do
        if item:find(needle, 1, true) ~= nil then
            return true
        end
    end
    return false
end

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

wezterm.on("gui-startup", function(_cmd)
    support.await_window(10, function(window, first_tab)
        support.settle(first_tab, 10, function()
            local tabs = window:tabs()
            add("tab_count", type(tabs) == "table" and #tabs == 2,
                "tabs=" .. tostring(type(tabs) == "table" and #tabs or "nil"))
            if type(tabs) ~= "table" or #tabs ~= 2 then
                finish()
                return
            end

            -- Compare each restored tab with the saved one, then collect the
            -- live pane and saved id for the history query.
            local live_panes = {}
            local mapping = {}
            local rect_mismatch = nil
            for index, tab in ipairs(tabs) do
                local saved_tab = expected.state.tabs[index]
                local title_ok, title = pcall(tab.get_title, tab)
                add("tab_title_" .. tostring(index),
                    title_ok and title == saved_tab.title,
                    string.format("saved %q live %q", tostring(saved_tab.title),
                        tostring(title)))
                local infos = tab:panes_with_info()
                if #infos ~= 1 then
                    rect_mismatch = string.format("tab %d has %d pane(s)", index, #infos)
                elseif rect_key(live_rect(infos[1])) ~= rect_key(saved_tab.panes[1].rect) then
                    rect_mismatch = string.format("tab %d: saved %s live %s", index,
                        rect_key(saved_tab.panes[1].rect), rect_key(live_rect(infos[1])))
                else
                    live_panes[#live_panes + 1] = { tab = index, info = infos[1] }
                    mapping[index] = {
                        live = infos[1].pane,
                        saved_id = saved_tab.panes[1].id,
                        command = expected.commands[tostring(saved_tab.panes[1].id)],
                    }
                end
            end
            add("rects_exact", rect_mismatch == nil, rect_mismatch or "both panes identical")

            -- A live pane loads history on its first prompt, so wait for it.
            local query_all, query_pane
            local ready = 0
            local function pane_ready()
                ready = ready + 1
                if ready == 2 then
                    query_all(mapping)
                end
            end
            local function prompt_timeout(which, text)
                add("prompts", false,
                    which .. " prompt missing; last text: " .. tostring(text):sub(-300))
                finish()
            end
            wait_for_text(mapping[1].live, "PS ", 15, pane_ready, function(text)
                prompt_timeout("first", text)
            end)
            wait_for_text(mapping[2].live, "PS ", 15, pane_ready, function(text)
                prompt_timeout("second", text)
            end)

            local pending = 2
            local function pane_done()
                pending = pending - 1
                if pending <= 0 then
                    finish()
                end
            end

            query_pane = function(entry)
                local sent = pcall(entry.live.send_text, entry.live, QUERY .. "\r")
                add("query_sent_" .. tostring(entry.saved_id), sent,
                    "typed history query in pane " .. tostring(entry.saved_id))
                local polls = 0
                local function await_output()
                    polls = polls + 1
                    local text = pane_text(entry.live, 400)
                    if text ~= nil and text:find("HISTPROBE-END", 1, true) ~= nil then
                        local items = items_from(text)
                        local ok, item_detail
                        if items == nil then
                            ok = false
                            item_detail = "no HISTPROBE-BEGIN in pane text"
                        else
                            local has_own = list_contains(items, entry.command)
                            local has_sibling = false
                            for _, other in pairs(mapping) do
                                if other.saved_id ~= entry.saved_id
                                    and list_contains(items, other.command)
                                then
                                    has_sibling = true
                                end
                            end
                            ok = has_own and not has_sibling
                            item_detail = string.format("own=%s sibling=%s items=%q",
                                tostring(has_own), tostring(has_sibling),
                                table.concat(items, " | "))
                        end
                        add("pane_history_" .. tostring(entry.saved_id), ok, item_detail)

                        local file_ok, file_text = contains(history_path(entry.saved_id),
                            entry.command)
                        local sibling_in_file = false
                        for _, other in pairs(mapping) do
                            if other.saved_id ~= entry.saved_id then
                                local other_ok = (file_text or ""):find(other.command, 1, true) ~= nil
                                if other_ok then
                                    sibling_in_file = true
                                end
                            end
                        end
                        add("pane_file_" .. tostring(entry.saved_id),
                            file_ok and not sibling_in_file,
                            string.format("path=%s own=%s sibling=%s text=%q",
                                history_path(entry.saved_id), tostring(file_ok),
                                tostring(sibling_in_file), tostring(file_text)))
                        pane_done()
                        return
                    end
                    if polls > 80 then
                        add("pane_history_" .. tostring(entry.saved_id), false,
                            "no HISTPROBE-END after 8s; text: "
                                .. tostring(pane_text(entry.live, 400)):sub(-400))
                        pane_done()
                        return
                    end
                    wezterm.time.call_after(0.1, await_output)
                end
                wezterm.time.call_after(0.1, await_output)
            end

            query_all = function(all)
                if all[1] == nil or all[2] == nil then
                    add("panes_mapped", false, "a restored tab did not map to a saved pane")
                    finish()
                    return
                end
                query_pane(all[1])
                query_pane(all[2])
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
