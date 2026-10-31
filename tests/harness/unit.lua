-- Headless unit harness.
--
-- This file is itself the WezTerm config passed to:
--
--   wezterm.exe --config-file tests\harness\unit.lua show-keys --lua
--
-- show-keys needs no window and exits 0 even when this config fails, so the
-- JSON report at tests\.report.json is the only pass signal. This file
-- discovers tests\unit\*_spec.lua, runs every spec, writes the report, and
-- returns a minimal config so the show-keys invocation itself succeeds.
--
-- It deliberately requires no lib module, so it works before the library
-- exists.
local wezterm = require("wezterm")

local function normalize(path)
    return (tostring(path):gsub("\\", "/"))
end

local function dirname(path)
    path = normalize(path):gsub("/+$", "")
    return path:match("^(.*)/[^/]+$") or path
end

local harness_dir = normalize(wezterm.config_dir or "")
local tests_dir = dirname(harness_dir)
local repo_root = dirname(tests_dir)
local report_path = tests_dir .. "/.report.json"
local unit_glob = tests_dir .. "/unit/*_spec.lua"
local selftest_path = harness_dir .. "/selftest_spec.lua"

-- --config-file does not add the config's directory to package.path, and the
-- sandbox has no debug library. wezterm.config_dir follows the loaded config
-- path, so derive the repository root from it.
package.path = repo_root .. "/?.lua;" .. repo_root .. "/?/init.lua;" .. package.path

local passed = 0
local failures = {}

local function add_failure(spec, test, message)
    failures[#failures + 1] = {
        spec = tostring(spec),
        test = tostring(test),
        message = tostring(message),
    }
end

local function relative(path)
    path = normalize(path)
    local prefix = repo_root .. "/"
    if path:sub(1, #prefix) == prefix then
        return path:sub(#prefix + 1)
    end
    return path
end

local function repr(value, depth, seen)
    depth = depth or 0
    if type(value) == "string" then
        return string.format("%q", value)
    end
    if type(value) ~= "table" then
        return tostring(value)
    end
    seen = seen or {}
    if seen[value] then
        return "<cycle>"
    end
    if depth >= 4 then
        return "{...}"
    end
    seen[value] = true
    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)
    local parts = {}
    for _, key in ipairs(keys) do
        local name
        if type(key) == "string" and key:match("^[%a_][%w_]*$") then
            name = key
        else
            name = "[" .. repr(key, depth + 1, seen) .. "]"
        end
        parts[#parts + 1] = name .. "=" .. repr(value[key], depth + 1, seen)
    end
    seen[value] = nil
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function deep_equal(a, b, seen)
    if a == b then
        return true
    end
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    seen = seen or {}
    seen[a] = seen[a] or {}
    if seen[a][b] then
        return true
    end
    seen[a][b] = true
    for key, value in pairs(a) do
        if not deep_equal(value, b[key], seen) then
            return false
        end
    end
    for key, value in pairs(b) do
        if not deep_equal(a[key], value, seen) then
            return false
        end
    end
    return true
end

local function assertion_error(message)
    error({ unit_failure = true, message = tostring(message) }, 0)
end

local function make_t()
    local t = {}
    function t.eq(actual, expected, msg)
        if not deep_equal(actual, expected) then
            local detail = "expected " .. repr(expected) .. ", got " .. repr(actual)
            if msg ~= nil and msg ~= "" then
                detail = tostring(msg) .. ": " .. detail
            end
            assertion_error(detail)
        end
    end
    function t.ok(cond, msg)
        if not cond then
            assertion_error(msg or ("expected a truthy value, got " .. repr(cond)))
        end
    end
    function t.fail(msg)
        assertion_error(msg or "explicit failure")
    end
    return t
end

local function json_escape(value)
    local text = tostring(value)
    local out = {}
    for i = 1, #text do
        local byte = text:byte(i)
        local char = text:sub(i, i)
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
        elseif char == "\b" then
            out[#out + 1] = "\\b"
        elseif char == "\f" then
            out[#out + 1] = "\\f"
        elseif byte < 32 then
            out[#out + 1] = string.format("\\u%04x", byte)
        else
            out[#out + 1] = char
        end
    end
    return '"' .. table.concat(out) .. '"'
end

local function write_report()
    local lines = {
        "{",
        '  "ok": ' .. tostring(#failures == 0) .. ",",
        '  "passed": ' .. tostring(passed) .. ",",
        '  "failed": ' .. tostring(#failures) .. ",",
        '  "failures": [',
    }
    for index, failure in ipairs(failures) do
        lines[#lines + 1] = "    {"
        lines[#lines + 1] = '      "spec": ' .. json_escape(failure.spec) .. ","
        lines[#lines + 1] = '      "test": ' .. json_escape(failure.test) .. ","
        lines[#lines + 1] = '      "message": ' .. json_escape(failure.message)
        lines[#lines + 1] = "    }" .. (index < #failures and "," or "")
    end
    lines[#lines + 1] = "  ]"
    lines[#lines + 1] = "}"

    local handle, err = io.open(report_path, "w")
    if not handle then
        error("could not open " .. report_path .. ": " .. tostring(err), 0)
    end
    handle:write(table.concat(lines, "\n") .. "\n")
    handle:close()
end

local function run_test(spec_name, test_name, fn)
    local t = make_t()
    local ok, err = pcall(fn, t)
    if ok then
        passed = passed + 1
        return
    end
    local message
    if type(err) == "table" and err.unit_failure then
        message = tostring(err.message)
    else
        message = "unexpected error: " .. tostring(err)
    end
    add_failure(spec_name, test_name, message)
end

local function run_spec_file(path)
    local spec_name = relative(path)
    local ok, result = pcall(dofile, path)
    if not ok then
        add_failure(spec_name, "<load>", "spec failed to load: " .. tostring(result))
        return
    end
    if type(result) ~= "table" then
        add_failure(spec_name, "<load>", "spec must return an array of tests, got " .. type(result))
        return
    end
    for index, test in ipairs(result) do
        if type(test) ~= "table" then
            add_failure(spec_name, "test #" .. tostring(index), "test entry must be a table, got " .. type(test))
        else
            local name = test.name
            if type(name) ~= "string" or name == "" then
                name = "test #" .. tostring(index)
            end
            if type(test.run) ~= "function" then
                add_failure(spec_name, name, "test has no run function")
            else
                run_test(spec_name, name, test.run)
            end
        end
    end
end

local function discover_unit_specs()
    local ok, paths = pcall(wezterm.glob, unit_glob)
    if not ok then
        add_failure("tests/unit", "<discovery>", "glob failed: " .. tostring(paths))
        return
    end
    if type(paths) ~= "table" then
        add_failure("tests/unit", "<discovery>", "glob returned " .. type(paths))
        return
    end
    table.sort(paths)
    for _, path in ipairs(paths) do
        run_spec_file(path)
    end
end

local ok, err = pcall(function()
    discover_unit_specs()
    run_spec_file(selftest_path)
end)
if not ok then
    add_failure("<harness>", "<internal>", "harness error: " .. tostring(err))
end

local written, write_err = pcall(write_report)
if not written then
    error("unit harness could not write its report: " .. tostring(write_err), 0)
end

return wezterm.config_builder()
