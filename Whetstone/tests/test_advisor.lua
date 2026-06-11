--[[
    Tests for advisor.lua: WS param routing (the atkVaries/fTP trap),
    mob candidate disambiguation, and ranked delta lines.

    Runs under busted or plain Lua 5.1+:
        lua5.1 Whetstone/tests/test_advisor.lua
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

        is_not_nil = function(value, msg)
            if value == nil then
                error((msg or 'assert.is_not_nil') .. ': got nil', 2)
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

        not_near = function(unexpected, actual, tolerance, msg)
            if type(actual) == 'number'
                and math.abs(unexpected - actual) <= tolerance then
                error((msg or 'assert.not_near') ..
                    ': value ' .. tostring(actual) ..
                    ' unexpectedly within ' .. tostring(tolerance) ..
                    ' of ' .. tostring(unexpected), 2)
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

local A = require('advisor')
local F = require('formulas')

-- ---------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------

local MOB_DB =
{
    [103] =
    {
        ['Test Crab'] =
        {
            -- candidate A: a level band. Level 21's eva (305) is
            -- deliberately NOT the 20/22 midpoint: the lookup must be
            -- exact, never interpolated.
            { group = 1, pool = 10, min_level = 20, max_level = 22,
              mjob = 'WAR', sjob = 'NON', family = 'Crab', nm = false,
              levels =
              {
                  [20] = { vit = 20, agi = 20, def = 80, eva = 300 },
                  [21] = { vit = 21, agi = 21, def = 84, eva = 305 },
                  [22] = { vit = 22, agi = 22, def = 86, eva = 306 },
              } },
            -- candidate B: a different, higher spawn with the same name
            { group = 2, pool = 11, min_level = 25, max_level = 25,
              mjob = 'WAR', sjob = 'NON', family = 'Crab', nm = false,
              levels =
              {
                  [25] = { vit = 30, agi = 30, def = 300, eva = 350 },
              } },
        },
    },
}

local WS_DB =
{
    -- pure fTP weapon skill
    heavy_strike =
    {
        id = 1, skill = 'great_axe', skill_level = 5, element = 0,
        kind = 'physical', source = 'wotg_module', main_only = false,
        unlock_id = 0, jobs = { 'WAR' }, sc = {},
        params = { numHits = 1, ftpMod = { 2.0, 2.0, 2.0 }, str_wsc = 0.5 },
    },
    -- "attack varies": same numbers, but routed through pDIF
    true_strike =
    {
        id = 2, skill = 'great_axe', skill_level = 5, element = 0,
        kind = 'physical', source = 'wotg_module', main_only = false,
        unlock_id = 0, jobs = { 'WAR' }, sc = {},
        params = { numHits = 1, ftpMod = { 1.0, 1.0, 1.0 },
                   atkVaries = { 2.0, 2.0, 2.0 }, str_wsc = 0.5 },
    },
    -- excluded: wrong weapon
    sword_ws =
    {
        id = 3, skill = 'sword', skill_level = 5, element = 0,
        kind = 'physical', source = 'base_script', main_only = false,
        unlock_id = 0, jobs = { 'WAR' }, sc = {},
        params = { numHits = 1, ftpMod = { 1.0, 1.0, 1.0 } },
    },
    -- excluded: special (MP drain style)
    drainer =
    {
        id = 4, skill = 'great_axe', skill_level = 5, element = 0,
        kind = 'special', source = 'wotg_module', main_only = false,
        unlock_id = 0, jobs = { 'WAR' }, sc = {},
        params = {},
    },
    -- quest-locked (unlock_id > 0): excluded unless toggled on
    quest_strike =
    {
        id = 6, skill = 'great_axe', skill_level = 240, element = 0,
        kind = 'physical', source = 'wotg_module', main_only = false,
        unlock_id = 10, jobs = { 'WAR' }, sc = {},
        params = { numHits = 1, ftpMod = { 3.0, 3.0, 3.0 }, str_wsc = 0.5 },
    },
    -- above the fixture player's combat skill when ws_skill is given
    high_skill_strike =
    {
        id = 7, skill = 'great_axe', skill_level = 250, element = 0,
        kind = 'physical', source = 'wotg_module', main_only = false,
        unlock_id = 0, jobs = { 'WAR' }, sc = {},
        params = { numHits = 1, ftpMod = { 1.5, 1.5, 1.5 }, str_wsc = 0.5 },
    },
    -- excluded: dynamic transcript value
    weird_ws =
    {
        id = 5, skill = 'great_axe', skill_level = 5, element = 0,
        kind = 'physical', source = 'base_script', main_only = false,
        unlock_id = 0, jobs = { 'WAR' }, sc = {},
        params = { numHits = 1,
                   ftpMod = "<dynamic: player:getMod(xi.mod.X)>" },
    },
}

local PLAYER =
{
    level     = 75,
    main_job  = 'WAR',
    stats     = { str = 80, dex = 70, vit = 60, agi = 50,
                  int = 40, mnd = 40, chr = 40 },
    attack    = 400,
    accuracy  = 300,
    weapon    = { dmg = 81, delay = 504, skill = 'great_axe' },
}

local function evaluate(overrides)
    local p =
    {
        player = PLAYER,
        target = { zone = 103, name = 'Test Crab' },
        data   = { mobs = MOB_DB, ws = WS_DB },
        tp     = 1000,
    }

    for key, value in pairs(overrides or {}) do
        p[key] = value
    end

    return A.evaluate(p)
end

-- =====================================================================
describe('WS param adapter', function()
    it('routes atkVaries to pDIF and ftpMod to fTP - never merged', function()
        local ws = A.adapt_ws_params(WS_DB.true_strike)

        assert.are.equal(WS_DB.true_strike.params.atkVaries, ws.atk_varies)
        assert.are.equal(WS_DB.true_strike.params.ftpMod, ws.ftp)
        assert.are.equal(1, ws.num_hits)
        assert.near(0.5, ws.mods.str, 1e-12)
    end)

    it('rejects non-physical and dynamic entries', function()
        assert.is_nil(A.adapt_ws_params(WS_DB.drainer))
        assert.is_nil(A.adapt_ws_params(WS_DB.weird_ws))
    end)
end)

describe('apples-to-apples guard', function()
    -- The same scenario evaluated three ways:
    --   correct: ftp 1.0, atk_varies 2.0  (server semantics)
    --   blurred: ftp 2.0, no atk mod      (wiki-style conflation)
    -- The advisor's number must equal the correct one and differ from
    -- the blurred one.
    local base =
    {
        weapon_dmg = 81, fstr = 13.5, stats = PLAYER.stats,
        tp = 1000, attack = 400, defense = 300, acc = 300, eva = 350,
        attacker_level = 75, target_level = 25,
        weapon = 'great_axe', two_handed = true,
        target_agi = 30,
    }

    local function ws_damage(ws)
        local p = { ws = ws }

        for key, value in pairs(base) do
            p[key] = value
        end

        return F.ws_damage(p).expected
    end

    it('advisor matches the server-routed computation exactly', function()
        local report = evaluate({ target = { zone = 103,
                                             name = 'Test Crab' } })

        local true_strike
        for _, ws in ipairs(report.ws) do
            if ws.name == 'true_strike' then
                true_strike = ws
            end
        end

        local correct = ws_damage(
        {
            ftp = { 1.0, 1.0, 1.0 },
            atk_varies = { 2.0, 2.0, 2.0 },
            num_hits = 1,
            mods = { str = 0.5 },
        })

        -- worst candidate point is B (Lv.25, def 300, eva 350): same
        -- inputs as `base` above
        assert.near(correct, true_strike.expected, 1e-9)
    end)

    it('differs from the wiki-blurred version', function()
        local correct = ws_damage(
        {
            ftp = { 1.0, 1.0, 1.0 },
            atk_varies = { 2.0, 2.0, 2.0 },
            num_hits = 1,
            mods = { str = 0.5 },
        })
        local blurred = ws_damage(
        {
            ftp = { 2.0, 2.0, 2.0 },
            num_hits = 1,
            mods = { str = 0.5 },
        })

        -- attack 400 vs def 300 at the Phoenix 2.0 cap: doubling
        -- attack saturates pDIF, doubling fTP doubles damage - very
        -- different numbers.
        assert.not_near(correct, blurred, correct * 0.10)
    end)
end)

-- =====================================================================
describe('WS availability gate (CanUseWeaponskill, the final_heaven hole)', function()
    -- Era H2H ladder straight from Phoenix weapon_skills.sql:
    --   combo            skilllevel 5    jobs incl. MNK
    --   shoulder_tackle  skilllevel 40   jobs incl. MNK
    --   raging_fists     skilllevel 125  jobs MNK/PUP
    --   asuran_fists     skilllevel 250  unlock_id 1 (quest), main_only
    --   final_heaven     skilllevel 0    jobs EMPTY, main_only (relic:
    --                    granted only by Spharai's ADDS_WEAPONSKILL)
    local H2H_LADDER =
    {
        combo = { id = 1, skill = 'hand_to_hand', skill_level = 5,
                  unlock_id = 0, main_only = false,
                  jobs = { 'WAR', 'MNK', 'THF', 'NIN', 'PUP', 'DNC' } },
        shoulder_tackle = { id = 2, skill = 'hand_to_hand',
                  skill_level = 40, unlock_id = 0, main_only = false,
                  jobs = { 'WAR', 'MNK', 'THF', 'NIN', 'PUP', 'DNC' } },
        raging_fists = { id = 5, skill = 'hand_to_hand',
                  skill_level = 125, unlock_id = 0, main_only = false,
                  jobs = { 'MNK', 'PUP' } },
        asuran_fists = { id = 9, skill = 'hand_to_hand',
                  skill_level = 250, unlock_id = 1, main_only = true,
                  jobs = { 'MNK', 'PUP' } },
        final_heaven = { id = 10, skill = 'hand_to_hand',
                  skill_level = 0, unlock_id = 0, main_only = true,
                  jobs = {} },
    }

    local function available(player, assume_quest)
        local names = {}

        for name, entry in pairs(H2H_LADDER) do
            if A.ws_usable(entry, player, assume_quest) then
                names[#names + 1] = name
            end
        end

        table.sort(names)
        return table.concat(names, ',')
    end

    it('a barehanded MNK 9 gets exactly Combo', function()
        -- MNK 9 era H2H skill cap = 27: only combo (5) is reachable;
        -- final_heaven must NOT appear (the live bug)
        local mnk9 = { level = 9, main_job = 'MNK', ws_skill = 27,
                       weapon = { skill = 'hand_to_hand' } }

        assert.are.equal('combo', available(mnk9, false))
    end)

    it('skill 40 adds Shoulder Tackle; 125 adds Raging Fists', function()
        local mnk13 = { level = 13, main_job = 'MNK', ws_skill = 40,
                        weapon = {} }

        assert.are.equal('combo,shoulder_tackle', available(mnk13, false))

        local mnk41 = { level = 41, main_job = 'MNK', ws_skill = 125,
                        weapon = {} }

        assert.are.equal('combo,raging_fists,shoulder_tackle',
            available(mnk41, false))
    end)

    it('quest WS needs the toggle; relic stays locked regardless', function()
        local mnk75 = { level = 75, main_job = 'MNK', ws_skill = 269,
                        weapon = {} }

        assert.are.equal('combo,raging_fists,shoulder_tackle',
            available(mnk75, false))
        assert.are.equal('asuran_fists,combo,raging_fists,shoulder_tackle',
            available(mnk75, true))
    end)

    it('the relic weapon itself grants its WS via ADDS_WEAPONSKILL', function()
        local with_spharai = { level = 75, main_job = 'MNK',
                               ws_skill = 269,
                               weapon = { skill = 'hand_to_hand',
                                          adds_weaponskill = 10 } }

        assert.is_true(A.ws_usable(H2H_LADDER.final_heaven,
                                   with_spharai, false))
    end)

    it('sub job qualifies unless the WS is main-only', function()
        local war_mnk = { level = 41, main_job = 'WAR', sub_job = 'MNK',
                          ws_skill = 125, weapon = {} }

        -- raging_fists (MNK/PUP, not main-only) via the MNK sub
        assert.is_true(A.ws_usable(H2H_LADDER.raging_fists,
                                   war_mnk, false))
        -- asuran_fists is main-only: the sub never qualifies
        assert.is_false(A.ws_usable(H2H_LADDER.asuran_fists,
                                    war_mnk, true))
    end)

    it('an empty jobs list means NOBODY, not everybody', function()
        local anyone = { level = 75, main_job = 'MNK', ws_skill = 999,
                         weapon = {} }

        assert.is_false(A.ws_usable(H2H_LADDER.final_heaven,
                                    anyone, true))
    end)
end)

-- =====================================================================
describe('barehanded MNK (unarmed H2H pseudo-weapon)', function()
    -- Field bug (HorizonXI v0.1.3): an empty MNK main slot dead-ended
    -- in S2w. The unarmed pseudo-weapon (itemutils.cpp: D 0, skill
    -- H2H) must flow through the full model.
    local MNK =
    {
        level     = 75,
        main_job  = 'MNK',
        stats     = { str = 80, dex = 80, vit = 70, agi = 70,
                      int = 50, mnd = 50, chr = 50 },
        attack    = 380,
        accuracy  = 320,
        ws_skill  = 269,
        weapon    = { dmg = 0, delay = 480, skill = 'hand_to_hand',
                      h2h_skill = 269, unarmed = true,
                      swings_per_round = 2 },
    }

    it('adds natural damage to the unarmed D of 0', function()
        -- floor(269 * 0.11) + 3 = 32 on a 0-damage pseudo-weapon
        assert.are.equal(32, A.effective_weapon_dmg(MNK.weapon))
    end)

    it('leaves non-H2H weapons untouched', function()
        assert.are.equal(81, A.effective_weapon_dmg(
            { dmg = 81, skill = 'great_axe' }))
    end)

    it('evaluates a full report barehanded', function()
        local report = evaluate({ player = MNK })

        -- no error path; ranked lines exist; fSTR rank is the
        -- unarmed (0+3)/9 = 0 rank (visible via the fstr line's
        -- presence rather than a crash)
        assert.is_nil(report.error)
        assert.is_true(#report.lines > 0)

        -- great_axe fixture WS are unusable barehanded: h2h fixture
        -- DB has none, so the ws list must be empty, not crashing
        assert.are.equal(0, #report.ws)
    end)

    it('ranks an H2H weapon skill using the skill level', function()
        local ws_db =
        {
            raging_fists =
            {
                id = 8, skill = 'hand_to_hand', skill_level = 5,
                element = 0, kind = 'physical', source = 'wotg_module',
                main_only = false, unlock_id = 0, jobs = { 'MNK' },
                sc = {},
                params = { numHits = 5, ftpMod = { 1.0, 1.0, 1.0 },
                           str_wsc = 0.3 },
            },
        }

        local report = evaluate(
        {
            player = MNK,
            data = { mobs = MOB_DB, ws = ws_db },
        })

        assert.are.equal(1, #report.ws)
        assert.are.equal('raging_fists', report.ws[1].name)

        -- apples-to-apples: must equal the direct formulas call with
        -- the unarmed D + h2h_skill routed through the h2h path,
        -- against the worst candidate (B: Lv.25 def 300 eva 350)
        local expected = F.ws_damage(
        {
            weapon_dmg       = 0,
            offhand_dmg      = 0,
            h2h_skill        = 269,
            fstr             = F.fstr(80, 30, 0),
            stats            = MNK.stats,
            ws               = { ftp = { 1.0, 1.0, 1.0 }, num_hits = 5,
                                 mods = { str = 0.3 } },
            tp               = 1000,
            attack           = 380,
            defense          = 300,
            acc              = 320,
            eva              = 350,
            attacker_level   = 75,
            target_level     = 25,
            weapon           = 'hand_to_hand',
            target_agi       = 30,
        }).expected

        assert.near(expected, report.ws[1].expected, 1e-9)
    end)
end)

-- =====================================================================
describe('mob candidates', function()
    it('looks up exact per-level rows (no interpolation)', function()
        local entry = MOB_DB[103]['Test Crab'][1]
        local mid = A.stats_at_level(entry, 21)

        -- 305 is the generated row, NOT the 303 a midpoint
        -- interpolation would produce
        assert.are.equal(305, mid.eva)
        assert.are.equal(84, mid.def)
        assert.are.equal(21, mid.vit)
    end)

    it('clamps out-of-range levels to the end rows', function()
        local entry = MOB_DB[103]['Test Crab'][1]

        assert.are.equal(300, A.stats_at_level(entry, 10).eva)
        assert.are.equal(306, A.stats_at_level(entry, 60).eva)
    end)

    it('surfaces the full range when nothing narrows it', function()
        local c = A.candidates({ mobs = MOB_DB, zone = 103,
                                 name = 'Test Crab' })

        assert.are.equal(2, #c.entries)
        assert.are.equal(3, #c.points) -- A min, A max, B single
        assert.is_true(c.ambiguous)
        assert.are.equal(20, c.level_min)
        assert.are.equal(25, c.level_max)
    end)

    it('narrows to one candidate with a pinned level', function()
        local c = A.candidates({ mobs = MOB_DB, zone = 103,
                                 name = 'Test Crab', level = 21 })

        assert.are.equal(1, #c.entries)
        assert.are.equal(1, #c.points)
        assert.is_false(c.ambiguous)
        assert.are.equal(305, c.points[1].stats.eva)
    end)

    it('falls back to the full set on a bad pin', function()
        local c = A.candidates({ mobs = MOB_DB, zone = 103,
                                 name = 'Test Crab', level = 99 })

        assert.are.equal(2, #c.entries)
    end)
end)

-- =====================================================================
describe('evaluate', function()
    it('produces an accuracy delta against the worst candidate', function()
        local report = evaluate()
        local acc_line

        for _, line in ipairs(report.lines) do
            if line.kind == 'acc' then
                acc_line = line
            end
        end

        -- worst eva 350 (Lv.25): rate = (75 + (300-350)/2)% = 50%
        -- phoenix cap 95% -> needed acc = 350 + 40 = 390 (+90)
        -- delta = 0.95/0.50 - 1 = 0.9
        assert.is_not_nil(acc_line)
        assert.near(0.9, acc_line.delta, 1e-9)
        assert.is_true(acc_line.text:find('%+90 acc') ~= nil)
        assert.is_true(acc_line.estimated) -- range not narrowed
    end)

    it('reports pDIF cap state against the highest-DEF candidate', function()
        local report = evaluate()
        local attack_line

        for _, line in ipairs(report.lines) do
            if line.kind == 'attack' then
                attack_line = line
            end
        end

        -- phoenix great_axe vs DEF 300: cap at ceil(1.625*300) = 488
        -- player attack 400 -> +88 needed
        assert.is_not_nil(attack_line)
        assert.is_true(attack_line.text:find('%+88 att') ~= nil)
    end)

    it('adds a haste overcap line when gear haste is wasted', function()
        local report = evaluate(
        {
            haste = { gear_overcap = 0.02, total_overcap = 0,
                      multiplier = 0.75 },
        })

        local haste_line

        for _, line in ipairs(report.lines) do
            if line.kind == 'haste' then
                haste_line = line
            end
        end

        assert.is_not_nil(haste_line)
        assert.near(0.02 / 0.75, haste_line.delta, 1e-12)
    end)

    it('ranks weapon skills and excludes unusable ones', function()
        local report = evaluate()

        -- sword/special/dynamic/quest excluded; no ws_skill given, so
        -- high_skill_strike passes the (absent) threshold check
        assert.are.equal(3, #report.ws)
        -- heavy_strike (fTP 2.0) beats true_strike (atk capped at 2.0
        -- pDIF already) against DEF 300
        assert.are.equal('heavy_strike', report.ws[1].name)
        assert.is_true(report.ws[1].expected > report.ws[2].expected)
    end)

    it('excludes quest WS by default, includes them when toggled', function()
        local function names(report)
            local found = {}
            for _, ws in ipairs(report.ws) do
                found[ws.name] = true
            end
            return found
        end

        assert.is_nil(names(evaluate()).quest_strike)
        assert.is_true(
            names(evaluate({ assume_quest_ws = true })).quest_strike
            == true)
    end)

    it('filters by real combat skill when provided', function()
        local player = {}
        for key, value in pairs(PLAYER) do
            player[key] = value
        end
        player.ws_skill = 240 -- below high_skill_strike's 250

        local found = {}
        for _, ws in ipairs(evaluate({ player = player }).ws) do
            found[ws.name] = true
        end

        assert.is_true(found.heavy_strike == true)
        assert.is_nil(found.high_skill_strike)
        -- quest_strike needs skill 240 AND the quest toggle
        assert.is_nil(found.quest_strike)
    end)

    it('emits a crit tier line when a dDEX tier is reachable', function()
        -- PLAYER dex 70 vs worst-AGI candidate (B, agi 30): dDEX 40 -
        -- inside the per-point band, so next tier is +1 DEX
        local report = evaluate()
        local crit_line

        for _, line in ipairs(report.lines) do
            if line.kind == 'crit' then
                crit_line = line
            end
        end

        assert.is_not_nil(crit_line)
        assert.is_true(crit_line.delta > 0)
        assert.is_true(crit_line.text:find('%+1 DEX') ~= nil)
    end)

    it('suppresses the crit line at the dDEX cap', function()
        local player = {}
        for key, value in pairs(PLAYER) do
            player[key] = value
        end
        player.stats = { str = 80, dex = 200, vit = 60, agi = 50,
                         int = 40, mnd = 40, chr = 40 }

        for _, line in ipairs(evaluate({ player = player }).lines) do
            assert.is_true(line.kind ~= 'crit')
        end
    end)

    it('sorts lines by delta, informational lines last', function()
        local report = evaluate()
        local seen_nil = false

        for index, line in ipairs(report.lines) do
            if line.delta == nil then
                seen_nil = true
            else
                assert.is_false(seen_nil, 'delta line after nil line')

                if index > 1 and report.lines[index - 1].delta then
                    assert.is_true(
                        report.lines[index - 1].delta >= line.delta)
                end
            end
        end
    end)

    it('collapses ranges when the level is pinned', function()
        local report = evaluate(
        {
            target = { zone = 103, name = 'Test Crab', level = 21 },
        })

        assert.is_false(report.target.ambiguous)

        for _, line in ipairs(report.lines) do
            if line.kind == 'acc' then
                -- single interpolated candidate -> no longer estimated
                assert.is_false(line.estimated)
            end
        end
    end)

    it('reports unknown mobs gracefully', function()
        local report = evaluate(
        {
            target = { zone = 103, name = 'No Such Mob' },
        })

        assert.are.equal('unknown mob', report.error)
        assert.are.equal(0, #report.lines)
    end)
end)

if WHETSTONE_TEST_SUMMARY then
    WHETSTONE_TEST_SUMMARY()
end
