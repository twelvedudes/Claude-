--[[
    Tests for tpledger.lua. Every expected value is HAND-DERIVED from
    the Phoenix source (phoenixffxi/Phoenix @ 0f3f8fc) in a comment
    next to the assertion - the tests are a transcript of the server
    arithmetic, not of the implementation.

    Runs under busted or plain Lua 5.1+:
        lua5.1 Telegraph/tests/test_tpledger.lua
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

local L = require('tpledger')

local MOB = 0x1000123 -- a mob-range server id
local PC  = 0x104     -- a player-range server id

-- =====================================================================
describe('era TP curve (soa/tp_gain.lua, the enabled override)', function()
    it('delay 240: 50 + 60*65/270 = 64.44 -> 64', function()
        assert.are.equal(64, L.tp_return(240, 'phoenix'))
    end)

    it('delay 450 sits exactly at the branch seam: 115', function()
        -- 450 is NOT > 450, so the > 180 branch: 50 + 270*65/270 = 115
        assert.are.equal(115, L.tp_return(450, 'phoenix'))
    end)

    it('delay 480: 115 + 30*15/30 = 130', function()
        assert.are.equal(130, L.tp_return(480, 'phoenix'))
    end)

    it('delay 530: 130 + 50*15/30 = 155 (top of the dip)', function()
        assert.are.equal(155, L.tp_return(530, 'phoenix'))
    end)

    it('delay 531 DROPS to 145 - the source discontinuity', function()
        -- > 530 branch restarts at 145: 145 + 1*35/470 = 145.07 -> 145
        assert.are.equal(145, L.tp_return(531, 'phoenix'))
    end)

    it('delay 600: 145 + 70*35/470 = 150.21 -> 150', function()
        assert.are.equal(150, L.tp_return(600, 'phoenix'))
    end)

    it('delay 999: 145 + 469*35/470 = 179.92 -> 179', function()
        assert.are.equal(179, L.tp_return(999, 'phoenix'))
    end)

    it('delay 150 (below 180): 50 - 30*15/180 = 47.5 -> 47', function()
        assert.are.equal(47, L.tp_return(150, 'phoenix'))
    end)

    it('delay 48 (the H2H/DW floor): 50 - 132*15/180 = 39', function()
        assert.are.equal(39, L.tp_return(48, 'phoenix'))
    end)

    it('phoenix profile uses ONE curve for every gainee', function()
        assert.are.equal(L.tp_return(240, 'phoenix', true),
            L.tp_return(240, 'phoenix', false))
    end)

    it('lsb profile splits: PC delay 240 = 61 + 60*88/360 = 75', function()
        -- upstream tp.lua PC branch
        assert.are.equal(75, L.tp_return(240, 'lsb', false))
        -- mob gainee keeps the mob curve
        assert.are.equal(64, L.tp_return(240, 'lsb', true))
    end)

    it('interval over [480, 600] finds the 530 peak and 531 dip', function()
        -- endpoints give 130/150 but the true extrema are curve(531) =
        -- 145 < 150 (NOT the min here - 480 gives 130) and curve(530)
        -- = 155 > 150
        local lo, hi = L.tp_return_interval(480, 600, 'phoenix')

        assert.are.equal(130, lo)
        assert.are.equal(155, hi)
    end)
end)

-- =====================================================================
describe('delay modification (getModifiedDelayAndCanZanshin)', function()
    it('mob H2H halves with a 48 floor: 480 -> 240', function()
        -- "Mobs are not affected at all by Martial Arts."
        assert.are.equal(240, L.modified_delay(
            { delay = 480, h2h = true, is_mob = true }))
    end)

    it('mob H2H floor: 80 -> max(40, 48) = 48', function()
        assert.are.equal(48, L.modified_delay(
            { delay = 80, h2h = true, is_mob = true }))
    end)

    it('PC dual wield: ((356 * 75/100))/2 = 133.5 -> 133', function()
        -- DW 25%: (delay * (100 - 25) / 100) / 2, floored at the end
        assert.are.equal(133, L.modified_delay(
            { delay = 356, dual_wield = true, dual_wield_mod = 25 }))
    end)

    it('PC H2H dual fists: (576 - 180)/2 = 198', function()
        -- H2H SQL delay includes the +480 base (96 + 480 = 576);
        -- MNK75 Martial Arts = 180
        assert.are.equal(198, L.modified_delay(
            { delay = 576, h2h = true, martial_arts = 180 }))
    end)

    it('PC H2H single fist: max(576 - 180, 96) = 396', function()
        assert.are.equal(396, L.modified_delay(
            { delay = 576, h2h = true, martial_arts = 180,
              single_fist = true }))
    end)

    it('DELAYP -10 applies: 240 * 0.90 = 216', function()
        -- tp.lua multiplies DELAYP into the TP delay even though
        -- modifier.h claims it does not affect TP gain - the Lua runs
        assert.are.equal(216, L.modified_delay(
            { delay = 240, delayp = -10 }))
    end)

    it('DELAYP floors at -15%: -20 -> 240 * 0.85 = 204', function()
        assert.are.equal(204, L.modified_delay(
            { delay = 240, delayp = -20 }))
    end)

    it('plain 1H/2H delay passes through', function()
        assert.are.equal(450, L.modified_delay({ delay = 450 }))
    end)
end)

-- =====================================================================
describe('attacker swing gain (getSingleMeleeHitTPReturn)', function()
    it('mob, cmbDelay 240: floor(64 * 1.0) = 64 per landed swing', function()
        assert.are.equal(64, L.attacker_swing_gain(
            { delay = 240, is_mob = true }, 'phoenix'))
    end)

    it('STORETP 10: floor(64 * 1.1) = 70', function()
        assert.are.equal(70, L.attacker_swing_gain(
            { delay = 240, is_mob = true, store_tp = 10 }, 'phoenix'))
    end)

    it('H2H mob with cmbDelay 480: modified 240 -> 64', function()
        assert.are.equal(64, L.attacker_swing_gain(
            { delay = 480, h2h = true, is_mob = true }, 'phoenix'))
    end)
end)

-- =====================================================================
describe('victim hit gain (calculateTPGainOnPhysicalDamage)', function()
    it('player GK (450) striking a mob: floor((115+30)*1*1*1*1) = 145',
    function()
        assert.are.equal(145, L.victim_hit_gain(
        {
            damage = 100,
            attacker = { delay = 450 },
            victim_is_mob = true,
        }, 'phoenix'))
    end)

    it('subtle blow 25: floor(145 * 0.75) = 108', function()
        assert.are.equal(108, L.victim_hit_gain(
        {
            damage = 100,
            attacker = { delay = 450, subtle_blow = 25 },
            victim_is_mob = true,
        }, 'phoenix'))
    end)

    it('subtle blow caps at 50: 80 -> floor(145 * 0.5) = 72', function()
        assert.are.equal(72, L.victim_hit_gain(
        {
            damage = 100,
            attacker = { delay = 450, subtle_blow = 80 },
            victim_is_mob = true,
        }, 'phoenix'))
    end)

    it('victim STORETP 20: floor(145 * 1.2) = 174', function()
        assert.are.equal(174, L.victim_hit_gain(
        {
            damage = 100,
            attacker = { delay = 450 },
            victim_is_mob = true,
            store_tp = 20,
        }, 'phoenix'))
    end)

    it('victim INHIBIT_TP 10 (the tp.lua copy): floor(145*0.9) = 130',
    function()
        assert.are.equal(130, L.victim_hit_gain(
        {
            damage = 100,
            attacker = { delay = 450 },
            victim_is_mob = true,
            inhibit = 10,
        }, 'phoenix'))
    end)

    it('dual-wield attacker: modified 133 -> curve 46 -> +30 = 76',
    function()
        -- (356 * 0.75)/2 = 133.5 -> 133; curve(133) = 50 - 47*15/180
        -- = 46.08 -> 46; (46+30) * 1 = 76
        assert.are.equal(76, L.victim_hit_gain(
        {
            damage = 100,
            attacker = { delay = 356, dual_wield = true,
                         dual_wield_mod = 25 },
            victim_is_mob = true,
        }, 'phoenix'))
    end)

    it('mob striking a mob (charm): floor(64 * 1/3) = 21, NO +30',
    function()
        assert.are.equal(21, L.victim_hit_gain(
        {
            damage = 100,
            attacker = { delay = 240, is_mob = true },
            victim_is_mob = true,
            attacker_is_mob = true,
        }, 'phoenix'))
    end)

    it('zero damage books NOTHING (TakePhysicalDamage damage>0 gate)',
    function()
        assert.are.equal(0, L.victim_hit_gain(
        {
            damage = 0,
            attacker = { delay = 450 },
            victim_is_mob = true,
        }, 'phoenix'))
    end)

    it('dAGI modifier is structurally 1.0 for every sane spread', function()
        -- clamp(200 - (dAGI+30)/200, 0.5, 1): dropping below 1 needs
        -- dAGI > 39770. The source comment promises 50% at +70; the
        -- expression does not deliver it. Replicated verbatim.
        assert.are.equal(1, L.dagi_modifier(0))
        assert.are.equal(1, L.dagi_modifier(70))
        assert.are.equal(1, L.dagi_modifier(-100))
        assert.are.equal(0.5, L.dagi_modifier(50000))
    end)
end)

-- =====================================================================
describe('victim magic gain (calculateTPGainOnMagicalDamage)', function()
    it('mob struck by a damaging spell: floor(100 * mods) = 100', function()
        assert.are.equal(100, L.victim_magic_gain(
            { damage = 86, victim_is_mob = true }, 'phoenix'))
    end)

    it('non-mob victim: 50 base', function()
        assert.are.equal(50, L.victim_magic_gain(
            { damage = 86, victim_is_mob = false }, 'phoenix'))
    end)

    it('zero damage books nothing', function()
        assert.are.equal(0, L.victim_magic_gain(
            { damage = 0, victim_is_mob = true }, 'phoenix'))
    end)

    it('caster subtle blow applies: 25 -> floor(100 * 0.75) = 75', function()
        assert.are.equal(75, L.victim_magic_gain(
        {
            damage = 86,
            attacker = { subtle_blow = 25 },
            victim_is_mob = true,
        }, 'phoenix'))
    end)
end)

-- =====================================================================
describe('WS victim gain (TakeWeaponskillDamage)', function()
    it('one addTP of hits * targetTPMult * per-hit base', function()
        -- 5 landed main hits x 145: trunc(725) = 725
        assert.are.equal(725, L.ws_victim_gain(5, 1, 145))
    end)

    it('targetTPMult scales: 2 hits x 1.5 x 145 = 435', function()
        assert.are.equal(435, L.ws_victim_gain(2, 1.5, 145))
    end)
end)

-- =====================================================================
describe('addTP (CBattleEntity::addTP)', function()
    it('plain gain adds and survives', function()
        assert.are.equal(1064, L.add_tp(1000, 64, 0, 1))
    end)

    it('clamps at 3000', function()
        assert.are.equal(3000, L.add_tp(2990, 64, 0, 1))
    end)

    it('clamps at 0 on losses', function()
        assert.are.equal(0, L.add_tp(30, -50, 0, 1))
    end)

    it('gainer-side INHIBIT_TP 25 on 64: 64 - 16 = 48', function()
        -- (int16)(tp - tp * 0.25) = trunc(48.0) = 48
        assert.are.equal(1048, L.add_tp(1000, 64, 25, 1))
    end)

    it('MOB_TP_MULTIPLIER applies with int16 truncation', function()
        -- (int16)(64 * 1.5) = 96
        assert.are.equal(1096, L.add_tp(1000, 64, 0, 1.5))
    end)

    it('negative gain bypasses inhibit and multiplier (gain>0 gate)',
    function()
        assert.are.equal(50, L.add_tp(100, -50, 99, 9))
    end)
end)

-- =====================================================================
describe('skill interrupt restore (reduceTpOnInterrupt)', function()
    it('spent 1000 (< 2900): floor(0.25 * 1000) = 250', function()
        assert.are.equal(250, L.skill_interrupt_restore(1000))
    end)

    it('spent 2899: floor(0.25 * 2899) = 724', function()
        assert.are.equal(724, L.skill_interrupt_restore(2899))
    end)

    it('spent 2900 (>= 2900): floor(round(966.67)) = 967', function()
        assert.are.equal(967, L.skill_interrupt_restore(2900))
    end)

    it('spent 3000: floor(round(999.999)) = 1000', function()
        assert.are.equal(1000, L.skill_interrupt_restore(3000))
    end)
end)

-- =====================================================================
describe('ledger lifecycle', function()
    it('cold entry: wide bounds, midpoint estimate, ~~ marker', function()
        local s = L.new()

        L.feed(s, MOB, 'Test Crab', 103, { lo = 64, hi = 64, best = 64 },
            nil, 100)

        local est = L.estimate(s, MOB, 103, 100)

        -- lo = addTP(0, 64) = 64; hi = addTP(3000, 64) clamps at 3000
        assert.are.equal(64, est.lo)
        assert.are.equal(3000, est.hi)
        assert.are.equal('~~', est.marker)
        assert.are.equal('cold', est.confidence)
        assert.is_false(est.calibrated)
    end)

    it('readying calibrates: clamp >= 1000, then the spend zeroes',
    function()
        local s = L.new()

        L.feed(s, MOB, 'Test Crab', 103, { lo = 100, hi = 500,
            best = 300 }, nil, 100)
        L.note_ready(s, MOB, 'Test Crab', 103, { id = 257 }, 101)

        local est = L.estimate(s, MOB, 103, 101)

        -- SpendCost runs at state ENTRY (the readying), not at finish
        assert.are.equal(0, est.lo)
        assert.are.equal(0, est.hi)
        assert.are.equal(0, est.best)
        assert.are.equal('~', est.marker)
        assert.is_true(est.calibrated)
        assert.is_true(est.pending)
    end)

    it('feeds during the windup survive the finish (no double spend)',
    function()
        local s = L.new()

        L.note_ready(s, MOB, 'Test Crab', 103, { id = 257 }, 100)
        L.feed(s, MOB, 'Test Crab', 103, { lo = 145, hi = 145,
            best = 145 }, nil, 101)
        L.feed(s, MOB, 'Test Crab', 103, { lo = 145, hi = 145,
            best = 145 }, nil, 102)
        L.note_skill_finish(s, MOB, 'Test Crab', 103, { id = 257 }, 103)

        local est = L.estimate(s, MOB, 103, 103)

        assert.are.equal(290, est.lo)
        assert.are.equal(290, est.hi)
        assert.are.equal(290, est.best)
        assert.is_false(est.pending)
    end)

    it('a finish without a readying is an instant skill: spend here',
    function()
        -- activation 0 skills never emit the SkillStart packet; the
        -- >= 1000 gate applied all the same
        local s = L.new()

        L.feed(s, MOB, 'Test Crab', 103, { lo = 500, hi = 2000,
            best = 900 }, nil, 100)
        L.note_skill_finish(s, MOB, 'Test Crab', 103, { id = 257 }, 101)

        local est = L.estimate(s, MOB, 103, 101)

        assert.are.equal(0, est.lo)
        assert.are.equal(0, est.hi)
        assert.is_true(est.calibrated)
    end)

    it('TP-free skills (SKILLFLAG_NO_TP_COST) never spend', function()
        local s = L.new()

        L.note_ready(s, MOB, 'Test Crab', 103,
            { id = 600, tp_free = true }, 100)

        local est = L.estimate(s, MOB, 103, 100)

        -- clamped up by the gate, NOT zeroed
        assert.are.equal(1000, est.lo)
        assert.are.equal(3000, est.hi)

        L.note_skill_finish(s, MOB, 'Test Crab', 103,
            { id = 600, tp_free = true }, 101)

        est = L.estimate(s, MOB, 103, 101)

        assert.are.equal(1000, est.lo)
        assert.is_false(est.pending)
    end)

    it('interrupt: lo 0 (non-stun keeps the spend), hi takes the '
        .. 'largest restore', function()
        local s = L.new()

        -- cold entry: ready clamps to [1000, 3000], spent remembers it
        L.note_ready(s, MOB, 'Test Crab', 103, { id = 257 }, 100)
        L.note_skill_interrupt(s, MOB, 'Test Crab', 103, 101)

        local est = L.estimate(s, MOB, 103, 101)

        assert.are.equal(0, est.lo)
        -- restore(3000) = floor(round(0.333333 * 3000)) = 1000
        assert.are.equal(1000, est.hi)
        -- best assumes the typical stun interrupt on the best spend:
        -- restore(1000) = floor(0.25 * 1000) = 250
        assert.are.equal(250, est.best)
        assert.is_false(est.pending)
    end)

    it('regain projects forward in 3s ticks (engaged-only caveat in '
        .. 'the glue)', function()
        local s = L.new()

        L.note_ready(s, MOB, 'Test Crab', 103, { id = 257 }, 100)
        L.set_regain(s, MOB, 'Test Crab', 103, 20, 100)

        -- 9.9 s later: floor(9.9/3) = 3 guaranteed ticks, hi books one
        -- extra for the unknown tick phase
        local est = L.estimate(s, MOB, 103, 109.9)

        assert.are.equal(60, est.lo)
        assert.are.equal(80, est.hi)
        assert.are.equal(60, est.best)
    end)

    it('stale entities widen and flag', function()
        local s = L.new()

        L.note_ready(s, MOB, 'Test Crab', 103, { id = 257 }, 100)

        -- 20 s without events: 8 s past the 12 s staleness horizon
        local est = L.estimate(s, MOB, 103, 120)

        assert.are.equal('~?', est.marker)
        assert.are.equal('stale', est.confidence)
        -- hi grew by 8 * 25 = 200; lo would decay but is already 0
        assert.are.equal(200, est.hi)
        assert.are.equal(0, est.lo)
    end)

    it('percent maps the era 0-300%% display (1000 TP = 100%%)', function()
        local s = L.new()

        L.note_ready(s, MOB, 'Test Crab', 103, { id = 257 }, 100)
        L.feed(s, MOB, 'Test Crab', 103, { lo = 740, hi = 740,
            best = 740 }, nil, 101)

        local est = L.estimate(s, MOB, 103, 101)

        assert.are.equal(74, est.percent)
        assert.are.equal('~', est.marker)
    end)
end)

-- =====================================================================
describe('ledger keying invariants (the narrow.lua lessons)', function()
    it('refuses degenerate ids on write and read', function()
        local s = L.new()

        assert.is_false(L.feed(s, 0, 'X', 103, { lo = 1, hi = 1 },
            nil, 100))
        assert.is_false(L.feed(s, nil, 'X', 103, { lo = 1, hi = 1 },
            nil, 100))
        assert.is_nil(L.estimate(s, 0, 103, 100))
        assert.is_nil(L.estimate(s, nil, 103, 100))
    end)

    it('zone change wipes the ledger (ids recycle across zones)', function()
        local s = L.new()

        L.note_ready(s, MOB, 'Test Crab', 103, { id = 257 }, 100)
        assert.is_true(L.estimate(s, MOB, 103, 100) ~= nil)

        L.feed(s, MOB, 'Zone Worm', 104, { lo = 5, hi = 5 }, nil, 101)

        assert.is_nil(L.estimate(s, MOB, 103, 101))

        local est = L.estimate(s, MOB, 104, 101)

        assert.are.equal('cold', est.confidence)
    end)

    it('a recycled id under a different name drops the history', function()
        local s = L.new()

        L.note_ready(s, MOB, 'Wild Rabbit', 103, { id = 257 }, 100)

        -- same id, different species: the calibration must NOT carry
        L.feed(s, MOB, 'Carrion Worm', 103, { lo = 5, hi = 5,
            best = 5 }, nil, 101)

        local est = L.estimate(s, MOB, 103, 101)

        assert.are.equal('cold', est.confidence)
    end)

    it('death eviction forgets the single id', function()
        local s = L.new()

        L.note_ready(s, MOB, 'Test Crab', 103, { id = 257 }, 100)
        L.forget(s, MOB)

        assert.is_nil(L.estimate(s, MOB, 103, 100))
    end)

    it('the ledger stays structurally id-keyed and bounded', function()
        local s = L.new()

        for index = 1, 200 do
            L.feed(s, 0x1000000 + index, 'Mob' .. index, 103,
                { lo = 1, hi = 1 }, nil, 100 + index)
        end

        assert.is_true(L.assert_id_keyed(s))
        assert.is_true(s.count <= 128, 'LRU cap holds: ' .. s.count)
    end)
end)

-- =====================================================================
describe('action mapping (on_action over parsed 0x028)', function()
    local function ctx()
        return
        {
            zone = 103,
            profile = 'phoenix',
            is_mob = function(id) return id >= 0x1000000 end,
            mob_params = function()
                return { delay = 240, h2h = false, agi = 26 }
            end,
            attacker_params = function(id)
                if id == PC then
                    return { delay = 450, agi = 55 }
                end

                return nil -- unknown party member
            end,
            mobskill_info = function(id)
                if id == 600 then
                    return { tp_free = true }
                end

                return { tp_free = false }
            end,
            ws_info = function(id)
                if id == 16 then
                    return { num_hits = 5 }
                end

                return nil
            end,
        }
    end

    local function result(param, message)
        return { reaction = 1, kind = 0, animation = 0, info = 0,
                 damage = param, param = param, message = message }
    end

    it('mob lands a melee round: attacker gain per landed swing', function()
        local s = L.new()

        -- two landed (hit + crit), one miss: 2 x 64
        local action =
        {
            actor = MOB, category = 1, action_id = 0x306B7461,
            targets = { { id = PC, results =
                { result(38, 1), result(52, 67), result(0, 15) } } },
        }

        assert.are.equal(2, L.on_action(s, action, ctx(), 100))

        local est = L.estimate(s, MOB, 103, 100)

        -- cold lo: addTP(addTP(0, 64), 64) = 128
        assert.are.equal(128, est.lo)
    end)

    it('a player counters the mob: the mob books VICTIM tp', function()
        local s = L.new()

        -- message 33 on the MOB's action: param = counter damage the
        -- mob takes; exact counterer unknown to the test ctx -> wide
        local action =
        {
            actor = MOB, category = 1, action_id = 0x306B7461,
            targets = { { id = PC, results = { result(12, 33) } } },
        }

        assert.are.equal(1, L.on_action(s, action, ctx(), 100))

        local est = L.estimate(s, MOB, 103, 100)

        -- the counterer's params resolve (PC id): curve(450) = 115,
        -- +30 = 145
        assert.are.equal(145, est.lo)
    end)

    it('player melee feeds the mob victim path', function()
        local s = L.new()

        local action =
        {
            actor = PC, category = 1, action_id = 0x306B7461,
            targets = { { id = MOB, results =
                { result(100, 1), result(0, 15) } } },
        }

        assert.are.equal(1, L.on_action(s, action, ctx(), 100))

        local est = L.estimate(s, MOB, 103, 100)

        -- known attacker: curve(450) + 30 = 145
        assert.are.equal(145, est.lo)
    end)

    it('unknown party attacker widens the feed interval', function()
        local s = L.new()

        local action =
        {
            actor = 0x105, category = 1, action_id = 0x306B7461,
            targets = { { id = MOB, results = { result(80, 1) } } },
        }

        L.on_action(s, action, ctx(), 100)

        local est = L.estimate(s, MOB, 103, 100)

        -- POLICY unknown delay [48, 999]: curve 39..179 -> +30 ->
        -- lo 69, hi 209 (hi also rides the cold 3000 clamp; check lo)
        assert.are.equal(69, est.lo)
    end)

    it('player WS feeds hits-bounded victim TP', function()
        local s = L.new()

        local action =
        {
            actor = PC, category = 3, action_id = 16,
            targets = { { id = MOB, results = { result(420, 185) } } },
        }

        L.on_action(s, action, ctx(), 100)

        local est = L.estimate(s, MOB, 103, 100)

        -- per-hit 145; lo books 1 landed main hit = 145
        assert.are.equal(145, est.lo)
    end)

    it('shadowed/missed results feed nothing', function()
        local s = L.new()

        local action =
        {
            actor = PC, category = 1, action_id = 0x306B7461,
            targets = { { id = MOB, results =
                { result(2, 31), result(0, 15), result(0, 32) } } },
        }

        assert.are.equal(0, L.on_action(s, action, ctx(), 100))
    end)

    it('nuke finish feeds the 100-base magic path', function()
        local s = L.new()

        local action =
        {
            actor = PC, category = 4, action_id = 159,
            targets = { { id = MOB, results = { result(86, 2) } } },
        }

        L.on_action(s, action, ctx(), 100)

        local est = L.estimate(s, MOB, 103, 100)

        assert.are.equal(100, est.lo)
    end)

    it('a resisted/non-damage magic message feeds nothing', function()
        local s = L.new()

        local action =
        {
            actor = PC, category = 4, action_id = 159,
            targets = { { id = MOB, results = { result(86, 85) } } },
        }

        assert.are.equal(0, L.on_action(s, action, ctx(), 100))
    end)

    it('readying (cat 7 + cate) calibrates and spends', function()
        local s = L.new()

        local action =
        {
            actor = MOB, category = 7, action_id = 0x65746163,
            targets = { { id = PC, results = { result(257, 43) } } },
        }

        L.on_action(s, action, ctx(), 100)

        local est = L.estimate(s, MOB, 103, 100)

        assert.are.equal(0, est.hi)
        assert.is_true(est.calibrated)
        assert.is_true(est.pending)
    end)

    it('mob skill finish (cat 11) spends when no readying preceded',
    function()
        local s = L.new()

        local action =
        {
            actor = MOB, category = 11, action_id = 257,
            targets = { { id = PC, results = { result(142, 185) } } },
        }

        L.on_action(s, action, ctx(), 100)

        local est = L.estimate(s, MOB, 103, 100)

        assert.are.equal(0, est.hi)
        assert.is_true(est.calibrated)
    end)

    it('cat 3 from a MOB actor is a mob skill finish, not a WS feed',
    function()
        -- battleentity.cpp OnMobSkillFinished: skill ids < 256 finish
        -- as SkillFinish (3)
        local s = L.new()

        local action =
        {
            actor = MOB, category = 3, action_id = 240,
            targets = { { id = PC, results = { result(88, 185) } } },
        }

        L.on_action(s, action, ctx(), 100)

        local est = L.estimate(s, MOB, 103, 100)

        assert.are.equal(0, est.hi)
    end)

    it('readying interrupt (cat 7 + spte) applies the restore window',
    function()
        local s = L.new()

        L.on_action(s,
        {
            actor = MOB, category = 7, action_id = 0x65746163,
            targets = { { id = PC, results = { result(257, 43) } } },
        }, ctx(), 100)

        L.on_action(s,
        {
            actor = MOB, category = 7, action_id = 0x65747073,
            targets = { { id = MOB, results = { result(0, 0) } } },
        }, ctx(), 101)

        local est = L.estimate(s, MOB, 103, 101)

        assert.are.equal(0, est.lo)
        assert.are.equal(1000, est.hi) -- restore(3000)
        assert.is_false(est.pending)
    end)
end)

if TELEGRAPH_TEST_SUMMARY then
    TELEGRAPH_TEST_SUMMARY()
end
