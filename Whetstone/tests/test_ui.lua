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
        if call.name == 'TextColored' then
            -- printf discipline: args = { color, '%s', payload }
            out[#out + 1] = call.args[3]
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

        assert.is_true(text:find('%[S4%] Test Crab %(Lv%.20%-25, unconfirmed%)') ~= nil)
        assert.is_true(text:find('~ %+90 acc to cap') ~= nil)
        assert.is_true(text:find('  %+1 STR') ~= nil)
    end)

    it('shows the haste footer with the gear-exact split', function()
        reset(true)
        ui.draw(REPORT,
            { total = 0.31, gear = 0.07, magic_estimated = true })

        assert.is_true(texts():find('Haste 31.0%% ~est %(gear 7.00%% exact%)') ~= nil)
    end)

    it('flags a missing status as a transport bug, never no-target', function()
        -- The v0.1.2 field bug: guarded() dropped the status argument
        -- (nil-hole unpack), and the panel impersonated the no-target
        -- state. Now zero-status draws render the [S?] sentinel.
        reset(true)
        ui.draw(nil, nil)

        assert.is_true(texts():find('%[S%?%] no status reached the panel')
            ~= nil)
        assert.are.equal(1, count('End'))
    end)

    it('shows the version in the title with a stable window id', function()
        reset(true)
        ui.version = '9.9.9-test'
        ui.draw(nil, nil, { state = 'no_target' })

        local title
        for _, call in ipairs(calls) do
            if call.name == 'Begin' then
                title = call.args[1]
            end
        end

        assert.are.equal('Whetstone 9.9.9-test###Whetstone', title)
        ui.version = nil
    end)

    it('lists out-of-model WS tagged, never with a damage number', function()
        reset(true)
        ui.draw(
        {
            target = { name = 'Test Crab' },
            lines = {},
            ws = {},
            ws_excluded =
            {
                { name = 'red_lotus_blade', reason = 'magic' },
                { name = 'tachi_jinpu', reason = 'hybrid' },
            },
        }, nil, { state = 'ok' })

        local text = texts()

        assert.is_true(text:find(
            'red_lotus_blade %(magic %- out of model%)') ~= nil)
        assert.is_true(text:find(
            'tachi_jinpu %(hybrid %- out of model%)') ~= nil)
    end)
end)

-- =====================================================================
describe('panel position persistence', function()
    it('samples the window position when the binding reports one', function()
        stub.GetWindowPos = function()
            calls[#calls + 1] = { name = 'GetWindowPos', args = {} }
            return 120, 340
        end

        reset(true)
        ui.draw(nil, nil, { state = 'no_target' })

        assert.are.equal(120, ui.window_pos.x)
        assert.are.equal(340, ui.window_pos.y)

        rawset(stub, 'GetWindowPos', nil) -- restore auto-stub
    end)

    it('applies a restored position exactly once', function()
        reset(true)
        ui.restore_window_pos({ x = 200, y = 80 })
        ui.draw(nil, nil, { state = 'no_target' })

        assert.are.equal(1, count('SetNextWindowPos'))

        for _, call in ipairs(calls) do
            if call.name == 'SetNextWindowPos' then
                assert.are.equal(200, call.args[1][1])
                assert.are.equal(80, call.args[1][2])
            end
        end

        -- consumed: the next frame must not re-pin the window
        reset(true)
        ui.draw(nil, nil, { state = 'no_target' })

        assert.are.equal(0, count('SetNextWindowPos'))
    end)

    it('ignores the unset sentinel position', function()
        reset(true)
        ui.restore_window_pos({ x = -1, y = -1 })
        ui.draw(nil, nil, { state = 'no_target' })

        assert.are.equal(0, count('SetNextWindowPos'))
    end)
end)

-- =====================================================================
describe('printf-format injection (the v0.1.4 field bug)', function()
    it('renders % sequences verbatim, never as conversions', function()
        -- live evidence: '% p' printed pointer hex, '% e' printed
        -- 3.787520e-244. Every dynamic string must ride the '%s' slot.
        reset(true)
        ui.draw(
        {
            target = { name = 'Crab % p % e 100%' },
            lines =
            {
                { kind = 'acc',
                  text = '+90 acc to cap (75% -> 95%, +26.7% melee)',
                  delta = 0.27, estimated = false },
            },
            ws = {},
        }, { total = 0.31, gear = 0.07, magic_estimated = false },
        { state = 'ok' })

        local text = texts()

        assert.is_true(text:find('Crab %% p %% e 100%%', 1, false) ~= nil
            or text:find('Crab % p % e 100%', 1, true) ~= nil)
        assert.is_true(text:find('(75% -> 95%, +26.7% melee)', 1, true)
            ~= nil)
    end)

    it('every TextColored call uses the %s slot (runtime)', function()
        reset(true)
        ui.draw(REPORT, { total = 0.31, gear = 0.07 },
                { state = 'ok', latched_error = 'x' })

        for _, call in ipairs(calls) do
            if call.name == 'TextColored' then
                assert.are.equal('%s', call.args[2],
                    'TextColored without %s slot')
            end
        end
    end)

    it('no imgui text call in ui.lua passes a non-literal format (source grep)', function()
        local source_path

        for _, candidate in ipairs({ here .. '../ui.lua',
                                     'Whetstone/ui.lua', 'ui.lua' }) do
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

            -- any direct imgui.Text/TextColored/TextUnformatted call
            -- must carry the literal '%s' format slot on that line
            if (line:find('imgui%.TextColored%s*%(')
                or line:find('imgui%.Text%s*%('))
                and not line:find("'%%s'") then
                offenders[#offenders + 1] = line_number .. ': ' .. line
            end
        end

        assert.are.equal(0, #offenders,
            'printf-unsafe text calls:\n'
            .. table.concat(offenders, '\n'))
    end)
end)

-- =====================================================================
describe('ui status states (never one catch-all)', function()
    it('distinguishes waiting-for-packets from no-target', function()
        reset(true)
        ui.draw(nil, nil, { state = 'waiting_packets' })

        assert.is_true(texts():find('%[S1%] Waiting for char data') ~= nil)
    end)

    it('names the zone when mob data is missing', function()
        reset(true)
        ui.draw(nil, nil, { state = 'no_zone_data', detail = 142 })

        assert.is_true(texts():find('%[S2z%] No mob data for zone 142.') ~= nil)
    end)

    it('names the item id when the mainhand misses the item DB', function()
        reset(true)
        ui.draw(nil, nil, { state = 'no_weapon', detail = 17440 })

        assert.is_true(
            texts():find('%[S2w%] Mainhand not in item DB %(id 17440%).') ~= nil)
    end)

    it('shows the target name when the mob is not in the DB', function()
        reset(true)
        ui.draw(
        {
            target = { name = 'Custom Horizon Mob' },
            lines = {}, ws = {},
            error = 'unknown mob',
        }, nil, { state = 'ok' })

        assert.is_true(texts():find(
            '%[S3%] Target: Custom Horizon Mob %(not in mob DB for this zone%)')
            ~= nil)
    end)

    it('renders the latched error line above everything', function()
        reset(true)
        ui.draw(nil, nil, { state = 'no_target',
                            latched_error = 'advisor_update' })

        local text = texts()

        assert.is_true(text:find(
            'ERROR %(latched%): advisor_update %- see '
            .. 'whetstone_error.log') ~= nil)
        -- the state line still renders after it
        assert.is_true(text:find('%[S2%] No target.') ~= nil)
        assert.are.equal(1, count('End'))
    end)
end)

-- =====================================================================
describe('nil-hole argument transport (the v0.1.2 field bug)', function()
    -- Replicates whetstone.lua's guarded() argument forwarding. The
    -- broken form { ... } + unpack(args) loses trailing args after
    -- nil holes on LuaJIT; the fixed form preserves them.
    local function forward_fixed(fn, ...)
        local count = select('#', ...)
        local args = { ... }
        return fn(unpack(args, 1, count))
    end

    it('delivers status through nil report/haste holes', function()
        reset(true)
        forward_fixed(ui.draw, nil, nil, { state = 'no_target' })

        assert.is_true(texts():find('%[S2%] No target.') ~= nil)
    end)

    it('select count sees through the holes', function()
        local seen
        forward_fixed(function(...) seen = select('#', ...) end,
            nil, nil, {})

        assert.are.equal(3, seen)
    end)
end)

if WHETSTONE_TEST_SUMMARY then
    WHETSTONE_TEST_SUMMARY()
end
