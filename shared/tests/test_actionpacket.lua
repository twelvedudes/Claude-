--[[
    Tests for shared/actionpacket.lua: the 0x028 bit reader (round-trip
    against an independent packer replicating the server's packBitsBE
    little-endian-aggregate semantics), one packet fixture per action
    category Telegraph consumes, classify(), and the 0x029 battle
    message parser.

    Every fixture is hand-built from the cited Phoenix emitter
    (phoenixffxi/Phoenix @ 0f3f8fc), not from the parser: the FourCC
    values, message ids and field routing in these tests are the
    ground-truth transcript, so a parser regression cannot hide.

    Runs under busted or plain Lua 5.1+:
        lua5.1 shared/tests/test_actionpacket.lua
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
    'shared/?.lua',
    '?.lua',
    package.path,
}, ';')

local A = require('actionpacket')

-- ---------------------------------------------------------------------
-- Independent bit PACKER replicating packBitsBE: value bits are OR'd
-- into a little-endian byte aggregate at the given bit offset. Written
-- from the C++ source (src/common/utils.cpp), not from the parser, so
-- the round trip is a real cross-check.
-- ---------------------------------------------------------------------

local Writer = {}
Writer.__index = Writer

function Writer.new()
    return setmetatable({ bytes = {}, offset = 0 }, Writer)
end

function Writer:put(value, length)
    for bit = 0, length - 1 do
        local absolute = self.offset + bit
        local byte_index = math.floor(absolute / 8) + 1
        local bit_in_byte = absolute % 8

        if math.floor(value / 2 ^ bit) % 2 == 1 then
            self.bytes[byte_index] = (self.bytes[byte_index] or 0)
                + 2 ^ bit_in_byte
        else
            self.bytes[byte_index] = self.bytes[byte_index] or 0
        end
    end

    self.offset = self.offset + length
end

function Writer:tostring()
    local out = {}

    for index = 1, math.ceil(self.offset / 8) do
        out[index] = string.char(self.bytes[index] or 0)
    end

    return table.concat(out)
end

-- Generic 0x028 builder mirroring 0x028_battle2.cpp pack():
--   spec = { actor, category, action_id, info?, targets = { { id,
--            results = { { param, message, animation? } } } } }
local function build_action(spec)
    local w = Writer.new()

    w:put(0x28, 8)  -- packet id
    w:put(0, 8)     -- size placeholder
    w:put(0, 16)    -- sync
    w:put(0, 8)     -- workSize byte (offset 0x04)

    w:put(spec.actor, 32)
    w:put(#spec.targets, 6)
    w:put(0, 4)                 -- res_sum is always 0
    w:put(spec.category, 4)
    w:put(spec.action_id or 0, 32)
    w:put(spec.info or 0, 32)

    for _, target in ipairs(spec.targets) do
        w:put(target.id, 32)
        w:put(#target.results, 4)

        for _, result in ipairs(target.results) do
            w:put(result.reaction or 0, 3)
            w:put(result.kind or 0, 2)
            w:put(result.animation or 0, 12)
            w:put(result.info or 0, 5)
            w:put(0, 2)                      -- distortion
            w:put(0, 3)                      -- knockback
            w:put(result.param or 0, 17)
            w:put(result.message or 0, 10)
            w:put(0, 31)                     -- modifier
            w:put(0, 1)                      -- no additional effect
            w:put(0, 1)                      -- no spikes
        end
    end

    return w:tostring()
end

-- =====================================================================
describe('bit reader', function()
    it('round-trips values through an independently packed stream', function()
        local w = Writer.new()

        w:put(0xDEADBEEF, 32)
        w:put(45, 6)
        w:put(5, 3)
        w:put(99999, 17)

        local data = w:tostring()

        assert.are.equal(0xDEADBEEF, A.read_bits(data, 0, 32))
        assert.are.equal(45, A.read_bits(data, 32, 6))
        assert.are.equal(5, A.read_bits(data, 38, 3))
        assert.are.equal(99999, A.read_bits(data, 41, 17))
    end)

    it('handles unaligned offsets across byte boundaries', function()
        local w = Writer.new()

        w:put(0, 5)
        w:put(1234, 11)

        assert.are.equal(1234, A.read_bits(w:tostring(), 5, 11))
    end)
end)

-- =====================================================================
describe('casting start (MagicStart, magic_state.cpp Cast)', function()
    -- magic_state.cpp: actiontype = MagicStart (8), actionid =
    -- getFourCC() of the spell GROUP ('cawh' for white magic), the
    -- SPELL ID rides in result.param, message = StartsCastingSelf (3)
    -- for non-PC casters.
    local packet = build_action(
    {
        actor     = 0x1000123,                -- a mob
        category  = A.CATEGORY.MAGIC_START,   -- 8
        action_id = 0x68776163,               -- FourCC 'cawh' WhiteMagicCast
        targets   = { { id = 0x104, results =
            { { param = 1, message = A.MSG.STARTS_CAST_SELF } } } },
    })

    local action = A.parse_action(packet)

    it('parses category 8 with the cast FourCC as action_id', function()
        assert.are.equal(0x1000123, action.actor)
        assert.are.equal(8, action.category)
        assert.are.equal(0x68776163, action.action_id)
        assert.is_true(A.CAST_FOURCC[action.action_id] ~= nil)
    end)

    it('carries the spell id in result.param, NOT in action_id', function()
        assert.are.equal(1, action.targets[1].results[1].param)
        assert.are.equal(A.MSG.STARTS_CAST_SELF,
            action.targets[1].results[1].message)
    end)

    it('classifies as cast_start with the spell id', function()
        local kind, id = A.classify(action)

        assert.are.equal('cast_start', kind)
        assert.are.equal(1, id)
    end)

    it('classifies a PC cast (message 327) the same way', function()
        local pc = A.parse_action(build_action(
        {
            actor     = 0x104,
            category  = A.CATEGORY.MAGIC_START,
            action_id = 0x6B626163, -- 'cabk' BlackMagicCast
            targets   = { { id = 0x1000123, results =
                { { param = 159, message = A.MSG.STARTS_CAST_TARGET } } } },
        }))

        local kind, id = A.classify(pc)

        assert.are.equal('cast_start', kind)
        assert.are.equal(159, id)
    end)

    it('treats an UNKNOWN scheduler FourCC as a start, never crashes', function()
        local odd = A.parse_action(build_action(
        {
            actor     = 0x1000123,
            category  = A.CATEGORY.MAGIC_START,
            action_id = 0x12345678, -- not a known FourCC
            targets   = { { id = 0x104, results = { { param = 77 } } } },
        }))

        local kind, id = A.classify(odd)

        assert.are.equal('cast_start', kind)
        assert.are.equal(77, id)
    end)
end)

-- =====================================================================
describe('casting interrupt (MagicStart + interrupt FourCC)', function()
    -- interrupts.cpp MagicInterrupt: a SECOND MagicStart action whose
    -- actionid is getFourCC(true) - 'spwh' for white magic - with the
    -- spell id in result.param and the actor self-targeted. The chat
    -- line ("casting is interrupted", MsgBasic 16) arrives on 0x029.
    local packet = build_action(
    {
        actor     = 0x1000123,
        category  = A.CATEGORY.MAGIC_START,
        action_id = 0x68777073, -- FourCC 'spwh' WhiteMagicInterrupt
        targets   = { { id = 0x1000123, results = { { param = 1 } } } },
    })

    local action = A.parse_action(packet)

    it('recognizes the interrupt FourCC set', function()
        assert.is_true(A.CAST_INTERRUPT_FOURCC[action.action_id] ~= nil)
        assert.is_nil(A.CAST_FOURCC[action.action_id])
    end)

    it('classifies as cast_interrupt with the spell id', function()
        local kind, id = A.classify(action)

        assert.are.equal('cast_interrupt', kind)
        assert.are.equal(1, id)
    end)

    it('covers every spell group with a distinct interrupt FourCC', function()
        -- spell.cpp getFourCC: 8 groups, 8 cast + 8 interrupt FourCCs
        local casts, interrupts = 0, 0

        for _ in pairs(A.CAST_FOURCC) do casts = casts + 1 end
        for _ in pairs(A.CAST_INTERRUPT_FOURCC) do
            interrupts = interrupts + 1
        end

        assert.are.equal(8, casts)
        assert.are.equal(8, interrupts)
    end)
end)

-- =====================================================================
describe('magic finish (MagicFinish, OnCastFinished)', function()
    -- battleentity.cpp OnCastFinished: actiontype = MagicFinish (4),
    -- actionid = spell id DIRECTLY (uint16 cast), result.param =
    -- damage, message = MagicDamage (2) for nukes. action.recast
    -- travels in the info field (normalize(): only MagicFinish emits
    -- recast).
    local packet = build_action(
    {
        actor     = 0x1000123,
        category  = A.CATEGORY.MAGIC_FINISH,
        action_id = 159,             -- the spell id itself
        info      = 30,              -- recast seconds
        targets   = { { id = 0x104, results =
            { { param = 86, message = A.MSG.MAGIC_DAMAGE } } } },
    })

    local action = A.parse_action(packet)

    it('parses spell id from action_id and damage from param', function()
        assert.are.equal(4, action.category)
        assert.are.equal(159, action.action_id)
        assert.are.equal(86, action.targets[1].results[1].damage)
        assert.are.equal(30, action.info)
    end)

    it('classifies as magic_finish with the spell id', function()
        local kind, id = A.classify(action)

        assert.are.equal('magic_finish', kind)
        assert.are.equal(159, id)
    end)
end)

-- =====================================================================
describe('TP-move readying (SkillStart + FourCC cate)', function()
    -- mobskill_state.cpp: when activation time > 0, actiontype =
    -- SkillStart (7), actionid = FourCC::SkillUse ('cate'), the MOB
    -- SKILL ID rides in result.param, message = ReadiesWeaponskill
    -- (43) unless SKILLFLAG_NO_START_MSG zeroes it.
    local packet = build_action(
    {
        actor     = 0x1000123,
        category  = A.CATEGORY.SKILL_START,
        action_id = A.FOURCC.SKILL_USE,
        targets   = { { id = 0x104, results =
            { { param = 257, message = A.MSG.READIES_SKILL } } } },
    })

    local action = A.parse_action(packet)

    it('parses the readying with the skill id in param', function()
        assert.are.equal(7, action.category)
        assert.are.equal(A.FOURCC.SKILL_USE, action.action_id)
        assert.are.equal(257, action.targets[1].results[1].param)
    end)

    it('classifies as ready_start with the skill id', function()
        local kind, id = A.classify(action)

        assert.are.equal('ready_start', kind)
        assert.are.equal(257, id)
    end)

    it('still classifies when NO_START_MSG zeroed the message', function()
        -- mobskill_state.cpp: SKILLFLAG_NO_START_MSG (0x010) zeroes
        -- messageID but the packet still flows with the skill id
        local silent = A.parse_action(build_action(
        {
            actor     = 0x1000123,
            category  = A.CATEGORY.SKILL_START,
            action_id = A.FOURCC.SKILL_USE,
            targets   = { { id = 0x104, results =
                { { param = 257, message = 0 } } } },
        }))

        local kind, id = A.classify(silent)

        assert.are.equal('ready_start', kind)
        assert.are.equal(257, id)
    end)
end)

-- =====================================================================
describe('readying interrupt (SkillStart + FourCC spte)', function()
    -- interrupts.cpp AbilityInterrupt (used by CMobSkillState::Cleanup
    -- when the state did not complete): SkillStart with actionid =
    -- FourCC::SkillInterrupt and an empty self-targeted result.
    local packet = build_action(
    {
        actor     = 0x1000123,
        category  = A.CATEGORY.SKILL_START,
        action_id = A.FOURCC.SKILL_INTERRUPT,
        targets   = { { id = 0x1000123, results = { {} } } },
    })

    local action = A.parse_action(packet)

    it('classifies as ready_interrupt', function()
        local kind = A.classify(action)

        assert.are.equal('ready_interrupt', kind)
    end)
end)

-- =====================================================================
describe('mob TP-move finish', function()
    it('classifies id >= 256 as mobskill_finish (category 11)', function()
        -- battleentity.cpp OnMobSkillFinished: skill id >= 256 ->
        -- MobSkillFinish, actionid = skill id, damage in param
        local action = A.parse_action(build_action(
        {
            actor     = 0x1000123,
            category  = A.CATEGORY.MOBSKILL_FINISH,
            action_id = 257,
            targets   = { { id = 0x104, results =
                { { param = 142, message = A.MSG.SKILL_DAMAGE } } } },
        }))

        local kind, id = A.classify(action)

        assert.are.equal('mobskill_finish', kind)
        assert.are.equal(257, id)
        assert.are.equal(142, action.targets[1].results[1].damage)
    end)

    it('classifies id < 256 as ws_finish (category 3) - the shared '
        .. 'category', function()
        -- battleentity.cpp OnMobSkillFinished: skill id < 256 finishes
        -- as SkillFinish (3) - the same category as player weapon
        -- skills. The consumer disambiguates by actor.
        local action = A.parse_action(build_action(
        {
            actor     = 0x1000123,
            category  = A.CATEGORY.WS_FINISH,
            action_id = 240,
            targets   = { { id = 0x104, results =
                { { param = 88, message = A.MSG.SKILL_DAMAGE } } } },
        }))

        local kind, id = A.classify(action)

        assert.are.equal('ws_finish', kind)
        assert.are.equal(240, id)
    end)

    it('classifies avatar skills as petskill_finish (category 13)', function()
        local action = A.parse_action(build_action(
        {
            actor     = 0x1000456,
            category  = A.CATEGORY.PETSKILL_FINISH,
            action_id = 584,
            targets   = { { id = 0x104, results = { { param = 0 } } } },
        }))

        assert.are.equal('petskill_finish', A.classify(action))
    end)
end)

-- =====================================================================
describe('job ability finish (AbilityFinish)', function()
    -- battleentity.cpp OnAbility: actiontype from abilities.sql
    -- actionType (default 6 = AbilityFinish), actionid = the RAW
    -- ability id (no offset on this server: action.actionid =
    -- PAbility->getID()).
    local packet = build_action(
    {
        actor     = 0x104,
        category  = A.CATEGORY.JA_FINISH,
        action_id = 16, -- mighty_strikes (abilities.sql)
        targets   = { { id = 0x104, results =
            { { param = 0, message = 100 } } } },
    })

    local action = A.parse_action(packet)

    it('classifies as ja_finish with the raw ability id', function()
        local kind, id = A.classify(action)

        assert.are.equal('ja_finish', kind)
        assert.are.equal(16, id)
    end)
end)

-- =====================================================================
describe('melee round (BasicAttack)', function()
    -- action.cpp normalize(): BasicAttack FORCES actionid to FourCC
    -- 'atk0' - the action id of a melee round is NOT zero.
    local packet = build_action(
    {
        actor     = 0x1000123,
        category  = A.CATEGORY.MELEE,
        action_id = A.FOURCC.BASIC_ATTACK,
        targets   = { { id = 0x104, results =
            {
                { param = 38, message = A.MSG.HIT },
                { param = 0, message = A.MSG.MISS },
                { param = 12, message = A.MSG.COUNTERED_DAMAGE },
            } } },
    })

    local action = A.parse_action(packet)

    it('parses all swing results', function()
        local results = action.targets[1].results

        assert.are.equal(3, #results)
        assert.are.equal(38, results[1].damage)
        assert.are.equal(A.MSG.HIT, results[1].message)
        assert.are.equal(A.MSG.MISS, results[2].message)
        -- message 33: the TARGET countered; param is the damage the
        -- ATTACKER takes (battleutils.cpp TakePhysicalDamage counter
        -- branch) - a TP feed for the countered ATTACKER
        assert.are.equal(A.MSG.COUNTERED_DAMAGE, results[3].message)
        assert.are.equal(12, results[3].param)
    end)

    it('classifies as melee', function()
        assert.are.equal('melee', A.classify(action))
    end)
end)

-- =====================================================================
describe('parser hardening', function()
    it('rejects runt packets', function()
        assert.is_nil(A.parse_action(string.char(0x28, 0, 0, 0)))
    end)

    it('classify tolerates nil', function()
        assert.is_nil(A.classify(nil))
    end)

    it('classify tolerates an action with zero targets', function()
        local action = A.parse_action(build_action(
        {
            actor     = 0x1000123,
            category  = A.CATEGORY.MAGIC_START,
            action_id = 0x68776163,
            targets   = {},
        }))

        local kind, id = A.classify(action)

        assert.are.equal('cast_start', kind)
        assert.is_nil(id)
    end)

    it('exposes param and damage as the same 17-bit field', function()
        local action = A.parse_action(build_action(
        {
            actor     = 0x104,
            category  = A.CATEGORY.MELEE,
            action_id = A.FOURCC.BASIC_ATTACK,
            targets   = { { id = 0x10F, results = { { param = 999 } } } },
        }))

        local result = action.targets[1].results[1]

        assert.are.equal(999, result.param)
        assert.are.equal(999, result.damage)
    end)
end)

-- =====================================================================
describe('0x029 battle message parser', function()
    -- src/map/packets/s2c/0x029_battle_message.h: u32 sender @0x04,
    -- u32 target @0x08, i32 param @0x0C, i32 value @0x10, u16 indexes,
    -- u16 message @0x18, u8 type @0x1A. Hand-packed little-endian.
    local function le32(value)
        local b0 = value % 256
        local b1 = math.floor(value / 256) % 256
        local b2 = math.floor(value / 65536) % 256
        local b3 = math.floor(value / 16777216) % 256

        return string.char(b0, b1, b2, b3)
    end

    local function le16(value)
        return string.char(value % 256, math.floor(value / 256) % 256)
    end

    local packet = string.char(0x29, 0, 0, 0)
        .. le32(0x104)       -- sender (the killer)
        .. le32(0x1000123)   -- target (the dying mob)
        .. le32(0)           -- param
        .. le32(0)           -- value
        .. le16(5)           -- sender index
        .. le16(291)         -- target index
        .. le16(6)           -- message: DefeatsTarget
        .. string.char(0)    -- type

    local message = A.parse_battle_message(packet)

    it('parses the full field set', function()
        assert.are.equal(0x104, message.sender_id)
        assert.are.equal(0x1000123, message.target_id)
        assert.are.equal(6, message.message_id)
        assert.are.equal(291, message.target_idx)
    end)

    it('flags both death message ids', function()
        -- mobentity.cpp OnDeath: DefeatsTarget = 6, FallsToGround = 20
        assert.is_true(A.DEATH_MESSAGES[6])
        assert.is_true(A.DEATH_MESSAGES[20])
        assert.is_nil(A.DEATH_MESSAGES[16])
    end)

    it('rejects runt packets', function()
        assert.is_nil(A.parse_battle_message(string.char(0x29, 0, 0)))
    end)

    it('decodes negative params as signed i32', function()
        local negative = string.char(0x29, 0, 0, 0)
            .. le32(0x104) .. le32(0x1000123)
            .. le32(4294967295) -- i32 -1
            .. le32(0) .. le16(0) .. le16(0) .. le16(170)
            .. string.char(0)

        assert.are.equal(-1, A.parse_battle_message(negative).param)
    end)
end)

-- =====================================================================
describe('duplicate packet rejection (shared transport state)', function()
    it('rejects an identical payload inside the window', function()
        local now = 100.0

        assert.is_false(A.is_duplicate('shared-A', now))
        assert.is_true(A.is_duplicate('shared-A', now + 0.05))
    end)

    it('accepts the same payload after the window', function()
        local now = 200.0

        assert.is_false(A.is_duplicate('shared-B', now))
        assert.is_false(A.is_duplicate('shared-B',
            now + A.DEDUP_WINDOW_S + 0.01))
    end)
end)

if TELEGRAPH_TEST_SUMMARY then
    TELEGRAPH_TEST_SUMMARY()
end
