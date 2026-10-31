-- Save collection, change detection and the explicit save key.
--
-- The detector is started from gui-startup, never from config load: WezTerm
-- evaluates a config twice per process, so a load-time timer would register
-- twice. Each tick collects the live window, fingerprints it with
-- state.fingerprint(), and writes only after the fingerprint has been stable
-- for DEBOUNCE_SECONDS. There is no unconditional periodic write.
local wezterm = require("wezterm")
local state = require("lib.state")
local log = require("lib.log")

local M = {}

M.TICK_SECONDS = 1
M.DEBOUNCE_SECONDS = 2
M.STATUS_SECONDS = 3
M.FAILURE_STATUS_SECONDS = 10

local started = false
local started_at
local last_written
local pending
local status_epoch = 0

-- Logging must never break the save path or the reschedule chain.
local function safe_log(level, event, fields)
    local emit = log[level]
    if type(emit) == "function" then
        pcall(emit, event, fields)
    end
end

local function now_seconds()
    return os.time()
end

local function instance_started_at()
    if started_at == nil then
        started_at = now_seconds()
    end
    return started_at
end

local function percent_decode(text)
    return (text:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

-- pane:get_current_working_dir() returns a Url object in this build. Its
-- file_path is decoded but carries the Windows leading slash ("/C:/..."), and
-- older string forms arrive as "file:///C:/...". Normalize both to "C:/...".
local function plain_path(value)
    if value == nil then
        return ""
    end

    if type(value) ~= "string" then
        local ok, file_path = pcall(function()
            return value.file_path
        end)
        if ok and type(file_path) == "string" then
            value = file_path
        else
            value = tostring(value)
        end
    end

    if type(value) ~= "string" then
        return ""
    end

    local path = value
    if path:sub(1, 7):lower() == "file://" then
        path = percent_decode(path:sub(8))
    end
    if path:match("^/[%a]:[/\\]") then
        path = path:sub(2)
    end
    return path
end

local function pane_title(pane)
    if pane == nil then
        return nil
    end
    local ok, title = pcall(pane.get_title, pane)
    if ok and type(title) == "string" then
        return title
    end
    return nil
end

local function tab_title(tab, active_pane)
    local ok, title = pcall(tab.get_title, tab)
    if ok and type(title) == "string" then
        return title
    end
    -- An unset tab title falls back to the pane title, which is what WezTerm
    -- displays. An explicitly empty title stays empty.
    return pane_title(active_pane) or ""
end

local function collect_foreground(pane)
    local info_ok, info = pcall(pane.get_foreground_process_info, pane)
    if not info_ok or type(info) ~= "table" then
        return nil
    end

    local alt_screen = false
    local alt_ok, alt = pcall(pane.is_alt_screen_active, pane)
    if alt_ok and alt == true then
        alt_screen = true
    end

    local argv = {}
    if type(info.argv) == "table" then
        for _, argument in ipairs(info.argv) do
            if type(argument) == "string" then
                argv[#argv + 1] = argument
            end
        end
    end

    local record
    if #argv > 0 then
        record = { argv = argv, alt_screen = alt_screen }
    end
    return { record = record, cwd = plain_path(info.cwd) }
end

local function collect_tab(tab)
    local infos_ok, infos = pcall(tab.panes_with_info, tab)
    if not infos_ok or type(infos) ~= "table" or #infos == 0 then
        error("tab has no panes", 0)
    end

    local active_index = 1
    local active_pane_object
    for position, info in ipairs(infos) do
        if type(info) ~= "table" or info.pane == nil then
            error("pane info " .. tostring(position) .. " has no pane", 0)
        end
        if info.is_active and active_pane_object == nil then
            active_index = position
            active_pane_object = info.pane
        end
    end
    if active_pane_object == nil then
        active_pane_object = infos[active_index].pane
    end

    local panes = {}
    local active_pane_id
    local width, height = 0, 0
    for position, info in ipairs(infos) do
        local pane = info.pane
        local id_ok, id = pcall(pane.pane_id, pane)
        if not id_ok or type(id) ~= "number" then
            error("pane " .. tostring(position) .. " has no numeric id", 0)
        end
        if position == active_index then
            active_pane_id = id
        end
        if
            type(info.left) ~= "number"
            or type(info.top) ~= "number"
            or type(info.width) ~= "number"
            or type(info.height) ~= "number"
        then
            error("pane " .. tostring(position) .. " has no cell rectangle", 0)
        end

        local cwd_ok, cwd_value = pcall(pane.get_current_working_dir, pane)
        local cwd = cwd_ok and plain_path(cwd_value) or ""
        local foreground = collect_foreground(pane)
        if cwd == "" and foreground ~= nil and foreground.cwd ~= "" then
            cwd = foreground.cwd
        end

        panes[#panes + 1] = {
            id = id,
            rect = {
                left = info.left,
                top = info.top,
                width = info.width,
                height = info.height,
            },
            cwd = cwd,
            foreground = foreground and foreground.record or nil,
        }

        width = math.max(width, info.left + info.width)
        height = math.max(height, info.top + info.height)
    end
    if active_pane_id == nil then
        error("active pane has no id", 0)
    end

    return {
        title = tab_title(tab, active_pane_object),
        panes = panes,
        -- The schema records pane identity, not a position. A position would
        -- point at the wrong pane whenever array order and ids diverge.
        active_pane = active_pane_id,
        width = width,
        height = height,
    }
end

-- Read the live window into the version 1 state shape. Returns the state, or
-- nil and a message. The caller decides whether a failure is fatal.
function M.collect(window)
    if window == nil then
        return nil, "window is required"
    end

    local ok, result = pcall(function()
        local mux = window:mux_window()
        if mux == nil then
            error("window:mux_window() returned nil", 0)
        end

        local infos = mux:tabs_with_info()
        if type(infos) ~= "table" or #infos == 0 then
            error("window has no tabs", 0)
        end

        local tabs = {}
        local active_tab = 1
        local active_size
        for position, item in ipairs(infos) do
            if type(item) ~= "table" or item.tab == nil then
                error("tab info " .. tostring(position) .. " has no tab", 0)
            end
            local collected = collect_tab(item.tab)
            tabs[#tabs + 1] = {
                title = collected.title,
                panes = collected.panes,
            }
            if item.is_active and active_size == nil then
                active_tab = position
                active_size = collected
            end
        end
        if active_size == nil then
            active_size = collect_tab(infos[active_tab].tab)
            tabs[active_tab] = {
                title = active_size.title,
                panes = active_size.panes,
            }
        end

        local snapshot = state.empty()
        snapshot.saved_at = now_seconds()
        snapshot.instance.started_at = instance_started_at()
        snapshot.window = {
            cols = active_size.width,
            rows = active_size.height,
            active_tab = active_tab,
            active_pane = active_size.active_pane,
        }
        snapshot.tabs = tabs

        if not state.validate(snapshot) then
            error("collected state failed validation", 0)
        end
        return snapshot
    end)

    if not ok then
        return nil, tostring(result)
    end
    return result
end

-- Pure debounce decision. last_written is the fingerprint of the last file this
-- instance wrote, pending is the fingerprint waiting to settle (or nil), and
-- current is the fingerprint observed at now. Returns whether to write and the
-- next pending table.
function M.decide(last_written, pending_state, current, now, settle_seconds)
    if type(current) ~= "string" then
        return false, pending_state
    end
    if last_written == current then
        return false, nil
    end

    now = now or now_seconds()
    settle_seconds = settle_seconds or M.DEBOUNCE_SECONDS
    if type(pending_state) ~= "table" or pending_state.fingerprint ~= current then
        return false, { fingerprint = current, since = now }
    end
    if type(pending_state.since) ~= "number" then
        return false, { fingerprint = current, since = now }
    end
    if now - pending_state.since >= settle_seconds then
        return true, pending_state
    end
    return false, pending_state
end

local function set_right_status(window, text)
    if window == nil then
        return false
    end
    local ok = pcall(function()
        window:set_right_status(text)
    end)
    return ok
end

-- Only the newest status may clear itself. A successful save therefore cannot
-- be wiped by an older failure timer, and a failure cannot be swallowed by an
-- older success timer.
local function clear_status_later(window, seconds, token)
    local ok = pcall(wezterm.time.call_after, seconds or M.STATUS_SECONDS, function()
        if token ~= nil and token ~= status_epoch then
            return
        end
        pcall(function()
            window:set_right_status("")
        end)
    end)
    return ok
end

local function show_status(window, text, seconds)
    if window == nil then
        return false
    end
    status_epoch = status_epoch + 1
    local token = status_epoch
    set_right_status(window, text)
    clear_status_later(window, seconds or M.STATUS_SECONDS, token)
    return true
end

local function show_failure(window)
    return show_status(window, " save failed ", M.FAILURE_STATUS_SECONDS)
end

local function pane_count(snapshot)
    local count = 0
    for _, tab in ipairs(snapshot.tabs) do
        count = count + #tab.panes
    end
    return count
end

local function write_snapshot(snapshot, trigger, window)
    local instance = tostring(snapshot.instance.id)
    local ok, wrote = pcall(state.write, snapshot)
    if not ok then
        local reason = tostring(wrote)
        safe_log("error", "save.failed", {
            trigger = trigger,
            instance = instance,
            reason = reason,
        })
        show_failure(window)
        return false
    end
    if not wrote then
        safe_log("error", "save.failed", {
            trigger = trigger,
            instance = instance,
            reason = "state.write refused the snapshot",
        })
        show_failure(window)
        return false
    end

    safe_log("info", "save.wrote", {
        trigger = trigger,
        instance = instance,
        tabs = #snapshot.tabs,
        panes = pane_count(snapshot),
        saved_at = snapshot.saved_at,
    })
    return true
end

local function find_window()
    local ok, windows = pcall(function()
        return wezterm.gui.gui_windows()
    end)
    if not ok or type(windows) ~= "table" or #windows == 0 then
        return nil
    end

    local fallback
    for _, window in ipairs(windows) do
        if fallback == nil then
            fallback = window
        end
        local focused_ok, focused = pcall(window.is_focused, window)
        if focused_ok and focused then
            return window
        end
    end
    return fallback
end

local function schedule_next()
    local ok, err = pcall(wezterm.time.call_after, M.TICK_SECONDS, M.tick)
    if not ok then
        safe_log("error", "save.failed", {
            trigger = "schedule",
            reason = tostring(err),
        })
        return false
    end
    return true
end

local function run_tick(now)
    local window = find_window()
    if window == nil then
        return
    end

    local snapshot, err = M.collect(window)
    if snapshot == nil then
        error(err or "collect failed", 0)
    end

    local current = state.fingerprint(snapshot)
    local should_write, next_pending = M.decide(last_written, pending, current, now)
    pending = next_pending
    if not should_write then
        return
    end

    snapshot.saved_at = now
    if write_snapshot(snapshot, "auto", window) then
        last_written = current
        pending = nil
    else
        -- Do not hammer an unwritable path every tick: start a fresh settle
        -- window and try again after it.
        pending = nil
    end
end

-- One detector tick. The body is wrapped so a collection, write or logging
-- error still schedules the next tick.
function M.tick(now)
    now = now or now_seconds()
    local ok, err = pcall(run_tick, now)
    if not ok then
        safe_log("warn", "save.tick_failed", { reason = tostring(err) })
    end
    schedule_next()
end

-- Start the detector. Idempotent: repeated gui-startup events or a double
-- config evaluation cannot register a second chain.
function M.start()
    if started then
        return true
    end
    started = true
    instance_started_at()
    if not schedule_next() then
        started = false
        return false
    end
    return true
end

-- Registered on gui-startup by the entry, after layout.on_gui_startup. Must
-- return true, for the same handler-silencing reason as the layout handler.
function M.on_gui_startup(cmd)
    local ok, err = pcall(M.start)
    if not ok then
        safe_log("warn", "save.tick_failed", { reason = "start: " .. tostring(err) })
    end
    return true
end

-- ALT+s. Writes immediately, updates the detector baseline, and shows a short
-- status message. Returns whether the write succeeded.
function M.save_now(window)
    if window == nil then
        safe_log("warn", "save.failed", { trigger = "manual", reason = "no window" })
        return false
    end

    local snapshot, err = M.collect(window)
    if snapshot == nil then
        safe_log("error", "save.failed", {
            trigger = "manual",
            reason = tostring(err),
        })
        show_failure(window)
        return false
    end

    snapshot.saved_at = now_seconds()
    local current = state.fingerprint(snapshot)
    if not write_snapshot(snapshot, "manual", window) then
        return false
    end

    last_written = current
    pending = nil

    local clock = os.date("%H:%M:%S")
    show_status(window, " saved " .. clock .. " ", M.STATUS_SECONDS)
    return true
end

return M
