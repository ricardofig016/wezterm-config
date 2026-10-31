-- Step 3 unit tests: the pure geometry planner plus replay logic that can run
-- without a live pane.
--
-- Replay's direct proof needs real panes (pane:split), so that belongs to the
-- integration suite. Here replay is driven by a fake pane that records the
-- split arguments, which pins the call shape, the cwd, the history key and the
-- returned expected rectangles. plan is covered exhaustively.
local layout = require("lib.layout")

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
            local first_width = rect.width - node.cells
            walk(node.first, {
                left = rect.left,
                top = rect.top,
                width = first_width,
                height = rect.height,
            })
            walk(node.second, {
                left = rect.left + first_width,
                top = rect.top,
                width = node.cells,
                height = rect.height,
            })
        elseif node.direction == "Bottom" then
            local first_height = rect.height - node.cells
            walk(node.first, {
                left = rect.left,
                top = rect.top,
                width = rect.width,
                height = first_height,
            })
            walk(node.second, {
                left = rect.left,
                top = rect.top + first_height,
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

local function make_layout(seed, count, width, height)
    local rand = lehmer(seed)
    local leaves = { { left = 0, top = 0, width = width, height = height } }
    while #leaves < count do
        local splittable = {}
        for index, leaf in ipairs(leaves) do
            if leaf.width >= 2 or leaf.height >= 2 then
                splittable[#splittable + 1] = index
            end
        end
        local pick = splittable[rand(#splittable)]
        local leaf = leaves[pick]
        table.remove(leaves, pick)

        local directions = {}
        if leaf.width >= 2 then
            directions[#directions + 1] = "Right"
        end
        if leaf.height >= 2 then
            directions[#directions + 1] = "Bottom"
        end
        local direction = directions[rand(#directions)]

        if direction == "Right" then
            local size = rand(leaf.width - 1)
            local second = {
                left = leaf.left + leaf.width - size,
                top = leaf.top,
                width = size,
                height = leaf.height,
            }
            leaf.width = leaf.width - size
            leaves[#leaves + 1] = leaf
            leaves[#leaves + 1] = second
        else
            local size = rand(leaf.height - 1)
            local second = {
                left = leaf.left,
                top = leaf.top + leaf.height - size,
                width = leaf.width,
                height = size,
            }
            leaf.height = leaf.height - size
            leaves[#leaves + 1] = leaf
            leaves[#leaves + 1] = second
        end
    end
    return leaves
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

local corner = { left = 0, top = 0, width = 100, height = 50 }
local right_top = { left = 100, top = 0, width = 100, height = 25 }
local right_bottom = { left = 100, top = 25, width = 100, height = 25 }

local three_pane_rects = { corner, right_top, right_bottom }
local three_pane_saved = {
    { id = 10, rect = corner, cwd = "C:\\a" },
    { id = 11, rect = right_top, cwd = "C:\\b" },
    { id = 12, rect = right_bottom, cwd = "C:\\c" },
}

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
        name = "plan emits the pinned tree shape with cells for the second side",
        run = function(t)
            t.eq(
                layout.plan({
                    { left = 0, top = 0, width = 120, height = 50 },
                    { left = 120, top = 0, width = 80, height = 50 },
                }),
                { direction = "Right", cells = 80, first = { leaf = 1 }, second = { leaf = 2 } }
            )
            t.eq(
                layout.plan({
                    { left = 0, top = 0, width = 100, height = 20 },
                    { left = 0, top = 20, width = 100, height = 30 },
                }),
                { direction = "Bottom", cells = 30, first = { leaf = 1 }, second = { leaf = 2 } }
            )
            t.eq(layout.plan({
                { left = 0, top = 0, width = 100, height = 50 },
                { left = 100, top = 0, width = 100, height = 25 },
                { left = 100, top = 25, width = 100, height = 25 },
            }), {
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
                { left = 0, top = 0, width = 120, height = 50 },
                { left = 120, top = 0, width = 80, height = 20 },
                { left = 120, top = 20, width = 80, height = 30 },
            }
            local before = deep_copy(input)
            local first = layout.plan(input)
            t.ok(first ~= nil, "plan returned nil")
            t.eq(input, before, "plan must not mutate its input")
            t.eq(layout.plan(input), first, "plan must be deterministic")
        end,
    },
    {
        name = "plan rejects empty, malformed, overlapping and non-guillotine inputs",
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
            -- Classic pinwheel: the area is exact but no single cut spans the
            -- full width or height, so no WezTerm split order can rebuild it.
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

            local created, expected = layout.replay(root, tree, three_pane_saved)
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
                { left = 0, top = 20, width = 100, height = 30 },
            })
            t.eq(vertical.direction, "Bottom", "a bottom split is spelled Bottom")
        end,
    },
}
