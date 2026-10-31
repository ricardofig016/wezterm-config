-- Entry point. WezTerm evaluates a config more than once per process, so this
-- file only assembles the config: no timers, no disk writes, no side effects.
local wezterm = require("wezterm")

-- --config-file does not put this file's directory on package.path, and the Lua
-- sandbox has no debug library, so wezterm.config_dir is the way to find it.
-- Duplicate entries are harmless.
local here = wezterm.config_dir
if here and here ~= "" then
    package.path = here .. "/?.lua;" .. here .. "/?/init.lua;" .. package.path
end

local config = wezterm.config_builder()

require("lib.config").apply(config)
require("lib.keys").apply(config)

local layout = require("lib.layout")
local save = require("lib.save")
require("lib.log")

-- A gui-startup handler that returns false silences every handler registered
-- after it, so each wrapper ends with an explicit true.
wezterm.on("gui-startup", function(cmd)
    layout.on_gui_startup(cmd)
    return true
end)

wezterm.on("gui-startup", function(cmd)
    save.on_gui_startup(cmd)
    return true
end)

return config
