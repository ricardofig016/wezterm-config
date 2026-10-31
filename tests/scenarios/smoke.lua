-- Integration smoke scenario: proves the runner plumbing and the maximized
-- fallback, not restore.
--
-- The runner launches this file as the WezTerm config:
--
--   wezterm-gui.exe --config-file tests\scenarios\smoke.lua
--
-- with WEZTERM_SESSION_STATE_DIR, WEZTERM_SESSION_TEST_REPORT and
-- WEZTERM_SESSION_TEST_TOKEN set (see support\integration.lua). This file
-- evaluates the repository entry exactly as a normal launch would, then
-- instruments the running app: it waits for the first window to settle, reads
-- real pane geometry from tab:panes_with_info(), and writes the JSON report.
--
-- With no saved state, the entry's restore falls back to a fresh window and
-- maximizes it, which is the behaviour the old config had. The intended shape
-- is therefore exactly one pane at the tab origin whose cell grid is at least
-- the configured 120 by 35 fallback and whose pixel size fills the primary
-- screen to within window chrome (title bar, tab bar, taskbar). Asserting the
-- pixel size against wezterm.gui.screens() is what proves the maximize ran,
-- rather than assuming a fixed cell count.
local wezterm = require("wezterm")

local config_dir = (wezterm.config_dir or ""):gsub("\\", "/"):gsub("/+$", "")
package.path = config_dir .. "/?.lua;" .. config_dir .. "/?/init.lua;" .. package.path
local support = require("support.integration")

local report_path = os.getenv("WEZTERM_SESSION_TEST_REPORT") or ""
local token = os.getenv("WEZTERM_SESSION_TEST_TOKEN") or ""

-- The configured fallback from lib\config.lua. A maximized window can only be
-- larger than this on this machine.
local FALLBACK_COLS = 120
local FALLBACK_ROWS = 35

-- The pane is inside the window's client area, which is inside the screen.
-- Chrome (title bar, tab bar) and the taskbar account for the gap; a normal
-- 120x35 fallback would leave roughly 720x430 px of slack on this 1920x1200
-- screen, so a 250 px allowance still rejects a window that did not maximize.
local SCREEN_TOLERANCE_PX = 250

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
    support.write(report_path, checks, {
        token = token,
        pid = support.pid(),
    })
end

-- The scenario must run with the repository entry as its config, so evaluate
-- that entry here and return the table it builds.
local repo_root = support.repo_root(config_dir)
package.path = repo_root .. "/?.lua;" .. repo_root .. "/?/init.lua;" .. package.path
local loaded, config = pcall(dofile, repo_root .. "/wezterm.lua")
if not loaded then
    add("entry_load", false,
        "dofile(" .. repo_root .. "/wezterm.lua) failed: " .. tostring(config))
    finish()
    return wezterm.config_builder()
end
add("entry_load", true, "repository entry evaluated from " .. repo_root .. "/wezterm.lua")

-- Concurrent edits to lib\ must not reload the config mid-scenario. This is a
-- harness policy only: restore and save behaviour are untouched.
config.automatically_reload_config = false

-- The state directory the app sees must be exactly the one the runner created
-- under %TEMP%, never the user's real state directory. The expected path is
-- derived from the report path the runner passed, so this checks the wiring
-- rather than trusting the variable it is checking. TEMP itself is not compared
-- because WezTerm canonicalises it to the long path form while the runner's own
-- paths keep the short form.
local state_dir = os.getenv("WEZTERM_SESSION_STATE_DIR")
local expected_state = support.dirname(report_path) .. "/state"
local isolated = support.same_path(state_dir, expected_state)
    and not support.normalize(state_dir or ""):lower():find("/appdata/roaming/", 1, true)
add("state_dir_isolated", isolated,
    "WEZTERM_SESSION_STATE_DIR=" .. tostring(state_dir) .. " expected=" .. expected_state)

local pid = support.pid()
add("process_pid", pid > 0, "pid=" .. tostring(pid))

local function pane_signature(panes)
    local parts = {}
    for _, info in ipairs(panes) do
        parts[#parts + 1] = string.format(
            "%s,%s,%s,%s,%s,%s",
            tostring(info.left),
            tostring(info.top),
            tostring(info.width),
            tostring(info.height),
            tostring(info.pixel_width),
            tostring(info.pixel_height)
        )
    end
    return table.concat(parts, ";")
end

wezterm.on("gui-startup", function(_cmd)
    local deadline = os.time() + 8
    local announced = false
    local last_signature = nil
    local stable = 0

    local function inspect(attempt)
        if finished then
            return
        end
        local ok, windows = pcall(wezterm.mux.all_windows)
        if not ok then
            add("window_present", false, "wezterm.mux.all_windows() failed: " .. tostring(windows))
            finish()
            return
        end
        windows = windows or {}

        local tab = nil
        if #windows > 0 then
            local tabs = windows[1]:tabs()
            if tabs and #tabs > 0 then
                tab = tabs[1]
            end
        end

        if tab == nil then
            if os.time() > deadline then
                add("window_present", false,
                    string.format("no window or tab after 8s (#windows=%d, poll %d)", #windows, attempt))
                finish()
                return
            end
            wezterm.time.call_after(0.1, function()
                inspect(attempt + 1)
            end)
            return
        end

        if not announced then
            add("window_present", true,
                string.format("window 1, tab 1, after %d poll(s)", attempt))
            announced = true
        end

        -- The fallback spawns the window and then maximizes it. Wait for two
        -- consecutive identical reads, so the checks never measure the
        -- pre-maximize geometry.
        local panes = tab:panes_with_info()
        local signature = pane_signature(panes)
        if signature == last_signature then
            stable = stable + 1
        else
            stable = 0
        end
        last_signature = signature
        if stable < 2 and os.time() <= deadline then
            wezterm.time.call_after(0.1, function()
                inspect(attempt + 1)
            end)
            return
        end

        add("pane_count", #panes == 1, "panes=" .. tostring(#panes))

        local first = panes[1]
        if first == nil then
            add("first_pane_rect", false, "tab:panes_with_info() returned no panes")
            add("maximized_pixels", false, "tab:panes_with_info() returned no panes")
            finish()
            return
        end

        local width = tonumber(first.width) or -1
        local height = tonumber(first.height) or -1
        add("first_pane_rect",
            first.left == 0
                and first.top == 0
                and width >= FALLBACK_COLS
                and height >= FALLBACK_ROWS,
            string.format(
                "left=%s top=%s width=%s height=%s (expected left=0 top=0 at least %dx%d cells)",
                tostring(first.left),
                tostring(first.top),
                tostring(width),
                tostring(height),
                FALLBACK_COLS,
                FALLBACK_ROWS
            ))

        local screens_ok, screens = pcall(wezterm.gui.screens)
        local screen = nil
        if screens_ok and type(screens) == "table" then
            screen = screens.main or screens.active or screens[1]
        end
        if type(screen) ~= "table" then
            add("maximized_pixels", false,
                "wezterm.gui.screens() returned no primary screen: " .. tostring(screens))
            finish()
            return
        end

        local pixel_width = tonumber(first.pixel_width) or -1
        local pixel_height = tonumber(first.pixel_height) or -1
        local screen_width = tonumber(screen.width) or -1
        local screen_height = tonumber(screen.height) or -1
        local width_slack = screen_width - pixel_width
        local height_slack = screen_height - pixel_height
        add("maximized_pixels",
            pixel_width > 0
                and pixel_height > 0
                and width_slack >= 0
                and height_slack >= 0
                and width_slack <= SCREEN_TOLERANCE_PX
                and height_slack <= SCREEN_TOLERANCE_PX,
            string.format(
                "pane=%dx%d px screen=%dx%d px slack=%dx%d px tolerance=%d px",
                pixel_width,
                pixel_height,
                screen_width,
                screen_height,
                width_slack,
                height_slack,
                SCREEN_TOLERANCE_PX
            ))

        finish()
    end

    wezterm.time.call_after(0.1, function()
        inspect(1)
    end)
    return true
end)

return config
