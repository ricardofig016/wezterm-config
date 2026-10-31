-- Step 3 and step 4 unit tests: the pure geometry planner, replay logic that
-- can run without a live pane, and restore's decision logic against a fake mux.
--
-- Replay's direct proof needs real panes (pane:split), so that belongs to the
-- integration suite. Here replay is driven by a fake pane that records the
-- split arguments, which pins the call shape, the cwd, the history key and the
-- returned expected rectangles. plan is covered exhaustively. restore is driven
-- by a fake mux/window/tab/pane so every fallback path can be observed without
-- a GUI.
local layout = require("lib.layout")
local state = require("lib.state")
local log = require("lib.log")
local wezterm = require("wezterm")

local function deep_copy(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for key, item in pairs(value) do
        copy[key] = deep_copy(item)
    end
    return copy
end

-- Rebuild each leaf's rectangle from the plan tree alone, using only the
-- documented meaning of direction and cells. This is the independent half of
-- the zero-tolerance round trip.
local function flatten(tree, root)
    local out = {}
    local function walk(node, rect)
        if node.leaf ~= nil then
            out[node.leaf] = {
                left = rect.left,
                top = rect.top,
                width = rect.width,
                height = rect.height,
            }
            return
        end
        if node.direction == "Right" then
            -- WezTerm reserves one divider cell between the siblings.
            local first_width = rect.width - 1 - node.cells
            walk(node.first, {
                left = rect.left,
                top = rect.top,
                width = first_width,
                height = rect.height,
            })
            walk(node.second, {
                left = rect.left + first_width + 1,
                top = rect.top,
                width = node.cells,
                height = rect.height,
            })
        elseif node.direction == "Bottom" then
            local first_height = rect.height - 1 - node.cells
            walk(node.first, {
                left = rect.left,
                top = rect.top,
                width = rect.width,
                height = first_height,
            })
            walk(node.second, {
                left = rect.left,
                top = rect.top + first_height + 1,
                width = rect.width,
                height = node.cells,
            })
        else
            error("unexpected split direction " .. tostring(node.direction))
        end
    end
    walk(tree, root)
    return out
end

local function leaf_indices(tree)
    local out = {}
    local function walk(node)
        if node.leaf ~= nil then
            out[#out + 1] = node.leaf
            return
        end
        walk(node.first)
        walk(node.second)
    end
    walk(tree)
    table.sort(out)
    return out
end

-- A small deterministic Lehmer generator, so the layout corpus is reproducible
-- without touching math.random and without needing a seed global.
local function lehmer(seed)
    local value = seed % 2147483647
    if value <= 0 then
        value = value + 2147483646
    end
    return function(max)
        value = (value * 48271) % 2147483647
        return (value % max) + 1
    end
end

-- Build a gutter-aware layout the way WezTerm does: splitting a region of width
-- W with second side b leaves first side W - 1 - b and one divider cell, and the
-- second region starts at first + 1. The returned tables are the leaf
-- rectangles exactly as panes_with_info() would report them.
local function make_layout(seed, count, width, height)
    local rand = lehmer(seed)
    local regions = { { left = 0, top = 0, width = width, height = height } }
    while #regions < count do
        local splittable = {}
        for index, region in ipairs(regions) do
            if region.width >= 3 or region.height >= 3 then
                splittable[#splittable + 1] = index
            end
        end
        local pick = splittable[rand(#splittable)]
        local region = regions[pick]
        table.remove(regions, pick)

        local directions = {}
        if region.width >= 3 then
            directions[#directions + 1] = "Right"
        end
        if region.height >= 3 then
            directions[#directions + 1] = "Bottom"
        end
        local direction = directions[rand(#directions)]

        if direction == "Right" then
            local second_width = rand(region.width - 2)
            local first = {
                left = region.left,
                top = region.top,
                width = region.width - 1 - second_width,
                height = region.height,
            }
            local second = {
                left = region.left + first.width + 1,
                top = region.top,
                width = second_width,
                height = region.height,
            }
            regions[#regions + 1] = first
            regions[#regions + 1] = second
        else
            local second_height = rand(region.height - 2)
            local first = {
                left = region.left,
                top = region.top,
                width = region.width,
                height = region.height - 1 - second_height,
            }
            local second = {
                left = region.left,
                top = region.top + first.height + 1,
                width = region.width,
                height = second_height,
            }
            regions[#regions + 1] = first
            regions[#regions + 1] = second
        end
    end
    return regions
end

local function shuffled(leaves, rand)
    local copy = {}
    for index, leaf in ipairs(leaves) do
        copy[index] = leaf
    end
    for index = #copy, 2, -1 do
        local other = rand(index)
        copy[index], copy[other] = copy[other], copy[index]
    end
    return copy
end

-- A fake pane records every split and returns a fresh fake child. Only the
-- parts of the Pane interface replay uses are provided.
local function make_fake_pane_factory()
    local calls = {}
    local fake_pane
    fake_pane = function()
        return {
            split = function(self, args)
                local child = fake_pane()
                calls[#calls + 1] = { source = self, args = args, child = child }
                return child
            end,
        }
    end
    return fake_pane, calls
end

-- Live geometry from tests\fixtures\five-pane.json: 190x46, three split
-- boundaries, one divider cell between every pair of siblings.
local corner = { left = 0, top = 0, width = 99, height = 50 }
local right_top = { left = 100, top = 0, width = 100, height = 24 }
local right_bottom = { left = 100, top = 25, width = 100, height = 25 }

local three_pane_rects = { corner, right_top, right_bottom }
local three_pane_saved = {
    { id = 10, rect = corner, cwd = "C:\\a" },
    { id = 11, rect = right_top, cwd = "C:\\b" },
    { id = 12, rect = right_bottom, cwd = "C:\\c" },
}

-- A fake mux, window, tab and pane set for restore. It records what restore
-- spawns and splits, and fakes the one asynchronous interaction restore needs.
local function new_fake_env(options)
    options = options or {}
    local pane_config = options.pane_options or {}

    local env = {
        spawn = nil,
        spawned_tabs = {},
        tabs = {},
        panes = {},
        windows = {},
    }

    local function make_pane(pane_options)
        pane_options = pane_options or pane_config
        local pane = {
            ready_at = pane_options.ready_at,
            info_calls = 0,
            texts = {},
            activations = 0,
            splits = {},
        }
        function pane:split(args)
            if pane_options.split_raises then
                error("split refused")
            end
            local child = make_pane(pane_options)
            self.splits[#self.splits + 1] = { args = args, child = child }
            return child
        end
        function pane:get_foreground_process_info()
            self.info_calls = self.info_calls + 1
            if self.ready_at ~= nil and self.info_calls >= self.ready_at then
                return { argv = { "ready" } }
            end
            return nil
        end
        function pane:send_text(text)
            self.texts[#self.texts + 1] = text
        end
        function pane:activate()
            self.activations = self.activations + 1
        end
        return pane
    end

    local function make_tab()
        local tab = { titles = {}, activations = 0 }
        function tab:set_title(title)
            self.title = title
            self.titles[#self.titles + 1] = title
        end
        function tab:activate()
            self.activations = self.activations + 1
        end
        return tab
    end

    local function make_window()
        local window = { maximized = 0, spawn_tab_calls = {}, statuses = {} }
        function window:spawn_tab(args)
            local tab = make_tab()
            local pane = make_pane()
            window.spawn_tab_calls[#window.spawn_tab_calls + 1] = args
            env.spawned_tabs[#env.spawned_tabs + 1] = { args = args, tab = tab, pane = pane }
            env.tabs[#env.tabs + 1] = tab
            env.panes[#env.panes + 1] = pane
            return tab, pane, window
        end
        function window:gui_window()
            if env.status_raises then
                error("no status area")
            end
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
            local tab = make_tab()
            local pane = make_pane()
            env.spawn = { args = args, tab = tab, pane = pane, window = window }
            env.windows[#env.windows + 1] = window
            env.tabs[#env.tabs + 1] = tab
            env.panes[#env.panes + 1] = pane
            return tab, pane, window
        end,
        all_windows = function()
            return env.windows
        end,
    }

    return env
end

local function with_stub(target, name, replacement, fn)
    local real = target[name]
    target[name] = replacement
    local ok, err = pcall(fn)
    target[name] = real
    if not ok then
        error(err, 0)
    end
end

-- Run fn(env, events) with a fake mux, immediate timers, a recording logger and
-- a neutered log.init. Everything is restored afterwards.
local function with_restore_env(options, fn)
    local env = new_fake_env(options)
    local real_mux = wezterm.mux
    local real_time = wezterm.time
    local real_log = {
        init = log.init,
        debug = log.debug,
        info = log.info,
        warn = log.warn,
        error = log.error,
    }
    local events = {}

    log.init = function()
        env.init_calls = (env.init_calls or 0) + 1
        return true
    end
    for _, level in ipairs({ "debug", "info", "warn", "error" }) do
        log[level] = function(event, fields)
            events[#events + 1] = { level = level, event = event, fields = fields }
            return true
        end
    end
    wezterm.mux = env.mux
    wezterm.time = {
        call_after = function(_, callback)
            callback()
        end,
        now = real_time.now,
    }

    local ok, err = pcall(fn, env, events)

    wezterm.mux = real_mux
    wezterm.time = real_time
    log.init = real_log.init
    log.debug = real_log.debug
    log.info = real_log.info
    log.warn = real_log.warn
    log.error = real_log.error

    if not ok then
        error(err, 0)
    end
end

local function with_settle_env(value, fn)
    local real_getenv = os.getenv
    os.getenv = function(name)
        if name == "WEZTERM_SESSION_SELFCHECK_SETTLE_MS" then
            return value
        end
        return real_getenv(name)
    end
    local ok, err = pcall(fn)
    os.getenv = real_getenv
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

-- A fresh, valid state for restore. Tests override only the pieces they care
-- about. Tabs and panes are the same shapes state.write serialises.
local function sample_restore_state(overrides)
    local now = os.time()
    local base = {
        version = state.SCHEMA_VERSION,
        saved_at = now,
        instance = { id = "1700000000-00aa01", started_at = now - 10 },
        window = { cols = 200, rows = 50, active_tab = 2, active_pane = 21 },
        tabs = {
            {
                title = "editor",
                panes = {
                    { id = 10, rect = { left = 0, top = 0, width = 99, height = 50 }, cwd = "C:\\a" },
                    { id = 11, rect = { left = 100, top = 0, width = 100, height = 24 }, cwd = "C:\\b" },
                    { id = 12, rect = { left = 100, top = 25, width = 100, height = 25 }, cwd = "C:\\c" },
                },
            },
            {
                title = "logs",
                panes = {
                    { id = 20, rect = { left = 0, top = 0, width = 99, height = 50 }, cwd = "C:\\d" },
                    { id = 21, rect = { left = 100, top = 0, width = 100, height = 50 }, cwd = "C:\\e" },
                },
            },
        },
    }
    for key, value in pairs(overrides or {}) do
        base[key] = value
    end
    return base
end

-- A hand-built report for selfcheck: each pane entry names its expected rect
-- and cwd plus optional live values, and the tab answers get_title and
-- panes_with_info the way a real MuxTab would.
local function fake_selfcheck_report(tabs)
    local report = { tabs = {} }
    for tab_index, tab_spec in ipairs(tabs) do
        local infos, panes = {}, {}
        for pane_index, pane_spec in ipairs(tab_spec.panes) do
            local url = pane_spec.live_url
            if url == nil and not pane_spec.unreported then
                url = { file_path = pane_spec.cwd }
            end
            local pane = {
                pane_id = function()
                    return pane_spec.id
                end,
                get_current_working_dir = function()
                    return url
                end,
            }
            panes[pane_index] = {
                id = pane_spec.id,
                rect = pane_spec.rect,
                cwd = pane_spec.cwd,
                pane = pane,
            }
            local rect = pane_spec.live_rect or pane_spec.rect
            infos[pane_index] = {
                pane = pane,
                left = rect.left,
                top = rect.top,
                width = rect.width,
                height = rect.height,
            }
        end
        report.tabs[tab_index] = {
            tab = {
                get_title = function()
                    return tab_spec.live_title or tab_spec.title
                end,
                panes_with_info = function()
                    return infos
                end,
            },
            title = tab_spec.title,
            panes = panes,
        }
    end
    return report
end

return {
    {
        name = "plan round-trips one to eight panes at zero tolerance",
        run = function(t)
            for count = 1, 8 do
                for seed = 1, 8 do
                    local width = 80 + ((seed * 37) % 120)
                    local height = 20 + ((seed * 11) % 40)
                    local generated = make_layout(seed * 101 + count, count, width, height)
                    local rand = lehmer(seed * 977 + count * 13)
                    local input = shuffled(generated, rand)
                    local before = deep_copy(input)
                    local context = string.format(
                        "%d panes, seed %d (%dx%d)",
                        count,
                        seed,
                        width,
                        height
                    )

                    local tree = layout.plan(input)
                    if tree == nil then
                        t.fail(context .. ": plan returned nil")
                    end
                    t.eq(input, before, context .. ": plan must not mutate its input")

                    local indices = leaf_indices(tree)
                    t.eq(#indices, count, context .. ": leaf count")
                    for index = 1, count do
                        t.eq(indices[index], index, context .. ": leaf indices must be 1..n")
                    end

                    local root = { left = 0, top = 0, width = width, height = height }
                    local actual = flatten(tree, root)
                    for index, rect in ipairs(input) do
                        local got = actual[index]
                        t.ok(got ~= nil, context .. ": leaf " .. index .. " missing from the tree")
                        t.eq(got.left, rect.left, context .. ": leaf " .. index .. " left")
                        t.eq(got.top, rect.top, context .. ": leaf " .. index .. " top")
                        t.eq(got.width, rect.width, context .. ": leaf " .. index .. " width")
                        t.eq(got.height, rect.height, context .. ": leaf " .. index .. " height")
                    end
                end
            end
        end,
    },
    {
        name = "random layouts survive plan and replay with their saved rectangles",
        run = function(t)
            for count = 1, 8 do
                for seed = 1, 8 do
                    local width = 80 + ((seed * 37) % 120)
                    local height = 20 + ((seed * 11) % 40)
                    local generated = make_layout(seed * 101 + count, count, width, height)
                    local rand = lehmer(seed * 977 + count * 13)
                    local input = shuffled(generated, rand)
                    local context = string.format("%d panes, seed %d", count, seed)

                    local tree = layout.plan(input)
                    if tree == nil then
                        t.fail(context .. ": plan returned nil")
                    end

                    local panes = {}
                    for index, rect in ipairs(input) do
                        panes[index] = {
                            id = index,
                            rect = rect,
                            cwd = "C:\\pane" .. index,
                        }
                    end

                    local make_pane = make_fake_pane_factory()
                    local created, expected = layout.replay(make_pane(), tree, panes)
                    if created == nil then
                        t.fail(context .. ": replay failed: " .. tostring(expected))
                    end
                    t.eq(#created, count - 1, context .. ": one pane is created per split")
                    for index, rect in ipairs(input) do
                        t.eq(expected[index], rect, context .. ": leaf " .. index .. " rectangle")
                    end
                end
            end
        end,
    },
    {
        name = "the captured five-pane fixture round-trips with its dividers",
        run = function(t)
            -- tests\fixtures\five-pane.json, captured from a live 190x46 window.
            local rects = {
                { left = 0, top = 0, width = 129, height = 20 },
                { left = 130, top = 0, width = 60, height = 20 },
                { left = 0, top = 21, width = 129, height = 25 },
                { left = 130, top = 21, width = 60, height = 14 },
                { left = 130, top = 36, width = 60, height = 10 },
            }
            local tree = layout.plan(rects)
            if tree == nil then
                t.fail("the live five-pane geometry must plan")
            end
            t.eq(tree, {
                direction = "Right",
                cells = 60,
                first = {
                    direction = "Bottom",
                    cells = 25,
                    first = { leaf = 1 },
                    second = { leaf = 3 },
                },
                second = {
                    direction = "Bottom",
                    cells = 25,
                    first = { leaf = 2 },
                    second = {
                        direction = "Bottom",
                        cells = 10,
                        first = { leaf = 4 },
                        second = { leaf = 5 },
                    },
                },
            })
            local actual = flatten(tree, { left = 0, top = 0, width = 190, height = 46 })
            for index, rect in ipairs(rects) do
                t.eq(actual[index], rect, "fixture leaf " .. index)
            end
        end,
    },
    {
        name = "plan emits the pinned tree shape with cells for the second side",
        run = function(t)
            t.eq(
                layout.plan({
                    { left = 0, top = 0, width = 119, height = 50 },
                    { left = 120, top = 0, width = 80, height = 50 },
                }),
                { direction = "Right", cells = 80, first = { leaf = 1 }, second = { leaf = 2 } }
            )
            t.eq(
                layout.plan({
                    { left = 0, top = 0, width = 100, height = 20 },
                    { left = 0, top = 21, width = 100, height = 30 },
                }),
                { direction = "Bottom", cells = 30, first = { leaf = 1 }, second = { leaf = 2 } }
            )
            t.eq(layout.plan(three_pane_rects), {
                direction = "Right",
                cells = 100,
                first = { leaf = 1 },
                second = {
                    direction = "Bottom",
                    cells = 25,
                    first = { leaf = 2 },
                    second = { leaf = 3 },
                },
            })
        end,
    },
    {
        name = "plan is pure and deterministic",
        run = function(t)
            local input = {
                { left = 0, top = 0, width = 119, height = 50 },
                { left = 120, top = 0, width = 80, height = 20 },
                { left = 120, top = 21, width = 80, height = 29 },
            }
            local before = deep_copy(input)
            local first = layout.plan(input)
            t.ok(first ~= nil, "plan returned nil")
            t.eq(input, before, "plan must not mutate its input")
            t.eq(layout.plan(input), first, "plan must be deterministic")
        end,
    },
    {
        name = "plan rejects empty, malformed, overlapping and non-gutter inputs",
        run = function(t)
            t.eq(layout.plan(nil), nil)
            t.eq(layout.plan({}), nil)
            t.eq(layout.plan({ { left = 0, top = 0, width = 0, height = 10 } }), nil)
            t.eq(layout.plan({ { left = 0.5, top = 0, width = 10, height = 10 } }), nil)
            t.eq(
                layout.plan({
                    { left = 0, top = 0, width = 60, height = 50 },
                    { left = 50, top = 0, width = 60, height = 50 },
                }),
                nil,
                "overlapping rectangles"
            )
            t.eq(
                layout.plan({
                    { left = 0, top = 0, width = 100, height = 50 },
                    { left = 100, top = 0, width = 100, height = 50 },
                }),
                nil,
                "an exact tiling has no divider and must not produce a plan"
            )
            t.eq(
                layout.plan({
                    { left = 0, top = 0, width = 99, height = 50 },
                    { left = 101, top = 0, width = 100, height = 50 },
                }),
                nil,
                "a two cell gap is not a divider"
            )
            t.eq(
                layout.plan({
                    { left = 0, top = 0, width = 100, height = 50 },
                    { left = 101, top = 0, width = 99, height = 25 },
                }),
                nil,
                "a one cell gap that does not span the split must be refused"
            )
            -- Classic pinwheel: no single cut spans the full width or height,
            -- so no WezTerm split order can rebuild it.
            t.eq(
                layout.plan({
                    { left = 0, top = 0, width = 2, height = 1 },
                    { left = 2, top = 0, width = 1, height = 2 },
                    { left = 1, top = 2, width = 2, height = 1 },
                    { left = 0, top = 1, width = 1, height = 2 },
                    { left = 1, top = 1, width = 1, height = 1 },
                }),
                nil,
                "the pinwheel has no full-length cut"
            )
        end,
    },
    {
        name = "replay splits in plan order with cwd and the history key",
        run = function(t)
            local make_pane, calls = make_fake_pane_factory()
            local root = make_pane()
            local tree = layout.plan(three_pane_rects)
            t.ok(tree ~= nil, "plan returned nil")

            local created, expected, by_leaf = layout.replay(root, tree, three_pane_saved)
            t.ok(created ~= nil, "replay failed: " .. tostring(expected))
            t.eq(#created, 2)
            t.eq(#calls, 2)

            t.ok(calls[1].source == root, "the first split must target the pane that was passed in")
            t.eq(calls[1].args.direction, "Right")
            t.eq(calls[1].args.size, 100)
            t.eq(calls[1].args.cwd, "C:\\b")
            t.eq(calls[1].args.set_environment_variables, {
                WEZTERM_SESSION_HISTORY_KEY = "11",
            })
            t.ok(created[1] == calls[1].child, "replay must return the panes it created")

            t.ok(calls[2].source == created[1], "the second split must target the new right pane")
            t.eq(calls[2].args.direction, "Bottom")
            t.eq(calls[2].args.size, 25)
            t.eq(calls[2].args.cwd, "C:\\c")
            t.eq(calls[2].args.set_environment_variables, {
                WEZTERM_SESSION_HISTORY_KEY = "12",
            })
            t.ok(created[2] == calls[2].child)

            t.eq(expected, {
                [1] = corner,
                [2] = right_top,
                [3] = right_bottom,
            })
            t.ok(by_leaf[1] == root, "the first leaf must be the pane that was passed in")
            t.ok(by_leaf[2] == created[1])
            t.ok(by_leaf[3] == created[2])
            t.eq(three_pane_saved[1].cwd, "C:\\a", "replay must not mutate the saved panes")
        end,
    },
    {
        name = "replay rejects a tree that does not match the saved panes",
        run = function(t)
            local make_pane = make_fake_pane_factory()
            local tree = layout.plan(three_pane_rects)

            local missing, missing_err = layout.replay(make_pane(), tree, { three_pane_saved[1] })
            t.eq(missing, nil)
            t.ok(
                type(missing_err) == "string" and missing_err:find("leaves", 1, true) ~= nil,
                "unexpected error: " .. tostring(missing_err)
            )

            local good_panes = { three_pane_saved[1], three_pane_saved[2], three_pane_saved[3] }
            for _, direction in ipairs({ "Up", "Down", "Left" }) do
                local bad = {
                    direction = direction,
                    cells = 10,
                    first = { leaf = 1 },
                    second = { leaf = 2 },
                }
                local created, err = layout.replay(make_pane(), bad, {
                    good_panes[1],
                    good_panes[2],
                })
                t.eq(created, nil, "direction " .. direction .. " must be rejected")
                t.ok(
                    type(err) == "string" and err:find("Right or Bottom", 1, true) ~= nil,
                    "unexpected error for " .. direction .. ": " .. tostring(err)
                )
            end

            local zero = {
                direction = "Right",
                cells = 0,
                first = { leaf = 1 },
                second = { leaf = 2 },
            }
            local created, err = layout.replay(make_pane(), zero, { good_panes[1], good_panes[2] })
            t.eq(created, nil, "a zero cell split must be rejected")
            t.ok(
                type(err) == "string" and err:find("invalid split size", 1, true) ~= nil,
                "unexpected error: " .. tostring(err)
            )
        end,
    },
    {
        name = "the Up/Down and Top/Bottom direction vocabularies are pinned as data",
        run = function(t)
            -- act.SplitPane key assignments use Up/Down; pane:split, and
            -- therefore replay, only accepts Top/Bottom (plus Left/Right).
            local key_action_to_split_call = {
                Up = "Top",
                Down = "Bottom",
                Left = "Left",
                Right = "Right",
            }
            t.eq(key_action_to_split_call.Up, "Top")
            t.eq(key_action_to_split_call.Down, "Bottom")
            t.eq(key_action_to_split_call.Left, "Left")
            t.eq(key_action_to_split_call.Right, "Right")

            local split_call_vocabulary = {
                Top = true,
                Bottom = true,
                Left = true,
                Right = true,
            }
            t.ok(split_call_vocabulary.Top and split_call_vocabulary.Bottom)
            t.ok(not split_call_vocabulary.Up and not split_call_vocabulary.Down)

            local vertical = layout.plan({
                { left = 0, top = 0, width = 100, height = 20 },
                { left = 0, top = 21, width = 100, height = 30 },
            })
            t.eq(vertical.direction, "Bottom", "a bottom split is spelled Bottom")
        end,
    },
    {
        name = "restore spawns saved cell dimensions and rebuilds tabs in order",
        run = function(t)
            with_restore_env({}, function(env, events)
                local restored = layout.restore({ args = { "pwsh.exe", "-NoLogo" } }, sample_restore_state())
                t.eq(restored, true)

                t.ok(env.spawn ~= nil, "spawn_window must be called")
                t.eq(env.spawn.args.width, 200, "saved cols must be the cell width")
                t.eq(env.spawn.args.height, 50, "saved rows must be the cell height")
                t.eq(env.spawn.args.cwd, "C:\\a", "the root pane's saved cwd")
                t.eq(env.spawn.args.args, { "pwsh.exe", "-NoLogo" }, "the startup command must survive")
                t.eq(env.spawn.args.set_environment_variables, {
                    WEZTERM_SESSION_HISTORY_KEY = "10",
                })
                t.eq(env.spawn.tab.titles, { "editor" })
                t.eq(env.spawn.tab.activations, 0, "the inactive tab must not be activated")

                t.eq(#env.spawned_tabs, 1, "the second tab must be spawned in the same window")
                t.eq(env.spawned_tabs[1].args.cwd, "C:\\d")
                t.eq(env.spawned_tabs[1].args.set_environment_variables, {
                    WEZTERM_SESSION_HISTORY_KEY = "20",
                })
                t.eq(env.spawned_tabs[1].tab.titles, { "logs" })
                t.eq(env.spawned_tabs[1].tab.activations, 1, "the saved active tab must be activated")

                local root = env.spawn.pane
                t.eq(#root.splits, 1)
                t.eq(root.splits[1].args.direction, "Right")
                t.eq(root.splits[1].args.size, 100)
                t.eq(root.splits[1].args.cwd, "C:\\b")
                t.eq(root.splits[1].args.set_environment_variables, {
                    WEZTERM_SESSION_HISTORY_KEY = "11",
                })
                local right = root.splits[1].child
                t.eq(#right.splits, 1)
                t.eq(right.splits[1].args.direction, "Bottom")
                t.eq(right.splits[1].args.size, 25)
                t.eq(right.splits[1].args.cwd, "C:\\c")
                t.eq(right.splits[1].args.set_environment_variables, {
                    WEZTERM_SESSION_HISTORY_KEY = "12",
                })

                local tab2_root = env.spawned_tabs[1].pane
                t.eq(#tab2_root.splits, 1)
                t.eq(tab2_root.splits[1].args.cwd, "C:\\e")
                t.eq(tab2_root.splits[1].args.set_environment_variables, {
                    WEZTERM_SESSION_HISTORY_KEY = "21",
                })
                t.eq(tab2_root.splits[1].child.activations, 1, "the saved active pane must be activated")
                t.eq(root.activations, 0, "non-active panes must not be activated")

                t.ok(find_event(events, "restore.start") ~= nil)
                t.ok(find_event(events, "restore.done") ~= nil)
            end)
        end,
    },
    {
        name = "restore without a state logs and opens one maximized window",
        run = function(t)
            with_restore_env({}, function(env, events)
                local restored = layout.restore({ args = { "pwsh.exe" } }, nil)
                t.eq(restored, false)
                t.ok(env.spawn ~= nil, "the fallback must spawn a window")
                t.eq(env.spawn.args.args, { "pwsh.exe" })
                t.eq(env.spawn.args.width, nil, "the fallback must not reuse saved cells")
                t.eq(env.spawn.args.height, nil)
                t.eq(env.spawn.window.maximized, 1)
                t.eq(env.spawn.window.statuses, { " restore failed ", "" })
                t.eq(#env.spawned_tabs, 0)
                t.ok(find_event(events, "restore.no_state") ~= nil)
            end)
        end,
    },
    {
        name = "restore rejects a stale state",
        run = function(t)
            local stale = sample_restore_state({ saved_at = os.time() - state.MAX_AGE_SECONDS - 10 })
            with_restore_env({}, function(env, events)
                t.eq(layout.restore(nil, stale), false)
                t.eq(env.spawn.args.width, nil)
                t.eq(env.spawn.window.maximized, 1)
                t.ok(find_event(events, "restore.stale") ~= nil)
            end)
        end,
    },
    {
        name = "restore rejects a mismatched schema version",
        run = function(t)
            local future = sample_restore_state({ version = 2 })
            with_restore_env({}, function(env, events)
                t.eq(layout.restore(nil, future), false)
                local event = find_event(events, "restore.version")
                t.ok(event ~= nil)
                t.eq(event.fields.found, "2")
                t.eq(event.fields.expected, state.SCHEMA_VERSION)
                t.eq(env.spawn.args.width, nil)
            end)
        end,
    },
    {
        name = "restore rejects a state with no tabs",
        run = function(t)
            with_restore_env({}, function(env, events)
                t.eq(layout.restore(nil, state.empty()), false)
                t.ok(find_event(events, "restore.empty") ~= nil)
                t.ok(env.spawn ~= nil)
                t.eq(env.spawn.args.width, nil)
            end)
        end,
    },
    {
        name = "restore falls back when the plan refuses the rectangles",
        run = function(t)
            local overlapped = sample_restore_state({
                window = { cols = 110, rows = 50, active_tab = 1, active_pane = 30 },
                tabs = {
                    {
                        title = "bad",
                        panes = {
                            { id = 30, rect = { left = 0, top = 0, width = 60, height = 50 }, cwd = "C:\\x" },
                            { id = 31, rect = { left = 50, top = 0, width = 60, height = 50 }, cwd = "C:\\y" },
                        },
                    },
                },
            })
            with_restore_env({}, function(env, events)
                t.eq(layout.restore(nil, overlapped), false)
                t.ok(find_event(events, "restore.plan_failed") ~= nil)
                t.ok(env.spawn ~= nil)
                t.eq(env.spawn.args.width, nil, "plan failure must fall back before spawning saved cells")
                t.eq(env.spawn.window.maximized, 1)
                t.eq(#env.spawned_tabs, 0)
            end)
        end,
    },
    {
        name = "restore logs and keeps a usable window when replay fails",
        run = function(t)
            local broken = sample_restore_state({
                window = { cols = 200, rows = 50, active_tab = 1, active_pane = 20 },
                tabs = {
                    {
                        title = "broken",
                        panes = {
                            { id = 20, rect = { left = 0, top = 0, width = 99, height = 50 }, cwd = "C:\\d" },
                            { id = 21, rect = { left = 100, top = 0, width = 100, height = 50 }, cwd = "C:\\e" },
                        },
                    },
                },
            })
            with_restore_env({ pane_options = { split_raises = true } }, function(env, events)
                t.eq(layout.restore(nil, broken), false)
                t.eq(#env.windows, 1, "the partially restored window must be kept, not duplicated")
                t.eq(env.spawn.args.width, 200, "the restored window was already spawned")
                t.eq(env.spawn.window.maximized, 1, "the kept window must be maximized")
                t.eq(#env.spawned_tabs, 0)
                t.ok(find_event(events, "restore.failed") ~= nil)
            end)
        end,
    },
    {
        name = "restore replays a full-screen program once the shell answers",
        run = function(t)
            local foreground = sample_restore_state({
                window = { cols = 200, rows = 50, active_tab = 1, active_pane = 10 },
                tabs = {
                    {
                        title = "apps",
                        panes = {
                            {
                                id = 10,
                                rect = { left = 0, top = 0, width = 99, height = 50 },
                                cwd = "C:\\a",
                                foreground = { argv = { "less", "app.log" }, alt_screen = true },
                            },
                            {
                                id = 11,
                                rect = { left = 100, top = 0, width = 100, height = 50 },
                                cwd = "C:\\b",
                                foreground = { argv = { "top" }, alt_screen = false },
                            },
                        },
                    },
                },
            })
            with_restore_env({ pane_options = { ready_at = 2 } }, function(env, events)
                t.eq(layout.restore(nil, foreground), true)
                local root = env.spawn.pane
                local child = root.splits[1].child
                t.eq(root.info_calls, 2, "the shell query must be polled before the first answer")
                t.eq(root.texts, { "less app.log\r" })
                t.eq(child.info_calls, 0, "a non-alt-screen foreground must not be replayed")
                t.eq(child.texts, {})
                t.ok(find_event(events, "restore.foreground") ~= nil)
            end)
        end,
    },
    {
        name = "restore gives up quietly when a foreground program never answers",
        run = function(t)
            local foreground = sample_restore_state({
                window = { cols = 200, rows = 50, active_tab = 1, active_pane = 10 },
                tabs = {
                    {
                        title = "apps",
                        panes = {
                            {
                                id = 10,
                                rect = { left = 0, top = 0, width = 200, height = 50 },
                                cwd = "C:\\a",
                                foreground = { argv = { "less" }, alt_screen = true },
                            },
                        },
                    },
                },
            })
            with_restore_env({}, function(env, events)
                t.eq(layout.restore(nil, foreground), true)
                local root = env.spawn.pane
                t.eq(root.info_calls, 20, "the foreground wait must be bounded")
                t.eq(root.texts, {}, "nothing must be typed after the timeout")
                t.ok(find_event(events, "restore.foreground_timeout") ~= nil)
                t.eq(find_event(events, "restore.foreground"), nil)
            end)
        end,
    },
    {
        name = "on_gui_startup initializes the log and restores the latest state",
        run = function(t)
            with_restore_env({}, function(env, events)
                with_stub(state, "read_latest", function()
                    return sample_restore_state()
                end, function()
                    t.eq(layout.on_gui_startup({ args = { "pwsh.exe" } }), true)
                end)
                t.eq(env.init_calls, 1, "the handler must initialize the log")
                t.ok(env.spawn ~= nil)
                t.eq(env.spawn.args.width, 200)
                t.ok(find_event(events, "restore.done") ~= nil)
            end)
        end,
    },
    {
        name = "on_gui_startup survives a state read failure",
        run = function(t)
            with_restore_env({}, function(env, events)
                with_stub(state, "read_latest", function()
                    error("disk gone")
                end, function()
                    t.eq(layout.on_gui_startup(nil), true)
                end)
                t.ok(find_event(events, "restore.read_failed") ~= nil)
                t.ok(find_event(events, "restore.no_state") ~= nil)
                t.ok(env.spawn ~= nil, "the fallback must still open a window")
                t.eq(env.spawn.window.maximized, 1)
            end)
        end,
    },
    {
        name = "on_gui_startup survives an unexpected restore failure",
        run = function(t)
            with_restore_env({}, function(env, events)
                with_stub(state, "read_latest", function()
                    return sample_restore_state()
                end, function()
                    with_stub(state, "is_stale", function()
                        error("boom")
                    end, function()
                        t.eq(layout.on_gui_startup(nil), true)
                    end)
                end)
                t.ok(find_event(events, "restore.failed") ~= nil)
                t.ok(env.spawn ~= nil, "the fallback must still open a window")
                t.eq(env.spawn.window.maximized, 1)
            end)
        end,
    },
    {
        name = "selfcheck accepts a one-cell drift and normalizes cwd URLs",
        run = function(t)
            local report = fake_selfcheck_report({
                {
                    title = "editor",
                    panes = {
                        {
                            id = 11,
                            rect = { left = 0, top = 0, width = 100, height = 50 },
                            live_rect = { left = 1, top = 0, width = 99, height = 50 },
                            cwd = "C:\\a",
                            live_url = { file_path = "/C:/a" },
                        },
                    },
                },
            })
            t.eq(layout.selfcheck(report), {})
        end,
    },
    {
        name = "selfcheck reports a rectangle drift beyond one cell",
        run = function(t)
            local report = fake_selfcheck_report({
                {
                    title = "editor",
                    panes = {
                        {
                            id = 11,
                            rect = { left = 0, top = 0, width = 100, height = 50 },
                            live_rect = { left = 2, top = 0, width = 98, height = 50 },
                            cwd = "C:\\a",
                        },
                    },
                },
            })
            t.eq(layout.selfcheck(report), {
                { kind = "rect", tab = 1, pane = 11 },
            })
        end,
    },
    {
        name = "selfcheck reports a cwd mismatch",
        run = function(t)
            local report = fake_selfcheck_report({
                {
                    title = "editor",
                    panes = {
                        {
                            id = 11,
                            rect = { left = 0, top = 0, width = 100, height = 50 },
                            cwd = "C:\\a",
                            live_url = { file_path = "/C:/elsewhere" },
                        },
                    },
                },
            })
            t.eq(layout.selfcheck(report), {
                { kind = "cwd", tab = 1, pane = 11 },
            })
        end,
    },
    {
        name = "selfcheck reports a title mismatch as a tab finding",
        run = function(t)
            local report = fake_selfcheck_report({
                {
                    title = "editor",
                    live_title = "renamed",
                    panes = {
                        {
                            id = 11,
                            rect = { left = 0, top = 0, width = 100, height = 50 },
                            cwd = "C:\\a",
                        },
                    },
                },
            })
            t.eq(layout.selfcheck(report), {
                { kind = "title", tab = 1 },
            })
        end,
    },
    {
        name = "a drifting restore logs and flashes a short status",
        run = function(t)
            with_restore_env({}, function(env, events)
                with_stub(layout, "selfcheck", function()
                    return {
                        { kind = "rect", tab = 1, pane = 10 },
                        { kind = "cwd", tab = 2, pane = 21 },
                    }
                end, function()
                    t.eq(layout.restore(nil, sample_restore_state()), true)
                end)
                t.eq(env.spawn.window.statuses, { " restore drift: 2 ", "" })
                local drift = find_event(events, "selfcheck.drift")
                t.ok(drift ~= nil, "the drift must be logged")
                t.eq(drift.level, "warn")
                t.eq(drift.fields.count, 2)
                t.eq(drift.fields.kinds, "rect,cwd")
                t.eq(drift.fields.tab, 1)
                t.eq(drift.fields.pane, 10)
                t.ok(find_event(events, "restore.done") ~= nil)
            end)
        end,
    },
    {
        name = "a clean restore stays quiet",
        run = function(t)
            with_restore_env({}, function(env, events)
                with_stub(layout, "selfcheck", function()
                    return {}
                end, function()
                    t.eq(layout.restore(nil, sample_restore_state()), true)
                end)
                t.eq(env.spawn.window.statuses, {})
                t.eq(find_event(events, "selfcheck.drift"), nil)
                t.eq(find_event(events, "selfcheck.failed"), nil)
            end)
        end,
    },
    {
        name = "a self-check error is logged and never falls back",
        run = function(t)
            with_restore_env({}, function(env, events)
                with_stub(layout, "selfcheck", function()
                    error("check exploded")
                end, function()
                    t.eq(layout.restore(nil, sample_restore_state()), true)
                end)
                t.eq(env.spawn.window.statuses, {})
                t.eq(#env.windows, 1, "a self-check error must not open or duplicate a window")
                local failed = find_event(events, "selfcheck.failed")
                t.ok(failed ~= nil)
                t.ok(failed.fields.error:find("check exploded", 1, true) ~= nil)
                t.eq(find_event(events, "selfcheck.drift"), nil)
            end)
        end,
    },
    {
        name = "a missing status area cannot break a restore",
        run = function(t)
            with_restore_env({}, function(env, events)
                env.status_raises = true
                with_stub(layout, "selfcheck", function()
                    return { { kind = "rect", tab = 1, pane = 10 } }
                end, function()
                    t.eq(layout.restore(nil, sample_restore_state()), true)
                end)
                t.eq(#env.windows, 1)
                t.eq(env.spawn.window.statuses, {})
                t.ok(find_event(events, "selfcheck.status_failed") ~= nil)
            end)
        end,
    },
    {
        name = "an odd clock cannot break a restore",
        run = function(t)
            with_restore_env({}, function(env, events)
                with_stub(layout, "selfcheck", function()
                    return { { kind = "rect", tab = 1, pane = 10 } }
                end, function()
                    wezterm.time.call_after = function()
                        error("no clock")
                    end
                    t.eq(layout.restore(nil, sample_restore_state()), true)
                end)
                t.eq(env.spawn.window.statuses, { " restore drift: 1 " })
                t.eq(#env.windows, 1)
            end)
        end,
    },
    {
        name = "selfcheck ignores case, slash direction and a trailing separator",
        run = function(t)
            local report = fake_selfcheck_report({
                {
                    title = "editor",
                    panes = {
                        {
                            id = 11,
                            rect = { left = 0, top = 0, width = 100, height = 50 },
                            cwd = "C:\\Work",
                            live_url = { file_path = "/c:/work/" },
                        },
                    },
                },
            })
            local findings, unknown = layout.selfcheck(report)
            t.eq(findings, {})
            t.eq(unknown, {})
        end,
    },
    {
        name = "a clean check settles immediately and stays silent",
        run = function(t)
            with_restore_env({}, function(env, events)
                local calls = 0
                with_stub(layout, "selfcheck", function()
                    calls = calls + 1
                    return {}
                end, function()
                    t.eq(layout.restore(nil, sample_restore_state()), true)
                end)
                t.eq(calls, 1, "a clean check must not poll")
                t.eq(env.spawn.window.statuses, {})
                t.eq(find_event(events, "selfcheck.drift"), nil)
            end)
        end,
    },
    {
        name = "a cwd that settles after one step stays silent",
        run = function(t)
            with_restore_env({}, function(env, events)
                local calls = 0
                with_stub(layout, "selfcheck", function()
                    calls = calls + 1
                    if calls == 1 then
                        return { { kind = "cwd", tab = 1, pane = 10 } }
                    end
                    return {}
                end, function()
                    t.eq(layout.restore(nil, sample_restore_state()), true)
                end)
                t.eq(calls, 2, "the cwd must be rechecked after one settle step")
                t.eq(env.spawn.window.statuses, {})
                t.eq(find_event(events, "selfcheck.drift"), nil)
            end)
        end,
    },
    {
        name = "a settled cwd leaves only the other findings in the report",
        run = function(t)
            with_restore_env({}, function(env, events)
                local calls = 0
                with_stub(layout, "selfcheck", function()
                    calls = calls + 1
                    if calls == 1 then
                        return {
                            { kind = "rect", tab = 1, pane = 10 },
                            { kind = "cwd", tab = 1, pane = 10 },
                        }
                    end
                    return { { kind = "rect", tab = 1, pane = 10 } }
                end, function()
                    t.eq(layout.restore(nil, sample_restore_state()), true)
                end)
                t.eq(calls, 2)
                t.eq(env.spawn.window.statuses, { " restore drift: 1 ", "" })
                local drift = find_event(events, "selfcheck.drift")
                t.ok(drift ~= nil)
                t.eq(drift.fields.count, 1)
                t.eq(drift.fields.kinds, "rect")
                t.eq(drift.fields.timed_out, nil)
            end)
        end,
    },
    {
        name = "a reported cwd mismatch keeps driving drift and status after the settle window",
        run = function(t)
            with_settle_env(nil, function()
                with_restore_env({}, function(env, events)
                    local calls = 0
                    with_stub(layout, "selfcheck", function()
                        calls = calls + 1
                        return { { kind = "cwd", tab = 1, pane = 10 } }
                    end, function()
                        t.eq(layout.restore(nil, sample_restore_state()), true)
                    end)
                    t.eq(calls, 101, "one immediate check plus one hundred settle steps")
                    t.eq(env.spawn.window.statuses, { " restore drift: 1 ", "" })
                    local drift = find_event(events, "selfcheck.drift")
                    t.ok(drift ~= nil)
                    t.eq(drift.fields.count, 1)
                    t.eq(drift.fields.kinds, "cwd")
                    t.eq(drift.fields.timed_out, true)
                    t.eq(#env.windows, 1, "a cwd timeout must never fall back")
                end)
            end)
        end,
    },
    {
        name = "restore accepts an active pane id of zero",
        run = function(t)
            local zero = sample_restore_state({
                window = { cols = 99, rows = 50, active_tab = 1, active_pane = 0 },
                tabs = {
                    {
                        title = "zero",
                        panes = {
                            {
                                id = 0,
                                rect = { left = 0, top = 0, width = 99, height = 50 },
                                cwd = "C:\\zero",
                            },
                        },
                    },
                },
            })
            with_restore_env({}, function(env)
                with_stub(layout, "selfcheck", function()
                    return {}
                end, function()
                    t.eq(layout.restore(nil, zero), true)
                end)
                t.eq(env.spawn.args.width, 99)
                t.eq(env.spawn.args.set_environment_variables.WEZTERM_SESSION_HISTORY_KEY, "0")
                t.eq(env.spawn.pane.activations, 1, "pane id 0 must be found and activated")
            end)
        end,
    },
    {
        name = "an unreported cwd is unknown, not a finding",
        run = function(t)
            local report = fake_selfcheck_report({
                {
                    title = "editor",
                    panes = {
                        {
                            id = 11,
                            rect = { left = 0, top = 0, width = 50, height = 50 },
                            cwd = "C:\\a",
                            unreported = true,
                        },
                        {
                            id = 12,
                            rect = { left = 51, top = 0, width = 49, height = 50 },
                            cwd = "C:\\b",
                            live_url = "",
                        },
                    },
                },
            })
            local findings, unknown = layout.selfcheck(report)
            t.eq(findings, {}, "an unreported cwd is not drift")
            t.eq(unknown, {
                { tab = 1, pane = 11 },
                { tab = 1, pane = 12 },
            })
        end,
    },
    {
        name = "an unreported cwd that arrives late stays silent",
        run = function(t)
            with_restore_env({}, function(env, events)
                local calls = 0
                with_stub(layout, "selfcheck", function()
                    calls = calls + 1
                    if calls <= 3 then
                        return {}, { { tab = 1, pane = 10 } }
                    end
                    return {}
                end, function()
                    t.eq(layout.restore(nil, sample_restore_state()), true)
                end)
                t.eq(calls, 4)
                t.eq(env.spawn.window.statuses, {})
                t.eq(find_event(events, "selfcheck.drift"), nil)
                t.eq(find_event(events, "selfcheck.cwd_unknown"), nil)
            end)
        end,
    },
    {
        name = "a cwd that never reports logs cwd_unknown without status or drift",
        run = function(t)
            with_settle_env(nil, function()
                with_restore_env({}, function(env, events)
                    local calls = 0
                    with_stub(layout, "selfcheck", function()
                        calls = calls + 1
                        return {}, { { tab = 1, pane = 10 } }
                    end, function()
                        t.eq(layout.restore(nil, sample_restore_state()), true)
                    end)
                    t.eq(calls, 101)
                    t.eq(env.spawn.window.statuses, {})
                    t.eq(find_event(events, "selfcheck.drift"), nil)
                    local unknown_event = find_event(events, "selfcheck.cwd_unknown")
                    t.ok(unknown_event ~= nil)
                    t.eq(unknown_event.level, "info")
                    t.eq(unknown_event.fields.count, 1)
                    t.eq(unknown_event.fields.tab, 1)
                    t.eq(unknown_event.fields.pane, 10)
                    t.eq(#env.windows, 1)
                end)
            end)
        end,
    },
    {
        name = "the self-check settle window defaults to ten seconds",
        run = function(t)
            with_settle_env(nil, function()
                with_restore_env({}, function(env, events)
                    local calls = 0
                    with_stub(layout, "selfcheck", function()
                        calls = calls + 1
                        return { { kind = "cwd", tab = 1, pane = 10 } }
                    end, function()
                        t.eq(layout.restore(nil, sample_restore_state()), true)
                    end)
                    t.eq(calls, 101, "100 steps of 100ms plus the immediate check")
                    local drift = find_event(events, "selfcheck.drift")
                    t.ok(drift ~= nil)
                    t.eq(drift.fields.timed_out, true)
                end)
            end)
        end,
    },
    {
        name = "a valid self-check settle override is honoured",
        run = function(t)
            with_settle_env("500", function()
                with_restore_env({}, function(env, events)
                    local calls = 0
                    with_stub(layout, "selfcheck", function()
                        calls = calls + 1
                        return { { kind = "cwd", tab = 1, pane = 10 } }
                    end, function()
                        t.eq(layout.restore(nil, sample_restore_state()), true)
                    end)
                    t.eq(calls, 6, "5 steps of 100ms plus the immediate check")
                    t.ok(find_event(events, "selfcheck.drift") ~= nil)
                end)
            end)
        end,
    },
    {
        name = "invalid or zero self-check settle values fall back to the default",
        run = function(t)
            for _, value in ipairs({ "", "abc", "0", "-5", "1.5" }) do
                with_settle_env(value, function()
                    with_restore_env({}, function()
                        local calls = 0
                        with_stub(layout, "selfcheck", function()
                            calls = calls + 1
                            return { { kind = "cwd", tab = 1, pane = 10 } }
                        end, function()
                            t.eq(layout.restore(nil, sample_restore_state()), true)
                        end)
                        t.eq(calls, 101, "value " .. value .. " must use the default")
                    end)
                end)
            end
        end,
    },
    {
        name = "early exit still works at a small settle window",
        run = function(t)
            with_settle_env("300", function()
                with_restore_env({}, function(env, events)
                    local calls = 0
                    with_stub(layout, "selfcheck", function()
                        calls = calls + 1
                        if calls <= 2 then
                            return { { kind = "cwd", tab = 1, pane = 10 } }
                        end
                        return {}
                    end, function()
                        t.eq(layout.restore(nil, sample_restore_state()), true)
                    end)
                    t.eq(calls, 3, "must stop as soon as the cwd matches, not wait out the window")
                    t.eq(env.spawn.window.statuses, {})
                    t.eq(find_event(events, "selfcheck.drift"), nil)
                end)
            end)
        end,
    },
}
