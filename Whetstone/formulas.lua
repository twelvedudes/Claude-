--[[
    Whetstone - formulas.lua

    Pure-Lua (5.1 / LuaJIT compatible) implementations of the melee combat
    math used by LandSandBoat-based FFXI private servers, tuned for the
    75-cap era.

    ZERO Ashita (or any other) dependencies. Every function is
    deterministic: where the server rolls dice (pDIF, melee random,
    spike), this module returns the distribution bounds and the exact
    expected value instead.

    Ground truth (primary): github.com/phoenixffxi/Phoenix
    commit 0f3f8fcfcad5872874fd6050bb4befb543b2d1fa
      - scripts/globals/combat/physical_utilities.lua  (fSTR, WSC, pDIF, crit)
      - scripts/globals/combat/physical_hit_rate.lua   (hit rate)
      - scripts/globals/weaponskills.lua               (WS pipeline, fTP)
      - src/map/entities/battleentity.cpp              (GetWeaponDelay, weapon rank)
      - modules/soa/lua/physical_hit_cap.lua           (flat 95% hit ceiling)
      - modules/wotg/lua/pdif_caps_revert.lua          (2.0 melee pDIF caps)

    Phoenix's core combat files are byte-identical to upstream
    LandSandBoat (commit fdc24716f825de6b96a3c4c9896cd1c7295c494f); its
    era behavior comes from the two modules above, which are enabled in
    modules/init.txt. Both rule sets are exposed here as profiles:

      'phoenix' (default) - 95% hit ceiling everywhere, 2.0 melee /
                3.0 ranged pDIF caps, legacy (level-based) WSC alpha
      'lsb'     - upstream defaults: 99%/95% hit ceilings, modern
                per-weapon pDIF caps (3.25-4.0), Adoulin WS rules
                (alpha = 1)

    Pass profile = 'phoenix' | 'lsb' | <custom table> in any params
    table (or as the trailing argument of the positional fSTR
    functions), or change M.default_profile.

    Conventions:
      - All rates/multipliers are fractions (0.25 == 25%).
      - "rank" is the weapon damage rank: floor(weaponDmg / 9).
      - Functions take a single params table unless they are trivially
        positional.
]]

local M = {}

local floor = math.floor
local min   = math.min
local max   = math.max

-- =====================================================================
-- Small utilities
-- =====================================================================

function M.clamp(value, lower, upper)
    if value < lower then
        return lower
    elseif value > upper then
        return upper
    end

    return value
end

local clamp = M.clamp

-- =====================================================================
-- Profiles
-- =====================================================================

M.PROFILES =
{
    -- Phoenix (phoenixffxi/Phoenix @ 0f3f8fc): upstream LSB code with
    -- the soa/physical_hit_cap and wotg/pdif_caps_revert modules
    -- enabled, and (75-cap era) legacy WSC alpha.
    phoenix =
    {
        name = 'phoenix',

        -- modules/soa/lua/physical_hit_cap.lua: getPhysicalHitRateCap
        -- override returns 0.95 unconditionally (Dec 2014 cap raise
        -- reverted).
        hit_rate_cap_high = 0.95,
        hit_rate_cap_low  = 0.95,

        -- modules/wotg/lua/pdif_caps_revert.lua ("Original pDIF caps
        -- for the base game", dated one day before the ToAU 2H update).
        pdif_caps =
        {
            hand_to_hand = 2.0,
            dagger       = 2.0,
            sword        = 2.0,
            great_sword  = 2.0,
            axe          = 2.0,
            great_axe    = 2.0,
            scythe       = 2.0,
            polearm      = 2.0,
            katana       = 2.0,
            great_katana = 2.0,
            club         = 2.0,
            staff        = 2.0,
            archery      = 3.0,
            marksmanship = 3.0,
            throwing     = 3.0,
        },

        -- 75-cap servers run with USE_ADOULIN_WEAPON_SKILL_CHANGES off,
        -- which enables the legacy level-based WSC alpha. (Phoenix's
        -- deployed settings are not in their repo; the tracked default
        -- is the upstream `true`, but their ToAU-era WS modules and 75
        -- cap imply the legacy path. Flip this knob if observed
        -- otherwise in game.)
        legacy_alpha = true,

        -- fSTR keeps LSB's unfloored quarter-point fractions; set true
        -- for strict-era forks (e.g. AirSkyBoat) that compute integer
        -- fSTR via C++ integer division (truncation toward zero).
        fstr_integer = false,

        -- settings/default/main.lua DELAY_REDUCTION_CAP
        delay_reduction_cap = 0.80,
    },

    -- Upstream LandSandBoat defaults (commit fdc2471), no era modules.
    lsb =
    {
        name = 'lsb',

        hit_rate_cap_high = 0.99, -- 1H mainhand, H2H (incl. kicks)
        hit_rate_cap_low  = 0.95, -- 2H, offhand, ranged

        -- physical_utilities.lua: xi.combat.physical.pDifWeaponCapTable
        pdif_caps =
        {
            hand_to_hand = 3.5,
            dagger       = 3.25,
            sword        = 3.25,
            great_sword  = 3.75,
            axe          = 3.25,
            great_axe    = 3.75,
            scythe       = 4.0,
            polearm      = 3.75,
            katana       = 3.25,
            great_katana = 3.5,
            club         = 3.25,
            staff        = 3.75,
            archery      = 3.25,
            marksmanship = 3.5,
            throwing     = 3.25,
        },

        legacy_alpha        = false, -- Adoulin WS rules: alpha = 1
        fstr_integer        = false,
        delay_reduction_cap = 0.80,
    },
}

M.default_profile = M.PROFILES.phoenix

-- Accepts a profile name, a profile table, or nil (-> default).
local function get_profile(profile)
    if type(profile) == 'table' then
        return profile
    end

    if type(profile) == 'string' then
        local found = M.PROFILES[profile]

        if not found then
            error('whetstone.formulas: unknown profile ' .. profile)
        end

        return found
    end

    return M.default_profile
end

M.get_profile = get_profile

-- =====================================================================
-- Constants shared by every profile
-- =====================================================================

-- physical_hit_rate.lua: getPhysicalHitRate clamp floor
M.HIT_RATE_FLOOR = 0.20

-- battleentity.cpp GetWeaponDelay clamps
M.HASTE_CAP_MAGIC   = 0.4375 -- 43.75%
M.HASTE_CAP_ABILITY = 0.25
M.HASTE_CAP_GEAR    = 0.25

-- calculateMeleePDIF: melee random factor is 1 + random(0..5)/100,
-- six equally likely values -> mean 1.025
M.MELEE_RANDOM_MEAN = 1.025
M.MELEE_RANDOM_MAX  = 1.05

-- calculateMeleePDIF: level correction slope (per level of difference)
M.PDIF_LEVEL_FACTOR = 3 / 64

-- physical_hit_rate.lua: accuracyAndEvasionToHitRate correction
M.ACC_LEVEL_FACTOR = 4

-- =====================================================================
-- Weapon rank
-- battleentity.cpp: GetMainWeaponRank / GetSubWeaponRank
-- =====================================================================

-- weapon_dmg: the weapon's DMG value (base rating, without DMG_RATING
-- style modifiers such as Maneater's latent).
-- is_h2h: players get +3 added to H2H damage for rank purposes.
function M.weapon_rank(weapon_dmg, is_h2h)
    if is_h2h then
        weapon_dmg = weapon_dmg + 3
    end

    return floor(weapon_dmg / 9)
end

-- =====================================================================
-- fSTR (players / trusts, melee)
-- physical_utilities.lua: calculateMeleeStatFactor
-- =====================================================================

-- The shared piecewise "SV function": maps a (clamped) STR-VIT diff to
-- 4x the fSTR value.
local function fstr4(stat_diff)
    if stat_diff >= 12 then
        return stat_diff + 4
    elseif stat_diff >= 6 then
        return stat_diff + 6
    elseif stat_diff >= 1 then
        return stat_diff + 7
    elseif stat_diff >= -2 then
        return stat_diff + 8
    elseif stat_diff >= -7 then
        return stat_diff + 9
    elseif stat_diff >= -15 then
        return stat_diff + 10
    elseif stat_diff >= -21 then
        return stat_diff + 12
    else
        return stat_diff + 13
    end
end

-- Stat-diff clamp window for a given weapon rank (same for melee and
-- ranged in LSB).
function M.fstr_stat_diff_caps(weapon_rank)
    return (7 + weapon_rank * 2) * -2, (14 + weapon_rank * 2) * 2
end

-- Final fSTR value clamp for a given weapon rank (melee).
function M.fstr_value_caps(weapon_rank)
    local lower = -weapon_rank

    if weapon_rank == 0 then
        lower = -1
    end

    return lower, weapon_rank + 8
end

-- C++ integer division semantics (truncation toward zero), used by
-- strict-era forks for fSTR. Validated against AirSkyBoat's GetFSTR
-- (battleutils.cpp), which computes (dif + N) / 2 then /= 2 on int32.
local function trunc(value)
    if value >= 0 then
        return floor(value)
    end

    return math.ceil(value)
end

-- Player melee fSTR. NOTE: LSB/Phoenix do NOT floor the player value,
-- so this can return fractions in steps of 0.25 (e.g. 4.25). Profiles
-- with fstr_integer (strict-era forks) truncate toward zero instead.
function M.fstr(str, target_vit, weapon_rank, profile)
    local stat_lower, stat_upper = M.fstr_stat_diff_caps(weapon_rank)
    local stat_diff = clamp(str - target_vit, stat_lower, stat_upper)

    local value = fstr4(stat_diff) / 4

    if get_profile(profile).fstr_integer then
        value = trunc(value)
    end

    local value_lower, value_upper = M.fstr_value_caps(weapon_rank)

    return clamp(value, value_lower, value_upper)
end

-- Player ranged fSTR ("fSTR2").
-- physical_utilities.lua: calculateRangedStatFactor
function M.fstr_ranged(str, target_vit, weapon_rank, profile)
    local stat_lower, stat_upper = M.fstr_stat_diff_caps(weapon_rank)
    local stat_diff = clamp(str - target_vit, stat_lower, stat_upper)

    local value = fstr4(stat_diff) / 2

    if get_profile(profile).fstr_integer then
        value = trunc(value)
    end

    local value_lower = weapon_rank * -2
    local value_upper = (weapon_rank + 8) * 2

    if weapon_rank == 0 then
        value_lower = -2
    elseif weapon_rank == 1 then
        value_lower = -3
    end

    return clamp(value, value_lower, value_upper)
end

-- Mob / pet melee fSTR.
-- physical_utilities.lua: calculateMeleeStatFactor (mob branch)
function M.fstr_mob(str, target_vit, mob_level)
    if mob_level <= 1 then
        return 1
    end

    local stat_diff = str - target_vit
    local value

    if stat_diff >= 36 then
        value = (stat_diff - 4) / 4
    elseif stat_diff >= 26 then
        value = (stat_diff - 3) / 4
    elseif stat_diff >= 17 then
        value = (stat_diff - 2) / 4
    elseif stat_diff >= 4 then
        value = (stat_diff - 1) / 4
    elseif stat_diff >= -8 then
        value = stat_diff / 4
    elseif stat_diff >= -13 then
        value = (stat_diff + 1) / 4
    elseif stat_diff >= -19 then
        value = (stat_diff + 3) / 4
    elseif stat_diff >= -32 then
        value = (stat_diff + 4) / 4
    elseif stat_diff >= -42 then
        value = (stat_diff + 5) / 4
    elseif stat_diff >= -54 then
        value = (stat_diff + 6) / 4
    elseif stat_diff >= -67 then
        value = (stat_diff + 7) / 4
    elseif stat_diff >= -76 then
        value = (stat_diff + 8) / 4
    else
        value = (stat_diff + 9) / 4
    end

    value = floor(value)

    return clamp(value, floor(mob_level / 5) - 1, floor(mob_level / 5) + 5)
end

-- Advisor helper: where am I on the fSTR curve and how many STR points
-- until the next increase?
-- Returns a table:
--   fstr        current fSTR
--   at_cap      true when no amount of STR will raise fSTR vs this target
--   str_to_next STR points needed for the next strictly higher fSTR (nil at cap)
--   next_fstr   the fSTR value reached at that point (nil at cap)
function M.fstr_info(str, target_vit, weapon_rank, profile)
    local current = M.fstr(str, target_vit, weapon_rank, profile)
    local _, stat_upper = M.fstr_stat_diff_caps(weapon_rank)
    local headroom = stat_upper - (str - target_vit)

    if headroom > 0 then
        for add = 1, headroom do
            local candidate = M.fstr(str + add, target_vit, weapon_rank, profile)

            if candidate > current then
                return
                {
                    fstr        = current,
                    at_cap      = false,
                    str_to_next = add,
                    next_fstr   = candidate,
                }
            end
        end
    end

    return { fstr = current, at_cap = true }
end

-- =====================================================================
-- Hit rate
-- physical_hit_rate.lua: getPhysicalHitRate / accuracyAndEvasionToHitRate
-- =====================================================================

-- Which ceiling applies to a swing.
-- p: { h2h = bool, two_handed = bool, offhand = bool, profile = ... }
function M.hit_rate_cap(p)
    p = p or {}

    local profile = get_profile(p.profile)

    if p.h2h then
        return profile.hit_rate_cap_high
    end

    if p.two_handed or p.offhand then
        return profile.hit_rate_cap_low
    end

    return profile.hit_rate_cap_high
end

-- Level-correction accuracy term for a PLAYER attacker (players only
-- ever get the penalty, never the bonus).
local function acc_level_correction(p)
    if
        p.level_correction and
        p.attacker_level and
        p.target_level and
        p.attacker_level < p.target_level
    then
        return (p.attacker_level - p.target_level) * M.ACC_LEVEL_FACTOR
    end

    return 0
end

-- Player melee hit rate.
-- p:
--   acc, eva          (required) raw accuracy / target evasion
--   acc_bonus         additive accuracy (WS first hit +100, WSACC, ...)
--   attacker_level, target_level, level_correction
--   h2h, two_handed, offhand   -> selects the ceiling
--   floor_percent     if true, truncate to whole percent first
--                     (matches the C++ GetHitRateEx path used for
--                     regular melee rounds; WS rolls use the raw value)
-- Returns rate, capped_high (bool: at ceiling), capped_low (bool: at floor)
function M.hit_rate(p)
    local acc = p.acc + (p.acc_bonus or 0) + acc_level_correction(p)
    local cap = M.hit_rate_cap(p)

    local rate = (75 + (acc - p.eva) / 2) / 100
    local clamped = clamp(rate, M.HIT_RATE_FLOOR, cap)

    if p.floor_percent then
        clamped = floor(clamped * 100) / 100
    end

    return clamped, rate >= cap, rate <= M.HIT_RATE_FLOOR
end

-- Advisor helper: accuracy needed to sit exactly at the ceiling against
-- a given evasion (same params as hit_rate; acc ignored).
function M.acc_for_cap(p)
    local cap = M.hit_rate_cap(p)

    return p.eva + (cap * 100 - 75) * 2 - acc_level_correction(p)
end

-- =====================================================================
-- Haste stacking / weapon delay
-- battleentity.cpp: GetWeaponDelay
-- =====================================================================

-- p:
--   magic, ability, gear   haste fractions by category (0.25 == 25%)
--   two_hand_ability       Hasso etc. (added to ability when two_handed)
--   two_handed             bool
--   total_cap              server DELAY_REDUCTION_CAP (default 0.80)
-- Returns a table:
--   multiplier      final delay multiplier (1 - total clamped haste)
--   total           effective total haste fraction after all clamps
--   magic/ability/gear            the clamped per-category values
--   magic_overcap/ability_overcap/gear_overcap  wasted amount per category
--   total_overcap   haste lost to the overall delay-reduction cap
function M.haste(p)
    p = p or {}

    local total_cap = p.total_cap or get_profile(p.profile).delay_reduction_cap

    local magic   = clamp(p.magic or 0, -1.0, M.HASTE_CAP_MAGIC)
    local ability = (p.ability or 0)

    if p.two_handed then
        ability = ability + (p.two_hand_ability or 0)
    end

    ability = clamp(ability, -0.25, M.HASTE_CAP_ABILITY)

    local gear = clamp(p.gear or 0, -0.25, M.HASTE_CAP_GEAR)

    local uncapped_total = magic + ability + gear
    local multiplier     = clamp(1 - uncapped_total, 1 - total_cap, 2.0)

    return
    {
        multiplier      = multiplier,
        total           = 1 - multiplier,
        magic           = magic,
        ability         = ability,
        gear            = gear,
        magic_overcap   = max(0, (p.magic or 0) - magic),
        ability_overcap = max(0, (p.ability or 0) + (p.two_handed and (p.two_hand_ability or 0) or 0) - ability),
        gear_overcap    = max(0, (p.gear or 0) - gear),
        total_overcap   = max(0, uncapped_total - total_cap),
    }
end

-- Final swing delay in milliseconds.
-- p:
--   delay             mainhand delay in FFXI delay units (e.g. 480)
--   sub_delay         offhand delay units when dual wielding (nil otherwise)
--   martial_arts      Martial Arts delay reduction in delay units (H2H)
--   dual_wield        Dual Wield trait/gear as a fraction (0.25 == DW25)
--   haste_multiplier  output of M.haste().multiplier (default 1)
--   delay_p           Mod::DELAYP as a fraction (rare; default 0)
function M.weapon_delay_ms(p)
    local to_ms = 1000 / 60

    local weapon_delay = p.delay * to_ms
    local martial_arts = (p.martial_arts or 0) * to_ms
    local dual_wield_multiplier = 1

    if p.sub_delay then
        weapon_delay = weapon_delay + p.sub_delay * to_ms
        dual_wield_multiplier = 1 - (p.dual_wield or 0)
    end

    local final_delay = weapon_delay - martial_arts
    final_delay = final_delay * dual_wield_multiplier
    final_delay = final_delay * (p.haste_multiplier or 1)
    final_delay = final_delay * (1 + (p.delay_p or 0))

    return clamp(final_delay, weapon_delay * 0.2, weapon_delay * 2)
end

-- =====================================================================
-- pDIF (player melee)
-- physical_utilities.lua: calculateMeleePDIF / wRatioCapPC / getSpikeRatio
-- =====================================================================

-- Pre-randomizer pDIF bounds for players.
function M.wratio_caps_pc(wratio, final_cap)
    local upper

    if wratio < 0.5 then
        upper = wratio + 0.5
    elseif wratio < 0.7 then
        upper = 1
    elseif wratio < 1.2 then
        upper = wratio + 0.3
    elseif wratio < 1.5 then
        upper = wratio + wratio * 0.25
    else
        upper = min(wratio + 0.375, final_cap)
    end

    local lower

    if wratio < 0.38 then
        lower = 0
    elseif wratio < 1.25 then
        lower = wratio * 1176 / 1024 - 448 / 1024
    elseif wratio < 1.51 then
        lower = 1
    elseif wratio < 2.44 then
        lower = wratio * 1176 / 1024 - 775 / 1024
    else
        lower = min(wratio - 0.375, final_cap)
    end

    return lower, upper
end

-- Chance for the "spike" outcome where the swing rolls exactly 1.0.
function M.spike_chance_pc(wratio)
    if wratio > 0.5 and wratio < 1.5 then
        return clamp((0.5 - math.abs(wratio - 1)) * 1.2, 0, 1 / 3)
    end

    return 0
end

local function uniform_mean(lower, upper)
    if upper <= 0 then
        return 0
    end

    return (min(lower, upper) + upper) / 2
end

-- Player melee/WS pDIF distribution.
--
-- RNG model (calculateMeleePDIF, byte-identical in Phoenix and LSB):
--   1. spike roll: with probability spike_chance return exactly 1.0
--      (bypasses everything below, including the crit damage bonus)
--   2. coin flip: the upper bound's floor is 0.5 or 0 (50/50)
--   3. ONE uniform draw between the (level-corrected) lower and upper
--      bounds -- not a max/min of multiple draws
--   4. multiply by the melee random factor 1.00-1.05 (six values)
-- `expected` below is the exact closed-form mean of that process.
--
-- p:
--   attack, defense     (required)
--   weapon              key into the profile's pdif_caps, or pass pdif_cap
--   profile             'phoenix' (default) | 'lsb' | custom table
--   pdif_cap            explicit per-weapon cap (overrides weapon)
--   crit                bool
--   ws_attack_mod       WS attack multiplier ("atkVaries", default 1)
--   ignored_def_factor  fraction of defense ignored (Asuran Fists etc., default 0)
--   attacker_level, target_level, level_correction
--   crit_dmg_bonus      Mod::CRIT_DMG_INCREASE - target CRIT_DEF_BONUS, fraction
--   damage_limit        Mod::DAMAGE_LIMIT as fraction (era: 0)
--   damage_limit_p      Mod::DAMAGE_LIMITP as fraction (era: 0)
-- Returns a table:
--   ratio, wratio, final_cap, level_factor
--   lower, upper        pre-randomizer bounds (level-corrected)
--   spike_chance
--   expected            exact mean pDIF including spike + melee random
--   roll_min, roll_max  extreme single-roll outcomes (excluding spike)
--   at_cap              true when the upper bound is pinned at final_cap
function M.melee_pdif(p)
    local defense = max(1, p.defense)
    local ws_attack_mod = p.ws_attack_mod or 1

    if (p.ignored_def_factor or 0) ~= 0 then
        defense = max(1, floor(defense * (1 - p.ignored_def_factor)))
    end

    local attack = max(1, floor(p.attack * ws_attack_mod))
    local ratio  = attack / defense

    local level_factor = 0

    if p.level_correction and p.attacker_level and p.target_level then
        level_factor = (p.attacker_level - p.target_level) * M.PDIF_LEVEL_FACTOR

        -- Players never get positive level correction.
        if level_factor > 0 then
            level_factor = 0
        end
    end

    local crit_add = p.crit and 1 or 0
    local wratio   = ratio + crit_add

    local weapon_cap = p.pdif_cap or get_profile(p.profile).pdif_caps[p.weapon or 'sword']
    local final_cap  = (weapon_cap + (p.damage_limit or 0)) * (1 + (p.damage_limit_p or 0)) + crit_add

    local lower, upper = M.wratio_caps_pc(wratio, final_cap)
    local spike        = M.spike_chance_pc(wratio)

    -- Level correction shifts both bounds; the floor of the lower bound
    -- is 0 and the upper bound has a 50/50 floor of 0.5 or 0.
    local upper_corrected = upper + level_factor
    local lower_corrected = max(lower + level_factor, 0)

    local crit_mult = 1

    if p.crit then
        crit_mult = (100 + clamp((p.crit_dmg_bonus or 0) * 100, 0, 100)) / 100
    end

    -- Expectation of the uniform roll, averaged over the two equally
    -- likely upper-bound floors, times the mean melee random factor.
    local roll_mean = (
        uniform_mean(lower_corrected, max(upper_corrected, 0.5)) +
        uniform_mean(lower_corrected, max(upper_corrected, 0))
    ) / 2 * M.MELEE_RANDOM_MEAN * crit_mult

    -- The spike outcome returns exactly 1.0 and bypasses both the melee
    -- random factor and the crit damage bonus.
    local expected = spike * 1.0 + (1 - spike) * roll_mean

    return
    {
        ratio        = ratio,
        wratio       = wratio,
        final_cap    = final_cap,
        level_factor = level_factor,
        lower        = lower_corrected,
        upper        = upper_corrected,
        spike_chance = spike,
        expected     = expected,
        roll_min     = lower_corrected * crit_mult,
        roll_max     = max(upper_corrected, 0.5) * M.MELEE_RANDOM_MAX * crit_mult,
        at_cap       = wratio >= 1.5 and (wratio + 0.375) >= final_cap,
    }
end

-- Advisor helper: attack needed to pin the pDIF upper bound at the
-- weapon's final cap (the point where more attack stops helping the
-- best-case roll). Only meaningful in the wratio >= 1.5 branch, which
-- holds for every weapon cap in the table.
function M.attack_for_pdif_cap(p)
    local weapon_cap = p.pdif_cap or get_profile(p.profile).pdif_caps[p.weapon or 'sword']
    local crit_add   = p.crit and 1 or 0
    local final_cap  = (weapon_cap + (p.damage_limit or 0)) * (1 + (p.damage_limit_p or 0)) + crit_add

    local wratio_needed = final_cap - 0.375
    local ratio_needed  = wratio_needed - crit_add

    return math.ceil(ratio_needed * max(1, p.defense) / (p.ws_attack_mod or 1))
end

-- =====================================================================
-- Weapon skill support
-- weaponskills.lua / physical_utilities.lua
-- =====================================================================

-- Legacy WSC alpha (servers with USE_ADOULIN_WEAPON_SKILL_CHANGES off).
-- weaponskills.lua: calculateRawWSDmg
function M.alpha(level)
    if level > 75 then
        return 0.85
    elseif level > 59 then
        return 0.9 - floor((level - 60) / 2) / 100
    elseif level > 5 then
        return 1 - floor(level / 6) / 100
    end

    return 1
end

-- fTP interpolation. ftp_table = { value@1000, value@2000, value@3000 }.
-- Returns 1 when the table is nil (xi.weaponskills.fTP semantics).
function M.ftp(tp, ftp_table)
    if not ftp_table or tp < 1000 then
        return 1
    end

    if tp >= 2000 then
        return ftp_table[2] + (tp - 2000) * (ftp_table[3] - ftp_table[2]) / 1000
    end

    return ftp_table[1] + (tp - 1000) * (ftp_table[2] - ftp_table[1]) / 1000
end

-- TP factor used for "crit rate varies with TP" etc.
-- physical_utilities.lua: calculateTPfactor - note the different
-- nil/low-TP behavior vs M.ftp (returns 0 for nil, table[1] below 1000).
function M.tp_factor(tp, tp_table)
    if not tp_table then
        return 0
    end

    if tp >= 2000 then
        return tp_table[2] + (tp - 2000) * (tp_table[3] - tp_table[2]) / 1000
    elseif tp >= 1000 then
        return tp_table[1] + (tp - 1000) * (tp_table[2] - tp_table[1]) / 1000
    end

    return tp_table[1]
end

-- WS secondary attribute contribution (WSC), before alpha.
-- stats = { str = , dex = , vit = , agi = , int = , mnd = , chr = }
-- mods  = same keys, fractional modifiers (0.3 == 30%)
function M.wsc(stats, mods)
    local total = 0

    for _, key in ipairs({ 'str', 'dex', 'vit', 'agi', 'int', 'mnd', 'chr' }) do
        local mod = mods[key]

        if mod and mod ~= 0 then
            total = total + floor((stats[key] or 0) * mod)
        end
    end

    return total
end

-- Crit rate bonus from dDEX.
-- physical_utilities.lua: criticalRateFromStatDiff
function M.crit_rate_from_dex(dex, target_agi)
    local diff = dex - target_agi

    if diff > 50 then
        return 0.15
    elseif diff >= 40 then
        return (diff - 35) / 100
    elseif diff >= 30 then
        return 0.04
    elseif diff >= 20 then
        return 0.03
    elseif diff >= 14 then
        return 0.02
    elseif diff >= 7 then
        return 0.01
    end

    return 0
end

-- Swing crit rate (base 5% + dDEX + flat bonuses), clamped to [5%, 100%].
function M.crit_rate(p)
    local rate = 0.05
        + M.crit_rate_from_dex(p.dex or 0, p.target_agi or 0)
        + (p.bonus or 0)
        + M.tp_factor(p.tp or 0, p.crit_varies)

    return clamp(rate, 0.05, 1)
end

-- =====================================================================
-- Expected weapon skill damage
-- weaponskills.lua: doPhysicalWeaponskill + calculateRawWSDmg
-- =====================================================================

--[[
    Deterministic expectation of a physical WS, replicating the LSB
    pipeline (excluding parry/block/shadows/enemy SDT, which the advisor
    treats separately):

      mainBase    = floor(D + fSTR + bonusWSmods + WSC * alpha)
      offhandBase = D_off + fSTR + WSC * alpha          (NOT floored)
      hit dmg     = base * fTP * pDIF
      fTP applies to the first hit only unless multi_hit_ftp
      first hit rolls with +100 accuracy
      offhand swings use the 95% hit cap
      crits only occur when crit_varies is set (plus flat crit bonuses)

    p:
      weapon_dmg          mainhand D (for H2H pass D + floor-less
                          h2h skill*0.11+3 yourself, or use h2h_skill)
      offhand_dmg         offhand D; nil when not dual wielding
      h2h_skill           if set, both "weapons" get skill*0.11+3 added
                          and weapon is forced to hand_to_hand
      fstr                from M.fstr()
      stats               { str=, dex=, ... } for WSC / crit
      ws                  {
                            ftp        = {a, b, c} or nil,
                            num_hits   = 1..8,
                            mods       = { str = 0.3, ... },
                            atk_varies     = {a, b, c} or flat number or nil,
                            crit_varies    = {a, b, c} or nil,
                            ignored_def    = {a, b, c} or nil,
                            multi_hit_ftp  = bool,
                            bonus_ws_mods  = flat addition to mainBase,
                          }
      tp                  1000..3000
      attack, defense     player attack (incl. food/buffs), target defense
      acc, eva            player accuracy, target evasion
      bonus_acc           WS accuracy bonuses (gear WSACC, elemental gorgets...)
      attacker_level, target_level, level_correction
      alpha               override; defaults to M.alpha(attacker_level)
      weapon              PDIF_WEAPON_CAP key (also picks 2H hit cap if
                          two_handed not given)
      two_handed          override hit-rate ceiling selection
      target_agi          for crit rate dDEX... (uses stats.dex)
      crit_bonus          flat crit rate additions (gear/merits), fraction
      crit_dmg_bonus      fraction
      ws_dmg_bonus        ALL_WSDMG_ALL_HITS as fraction (era gear: 0)
      first_hit_bonus     ALL_WSDMG_FIRST_HIT as fraction
      extra_main_swings   expected bonus mainhand swings (DA/TA procs)

    Returns a table:
      expected            expected total damage
      main_base, offhand_base, wsc, ftp, alpha
      first_hit_rate, extra_hit_rate, offhand_hit_rate
      crit_rate
      pdif                melee_pdif() result for a normal hit
      pdif_crit           melee_pdif() result for a crit (nil if crit_rate 0)
      swings              total swings counted (capped at 8)
]]
function M.ws_damage(p)
    local ws      = p.ws
    local profile = get_profile(p.profile)
    local alpha   = p.alpha

    if not alpha then
        -- Legacy-era servers (USE_ADOULIN_WEAPON_SKILL_CHANGES off) use
        -- the level-based alpha; Adoulin rules dropped it entirely.
        alpha = profile.legacy_alpha and M.alpha(p.attacker_level) or 1
    end

    local weapon_dmg  = p.weapon_dmg
    local offhand_dmg = p.offhand_dmg
    local is_h2h      = p.h2h_skill ~= nil
    local weapon      = p.weapon

    if is_h2h then
        local natural = p.h2h_skill * 0.11 + 3
        weapon_dmg  = weapon_dmg + natural
        offhand_dmg = weapon_dmg
        weapon      = 'hand_to_hand'
    end

    local wsc = M.wsc(p.stats or {}, ws.mods or {})

    local main_base = floor(weapon_dmg + p.fstr + (ws.bonus_ws_mods or 0) + wsc * alpha)
    local offhand_base = nil

    if offhand_dmg then
        offhand_base = offhand_dmg + p.fstr + wsc * alpha
    end

    -- fTP for the first hit; later hits revert to 1 unless multi_hit_ftp.
    local ftp_first = M.ftp(p.tp, ws.ftp) + (p.bonus_ftp or 0)
    local ftp_rest  = ws.multi_hit_ftp and ftp_first or 1

    -- WS attack multiplier may be TP-varying or flat.
    local atk_mod = 1

    if type(ws.atk_varies) == 'table' then
        atk_mod = M.ftp(p.tp, ws.atk_varies)
    elseif type(ws.atk_varies) == 'number' then
        atk_mod = ws.atk_varies
    end

    local ignored_def = 0

    if ws.ignored_def then
        ignored_def = M.ftp(p.tp, ws.ignored_def)
    end

    -- "Accuracy varies with TP" (weaponskills.lua: accMod added to
    -- bonusAcc via the fTP interpolator).
    local acc_varies_bonus = 0

    if ws.acc_varies then
        acc_varies_bonus = M.ftp(p.tp, ws.acc_varies)
    end

    -- Crit rate: only crit-varies weapon skills can crit naturally.
    local crit_rate = 0

    if ws.crit_varies then
        crit_rate = M.crit_rate(
        {
            dex         = (p.stats or {}).dex,
            target_agi  = p.target_agi,
            bonus       = p.crit_bonus,
            tp          = p.tp,
            crit_varies = ws.crit_varies,
        })
    end

    local pdif_params =
    {
        attack             = p.attack,
        defense            = p.defense,
        weapon             = weapon,
        pdif_cap           = p.pdif_cap,
        profile            = profile,
        ws_attack_mod      = atk_mod,
        ignored_def_factor = ignored_def,
        attacker_level     = p.attacker_level,
        target_level       = p.target_level,
        level_correction   = p.level_correction,
        crit_dmg_bonus     = p.crit_dmg_bonus,
    }

    local pdif = M.melee_pdif(pdif_params)
    local pdif_crit = nil
    local expected_pdif = pdif.expected

    if crit_rate > 0 then
        local crit_params = {}

        for key, value in pairs(pdif_params) do
            crit_params[key] = value
        end

        crit_params.crit = true
        pdif_crit = M.melee_pdif(crit_params)

        expected_pdif = (1 - crit_rate) * pdif.expected + crit_rate * pdif_crit.expected
    end

    -- Hit rates: first hit gets +100 acc; mainhand swings use the
    -- mainhand ceiling, the offhand swing uses the offhand ceiling.
    local two_handed = p.two_handed

    if two_handed == nil and weapon then
        two_handed =
            weapon == 'great_sword' or weapon == 'great_axe' or
            weapon == 'scythe' or weapon == 'polearm' or
            weapon == 'great_katana' or weapon == 'staff'
    end

    local hit_params =
    {
        acc              = p.acc,
        eva              = p.eva,
        attacker_level   = p.attacker_level,
        target_level     = p.target_level,
        level_correction = p.level_correction,
        h2h              = is_h2h,
        two_handed       = two_handed,
        profile          = profile,
    }

    hit_params.acc_bonus = (p.bonus_acc or 0) + acc_varies_bonus + 100
    local first_hit_rate = M.hit_rate(hit_params)

    hit_params.acc_bonus = (p.bonus_acc or 0) + acc_varies_bonus
    local extra_hit_rate = M.hit_rate(hit_params)

    hit_params.offhand = true
    local offhand_hit_rate = M.hit_rate(hit_params)

    -- Swing accounting (LSB caps a WS at 8 swings total).
    local main_swings  = (ws.num_hits or 1) + (p.extra_main_swings or 0)
    local total_swings = main_swings + (offhand_base and 1 or 0)

    if total_swings > 8 then
        local over = total_swings - 8

        main_swings  = main_swings - over
        total_swings = 8
    end

    local expected = main_base * ftp_first * expected_pdif * first_hit_rate

    if main_swings > 1 then
        expected = expected
            + main_base * ftp_rest * expected_pdif * extra_hit_rate * (main_swings - 1)
    end

    if offhand_base then
        expected = expected
            + offhand_base * ftp_rest * expected_pdif * offhand_hit_rate
    end

    expected = expected * (1 + (p.ws_dmg_bonus or 0))
    expected = expected
        + main_base * ftp_first * expected_pdif * first_hit_rate * (p.first_hit_bonus or 0)

    return
    {
        expected         = expected,
        main_base        = main_base,
        offhand_base     = offhand_base,
        wsc              = wsc,
        alpha            = alpha,
        ftp              = ftp_first,
        atk_mod          = atk_mod,
        crit_rate        = crit_rate,
        pdif             = pdif,
        pdif_crit        = pdif_crit,
        expected_pdif    = expected_pdif,
        first_hit_rate   = first_hit_rate,
        extra_hit_rate   = extra_hit_rate,
        offhand_hit_rate = offhand_hit_rate,
        swings           = total_swings,
    }
end

-- =====================================================================
-- Expected auto-attack swing (advisor convenience)
-- =====================================================================

-- Expected damage of one mainhand auto-attack swing, blending crits.
-- p: melee_pdif params plus
--   weapon_dmg, fstr
--   acc, eva, acc_bonus + hit rate level params
--   crit_rate (fraction; build via M.crit_rate)
function M.melee_swing(p)
    local base = p.weapon_dmg + p.fstr

    local pdif_params =
    {
        attack           = p.attack,
        defense          = p.defense,
        weapon           = p.weapon,
        pdif_cap         = p.pdif_cap,
        profile          = p.profile,
        attacker_level   = p.attacker_level,
        target_level     = p.target_level,
        level_correction = p.level_correction,
        crit_dmg_bonus   = p.crit_dmg_bonus,
    }

    local normal = M.melee_pdif(pdif_params)

    pdif_params.crit = true
    local crit = M.melee_pdif(pdif_params)

    local crit_rate = p.crit_rate or 0
    local expected_pdif = (1 - crit_rate) * normal.expected + crit_rate * crit.expected

    local hit_rate = M.hit_rate(
    {
        acc              = p.acc,
        eva              = p.eva,
        acc_bonus        = p.acc_bonus,
        attacker_level   = p.attacker_level,
        target_level     = p.target_level,
        level_correction = p.level_correction,
        h2h              = p.h2h,
        two_handed       = p.two_handed,
        offhand          = p.offhand,
        profile          = p.profile,
        floor_percent    = true,
    })

    return
    {
        expected      = base * expected_pdif * hit_rate,
        base          = base,
        hit_rate      = hit_rate,
        pdif          = normal,
        pdif_crit     = crit,
        expected_pdif = expected_pdif,
    }
end

return M
