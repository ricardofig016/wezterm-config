-- Schema version 1: one state file per live instance under a sessions folder,
-- plus an optional pinned layout that always wins restore and never expires.
--
-- Layout (cells everywhere; pane rectangles are tab-relative from 0,0):
--
--   <state dir>\pinned.json                      optional pinned layout
--   <state dir>\sessions\<instance id>.json       one file per live instance
--   <state dir>\sessions\<instance id>.json.tmp   transient write target
--
-- An instance writes only its own file, so two live instances can never
-- overwrite each other. read_latest() lists the sessions folder with
-- wezterm.read_dir, which this build provides, and returns the valid state with
-- the newest saved_at. Pinned.json is never part of that listing. There is no
-- pointer or index file; a crash can only leave a .json.tmp behind, which the
-- next save of that instance truncates and overwrites. instance_id() is
-- memoized, so repeated saves reuse one file.
local wezterm = require("wezterm")
local log = require("lib.log")

local M = {}

M.SCHEMA_VERSION = 1
M.MAX_AGE_SECONDS = 604800

local DEFAULT_STATE_DIR = "C:\\Users\\rfigueiredo\\AppData\\Roaming\\wezterm-session-layer"
local SESSION_SUFFIX = ".json"
local TMP_SUFFIX = ".tmp"
local PINNED_NAME = "pinned.json"
local SESSION_KEEP = 3

local function env(name)
    local ok, value = pcall(os.getenv, name)
    if ok and value ~= nil and value ~= "" then
        return value
    end
end

function M.state_dir()
    return env("WEZTERM_SESSION_STATE_DIR") or DEFAULT_STATE_DIR
end

function M.sessions_dir()
    return M.state_dir() .. "\\sessions"
end

local cached_id

function M.instance_id()
    if cached_id == nil then
        cached_id = string.format("%d-%06x", os.time(), math.random(0, 0xffffff))
    end
    return cached_id
end

function M.path(id)
    return M.sessions_dir() .. "\\" .. tostring(id) .. SESSION_SUFFIX
end

function M.pinned_path()
    return M.state_dir() .. "\\" .. PINNED_NAME
end

-- mkdir is not exposed by the sandbox Lua API, so fall back to cmd when the
-- first open fails. The common path never spawns a process.
local function ensure_dir(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    local ok = pcall(os.execute, 'mkdir "' .. path:gsub("/", "\\") .. '" 2>nul')
    return ok
end

local function file_exists(path)
    local handle = io.open(path, "r")
    if handle then
        handle:close()
        return true
    end
    return false
end

local function read_text(path)
    local handle = io.open(path, "r")
    if not handle then
        return nil
    end
    local data = handle:read("*a")
    handle:close()
    return data
end

local function parse_text(text)
    if type(text) ~= "string" or text == "" then
        return nil
    end
    local ok, value = pcall(wezterm.json_parse, text)
    if not ok or type(value) ~= "table" then
        return nil
    end
    return value
end

local function parse_path(path)
    return parse_text(read_text(path))
end

-- Every full path of the session files, sorted for determinism. read_dir
-- raises when the folder does not exist yet, which just means "no state".
-- pinned.json lives beside sessions\, not inside it, and is never included.
local function list_session_files()
    local dir = M.sessions_dir()
    local files = {}
    local ok, entries = pcall(wezterm.read_dir, dir)
    if not ok or type(entries) ~= "table" then
        return files
    end
    for _, entry in ipairs(entries) do
        local text = tostring(entry)
        local name = text:match("([^\\/]+)$") or text
        if name:sub(-#SESSION_SUFFIX) == SESSION_SUFFIX and name:lower() ~= PINNED_NAME then
            if text:find("[\\/]") then
                files[#files + 1] = text
            else
                files[#files + 1] = dir .. "\\" .. name
            end
        end
    end
    table.sort(files)
    return files
end

local function is_integer(value)
    return type(value) == "number" and value == math.floor(value)
end

local function is_string(value)
    return type(value) == "string"
end

local function is_non_negative_integer(value)
    return is_integer(value) and value >= 0
end

local function valid_rect(rect)
    if type(rect) ~= "table" then
        return false
    end
    if not is_integer(rect.left) or not is_integer(rect.top) then
        return false
    end
    if not is_integer(rect.width) or not is_integer(rect.height) then
        return false
    end
    return rect.width > 0 and rect.height > 0
end

local function valid_foreground(foreground)
    if foreground == nil then
        return true
    end
    if type(foreground) ~= "table" then
        return false
    end
    if type(foreground.argv) ~= "table" or #foreground.argv == 0 then
        return false
    end
    for _, argument in ipairs(foreground.argv) do
        if not is_string(argument) then
            return false
        end
    end
    return type(foreground.alt_screen) == "boolean"
end

local function valid_pane(pane)
    if type(pane) ~= "table" then
        return false
    end
    if not is_integer(pane.id) then
        return false
    end
    if not valid_rect(pane.rect) then
        return false
    end
    if not is_string(pane.cwd) then
        return false
    end
    return valid_foreground(pane.foreground)
end

local function valid_tab(tab)
    if type(tab) ~= "table" then
        return false
    end
    if not is_string(tab.title) or type(tab.panes) ~= "table" then
        return false
    end
    for _, pane in ipairs(tab.panes) do
        if not valid_pane(pane) then
            return false
        end
    end
    return true
end

function M.validate(t)
    if type(t) ~= "table" then
        return false
    end
    if t.version ~= M.SCHEMA_VERSION then
        return false
    end
    if not is_non_negative_integer(t.saved_at) then
        return false
    end

    local instance = t.instance
    if type(instance) ~= "table" then
        return false
    end
    if not is_string(instance.id) or instance.id == "" then
        return false
    end
    if not is_non_negative_integer(instance.started_at) then
        return false
    end

    local window = t.window
    if type(window) ~= "table" then
        return false
    end
    if not is_non_negative_integer(window.cols) or not is_non_negative_integer(window.rows) then
        return false
    end
    if not is_integer(window.active_tab) or window.active_tab < 1 then
        return false
    end
    -- active_tab is a one-based position, but active_pane is a pane id and this
    -- build numbers panes from zero. A non-empty state must point at a pane that
    -- actually exists in the active tab; an empty state has no pane to match.
    if not is_integer(window.active_pane) or window.active_pane < 0 then
        return false
    end

    if type(t.tabs) ~= "table" then
        return false
    end
    for _, tab in ipairs(t.tabs) do
        if not valid_tab(tab) then
            return false
        end
    end
    if #t.tabs > 0 then
        local active_tab = t.tabs[window.active_tab]
        if active_tab == nil then
            return false
        end
        local found = false
        for _, pane in ipairs(active_tab.panes) do
            if pane.id == window.active_pane then
                found = true
                break
            end
        end
        if not found then
            return false
        end
    end
    return true
end

local function valid_pinned(t)
    return M.validate(t) and is_non_negative_integer(t.pinned_at)
end

-- A pin never expires on its own: deliberately no is_stale check here.
function M.read_pinned()
    local path = M.pinned_path()
    if not file_exists(path) then
        return nil
    end
    local value = parse_path(path)
    if value == nil or not valid_pinned(value) then
        return nil, "invalid"
    end
    return value
end

-- The suite sets WEZTERM_SESSION_TEST=1 on every launch. If a test forgets its
-- state-directory override, refuse the write instead of touching real state.
local function test_write_blocked()
    if env("WEZTERM_SESSION_TEST") ~= "1" then
        return nil
    end
    if env("WEZTERM_SESSION_STATE_DIR") ~= nil then
        return nil
    end
    return "refusing to write the real state directory while WEZTERM_SESSION_TEST=1; "
        .. "set WEZTERM_SESSION_STATE_DIR"
end

local function guard_write(target)
    local reason = test_write_blocked()
    if reason == nil then
        return nil
    end
    log.warn("save.blocked", { path = tostring(target), reason = reason })
    return reason
end

-- Returns whether a pin existed and was removed.
function M.unpin()
    local path = M.pinned_path()
    if not file_exists(path) then
        return false
    end
    return os.remove(path) ~= nil
end

function M.read(id)
    if id == nil or id == "" then
        return nil
    end
    local value = parse_path(M.path(id))
    if value and M.validate(value) then
        return value
    end
    return nil
end

function M.read_latest()
    local best
    for _, file in ipairs(list_session_files()) do
        local value = parse_path(file)
        if value and M.validate(value) then
            local newer = best == nil
            if not newer and value.saved_at > best.saved_at then
                newer = true
            end
            if
                not newer
                and value.saved_at == best.saved_at
                and tostring(value.instance.id) > tostring(best.instance.id)
            then
                newer = true
            end
            if newer then
                best = value
            end
        end
    end
    return best
end

function M.is_stale(t, now)
    if type(t) ~= "table" or not is_integer(t.saved_at) then
        return true
    end
    now = now or os.time()
    return (now - t.saved_at) > M.MAX_AGE_SECONDS
end

-- Stable across a save that only changes saved_at (and instance), so the
-- change detector can compare fingerprints instead of tables. Covers the
-- window cell size with its active tab and pane, plus every tab title, pane
-- id, rectangle and cwd.
function M.fingerprint(t)
    if type(t) ~= "table" then
        return ""
    end
    local parts = { "v=" .. tostring(t.version) }
    local window = t.window
    if type(window) == "table" then
        parts[#parts + 1] = string.format(
            "w=%s,%s,%s,%s",
            tostring(window.cols),
            tostring(window.rows),
            tostring(window.active_tab),
            tostring(window.active_pane)
        )
    end
    if type(t.tabs) == "table" then
        for tab_index, tab in ipairs(t.tabs) do
            local panes = type(tab.panes) == "table" and tab.panes or {}
            parts[#parts + 1] = string.format(
                "t%d=%s|%d",
                tab_index,
                tostring(tab.title),
                #panes
            )
            for pane_index, pane in ipairs(panes) do
                local rect = type(pane.rect) == "table" and pane.rect or {}
                parts[#parts + 1] = string.format(
                    "p%d.%d=%s,%s,%s,%s,%s,%s",
                    tab_index,
                    pane_index,
                    tostring(pane.id),
                    tostring(rect.left),
                    tostring(rect.top),
                    tostring(rect.width),
                    tostring(rect.height),
                    tostring(pane.cwd)
                )
            end
        end
    end
    return table.concat(parts, "\30")
end

-- A valid, empty state: no tabs, so restore can reject it as "no windows"
-- without the validator itself rejecting the shape.
function M.empty()
    local now = os.time()
    return {
        version = M.SCHEMA_VERSION,
        saved_at = now,
        instance = { id = M.instance_id(), started_at = now },
        window = { cols = 0, rows = 0, active_tab = 1, active_pane = 0 },
        tabs = {},
    }
end

local function parent_dir(path)
    return tostring(path):match("^(.*)[\\/][^\\/]*$")
end

local function write_atomic(t, final_path, validator)
    local tmp_path = final_path .. TMP_SUFFIX

    local ok, text = pcall(wezterm.json_encode, t)
    if not ok or type(text) ~= "string" then
        return false
    end

    local handle = io.open(tmp_path, "w")
    if not handle then
        ensure_dir(parent_dir(tmp_path))
        handle = io.open(tmp_path, "w")
    end
    if not handle then
        return false
    end

    local wrote = pcall(function()
        handle:write(text)
        handle:flush()
        handle:close()
    end)
    if not wrote then
        pcall(function()
            handle:close()
        end)
        os.remove(tmp_path)
        return false
    end

    -- Validate what is actually on disk, not just what we meant to write, so a
    -- truncated or corrupt temporary file can never replace the previous state.
    local fresh = read_text(tmp_path)
    if fresh == nil or fresh ~= text then
        os.remove(tmp_path)
        return false
    end
    local parsed = parse_text(fresh)
    if parsed == nil or parsed.version ~= M.SCHEMA_VERSION or not validator(parsed) then
        os.remove(tmp_path)
        return false
    end

    -- Windows rename refuses an existing destination. Keep the old state until
    -- the fresh file has proved itself, then remove and retry. Never remove the
    -- old state unless the validated temp file is still there to replace it.
    if not os.rename(tmp_path, final_path) then
        if not file_exists(tmp_path) then
            return false
        end
        os.remove(final_path)
        if not os.rename(tmp_path, final_path) then
            os.remove(tmp_path)
            return false
        end
    end
    return true
end

-- Keep the three newest session files no matter how old they are; only stale
-- files beyond that are removed. pinned.json is not in the sessions listing.
function M.prune(now)
    now = now or os.time()
    local entries = {}
    for _, file in ipairs(list_session_files()) do
        local value = parse_path(file)
        if value and M.validate(value) then
            entries[#entries + 1] = { file = file, state = value }
        end
    end
    table.sort(entries, function(a, b)
        if a.state.saved_at ~= b.state.saved_at then
            return a.state.saved_at > b.state.saved_at
        end
        return tostring(a.state.instance.id) > tostring(b.state.instance.id)
    end)

    local removed = 0
    for index, entry in ipairs(entries) do
        if index > SESSION_KEEP and M.is_stale(entry.state, now) then
            if os.remove(entry.file) then
                removed = removed + 1
            end
        end
    end
    return removed
end

function M.write(t)
    if not M.validate(t) then
        return false
    end
    local final_path = M.path(t.instance.id)
    local blocked = guard_write(final_path)
    if blocked ~= nil then
        return false, blocked
    end
    return write_atomic(t, final_path, M.validate)
end

function M.write_pinned(t)
    if not valid_pinned(t) then
        return false, "pinned state must be a valid version 1 state with an integer pinned_at"
    end
    local final_path = M.pinned_path()
    local blocked = guard_write(final_path)
    if blocked ~= nil then
        return false, blocked
    end
    return write_atomic(t, final_path, valid_pinned)
end


return M
