--[[
    shared/actionpacket.lua - the ONE 0x028/0x029 packet parser.

    Shared between the Whetstone and Telegraph addons. There is exactly
    one canonical require path - require('actionpacket') - used by every
    module in both addons; requiring it under any other name would
    create a second module instance with its own dedup state (the
    Whetstone module-identity lesson: /whet panel prints table
    identities precisely because two instances of "the same" module
    diverge silently).

    Ground truth: Phoenix (phoenixffxi/Phoenix @ 0f3f8fc).

    0x028 bit layout replicated from
    src/map/packets/s2c/0x028_battle2.cpp pack()/unpack(), starting at
    bit 40 (after the 4-byte header + 1-byte workSize):

        actor id 32 | trg_sum 6 | res_sum 4 | cmd_no 4 | cmd_arg 32 |
        info 32 | per target: id 32, result count 4 | per result:
        reaction 3, kind 2, animation 12, info 5, distortion 2,
        knockback 3, param 17, message 10, modifier 31,
        add-effect flag 1 [+ 6/4/17/10], spikes flag 1 [+ 6/4/14/10]

    unpackBitsBE (despite the name) reads bits from a LITTLE-ENDIAN
    byte aggregate (src/common/utils.cpp); read_bits below matches it
    exactly and is verified by round-trip tests against an independent
    packer (shared/tests/test_actionpacket.lua).

    CATEGORY SEMANTICS - verified against the server enums and the AI
    states that emit each category, NOT assumed from the category name
    (src/map/enums/action/category.h; emitters cited per constant):

      cmd_no (4 bits)            cmd_arg (32 bits)        result.param
      1  BasicAttack             FourCC 'atk0' (forced    damage
                                 by action.cpp
                                 normalize())
      2  RangedFinish            0                        damage
      3  SkillFinish             ws/mobskill id (mob      damage
                                 skills with id < 256
                                 finish as category 3,
                                 battleentity.cpp
                                 OnMobSkillFinished)
      4  MagicFinish             spell id                 damage/param
      5  ItemFinish              item id                  param
      6  AbilityFinish           ability id (or per       param
                                 abilities.sql
                                 actionType: 14/15)
      7  SkillStart              FourCC 'cate' = readying skill id
                                 (mobskill_state.cpp /
                                 weaponskill_state.cpp);
                                 FourCC 'spte' = skill/JA
                                 INTERRUPT (interrupts.cpp
                                 AbilityInterrupt)
      8  MagicStart              spell-group CAST FourCC  spell id
                                 ('cawh'...) = casting
                                 start (magic_state.cpp);
                                 spell-group INTERRUPT
                                 FourCC ('spwh'...) =
                                 cast interrupted
                                 (interrupts.cpp
                                 MagicInterrupt)
      9  ItemStart               FourCC 'cait'/'spit'     item id
      10 AbilityStart            (ability charge-up)      param
      11 MobSkillFinish          mob skill id (id >= 256) damage
      12 RangedStart             FourCC 'calg'/'splg'     -
      13 PetSkillFinish          pet/avatar skill id      damage
      14 Dancer / 15 RuneFencer  ability id               param

    A casting INTERRUPT is therefore a SECOND MagicStart whose cmd_arg
    is the interrupt FourCC for the spell's group, carrying the spell
    id in result.param (battleentity.cpp OnCastInterrupted ->
    interrupts.cpp MagicInterrupt). The "is interrupted" chat message
    itself arrives separately on 0x029 (MsgBasic::IsInterrupted = 16) -
    "despite the system supporting interrupted message in the action
    packet ... an 0x029 message is sent for spells" (battleentity.cpp).

    0x029 battle message layout from
    src/map/packets/s2c/0x029_battle_message.h (also parsed here so
    both addons share death detection - ids recycle onto respawns).

    Everything here is pure Lua; the addon glue owns file I/O and
    Ashita event wiring.
]]

local M = {}

local floor = math.floor

-- =====================================================================
-- Packet ids
-- =====================================================================

M.PACKET_ACTION         = 0x028
M.PACKET_BATTLE_MESSAGE = 0x029

-- =====================================================================
-- Action categories (src/map/enums/action/category.h ActionCategory)
-- =====================================================================

M.CATEGORY =
{
    NONE            = 0,
    MELEE           = 1,  -- BasicAttack
    RANGED_FINISH   = 2,
    WS_FINISH       = 3,  -- SkillFinish (player WS, and mob skills id < 256)
    MAGIC_FINISH    = 4,
    ITEM_FINISH     = 5,
    JA_FINISH       = 6,  -- AbilityFinish
    SKILL_START     = 7,  -- readying / skill interrupt (see FourCC)
    MAGIC_START     = 8,  -- casting start / cast interrupt (see FourCC)
    ITEM_START      = 9,
    JA_START        = 10,
    MOBSKILL_FINISH = 11, -- mob skills id >= 256
    RANGED_START    = 12,
    PETSKILL_FINISH = 13,
    DANCER          = 14,
    RUNE_FENCER     = 15,
}

-- =====================================================================
-- FourCC schedulers (src/map/enums/four_cc.h, byte-swapped LE values)
-- =====================================================================

M.FOURCC =
{
    BASIC_ATTACK     = 0x306B7461, -- "atk0"
    SKILL_USE        = 0x65746163, -- "cate" - readying (mob TP move / player WS)
    SKILL_INTERRUPT  = 0x65747073, -- "spte" - mob skill / JA interrupted
    ITEM_USE         = 0x74696163, -- "cait"
    ITEM_INTERRUPT   = 0x74697073, -- "spit"
    RANGED_START     = 0x676C6163, -- "calg"
    RANGED_INTERRUPT = 0x676C7073, -- "splg"
    RANGED_FINISH    = 0x676C6873, -- "shlg"
}

-- MagicStart cmd_arg when a cast BEGINS, by spell group
-- (CSpell::getFourCC, spell.cpp).
M.CAST_FOURCC =
{
    [0x68776163] = 'white',    -- "cawh"
    [0x6B626163] = 'black',    -- "cabk"
    [0x6C626163] = 'blue',     -- "cabl"
    [0x6F736163] = 'song',     -- "caso"
    [0x6A6E6163] = 'ninjutsu', -- "canj"
    [0x6D736163] = 'summon',   -- "casm"
    [0x65676163] = 'geomancy', -- "cage"
    [0x61666163] = 'trust',    -- "cafa"
}

-- MagicStart cmd_arg when a cast is INTERRUPTED, by spell group
-- (CSpell::getFourCC(interrupt = true); emitted by
-- interrupts.cpp MagicInterrupt/MagicParalyzed/MagicIntimidated).
M.CAST_INTERRUPT_FOURCC =
{
    [0x68777073] = 'white',    -- "spwh"
    [0x6B627073] = 'black',    -- "spbk"
    [0x6C627073] = 'blue',     -- "spbl"
    [0x6F737073] = 'song',     -- "spso"
    [0x6A6E7073] = 'ninjutsu', -- "spnj"
    [0x6D737073] = 'summon',   -- "spsm"
    [0x65677073] = 'geomancy', -- "spge"
    [0x61667073] = 'trust',    -- "spfa"
}

-- =====================================================================
-- Battle message ids (src/map/enums/msg_basic.h MsgBasic)
-- =====================================================================

M.MSG =
{
    HIT                 = 1,   -- AttackHits
    MAGIC_DAMAGE        = 2,   -- MagicDamage "<caster> casts <spell>. <target> takes .."
    STARTS_CAST_SELF    = 3,   -- StartsCastingSelf (non-PC casters)
    MISS                = 15,  -- AttackMisses
    CAST_INTERRUPTED    = 16,  -- IsInterrupted (arrives on 0x029 for spells)
    SHADOW_ABSORB       = 31,  -- ShadowAbsorb (param = shadows used, NOT damage)
    DODGE               = 32,  -- TargetDodges
    COUNTERED_DAMAGE    = 33,  -- AttackCounteredDamage (param = damage the
                               --   ATTACKER takes from the counter)
    READIES_SKILL       = 43,  -- ReadiesWeaponskill "<entity> readies <skill>."
    CRIT                = 67,  -- AttackCrit
    SKILL_DAMAGE        = 185, -- UsesSkillTakesDamage
    SKILL_MISS          = 188, -- UsesSkillMisses
    SKILL_NO_EFFECT     = 189, -- UsesSkillNoEffect
    MAGIC_BURST_DAMAGE  = 252, -- MagicBurstDamage
    SECONDARY_DAMAGE    = 264, -- TargetTakesDamage (offhand/secondary WS msg)
    EVADE               = 282, -- TargetEvades
    STARTS_CAST_TARGET  = 327, -- StartsCastingTarget (PC casters)
}

-- =====================================================================
-- Monotonic clock + duplicate-packet rejection
-- =====================================================================

-- Injectable monotonic clock (seconds, ms resolution): os.clock is
-- process-monotonic under Ashita; tests substitute their own.
M.clock = os.clock

-- FIELD FINDING (Whetstone v0.1.7 log, Horizon): identical action
-- packets were observed parsed 2-3x within the same second - with 15+
-- addons loaded, packet re-injection makes the same raw payload arrive
-- more than once. A genuine repeat of the SAME payload (same damage
-- rolls on every hit) inside 200ms is overwhelmingly unlikely (swing
-- rounds are seconds apart; multi-hits share one packet), so the raw
-- payload string within a 200ms window is the de-dup key.
M.DEDUP_WINDOW_S = 0.2

local recent_payloads = {}
local recent_count = 0

function M.is_duplicate(payload, now)
    now = now or M.clock()

    -- bound the table: sweep expired entries once it grows
    if recent_count > 32 then
        for key, seen in pairs(recent_payloads) do
            if now - seen >= M.DEDUP_WINDOW_S then
                recent_payloads[key] = nil
                recent_count = recent_count - 1
            end
        end
    end

    local seen = recent_payloads[payload]

    if seen ~= nil and now - seen < M.DEDUP_WINDOW_S then
        recent_payloads[payload] = now
        return true
    end

    if seen == nil then
        recent_count = recent_count + 1
    end

    recent_payloads[payload] = now

    return false
end

-- =====================================================================
-- Bit reader (unpackBitsBE-compatible)
-- =====================================================================

-- data: byte string; bit_offset: 0-based absolute bit position;
-- length <= 32. Bytes aggregate little-endian, then shift+mask.
function M.read_bits(data, bit_offset, length)
    local byte_index = floor(bit_offset / 8) -- 0-based
    local shift = bit_offset % 8
    local needed = math.ceil((shift + length) / 8)

    local value = 0
    local multiplier = 1

    for index = 0, needed - 1 do
        value = value + (data:byte(byte_index + 1 + index) or 0) * multiplier
        multiplier = multiplier * 256
    end

    value = floor(value / 2 ^ shift)

    return value % 2 ^ length
end

-- =====================================================================
-- 0x028 parser
-- =====================================================================

-- Returns
--   { actor, category, action_id, info, targets = { { id, results =
--     { { reaction, kind, animation, info, damage, param, message,
--         add_effect_damage? } } } } }
-- or nil for runt packets.
--
-- result.param and result.damage are the SAME 17-bit field: the server
-- calls it 'param' and its meaning depends on the category (damage on
-- finishes, SPELL id on MagicStart, SKILL id on SkillStart readying).
-- Both names are exposed so damage consumers stay readable and
-- start-event consumers do not read a spell id from a field named
-- "damage".
function M.parse_action(data)
    if #data < 10 then
        return nil
    end

    local offset = 8 * 5

    local function take(length)
        local value = M.read_bits(data, offset, length)
        offset = offset + length
        return value
    end

    local action = { targets = {} }

    action.actor = take(32)

    local target_count = take(6)
    take(4) -- res_sum, always 0

    action.category = take(4)
    action.action_id = take(32)
    action.info = take(32) -- recast seconds; only MagicFinish emits it
                           -- (action.cpp normalize() zeroes the rest)

    for _ = 1, target_count do
        local target = { id = take(32), results = {} }
        local result_count = take(4)

        for _ = 1, result_count do
            local result = {}

            result.reaction = take(3)
            result.kind = take(2)
            result.animation = take(12)
            result.info = take(5)
            take(2) -- hit distortion
            take(3) -- knockback
            result.damage = take(17)
            result.param = result.damage -- canonical server name
            result.message = take(10)
            take(31) -- modifier

            if take(1) == 1 then -- additional effect
                take(6)
                take(4)
                result.add_effect_damage = take(17)
                take(10)
            end

            if take(1) == 1 then -- spikes
                take(6)
                take(4)
                take(14)
                take(10)
            end

            target.results[#target.results + 1] = result
        end

        action.targets[#action.targets + 1] = target
    end

    return action
end

-- =====================================================================
-- Category classification helpers
-- =====================================================================

-- Classify a parsed action into the event Telegraph/Whetstone care
-- about. Returns one of:
--   'cast_start'      actor began casting; spell_id = first result param
--   'cast_interrupt'  actor's cast was interrupted (MagicStart with the
--                     spell group's interrupt FourCC)
--   'magic_finish'    spell landed/completed (also emitted by the
--                     server for some mob skill failure paths, with
--                     SkillInterrupt animation - see interrupts.cpp)
--   'ready_start'     actor is readying a TP move / WS (SkillStart +
--                     FourCC 'cate'); skill_id = first result param
--   'ready_interrupt' readying interrupted (SkillStart + FourCC 'spte')
--   'melee'           auto-attack round
--   'ws_finish'       SkillFinish (player WS or mob skill id < 256)
--   'mobskill_finish' MobSkillFinish (id >= 256)
--   'petskill_finish' PetSkillFinish
--   'ja_finish'       AbilityFinish
--   'ranged_finish'   RangedFinish
--   nil               anything else
-- The second return value is the relevant id (spell/skill/ability) when
-- the classification carries one.
function M.classify(action)
    if not action then
        return nil
    end

    local category = action.category
    local first = action.targets[1] and action.targets[1].results[1]

    if category == M.CATEGORY.MAGIC_START then
        if M.CAST_INTERRUPT_FOURCC[action.action_id] then
            return 'cast_interrupt', first and first.param or nil
        end

        if M.CAST_FOURCC[action.action_id] then
            return 'cast_start', first and first.param or nil
        end

        -- Unknown FourCC: a server fork could add a spell group. Treat
        -- as a start (display copes with unknown ids) - never crash.
        return 'cast_start', first and first.param or nil
    end

    if category == M.CATEGORY.MAGIC_FINISH then
        return 'magic_finish', action.action_id
    end

    if category == M.CATEGORY.SKILL_START then
        if action.action_id == M.FOURCC.SKILL_INTERRUPT then
            return 'ready_interrupt', nil
        end

        -- FourCC 'cate' (and anything unknown) = readying
        return 'ready_start', first and first.param or nil
    end

    if category == M.CATEGORY.MELEE then
        return 'melee', nil
    end

    if category == M.CATEGORY.WS_FINISH then
        return 'ws_finish', action.action_id
    end

    if category == M.CATEGORY.MOBSKILL_FINISH then
        return 'mobskill_finish', action.action_id
    end

    if category == M.CATEGORY.PETSKILL_FINISH then
        return 'petskill_finish', action.action_id
    end

    if category == M.CATEGORY.JA_FINISH then
        return 'ja_finish', action.action_id
    end

    if category == M.CATEGORY.RANGED_FINISH then
        return 'ranged_finish', nil
    end

    return nil
end

-- =====================================================================
-- 0x029 battle message parser
-- =====================================================================

-- GP_SERV_COMMAND_BATTLE_MESSAGE layout
-- (src/map/packets/s2c/0x029_battle_message.h, offsets include the
-- 4-byte FFXI header):
--   0x04 u32 UniqueNoCas   sender server id
--   0x08 u32 UniqueNoTar   target server id
--   0x0C u32 Data          param
--   0x10 u32 Data2         value
--   0x14 u16 ActIndexCas   0x16 u16 ActIndexTar
--   0x18 u16 MessageNum    0x1A u8 Type

local function u16(data, offset)
    return data:byte(offset + 1) + data:byte(offset + 2) * 256
end

local function u32(data, offset)
    return data:byte(offset + 1)
        + data:byte(offset + 2) * 256
        + data:byte(offset + 3) * 65536
        + data:byte(offset + 4) * 16777216
end

local function i32(data, offset)
    local value = u32(data, offset)

    if value >= 2147483648 then
        value = value - 4294967296
    end

    return value
end

function M.parse_battle_message(data)
    if #data < 0x1B then
        return nil
    end

    return
    {
        sender_id  = u32(data, 0x04),
        target_id  = u32(data, 0x08),
        param      = i32(data, 0x0C),
        value      = i32(data, 0x10),
        sender_idx = u16(data, 0x14),
        target_idx = u16(data, 0x16),
        message_id = u16(data, 0x18),
    }
end

-- Mob death arrives on 0x029 (mobentity.cpp OnDeath pushes
-- DefeatsTarget = 6 "<player> defeats <target>" and FallsToGround =
-- 20 "<target> falls to the ground", both with UniqueNoTar = the
-- dying mob). FFXI recycles server ids onto respawns, so a death
-- message is the signal to evict everything keyed on that id.
M.DEATH_MESSAGES = { [6] = true, [20] = true }

return M
