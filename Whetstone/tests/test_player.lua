--[[
    Tests for the pure-Lua parts of player.lua (packet parsing, buff
    haste classification, gear aggregation).

    Runs under busted or plain Lua 5.1+:
        lua5.1 Whetstone/tests/test_player.lua

    The 0x061 fixture below is built byte-by-byte against the layout in
    Phoenix src/map/packets/s2c/0x061_clistatus.h; expected values are
    the ones written into the fixture, exercising little-endian and
    signed-int16 decoding (negative stat bonus).
]]

-- ---------------------------------------------------------------------
-- Minimal busted shim (same as test_formulas.lua)
-- ---------------------------------------------------------------------
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

        near = function(expected, actual, tolerance, msg)
            if type(actual) ~= 'number' or math.abs(expected - actual) > tolerance then
                error((msg or 'assert.near') ..
                    ': expected ' .. tostring(expected) ..
                    ' +/- ' .. tostring(tolerance) ..
                    ', got ' .. tostring(actual), 2)
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

local P = require('player')
local F = require('formulas')

-- ---------------------------------------------------------------------
-- 0x061 fixture builder
-- ---------------------------------------------------------------------

local function le16(value)
    if value < 0 then
        value = value + 0x10000
    end

    return string.char(value % 256, math.floor(value / 256) % 256)
end

local function le32(value)
    return le16(value % 65536) .. le16(math.floor(value / 65536))
end

local function build_char_stats_packet()
    local parts =
    {
        string.char(0x61, 0x30, 0x00, 0x00), -- header (id, size, sync)
        le32(1250),                          -- 0x04 hpmax
        le32(780),                           -- 0x08 mpmax
        string.char(1, 75, 13, 37),          -- 0x0C WAR75 / NIN37
        le16(5000), le16(44000),             -- 0x10 exp / exp next
        -- 0x14 bp_base[7]: STR DEX VIT AGI INT MND CHR
        le16(70), le16(65), le16(60), le16(55), le16(50), le16(45), le16(40),
        -- 0x22 bp_adj[7] (signed; DEX bonus is negative)
        le16(12), le16(-3), le16(5), le16(0), le16(1), le16(2), le16(3),
        le16(420),                           -- 0x30 atk
        le16(310),                           -- 0x32 def
        le16(0),                             -- padding past minimum size
    }

    return table.concat(parts)
end

-- =====================================================================
describe('char stats packet (0x061)', function()
    local parsed = P.parse_char_stats(build_char_stats_packet())

    it('parses jobs, levels and pools', function()
        assert.are.equal(1250, parsed.max_hp)
        assert.are.equal(780, parsed.max_mp)
        assert.are.equal(1, parsed.main_job)
        assert.are.equal(75, parsed.main_level)
        assert.are.equal(13, parsed.sub_job)
        assert.are.equal(37, parsed.sub_level)
    end)

    it('parses attack and defense', function()
        assert.are.equal(420, parsed.attack)
        assert.are.equal(310, parsed.defense)
    end)

    it('sums base stats and signed bonuses', function()
        assert.are.equal(82, parsed.stats.str)  -- 70 + 12
        assert.are.equal(62, parsed.stats.dex)  -- 65 + (-3), signed i16
        assert.are.equal(65, parsed.stats.vit)
        assert.are.equal(55, parsed.stats.agi)
        assert.are.equal(43, parsed.stats.chr)
        assert.are.equal(-3, parsed.stat_bonus.dex)
    end)

    it('rejects truncated packets', function()
        assert.is_nil(P.parse_char_stats(string.char(0x61, 8, 0, 0, 1, 2, 3, 4)))
    end)
end)

-- ---------------------------------------------------------------------
-- 0x062 fixture: 4-byte header + 31 u32 recasts + u16 skill_base[64]
-- ---------------------------------------------------------------------

local function build_char_skills_packet()
    local parts = { string.char(0x62, 0x00, 0x00, 0x00) }

    for _ = 1, 31 do
        parts[#parts + 1] = le32(0) -- recasts, skipped by the parser
    end

    local skills = {}
    for id = 0, 63 do
        skills[id] = 0
    end

    skills[6]  = 269 + 0x8000 -- great axe 269, capped flag set
    skills[5]  = 240          -- axe 240, not capped
    skills[29] = 230 + 0x8000 -- evasion 230, capped

    for id = 0, 63 do
        parts[#parts + 1] = le16(skills[id])
    end

    return table.concat(parts)
end

describe('char skills packet (0x062)', function()
    local parsed = P.parse_char_skills(build_char_skills_packet())

    it('reads skill values from offset 0x80 by SKILLTYPE id', function()
        assert.are.equal(269, parsed.by_name.great_axe.value)
        assert.are.equal(240, parsed.by_name.axe.value)
        assert.are.equal(230, parsed.by_name.evasion.value)
        assert.are.equal(0, parsed.by_name.dagger.value)
    end)

    it('separates the 0x8000 capped flag from the value', function()
        assert.is_true(parsed.by_name.great_axe.capped)
        assert.is_false(parsed.by_name.axe.capped)
        assert.is_true(parsed.by_name.evasion.capped)
    end)

    it('rejects truncated packets', function()
        assert.is_nil(P.parse_char_skills(string.char(0x62, 8, 0, 0, 1, 2)))
    end)
end)

-- =====================================================================
describe('haste from buffs', function()
    it('sums magic haste per buff instance and flags it estimated', function()
        -- Haste (0.1465 exact-by-source) + double March (estimated)
        local h = P.haste_from_buffs({ 33, 214, 214 })

        assert.near(0.3965, h.magic, 1e-12)
        assert.is_true(h.estimated)
        assert.are.equal(3, #h.sources)
    end)

    it('keeps Hasso separate as 2H-only ability haste (exact)', function()
        local h = P.haste_from_buffs({ 353 })

        assert.near(0.10, h.two_hand_ability, 1e-12)
        assert.near(0, h.ability, 1e-12)
        -- Hasso is a fixed 10%: nothing estimated here
        assert.is_false(h.estimated)
    end)

    it('treats Haste Samba as estimated ability haste', function()
        local h = P.haste_from_buffs({ 370 })

        assert.near(0.05, h.ability, 1e-12)
        assert.is_true(h.estimated)
    end)

    it('counts slows as negative magic haste', function()
        local h = P.haste_from_buffs({ 33, 13 })

        assert.near(0, h.magic, 1e-12) -- 0.1465 - 0.1465
    end)

    it('treats Haste alone as exact (power fixed at skill cap in source)', function()
        local h = P.haste_from_buffs({ 33 })

        assert.near(0.1465, h.magic, 1e-12)
        assert.is_false(h.estimated)
    end)

    it('treats merit-dependent Last Resort as estimated 2H haste', function()
        local h = P.haste_from_buffs({ 64 })

        assert.near(0.25, h.two_hand_ability, 1e-12)
        assert.is_true(h.estimated)
    end)

    it('honors user-configured magnitudes and clears the estimate flag', function()
        -- Player knows their bard: March at 14.06% (144/1024)
        local h = P.haste_from_buffs({ 214 }, { [214] = 0.140625 })

        assert.near(0.140625, h.magic, 1e-12)
        assert.is_false(h.estimated)
    end)

    it('detects Hundred Fists', function()
        assert.is_true(P.haste_from_buffs({ 46 }).hundred_fists)
    end)
end)

-- =====================================================================
local ITEM_DB =
{
    [15457] = { name = 'swift_belt', level = 50, jobs = 4194303, slots = 1024,
                mods = { haste = 400, acc = 3, att = -5 },
                latent_mods = { 'acc', 'racc' } },
    [12701] = { name = 'dusk_gloves', level = 72, jobs = 4194303, slots = 64,
                mods = { haste = 300, att = 5 } },
    [12555] = { name = 'haubergeon', level = 59, jobs = 4194303, slots = 32,
                mods = { acc = 10, att = 10, str = 5, dex = 5, eva = -20 } },
    [17559] = { name = 'fixture_axe', level = 60, jobs = 129, slots = 3,
                mods = { str = 4, double_attack = 5 },
                weapon = { skill = 'axe', dmg = 48, delay = 276,
                           dmg_type = 3, hit_count = 1 } },
}

describe('gear stats', function()
    local equipment =
    {
        [0]  = 17559, -- main
        [5]  = 12555, -- body
        [6]  = 12701, -- hands
        [10] = 15457, -- waist
    }

    local gear = P.gear_stats(equipment, ITEM_DB)

    it('computes exact gear haste from the item DB', function()
        -- 400 + 300 = 700 / 10000
        assert.are.equal(700, gear.haste_raw)
        assert.near(0.07, gear.haste, 1e-12)
    end)

    it('sums whitelisted mods across pieces', function()
        assert.are.equal(10, gear.att)  -- -5 + 5 + 10
        assert.are.equal(13, gear.acc)  -- 3 + 10
        assert.are.equal(9, gear.str)   -- 5 + 4
        assert.are.equal(5, gear.double_attack)
        assert.are.equal(-20, gear.eva)
    end)

    it('exposes the mainhand weapon', function()
        assert.are.equal('axe', gear.main.weapon.skill)
        assert.are.equal(48, gear.main.weapon.dmg)
    end)

    it('skips empty slots and unknown items', function()
        local sparse = P.gear_stats({ [0] = 99999, [4] = 0 }, ITEM_DB)

        assert.are.equal(0, #sparse.pieces)
        assert.are.equal(0, sparse.haste_raw)
    end)

    it('surfaces latent flags on pieces without summing them', function()
        local belt

        for _, piece in ipairs(gear.pieces) do
            if piece.name == 'swift_belt' then
                belt = piece
            else
                assert.is_nil(piece.latent_mods)
            end
        end

        assert.are.equal('acc', belt.latent_mods[1])
        assert.are.equal('racc', belt.latent_mods[2])
        -- the conditional acc never reaches the summed total
        assert.are.equal(13, gear.acc)
    end)
end)

-- =====================================================================
describe('haste report integration', function()
    it('combines estimated magic with exact gear through formulas.haste', function()
        local report = P.haste_report(
        {
            buffs      = { 33, 214, 214, 353 }, -- 39.65% magic + Hasso
            equipment  = { [10] = 15457, [6] = 12701 }, -- 7% gear
            item_db    = ITEM_DB,
            two_handed = true,
        }, F)

        -- magic 0.3965 (under the 0.4375 cap), ability 0.10, gear 0.07
        assert.near(1 - 0.3965 - 0.10 - 0.07, report.multiplier, 1e-12)
        assert.is_true(report.magic_estimated)
        assert.is_true(report.gear_exact)
    end)

    it('reports gear overcap exactly', function()
        -- 3 fictional 10% pieces = 30% gear -> 25% cap, 5% wasted
        local db =
        {
            [1] = { name = 'a', mods = { haste = 1000 } },
            [2] = { name = 'b', mods = { haste = 1000 } },
            [3] = { name = 'c', mods = { haste = 1000 } },
        }

        local report = P.haste_report(
        {
            equipment = { [4] = 1, [5] = 2, [6] = 3 },
            item_db   = db,
        }, F)

        assert.near(0.25, report.gear, 1e-12)
        assert.near(0.05, report.gear_overcap, 1e-12)
        assert.is_false(report.magic_estimated)
    end)
end)

if WHETSTONE_TEST_SUMMARY then
    WHETSTONE_TEST_SUMMARY()
end
