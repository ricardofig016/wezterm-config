-- Step 8b: fresh start with no saved state.
--
-- The entry's restore must take its fallback: one fresh window, maximized, with
-- a single pane and no restore error in the log. The startup save baseline is
-- expected and is not this scenario's concern (save_timing covers it).
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
local loaded, config = pcall(dofile, repo_root .. "/wezterm.lua")
if not loaded then
    add("entry_load", false, "dofile(" .. repo_root .. "/wezterm.lua) failed: " .. tostring(config))
    finish()
    return wezterm.config_builder()
end
add("entry_load", true, "repository entry evaluated from " .. repo_root .. "/wezterm.lua")
config.automatically_reload_config = false

-- The state directory is empty because the runner created it fresh. Assert that
-- rather than trusting the variable: the report path determines it.
add("no_state_before_launch",
    #support.session_names(report_path) == 0,
    "session files before launch: " .. tostring(#support.session_names(report_path)))

wezterm.on("gui-startup", function(_cmd)
    support.await_window(8, function(_window, tab)
        support.settle(tab, 8, function(infos)
            support.check_maximized_fallback(add, infos)
            support.add_log_check(add, report_path, "log_no_state", "restore.no_state", "warn")
            support.add_log_absent(add, report_path, "log_no_restore_errors", {
                "restore.failed",
                "restore.plan_failed",
                "restore.invalid",
                "restore.version",
                "restore.stale",
                "restore.read_failed",
                "restore.spawn_failed",
                "restore.empty",
                "restore.invalid_window",
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
