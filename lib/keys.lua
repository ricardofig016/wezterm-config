-- The key behaviour carried over from the old config.
local wezterm = require("wezterm")
local act = wezterm.action

local function split(direction)
    return act.SplitPane({ direction = direction, size = { Percent = 50 } })
end

local function save_now(window, pane)
    require("lib.save").save_now(window)
end

-- The pinned layout is the one restore always chooses. Resolved at key-press
-- time, so the bindings exist before lib.save implements the pair.
local function pin_now(window, pane)
    require("lib.save").pin_now(window)
end

local function unpin_now(window, pane)
    require("lib.save").unpin_now(window)
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
        -- Mapped key semantics: the key's case encodes SHIFT and WezTerm strips
        -- an explicit SHIFT from mods, so ALT with lowercase p and ALT with
        -- uppercase P are two distinct bindings. Sharing one case silently
        -- collapses them into a single assignment.
        { key = "p", mods = "ALT", action = wezterm.action_callback(pin_now) },
        { key = "P", mods = "ALT|SHIFT", action = wezterm.action_callback(unpin_now) },
        { key = "F2", action = wezterm.action_callback(rename_tab) },
        { key = "r", mods = "ALT", action = wezterm.action_callback(rename_tab) },
    }
end

return M
