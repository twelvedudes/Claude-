--[[
    Tests for selftest.lua (pure check runner).

    Runs under busted or plain Lua 5.1+:
        lua5.1 Whetstone/tests/test_selftest.lua
]]

if type(describe) ~= 'function' then
    local stack  = {}
    local tests  = 0
    local failed = 0

    function describe(name, fn)
        table.insert(stack, name)
        fn()
        table.remove(stack)
    end

    function it(name, fn)
        tests = tests + 1

        local ok, err = pcall(fn)

        if ok then
            print('ok   ' .. table.concat(stack, ' > ') .. ' > ' .. name)
        else
            failed = failed + 1
            print('FAIL ' .. table.concat(stack, ' > ') .. ' > ' .. name)
            print('     ' .. tostring(err))
        end
    end

    local original_assert = assert

    assert = setmetatable(
    {
        are =
        {
            equal = function(expected, actual, msg)
                if expected ~= actual then
                    error((msg or 'assert.are.equal') ..
                        ': expected ' .. tostring(expected) ..
                        ', got ' .. tostring(actual), 2)
                end
            end,
        },

        is_true = function(value, msg)
            if value ~= true then
                error((msg or 'assert.is_true') .. ': got ' .. tostring(value), 2)
            end
        end,
    },
    {
        __call = function(_, ...)
            return original_assert(...)
        end,
    })

    WHETSTONE_TEST_SUMMARY = function()
        print(string.format('%d tests, %d failures', tests, failed))

        if failed > 0 then
            os.exit(1)
        end
    end
end

local here = (arg and arg[0] and arg[0]:match('(.*[/\\])')) or ''
package.path = table.concat(
{
    here .. '../?.lua',
    here .. '../../shared/?.lua',
    'Whetstone/?.lua',
    'shared/?.lua',
    '?.lua',
    package.path,
}, ';')

local S = require('selftest')

describe('selftest runner', function()
    it('reports ok and failed checks with details', function()
        local report = S.run(
        {
            { name = 'data_tables', fn = function()
                return '3 tables loaded'
            end },
            { name = 'inventory_api', fn = function()
                error('GetEquippedItem returned userdata surprise')
            end },
            { name = 'expect_helper', fn = function()
                S.expect(1 + 1 == 2, 'math broke')
                return 'fine'
            end },
        })

        assert.are.equal(2, report.ok)
        assert.are.equal(1, report.failed)
        assert.are.equal(5, #report.lines) -- header + 3 checks + footer

        local text = table.concat(report.lines, '\n')

        assert.is_true(text:find('OK   data_tables') ~= nil)
        assert.is_true(text:find('3 tables loaded') ~= nil)
        assert.is_true(text:find('FAIL inventory_api') ~= nil)
        assert.is_true(text:find('userdata surprise') ~= nil)
        assert.is_true(text:find('2 ok, 1 failed') ~= nil)
    end)

    it('expect raises with the given message', function()
        local ok, err = pcall(S.expect, false, 'slot 3 came back nil')

        assert.is_true(not ok)
        assert.is_true(tostring(err):find('slot 3 came back nil') ~= nil)
    end)
end)

if WHETSTONE_TEST_SUMMARY then
    WHETSTONE_TEST_SUMMARY()
end
