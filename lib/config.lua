-- Static options, moved out of the old single-file config.
local M = {}

function M.default_program()
    return { "pwsh.exe", "-NoLogo" }
end

function M.apply(config)
    config.color_scheme = "Tokyo Night"
    config.font_size = 8.0
    config.window_decorations = "TITLE | RESIZE"
    config.initial_cols = 120
    config.initial_rows = 35
    config.default_prog = M.default_program()
    -- Keep the nested-shell history cache within the pane that created it.
    config.set_environment_variables = {
        WEZTERM_SESSION_HISTORY_PANE = "",
        WEZTERM_SESSION_PANE_HISTORY = "",
    }
end

return M
