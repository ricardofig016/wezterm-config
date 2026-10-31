-- Step 5 unit tests: collection from fake windows, fingerprint stability, and
-- the debounce decision. Timer behaviour and live-window behaviour belong to
-- the integration suite.
local wezterm = require("wezterm")
local save = require("lib.save")
local state = require("lib.state")
local log = require("lib.log")

local real_getenv = os.getenv

local function fake_pane(opts)
    local pane = {
        id = opts.id,
        cwd = opts.cwd,
        alt = opts.alt,
        foreground = opts.foreground,
        title = opts.title,
    }

    function pane:pane_id()
        return self.id
    end

    function pane:get_current_working_dir()
        return self.cwd
    end

    function pane:is_alt_screen_active()
        return self.alt == true
    end

    function pane:get_foreground_process_info()
        return self.foreground
    end

    function pane:get_title()
        return self.title
    end

    return pane
end

local function fake_tab(opts)
    local tab = { title = opts.title, panes = opts.panes }

    function tab:get_title()
        return self.title
    end

    function tab:panes_with_info()
        return self.panes
    end

    return tab
end

local function pane_info(pane, index, left, top, width, height, active)
    return {
        index = index,
        is_active = active == true,
        is_zoomed = false,
        left = left,
        top = top,
        width = width,
        height = height,
        pane = pane,
    }
end

local function fake_window(tab_entries)
    local mux = {}

    function mux:tabs_with_info()
        return tab_entries
    end

    local window = {}

    function window:mux_window()
        return mux
    end

    return window
end

local function one_tab_window(pane_opts, tab_title)
    local pane = fake_pane(pane_opts)
    local tab = fake_tab({
        title = tab_title,
        panes = { pane_info(pane, 0, 0, 0, 20, 10, true) },
    })
    return fake_window({
        { index = 0, is_active = true, tab = tab },
    }), pane
end

local function status_window(pane_opts, tab_title)
    local window, pane = one_tab_window(pane_opts, tab_title)
    window.status = nil
    function window:set_right_status(text)
        self.status = text
    end
    function window:is_focused()
        return true
    end
    return window, pane
end

local temp_counter = 0

local function next_dir(name)
    temp_counter = temp_counter + 1
    local base = (os.getenv("TEMP") or "."):gsub("\\", "/")
    local dir = string.format("%s/wezterm-save-spec-%d-%d-%s", base, os.time(), temp_counter, name)
    dir = dir:gsub("/", "\\")
    os.execute('mkdir "' .. dir .. '"')
    return dir
end

local function with_state_dir(name, fn)
    local dir = next_dir(name)
    os.getenv = function(var)
        if var == "WEZTERM_SESSION_STATE_DIR" then
            return dir
        end
        return real_getenv(var)
    end
    local ok, err = pcall(fn, dir)
    os.getenv = real_getenv
    os.execute('rmdir /s /q "' .. dir .. '"')
    if not ok then
        error(err, 0)
    end
end

local function with_fake_timers(fn)
    local real_call_after = wezterm.time.call_after
    local timers = {}
    wezterm.time.call_after = function(seconds, callback)
        timers[#timers + 1] = { seconds = seconds, callback = callback }
        return true
    end
    local ok, err = pcall(fn, timers)
    wezterm.time.call_after = real_call_after
    if not ok then
        error(err, 0)
    end
end

local function with_captured_logs(fn)
    local real_error = log.error
    local real_info = log.info
    local events = {}
    log.error = function(event, fields)
        events[#events + 1] = { level = "error", event = event, fields = fields }
        return true
    end
    log.info = function(event, fields)
        events[#events + 1] = { level = "info", event = event, fields = fields }
        return true
    end
    local ok, err = pcall(fn, events)
    log.error = real_error
    log.info = real_info
    if not ok then
        error(err, 0)
    end
end

local function with_blocked_state_write(blocked, fn)
    local real_open = io.open
    io.open = function(path, mode, ...)
        if path == blocked and type(mode) == "string" and mode:sub(1, 1) == "w" then
            return nil
        end
        return real_open(path, mode, ...)
    end
    local ok, err = pcall(fn)
    io.open = real_open
    if not ok then
        error(err, 0)
    end
end

return {
    {
        name = "collect reads tabs, titles, pane rects, cwds, active indices and dimensions",
        run = function(t)
            local first = fake_pane({
                id = 11,
                cwd = "/C:/work/alpha",
            })
            local foreground_pane = fake_pane({
                id = 12,
                cwd = { file_path = "/C:/work/beta" },
                alt = true,
                foreground = {
                    argv = { "vim", "a.txt" },
                    cwd = "/C:/work/beta",
                },
            })
            local last = fake_pane({
                id = 21,
                cwd = "file:///C:/work/gamma%20delta",
            })

            local editor = fake_tab({
                title = "editor",
                panes = {
                    pane_info(first, 0, 0, 0, 80, 24, false),
                    pane_info(foreground_pane, 1, 80, 0, 40, 24, true),
                },
            })
            local logs = fake_tab({
                title = "logs",
                panes = {
                    pane_info(last, 0, 0, 0, 120, 24, true),
                },
            })
            local window = fake_window({
                { index = 0, is_active = false, tab = editor },
                { index = 1, is_active = true, tab = logs },
            })

            local snapshot, err = save.collect(window)
            t.ok(snapshot ~= nil, "collect failed: " .. tostring(err))
            t.ok(state.validate(snapshot), "collected state must validate")
            t.eq(snapshot.version, state.SCHEMA_VERSION)
            t.eq(snapshot.window, {
                cols = 120,
                rows = 24,
                active_tab = 2,
                active_pane = 1,
            })
            t.eq(#snapshot.tabs, 2)
            t.eq(snapshot.tabs[1].title, "editor")
            t.eq(snapshot.tabs[2].title, "logs")
            t.eq(snapshot.tabs[1].panes, {
                {
                    id = 11,
                    rect = { left = 0, top = 0, width = 80, height = 24 },
                    cwd = "C:/work/alpha",
                },
                {
                    id = 12,
                    rect = { left = 80, top = 0, width = 40, height = 24 },
                    cwd = "C:/work/beta",
                    foreground = { argv = { "vim", "a.txt" }, alt_screen = true },
                },
            })
            t.eq(snapshot.tabs[2].panes, {
                {
                    id = 21,
                    rect = { left = 0, top = 0, width = 120, height = 24 },
                    cwd = "C:/work/gamma delta",
                },
            })
            t.eq(snapshot.instance.id, state.instance_id(), "the save uses this process instance id")
            t.ok(type(snapshot.instance.started_at) == "number", "started_at must be a number")

            local again = save.collect(window)
            t.ok(again ~= nil)
            t.eq(
                state.fingerprint(snapshot),
                state.fingerprint(again),
                "saved_at and identity must not affect the fingerprint"
            )
        end,
    },
    {
        name = "collect normalizes cwd forms and falls back to the foreground cwd",
        run = function(t)
            local cases = {
                { label = "url file_path", cwd = { file_path = "/C:/Users/me" }, expected = "C:/Users/me" },
                {
                    label = "file uri",
                    cwd = "file:///C:/Users/me/My%20Docs",
                    expected = "C:/Users/me/My Docs",
                },
                { label = "already a drive path", cwd = "C:/Users/me", expected = "C:/Users/me" },
                { label = "unix path", cwd = "/home/me", expected = "/home/me" },
                { label = "nil", cwd = nil, expected = "" },
            }

            for _, case in ipairs(cases) do
                local snapshot, err = save.collect(one_tab_window({ id = 1, cwd = case.cwd }))
                t.ok(snapshot ~= nil, case.label .. ": " .. tostring(err))
                t.eq(snapshot.tabs[1].panes[1].cwd, case.expected, case.label)
            end

            local fallback, fallback_err = save.collect(one_tab_window({
                id = 2,
                cwd = nil,
                foreground = {
                    argv = { "pwsh", "-NoLogo" },
                    alt_screen = false,
                    cwd = "/C:/fallback",
                },
            }))
            t.ok(fallback ~= nil, tostring(fallback_err))
            t.eq(fallback.tabs[1].panes[1].cwd, "C:/fallback")
        end,
    },
    {
        name = "collect records alt-screen foreground only when a process record exists",
        run = function(t)
            local record, err = save.collect(one_tab_window({
                id = 1,
                cwd = "/C:/work",
                alt = true,
                foreground = { argv = { "less", "app.log" }, alt_screen = true },
            }))
            t.ok(record ~= nil, tostring(err))
            t.eq(record.tabs[1].panes[1].foreground, {
                argv = { "less", "app.log" },
                alt_screen = true,
            })

            local no_info = save.collect(one_tab_window({
                id = 2,
                cwd = "/C:/work",
                alt = true,
                foreground = nil,
            }))
            t.ok(no_info ~= nil)
            t.eq(no_info.tabs[1].panes[1].foreground, nil)

            local empty_argv = save.collect(one_tab_window({
                id = 3,
                cwd = "/C:/work",
                foreground = { argv = {}, alt_screen = false },
            }))
            t.ok(empty_argv ~= nil)
            t.eq(empty_argv.tabs[1].panes[1].foreground, nil)
        end,
    },
    {
        name = "an unset tab title falls back to the active pane title, but an empty title stays empty",
        run = function(t)
            local fallback = save.collect(one_tab_window({
                id = 1,
                cwd = "/C:/work",
                title = "pwsh",
            }, nil))
            t.ok(fallback ~= nil)
            t.eq(fallback.tabs[1].title, "pwsh")

            local empty = save.collect(one_tab_window({
                id = 2,
                cwd = "/C:/work",
                title = "pwsh",
            }, ""))
            t.ok(empty ~= nil)
            t.eq(empty.tabs[1].title, "")

            local named = save.collect(one_tab_window({
                id = 3,
                cwd = "/C:/work",
                title = "pwsh",
            }, "editor"))
            t.ok(named ~= nil)
            t.eq(named.tabs[1].title, "editor")
        end,
    },
    {
        name = "active indices are one-based positions in the saved arrays",
        run = function(t)
            local first = fake_pane({ id = 1, cwd = "/C:/one" })
            local second = fake_pane({ id = 2, cwd = "/C:/two" })
            local third = fake_pane({ id = 3, cwd = "/C:/three" })
            local tab_one = fake_tab({
                title = "one",
                panes = { pane_info(first, 0, 0, 0, 200, 40, false) },
            })
            local tab_two = fake_tab({
                title = "two",
                panes = {
                    pane_info(second, 5, 0, 0, 50, 40, false),
                    pane_info(third, 9, 50, 0, 50, 40, true),
                },
            })
            local window = fake_window({
                { index = 7, is_active = false, tab = tab_one },
                { index = 8, is_active = true, tab = tab_two },
            })

            local snapshot, err = save.collect(window)
            t.ok(snapshot ~= nil, tostring(err))
            t.eq(snapshot.window.cols, 100, "the active tab, not another tab, sets the window cell width")
            t.eq(snapshot.window.active_tab, 2)
            t.eq(snapshot.window.active_pane, 2)
            t.eq(snapshot.tabs[2].panes[1].id, 2)
            t.eq(snapshot.tabs[2].panes[2].id, 3)
        end,
    },
    {
        name = "collected fingerprints are stable until a tracked field changes",
        run = function(t)
            local first = fake_pane({ id = 1, cwd = "/C:/one" })
            local second = fake_pane({ id = 2, cwd = "/C:/two" })
            local tab = fake_tab({
                title = "editor",
                panes = {
                    pane_info(first, 0, 0, 0, 60, 20, false),
                    pane_info(second, 1, 60, 0, 40, 20, true),
                },
            })
            local window = fake_window({
                { index = 0, is_active = true, tab = tab },
            })

            local base = save.collect(window)
            t.ok(base ~= nil)
            local baseline = state.fingerprint(base)
            t.eq(state.fingerprint(save.collect(window)), baseline, "the same window must fingerprint the same")

            tab.title = "renamed"
            t.ok(state.fingerprint(save.collect(window)) ~= baseline, "a title change must be tracked")
            tab.title = "editor"

            tab.panes[1].width = 61
            t.ok(state.fingerprint(save.collect(window)) ~= baseline, "a rectangle change must be tracked")
            tab.panes[1].width = 60

            first.cwd = "/C:/elsewhere"
            t.ok(state.fingerprint(save.collect(window)) ~= baseline, "a cwd change must be tracked")
            first.cwd = "/C:/one"

            tab.panes[2].width = 39
            t.ok(state.fingerprint(save.collect(window)) ~= baseline, "a window cell size change must be tracked")
        end,
    },
    {
        name = "the debounce writes after two stable seconds and not while idle",
        run = function(t)
            t.eq(save.DEBOUNCE_SECONDS, 2)

            local write, pending = save.decide("A", nil, "A", 100)
            t.eq(write, false, "an unchanged fingerprint must not write")
            t.eq(pending, nil)

            write, pending = save.decide(nil, nil, "A", 0)
            t.eq(write, false)
            t.eq(pending, { fingerprint = "A", since = 0 })

            local at_one = save.decide(nil, pending, "A", 1)
            t.eq(at_one, false, "one second is not enough")
            t.eq(pending, { fingerprint = "A", since = 0 })

            local at_two, written_pending = save.decide(nil, pending, "A", 2)
            t.eq(at_two, true, "two stable seconds must write")
            t.eq(written_pending, { fingerprint = "A", since = 0 })

            local idle, idle_pending = save.decide("A", nil, "A", 200)
            t.eq(idle, false, "a written fingerprint must stay idle")
            t.eq(idle_pending, nil)

            local changed, changed_pending = save.decide("A", nil, "B", 10)
            t.eq(changed, false)
            t.eq(changed_pending, { fingerprint = "B", since = 10 })

            local restarted, restarted_pending = save.decide("A", changed_pending, "C", 11)
            t.eq(restarted, false, "a new fingerprint restarts the settle window")
            t.eq(restarted_pending, { fingerprint = "C", since = 11 })

            local not_yet = save.decide("A", restarted_pending, "C", 12.9)
            t.eq(not_yet, false, "less than two seconds after the restart is not enough")

            local settled = save.decide("A", restarted_pending, "C", 13)
            t.eq(settled, true, "two seconds after the restart must write")

            local reverted, reverted_pending = save.decide("A", changed_pending, "A", 12)
            t.eq(reverted, false, "a fingerprint that returns to the written one must not write")
            t.eq(reverted_pending, nil)
        end,
    },
    {
        name = "start is idempotent and gui-startup always returns true",
        run = function(t)
            local real_call_after = wezterm.time.call_after
            local scheduled = 0
            wezterm.time.call_after = function(seconds, fn)
                scheduled = scheduled + 1
                t.eq(seconds, save.TICK_SECONDS)
                t.ok(type(fn) == "function", "the timer needs a callback")
                return true
            end

            local ok, err = pcall(function()
                t.eq(save.on_gui_startup(nil), true)
                t.eq(save.start(), true)
                t.eq(save.start(), true)
            end)
            wezterm.time.call_after = real_call_after

            t.ok(ok, err ~= nil and tostring(err) or "startup failed")
            t.eq(scheduled, 1, "the detector must register exactly one tick chain")
        end,
    },
    {
        name = "a refused write shows save failed, logs it, and a later save replaces the status",
        run = function(t)
            with_state_dir("save-failure", function()
                local window = status_window({ id = 41, cwd = "/C:/work" })
                local blocked = state.path(state.instance_id()) .. ".tmp"

                with_fake_timers(function(timers)
                    with_captured_logs(function(events)
                        with_blocked_state_write(blocked, function()
                            t.eq(save.save_now(window), false, "a refused write must return false")
                        end)

                        t.eq(window.status, " save failed ", "the failure must be visible")
                        t.eq(#timers, 1, "the failure must schedule one clear")
                        t.eq(
                            timers[1].seconds,
                            save.FAILURE_STATUS_SECONDS,
                            "the failure must last ten seconds, not a flicker"
                        )

                        t.eq(#events, 1, "the failure must log one event")
                        t.eq(events[1].level, "error")
                        t.eq(events[1].event, "save.failed")
                        t.eq(events[1].fields.trigger, "manual")
                        t.ok(
                            type(events[1].fields.reason) == "string" and events[1].fields.reason ~= "",
                            "the failure must carry a reason"
                        )

                        t.eq(save.save_now(window), true, "the next save must succeed")
                        t.ok(
                            window.status:match("^ saved %d%d:%d%d:%d%d $") ~= nil,
                            "the timestamp must replace the failure, got " .. tostring(window.status)
                        )
                        t.eq(#timers, 2, "the success must schedule its own clear")
                        t.eq(timers[2].seconds, save.STATUS_SECONDS, "the success status clears after three seconds")

                        timers[1].callback()
                        t.ok(
                            window.status:match("^ saved %d%d:%d%d:%d%d $") ~= nil,
                            "an older failure timer must not clear the successful status"
                        )

                        timers[2].callback()
                        t.eq(window.status, "", "the success timer must clear the status")

                        t.eq(#events, 2, "the success must log one event")
                        t.eq(events[2].level, "info")
                        t.eq(events[2].event, "save.wrote")
                        t.eq(events[2].fields.trigger, "manual")
                        t.eq(events[2].fields.tabs, 1)
                        t.eq(events[2].fields.panes, 1)
                    end)
                end)
            end)
        end,
    },
    {
        name = "collect reports a malformed window instead of raising",
        run = function(t)
            local snapshot, err = save.collect(nil)
            t.eq(snapshot, nil)
            t.ok(type(err) == "string" and err ~= "")

            local empty = fake_window({})
            local empty_snapshot, empty_err = save.collect(empty)
            t.eq(empty_snapshot, nil)
            t.ok(type(empty_err) == "string" and empty_err ~= "")
        end,
    },
}
