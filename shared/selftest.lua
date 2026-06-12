--[[
    shared/selftest.lua

    Pure check runner for `/whet selftest` and `/tele selftest`:
    executes a list of named checks (each a function returning a
    detail string, or raising) and formats a diagnostic report. The
    point: in-game shakedown failures arrive as a readable file naming
    the exact glue call that misbehaved, instead of mystery silence.

    Shared between the Whetstone and Telegraph addons under the ONE
    require name 'selftest' (the module-identity discipline; see
    shared/actionpacket.lua). Each addon's glue supplies its own
    Ashita-touching check closures; this module never imports anything
    and is unit-tested offline.
]]

local M = {}

-- checks: array of { name = string, fn = function() -> detail }
-- Returns { lines = {...}, ok = n, failed = n }
function M.run(checks)
    local report =
    {
        lines  = {},
        ok     = 0,
        failed = 0,
    }

    local function add(line)
        report.lines[#report.lines + 1] = line
    end

    add(string.format('=== whetstone selftest %s ===',
        os.date('%Y-%m-%d %H:%M:%S')))

    for _, check in ipairs(checks) do
        local ok, detail = pcall(check.fn)

        if ok then
            report.ok = report.ok + 1
            add(string.format('OK   %-28s %s', check.name,
                tostring(detail or '')))
        else
            report.failed = report.failed + 1
            add(string.format('FAIL %-28s %s', check.name,
                tostring(detail)))
        end
    end

    add(string.format('=== %d ok, %d failed ===', report.ok,
        report.failed))

    return report
end

-- Convenience assertion for check bodies: fail with a clear message
-- instead of "attempt to index a nil value" noise.
function M.expect(condition, message)
    if not condition then
        error(message, 2)
    end

    return true
end

return M
