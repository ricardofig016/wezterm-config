-- Step 8b: state describing panes the rebuild cannot create.
--
-- The state is valid version 1, but its rectangles overlap, so no guillotine
-- split order can reproduce them. Restore must plan before touching the mux,
-- log restore.plan_failed, and take the maximized fallback rather than opening
-- a window with a wrong layout.
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
    instance = { id = "seeded-unrebuildable", started_at = now - 60 },
    window = { cols = 110, rows = 30, active_tab = 1, active_pane = 31 },
    tabs = {
        {
            title = "seeded unrebuildable",
            panes = {
                {
                    id = 31,
                    rect = { left = 0, top = 0, width = 60, height = 30 },
                    cwd = "C:/Windows",
                },
                {
                    id = 32,
                    rect = { left = 50, top = 0, width = 60, height = 30 },
                    cwd = "C:/Windows",
                },
            },
        },
    },
}
local seeded_ok, seeded_err = state.write(seeded)
add("unrebuildable_state_seeded", seeded_ok,
    seeded_ok and "two overlapping rectangles" or ("state.write failed: " .. tostring(seeded_err)))

local loaded, config = pcall(dofile, repo_root .. "/wezterm.lua")
if not loaded then
    add("entry_load", false, "dofile(" .. repo_root .. "/wezterm.lua) failed: " .. tostring(config))
    finish()
    return wezterm.config_builder()
end
add("entry_load", true, "repository entry evaluated from " .. repo_root .. "/wezterm.lua")
config.automatically_reload_config = false

wezterm.on("gui-startup", function(_cmd)
    support.await_window(8, function(_window, tab)
        support.settle(tab, 8, function(infos)
            support.check_maximized_fallback(add, infos)
            support.add_log_check(add, report_path, "log_plan_failed", "restore.plan_failed", "error")
            support.add_log_absent(add, report_path, "log_no_rebuild_failure", {
                "restore.failed",
                "restore.invalid",
                "restore.spawn_failed",
            })
            finish()
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
