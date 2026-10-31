-- Geometry planner and replay.
--
-- plan(rects) turns an ordered list of tab-relative cell rectangles into a
-- binary split tree:
--
--   leaf  = { leaf = <1-based index of the rect it came from> }
--   split = { direction = "Right" | "Bottom",
--             cells = <size of the second (right/bottom) side in cells>,
--             first = <left/top subtree>,
--             second = <right/bottom subtree> }
--
-- plan is pure: it never mutates its input, it returns nil for a list that is
-- not an exact guillotine tiling, and it reproduces every rectangle at zero
-- cells of drift. Leaves keep the input order rather than geometric order, so
-- replays and expected rectangles stay keyed by the saved pane index.
--
-- replay(pane, tree, panes) walks the tree, calling pane:split for each split
-- with a numeric size in cells. pane:split's direction vocabulary is Left,
-- Right, Top and Bottom; the act.SplitPane key-action vocabulary (Up/Down) is
-- a different spelling and belongs to lib\keys.lua. Each split passes cwd and
-- WEZTERM_SESSION_HISTORY_KEY for the pane it creates, which is the first leaf
-- of that split's second subtree. replay returns the created panes (in creation
-- order) and the expected rectangles keyed by leaf; the pane passed in is the
-- first leaf of the whole tree and its cwd is restore's job.
local M = {}

local function is_integer(value)
    return type(value) == "number" and value == math.floor(value)
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

local function bounds(items)
    local left, top = math.huge, math.huge
    local right, bottom = -math.huge, -math.huge
    local area = 0
    for _, item in ipairs(items) do
        local rect = item.rect
        left = math.min(left, rect.left)
        top = math.min(top, rect.top)
        right = math.max(right, rect.left + rect.width)
        bottom = math.max(bottom, rect.top + rect.height)
        area = area + rect.width * rect.height
    end
    return left, top, right, bottom, area
end

local function matches_box(items, left, top, right, bottom)
    local first_left, first_top, first_right, first_bottom = bounds(items)
    return first_left == left
        and first_top == top
        and first_right == right
        and first_bottom == bottom
end

-- Split items into the two sides of a full-length cut. A rectangle that
-- straddles the cut means this boundary is not a valid split.
local function partition(items, axis, boundary)
    local first, second = {}, {}
    for _, item in ipairs(items) do
        local rect = item.rect
        if axis == "x" then
            local rect_right = rect.left + rect.width
            if rect_right <= boundary then
                first[#first + 1] = item
            elseif rect.left >= boundary then
                second[#second + 1] = item
            else
                return nil
            end
        else
            local rect_bottom = rect.top + rect.height
            if rect_bottom <= boundary then
                first[#first + 1] = item
            elseif rect.top >= boundary then
                second[#second + 1] = item
            else
                return nil
            end
        end
    end
    if #first == 0 or #second == 0 then
        return nil
    end
    return first, second
end

-- Prefer the leftmost vertical cut, then the topmost horizontal cut. Both
-- sides must span the full extent of the other axis, which is what makes the
-- cut reconstruct the boxes exactly.
local function find_split(items, left, top, right, bottom)
    local xs, seen_x = {}, {}
    for _, item in ipairs(items) do
        local edge = item.rect.left + item.rect.width
        if edge > left and edge < right and not seen_x[edge] then
            seen_x[edge] = true
            xs[#xs + 1] = edge
        end
    end
    table.sort(xs)
    for _, x in ipairs(xs) do
        local first, second = partition(items, "x", x)
        if
            first
            and matches_box(first, left, top, x, bottom)
            and matches_box(second, x, top, right, bottom)
        then
            return {
                direction = "Right",
                cells = right - x,
                first = first,
                second = second,
            }
        end
    end

    local ys, seen_y = {}, {}
    for _, item in ipairs(items) do
        local edge = item.rect.top + item.rect.height
        if edge > top and edge < bottom and not seen_y[edge] then
            seen_y[edge] = true
            ys[#ys + 1] = edge
        end
    end
    table.sort(ys)
    for _, y in ipairs(ys) do
        local first, second = partition(items, "y", y)
        if
            first
            and matches_box(first, left, top, right, y)
            and matches_box(second, left, y, right, bottom)
        then
            return {
                direction = "Bottom",
                cells = bottom - y,
                first = first,
                second = second,
            }
        end
    end

    return nil
end

local function plan_items(items)
    if #items == 0 then
        return nil
    end
    if #items == 1 then
        return { leaf = items[1].index }
    end

    local left, top, right, bottom, area = bounds(items)
    -- A guillotine tiling of the bounding box has exactly the box's area; this
    -- rejects overlaps and holes before the cut search has to reason about them.
    if area ~= (right - left) * (bottom - top) then
        return nil
    end

    local split = find_split(items, left, top, right, bottom)
    if split == nil then
        return nil
    end

    local first = plan_items(split.first)
    if first == nil then
        return nil
    end
    local second = plan_items(split.second)
    if second == nil then
        return nil
    end

    return {
        direction = split.direction,
        cells = split.cells,
        first = first,
        second = second,
    }
end

function M.plan(rects)
    if type(rects) ~= "table" then
        return nil
    end
    local items = {}
    for index, rect in ipairs(rects) do
        if not valid_rect(rect) then
            return nil
        end
        items[#items + 1] = { index = index, rect = rect }
    end
    if #items == 0 then
        return nil
    end
    return plan_items(items)
end

-- The pane a split creates keeps the first leaf of that split's second
-- subtree; every deeper split in that subtree starts from it.
local function first_leaf(node)
    while type(node) == "table" do
        if node.leaf ~= nil then
            return node.leaf
        end
        node = node.first
    end
    return nil
end

local function count_leaves(node)
    if type(node) ~= "table" then
        error("invalid plan node")
    end
    if node.leaf ~= nil then
        return 1
    end
    return count_leaves(node.first) + count_leaves(node.second)
end

function M.replay(pane, tree, panes)
    if pane == nil or type(tree) ~= "table" or type(panes) ~= "table" then
        return nil, "replay needs a pane, a plan tree and the saved panes"
    end

    local created = {}
    local expected = {}

    local seen = {}

    local ok, err = pcall(function()
        local leaf_count = count_leaves(tree)
        if leaf_count ~= #panes then
            error(string.format("plan has %d leaves but %d panes were saved", leaf_count, #panes))
        end

        local function walk(node, target)
            if node.leaf ~= nil then
                local index = node.leaf
                if not is_integer(index) or index < 1 or index > #panes then
                    error("invalid leaf index " .. tostring(index))
                end
                if seen[index] then
                    error("duplicate leaf index " .. tostring(index))
                end
                seen[index] = true

                local saved = panes[index]
                if type(saved) ~= "table" then
                    error("no saved pane for leaf " .. tostring(index))
                end
                if not is_integer(saved.id) then
                    error("saved pane " .. tostring(index) .. " has no numeric id")
                end
                if type(saved.cwd) ~= "string" then
                    error("saved pane " .. tostring(index) .. " has no cwd")
                end
                if not valid_rect(saved.rect) then
                    error("saved pane " .. tostring(index) .. " has no valid rect")
                end
                expected[index] = saved.rect
                return
            end

            local direction = node.direction
            local cells = node.cells
            if direction ~= "Right" and direction ~= "Bottom" then
                error("plan tree split direction must be Right or Bottom, got " .. tostring(direction))
            end
            if not is_integer(cells) or cells < 1 then
                error("invalid split size " .. tostring(cells))
            end

            local created_index = first_leaf(node.second)
            local created_pane = created_index and panes[created_index]
            if type(created_pane) ~= "table" then
                error("no saved pane for leaf " .. tostring(created_index))
            end
            if not is_integer(created_pane.id) then
                error("saved pane " .. tostring(created_index) .. " has no numeric id")
            end
            if type(created_pane.cwd) ~= "string" then
                error("saved pane " .. tostring(created_index) .. " has no cwd")
            end

            local child = target:split({
                direction = direction,
                size = cells,
                cwd = created_pane.cwd,
                set_environment_variables = {
                    WEZTERM_SESSION_HISTORY_KEY = tostring(created_pane.id),
                },
            })
            if child == nil then
                error("pane:split returned no pane")
            end
            created[#created + 1] = child

            walk(node.first, target)
            walk(node.second, child)
        end

        walk(tree, pane)
    end)

    if not ok then
        return nil, tostring(err)
    end
    return created, expected
end

function M.restore(window, state)
    return nil
end

-- Registered on gui-startup by the entry. Must return true: a false return
-- silences every gui-startup handler registered after this one.
function M.on_gui_startup(cmd)
    return true
end

function M.selfcheck(report)
    return nil
end

return M