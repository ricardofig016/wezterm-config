-- Step 8b: save timing.
--
-- The startup baseline write is expected. After the fingerprint has settled,
-- an idle instance must not write for at least ten seconds, and a split must be
-- written within three seconds. The scenario reads this instance's own file
-- from the isolated state directory; it never looks at the user's real state.
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

local state = require("lib.state")

local function pane_count(snapshot)
    local count = 0
    for _, tab in ipairs(snapshot.tabs or {}) do
        count = count + #(tab.panes or {})
    end
    return count
end

wezterm.on("gui-startup", function(_cmd)
    support.await_window(8, function(_window, tab)
        support.settle(tab, 10, function(infos)
            local instance_id = state.instance_id()
            local state_path = state.path(instance_id)
            add("starter_pane", #infos == 1, "panes=" .. tostring(#infos))

            -- Forward declarations: each step schedules the next one in a timer,
            -- so the callee must be in scope at definition time, not at call
            -- time.
            local await_baseline, await_quiet, measure_idle, split_and_measure

            -- 1. The startup baseline is expected; wait for it, do not measure
            -- from process start.
            local baseline_polls = 0
            await_baseline = function()
                baseline_polls = baseline_polls + 1
                local snapshot = state.read(instance_id)
                if snapshot ~= nil then
                    add("baseline_written", true,
                        string.format("after %.1fs, %d pane(s), saved_at=%s",
                            baseline_polls * 0.1, pane_count(snapshot), tostring(snapshot.saved_at)))
                    await_quiet()
                    return
                end
                if baseline_polls > 120 then
                    add("baseline_written", false, "no baseline state file after 12s")
                    finish()
                    return
                end
                wezterm.time.call_after(0.1, await_baseline)
            end

            -- 2. The shell and tab title can settle just after the baseline
            -- write. Let the fingerprint go quiet before the ten second idle
            -- measurement, otherwise this would measure startup, not idleness.
            local quiet_rounds = 0
            await_quiet = function()
                local before = support.read_text(state_path)
                wezterm.time.call_after(2.0, function()
                    local after = support.read_text(state_path)
                    if after ~= before and quiet_rounds < 3 then
                        quiet_rounds = quiet_rounds + 1
                        await_quiet()
                        return
                    end
                    measure_idle(after)
                end)
            end

            -- 3. Ten seconds of silence.
            measure_idle = function(before)
                wezterm.time.call_after(10.0, function()
                    local after = support.read_text(state_path)
                    add("idle_silent_10s", after ~= nil and after == before,
                        after == before and "state file unchanged for 10s"
                            or "state file changed during ten idle seconds")
                    split_and_measure()
                end)
            end

            -- 4. A split must be written within three seconds. The detector
            -- ticks every second and settles for two, so three seconds is the
            -- documented bound; one poll of slack covers the 0.1s sampling.
            split_and_measure = function()
                local current = tab:panes_with_info()
                local root = current[1] and current[1].pane or nil
                if root == nil then
                    add("split_created", false, "no pane to split")
                    finish()
                    return
                end
                local ok, child = pcall(root.split, root, { direction = "Right", size = 40 })
                add("split_created", ok and child ~= nil,
                    ok and "Right split, 40 cells" or ("split failed: " .. tostring(child)))

                local idle_text = support.read_text(state_path)
                local polls = 0
                local function await_saved()
                    polls = polls + 1
                    local snapshot = state.read(instance_id)
                    local text = support.read_text(state_path)
                    if snapshot ~= nil
                        and pane_count(snapshot) == 2
                        and text ~= nil
                        and text ~= idle_text
                    then
                        local seconds = polls * 0.1
                        add("split_saved_within_3s", seconds <= 3.3,
                            string.format("observed after %.1fs (%d polls)", seconds, polls))
                        finish()
                        return
                    end
                    if polls > 60 then
                        add("split_saved_within_3s", false, "no two-pane save after 6s")
                        finish()
                        return
                    end
                    wezterm.time.call_after(0.1, await_saved)
                end
                wezterm.time.call_after(0.1, await_saved)
            end

            wezterm.time.call_after(0.1, await_baseline)
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
