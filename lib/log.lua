-- Structured lines with a size cap.
--
-- One line per event, fields sorted, values containing a space or an equals
-- sign double quoted:
--
--   ts=<RFC3339 UTC> level=<level> event=<dotted.name> k=v ...
--
-- Events must live in the restore, save, selfcheck or history namespace; an
-- event outside them is dropped rather than written. The default file is
-- <state dir>\session.log, rotated at 262144 bytes to session.log.1 with a
-- single backup. init(path) must run once before any event is written; a
-- process that never calls it never touches the disk.
local M = {}

local MAX_BYTES = 262144
local NAMESPACES = { restore = true, save = true, selfcheck = true, history = true }

local current_path

local function ensure_dir(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    local ok = pcall(os.execute, 'mkdir "' .. path:gsub("/", "\\") .. '" 2>nul')
    return ok
end

local function dirname(path)
    return tostring(path):match("^(.*)[\\/][^\\/]*$")
end

local function valid_event(event)
    if type(event) ~= "string" then
        return false
    end
    local namespace, rest = event:match("^([%a_][%w_]*)%.([%w_][%w_%.]*)$")
    if namespace == nil or rest == nil or rest == "" then
        return false
    end
    return NAMESPACES[namespace] == true
end

-- Keep the line on one line: a title or cwd can contain a newline. Backslashes
-- are left alone so Windows paths stay readable.
local function quote(value)
    local text = tostring(value)
    text = text:gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "\\t")
    text = text:gsub("%c", function(char)
        return string.format("\\x%02x", string.byte(char))
    end)
    if text:find("[ =]") then
        text = text:gsub('"', '\\"')
        return '"' .. text .. '"'
    end
    return text
end

local function fields_to_text(fields)
    if type(fields) ~= "table" then
        return {}
    end
    local keys = {}
    for key in pairs(fields) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)
    local parts = {}
    for _, key in ipairs(keys) do
        local value = fields[key]
        if value ~= nil then
            local name = tostring(key):gsub("[%s=]", "_")
            parts[#parts + 1] = name .. "=" .. quote(value)
        end
    end
    return parts
end

local function append(path, line)
    local handle = io.open(path, "a")
    if not handle then
        ensure_dir(dirname(path))
        handle = io.open(path, "a")
    end
    if not handle then
        return false
    end

    local size = handle:seek("end")
    if type(size) == "number" and size >= MAX_BYTES then
        handle:close()
        os.remove(path .. ".1")
        os.rename(path, path .. ".1")
        handle = io.open(path, "a")
        if not handle then
            return false
        end
    end

    local ok = pcall(function()
        handle:write(line)
        handle:flush()
        handle:close()
    end)
    if not ok then
        pcall(function()
            handle:close()
        end)
    end
    return ok
end

local function emit(level, event, fields)
    if current_path == nil or not valid_event(event) then
        return false
    end
    local parts = {
        "ts=" .. os.date("!%Y-%m-%dT%H:%M:%SZ"),
        "level=" .. level,
        "event=" .. event,
    }
    for _, part in ipairs(fields_to_text(fields)) do
        parts[#parts + 1] = part
    end
    return append(current_path, table.concat(parts, " ") .. "\n")
end

function M.init(path)
    if path == nil or path == "" then
        local ok, state = pcall(require, "lib.state")
        if not ok or type(state) ~= "table" then
            return false
        end
        path = state.state_dir() .. "\\session.log"
    end
    current_path = tostring(path)
    return true
end

function M.debug(event, fields)
    return emit("debug", event, fields)
end

function M.info(event, fields)
    return emit("info", event, fields)
end

function M.warn(event, fields)
    return emit("warn", event, fields)
end

function M.error(event, fields)
    return emit("error", event, fields)
end

return M
