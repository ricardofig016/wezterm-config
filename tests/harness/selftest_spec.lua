-- Self-test for the headless unit harness.
--
-- The first tests always run and prove that the assertion helpers fail the
-- way the runner expects. The last test is deliberately false and only
-- appears when WEZTERM_UNIT_SELFTEST=1, so a normal run stays green and the
-- gated run turns red.
local tests = {
    {
        name = "eq accepts deeply equal tables",
        run = function(t)
            t.eq(
                { version = 1, panes = { { id = 3, cols = { 10, 40 } } } },
                { version = 1, panes = { { id = 3, cols = { 10, 40 } } } },
                "deep equality should accept equal tables"
            )
        end,
    },
    {
        name = "eq raises on a mismatch",
        run = function(t)
            local ok, err = pcall(t.eq, 1, 2, "mismatch")
            t.ok(not ok, "eq must raise on a mismatch")
            t.ok(type(err) == "table", "eq must raise a failure object")
            t.ok(err.unit_failure == true, "eq must mark the failure object")
        end,
    },
    {
        name = "ok and fail raise",
        run = function(t)
            t.ok(not pcall(t.ok, false, "false must raise"), "ok(false) must raise")
            t.ok(not pcall(t.fail, "must raise"), "fail must raise")
        end,
    },
}

if os.getenv("WEZTERM_UNIT_SELFTEST") == "1" then
    tests[#tests + 1] = {
        name = "deliberately false assertion",
        run = function(t)
            t.eq(1, 2, "the gated self-test must turn the unit runner red")
        end,
    }
end

return tests
