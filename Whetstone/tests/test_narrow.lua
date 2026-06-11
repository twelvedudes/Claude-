--[[
    Tests for narrow.lua - the v0.1.9 field bug regression suite
    ("check one Wild Rabbit -> every Wild Rabbit shows Lv.4 checked").

    Runs under busted or plain Lua 5.1+:
        lua5.1 Whetstone/tests/test_narrow.lua
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
    }, { __call = function(_, ...) return original_assert(...) end })
    WHETSTONE_TEST_SUMMARY = function()
        print(string.format('%d tests, %d failures', tests, failed))
        if failed > 0 then os.exit(1) end
    end
end

local here = (arg and arg[0] and arg[0]:match('(.*[/\\])')) or ''
package.path = table.concat({
    here .. '../?.lua', 'Whetstone/?.lua', '?.lua', package.path }, ';')

local N = require('narrow')

local ZONE = 230
local RABBIT_1 = 0x10600101
local RABBIT_2 = 0x10600102

describe('field-bug regression (same-name mobs are different levels)', function()
    it('a. checking rabbit#1 leaves rabbit#2 UNCONFIRMED', function()
        local s = N.new()

        N.remember_check(s, ZONE, RABBIT_1, 4, 'easy prey', 'Wild Rabbit')

        local level, source = N.resolve(s, ZONE, 'Wild Rabbit', RABBIT_2)

        assert.is_nil(level)
        assert.is_nil(source)

        -- and rabbit#1 itself IS narrowed
        local l1, s1 = N.resolve(s, ZONE, 'Wild Rabbit', RABBIT_1)
        assert.are.equal(4, l1)
        assert.are.equal('checked', s1)
    end)

    it('b. checking rabbit#2 narrows it without touching rabbit#1', function()
        local s = N.new()

        N.remember_check(s, ZONE, RABBIT_1, 4, 'easy prey', 'Wild Rabbit')
        N.remember_check(s, ZONE, RABBIT_2, 6, 'even match', 'Wild Rabbit')

        assert.are.equal(4, (N.resolve(s, ZONE, 'Wild Rabbit', RABBIT_1)))
        assert.are.equal(6, (N.resolve(s, ZONE, 'Wild Rabbit', RABBIT_2)))
    end)

    it('c. re-checking an entity ALWAYS overwrites (latest wins)', function()
        local s = N.new()

        N.remember_check(s, ZONE, RABBIT_1, 4, 'easy prey', 'Wild Rabbit')

        local ok = N.remember_check(s, ZONE, RABBIT_1, 5, 'decent challenge',
                                    'Wild Rabbit')

        assert.is_true(ok)
        assert.are.equal(5, (N.resolve(s, ZONE, 'Wild Rabbit', RABBIT_1)))
    end)

    it('d. the checked cache is structurally id-keyed only', function()
        local s = N.new()

        N.remember_check(s, ZONE, RABBIT_1, 4, 'easy prey', 'Wild Rabbit')
        N.remember_check(s, ZONE, RABBIT_2, 6, 'even match', 'Wild Rabbit')
        N.pin(s, 'Wild Rabbit', 3)

        assert.is_true(N.assert_id_keyed(s))

        -- a level lookup by a DIFFERENT id finds nothing, whatever
        -- the name says: no name-keyed read path exists
        assert.is_nil(N.checked_for(s, ZONE, 0x10600999, 'Wild Rabbit'))
    end)
end)

describe('degenerate id guard (the glue failure mode)', function()
    it('refuses to cache under id 0 or non-numeric ids', function()
        local s = N.new()

        local ok0, why0 = N.remember_check(s, ZONE, 0, 4, 'ep', 'Worm')
        local okn, _ = N.remember_check(s, ZONE, nil, 4, 'ep', 'Worm')

        assert.is_false(ok0)
        assert.is_true(why0:find('invalid server id') ~= nil)
        assert.is_false(okn)

        -- and a degenerate lookup can never hit anything
        assert.is_nil(N.checked_for(s, ZONE, 0, 'Worm'))
        assert.is_nil(N.checked_for(s, ZONE, nil, 'Worm'))
        assert.is_true(N.assert_id_keyed(s))
    end)
end)

describe('zone scoping and recycling', function()
    it('wipes the cache on zone change', function()
        local s = N.new()

        N.remember_check(s, ZONE, RABBIT_1, 4, 'ep', 'Wild Rabbit')
        N.remember_check(s, 231, 0x10610001, 8, 'em', 'Carrion Worm')

        assert.is_nil(N.checked_for(s, 231, RABBIT_1, 'Wild Rabbit'))
        assert.are.equal(8, (N.checked_for(s, 231, 0x10610001,
                                           'Carrion Worm')))
    end)

    it('forgets a single id on death', function()
        local s = N.new()

        N.remember_check(s, ZONE, RABBIT_1, 4, 'ep', 'Wild Rabbit')
        N.remember_check(s, ZONE, RABBIT_2, 6, 'em', 'Wild Rabbit')
        N.forget(s, RABBIT_1)

        assert.is_nil(N.checked_for(s, ZONE, RABBIT_1, 'Wild Rabbit'))
        assert.are.equal(6, (N.checked_for(s, ZONE, RABBIT_2,
                                           'Wild Rabbit')))
    end)

    it('drops an entry when the id was recycled onto another species', function()
        local s = N.new()

        N.remember_check(s, ZONE, RABBIT_1, 4, 'ep', 'Wild Rabbit')

        -- same id now belongs to a Ding Bat: never trust the old level
        assert.is_nil(N.checked_for(s, ZONE, RABBIT_1, 'Ding Bat'))
        -- and the poisoned entry is gone for good
        assert.is_nil(N.checked_for(s, ZONE, RABBIT_1, 'Wild Rabbit'))
    end)
end)

describe('precedence resolution', function()
    it('pin > checked, with the losing check still reported', function()
        local s = N.new()

        N.remember_check(s, ZONE, RABBIT_1, 1, 'tw', 'Wild Rabbit')
        N.pin(s, 'Wild Rabbit', 3)

        local level, source, check = N.resolve(s, ZONE, 'Wild Rabbit',
                                               RABBIT_1)

        assert.are.equal(3, level)
        assert.are.equal('pinned', source)
        assert.are.equal(1, check) -- conflict surfacing needs this

        N.unpin(s, 'Wild Rabbit')

        level, source = N.resolve(s, ZONE, 'Wild Rabbit', RABBIT_1)

        assert.are.equal(1, level)
        assert.are.equal('checked', source)
    end)

    it('pins apply by name even with no entity id', function()
        local s = N.new()

        N.pin(s, 'Wild Rabbit', 3)

        local level, source = N.resolve(s, ZONE, 'Wild Rabbit', nil)

        assert.are.equal(3, level)
        assert.are.equal('pinned', source)
    end)
end)

if WHETSTONE_TEST_SUMMARY then
    WHETSTONE_TEST_SUMMARY()
end
