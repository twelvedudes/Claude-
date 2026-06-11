--[[
    Tests for ui.lua against a recording stub of the Ashita v4 ImGui
    binding. Locks in the binding rules that caused the first in-game
    crash (HorizonXI, v0.1.0-beta):
      - ui.lua must require('imgui'), never touch a global
      - imgui.End() runs exactly once per draw, whatever Begin returned
      - nothing renders when the window is hidden

    Runs under busted or plain Lua 5.1+:
        lua5.1 Whetstone/tests/test_ui.lua
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
    'Whetstone/?.lua',
    '?.lua',
    package.path,
}, ';')

-- ---------------------------------------------------------------------
-- Recording stub of the Ashita v4 binding, preloaded BEFORE ui.lua is
-- required: if ui.lua reaches for a global imgui instead, it crashes
-- exactly like it did in game.
-- ---------------------------------------------------------------------

local calls = {}
local begin_result = true

local stub = {}

setmetatable(stub, {
    __index = function(_, name)
        local fn = function(...)
            calls[#calls + 1] = { name = name, args = { ... } }
        end
        rawset(stub, name, fn)
        return fn
    end,
})

stub.Begin = function(...)
    calls[#calls + 1] = { name = 'Begin', args = { ... } }
    return begin_result
end

package.preload['imgui'] = function()
    return stub
end

-- Flag/cond enums are globals in Ashita v4 (verified vs imguidef)
ImGuiCond_FirstUseEver = 4
ImGuiWindowFlags_NoScrollbar = 8

local ui = require('ui')

local function reset(begin_value)
    calls = {}
    begin_result = begin_value
    ui.visible[1] = true
end

local function count(name)
    local total = 0

    for _, call in ipairs(calls) do
        if call.name == name then
            total = total + 1
        end
    end

    return total
end

local function texts()
    local out = {}

    for _, call in ipairs(calls) do
        if call.name == 'TextColored' then
            out[#out + 1] = call.args[2]
        end
    end

    return table.concat(out, '\n')
end

local REPORT =
{
    target =
    {
        name = 'Test Crab', level_min = 20, level_max = 25,
        ambiguous = true,
    },
    lines =
    {
        { kind = 'acc', text = '+90 acc to cap', delta = 0.9,
          estimated = true },
        { kind = 'fstr', text = '+1 STR -> fSTR 13.75', delta = 0.004,
          estimated = false },
    },
    ws = {},
}

-- =====================================================================
describe('ui binding contract', function()
    it('uses require(\'imgui\'), not a global', function()
        reset(true)
        ui.draw(REPORT, nil)

        assert.is_true(#calls > 0) -- the preloaded stub received calls
    end)

    it('calls End exactly once when Begin returns true', function()
        reset(true)
        ui.draw(REPORT, nil)

        assert.are.equal(1, count('Begin'))
        assert.are.equal(1, count('End'))
    end)

    it('calls End exactly once when Begin returns FALSE (collapsed)', function()
        reset(false)
        ui.draw(REPORT, nil)

        assert.are.equal(1, count('Begin'))
        assert.are.equal(1, count('End'))
        -- and no body rendering happened
        assert.are.equal(0, count('TextColored'))
    end)

    it('renders nothing at all when hidden', function()
        reset(true)
        ui.visible[1] = false
        ui.draw(REPORT, nil)

        assert.are.equal(0, #calls)
    end)
end)

describe('ui rendering', function()
    it('shows the unconfirmed level range and estimate markers', function()
        reset(true)
        ui.draw(REPORT, nil)

        local text = texts()

        assert.is_true(text:find('Test Crab %(Lv%.20%-25, unconfirmed%)') ~= nil)
        assert.is_true(text:find('~ %+90 acc to cap') ~= nil)
        assert.is_true(text:find('  %+1 STR') ~= nil)
    end)

    it('shows the haste footer with the gear-exact split', function()
        reset(true)
        ui.draw(REPORT,
            { total = 0.31, gear = 0.07, magic_estimated = true })

        assert.is_true(texts():find('Haste 31.0%% ~est %(gear 7.00%% exact%)') ~= nil)
    end)

    it('handles a nil report without erroring', function()
        reset(true)
        ui.draw(nil, nil)

        assert.is_true(texts():find('No target.') ~= nil)
        assert.are.equal(1, count('End'))
    end)
end)

if WHETSTONE_TEST_SUMMARY then
    WHETSTONE_TEST_SUMMARY()
end
