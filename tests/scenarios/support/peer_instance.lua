-- Peer instance config for tests\scenarios\two_instances.lua.
--
-- Lives under support\ so the runner never discovers it as a scenario. The
-- two-instance scenario launches wezterm-gui with this file as the config; the
-- child inherits WEZTERM_SESSION_STATE_DIR, evaluates the real repository entry
-- so its own save detector runs, and records its pid for the parent to track.
local wezterm = require("wezterm")

local config_dir = (wezterm.config_dir or ""):gsub("\\", "/"):gsub("/+$", "")
package.path = config_dir .. "/?.lua;" .. config_dir .. "/?/init.lua;" .. package.path

local scenarios_dir = config_dir:gsub("/support$", "")
local repo_root = scenarios_dir:match("^(.*)/tests/scenarios$")
if repo_root == nil then
    return wezterm.config_builder()
end
package.path = repo_root .. "/?.lua;" .. repo_root .. "/?/init.lua;" .. package.path

local state_dir = os.getenv("WEZTERM_SESSION_STATE_DIR")
if state_dir ~= nil and state_dir ~= "" then
    local handle = io.open(state_dir .. "/peer.pid", "w")
    if handle then
        handle:write(tostring(wezterm.procinfo.pid()) .. "\n")
        handle:flush()
        handle:close()
    end
end

local loaded, config = pcall(dofile, repo_root .. "/wezterm.lua")
if not loaded then
    return wezterm.config_builder()
end
config.automatically_reload_config = false
return config
