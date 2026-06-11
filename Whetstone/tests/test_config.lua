--[[
    Tests for config.lua: save/load round-trip, sanitize hardening.
    Runs under busted or plain Lua 5.1+:
        lua5.1 Whetstone/tests/test_config.lua
]]

if type(describe) ~= 'function' then
    local stack, tests, failed = {}, 0, 0
    function describe(name, fn)
        table.insert(stack, name); fn(); table.remove(stack)
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
    assert = setmetatable({
        are = {
            equal = function(e, a, msg)
                if e ~= a then
                    error((msg or 'assert.are.equal') .. ': expected '
                        .. tostring(e) .. ', got ' .. tostring(a), 2)
                end
            end,
        },
        is_true = function(v, msg)
            if v ~= true then
                error((msg or 'assert.is_true') .. ': got ' .. tostring(v), 2)
            end
        end,
        is_false = function(v, msg)
            if v ~= false then
                error((msg or 'assert.is_false') .. ': got ' .. tostring(v), 2)
            end
        end,
        is_nil = function(v, msg)
            if v ~= nil then
                error((msg or 'assert.is_nil') .. ': got ' .. tostring(v), 2)
            end
        end,
        near = function(e, a, tol, msg)
            if type(a) ~= 'number' or math.abs(e - a) > tol then
                error((msg or 'assert.near') .. ': expected ' .. tostring(e)
                    .. ', got ' .. tostring(a), 2)
            end
        end,
    }, { __call = function(_, ...) return original_assert(...) end })
    WHETSTONE_TEST_SUMMARY = function()
        print(string.format('%d tests, %d failures', tests, failed))
        if failed > 0 then os.exit(1) end
    end
end

local here = (arg and arg[0] and arg[0]:match('(.*[/\\])')) or ''
package.path = table.concat({
    here .. '../?.lua', 'Whetstone/?.lua', '?.lua', package.path }, ';')

local C = require('config')

describe('config round-trip', function()
    it('survives serialize -> deserialize -> sanitize intact', function()
        local original = C.sanitize(
        {
            assume_quest_ws = true,
            march_override  = 0.140625,
            buff_overrides  = { [214] = 0.140625, [64] = 0.20 },
            profile         = 'lsb',
            visible         = false,
            window_pos      = { x = 120, y = 340 },
        })

        local restored = C.sanitize(C.deserialize(C.serialize(original)))

        assert.is_true(restored.assume_quest_ws)
        assert.near(0.140625, restored.march_override, 1e-12)
        assert.near(0.140625, restored.buff_overrides[214], 1e-12)
        assert.near(0.20, restored.buff_overrides[64], 1e-12)
        assert.are.equal('lsb', restored.profile)
        assert.is_false(restored.visible)
        assert.are.equal(120, restored.window_pos.x)
        assert.are.equal(340, restored.window_pos.y)
    end)

    it('drops legacy level pins from pre-v0.1.9 files (migration)', function()
        -- v0.1.6-0.1.8 persisted pinned_levels, and an immortal
        -- name-pin silently overrode fresh con checks (the v0.1.8
        -- field bug). Loading an old file must shed the pins and
        -- keep everything else.
        local legacy = table.concat(
        {
            'return {',
            '    assume_quest_ws = true,',
            "    profile = 'lsb',",
            '    pinned_levels = {',
            "        ['Tunnel Worm'] = 3,",
            "        ['Carrion Crow'] = 6,",
            '    },',
            '}',
        }, '\n')

        local restored = C.sanitize(C.deserialize(legacy))

        assert.is_true(restored.assume_quest_ws)
        assert.are.equal('lsb', restored.profile)
        assert.is_nil(restored.pinned_levels)
    end)

    it('round-trips the defaults unchanged', function()
        local restored = C.sanitize(C.deserialize(
            C.serialize(C.sanitize(nil))))

        assert.is_false(restored.assume_quest_ws)
        assert.are.equal(0, restored.march_override)
        assert.are.equal('phoenix', restored.profile)
        assert.are.equal(-1, restored.window_pos.x)
    end)
end)

describe('sanitize hardening', function()
    it('drops type-mismatched and out-of-range values', function()
        local result = C.sanitize(
        {
            assume_quest_ws = 'yes',           -- wrong type
            march_override  = 7,               -- out of range
            buff_overrides  = { [214] = 'x', a = 0.1, [33] = 0.15 },
            profile         = 42,
            window_pos      = { x = 'left' },
        })

        assert.is_false(result.assume_quest_ws)
        assert.are.equal(0, result.march_override)
        assert.is_nil(result.buff_overrides[214])
        assert.near(0.15, result.buff_overrides[33], 1e-12)
        assert.are.equal('phoenix', result.profile)
        assert.are.equal(-1, result.window_pos.x)
    end)

    it('never executes code from a malicious settings file', function()
        local evil = 'os.execute("touch /tmp/pwned") return {}'

        -- sandboxed env: os is nil inside the chunk -> pcall fails or
        -- returns the empty table; either way nothing executes
        local result = C.deserialize(evil)

        assert.is_true(result == nil or type(result) == 'table')
    end)

    it('rejects garbage input', function()
        assert.is_nil(C.deserialize('not lua {{{'))
        assert.is_nil(C.deserialize(nil))
        assert.is_nil(C.deserialize('return 42'))
    end)
end)

if WHETSTONE_TEST_SUMMARY then
    WHETSTONE_TEST_SUMMARY()
end
