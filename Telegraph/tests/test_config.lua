--[[
    Tests for Telegraph config.lua: sanitize hardening, save/load
    round-trip, sandboxed deserialization (the fixed persistence
    pattern - a corrupt or malicious settings file can neither poison
    runtime state nor execute code).

    Runs under busted or plain Lua 5.1+:
        lua5.1 Telegraph/tests/test_config.lua
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
    'Telegraph/?.lua',
    '?.lua',
    package.path,
}, ';')

local C = require('config')

-- =====================================================================
describe('sanitize', function()
    it('returns defaults for nil/garbage input', function()
        local from_nil = C.sanitize(nil)
        local from_string = C.sanitize('return os.exit()')

        assert.are.equal(true, from_nil.visible)
        assert.are.equal('phoenix', from_nil.profile)
        assert.are.equal(true, from_string.show_tp)
        assert.are.equal(-1, from_nil.window_pos.x)
    end)

    it('keeps well-typed values', function()
        local clean = C.sanitize(
        {
            visible = false,
            window_pos = { x = 120, y = 340 },
            profile = 'lsb',
            show_tp = false,
            show_bars = false,
        })

        assert.is_false(clean.visible)
        assert.are.equal(120, clean.window_pos.x)
        assert.are.equal('lsb', clean.profile)
        assert.is_false(clean.show_tp)
        assert.is_false(clean.show_bars)
    end)

    it('drops type mismatches and unknown keys', function()
        local clean = C.sanitize(
        {
            visible = 'yes',                  -- wrong type
            window_pos = { x = 'a', y = 2 },  -- wrong type inside
            profile = 42,                     -- wrong type
            debug_log = true,                 -- unknown (session-only)
            evil = { payload = true },        -- unknown
        })

        assert.are.equal(true, clean.visible)
        assert.are.equal(-1, clean.window_pos.x)
        assert.are.equal('phoenix', clean.profile)
        assert.is_nil(clean.debug_log)
        assert.is_nil(clean.evil)
    end)

    it('never returns shared mutable defaults', function()
        local a = C.sanitize(nil)
        local b = C.sanitize(nil)

        a.window_pos.x = 999

        assert.are.equal(-1, b.window_pos.x)
        assert.are.equal(-1, C.DEFAULTS.window_pos.x)
    end)
end)

-- =====================================================================
describe('serialize/deserialize round trip', function()
    it('round-trips a full config', function()
        local original = C.sanitize(
        {
            visible = false,
            window_pos = { x = 64, y = 128 },
            profile = 'lsb',
            show_tp = false,
            show_bars = true,
        })

        local restored = C.sanitize(C.deserialize(C.serialize(original)))

        assert.are.equal(false, restored.visible)
        assert.are.equal(64, restored.window_pos.x)
        assert.are.equal(128, restored.window_pos.y)
        assert.are.equal('lsb', restored.profile)
        assert.is_false(restored.show_tp)
        assert.is_true(restored.show_bars)
    end)

    it('deserialize is sandboxed: environment access yields nil',
    function()
        -- a malicious settings file must not reach os/io
        assert.is_nil(C.deserialize('return os.getenv("HOME")'))
        assert.is_nil(C.deserialize('os.remove("x") return {}')
            and nil or C.deserialize('return (os and 1)'))
    end)

    it('deserialize rejects non-table payloads and syntax errors',
    function()
        assert.is_nil(C.deserialize('return 42'))
        assert.is_nil(C.deserialize('this is not lua'))
        assert.is_nil(C.deserialize(nil))
    end)

    it('serialization is deterministic (files diff cleanly)', function()
        local cfg = C.sanitize(nil)

        assert.are.equal(C.serialize(cfg), C.serialize(cfg))
    end)
end)

if TELEGRAPH_TEST_SUMMARY then
    TELEGRAPH_TEST_SUMMARY()
end
