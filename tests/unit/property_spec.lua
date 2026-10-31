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

-- Start from one rectangle and split a randomly chosen splittable leaf, in a
-- random direction, at a random size. Because the split size becomes the size of
-- the second (right or bottom) side, the leaf keeps its position and shrinks,
-- which is exactly the contract of plan's tree.
local function generate(seed, count, width, height, origin_left, origin_top)
    local rand = lehmer(seed)
    local leaves = {
        { left = origin_left, top = origin_top, width = width, height = height },
    }
    while #leaves < count do
        local splittable = {}
        for index, leaf in ipairs(leaves) do
            if leaf.width >= 2 or leaf.height >= 2 then
                splittable[#splittable + 1] = index
            end
        end
        if #splittable == 0 then
            error(string.format("seed %d: could not reach %d panes on a %dx%d canvas", seed, count, width, height))
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

-- Pick a pane that has another pane directly to its right and grow it by one
-- cell. A guillotine tiling has no gaps, so such a neighbour starts exactly at
-- this pane's right edge and the mutation overlaps it by one cell while leaving
-- the bounding box unchanged: exactly the input plan must reject.
local function overlapping_mutation(rects, rand)
    local candidates = {}
    for index, rect in ipairs(rects) do
        for other_index, other in ipairs(rects) do
            if other_index ~= index then
                local vertical_overlap = other.top < rect.top + rect.height
                    and rect.top < other.top + other.height
                local touches = other.left == rect.left + rect.width
                if vertical_overlap and touches then
                    candidates[#candidates + 1] = index
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
    mutated[pick].width = mutated[pick].width + 1
    return mutated, pick
end

-- Shrink a pane by one cell. The bounding box is recomputed and the mutation is
-- only used when the other panes still define the same box, so the result is
-- guaranteed to be a hole inside a fixed box, never a smaller valid tiling.
local function hole_mutation(rects, rand)
    local before_left, before_top, before_right, before_bottom = bounds(rects)
    local candidates = {}
    for index, rect in ipairs(rects) do
        if rect.width > 1 then
            local mutated = deep_copy(rects)
            mutated[index].width = mutated[index].width - 1
            local left, top, right, bottom = bounds(mutated)
            if
                left == before_left
                and top == before_top
                and right == before_right
                and bottom == before_bottom
            then
                candidates[#candidates + 1] = mutated
            end
        end
    end
    if #candidates == 0 then
        return nil
    end
    return candidates[rand(#candidates)]
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
        -- A four-pane 2x2 tiling with the top-left pane one cell narrower: the
        -- other panes still span the same box, so the missing cells are a hole.
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
        t.eq(
            layout.plan({
                { left = 0, top = 0, width = 100, height = 24 },
                { left = 0, top = 25, width = 100, height = 25 },
            }),
            nil,
            "a one cell gap between rows must not produce a plan"
        )
    end,
}

specs[#specs + 1] = {
    name = "plan rejects a corrupted layout for every seed",
    run = function(t)
        for seed = 1, SEED_COUNT do
            local count = 2 + (seed % (PANE_MAX - 1))
            local generated = generate(seed * 3571 + count, count, 110 + (seed % 40), 30 + (seed % 20), 0, 0)
            local rand = lehmer(seed * 1229 + count)

            local overlap = overlapping_mutation(generated, rand)
            if overlap ~= nil then
                t.eq(
                    layout.plan(overlap),
                    nil,
                    string.format("seed %d: an overlapping rectangle must not produce a plan", seed)
                )
            end

            local hole = hole_mutation(generated, rand)
            if hole ~= nil then
                t.eq(
                    layout.plan(hole),
                    nil,
                    string.format("seed %d: a hole in the bounding box must not produce a plan", seed)
                )
            end

            if overlap == nil and hole == nil then
                t.fail(string.format("seed %d: could not build a corrupted layout to test", seed))
            end
        end
    end,
}

return specs
