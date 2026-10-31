-- Step 2 unit tests: state schema version 1, its reader/writer, and the logger.
--
-- Every disk test redirects WEZTERM_SESSION_STATE_DIR to a unique folder under
-- %TEMP% (by replacing os.getenv for the duration of the test) and removes it
-- afterwards, so no test can touch the real state directory.
local state = require("lib.state")
local log = require("lib.log")

local real_getenv = os.getenv

local function file_exists(path)
    local handle = io.open(path, "r")
    if handle then
        handle:close()
        return true
    end
    return false
end

local function read_all(path)
    local handle = io.open(path, "r")
    if not handle then
        return nil
    end
    local data = handle:read("*a")
    handle:close()
    return data
end

local function read_lines(path)
    local data = read_all(path)
    if not data then
        return {}
    end
    local lines = {}
    for line in data:gmatch("[^\r\n]+") do
        lines[#lines + 1] = line
    end
    return lines
end

local function write_raw(path, text)
    local handle = io.open(path, "w")
    assert(handle, "could not open " .. path)
    handle:write(text)
    handle:close()
end

local temp_counter = 0

local function next_dir(name)
    temp_counter = temp_counter + 1
    local base = (os.getenv("TEMP") or "."):gsub("\\", "/")
    local dir = string.format("%s/wezterm-state-spec-%d-%d-%s", base, os.time(), temp_counter, name)
    dir = dir:gsub("/", "\\")
    os.execute('mkdir "' .. dir .. '"')
    return dir
end

-- Run fn(dir) with the state directory redirected to a fresh temp folder, then
-- remove the folder and restore os.getenv even when the assertion fails.
local function with_dir(name, redirect, fn)
    local dir = next_dir(name)
    if redirect then
        os.getenv = function(var)
            if var == "WEZTERM_SESSION_STATE_DIR" then
                return dir
            end
            return real_getenv(var)
        end
    end
    local ok, err = pcall(fn, dir)
    os.getenv = real_getenv
    os.execute('rmdir /s /q "' .. dir .. '"')
    if not ok then
        error(err, 0)
    end
end

local function with_state_dir(name, fn)
    with_dir(name, true, fn)
end

local function with_plain_dir(name, fn)
    with_dir(name, false, fn)
end

-- A complete state: two tabs, three panes, one pane with a foreground program,
-- one without, and two cwds per tab so geometry and directories both matter.
local function sample_state(id, saved_at)
    return {
        version = state.SCHEMA_VERSION,
        saved_at = saved_at,
        instance = { id = id, started_at = saved_at - 100 },
        window = { cols = 200, rows = 50, active_tab = 2, active_pane = 7 },
        tabs = {
            {
                title = "editor",
                panes = {
                    {
                        id = 3,
                        rect = { left = 0, top = 0, width = 100, height = 50 },
                        cwd = "C:\\work\\alpha",
                    },
                    {
                        id = 7,
                        rect = { left = 100, top = 0, width = 100, height = 50 },
                        cwd = "C:\\work\\beta",
                        foreground = { argv = { "pwsh", "-NoLogo" }, alt_screen = false },
                    },
                },
            },
            {
                title = "logs",
                panes = {
                    {
                        id = 9,
                        rect = { left = 0, top = 0, width = 200, height = 50 },
                        cwd = "C:\\work\\gamma",
                        foreground = { argv = { "less", "app.log" }, alt_screen = true },
                    },
                },
            },
        },
    }
end

return {
    {
        name = "state directory honours WEZTERM_SESSION_STATE_DIR and its pinned fallback",
        run = function(t)
            local pinned = "C:\\Users\\rfigueiredo\\AppData\\Roaming\\wezterm-session-layer"
            with_state_dir("env", function(dir)
                t.eq(state.state_dir(), dir, "the environment variable must win")
                t.eq(state.sessions_dir(), dir .. "\\sessions")
                t.eq(state.path("7-0000aa"), dir .. "\\sessions\\7-0000aa.json")
            end)

            local original = real_getenv("WEZTERM_SESSION_STATE_DIR")
            local expected = (original ~= nil and original ~= "") and original or pinned
            t.eq(state.state_dir(), expected, "unset variable falls back to the pinned directory")

            os.getenv = function(var)
                if var == "WEZTERM_SESSION_STATE_DIR" then
                    return ""
                end
                return real_getenv(var)
            end
            local ok, value = pcall(state.state_dir)
            os.getenv = real_getenv
            t.ok(ok, "state_dir must not raise")
            t.eq(value, pinned, "an empty variable counts as unset")
        end,
    },
    {
        name = "the instance id is memoized so repeated saves cannot mint several files",
        run = function(t)
            local first = state.instance_id()
            local second = state.instance_id()
            t.eq(second, first, "instance_id must be stable for the life of the process")
            t.ok(first:match("^%d+%-%x+$") ~= nil, "unexpected instance id: " .. tostring(first))
        end,
    },
    {
        name = "a full state round-trips through write and read",
        run = function(t)
            with_state_dir("roundtrip", function()
                local original = sample_state("1700000000-00ab12", 1700000000)
                t.ok(state.write(original), "write must succeed")
                t.ok(file_exists(state.path(original.instance.id)), "the session file must exist")
                t.ok(
                    not file_exists(state.path(original.instance.id) .. ".tmp"),
                    "the temporary file must be gone after a successful write"
                )
                local loaded = state.read(original.instance.id)
                t.ok(loaded ~= nil, "read must return the state")
                t.eq(loaded, original, "the loaded state must equal the written state")
                t.ok(state.validate(loaded), "a loaded state must validate")
            end)
        end,
    },
    {
        name = "the empty state is valid, writable and readable",
        run = function(t)
            with_state_dir("empty", function()
                local empty = state.empty()
                t.eq(empty.version, state.SCHEMA_VERSION)
                t.eq(#empty.tabs, 0, "an empty state has no tabs")
                t.ok(state.validate(empty), "the empty state must validate")
                t.ok(state.write(empty), "the empty state must be writable")
                t.eq(state.read(empty.instance.id), empty)
            end)
        end,
    },
    {
        name = "a second write replaces the existing file",
        run = function(t)
            with_state_dir("replace", function()
                local id = "1700000001-00cd34"
                t.ok(state.write(sample_state(id, 1700000001)), "seed write")
                local second = sample_state(id, 1700000002)
                second.tabs[1].title = "renamed"
                t.ok(state.write(second), "a write over an existing file must use the remove-then-rename fallback")
                local loaded = state.read(id)
                t.eq(loaded.saved_at, 1700000002)
                t.eq(loaded.tabs[1].title, "renamed")
                t.ok(not file_exists(state.path(id) .. ".tmp"), "no temporary file is left behind")
            end)
        end,
    },
    {
        name = "two instances own two files and restore reads the newest",
        run = function(t)
            with_state_dir("two-instances", function()
                local older = sample_state("1700000500-0000aa", 500)
                local newer = sample_state("1700000501-0000bb", 501)
                t.ok(state.write(older))
                t.ok(state.write(newer))
                t.ok(state.read(older.instance.id) ~= nil, "the first instance file must survive")
                t.ok(state.read(newer.instance.id) ~= nil, "the second instance file must survive")
                local latest = state.read_latest()
                t.ok(latest ~= nil)
                t.eq(latest.instance.id, newer.instance.id)
            end)
        end,
    },
    {
        name = "read and read_latest reject a mismatched schema version",
        run = function(t)
            with_state_dir("version", function()
                local good_id = "1700000010-000001"
                t.ok(state.write(sample_state(good_id, 1700000010)), "seed a valid state")

                write_raw(state.path("1800000000-000002"), '{"version":2,"saved_at":1800000000}')
                t.eq(state.read("1800000000-000002"), nil, "read must reject version 2")
                t.eq(state.validate({ version = 2 }), false, "validate must reject version 2")
                t.eq(state.read_latest().instance.id, good_id, "read_latest must skip a newer invalid version")

                write_raw(state.path("1900000000-000003"), '{"version":1,"saved_at":1900000')
                t.eq(state.read("1900000000-000003"), nil, "read must reject truncated json")
                t.eq(state.read_latest().instance.id, good_id, "read_latest must skip a truncated file")
            end)
        end,
    },
    {
        name = "a truncated temporary file leaves the previous state intact",
        run = function(t)
            with_state_dir("truncated-temp", function()
                local id = "1700000020-000004"
                local previous = sample_state(id, 1700000020)
                t.ok(state.write(previous), "seed the previous state")

                local next_state = sample_state(id, 1700000030)
                next_state.tabs[1].title = "should not survive"
                local tmp_path = state.path(id) .. ".tmp"

                -- Simulate a crash between writing and validating the temp file:
                -- let the writer write and close it, then truncate it before the
                -- writer reads it back.
                local real_open = io.open
                io.open = function(path, mode, ...)
                    if path == tmp_path and type(mode) == "string" and mode:sub(1, 1) == "w" then
                        local handle = real_open(path, mode, ...)
                        local closed = false
                        return {
                            write = function(_, data)
                                return handle:write(data)
                            end,
                            flush = function()
                                return handle:flush()
                            end,
                            close = function()
                                if closed then
                                    return
                                end
                                closed = true
                                handle:close()
                                local truncate = real_open(path, "w")
                                if truncate then
                                    truncate:close()
                                end
                            end,
                        }
                    end
                    return real_open(path, mode, ...)
                end

                local ok, wrote = pcall(state.write, next_state)
                io.open = real_open

                t.ok(ok, "write must not raise")
                t.eq(wrote, false, "write must refuse a temp file that no longer matches what it wrote")
                local loaded = state.read(id)
                t.ok(loaded ~= nil, "the previous state must still be readable")
                t.eq(loaded.saved_at, previous.saved_at, "the previous state must not be replaced")
                t.eq(loaded.tabs[1].title, previous.tabs[1].title)
                t.ok(not file_exists(tmp_path), "the bad temp file must be removed")
            end)
        end,
    },
    {
        name = "read_latest picks the largest saved_at and breaks ties by instance id",
        run = function(t)
            with_state_dir("latest", function()
                t.eq(state.read_latest(), nil, "no sessions folder means no state")
                t.ok(state.write(sample_state("1700000100-0000aa", 100)))
                t.ok(state.write(sample_state("1700000300-0000cc", 300)))
                t.ok(state.write(sample_state("1700000200-0000bb", 200)))
                t.eq(state.read_latest().instance.id, "1700000300-0000cc")
                t.ok(state.write(sample_state("1700000300-0000dd", 300)))
                t.eq(state.read_latest().instance.id, "1700000300-0000dd", "ties are deterministic")
            end)
        end,
    },
    {
        name = "prune removes stale states and leaves fresh and unreadable files alone",
        run = function(t)
            with_state_dir("prune", function()
                local now = 1700001000
                local stale = sample_state("1600000000-0000aa", now - state.MAX_AGE_SECONDS - 10)
                local fresh = sample_state("1700001000-0000bb", now - 60)
                local corrupt_id = "1700000900-0000cc"
                t.ok(state.write(stale))
                t.ok(state.write(fresh))
                write_raw(state.path(corrupt_id), "{")
                t.eq(state.prune(now), 1, "exactly the stale state must be removed")
                t.eq(state.read(stale.instance.id), nil, "the stale file must be gone")
                t.ok(state.read(fresh.instance.id) ~= nil, "the fresh file must stay")
                t.ok(file_exists(state.path(corrupt_id)), "an unreadable file is left for a human, not guessed at")
            end)
        end,
    },
    {
        name = "is_stale compares against the seven day cap",
        run = function(t)
            local now = 1700000000
            t.eq(state.is_stale({ saved_at = now }, now), false)
            t.eq(state.is_stale({ saved_at = now - state.MAX_AGE_SECONDS }, now), false)
            t.eq(state.is_stale({ saved_at = now - state.MAX_AGE_SECONDS - 1 }, now), true)
            t.eq(state.is_stale(nil, now), true)
        end,
    },
    {
        name = "fingerprint tracks layout and titles but not saved_at",
        run = function(t)
            local a = sample_state("1700000000-00aa01", 1700000000)
            local b = sample_state("1700000000-00aa01", 1700009999)
            t.eq(state.fingerprint(a), state.fingerprint(b), "saved_at must not affect the fingerprint")

            local c = sample_state("1700000000-00aa01", 1700000000)
            c.tabs[1].panes[2].rect.width = 99
            t.ok(state.fingerprint(a) ~= state.fingerprint(c), "a rectangle change must change the fingerprint")

            local d = sample_state("1700000000-00aa01", 1700000000)
            d.tabs[2].title = "other"
            t.ok(state.fingerprint(a) ~= state.fingerprint(d), "a title change must change the fingerprint")

            local e = sample_state("1700000000-00aa01", 1700000000)
            e.window.cols = 201
            t.ok(state.fingerprint(a) ~= state.fingerprint(e), "a window size change must change the fingerprint")

            local f = sample_state("1700000000-00aa01", 1700000000)
            f.tabs[1].panes[1].cwd = "C:\\elsewhere"
            t.ok(state.fingerprint(a) ~= state.fingerprint(f), "a cwd change must change the fingerprint")
        end,
    },
    {
        name = "the logger stays inert until init is called",
        run = function(t)
            t.eq(log.info("save.tick", {}), false, "a logger without init must not write")
        end,
    },
    {
        name = "the logger writes one sorted, quoted line per event",
        run = function(t)
            with_plain_dir("log", function(dir)
                local path = dir .. "\\session.log"
                t.ok(log.init(path), "init must accept an explicit path")
                t.ok(log.info("restore.start", { note = "two words", eq = "a=b", tab = 2 }))
                t.ok(log.debug("save.tick", {}))
                local lines = read_lines(path)
                t.eq(#lines, 2, "one event means one line")
                t.ok(
                    lines[1]:match("^ts=%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ level=info event=restore%.start ") ~= nil,
                    "unexpected line: " .. lines[1]
                )
                t.ok(lines[1]:find('eq="a=b"', 1, true) ~= nil, "an equals sign must force quoting")
                t.ok(lines[1]:find('note="two words"', 1, true) ~= nil, "a space must force quoting")
                t.ok(lines[1]:find("tab=2", 1, true) ~= nil)
                t.ok(lines[2]:find("level=debug", 1, true) ~= nil)

                t.eq(log.info("other.event", {}), false, "events outside the four namespaces are dropped")
                t.eq(log.info("restore", {}), false, "an event without a dotted name is dropped")
                t.eq(#read_lines(path), 2, "a dropped event writes nothing")
            end)
        end,
    },
    {
        name = "the logger rotates at the size cap and keeps one backup",
        run = function(t)
            with_plain_dir("log-rotate", function(dir)
                local path = dir .. "\\session.log"
                local filler = io.open(path, "w")
                filler:write(string.rep("x", 300000))
                filler:close()
                local old_backup = io.open(path .. ".1", "w")
                old_backup:write("old backup")
                old_backup:close()

                t.ok(log.init(path))
                t.ok(log.info("history.record", { pane = 7 }))
                t.ok(file_exists(path .. ".1"), "the old log must become the backup")
                t.eq(#read_all(path .. ".1"), 300000, "the backup must be replaced, not appended to")
                t.ok(read_all(path):find("event=history.record", 1, true) ~= nil, "the new event must be in the fresh log")
                t.ok(not file_exists(path .. ".2"), "only one backup is kept")
            end)
        end,
    },
}
