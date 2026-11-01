-- Step 10 fault injection: stale, schema-mismatched, truncated, unwritable and
-- concurrent state. Every restore-level case must log a restore. event, show
-- the failure status, and leave a usable maximized window instead of a partial
-- or wrong layout. The writer case proves a refused write leaves no temp file
-- and keeps the previous state; the concurrency cases prove per-instance files
-- never overwrite each other and that pruning keeps the newer file.
local wezterm = require("wezterm")
local state = require("lib.state")
local layout = require("lib.layout")
local log = require("lib.log")
local save = require("lib.save")

local function sample_state(id, saved_at)
    return {
        version = state.SCHEMA_VERSION,
        saved_at = saved_at,
        instance = { id = id, started_at = saved_at - 10 },
        window = { cols = 99, rows = 50, active_tab = 1, active_pane = 7 },
        tabs = {
            {
                title = "faults",
                panes = {
                    {
                        id = 7,
                        rect = { left = 0, top = 0, width = 99, height = 50 },
                        cwd = "C:\\work",
                    },
                },
            },
        },
    }
end

local dir_counter = 0

-- Redirect the state directory to a unique temp folder for one test and remove
-- it afterwards, so no fault touches real state.
local function with_state_dir(fn)
    dir_counter = dir_counter + 1
    local base = (os.getenv("TEMP") or "."):gsub("\\", "/")
    local dir = string.format("%s/wezterm-faults-%d-%d", base, os.time(), dir_counter)
    dir = dir:gsub("/", "\\")
    os.execute('mkdir "' .. dir .. '"')

    local real_getenv = os.getenv
    os.getenv = function(name)
        if name == "WEZTERM_SESSION_STATE_DIR" then
            return dir
        end
        return real_getenv(name)
    end

    local ok, err = pcall(fn, dir)
    os.getenv = real_getenv
    os.execute('rmdir /s /q "' .. dir .. '"')
    if not ok then
        error(err, 0)
    end
end

local function write_raw(path, text)
    os.execute('mkdir "' .. state.sessions_dir():gsub("/", "\\") .. '"')
    local handle = io.open(path, "w")
    if not handle then
        error("could not write " .. path)
    end
    handle:write(text)
    handle:close()
end

local function with_log(fn)
    local events = {}
    local saved = {}
    for _, level in ipairs({ "debug", "info", "warn", "error" }) do
        saved[level] = log[level]
        log[level] = function(event, fields)
            events[#events + 1] = { level = level, event = event, fields = fields }
            return true
        end
    end
    saved.init = log.init
    log.init = function()
        return true
    end

    local ok, err = pcall(fn, events)

    log.init = saved.init
    log.debug = saved.debug
    log.info = saved.info
    log.warn = saved.warn
    log.error = saved.error
    if not ok then
        error(err, 0)
    end
end

local function find_event(events, name)
    for _, event in ipairs(events) do
        if event.event == name then
            return event
        end
    end
    return nil
end

-- Minimal fake mux for the fallback path: enough to spawn one window, maximize
-- it and record the right status. These fault cases never reach replay.
local function with_restore_fakes(fn)
    local env = { windows = {}, spawn = nil, spawned_tabs = {} }

    local function make_pane()
        return {
            split = function()
                return make_pane()
            end,
            get_foreground_process_info = function()
                return nil
            end,
            send_text = function() end,
            activate = function() end,
            pane_id = function()
                return 0
            end,
            get_current_working_dir = function()
                return nil
            end,
        }
    end

    local function make_tab()
        return {
            set_title = function() end,
            activate = function() end,
            get_title = function()
                return ""
            end,
            panes_with_info = function()
                return {}
            end,
        }
    end

    local function make_window()
        local window = { maximized = 0, statuses = {} }
        function window:spawn_tab(args)
            local tab, pane = make_tab(), make_pane()
            env.spawned_tabs[#env.spawned_tabs + 1] = { args = args, tab = tab, pane = pane }
            return tab, pane, window
        end
        function window:gui_window()
            return {
                maximize = function()
                    window.maximized = window.maximized + 1
                end,
                set_right_status = function(_, text)
                    window.statuses[#window.statuses + 1] = text
                end,
            }
        end
        return window
    end

    env.mux = {
        spawn_window = function(args)
            local window = make_window()
            local tab, pane = make_tab(), make_pane()
            env.spawn = { args = args, tab = tab, pane = pane, window = window }
            env.windows[#env.windows + 1] = window
            return tab, pane, window
        end,
        all_windows = function()
            return env.windows
        end,
    }

    local real_mux = wezterm.mux
    local real_time = wezterm.time
    wezterm.mux = env.mux
    wezterm.time = {
        call_after = function(_, callback)
            callback()
        end,
        now = real_time.now,
    }

    local ok, err = pcall(fn, env)

    wezterm.mux = real_mux
    wezterm.time = real_time
    if not ok then
        error(err, 0)
    end
end

-- A one-tab, one-pane fake window for save.collect, so the real save path can
-- reach the real state writer.
local function fake_save_window()
    local pane = {
        pane_id = function()
            return 7
        end,
        get_current_working_dir = function()
            return { file_path = "/C:/work" }
        end,
        is_alt_screen_active = function()
            return false
        end,
        get_foreground_process_info = function()
            return nil
        end,
        get_title = function()
            return "pwsh.exe"
        end,
    }
    local tab = {
        get_title = function()
            return "faults"
        end,
        panes_with_info = function()
            return {
                {
                    index = 1,
                    is_active = true,
                    is_zoomed = false,
                    left = 0,
                    top = 0,
                    width = 99,
                    height = 50,
                    pane = pane,
                },
            }
        end,
    }
    local mux = {
        tabs_with_info = function()
            return { { index = 1, is_active = true, tab = tab } }
        end,
    }
    local window = { statuses = {} }
    function window:mux_window()
        return mux
    end
    function window:set_right_status(text)
        self.statuses[#self.statuses + 1] = text
    end
    return window
end

local function sessions_entries()
    local ok, entries = pcall(wezterm.read_dir, state.sessions_dir())
    if not ok or type(entries) ~= "table" then
        return {}
    end
    return entries
end

return {
    {
        name = "a stale state file logs, shows a failure and opens a maximized fallback",
        run = function(t)
            with_state_dir(function()
                local stale = sample_state(state.instance_id(), os.time() - state.MAX_AGE_SECONDS - 10)
                t.ok(state.write(stale), "seed a stale state")
                local latest = state.read_latest()
                t.ok(latest ~= nil, "read_latest must return the valid stale file")

                with_log(function(events)
                    with_restore_fakes(function(env)
                        t.eq(layout.restore(nil, latest), false)
                        t.ok(find_event(events, "restore.stale") ~= nil, "the stale rejection must be logged")
                        t.eq(env.spawn.window.statuses, { " restore failed ", "" })
                        t.eq(env.spawn.args.width, nil, "a stale state must not spawn a restored layout")
                        t.eq(env.spawn.window.maximized, 1)
                    end)
                end)
            end)
        end,
    },
    {
        name = "a schema mismatch logs, shows a failure and opens a maximized fallback",
        run = function(t)
            with_state_dir(function()
                local raw = '{"version":2,"saved_at":1}'
                write_raw(state.path("future"), raw)
                t.eq(state.read_latest(), nil, "read_latest must skip the future schema")
                local future = wezterm.json_parse(raw)

                with_log(function(events)
                    with_restore_fakes(function(env)
                        t.eq(layout.restore(nil, future), false)
                        t.ok(find_event(events, "restore.version") ~= nil, "the version rejection must be logged")
                        t.eq(env.spawn.window.statuses, { " restore failed ", "" })
                        t.eq(env.spawn.args.width, nil, "a schema mismatch must not spawn a restored layout")
                        t.eq(env.spawn.window.maximized, 1)
                    end)
                end)
            end)
        end,
    },
    {
        name = "a truncated state file is skipped and logs a maximized fallback",
        run = function(t)
            with_state_dir(function()
                write_raw(state.path("truncated"), '{"version":1,"saved_at":')
                t.eq(state.read_latest(), nil, "read_latest must skip the truncated file")

                with_log(function(events)
                    with_restore_fakes(function(env)
                        t.eq(layout.restore(nil, state.read_latest()), false)
                        t.ok(find_event(events, "restore.no_state") ~= nil, "the skipped state must be logged")
                        t.eq(env.spawn.window.statuses, { " restore failed ", "" })
                        t.eq(env.spawn.args.width, nil, "a truncated state must not spawn a restored layout")
                        t.eq(env.spawn.window.maximized, 1)
                    end)
                end)
            end)
        end,
    },
    {
        name = "an unwritable state directory logs and leaves no partial file",
        run = function(t)
            with_state_dir(function()
                local id = state.instance_id()
                local previous = sample_state(id, os.time() - 60)
                t.ok(state.write(previous), "seed the previous state")

                with_log(function(events)
                    local sessions = state.sessions_dir()
                    local real_open = io.open
                    io.open = function(path, mode, ...)
                        if
                            type(mode) == "string"
                            and mode:sub(1, 1) == "w"
                            and tostring(path):find(sessions, 1, true) ~= nil
                        then
                            return nil, "permission denied"
                        end
                        return real_open(path, mode, ...)
                    end

                    local fake_window = fake_save_window()
                    local ok, wrote = pcall(save.save_now, fake_window)
                    io.open = real_open

                    t.ok(ok, "save must not raise on an unwritable directory")
                    t.eq(wrote, false, "the failed write must be reported")
                    t.eq(
                        fake_window.statuses[1],
                        " save failed ",
                        "the failed save must be shown in the status area"
                    )
                    local failed = find_event(events, "save.failed")
                    t.ok(failed ~= nil, "the refused write must be logged")
                    t.eq(failed.fields.reason, "state.write refused the snapshot")
                end)

                t.eq(state.read(id), previous, "the previous state must survive a refused write")
                for _, entry in ipairs(sessions_entries()) do
                    local name = tostring(entry)
                    t.ok(name:sub(-4) ~= ".tmp", "no temporary file may be left behind: " .. name)
                end
            end)
        end,
    },
    {
        name = "two instances own two files and read_latest follows the newer write",
        run = function(t)
            with_state_dir(function()
                local first = sample_state("1700000100-0000aa", 100)
                local second = sample_state("1700000200-0000bb", 200)
                t.ok(state.write(first))
                t.ok(state.write(second))

                t.eq(state.read(first.instance.id), first)
                t.eq(state.read(second.instance.id), second, "the first instance's write must survive")
                t.eq(state.read_latest().instance.id, second.instance.id)

                local later = sample_state(first.instance.id, 300)
                t.ok(state.write(later))
                t.eq(state.read(second.instance.id), second, "the later write must not touch the other file")
                t.eq(state.read_latest().instance.id, first.instance.id)
            end)
        end,
    },
    {
        name = "pruning keeps the three newest and removes only stale files beyond them",
        run = function(t)
            with_state_dir(function()
                local now = os.time()
                local oldest_stale = sample_state("1700000300-0000cc", now - state.MAX_AGE_SECONDS - 10)
                local fresh = sample_state("1700000400-0000dd", now - 10)
                t.ok(state.write(oldest_stale))
                t.ok(state.write(fresh))
                t.eq(state.prune(now), 0, "fewer than three sessions cannot be pruned")
                t.ok(state.read(oldest_stale.instance.id) ~= nil)

                local older_fresh = sample_state("1700000500-0000ee", now - 20)
                local newer_fresh = sample_state("1700000501-0000ff", now - 5)
                local stale_third = sample_state("1600000000-0000ab", now - state.MAX_AGE_SECONDS - 50)
                t.ok(state.write(older_fresh))
                t.ok(state.write(newer_fresh))
                t.ok(state.write(stale_third))
                -- Five valid sessions: the three newest survive, the two stale
                -- ones beyond them are removed.
                t.eq(state.prune(now), 2, "stale files beyond the three newest are removed")
                t.eq(state.read(oldest_stale.instance.id), nil)
                t.eq(state.read(stale_third.instance.id), nil)
                t.eq(state.read_latest().instance.id, newer_fresh.instance.id)
                t.ok(state.read(older_fresh.instance.id) ~= nil, "the third newest survives")
            end)
        end,
    },
}
