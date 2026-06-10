--[[
    Whetstone - player.lua

    Player state: stats from packet 0x061, equipment from the Ashita
    inventory manager, haste from buff IDs + the generated item DB.

    Precision model (deliberate, see README):
      - GEAR haste is EXACT: equipped item IDs are joined against the
        generated data/items.lua (Phoenix item_mods, Mod 384,
        10000-based), so the "gear haste overcap" advice is precise.
      - MAGIC haste is ESTIMATED: a buff ID does not carry magnitude
        (March potency depends on the bard's instruments, etc.), so
        magic haste uses the defaults below and is flagged
        `estimated = true` everywhere it surfaces.
      - ABILITY haste: Hasso is a fixed, known 10% (2H only); Haste
        Samba magnitude depends on the dancer's gear -> estimated.

    Everything except the `ashita` block at the bottom is pure Lua and
    unit-tested (tests/test_player.lua).

    Packet 0x061 layout from Phoenix
    src/map/packets/s2c/0x061_clistatus.h (offsets include the 4-byte
    packet header):
      0x04 i32 hpmax        0x08 i32 mpmax
      0x0C u8  mjob         0x0D u8  mjob_lv
      0x0E u8  sjob         0x0F u8  sjob_lv
      0x10 i16 exp_now      0x12 i16 exp_next
      0x14 u16 bp_base[7]   0x22 i16 bp_adj[7]
      0x30 i16 atk          0x32 i16 def
]]

local M = {}

local floor = math.floor

-- =====================================================================
-- Little-endian byte readers (offsets are 0-based, like the packet docs)
-- =====================================================================

local function u8(data, offset)
    return data:byte(offset + 1)
end

local function u16(data, offset)
    return data:byte(offset + 1) + data:byte(offset + 2) * 256
end

local function i16(data, offset)
    local value = u16(data, offset)

    if value >= 0x8000 then
        value = value - 0x10000
    end

    return value
end

local function u32(data, offset)
    return u16(data, offset) + u16(data, offset + 2) * 65536
end

local function i32(data, offset)
    local value = u32(data, offset)

    if value >= 0x80000000 then
        value = value - 0x100000000
    end

    return value
end

M.PACKET_CHAR_STATS  = 0x061
M.PACKET_CHAR_SKILLS = 0x062

local STAT_KEYS = { 'str', 'dex', 'vit', 'agi', 'int', 'mnd', 'chr' }

-- SKILLTYPE ids (src/common/mmo.h) for the combat skills the advisor
-- needs; 0x062 carries u16[64] indexed by this id.
M.COMBAT_SKILL_IDS =
{
    hand_to_hand = 1,  dagger = 2,        sword = 3,
    great_sword  = 4,  axe = 5,           great_axe = 6,
    scythe       = 7,  polearm = 8,       katana = 9,
    great_katana = 10, club = 11,         staff = 12,
    archery      = 25, marksmanship = 26, throwing = 27,
    guard        = 28, evasion = 29,      shield = 30, parry = 31,
}

-- Parse a full 0x061 packet (including the 4-byte header).
-- Returns nil if the payload is too short to contain atk/def.
function M.parse_char_stats(data)
    if #data < 0x34 then
        return nil
    end

    local result =
    {
        max_hp     = i32(data, 0x04),
        max_mp     = i32(data, 0x08),
        main_job   = u8(data, 0x0C),
        main_level = u8(data, 0x0D),
        sub_job    = u8(data, 0x0E),
        sub_level  = u8(data, 0x0F),
        attack     = i16(data, 0x30),
        defense    = i16(data, 0x32),
        stats      = {},
        base_stats = {},
        stat_bonus = {},
    }

    for index, key in ipairs(STAT_KEYS) do
        local base  = u16(data, 0x14 + (index - 1) * 2)
        local bonus = i16(data, 0x22 + (index - 1) * 2)

        result.base_stats[key] = base
        result.stat_bonus[key] = bonus
        result.stats[key]      = base + bonus
    end

    return result
end

-- Parse a full 0x062 packet (Char Skills / CLISTATUS2).
-- Layout (Phoenix src/map/packets/s2c/0x062_clistatus2.h, offsets
-- include the 4-byte header):
--   0x04 u32 CommandRecast[31]   (ability recasts, skipped)
--   0x80 u16 skill_base[64]      indexed by SKILLTYPE id; the high bit
--                                (0x8000) flags the skill as capped
--                                (blue in the client), low 15 bits are
--                                the actual value.
-- Returns { by_name = { hand_to_hand = { value, capped }, ... } } or
-- nil when truncated.
function M.parse_char_skills(data)
    local base = 0x80

    if #data < base + 2 then
        return nil
    end

    local result = { by_name = {} }

    for name, id in pairs(M.COMBAT_SKILL_IDS) do
        local offset = base + id * 2

        if #data >= offset + 2 then
            local raw = u16(data, offset)

            result.by_name[name] =
            {
                value  = raw % 0x8000,
                capped = raw >= 0x8000,
            }
        end
    end

    return result
end

-- =====================================================================
-- Buff-based haste (magic estimated, see header)
-- =====================================================================

-- Effect IDs from Phoenix src/map/status_effect.h.
-- amount: fraction per buff INSTANCE (March can appear twice).
--
-- Magnitudes audited against Phoenix source (@ 0f3f8fc):
--   Haste  scripts/globals/spells/enhancing_spell.lua: power caps at
--          1465/10000 (= 150/1024). The 75-era norm is a capped-skill
--          caster, so this is EXACT-BY-SOURCE; a heavily underskilled
--          caster lands lower (override if it ever matters).
--   Hasso  modules/abyssea/lua/job_adjustments.lua (enabled): fixed
--          TWOHAND_HASTE_ABILITY 1000 -> exactly 10%.
--   Elegy  scripts/globals/spells/enfeebling_song.lua: FIXED powers,
--          but Battlefield (2500) and Carnage (5000) share effect 194
--          -> ambiguous from the buff ID; defaults to Carnage.
--   Slow   white-magic Slow is dMND-scaled; Hojo: Ichi/Ni are fixed
--          1465/1953 but all share effect 13 -> estimated.
--   March  power = base + singing skill + instrument mods
--          (enhancing_song.lua) -> genuinely caster-dependent.
--   Last Resort  modules/soa/lua/job_adjustments.lua (enabled): 2H
--          haste equal to the DRK's Desperate Blows merits; default
--          assumes 5/5 (25%), zero without merits.
M.BUFFS =
{
    [33]  = { name = 'Haste',       category = 'magic',   amount = 0.1465,  estimated = false },
    [214] = { name = 'March',       category = 'magic',   amount = 0.125,   estimated = true },
    [13]  = { name = 'Slow',        category = 'magic',   amount = -0.1465, estimated = true },
    [194] = { name = 'Elegy',       category = 'magic',   amount = -0.50,   estimated = true },
    [353] = { name = 'Hasso',       category = 'ability', amount = 0.10,    estimated = false, two_hand_only = true },
    [370] = { name = 'Haste Samba', category = 'ability', amount = 0.05,    estimated = true },
    [64]  = { name = 'Last Resort', category = 'ability', amount = 0.25,    estimated = true,  two_hand_only = true },
}

M.BUFF_HUNDRED_FISTS = 46

-- buff_ids: array of active status effect IDs (duplicates count - two
-- Marches are two instances).
-- overrides: optional { [buff_id] = amount } user-configured magnitudes
-- (e.g. the player knows their bard's March potency).
-- Returns:
--   magic, ability       summed fractions (ability EXCLUDES 2H-only)
--   two_hand_ability     Hasso-style haste, apply only when 2H
--   estimated            true if any contributing amount was a default
--   hundred_fists        bool
--   sources              { { name, category, amount, estimated }, ... }
function M.haste_from_buffs(buff_ids, overrides)
    overrides = overrides or {}

    local result =
    {
        magic            = 0,
        ability          = 0,
        two_hand_ability = 0,
        estimated        = false,
        hundred_fists    = false,
        sources          = {},
    }

    for _, id in ipairs(buff_ids) do
        if id == M.BUFF_HUNDRED_FISTS then
            result.hundred_fists = true
        end

        local buff = M.BUFFS[id]

        if buff then
            local amount = overrides[id] or buff.amount
            local estimated = buff.estimated and overrides[id] == nil

            if buff.category == 'magic' then
                result.magic = result.magic + amount
            elseif buff.two_hand_only then
                result.two_hand_ability = result.two_hand_ability + amount
            else
                result.ability = result.ability + amount
            end

            result.estimated = result.estimated or estimated

            result.sources[#result.sources + 1] =
            {
                name      = buff.name,
                category  = buff.category,
                amount    = amount,
                estimated = estimated,
            }
        end
    end

    return result
end

-- =====================================================================
-- Equipment (exact, via the generated item DB)
-- =====================================================================

M.SLOT_NAMES =
{
    [0] = 'main', [1] = 'sub', [2] = 'ranged', [3] = 'ammo',
    [4] = 'head', [5] = 'body', [6] = 'hands', [7] = 'legs',
    [8] = 'feet', [9] = 'neck', [10] = 'waist', [11] = 'ear1',
    [12] = 'ear2', [13] = 'ring1', [14] = 'ring2', [15] = 'back',
}

local SUMMED_MODS =
{
    'str', 'dex', 'vit', 'agi', 'int', 'mnd', 'chr',
    'att', 'ratt', 'acc', 'racc', 'attp', 'eva',
    'store_tp', 'crit_rate', 'double_attack', 'triple_attack',
    'dual_wield', 'martial_arts', 'subtle_blow', 'delay_p',
}

-- equipment: { [slot_id 0..15] = item_id } (0/nil = empty)
-- item_db:   generated data/items.lua table
-- Returns totals across all equipped items:
--   haste        EXACT gear haste fraction (Mod 384 sum / 10000)
--   haste_raw    the 10000-based sum
--   <mod>        sums for each whitelisted mod key
--   main/sub     { id, name, weapon = {...} } for the weapon slots
--   pieces       { { slot, id, name, haste }, ... } (equipped only)
function M.gear_stats(equipment, item_db)
    local totals = { haste = 0, haste_raw = 0, pieces = {} }

    for _, key in ipairs(SUMMED_MODS) do
        totals[key] = 0
    end

    for slot = 0, 15 do
        local item_id = equipment[slot]
        local item = item_id and item_id ~= 0 and item_db[item_id] or nil

        if item then
            local mods = item.mods or {}

            totals.haste_raw = totals.haste_raw + (mods.haste or 0)

            for _, key in ipairs(SUMMED_MODS) do
                if mods[key] then
                    totals[key] = totals[key] + mods[key]
                end
            end

            if slot == 0 then
                totals.main = { id = item_id, name = item.name,
                                weapon = item.weapon }
            elseif slot == 1 then
                totals.sub = { id = item_id, name = item.name,
                               weapon = item.weapon,
                               shield_size = item.shield_size }
            end

            totals.pieces[#totals.pieces + 1] =
            {
                slot  = M.SLOT_NAMES[slot],
                id    = item_id,
                name  = item.name,
                haste = (mods.haste or 0) / 10000,
            }
        end
    end

    totals.haste = totals.haste_raw / 10000

    return totals
end

-- =====================================================================
-- Combined haste report (feeds formulas.haste)
-- =====================================================================

-- p: { buffs = {...ids}, equipment = {...}, item_db = t,
--     two_handed = bool, overrides = {...}, profile = ... }
-- Returns formulas.haste() result plus:
--   gear_exact = true, magic_estimated, sources, hundred_fists
function M.haste_report(p, formulas)
    formulas = formulas or require('formulas')

    local from_buffs = M.haste_from_buffs(p.buffs or {}, p.overrides)
    local gear = M.gear_stats(p.equipment or {}, p.item_db or {})

    local report = formulas.haste(
    {
        magic            = from_buffs.magic,
        ability          = from_buffs.ability,
        two_hand_ability = from_buffs.two_hand_ability,
        two_handed       = p.two_handed,
        gear             = gear.haste,
        profile          = p.profile,
    })

    report.gear_exact      = true
    report.magic_estimated = from_buffs.estimated
    report.hundred_fists   = from_buffs.hundred_fists
    report.sources         = from_buffs.sources

    return report
end

-- =====================================================================
-- Ashita v4 glue (inactive outside the game; everything above is pure)
-- =====================================================================

M.state =
{
    char_stats = nil, -- last parsed 0x061
    skills     = nil, -- last parsed 0x062
    equipment  = {},  -- slot id -> item id
    buffs      = {},  -- active buff id array
}

local function read_equipment_ashita()
    local inventory = AshitaCore:GetMemoryManager():GetInventory()
    local equipment = {}

    for slot = 0, 15 do
        local entry = inventory:GetEquippedItem(slot)

        if entry and entry.Index ~= 0 then
            -- Index packs container in the high byte, index in the low.
            local container = floor(entry.Index / 256)
            local index = entry.Index % 256
            local item = inventory:GetContainerItem(container, index)

            equipment[slot] = item and item.Id or nil
        end
    end

    return equipment
end

local function read_buffs_ashita()
    local player = AshitaCore:GetMemoryManager():GetPlayer()
    local buffs = {}

    for index = 0, 31 do
        local id = player:GetBuffs()[index + 1]

        if id and id > 0 then
            buffs[#buffs + 1] = id
        end
    end

    return buffs
end

-- Call once from the addon bootstrap (whetstone.lua). Safe to require
-- this module without Ashita present; attach() is the only entry point
-- that touches Ashita APIs.
function M.attach(addon_name)
    ashita.events.register('packet_in', addon_name .. '_player_packet_in',
        function(event)
            if event.id == M.PACKET_CHAR_STATS then
                local parsed = M.parse_char_stats(event.data)

                if parsed then
                    M.state.char_stats = parsed
                end
            elseif event.id == M.PACKET_CHAR_SKILLS then
                local parsed = M.parse_char_skills(event.data)

                if parsed then
                    M.state.skills = parsed
                end
            end
        end)

    function M.refresh()
        local ok_equipment, equipment = pcall(read_equipment_ashita)
        local ok_buffs, buffs = pcall(read_buffs_ashita)

        if ok_equipment then
            M.state.equipment = equipment
        end

        if ok_buffs then
            M.state.buffs = buffs
        end

        return M.state
    end
end

return M
