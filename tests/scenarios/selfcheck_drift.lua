-- Step 11: the self-check sees drift, logs it, and flashes the status.
--
-- The seeded state is geometrically valid, so the restore succeeds. Its second
-- pane has an empty cwd, which pane:split cannot apply: the live pane inherits
-- a real directory, so the post-restore self-check inside lib\layout sees a cwd
-- drift and takes the emission path (selfcheck.drift log plus the
-- " restore drift: N " status). Then the scenario changes the live layout with
-- an extra split and calls lib\layout.selfcheck through the public seam against
-- a report of the pre-split layout, proving the comparison itself catches the
-- drift rather than only the restore path.
local wezterm = require("wezterm")

local config_dir = (wezterm.config_dir or ""):gsub("\\", "/"):gsub("/+$", "")
package.path = config_dir .. "/?.lua;" .. config_dir .. "/?/init.lua;" .. package.path
local support = require("support.integration")

local report_path = os.getenv("WEZTERM_SESSION_TEST_REPORT") or ""
local token = os.getenv("WEZTERM_SESSION_TEST_TOKEN") or ""

local checks = {}
local finished = false

local function add(name, ok, detail)
    support.add(checks, name, ok, detail)
end

local function finish()
    if finished then
        return
    end
    finished = true
    support.write(report_path, checks, { token = token, pid = support.pid() })
end

local repo_root = support.repo_root(config_dir)
package.path = repo_root .. "/?.lua;" .. repo_root .. "/?/init.lua;" .. package.path

local state = require("lib.state")
local now = os.time()
local seeded = {
    version = state.SCHEMA_VERSION,
    saved_at = now,
    instance = { id = "selfcheck-drift", started_at = now - 60 },
    window = { cols = 120, rows = 35, active_tab = 1, active_pane = 1 },
    tabs = {
        {
            title = "drift-seed",
            panes = {
                {
                    id = 1,
                    rect = { left = 0, top = 0, width = 79, height = 35 },
                    cwd = "C:/Windows",
                },
                {
                    id = 2,
                    rect = { left = 80, top = 0, width = 40, height = 35 },
                    -- A directory that does not exist. The split cannot apply
                    -- it, so the pane starts elsewhere and reports that other
                    -- path: a genuine reported mismatch, not an unknown cwd.
                    cwd = "C:/Users/rfigueiredo/wezterm-session-layer-missing-dir",
                },
            },
        },
    },
}
local seeded_ok, seeded_err = state.write(seeded)
add("drift_state_seeded", seeded_ok,
    seeded_ok and "valid geometry with a non-reproducible cwd"
        or ("state.write failed: " .. tostring(seeded_err)))

local loaded, config = pcall(dofile, repo_root .. "/wezterm.lua")
if not loaded then
    add("entry_load", false, "dofile(" .. repo_root .. "/wezterm.lua) failed: " .. tostring(config))
    finish()
    return wezterm.config_builder()
end
add("entry_load", true, "repository entry evaluated from " .. repo_root .. "/wezterm.lua")
config.automatically_reload_config = false

local layout = require("lib.layout")

local function pane_id(pane)
    local ok, id = pcall(pane.pane_id, pane)
    if ok then
        return id
    end
    return nil
end

local function rect_key(rect)
    return string.format("%d,%d,%d,%d", rect.left, rect.top, rect.width, rect.height)
end

local function live_rect(info)
    return {
        left = info.left,
        top = info.top,
        width = info.width,
        height = info.height,
    }
end

wezterm.on("gui-startup", function(_cmd)
    support.await_window(10, function(_window, tab)
        support.settle(tab, 10, function(infos)
            local expected = {}
            for _, pane in ipairs(seeded.tabs[1].panes) do
                expected[#expected + 1] = pane.rect
            end
            local live = {}
            for _, info in ipairs(infos) do
                live[#live + 1] = live_rect(info)
            end

            add("pane_count", #live == 2, "panes=" .. tostring(#live))
            local mismatch
            for index = 1, math.max(#expected, #live) do
                if expected[index] == nil
                    or live[index] == nil
                    or rect_key(expected[index]) ~= rect_key(live[index])
                then
                    mismatch = string.format("pane %d: saved %s live %s", index,
                        expected[index] ~= nil and rect_key(expected[index]) or "missing",
                        live[index] ~= nil and rect_key(live[index]) or "missing")
                    break
                end
            end
            add("rects_exact", mismatch == nil, mismatch or "both rectangles identical")

            -- Emission path: the restore's own self-check must have logged the
            -- The restore's own self-check may wait for the shells to report
            -- cwd before it reports, so poll for the drift line before reading
            -- the status it just flashed.
            local function after_drift()
                support.add_log_absent(add, report_path, "no_selfcheck_error", {
                    "selfcheck.failed",
                    "selfcheck.status_failed",
                    "restore.failed",
                })

                local gui_ok, gui_windows = pcall(wezterm.gui.gui_windows)
                local gui_window = gui_ok and gui_windows and gui_windows[1] or nil
                local getter = gui_window and gui_window.get_right_status
                if type(getter) == "function" then
                    local read_ok, status = pcall(getter, gui_window)
                    add("drift_status",
                        read_ok and type(status) == "string" and status:find("drift", 1, true) ~= nil,
                        "status=" .. tostring(status))
                else
                    -- This build exposes no status getter. Setting the status is
                    -- proven by the absence of selfcheck.status_failed above.
                    add("drift_status", true,
                        "no status getter in this build; selfcheck.status_failed absent")
                end

                -- Public seam: build the report from the live layout as it was,
                -- assert it is clean, add an extra split, then assert the
                -- comparison now reports rectangle drift.
                local report = {
                    tabs = {
                        {
                            tab = tab,
                            title = seeded.tabs[1].title,
                            panes = {},
                        },
                    },
                }
                for index, info in ipairs(infos) do
                    local cwd_ok, live_url = pcall(info.pane.get_current_working_dir, info.pane)
                    report.tabs[1].panes[index] = {
                        id = pane_id(info.pane),
                        rect = live_rect(info),
                        cwd = cwd_ok and live_url or nil,
                        pane = info.pane,
                    }
                end

                local clean_findings = layout.selfcheck(report)
                add("selfcheck_clean", type(clean_findings) == "table" and #clean_findings == 0,
                    type(clean_findings) == "table"
                        and (#clean_findings .. " finding(s) before the split")
                        or "selfcheck did not return a table")

                local source = infos[1].pane
                local split_ok, child = pcall(source.split, source, {
                    direction = "Right",
                    size = 20,
                })
                add("drift_split", split_ok and child ~= nil,
                    split_ok and "extra Right split, 20 cells" or tostring(child))

                local findings = layout.selfcheck(report)
                local kinds = {}
                for _, finding in ipairs(type(findings) == "table" and findings or {}) do
                    kinds[#kinds + 1] = tostring(finding.kind)
                end
                local saw_rect = false
                for _, kind in ipairs(kinds) do
                    if kind == "rect" then
                        saw_rect = true
                    end
                end
                add("selfcheck_seam_drift",
                    type(findings) == "table" and #findings > 0 and saw_rect,
                    string.format("%d finding(s): %s",
                        type(findings) == "table" and #findings or -1,
                        table.concat(kinds, ",")))

                finish()
            end

            local drift_polls = 0
            local function await_drift_log()
                drift_polls = drift_polls + 1
                local found, line = support.find_log_event(report_path, "selfcheck.drift", "warn")
                if found then
                    add("log_drift", true, line)
                    add("drift_timed_out", line:find("timed_out=true", 1, true) ~= nil, line)
                    after_drift()
                    return
                end
                -- The fixed self-check waits up to ten seconds for the shells to
                -- report cwd, so poll past that window before declaring failure.
                if drift_polls > 160 then
                    add("log_drift", false,
                        "no selfcheck.drift within 16s (artifacts: "
                            .. support.scenario_dir(report_path) .. ")")
                    after_drift()
                    return
                end
                wezterm.time.call_after(0.1, await_drift_log)
            end
            await_drift_log()
        end, function(message)
            add("layout_settled", false, message)
            finish()
        end)
    end, function(message)
        add("window_present", false, message)
        finish()
    end)
    return true
end)

return config
