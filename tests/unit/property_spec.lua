-- Step 9a: property tests for the guillotine planner.
--
-- One seeded test per seed builds random guillotine layouts of one to eight
-- panes: the split order, the split direction, the split size and the order of
-- the rectangles in the input are all random. plan must accept every layout,
-- and flattening the returned tree with nothing but the documented meaning of
-- direction and cells must reproduce every input rectangle exactly, zero cells
-- of tolerance. The seed is part of every failure message, so a failure
-- reproduces by rerunning the same seed.
--
-- The companion tests mutate those layouts into something that is not a tiling
-- (an overlap or a hole) and require plan to return nil. A planner that returns
-- a silently wrong plan for such input fails here; that is the proof the plan's
-- completion criterion asks for.
local layout = require("lib.layout")

-- Lehmer generator: deterministic across runs and independent of math.random,
-- which the unit harness must not depend on.
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

local function shuffled(items, rand)
    local copy = {}
    for index, item in ipairs(items) do
        copy[index] = item
    end
    for index = #copy, 2, -1 do
        local other = rand(index)
        copy[index], copy[other] = copy[other], copy[index]
    end
    return copy
end

-- Start from one region and split a randomly chosen splittable region. A live
-- WezTerm split reserves one divider cell: with second side b, the first side is
-- W - 1 - b and the second region starts at first + 1. The leaves this produces
-- are the rectangles panes_with_info() reports, gutters included.
local function generate(seed, count, width, height, origin_left, origin_top)
    local rand = lehmer(seed)
    local regions = {
        { left = origin_left, top = origin_top, width = width, height = height },
    }
    while #regions < count do
        local splittable = {}
        for index, region in ipairs(regions) do
            if region.width >= 3 or region.height >= 3 then
                splittable[#splittable + 1] = index
            end
        end
        if #splittable == 0 then
            error(string.format("seed %d: could not reach %d panes on a %dx%d canvas", seed, count, width, height))
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

local function bounds(rects)
    local left, top = math.huge, math.huge
    local right, bottom = -math.huge, -math.huge
    for _, rect in ipairs(rects) do
        left = math.min(left, rect.left)
        top = math.min(top, rect.top)
        right = math.max(right, rect.left + rect.width)
        bottom = math.max(bottom, rect.top + rect.height)
    end
    return left, top, right, bottom
end

-- Rebuild each leaf's rectangle from the plan tree alone, using only the
-- documented meaning of direction and cells. Independent of lib.layout, so a
-- planner that is wrong in the same way twice cannot hide here.
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

-- Pick a pane with a neighbour one divider cell to its right (or below) and
-- grow it by two cells, so it overlaps that neighbour by one cell while leaving
-- the bounding box unchanged: exactly the input plan must reject.
local function overlapping_mutation(rects, rand)
    local candidates = {}
    for index, rect in ipairs(rects) do
        for other_index, other in ipairs(rects) do
            if other_index ~= index then
                local vertical_overlap = other.top < rect.top + rect.height
                    and rect.top < other.top + other.height
                local horizontal_overlap = other.left < rect.left + rect.width
                    and rect.left < other.left + other.width
                if other.left == rect.left + rect.width + 1 and vertical_overlap then
                    candidates[#candidates + 1] = { index = index, axis = "width" }
                    break
                end
                if other.top == rect.top + rect.height + 1 and horizontal_overlap then
                    candidates[#candidates + 1] = { index = index, axis = "height" }
                    break
                end
            end
        end
    end
    if #candidates == 0 then
        return nil
    end
    local pick = candidates[rand(#candidates)]
    local mutated = deep_copy(rects)
    mutated[pick.index][pick.axis] = mutated[pick.index][pick.axis] + 2
    return mutated, pick.index
end

local SEED_COUNT = 30
local PANE_MAX = 8

local specs = {}

for seed = 1, SEED_COUNT do
    specs[#specs + 1] = {
        name = string.format("seed %d: random layouts of one to eight panes round-trip at zero tolerance", seed),
        run = function(t)
            for count = 1, PANE_MAX do
                local width = 60 + ((seed * 37 + count * 11) % 101)
                local height = 24 + ((seed * 13 + count * 7) % 37)
                local origin_left = (seed * 5 + count * 3) % 11
                local origin_top = (seed * 7 + count * 2) % 9
                local generated = generate(
                    seed * 1009 + count * 97,
                    count,
                    width,
                    height,
                    origin_left,
                    origin_top
                )

                local context = string.format(
                    "seed %d, %d panes (%dx%d at %d,%d)",
                    seed,
                    count,
                    width,
                    height,
                    origin_left,
                    origin_top
                )

                -- The input order is random too: leaves must map back to the
                -- position of their rectangle in the input, not to geometry.
                local order = lehmer(seed * 7919 + count * 31)
                local input = shuffled(generated, order)
                local before = deep_copy(input)

                local tree = layout.plan(input)
                if tree == nil then
                    t.fail(context .. ": plan returned nil for a valid guillotine tiling")
                end
                t.eq(input, before, context .. ": plan must not mutate its input")

                local indices = leaf_indices(tree)
                t.eq(#indices, count, context .. ": leaf count")
                for index = 1, count do
                    t.eq(indices[index], index, context .. ": leaf indices must be 1..n")
                end

                local root_left, root_top, root_right, root_bottom = bounds(input)
                local actual = flatten(tree, {
                    left = root_left,
                    top = root_top,
                    width = root_right - root_left,
                    height = root_bottom - root_top,
                })
                for index, rect in ipairs(input) do
                    local got = actual[index]
                    t.ok(got ~= nil, context .. ": leaf " .. index .. " missing from the tree")
                    t.eq(got.left, rect.left, context .. ": leaf " .. index .. " left")
                    t.eq(got.top, rect.top, context .. ": leaf " .. index .. " top")
                    t.eq(got.width, rect.width, context .. ": leaf " .. index .. " width")
                    t.eq(got.height, rect.height, context .. ": leaf " .. index .. " height")
                end
            end
        end,
    }
end

specs[#specs + 1] = {
    name = "plan rejects a layout whose rectangles overlap",
    run = function(t)
        t.eq(
            layout.plan({
                { left = 0, top = 0, width = 100, height = 50 },
                { left = 90, top = 0, width = 100, height = 50 },
            }),
            nil,
            "a ten cell overlap must not produce a plan"
        )
        t.eq(
            layout.plan({
                { left = 0, top = 0, width = 100, height = 50 },
                { left = 50, top = 0, width = 100, height = 50 },
            }),
            nil,
            "a fifty cell overlap must not produce a plan"
        )
    end,
}

specs[#specs + 1] = {
    name = "plan rejects a layout with a hole inside its bounding box",
    run = function(t)
        -- A 2x2 layout with the top-left pane one cell narrower: the other panes
        -- still span the same box, so the missing cells are a hole, not a
        -- one-cell divider spanning the split.
        t.eq(
            layout.plan({
                { left = 0, top = 0, width = 59, height = 25 },
                { left = 60, top = 0, width = 60, height = 25 },
                { left = 0, top = 25, width = 60, height = 25 },
                { left = 60, top = 25, width = 60, height = 25 },
            }),
            nil,
            "a one cell hole must not produce a plan"
        )
        -- The bottom-right region is missing, so the top row does not define a
        -- full-width sibling of the bottom-left pane.
        t.eq(
            layout.plan({
                { left = 0, top = 0, width = 59, height = 25 },
                { left = 60, top = 0, width = 60, height = 25 },
                { left = 0, top = 25, width = 60, height = 25 },
            }),
            nil,
            "a missing bottom-right region must not produce a plan"
        )
    end,
}

specs[#specs + 1] = {
    name = "plan rejects an overlap for every seed",
    run = function(t)
        for seed = 1, SEED_COUNT do
            local count = 2 + (seed % (PANE_MAX - 1))
            local generated = generate(seed * 3571 + count, count, 110 + (seed % 40), 30 + (seed % 20), 0, 0)
            local rand = lehmer(seed * 1229 + count)

            local overlap = overlapping_mutation(generated, rand)
            if overlap == nil then
                t.fail(string.format("seed %d: could not build an overlapping layout to test", seed))
            end
            t.eq(
                layout.plan(overlap),
                nil,
                string.format("seed %d: an overlapping rectangle must not produce a plan", seed)
            )
        end
    end,
}

return specs
