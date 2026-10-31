-- The key behaviour carried over from the old config.
local wezterm = require("wezterm")
local act = wezterm.action

local function split(direction)
    return act.SplitPane({ direction = direction, size = { Percent = 50 } })
end

local function save_now(window, pane)
    require("lib.save").save_now(window)
end

-- initial_value does not exist in this build, so the prompt starts empty.
-- Submitting an empty line clears the title. A nil line means the prompt was
-- cancelled, so the current title stays.
local function rename_tab(window, pane)
    window:perform_action(act.PromptInputLine({
        description = "Rename tab",
        action = wezterm.action_callback(function(win, _, line)
            if line == nil then
                return
            end
            win:active_tab():set_title(line)
        end),
    }), pane)
end

local M = {}

function M.apply(config)
    config.keys = {
        { key = "RightArrow", mods = "ALT", action = split("Right") },
        { key = "LeftArrow", mods = "ALT", action = split("Left") },
        { key = "DownArrow", mods = "ALT", action = split("Down") },
        { key = "UpArrow", mods = "ALT", action = split("Up") },
        { key = "w", mods = "ALT", action = act.CloseCurrentPane({ confirm = false }) },
        { key = "s", mods = "ALT", action = wezterm.action_callback(save_now) },
        { key = "F2", action = wezterm.action_callback(rename_tab) },
        { key = "r", mods = "ALT", action = wezterm.action_callback(rename_tab) },
    }
end

return M
