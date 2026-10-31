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
-- Live WezTerm panes never tile their bounding box: every split reserves a
-- one-cell divider between siblings. For a Right split of a parent W cells wide
-- whose second side is b, the first side is a = W - 1 - b, the divider is the
-- cell after it, and the second pane starts at parent.left + a + 1; Bottom
-- splits use the same arithmetic on rows, and nested splits apply inside a
-- child's rectangle. plan accepts exactly that geometry, rectangles as
-- panes_with_info() reports them with the gutters included, and returns nil for
-- an exact tiling, an overlap, or any gap that is not a one-cell divider. The
-- tree still carries `cells` = the second side's size, which is exactly the
-- numeric size pane:split needs. plan is pure and reproduces every rectangle at
-- zero cells of drift. Leaves keep the input order rather than geometric order,
-- so replays and expected rectangles stay keyed by the saved pane index.
--
-- replay(pane, tree, panes) walks the tree, calling pane:split for each split
-- with a numeric size in cells. pane:split's direction vocabulary is Left,
-- Right, Top and Bottom; the act.SplitPane key-action vocabulary (Up/Down) is
-- a different spelling and belongs to lib\keys.lua. Each split passes cwd and
-- WEZTERM_SESSION_HISTORY_KEY for the pane it creates, which is the first leaf
-- of that split's second subtree. replay returns the created panes (in creation
-- order), the expected rectangles keyed by leaf, and the pane object that ended
-- up in each leaf. The pane passed in is the first leaf of the whole tree and
-- its cwd is restore's job.
--
-- restore(cmd, latest) spawns the saved window and rebuilds its tabs from a
-- state that on_gui_startup already read. It validates the state, plans every
-- tab before touching the mux, then spawns with saved cell dimensions and
-- replays each tab. Every rejection or rebuild failure logs a restore. event
-- and falls back to a maximized window, so a bad state never leaves the user
-- without a terminal.
local wezterm = require("wezterm")

local state = require("lib.state")
local log = require("lib.log")

local M = {}

-- Foreground programs are typed once the pane's shell answers the foreground
-- process query. Poll a bounded number of times, then give up quietly.
local FOREGROUND_POLL_ATTEMPTS = 20
local FOREGROUND_POLL_DELAY = 0.1

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
    for _, item in ipairs(items) do
        local rect = item.rect
        left = math.min(left, rect.left)
        top = math.min(top, rect.top)
        right = math.max(right, rect.left + rect.width)
        bottom = math.max(bottom, rect.top + rect.height)
    end
    return left, top, right, bottom
end

local function matches_box(items, left, top, right, bottom)
    local first_left, first_top, first_right, first_bottom = bounds(items)
    return first_left == left
        and first_top == top
        and first_right == right
        and first_bottom == bottom
end

-- Split items into the two sides of a full-length cut whose one-cell divider
-- starts at boundary. The second side therefore starts at boundary + 1. A
-- rectangle that straddles the cut or sits in the divider means this boundary is
-- not a valid split.
local function partition(items, axis, boundary)
    local first, second = {}, {}
    for _, item in ipairs(items) do
        local rect = item.rect
        if axis == "x" then
            local rect_right = rect.left + rect.width
            if rect_right <= boundary then
                first[#first + 1] = item
            elseif rect.left >= boundary + 1 then
                second[#second + 1] = item
            else
                return nil
            end
        else
            local rect_bottom = rect.top + rect.height
            if rect_bottom <= boundary then
                first[#first + 1] = item
            elseif rect.top >= boundary + 1 then
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

-- Prefer the leftmost vertical cut, then the topmost horizontal cut. The
-- divider is one cell; the two sides must span the full extent of the other
-- axis, and the second side starts one cell past the first side's right (or
-- bottom) edge.
local function find_split(items, left, top, right, bottom)
    local xs, seen_x = {}, {}
    for _, item in ipairs(items) do
        local edge = item.rect.left + item.rect.width
        if edge > left and edge + 1 < right and not seen_x[edge] then
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
            and matches_box(second, x + 1, top, right, bottom)
        then
            return {
                direction = "Right",
                cells = right - (x + 1),
                first = first,
                second = second,
                first_region = { left = left, top = top, right = x, bottom = bottom },
                second_region = { left = x + 1, top = top, right = right, bottom = bottom },
            }
        end
    end

    local ys, seen_y = {}, {}
    for _, item in ipairs(items) do
        local edge = item.rect.top + item.rect.height
        if edge > top and edge + 1 < bottom and not seen_y[edge] then
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
            and matches_box(second, left, y + 1, right, bottom)
        then
            return {
                direction = "Bottom",
                cells = bottom - (y + 1),
                first = first,
                second = second,
                first_region = { left = left, top = top, right = right, bottom = y },
                second_region = { left = left, top = y + 1, right = right, bottom = bottom },
            }
        end
    end

    return nil
end

local function plan_items(items, region)
    if #items == 0 then
        return nil
    end
    if #items == 1 then
        return { leaf = items[1].index }
    end

    local split = find_split(items, region.left, region.top, region.right, region.bottom)
    if split == nil then
        return nil
    end

    local first = plan_items(split.first, split.first_region)
    if first == nil then
        return nil
    end
    local second = plan_items(split.second, split.second_region)
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

    local left, top, right, bottom = bounds(items)
    return plan_items(items, { left = left, top = top, right = right, bottom = bottom })
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
    local by_leaf = {}
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
                by_leaf[index] = target
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
    return created, expected, by_leaf
end

local function spawn_args(cmd)
    local args = {}
    if type(cmd) == "table" then
        for key, value in pairs(cmd) do
            args[key] = value
        end
    end
    return args
end

local function with_history_env(args, saved_pane)
    local variables = {}
    if type(args.set_environment_variables) == "table" then
        for key, value in pairs(args.set_environment_variables) do
            variables[key] = value
        end
    end
    variables.WEZTERM_SESSION_HISTORY_KEY = tostring(saved_pane.id)
    args.set_environment_variables = variables
    return args
end

local function maximize(window)
    if window == nil then
        return false
    end
    return pcall(function()
        window:gui_window():maximize()
    end)
end

local function existing_window()
    local ok, windows = pcall(wezterm.mux.all_windows)
    if not ok or windows == nil then
        return nil
    end
    local last
    for _, window in ipairs(windows) do
        last = window
    end
    return last
end

local STATUS_CLEAR_SECONDS = 4
local SELFCHECK_KINDS_SHOWN = 3
-- Production waits about ten seconds in short steps: a cold first pwsh prompt
-- can take longer than the old two-second window before it reports its
-- directory. Tests shrink the window with WEZTERM_SESSION_SELFCHECK_SETTLE_MS;
-- the value is read once per restore, clamped, and anything malformed falls
-- back to the default.
local DEFAULT_SELFCHECK_SETTLE_MS = 10000
local MIN_SELFCHECK_SETTLE_MS = 100
local MAX_SELFCHECK_SETTLE_MS = 60000
local SELFCHECK_STEP_MS = 100
local SELFCHECK_SETTLE_SECONDS = 0.1

local function selfcheck_settle_steps()
    local ok, raw = pcall(os.getenv, "WEZTERM_SESSION_SELFCHECK_SETTLE_MS")
    local milliseconds = ok and tonumber(raw) or nil
    if
        type(milliseconds) ~= "number"
        or milliseconds ~= math.floor(milliseconds)
        or milliseconds <= 0
    then
        milliseconds = DEFAULT_SELFCHECK_SETTLE_MS
    end
    if milliseconds < MIN_SELFCHECK_SETTLE_MS then
        milliseconds = MIN_SELFCHECK_SETTLE_MS
    elseif milliseconds > MAX_SELFCHECK_SETTLE_MS then
        milliseconds = MAX_SELFCHECK_SETTLE_MS
    end
    local steps = math.floor(milliseconds / SELFCHECK_STEP_MS)
    if steps < 1 then
        steps = 1
    end
    return steps
end

-- Status and timer calls are best effort: a missing status area, a closed
-- window or an odd clock must never turn a self-check or a fallback into a
-- crash, and a self-check problem must never cause another fallback.
local function set_status(window, text)
    if window == nil then
        return false
    end
    return pcall(function()
        window:gui_window():set_right_status(text)
    end)
end

local function flash_status(window, text)
    if not set_status(window, text) then
        return false
    end
    pcall(function()
        wezterm.time.call_after(STATUS_CLEAR_SECONDS, function()
            set_status(window, "")
        end)
    end)
    return true
end

local function summarize_findings(findings)
    local kinds, seen = {}, {}
    for _, finding in ipairs(findings) do
        if not seen[finding.kind] and #kinds < SELFCHECK_KINDS_SHOWN then
            seen[finding.kind] = true
            kinds[#kinds + 1] = finding.kind
        end
    end
    return table.concat(kinds, ",")
end

local function report_findings(window, findings, timed_out)
    local count = #findings
    if count == 0 then
        return
    end
    local first = findings[1]
    local fields = {
        count = count,
        kinds = summarize_findings(findings),
        tab = first.tab,
    }
    if first.pane ~= nil then
        fields.pane = first.pane
    end
    if timed_out then
        fields.timed_out = true
    end
    log.warn("selfcheck.drift", fields)
    if not flash_status(window, " restore drift: " .. tostring(count) .. " ") then
        log.warn("selfcheck.status_failed")
    end
end

-- Titles, rectangles and missing panes are stable immediately. Cwd is not: a
-- fresh pane reports the cwd handed to pane:split only once its shell (or the
-- process query) catches up. An unreported cwd is unknown, not drift, so wait
-- in short steps while any pane is unreported or reports a value that does not
-- match yet, then report only what is still wrong. A timeout reports genuine
-- cwd drift with a timed_out note and logs still-unreported panes as
-- selfcheck.cwd_unknown without touching the status. Nothing here can escalate
-- into a fallback.
local function cwd_finding(findings)
    for _, finding in ipairs(findings) do
        if finding.kind == "cwd" then
            return true
        end
    end
    return false
end

local function log_unknown(unknown)
    if #unknown == 0 then
        return
    end
    local first = unknown[1]
    log.info("selfcheck.cwd_unknown", {
        count = #unknown,
        tab = first.tab,
        pane = first.pane,
    })
end

local function check_selfcheck(window, report, attempt, settle_steps)
    local checked, findings, unknown = pcall(M.selfcheck, report)
    if not checked then
        log.warn("selfcheck.failed", { error = tostring(findings) })
        return
    end
    if type(findings) ~= "table" then
        findings = {}
    end
    if type(unknown) ~= "table" then
        unknown = {}
    end

    local drifted = cwd_finding(findings)
    if #unknown == 0 and not drifted then
        report_findings(window, findings, false)
        return
    end

    if attempt >= settle_steps then
        report_findings(window, findings, drifted)
        log_unknown(unknown)
        return
    end

    local scheduled = pcall(wezterm.time.call_after, SELFCHECK_SETTLE_SECONDS, function()
        check_selfcheck(window, report, attempt + 1, settle_steps)
    end)
    if not scheduled then
        report_findings(window, findings, drifted)
        log_unknown(unknown)
    end
end

-- Fallback: keep exactly one usable window. A partially restored window is
-- maximized rather than replaced, so a failure never leaves the user with no
-- terminal or with two windows.
local function fallback(cmd)
    local window = existing_window()
    if window ~= nil then
        maximize(window)
        flash_status(window, " restore failed ")
        return false
    end

    local ok, _, _, spawned = pcall(wezterm.mux.spawn_window, spawn_args(cmd))
    if not ok or spawned == nil then
        log.error("restore.fallback_failed", { error = tostring(spawned) })
        return false
    end
    maximize(spawned)
    flash_status(spawned, " restore failed ")
    return false
end

local function join_argv(argv)
    local ok, joined = pcall(wezterm.shell_join_args, argv)
    if ok and type(joined) == "string" and joined ~= "" then
        return joined
    end
    return table.concat(argv, " ")
end

-- Wait, bounded, for the pane's shell to answer the foreground process query,
-- then type the saved argv. The pane's shell does not exist during gui-startup,
-- so this has to be a timer, not an immediate send.
local function schedule_foreground(pane, argv, pane_id, tab_index)
    local attempts = 0
    local function poll()
        attempts = attempts + 1
        local info_ok, info = pcall(pane.get_foreground_process_info, pane)
        if info_ok and info ~= nil then
            local command = join_argv(argv)
            local sent = pcall(pane.send_text, pane, command .. "\r")
            if sent then
                log.info("restore.foreground", {
                    tab = tab_index,
                    pane = pane_id,
                    command = command,
                })
            else
                log.warn("restore.foreground_failed", { tab = tab_index, pane = pane_id })
            end
            return
        end
        if attempts >= FOREGROUND_POLL_ATTEMPTS then
            log.debug("restore.foreground_timeout", { tab = tab_index, pane = pane_id })
            return
        end
        wezterm.time.call_after(FOREGROUND_POLL_DELAY, poll)
    end
    wezterm.time.call_after(FOREGROUND_POLL_DELAY, poll)
end

-- latest is the state on_gui_startup read, or nil when there is none. restore
-- itself never reads the disk, so the decision logic is testable with a fake
-- mux. It returns true only when the saved layout was rebuilt.
function M.restore(cmd, latest)
    if type(latest) ~= "table" then
        log.warn("restore.no_state")
        return fallback(cmd)
    end

    if latest.version ~= state.SCHEMA_VERSION then
        log.warn("restore.version", {
            found = tostring(latest.version),
            expected = state.SCHEMA_VERSION,
        })
        return fallback(cmd)
    end

    if not state.validate(latest) then
        log.warn("restore.invalid")
        return fallback(cmd)
    end

    if state.is_stale(latest) then
        log.warn("restore.stale", {
            saved_at = tostring(latest.saved_at),
            max_age = state.MAX_AGE_SECONDS,
        })
        return fallback(cmd)
    end

    local tab_count = #latest.tabs
    if tab_count == 0 then
        log.warn("restore.empty")
        return fallback(cmd)
    end

    if
        not is_integer(latest.window.cols)
        or latest.window.cols < 1
        or not is_integer(latest.window.rows)
        or latest.window.rows < 1
    then
        log.warn("restore.invalid_window", {
            cols = tostring(latest.window.cols),
            rows = tostring(latest.window.rows),
        })
        return fallback(cmd)
    end

    -- Plan every tab before touching the mux, so a layout WezTerm cannot
    -- rebuild falls back without first opening a window.
    local plans = {}
    for tab_index, tab in ipairs(latest.tabs) do
        local rects = {}
        for _, saved_pane in ipairs(tab.panes) do
            rects[#rects + 1] = saved_pane.rect
        end
        local tree = M.plan(rects)
        if tree == nil then
            log.error("restore.plan_failed", { tab = tab_index, panes = #rects })
            return fallback(cmd)
        end
        plans[tab_index] = { saved = tab, tree = tree }
    end

    local active_tab = latest.window.active_tab
    if not is_integer(active_tab) or active_tab < 1 or active_tab > tab_count then
        log.warn("restore.active_tab_missing", { tab = tostring(active_tab) })
        active_tab = 1
    end

    local active_leaf
    for index, saved_pane in ipairs(latest.tabs[active_tab].panes) do
        if saved_pane.id == latest.window.active_pane then
            active_leaf = index
            break
        end
    end
    if active_leaf == nil then
        log.warn("restore.active_pane_missing", { pane = tostring(latest.window.active_pane) })
        active_leaf = 1
    end

    log.info("restore.start", {
        tabs = tab_count,
        cols = latest.window.cols,
        rows = latest.window.rows,
    })

    local root_saved = latest.tabs[1].panes[first_leaf(plans[1].tree)]
    local args = spawn_args(cmd)
    args.width = latest.window.cols
    args.height = latest.window.rows
    args.cwd = root_saved.cwd
    with_history_env(args, root_saved)

    local spawn_ok, spawned_tab, spawned_pane, window = pcall(wezterm.mux.spawn_window, args)
    if not spawn_ok or window == nil then
        log.error("restore.spawn_failed", { error = tostring(spawned_tab) })
        return fallback(cmd)
    end

    local tab_objects = {}
    local built, build_err = pcall(function()
        for tab_index, plan in ipairs(plans) do
            local tab
            local pane
            if tab_index == 1 then
                tab, pane = spawned_tab, spawned_pane
            else
                local tab_root_saved = plan.saved.panes[first_leaf(plan.tree)]
                local tab_args = { cwd = tab_root_saved.cwd }
                with_history_env(tab_args, tab_root_saved)
                local tab_ok, new_tab, new_pane = pcall(window.spawn_tab, window, tab_args)
                if not tab_ok or new_tab == nil or new_pane == nil then
                    error("tab " .. tab_index .. " spawn failed: " .. tostring(new_tab))
                end
                tab, pane = new_tab, new_pane
            end
            tab_objects[tab_index] = tab

            if type(plan.saved.title) == "string" then
                local titled = pcall(tab.set_title, tab, plan.saved.title)
                if not titled then
                    log.warn("restore.title_failed", { tab = tab_index })
                end
            end

            local created, expected, by_leaf = M.replay(pane, plan.tree, plan.saved.panes)
            if created == nil then
                error("tab " .. tab_index .. " replay failed: " .. tostring(expected))
            end
            plan.by_leaf = by_leaf
        end
    end)

    if not built then
        log.error("restore.failed", { error = tostring(build_err) })
        maximize(window)
        flash_status(window, " restore failed ")
        return false
    end

    for tab_index, plan in ipairs(plans) do
        for leaf, saved_pane in ipairs(plan.saved.panes) do
            local foreground = saved_pane.foreground
            if
                foreground ~= nil
                and foreground.alt_screen == true
                and type(foreground.argv) == "table"
                and #foreground.argv > 0
            then
                local pane_object = plan.by_leaf[leaf]
                if pane_object ~= nil then
                    local scheduled = pcall(
                        schedule_foreground,
                        pane_object,
                        foreground.argv,
                        saved_pane.id,
                        tab_index
                    )
                    if not scheduled then
                        log.warn("restore.foreground_failed", {
                            tab = tab_index,
                            pane = saved_pane.id,
                        })
                    end
                end
            end
        end
    end

    local active_tab_object = tab_objects[active_tab]
    if active_tab_object ~= nil then
        pcall(active_tab_object.activate, active_tab_object)
    end
    local active_pane_object = plans[active_tab].by_leaf[active_leaf]
    if active_pane_object ~= nil then
        pcall(active_pane_object.activate, active_pane_object)
    end

    local report = { tabs = {} }
    for tab_index, plan in ipairs(plans) do
        local expected_tab = {
            tab = tab_objects[tab_index],
            title = plan.saved.title,
            panes = {},
        }
        for leaf, saved_pane in ipairs(plan.saved.panes) do
            expected_tab.panes[leaf] = {
                id = saved_pane.id,
                rect = saved_pane.rect,
                cwd = saved_pane.cwd,
                pane = plan.by_leaf[leaf],
            }
        end
        report.tabs[tab_index] = expected_tab
    end

    -- A self-check problem is logged but never escalates into a fallback: the
    -- layout is already usable and a broken status area must not lose it.
    local settle_steps = selfcheck_settle_steps()
    local wired = pcall(check_selfcheck, window, report, 0, settle_steps)
    if not wired then
        log.warn("selfcheck.failed", { error = "self-check wiring raised" })
    end

    log.info("restore.done", { tabs = tab_count, active_tab = active_tab })
    return true
end

-- Registered on gui-startup by the entry. Must return true: a false return
-- silences every gui-startup handler registered after this one. The entry
-- wraps this call already; it also must not depend on that wrapper, so every
-- internal failure is caught here.
function M.on_gui_startup(cmd)
    pcall(log.init)

    local read_ok, latest = pcall(state.read_latest)
    if not read_ok then
        log.error("restore.read_failed", { error = tostring(latest) })
        latest = nil
    end

    local ok, err = pcall(M.restore, cmd, latest)
    if not ok then
        log.error("restore.failed", { error = tostring(err) })
        fallback(cmd)
    end

    -- Stale instance files otherwise accumulate forever. Prune once per
    -- startup, after the restore attempt, and never let it break startup.
    local pruned_ok, pruned = pcall(state.prune, os.time())
    if pruned_ok then
        log.info("restore.pruned", { removed = tonumber(pruned) or 0 })
    else
        log.warn("restore.prune_failed", { error = tostring(pruned) })
    end
    return true
end

local function pane_id_of(pane)
    if pane == nil then
        return nil
    end
    local ok, id = pcall(function()
        return pane:pane_id()
    end)
    if ok then
        return id
    end
    return nil
end

-- A Url or a plain path from pane:get_current_working_dir(). Missing or empty
-- means the pane has not reported yet; it is not a directory mismatch.
local function reported_cwd(value)
    if value == nil then
        return nil
    end
    local text
    if type(value) == "string" then
        text = value
    else
        local ok, file_path = pcall(function()
            return value.file_path
        end)
        if ok and type(file_path) == "string" then
            text = file_path
        end
    end
    if type(text) ~= "string" or text == "" then
        return nil
    end
    if text:sub(1, 7):lower() == "file://" then
        text = text:sub(8):gsub("%%(%x%x)", function(hex)
            return string.char(tonumber(hex, 16))
        end)
    end
    return text
end

-- Compare a reported cwd with the saved path. Windows cwds arrive as
-- /C:/Users/... from the Url and as C:\Users\... from the state, so normalise
-- case, forward versus backslash, and a trailing separator: C:\work and
-- c:/work/ are the same directory.
local function normalize_cwd(value)
    local text = reported_cwd(value)
    if text == nil then
        return nil
    end
    text = text:gsub("^/([%a]):", "%1:")
    text = text:gsub("/", "\\")
    text = text:lower()
    return (text:gsub("\\+$", ""))
end

-- One cell of slack on every rectangle edge absorbs rounding, not a real
-- layout change.
local function rect_drifts(live, expected)
    for _, edge in ipairs({ "left", "top", "width", "height" }) do
        local want = expected[edge]
        local got = live[edge]
        if type(want) ~= "number" or type(got) ~= "number" then
            return true
        end
        if math.abs(got - want) > 1 then
            return true
        end
    end
    return false
end

-- Compare the live tabs and panes against the report restore built from the
-- plan. Returns an array of { kind, tab, pane } findings (pane is absent for a
-- tab-level title finding) and an array of panes whose cwd has not been
-- reported yet. Never raises for a missing or odd live value.
function M.selfcheck(report)
    local findings = {}
    local unknown = {}
    if type(report) ~= "table" or type(report.tabs) ~= "table" then
        return findings, unknown
    end

    for tab_index, expected_tab in ipairs(report.tabs) do
        local tab = expected_tab.tab
        local live_title
        if tab ~= nil then
            local ok, title = pcall(tab.get_title, tab)
            if ok then
                live_title = title
            end
        end
        if type(expected_tab.title) == "string" and live_title ~= expected_tab.title then
            findings[#findings + 1] = { kind = "title", tab = tab_index }
        end

        local live_by_id = {}
        if tab ~= nil then
            local ok, infos = pcall(tab.panes_with_info, tab)
            if ok and type(infos) == "table" then
                for _, info in ipairs(infos) do
                    local id = pane_id_of(info.pane)
                    if id ~= nil then
                        live_by_id[id] = info
                    end
                end
            end
        end

        for _, expected_pane in ipairs(expected_tab.panes or {}) do
            local live = live_by_id[pane_id_of(expected_pane.pane)]
            if live == nil then
                findings[#findings + 1] = {
                    kind = "missing_pane",
                    tab = tab_index,
                    pane = expected_pane.id,
                }
            else
                if rect_drifts(live, expected_pane.rect or {}) then
                    findings[#findings + 1] = {
                        kind = "rect",
                        tab = tab_index,
                        pane = expected_pane.id,
                    }
                end

                local live_cwd
                if expected_pane.pane ~= nil then
                    local ok, url = pcall(expected_pane.pane.get_current_working_dir, expected_pane.pane)
                    if ok then
                        live_cwd = url
                    end
                end
                if type(expected_pane.cwd) == "string" and expected_pane.cwd ~= "" then
                    local reported = reported_cwd(live_cwd)
                    if reported == nil then
                        unknown[#unknown + 1] = {
                            tab = tab_index,
                            pane = expected_pane.id,
                        }
                    elseif normalize_cwd(reported) ~= normalize_cwd(expected_pane.cwd) then
                        findings[#findings + 1] = {
                            kind = "cwd",
                            tab = tab_index,
                            pane = expected_pane.id,
                        }
                    end
                end
            end
        end
    end

    return findings, unknown
end

return M
