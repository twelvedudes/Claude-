--[[
    Tests for castbar.lua: the per-actor cast/ready bar state machine.
    Action fixtures are the documented parser output shape; the
    category/FourCC routing they exercise is the ground-truth
    transcript from Phoenix (see shared/actionpacket.lua and
    shared/tests/test_actionpacket.lua for the packed-byte round
    trips).

    Runs under busted or plain Lua 5.1+:
        lua5.1 Telegraph/tests/test_castbar.lua
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

local C = require('castbar')

local MOB  = 0x1000123
local MOB2 = 0x1000456
local PC   = 0x104

-- FourCC constants under test (shared/actionpacket.lua, from
-- src/map/enums/four_cc.h)
local CAWH = 0x68776163 -- WhiteMagicCast
local SPWH = 0x68777073 -- WhiteMagicInterrupt
local CATE = 0x65746163 -- SkillUse (readying)
local SPTE = 0x65747073 -- SkillInterrupt

local function ctx()
    return
    {
        spell_info = function(id)
            if id == 1 then
                return { name = 'Cure', cast_ms = 2000 }
            end

            if id == 159 then
                return { name = 'Stone', cast_ms = 1500 }
            end

            return nil
        end,

        mobskill_info = function(id)
            if id == 257 then
                return { name = 'Wild Carrot', windup_ms = 3000 }
            end

            return nil
        end,
    }
end

local function action(actor, category, action_id, param, message, target)
    return
    {
        actor = actor,
        category = category,
        action_id = action_id,
        targets = { { id = target or PC, results =
            { { reaction = 0, kind = 0, animation = 0, info = 0,
                damage = param, param = param,
                message = message or 0 } } } },
    }
end

local function cast_start(actor, spell_id)
    return action(actor, 8, CAWH, spell_id, 3)
end

local function cast_interrupt(actor, spell_id)
    return action(actor, 8, SPWH, spell_id, 0, actor)
end

local function magic_finish(actor, spell_id, damage)
    return action(actor, 4, spell_id, damage or 0, 2)
end

local function ready_start(actor, skill_id)
    return action(actor, 7, CATE, skill_id, 43)
end

local function ready_interrupt(actor)
    return action(actor, 7, SPTE, 0, 0, actor)
end

local function mobskill_finish(actor, skill_id)
    return action(actor, 11, skill_id, 142, 185)
end

-- =====================================================================
describe('cast bars', function()
    it('casting start opens a depleting bar with the table time', function()
        local s = C.new()

        C.on_action(s, cast_start(MOB, 1), ctx(), 100)

        local bars = C.bars(s, 100.5)

        assert.are.equal(1, #bars)
        assert.are.equal('cast', bars[1].kind)
        assert.are.equal('Cure', bars[1].label)
        assert.are.equal(2, bars[1].duration_s)
        assert.are.equal(1.5, bars[1].remaining_s)
        assert.are.equal(0.75, bars[1].fraction)
        assert.is_false(bars[1].overrun)
    end)

    it('an UNKNOWN spell id shows "casting (id N)", no duration, '
        .. 'no crash', function()
        local s = C.new()

        C.on_action(s, cast_start(MOB, 9999), ctx(), 100)

        local bars = C.bars(s, 101)

        assert.are.equal(1, #bars)
        assert.are.equal('casting (id 9999)', bars[1].label)
        assert.is_nil(bars[1].duration_s)
        assert.is_nil(bars[1].fraction)
    end)

    it('magic finish clears the bar and reports observed timing', function()
        local s = C.new()

        C.on_action(s, cast_start(MOB, 1), ctx(), 100)

        local events = C.on_action(s, magic_finish(MOB, 1, 86),
            ctx(), 102.1)

        assert.are.equal(1, #events)
        assert.are.equal('finish', events[1].outcome)
        assert.are.equal(2, events[1].expected_s)
        -- observed 2.1s vs table 2.0s: the validator's raw material
        assert.is_true(math.abs(events[1].observed_s - 2.1) < 1e-9)
        assert.are.equal(0, #C.bars(s, 102.1))
    end)

    it('the interrupt FourCC clears the bar as interrupted', function()
        -- interrupts.cpp MagicInterrupt: a SECOND MagicStart whose
        -- action_id is the spell group interrupt FourCC
        local s = C.new()

        C.on_action(s, cast_start(MOB, 1), ctx(), 100)

        local events = C.on_action(s, cast_interrupt(MOB, 1),
            ctx(), 101)

        assert.are.equal(1, #events)
        assert.are.equal('interrupt', events[1].outcome)
        assert.are.equal(0, #C.bars(s, 101))
    end)

    it('a finish without a start is silently ignored', function()
        local s = C.new()

        local events = C.on_action(s, magic_finish(MOB, 1, 86),
            ctx(), 100)

        assert.are.equal(0, #events)
        assert.are.equal(0, #C.bars(s, 100))
    end)

    it('overrun bars linger flagged, then drop', function()
        local s = C.new()

        C.on_action(s, cast_start(MOB, 159), ctx(), 100) -- 1.5s

        -- past expiry, inside the overrun window
        local bars = C.bars(s, 102.5)

        assert.are.equal(1, #bars)
        assert.is_true(bars[1].overrun)
        assert.are.equal(0, bars[1].remaining_s)

        -- past the drop horizon (1.5 + 3.0)
        assert.are.equal(0, #C.bars(s, 105))
        -- and the prune is real, not cosmetic
        assert.are.equal(0, s.count)
    end)
end)

-- =====================================================================
describe('ready bars (TP-move windup)', function()
    it('readying opens a windup bar from the skill table', function()
        local s = C.new()

        C.on_action(s, ready_start(MOB, 257), ctx(), 100)

        local bars = C.bars(s, 101)

        assert.are.equal(1, #bars)
        assert.are.equal('ready', bars[1].kind)
        assert.are.equal('Wild Carrot', bars[1].label)
        assert.are.equal(3, bars[1].duration_s)
        assert.are.equal(2, bars[1].remaining_s)
    end)

    it('an unknown skill id labels itself and never crashes', function()
        local s = C.new()

        C.on_action(s, ready_start(MOB, 8888), ctx(), 100)

        local bars = C.bars(s, 100)

        assert.are.equal('skill (id 8888)', bars[1].label)
        assert.is_nil(bars[1].duration_s)
    end)

    it('the skill finish clears the bar', function()
        local s = C.new()

        C.on_action(s, ready_start(MOB, 257), ctx(), 100)

        local events = C.on_action(s, mobskill_finish(MOB, 257),
            ctx(), 103)

        assert.are.equal('finish', events[1].outcome)
        assert.are.equal(0, #C.bars(s, 103))
    end)

    it('SkillInterrupt (spte) clears the bar as interrupted', function()
        local s = C.new()

        C.on_action(s, ready_start(MOB, 257), ctx(), 100)

        local events = C.on_action(s, ready_interrupt(MOB), ctx(), 101)

        assert.are.equal('interrupt', events[1].outcome)
        assert.are.equal(0, #C.bars(s, 101))
    end)

    it('MagicFinish ALSO clears a ready bar (the no-target / '
        .. 'out-of-range failure paths)', function()
        -- interrupts.cpp MobSkillNoTargetInRange/MobSkillOutOfRange:
        -- the readying resolves with a MagicFinish carrying the
        -- SkillInterrupt animation
        local s = C.new()

        C.on_action(s, ready_start(MOB, 257), ctx(), 100)
        C.on_action(s, magic_finish(MOB, 0, 0), ctx(), 103)

        assert.are.equal(0, #C.bars(s, 103))
    end)
end)

-- =====================================================================
describe('per-actor exclusivity and lifecycle', function()
    it('one bar per actor: a new start replaces the old bar', function()
        local s = C.new()

        C.on_action(s, cast_start(MOB, 1), ctx(), 100)

        local events = C.on_action(s, cast_start(MOB, 159), ctx(), 101)

        assert.are.equal(1, #events)
        assert.are.equal('replaced', events[1].outcome)

        local bars = C.bars(s, 101)

        assert.are.equal(1, #bars)
        assert.are.equal('Stone', bars[1].label)
    end)

    it('bars from different actors coexist, sorted by remaining', function()
        local s = C.new()

        C.on_action(s, cast_start(MOB, 1), ctx(), 100)    -- 2.0s
        C.on_action(s, ready_start(MOB2, 257), ctx(), 100) -- 3.0s

        local bars = C.bars(s, 100.5)

        assert.are.equal(2, #bars)
        assert.are.equal('Cure', bars[1].label)        -- 1.5s left
        assert.are.equal('Wild Carrot', bars[2].label) -- 2.5s left
    end)

    it('death drops the actor bar', function()
        local s = C.new()

        C.on_action(s, ready_start(MOB, 257), ctx(), 100)
        C.on_death(s, MOB)

        assert.are.equal(0, #C.bars(s, 100))
    end)

    it('zone change wipes everything', function()
        local s = C.new()

        C.on_action(s, cast_start(MOB, 1), ctx(), 100)
        C.on_action(s, ready_start(MOB2, 257), ctx(), 100)
        C.on_zone_change(s)

        assert.are.equal(0, #C.bars(s, 100))
        assert.are.equal(0, s.count)
    end)

    it('the actor table stays bounded and id-keyed', function()
        local s = C.new()

        for index = 1, 100 do
            C.on_action(s, cast_start(0x1000000 + index, 9999),
                ctx(), 100 + index)
        end

        assert.is_true(C.assert_id_keyed(s))
        assert.is_true(s.count <= C.POLICY.max_actors,
            'actor cap holds: ' .. s.count)
    end)

    it('refuses degenerate actor ids', function()
        local s = C.new()

        C.on_action(s, cast_start(0, 1), ctx(), 100)

        assert.are.equal(0, #C.bars(s, 100))
    end)
end)

if TELEGRAPH_TEST_SUMMARY then
    TELEGRAPH_TEST_SUMMARY()
end
