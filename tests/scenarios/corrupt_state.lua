-- Step 8b: corrupt state.
--
-- Seed a truncated JSON file where a session file belongs. state.read_latest()
-- validates every file and skips an unparseable one, so restore sees no state,
-- logs restore.no_state, and takes the maximized fallback rather than a wrong
-- layout. The file is left in place so the scenario can assert the runner did
-- not silently delete it.
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
    instance = { id = "seeded-corrupt", started_at = now - 60 },
    window = { cols = 100, rows = 30, active_tab = 1, active_pane = 21 },
    tabs = {
        {
            title = "seeded corrupt",
            panes = {
                {
                    id = 21,
                    rect = { left = 0, top = 0, width = 100, height = 30 },
                    cwd = "C:/Windows",
                },
            },
        },
    },
}
local seeded_ok, seeded_err = state.write(seeded)
local truncated = '{"version": 1, "saved_at": 1700000000, "instance": {"id": "seeded-corrupt"'
local overwrote, overwrite_err = support.write_text(state.path("seeded-corrupt"), truncated)
add("corrupt_state_seeded",
    seeded_ok and overwrote,
    seeded_ok and overwrote and ("truncated JSON at " .. state.path("seeded-corrupt"))
        or ("seed: " .. tostring(seeded_err) .. " overwrite: " .. tostring(overwrite_err)))

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
            -- This build's read_latest() treats an unparseable file as absent,
            -- so the observable event is restore.no_state, not a corrupt-file
            -- error line. Assert what the implementation actually promises.
            support.add_log_check(add, report_path, "log_corrupt_ignored", "restore.no_state", "warn")
            add("corrupt_file_kept",
                support.read_text(state.path("seeded-corrupt")) == truncated,
                "the truncated file must stay where it was")
            support.add_log_absent(add, report_path, "log_no_wrong_restore", {
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
