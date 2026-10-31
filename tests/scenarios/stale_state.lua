-- Step 8b: stale state.
--
-- Seed version 1 state whose saved_at is eight days old. Restore must reject it
-- as older than seven days, log restore.stale, and take the maximized fallback
-- instead of rebuilding the single saved pane at its saved size.
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

-- Seed the stale state before the entry registers gui-startup, so restore reads
-- it on its first pass.
local state = require("lib.state")
local eight_days = 8 * 24 * 60 * 60
local seeded_at = os.time() - eight_days
local seeded = {
    version = state.SCHEMA_VERSION,
    saved_at = seeded_at,
    instance = { id = "seeded-stale", started_at = seeded_at - 60 },
    window = { cols = 100, rows = 30, active_tab = 1, active_pane = 11 },
    tabs = {
        {
            title = "seeded stale",
            panes = {
                {
                    id = 11,
                    rect = { left = 0, top = 0, width = 100, height = 30 },
                    cwd = "C:/Windows",
                },
            },
        },
    },
}
local seeded_ok, seeded_err = state.write(seeded)
add("stale_state_seeded", seeded_ok,
    seeded_ok and ("saved_at=" .. tostring(seeded_at) .. " (eight days old)")
        or ("state.write failed: " .. tostring(seeded_err)))

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
            support.add_log_check(add, report_path, "log_stale", "restore.stale", "warn")
            support.add_log_absent(add, report_path, "log_no_rebuild_error", {
                "restore.failed",
                "restore.plan_failed",
                "restore.invalid",
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
