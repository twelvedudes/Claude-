--[[
    Telegraph - tpledger.lua

    Per-entity mob TP estimator: replicates Phoenix's TP arithmetic
    exactly and tracks an INTERVAL [lo, hi] + flagged point estimate
    per mob, fed by the same 0x028 action stream Whetstone parses
    (all actors, not just the player).

    Ground truth (phoenixffxi/Phoenix @ 0f3f8fc) - every formula below
    cites its source; the full row set lives in Telegraph/PROVENANCE.md:

      TP-per-hit curve      modules/soa/lua/tp_gain.lua (ENABLED
                            module) overrides
                            xi.combat.tp.calculateTPReturn with the
                            single era curve for ALL entities; the
                            upstream dual curve (scripts/globals/
                            combat/tp.lua) is the 'lsb' profile.
      delay modification    tp.lua getModifiedDelayAndCanZanshin:
                            dual wield ((delay*(100-DW))/100)/2; H2H
                            mob max(delay/2, 48), PC (delay-MA)/2 min
                            48 (or -MA min 96 single-fist); x
                            max((100+DELAYP)/100, 0.85); floored.
      attacker swing gain   tp.lua getSingleMeleeHitTPReturn:
                            floor(curve(modified) * (1 + STORETP/100))
      victim hit gain       tp.lua calculateTPGainOnPhysicalDamage:
                            mob struck by non-mob:
                              floor((base+30) * inhibit * dAGI * sb * stp)
                            else (mob vs mob, or non-mob victim):
                              floor(base * inhibit * sb * stp * (1/3))
                            damage <= 0 gives NOTHING (TakePhysical-
                            Damage only awards TP inside `damage > 0`).
      victim magic gain     tp.lua calculateTPGainOnMagicalDamage:
                            mob victim floor(100 * mods), else 50;
                            only damaging spells (battleutils.cpp
                            CalculateMagicDamage, canTargetEnemy &&
                            damage > 0).
      WS victim gain        battleutils.cpp TakeWeaponskillDamage:
                            ONE addTP of tpHitsLanded * targetTPMult *
                            per-hit base (extra DA/TA hits do NOT feed
                            the victim).
      addTP                 battleentity.cpp CBattleEntity::addTP:
                            gain>0 -> minus INHIBIT_TP% (int16 trunc),
                            x map.MOB_TP_MULTIPLIER (int16 trunc),
                            clamp [0, 3000].
      spend on skill use    mobskill_state.cpp SpendCost - runs at
                            STATE ENTRY (the readying packet), NOT at
                            finish: health.tp = 0 unless
                            SKILLFLAG_NO_TP_COST (0x004). Skills with
                            activation 0 never emit a readying - their
                            spend lands on the finish packet instead.
      >=1000 readying gate  mobentity.cpp shouldUseTPMove: hard
                            health.tp >= 1000 floor (threshold rolls
                            1000..3000). CAVEAT: the MOBMOD_SPECIAL_
                            SKILL path (mob_controller.cpp
                            TrySpecialSkill) bypasses the gate - a
                            special-skill readying can over-clamp;
                            the error self-corrects at the spend.
      interrupt restore     mobskill_state.cpp reduceTpOnInterrupt:
                            stun-class interrupts restore
                            floor(round(spent/3)) at >= 2900 else
                            floor(spent/4); non-stun interrupts keep 0.
      regain                status_effect_container.cpp TickRegen:
                            addTP(REGAIN - REGAIN_DOWN) every 3s
                            (zone_entities.cpp m_EffectCheckTime), and
                            for mobs ONLY while engaged.
      idle decay            mob_controller.cpp DoRoamTick + Rest(0.1):
                            addTP(-50) every >= 10s while unengaged.

    The CONFIDENCE model (cold / calibrated / stale markers, unseen-
    entity widening rates) is estimator POLICY, not server truth - its
    constants are in M.POLICY and labeled as such.

    Zero Ashita dependencies; fully unit-tested offline
    (tests/test_tpledger.lua). telegraph.lua owns the glue.
]]

local M = {}

local floor = math.floor

M.TP_MAX = 3000

-- =====================================================================
-- Profiles (mirrors Whetstone formulas.lua: 'phoenix' is the enabled-
-- module behavior, 'lsb' the upstream default)
-- =====================================================================

M.PROFILES =
{
    -- modules/soa/lua/tp_gain.lua: one curve for every entity
    phoenix = { single_curve = true,  mob_tp_multiplier = 1.0 },
    -- upstream tp.lua: PC/pet curve + mob curve split by gainee
    lsb     = { single_curve = false, mob_tp_multiplier = 1.0 },
}

local function profile_of(name)
    if type(name) == 'table' then
        return name
    end

    return M.PROFILES[name] or M.PROFILES.phoenix
end

-- =====================================================================
-- TP return curve
-- =====================================================================

-- The era curve (modules/soa/lua/tp_gain.lua, byte-for-byte the same
-- piecewise function as upstream tp.lua's mob branch). NOTE the
-- deliberate source discontinuity at 530->531: curve(530) = 155 but
-- curve(531) = 145 - interval propagation below has to know about it.
local function curve_mob(delay)
    local tp

    if delay > 530 then
        tp = 145 + (delay - 530) * 35 / 470
    elseif delay > 480 then
        tp = 130 + (delay - 480) * 15 / 30
    elseif delay > 450 then
        tp = 115 + (delay - 450) * 15 / 30
    elseif delay > 180 then
        tp = 50 + (delay - 180) * 65 / 270
    else
        tp = 50 + (delay - 180) * 15 / 180
    end

    return floor(tp)
end

-- Upstream PC/pet branch (scripts/globals/combat/tp.lua) - only used
-- by the 'lsb' profile.
local function curve_pc(delay)
    local tp

    if delay > 900 then
        tp = 173 + (delay - 900) * 28 / 360
    elseif delay > 720 then
        tp = 161 + (delay - 720) * 24 / 360
    elseif delay > 630 then
        tp = 154 + (delay - 630) * 28 / 360
    elseif delay > 540 then
        tp = 149 + (delay - 540) * 20 / 360
    elseif delay > 180 then
        tp = 61 + (delay - 180) * 88 / 360
    else
        tp = 61 + (delay - 180) * 63 / 360
    end

    return floor(tp)
end

-- calculateTPReturn. gainee_is_mob only matters on the 'lsb' profile
-- (the enabled soa module collapsed both branches).
function M.tp_return(delay, profile, gainee_is_mob)
    local p = profile_of(profile)

    if p.single_curve or gainee_is_mob then
        return curve_mob(delay)
    end

    return curve_pc(delay)
end

-- Curve extrema over a delay interval. The 530->531 discontinuity
-- means max/min are NOT always at the endpoints: max over [480, 600]
-- sits at 530 (155), min at 531 (145).
function M.tp_return_interval(delay_lo, delay_hi, profile, gainee_is_mob)
    local candidates = { delay_lo, delay_hi }

    if delay_lo <= 530 and 530 <= delay_hi then
        candidates[#candidates + 1] = 530
    end

    if delay_lo <= 531 and 531 <= delay_hi then
        candidates[#candidates + 1] = 531
    end

    local lo, hi

    for _, delay in ipairs(candidates) do
        local value = M.tp_return(delay, profile, gainee_is_mob)

        if not lo or value < lo then lo = value end
        if not hi or value > hi then hi = value end
    end

    return lo, hi
end

-- =====================================================================
-- Delay modification (getModifiedDelayAndCanZanshin)
-- =====================================================================

-- p:
--   delay         base delay (PC: main+sub summed by GetBaseDelay;
--                 H2H: SQL delay already includes the +480 base;
--                 mob: mob_pools.cmbDelay)
--   dual_wield    true when the attacker dual wields
--   dual_wield_mod  Mod::DUAL_WIELD percent (delay reduction)
--   h2h           true when the attacker swings hand-to-hand
--   is_mob        mob H2H branch: max(delay/2, 48), no Martial Arts
--   martial_arts  Mod::MARTIAL_ARTS flat delay reduction (PC H2H)
--   single_fist   PC H2H with a sub item or zero skill rank: one
--                 swing, -MA only, floor 96
--   delayp        Mod::DELAYP percent (the tp.lua code applies it
--                 even though modifier.h claims it does not affect
--                 TP gain - the Lua is what runs)
function M.modified_delay(p)
    local delay = p.delay

    if p.dual_wield then
        delay = (delay * (100 - (p.dual_wield_mod or 0)) / 100) / 2
    elseif p.h2h then
        if p.is_mob then
            -- "Mobs are not affected at all by Martial Arts."
            delay = math.max(delay / 2, 48)
        elseif p.single_fist then
            delay = math.max(delay - (p.martial_arts or 0), 96)
        else
            delay = math.max((delay - (p.martial_arts or 0)) / 2, 48)
        end
    end

    delay = delay * math.max((100 + (p.delayp or 0)) / 100, 0.85)

    return floor(delay)
end

-- =====================================================================
-- Gains (exact source replication; every floor placed where the
-- source places it)
-- =====================================================================

-- getSingleMeleeHitTPReturn: the gain the ATTACKER books per landed
-- swing (before addTP). Meikyo zeroes it; Zanshin/Ikishoten are
-- PC-only details that never apply to a mob attacker.
function M.attacker_swing_gain(p, profile)
    local modified = M.modified_delay(p)
    local base = M.tp_return(modified, profile, p.is_mob)

    return floor(base * (1 + (p.store_tp or 0) / 100))
end

-- dAGI modifier, replicated VERBATIM from calculateTPGainOnPhysical-
-- Damage: clamp(200 - (dAGI + 30) / 200, 0.5, 1). As written it
-- evaluates to 1.0 for every achievable dAGI (dropping below 1 needs
-- dAGI > 39770) - the comment in the source promises 50% at +70 but
-- the expression does not deliver it. We replicate what RUNS.
function M.dagi_modifier(dagi)
    local value = 200 - ((dagi or 0) + 30) / 200

    if value < 0.5 then return 0.5 end
    if value > 1 then return 1 end

    return value
end

-- calculateTPGainOnPhysicalDamage: the gain the VICTIM books per
-- landed hit (before addTP). p:
--   damage            <= 0 -> 0 (and TakePhysicalDamage would not
--                     even call this path)
--   attacker          delay-modification table for the ATTACKER
--                     (modified_delay fields), plus:
--     subtle_blow     Mod::SUBTLE_BLOW + merits (capped 50)
--     subtle_blow_2   Mod::SUBTLE_BLOW_II (+ tandem). NOTE the
--                     source's sign: (100 - SB1 + SB2)/100 - SB2 as
--                     written RAISES the modifier. Era entities have
--                     no SB2, replicated verbatim.
--     agi             attacker AGI (dAGI term)
--   victim_is_mob / attacker_is_mob   route the +30 vs the 1/3 branch
--   victim_agi        victim AGI
--   inhibit           victim Mod::INHIBIT_TP (the tp.lua copy -
--                     addTP applies the SAME mod again; both
--                     replicated, both usually 0)
--   store_tp          victim Mod::STORETP
function M.victim_hit_gain(p, profile)
    if (p.damage or 0) <= 0 then
        return 0
    end

    local attacker = p.attacker or {}
    local modified = M.modified_delay(attacker)
    local base = M.tp_return(modified, profile, p.victim_is_mob)

    local inhibit_mod = (100 - (p.inhibit or 0)) / 100
    local sb1 = math.min(attacker.subtle_blow or 0, 50)
    local sb2 = attacker.subtle_blow_2 or 0
    local sb_mod = math.max((100 - sb1 + sb2) / 100, 0.25)
    local store_mod = 1 + (p.store_tp or 0) / 100

    if p.victim_is_mob and not p.attacker_is_mob then
        -- the +30 keeps mobs dangerous against players (tp.lua cites
        -- wiki.ffo.jp/html/2621.html)
        local dagi = (attacker.agi or 0) - (p.victim_agi or 0)

        return floor((base + 30) * inhibit_mod * M.dagi_modifier(dagi)
            * sb_mod * store_mod)
    end

    -- mob-vs-mob (charm) and non-mob victims: base/3, NO dAGI term
    return floor(base * inhibit_mod * sb_mod * store_mod * (1 / 3))
end

-- calculateTPGainOnMagicalDamage (battleutils.cpp CalculateMagicDamage
-- awards it for canTargetEnemy spells with damage > 0).
function M.victim_magic_gain(p, profile)
    if (p.damage or 0) <= 0 then
        return 0
    end

    local attacker = p.attacker or {}
    local inhibit_mod = (100 - (p.inhibit or 0)) / 100
    local sb1 = math.min(attacker.subtle_blow or 0, 50)
    local sb2 = attacker.subtle_blow_2 or 0
    local sb_mod = math.max((100 - sb1 + sb2) / 100, 0.25)
    local store_mod = 1 + (p.store_tp or 0) / 100

    if p.victim_is_mob then
        local dagi = (attacker.agi or 0) - (p.victim_agi or 0)

        return floor(100 * inhibit_mod * M.dagi_modifier(dagi)
            * sb_mod * store_mod)
    end

    return floor(50 * inhibit_mod * sb_mod * store_mod)
end

-- int16-style truncation toward zero ((int16)(...) casts in addTP /
-- TakeWeaponskillDamage).
local function trunc(value)
    if value >= 0 then
        return floor(value)
    end

    return -floor(-value)
end

-- TakeWeaponskillDamage: ONE addTP of trunc(tpHitsLanded *
-- targetTPMult * per-hit base). Extra DA/TA proc hits do NOT feed.
function M.ws_victim_gain(hits_landed, target_tp_mult, per_hit_base)
    return trunc(hits_landed * (target_tp_mult or 1) * per_hit_base)
end

-- CBattleEntity::addTP: gainer-side INHIBIT_TP, then the server
-- map.MOB_TP_MULTIPLIER (tracked default 1.0; the DEPLOYED value is
-- not client-readable - README caveat), then clamp [0, 3000].
function M.add_tp(current, gain, inhibit, multiplier)
    if gain > 0 then
        gain = trunc(gain - gain * (inhibit or 0) / 100)
        gain = trunc(gain * (multiplier or 1))
    end

    local capped = current + gain

    if capped < 0 then capped = 0 end
    if capped > M.TP_MAX then capped = M.TP_MAX end

    return capped
end

-- reduceTpOnInterrupt: restore when a stun-class effect interrupted
-- the skill mid-windup. floor(round(spent/3)) at >= 2900, else
-- floor(spent/4); a non-stun interrupt keeps the spend (0).
function M.skill_interrupt_restore(spent)
    if spent >= 2900 then
        return floor(floor(0.333333 * spent + 0.5))
    end

    return floor(0.25 * spent)
end

-- =====================================================================
-- Estimator policy (OURS, not server truth - every constant here is
-- an estimation choice, kept visible and tunable)
-- =====================================================================

M.POLICY =
{
    -- Without any TP-move observation the entity's history is unknown:
    -- cold entries start at the full range.
    cold_lo = 0,
    cold_hi = 3000,

    -- Unknown party-member attackers: bounds on the MODIFIED delay
    -- entering the curve. 48 = the H2H/dual-wield floor in
    -- getModifiedDelayAndCanZanshin; 999 comfortably covers every era
    -- 2H (curve(999) = 179). best = 240, a common 1H delay.
    unknown_delay_lo   = 48,
    unknown_delay_hi   = 999,
    unknown_delay_best = 240,

    -- Unknown WS main-hit count when the WS id is not in the table.
    unknown_ws_hits_hi = 8, -- the server's 8-swing cap

    -- Damaging JA hit count bounds (Jump-class abilities).
    ja_hits_hi = 2,

    -- Mob auto-ranged attacks: mobutils.cpp:1071 fixes the mob ranged
    -- weapon base delay at 300.
    mob_ranged_delay = 300,

    -- Staleness: after this many seconds without an event the entity
    -- is flagged and its bounds start widening.
    stale_after_s = 12,

    -- Widening rates per second once stale: hi grows at a generous
    -- being-fought ceiling; lo decays at the server's idle Rest rate
    -- (-50 TP / 10 s, mob_controller.cpp DoRoamTick).
    stale_hi_gain_per_s = 25,
    stale_lo_decay_per_s = 5,

    -- Ledger size cap (LRU sweep; a camp rarely tracks > 30 mobs).
    max_entries = 128,
}

-- =====================================================================
-- Interval ledger (keyed by entity SERVER ID and nothing else -
-- narrow.lua's invariants: latest wins, refuse degenerate ids, names
-- only as a recycling tripwire, zone change wipes)
-- =====================================================================

function M.new()
    return
    {
        zone  = nil,
        by_id = {}, -- [server_id] = entry
        count = 0,
    }
end

local function valid_id(server_id)
    return type(server_id) == 'number' and server_id > 0
end

local function sweep_lru(s, now)
    if s.count <= M.POLICY.max_entries then
        return
    end

    -- drop the stalest half beyond the cap
    local oldest_id, oldest_t

    for id, entry in pairs(s.by_id) do
        if not oldest_t or entry.t < oldest_t then
            oldest_id, oldest_t = id, entry.t
        end
    end

    if oldest_id then
        s.by_id[oldest_id] = nil
        s.count = s.count - 1
    end
end

-- Fetch-or-create the entry for an id. Returns nil (refusing) on
-- degenerate ids or a name-tripwire mismatch eviction.
local function entry_for(s, id, name, zone, now)
    if not valid_id(id) then
        return nil
    end

    if s.zone ~= zone then
        s.zone = zone
        s.by_id = {}
        s.count = 0
    end

    local entry = s.by_id[id]

    -- id recycled onto a different species: never trust the history
    if entry and entry.name and name and entry.name ~= name then
        s.by_id[id] = nil
        s.count = s.count - 1
        entry = nil
    end

    if not entry then
        entry =
        {
            lo = M.POLICY.cold_lo,
            hi = M.POLICY.cold_hi,
            best = nil, -- cold: no point estimate yet
            confidence = 'cold',
            t = now,
            name = name,
            pending = nil, -- readying in flight
            regain = 0,
        }
        s.by_id[id] = entry
        s.count = s.count + 1
        sweep_lru(s, now)
    elseif name and not entry.name then
        entry.name = name
    end

    return entry
end

-- Project regain + staleness onto (lo, hi, best) WITHOUT mutating -
-- estimate() is a pure view; only events move the stored state.
local function project(entry, now)
    local lo, hi, best = entry.lo, entry.hi, entry.best
    local elapsed = math.max(0, now - entry.t)

    -- REGAIN ticks every 3 s while engaged (TickRegen / zone tick).
    -- Tick phase is unknowable: lo books the guaranteed ticks, hi one
    -- extra.
    if (entry.regain or 0) > 0 then
        local ticks = floor(elapsed / 3)

        lo = M.add_tp(lo, entry.regain * ticks, 0, 1)
        hi = M.add_tp(hi, entry.regain * (ticks + 1), 0, 1)

        if best then
            best = M.add_tp(best, entry.regain * ticks, 0, 1)
        end
    end

    local stale = elapsed > M.POLICY.stale_after_s

    if stale then
        local over = elapsed - M.POLICY.stale_after_s

        hi = math.min(M.TP_MAX,
            hi + floor(over * M.POLICY.stale_hi_gain_per_s))
        lo = math.max(0,
            lo - floor(over * M.POLICY.stale_lo_decay_per_s))

        if best and best > hi then best = hi end
        if best and best < lo then best = lo end
    end

    return lo, hi, best, stale
end

-- Book a gain interval onto an entry. gain = { lo, hi, best } in
-- pre-addTP units; inhibit/multiplier are the addTP-side parameters
-- (gainer mods).
function M.feed(s, id, name, zone, gain, addtp, now)
    local entry = entry_for(s, id, name, zone, now)

    if not entry then
        return false
    end

    local inhibit = addtp and addtp.inhibit or 0
    local mult = addtp and addtp.multiplier or 1

    entry.lo = M.add_tp(entry.lo, gain.lo, inhibit, mult)
    entry.hi = M.add_tp(entry.hi, gain.hi, inhibit, mult)

    if entry.best then
        entry.best = M.add_tp(entry.best, gain.best or gain.lo,
            inhibit, mult)
    end

    entry.t = now

    return true
end

-- Readying observed (SkillStart + FourCC 'cate' from this actor).
-- shouldUseTPMove implies TP >= 1000 at this instant; SpendCost runs
-- at state ENTRY, so unless the skill is TP-free the spend lands NOW,
-- not at the finish. The pre-spend interval is remembered for the
-- interrupt-restore path.
function M.note_ready(s, id, name, zone, skill, now)
    local entry = entry_for(s, id, name, zone, now)

    if not entry then
        return false
    end

    -- calibration clamp: >= 1000 (documented caveat: the special-
    -- skill path bypasses the gate; the spend below self-corrects)
    entry.lo = math.max(entry.lo, 1000)
    entry.hi = math.max(entry.hi, 1000)
    entry.best = math.max(entry.best or 1000, 1000)

    local spent = { lo = entry.lo, hi = entry.hi, best = entry.best }

    if not (skill and skill.tp_free) then
        entry.lo, entry.hi, entry.best = 0, 0, 0
    end

    entry.pending =
    {
        id = skill and skill.id or nil,
        spent = spent,
        tp_free = skill and skill.tp_free or false,
        t = now,
    }

    entry.confidence = 'calibrated'
    entry.t = now

    return true
end

-- Skill finish observed. With a pending readying the spend already
-- happened there - feeds booked during the windup survive. Without
-- one this was an instant skill (activation 0, no readying packet):
-- the same >= 1000 gate applied and the spend lands here.
function M.note_skill_finish(s, id, name, zone, skill, now)
    local entry = entry_for(s, id, name, zone, now)

    if not entry then
        return false
    end

    if entry.pending then
        entry.pending = nil
    elseif not (skill and skill.tp_free) then
        entry.confidence = 'calibrated'
        entry.lo, entry.hi, entry.best = 0, 0, 0
    else
        entry.confidence = 'calibrated'
        entry.lo = math.max(entry.lo, 1000)
        entry.hi = math.max(entry.hi, 1000)
        entry.best = math.max(entry.best or 1000, 1000)
    end

    entry.t = now

    return true
end

-- Readying interrupted (SkillStart + FourCC 'spte'). Stun-class
-- interrupts restore part of the spend (reduceTpOnInterrupt); other
-- interrupt causes keep 0. We cannot read the cause: lo stays 0, hi
-- takes the largest restore, best assumes the typical stun interrupt.
function M.note_skill_interrupt(s, id, name, zone, now)
    local entry = entry_for(s, id, name, zone, now)

    if not entry then
        return false
    end

    local pending = entry.pending

    if pending and not pending.tp_free then
        entry.lo = 0
        entry.hi = M.skill_interrupt_restore(pending.spent.hi)
        entry.best = M.skill_interrupt_restore(pending.spent.best
            or pending.spent.hi)
    end

    entry.pending = nil
    entry.t = now

    return true
end

-- Record the entity's TP-relevant mob mods when the caller knows them
-- (extract_mobs emits REGAIN where present in mob_pool_mods /
-- mob_species_mods).
function M.set_regain(s, id, name, zone, regain, now)
    local entry = entry_for(s, id, name, zone, now)

    if entry then
        entry.regain = regain or 0
    end
end

-- The estimator view. Returns nil for unknown/refused ids, else:
--   { lo, hi, best, percent, marker, confidence, calibrated, stale }
-- percent maps the era 0..300% display (1000 TP = 100%); best is nil
-- while cold and the marker says so - never an unflagged guess.
function M.estimate(s, id, zone, now)
    if s.zone ~= zone or not valid_id(id) then
        return nil
    end

    local entry = s.by_id[id]

    if not entry then
        return nil
    end

    local lo, hi, best, stale = project(entry, now)

    local confidence = entry.confidence

    if stale then
        confidence = 'stale'
    end

    local marker

    if confidence == 'calibrated' then
        marker = '~'
    elseif confidence == 'stale' then
        marker = '~?'
    else
        marker = '~~'
    end

    local point = best

    if point == nil then
        -- cold: report the interval midpoint, marked wide
        point = floor((lo + hi) / 2)
    end

    return
    {
        lo = lo,
        hi = hi,
        best = point,
        percent = floor(point / 10),
        lo_percent = floor(lo / 10),
        hi_percent = floor(hi / 10),
        marker = marker,
        confidence = confidence,
        calibrated = entry.confidence == 'calibrated',
        stale = stale,
        pending = entry.pending ~= nil,
    }
end

function M.forget(s, id)
    if id ~= nil and s.by_id[id] then
        s.by_id[id] = nil
        s.count = s.count - 1
    end
end

function M.on_zone_change(s, zone)
    s.zone = zone
    s.by_id = {}
    s.count = 0
end

-- Structural assertion (narrow.lua regression-test d, applied here):
-- the ledger may key on numeric server ids only and carry no other
-- lookup structure.
function M.assert_id_keyed(s)
    for key in pairs(s.by_id) do
        if type(key) ~= 'number' then
            error('tpledger key is not a server id: ' .. tostring(key))
        end
    end

    for field in pairs(s) do
        if field ~= 'zone' and field ~= 'by_id' and field ~= 'count' then
            error('unexpected tpledger state field: ' .. tostring(field))
        end
    end

    return true
end

-- =====================================================================
-- Action mapping: parsed 0x028 -> ledger events
-- =====================================================================

-- Interval-normalize a parameter that may be a scalar or {lo,hi,best}.
local function band(value, default)
    if type(value) == 'table' then
        return value.lo or default, value.hi or default,
            value.best or value.lo or default
    end

    if value == nil then
        return default, default, default
    end

    return value, value, value
end

-- Victim-side per-hit gain interval for an attacker description whose
-- delay may be uncertain. modified_delay is monotone nondecreasing in
-- the raw delay, so the modified interval is the image of the raw
-- endpoints; tp_return_interval then handles the curve discontinuity
-- EXACTLY (the max over a straddling interval sits at 530, not at an
-- endpoint). attacker fields follow victim_hit_gain.
local function victim_gain_interval(attacker, victim, profile)
    local d_lo, d_hi, d_best = band(attacker.delay,
        M.POLICY.unknown_delay_best)

    local function modify(delay)
        return M.modified_delay(
        {
            delay = delay,
            dual_wield = attacker.dual_wield,
            dual_wield_mod = attacker.dual_wield_mod,
            h2h = attacker.h2h,
            is_mob = attacker.is_mob,
            martial_arts = attacker.martial_arts,
            single_fist = attacker.single_fist,
            delayp = attacker.delayp,
        })
    end

    local base_lo, base_hi = M.tp_return_interval(
        modify(d_lo), modify(d_hi), profile, true)

    -- the multiplier chain around the curve value, replicated from
    -- calculateTPGainOnPhysicalDamage (the +30 player-vs-mob branch /
    -- the 1/3 mob-vs-mob branch)
    local inhibit_mod = (100 - (victim.inhibit or 0)) / 100
    local sb1 = math.min(attacker.subtle_blow or 0, 50)
    local sb2 = attacker.subtle_blow_2 or 0
    local sb_mod = math.max((100 - sb1 + sb2) / 100, 0.25)
    local store_mod = 1 + (victim.store_tp or 0) / 100
    local dagi = (attacker.agi or 0) - (victim.agi or 0)

    local function wrap(base)
        if attacker.is_mob then
            return floor(base * inhibit_mod * sb_mod * store_mod
                * (1 / 3))
        end

        return floor((base + 30) * inhibit_mod * M.dagi_modifier(dagi)
            * sb_mod * store_mod)
    end

    return
    {
        lo = wrap(base_lo),
        hi = wrap(base_hi),
        best = wrap(M.tp_return(modify(d_best), profile, true)),
    }
end

-- Map one parsed action onto the ledger. ctx supplies what the glue
-- knows (every callback optional-failure-safe):
--   ctx.zone                  current zone id
--   ctx.is_mob(id)            ledger-relevant actor/target?
--   ctx.mob_params(id)        { delay, h2h, store_tp, inhibit,
--                               regain, agi, multiplier } or nil
--   ctx.attacker_params(id)   attacker description for victim feeds
--                             (nil -> POLICY unknown-attacker bounds)
--   ctx.mobskill_info(id)     { tp_free, name } or nil
--   ctx.ws_info(id)           { num_hits, target_tp_mult } or nil
--   ctx.profile               'phoenix' | 'lsb' | custom table
-- Returns the number of ledger mutations performed (for tests/debug).
function M.on_action(s, action, ctx, now)
    if not action then
        return 0
    end

    -- ctx.classify lets tests inject a classifier; the default is the
    -- shared parser's (one canonical require path, lazily resolved so
    -- the formula half of this module stays usable without it).
    local classify = ctx.classify

    if not classify then
        local ok, actionpacket = pcall(require, 'actionpacket')

        if not ok then
            return 0
        end

        classify = actionpacket.classify
        ctx.classify = classify
    end

    local kind, ref_id = classify(action)

    if not kind then
        return 0
    end

    local zone = ctx.zone
    local profile = ctx.profile or 'phoenix'
    local mutations = 0

    local MSG_HIT, MSG_CRIT = 1, 67
    local MSG_COUNTERED = 33
    local MSG_MAGIC, MSG_BURST = 2, 252

    local actor_is_mob = ctx.is_mob and ctx.is_mob(action.actor)

    -- ---------------- mob as the ACTOR ----------------

    if actor_is_mob then
        local mob = (ctx.mob_params and ctx.mob_params(action.actor))
            or {}
        local addtp =
        {
            inhibit = mob.inhibit or 0,
            multiplier = mob.multiplier
                or profile_of(profile).mob_tp_multiplier,
        }

        if mob.regain and mob.regain > 0 then
            M.set_regain(s, action.actor, nil, zone, mob.regain, now)
        end

        if kind == 'melee' or kind == 'ranged_finish' then
            for _, target in ipairs(action.targets) do
                for _, result in ipairs(target.results) do
                    if (result.message == MSG_HIT
                        or result.message == MSG_CRIT)
                        and result.damage > 0 then
                        -- attacker-side gain per landed swing
                        local delay = mob.delay
                            or M.POLICY.unknown_delay_best

                        if kind == 'ranged_finish' then
                            delay = M.POLICY.mob_ranged_delay
                        end

                        local gain = M.attacker_swing_gain(
                        {
                            delay = delay,
                            h2h = kind == 'melee' and mob.h2h or false,
                            is_mob = true,
                            store_tp = mob.store_tp,
                        }, profile)

                        if M.feed(s, action.actor, nil, zone,
                            { lo = gain, hi = gain, best = gain },
                            addtp, now) then
                            mutations = mutations + 1
                        end
                    elseif result.message == MSG_COUNTERED
                        and result.damage > 0 then
                        -- the TARGET countered: the mob TAKES
                        -- result.param damage as the DEFENDER and
                        -- books victim TP from the counterer's delay
                        -- (battleutils.cpp counter branch:
                        -- giveTPtoVictim=true, attacker=counterer)
                        local counterer = (ctx.attacker_params
                            and ctx.attacker_params(target.id))
                            or { delay =
                                { lo = M.POLICY.unknown_delay_lo,
                                  hi = M.POLICY.unknown_delay_hi,
                                  best = M.POLICY.unknown_delay_best } }

                        local gain = victim_gain_interval(counterer,
                            mob, profile)

                        if M.feed(s, action.actor, nil, zone, gain,
                            addtp, now) then
                            mutations = mutations + 1
                        end
                    end
                end
            end
        elseif kind == 'ready_start' then
            local info = ctx.mobskill_info
                and ctx.mobskill_info(ref_id) or nil

            if M.note_ready(s, action.actor, nil, zone,
                { id = ref_id, tp_free = info and info.tp_free },
                now) then
                mutations = mutations + 1
            end
        elseif kind == 'ready_interrupt' then
            if M.note_skill_interrupt(s, action.actor, nil, zone,
                now) then
                mutations = mutations + 1
            end
        elseif kind == 'mobskill_finish' or kind == 'petskill_finish'
            or kind == 'ws_finish' then
            -- category 3 from a mob actor IS a mob skill finish
            -- (skill ids < 256, battleentity.cpp OnMobSkillFinished)
            local info = ctx.mobskill_info
                and ctx.mobskill_info(ref_id) or nil

            if M.note_skill_finish(s, action.actor, nil, zone,
                { id = ref_id, tp_free = info and info.tp_free },
                now) then
                mutations = mutations + 1
            end
        end
        -- cast_start / cast_interrupt / magic_finish from a mob:
        -- casting moves no TP for non-PC casters (calculateSpellTP is
        -- PC-only, Occult Acumen)
    end

    -- ---------------- mob as a TARGET ----------------

    if kind == 'melee' or kind == 'ws_finish' or kind == 'ja_finish'
        or kind == 'ranged_finish' or kind == 'magic_finish' then
        for _, target in ipairs(action.targets) do
            if ctx.is_mob and ctx.is_mob(target.id)
                and target.id ~= action.actor and not actor_is_mob then
                local mob = (ctx.mob_params
                    and ctx.mob_params(target.id)) or {}
                local addtp =
                {
                    inhibit = mob.inhibit or 0,
                    multiplier = mob.multiplier
                        or profile_of(profile).mob_tp_multiplier,
                }
                local attacker = (ctx.attacker_params
                    and ctx.attacker_params(action.actor))
                    or { delay =
                        { lo = M.POLICY.unknown_delay_lo,
                          hi = M.POLICY.unknown_delay_hi,
                          best = M.POLICY.unknown_delay_best } }

                if mob.regain and mob.regain > 0 then
                    M.set_regain(s, target.id, nil, zone,
                        mob.regain, now)
                end

                for _, result in ipairs(target.results) do
                    local damaging = result.damage > 0

                    if kind == 'magic_finish' then
                        -- only damaging-spell messages feed
                        -- (MagicDamage 2 / MagicBurstDamage 252);
                        -- resists, enfeebles and failure paths with
                        -- SkillInterrupt animation do not
                        if damaging and (result.message == MSG_MAGIC
                            or result.message == MSG_BURST) then
                            local gain = M.victim_magic_gain(
                            {
                                damage = result.damage,
                                attacker = attacker,
                                victim_is_mob = true,
                                victim_agi = mob.agi,
                                inhibit = mob.inhibit,
                                store_tp = mob.store_tp,
                            }, profile)

                            if M.feed(s, target.id, nil, zone,
                                { lo = gain, hi = gain, best = gain },
                                addtp, now) then
                                mutations = mutations + 1
                            end
                        end
                    elseif kind == 'melee' then
                        if damaging and (result.message == MSG_HIT
                            or result.message == MSG_CRIT) then
                            local gain = victim_gain_interval(
                                attacker, mob, profile)

                            if M.feed(s, target.id, nil, zone, gain,
                                addtp, now) then
                                mutations = mutations + 1
                            end
                        end
                        -- message 33 on a PLAYER action = the MOB
                        -- countered; the mob books NO TP for its
                        -- counter (giveTPtoAttacker=false in the
                        -- counter branch)
                    elseif damaging then
                        -- ws_finish / ja_finish / ranged_finish:
                        -- per-hit base x landed main hits. The packet
                        -- carries only the damage total; hit counts
                        -- come from the WS table or POLICY bounds.
                        local per_hit = victim_gain_interval(attacker,
                            mob, profile)

                        local hits_lo, hits_hi, hits_best = 1, 1, 1
                        local target_mult = 1

                        if kind == 'ws_finish' then
                            local info = ctx.ws_info
                                and ctx.ws_info(ref_id) or nil

                            hits_hi = (info and info.num_hits)
                                or M.POLICY.unknown_ws_hits_hi
                            hits_best = hits_hi
                            target_mult = (info
                                and info.target_tp_mult) or 1
                        elseif kind == 'ja_finish' then
                            hits_hi = M.POLICY.ja_hits_hi
                        end

                        local gain =
                        {
                            lo = M.ws_victim_gain(hits_lo,
                                target_mult, per_hit.lo),
                            hi = M.ws_victim_gain(hits_hi,
                                target_mult, per_hit.hi),
                            best = M.ws_victim_gain(hits_best,
                                target_mult, per_hit.best),
                        }

                        if M.feed(s, target.id, nil, zone, gain,
                            addtp, now) then
                            mutations = mutations + 1
                        end
                    end
                end
            end
        end
    end

    return mutations
end

return M
