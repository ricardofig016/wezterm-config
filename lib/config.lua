-- Static options, moved out of the old single-file config.
local M = {}

function M.apply(config)
    config.color_scheme = "Tokyo Night"
    config.font_size = 8.0
    config.window_decorations = "TITLE | RESIZE"
    config.initial_cols = 120
    config.initial_rows = 35
    config.default_prog = { "pwsh.exe", "-NoLogo" }
end

return M
