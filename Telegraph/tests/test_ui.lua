--[[
    Tests for Telegraph ui.lua: the Ashita v4 binding contract
    (require'd imgui, unconditional End, TextUnformatted-only - the
    Whetstone v0.1.1/v0.1.6/v0.1.7 field lessons enforced by stub AND
    source grep) plus the pure bar/TP line builders.

    Runs under busted or plain Lua 5.1+:
        lua5.1 Telegraph/tests/test_ui.lua
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

        is_false = function(value, msg)
            if value ~= false then
                error((msg or 'assert.is_false') .. ': got ' .. tostring(value), 2)
            end
        end,

        is_nil = function(value, msg)
            if value ~= nil then
                error((msg or 'assert.is_nil') .. ': got ' .. tostring(value), 2)
            end
        end,
    },
    {
        __call = function(_, ...)
            return original_assert(...)
        end,
    })

    TELEGRAPH_TEST_SUMMARY = function()
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
    'Telegraph/?.lua',
    'shared/?.lua',
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

ImGuiCond_Always = 1
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
        if call.name == 'TextUnformatted' then
            out[#out + 1] = call.args[1]
        end
    end

    return table.concat(out, '\n')
end

local REPORT =
{
    bars =
    {
        { kind = 'cast', actor_name = 'Goblin Smithy', label = 'Stone',
          remaining_s = 1.2, duration_s = 1.5, fraction = 0.8,
          overrun = false },
        { kind = 'ready', actor_name = 'Wild Rabbit',
          label = 'Wild Carrot', remaining_s = 2.1, duration_s = 3.0,
          fraction = 0.7, overrun = false },
    },
    tp =
    {
        { name = 'Goblin Smithy', percent = 74, lo_percent = 40,
          hi_percent = 110, marker = '~', pending = false,
          confidence = 'calibrated' },
    },
}

-- =====================================================================
describe('ui binding contract', function()
    it("uses require('imgui'), not a global", function()
        reset(true)
        ui.draw(REPORT, { state = 'ok' })

        assert.is_true(#calls > 0)
    end)

    it('calls End exactly once when Begin returns true', function()
        reset(true)
        ui.draw(REPORT, { state = 'ok' })

        assert.are.equal(1, count('Begin'))
        assert.are.equal(1, count('End'))
    end)

    it('calls End exactly once when Begin returns FALSE (collapsed)',
    function()
        reset(false)
        ui.draw(REPORT, { state = 'ok' })

        assert.are.equal(1, count('Begin'))
        assert.are.equal(1, count('End'))
        assert.are.equal(0, count('TextUnformatted'))
    end)

    it('renders nothing while hidden and zeroes the line counter',
    function()
        reset(true)
        ui.visible[1] = false
        ui.draw(REPORT, { state = 'ok' })

        assert.are.equal(0, #calls)
        assert.are.equal(0, ui.lines_rendered)
    end)

    it('counts rendered lines (the all-green-empty-panel tripwire)',
    function()
        reset(true)
        ui.draw(REPORT, { state = 'ok' })

        -- 2 bars + 1 tp line
        assert.are.equal(3, ui.lines_rendered)
    end)

    it('percent payloads survive the render byte-identical', function()
        -- the %% discipline: a literal % in panel text must never hit
        -- a printf path
        reset(true)
        ui.draw(REPORT, { state = 'ok' })

        -- plain find: the rendered text carries a literal single '%'
        assert.is_true(texts():find('~74%', 1, true) ~= nil)
        assert.is_true(texts():find('[40-110%]', 1, true) ~= nil)
    end)

    it('version travels in the window title', function()
        reset(true)
        ui.version = '9.9.9-test'
        ui.draw(REPORT, { state = 'ok' })

        local title = nil

        for _, call in ipairs(calls) do
            if call.name == 'Begin' then
                title = call.args[1]
            end
        end

        assert.is_true(title:find('9.9.9-test', 1, true) ~= nil)
        assert.is_true(title:find('###Telegraph', 1, true) ~= nil)
    end)

    it('renders distinct waiting/idle/latched states', function()
        reset(true)
        ui.draw(nil, { state = 'waiting_data' })
        assert.is_true(texts():find('[T1]', 1, true) ~= nil)

        reset(true)
        ui.draw({ bars = {}, tp = {} }, { state = 'ok' })
        assert.is_true(texts():find('[T2]', 1, true) ~= nil)

        reset(true)
        ui.draw(nil, { state = 'ok', latched_error = 'action_packet' })
        assert.is_true(texts():find('ERROR (latched): action_packet',
            1, true) ~= nil)
    end)

    it('a missing status names itself instead of impersonating idle',
    function()
        reset(true)
        ui.draw(nil, nil)

        assert.is_true(texts():find('[T?]', 1, true) ~= nil)
    end)

    it('TextUnformatted is the only imgui text call in ui.lua '
        .. '(source grep)', function()
        local source_path

        for _, candidate in ipairs({ here .. '../ui.lua',
                                     'Telegraph/ui.lua', 'ui.lua' }) do
            local handle = io.open(candidate, 'r')

            if handle then
                source_path = candidate
                handle:close()
                break
            end
        end

        assert.is_true(source_path ~= nil, 'ui.lua not found')

        local offenders = {}
        local line_number = 0

        for line in io.lines(source_path) do
            line_number = line_number + 1

            -- comments may NAME the forbidden calls (war stories);
            -- only code is held to the contract
            local code = line:gsub('%-%-.*', '')

            for name in code:gmatch('imgui%.(Text%a*)%s*%(') do
                if name ~= 'TextUnformatted' then
                    offenders[#offenders + 1] =
                        line_number .. ': ' .. line
                end
            end
        end

        assert.are.equal(0, #offenders,
            'format-interpreting text calls:\n'
            .. table.concat(offenders, '\n'))
    end)
end)

-- =====================================================================
describe('pure line builders', function()
    it('bar_text maps fractions to fills', function()
        assert.are.equal('[##########]', ui.bar_text(1.0, 10))
        assert.are.equal('[#####.....]', ui.bar_text(0.5, 10))
        assert.are.equal('[..........]', ui.bar_text(0.0, 10))
        -- clamped
        assert.are.equal('[##########]', ui.bar_text(1.7, 10))
        assert.are.equal('[..........]', ui.bar_text(-0.2, 10))
    end)

    it('bar_text renders unknown durations as ?', function()
        assert.are.equal('[??????????]', ui.bar_text(nil, 10))
    end)

    it('cast lines carry actor, label, bar and time', function()
        local line = ui.bar_line(
        {
            kind = 'cast', actor_name = 'Goblin Smithy',
            label = 'Stone', remaining_s = 1.34, fraction = 0.5,
        })

        assert.is_true(line:find('Goblin Smithy: casting Stone',
            1, true) ~= nil)
        assert.is_true(line:find('1.3s', 1, true) ~= nil)
    end)

    it('ready lines use the READYING: format', function()
        local line = ui.bar_line(
        {
            kind = 'ready', actor_name = 'Wild Rabbit',
            label = 'Wild Carrot', remaining_s = 2.0, fraction = 0.66,
        })

        assert.is_true(line:find('Wild Rabbit READYING: Wild Carrot',
            1, true) ~= nil)
    end)

    it('overrun bars show ... instead of a negative time', function()
        local line = ui.bar_line(
        {
            kind = 'cast', actor_name = 'X', label = 'Y',
            remaining_s = 0, fraction = 0, overrun = true,
        })

        assert.is_true(line:find('...', 1, true) ~= nil)
        assert.is_nil(line:find('-', 1, true))
    end)

    it('tp lines flag the estimate and show the band', function()
        local line = ui.tp_line(
        {
            name = 'Goblin Smithy', percent = 74, lo_percent = 40,
            hi_percent = 110, marker = '~',
        })

        assert.are.equal('Goblin Smithy TP ~74% [40-110%]', line)
    end)

    it('tp lines collapse the band when degenerate and mark pending',
    function()
        local line = ui.tp_line(
        {
            name = 'Wild Rabbit', percent = 0, lo_percent = 0,
            hi_percent = 0, marker = '~', pending = true,
        })

        assert.are.equal('Wild Rabbit TP ~0% (readying!)', line)
    end)

    it('tp lines never render unflagged (marker always present)',
    function()
        -- a nil marker falls back to the cold ~~, never to nothing
        local line = ui.tp_line({ name = 'X', percent = 50 })

        assert.is_true(line:find('~~50%%') ~= nil)
    end)
end)

if TELEGRAPH_TEST_SUMMARY then
    TELEGRAPH_TEST_SUMMARY()
end
