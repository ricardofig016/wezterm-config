-- Shared plumbing for real-GUI integration scenarios.
--
-- A scenario is itself the WezTerm config file:
--
--   wezterm-gui.exe --config-file tests\scenarios\<name>.lua
--
-- The runner passes three environment variables to the launched process:
--
--   WEZTERM_SESSION_STATE_DIR    isolated state directory for this scenario
--   WEZTERM_SESSION_TEST_REPORT  where the scenario must write its JSON report
--   WEZTERM_SESSION_TEST_TOKEN   copied into the report so the runner can tell
--                                this launch's report from any other file
--
-- The report is the only pass signal; the runner never inspects the window.
-- Its shape is:
--
--   { "ok": <bool>, "token": <string>, "pid": <number>,
--     "checks": [ { "name": <string>, "ok": <bool>, "detail": <string> } ] }
--
-- Nothing here launches a process or writes state. The scenario owns the
-- in-app assertions; the runner owns process lifetime and the timeout.

local wezterm = require("wezterm")

local M = {}

function M.normalize(path)
    return (tostring(path):gsub("\\", "/"))
end

-- Strip trailing separators, then drop the final component. Kept local to this
-- file so scenarios need no debug library and no repository-relative cwd.
function M.dirname(path)
    local normalized = M.normalize(path):gsub("/+$", "")
    return normalized:match("^(.*)/[^/]+$") or normalized
end

-- config_dir follows --config-file, and scenarios live in
-- <repo>\tests\scenarios, so two levels up is the repository root.
function M.repo_root(config_dir)
    return M.dirname(M.dirname(config_dir))
end

function M.same_path(a, b)
    if a == nil or b == nil then
        return false
    end
    return M.normalize(a):lower() == M.normalize(b):lower()
end

-- Windows process id of the GUI process, or -1 when the API is missing. The
-- runner requires this value to match the pid it launched.
function M.pid()
    local ok, pid = pcall(function()
        return wezterm.procinfo.pid()
    end)
    if ok and type(pid) == "number" then
        return pid
    end
    return -1
end

function M.add(checks, name, ok, detail)
    checks[#checks + 1] = {
        name = tostring(name),
        ok = ok == true,
        detail = detail == nil and "" or tostring(detail),
    }
end

function M.passed(checks)
    for _, check in ipairs(checks) do
        if not check.ok then
            return false
        end
    end
    return true
end

local function quote(value)
    local text = tostring(value)
    local out = {}
    for index = 1, #text do
        local char = text:sub(index, index)
        local byte = text:byte(index)
        if char == '"' then
            out[#out + 1] = '\\"'
        elseif char == "\\" then
            out[#out + 1] = "\\\\"
        elseif char == "\n" then
            out[#out + 1] = "\\n"
        elseif char == "\r" then
            out[#out + 1] = "\\r"
        elseif char == "\t" then
            out[#out + 1] = "\\t"
        elseif byte < 32 then
            out[#out + 1] = string.format("\\u%04x", byte)
        else
            out[#out + 1] = char
        end
    end
    return '"' .. table.concat(out) .. '"'
end

-- Write to a temporary sibling first, then rename, so the runner can never read
-- a half-written report. Windows os.rename refuses an existing destination, so
-- the previous report (if any) is removed first; a direct write is the last
-- resort so the runner still gets a report when rename is unavailable.
function M.write(report_path, checks, extra)
    if type(report_path) ~= "string" or report_path == "" then
        return false, "no report path"
    end

    local parts = {}
    if type(extra) == "table" then
        local keys = {}
        for key in pairs(extra) do
            if key ~= "checks" and key ~= "ok" then
                keys[#keys + 1] = key
            end
        end
        table.sort(keys, function(a, b)
            return tostring(a) < tostring(b)
        end)
        for _, key in ipairs(keys) do
            local value = extra[key]
            local encoded
            if type(value) == "number" or type(value) == "boolean" then
                encoded = tostring(value)
            else
                encoded = quote(value)
            end
            parts[#parts + 1] = quote(key) .. ":" .. encoded
        end
    end

    local check_parts = {}
    for _, check in ipairs(checks) do
        check_parts[#check_parts + 1] = string.format(
            '{"name":%s,"ok":%s,"detail":%s}',
            quote(check.name),
            tostring(check.ok == true),
            quote(check.detail)
        )
    end
    parts[#parts + 1] = '"ok":' .. tostring(M.passed(checks))
    parts[#parts + 1] = '"checks":[' .. table.concat(check_parts, ",") .. "]"
    local body = "{" .. table.concat(parts, ",") .. "}"

    local tmp = report_path .. ".tmp"
    local handle, err = io.open(tmp, "w")
    if not handle then
        return false, "could not open " .. tmp .. ": " .. tostring(err)
    end
    local wrote = pcall(function()
        handle:write(body)
        handle:flush()
        handle:close()
    end)
    if not wrote then
        pcall(function()
            handle:close()
        end)
        return false, "could not write " .. tmp
    end

    os.remove(report_path)
    local renamed, rename_err = os.rename(tmp, report_path)
    if not renamed then
        local direct = io.open(report_path, "w")
        if not direct then
            return false,
                "could not rename or write " .. report_path .. ": " .. tostring(rename_err)
        end
        direct:write(body)
        direct:flush()
        direct:close()
    end
    return true
end

return M
