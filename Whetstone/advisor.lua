--[[
    Whetstone - advisor.lua

    Pure-Lua advisor: combines formulas.lua, the generated data tables
    (mobs/weaponskills/items) and the player snapshot into RANKED
    ACTIONABLE DELTAS - each line is a concrete change plus its
    expected damage gain, not a stat dump.

    Param routing guard (the atkVaries/fTP trap):
      The WS database carries the server's params VERBATIM. Wiki tables
      routinely blur "attack varies with TP" into fTP; the server does
      not. adapt_ws_params() routes each param down the same path
      weaponskills.lua does:
        ftpMod      -> fTP        (base damage MULTIPLIER, first hit)
        atkVaries   -> wsAttackMod (pDIF ATTACK input, before the ratio)
        critVaries  -> swing crit rate TP factor
        accVaries   -> accuracy bonus
        ignoredDefense -> defense reduction factor
      so server-vs-wiki comparisons stay apples-to-apples.

    Mob disambiguation:
      Same-name spawns with different level rows are evaluated as a SET
      of candidates and every metric is surfaced as a range until
      something narrows it (checker result, widescan level, user pin).
      Use narrow{} with a known level to collapse the range.

    Zero Ashita dependencies; fully unit-tested.
]]

local formulas = require('formulas')

local M = {}

local floor = math.floor

-- =====================================================================
-- WS parameter adapter (verbatim server params -> formulas inputs)
-- =====================================================================

-- entry: one record from data/weaponskills.lua
-- Returns a `ws` table for formulas.ws_damage, or nil for entries the
-- damage model cannot rank (specials, magic WS).
function M.adapt_ws_params(entry)
    if entry.kind ~= 'physical' then
        return nil
    end

    local p = entry.params or {}

    -- A dynamic transcript value (string placeholder) means the server
    -- computes this from live state; refuse to guess.
    for _, value in pairs(p) do
        if type(value) == 'string' and value:find('<dynamic') then
            return nil
        end
    end

    return
    {
        -- fTP path: base damage multiplier (first hit unless multiHitfTP)
        ftp           = p.ftpMod,
        multi_hit_ftp = p.multiHitfTP and true or nil,

        -- pDIF path: attack multiplier ONLY - never merged into fTP
        atk_varies    = p.atkVaries,

        crit_varies   = p.critVaries,
        acc_varies    = p.accVaries,
        ignored_def   = p.ignoredDefense,

        num_hits      = p.numHits or 1,

        mods =
        {
            str = p.str_wsc,
            dex = p.dex_wsc,
            vit = p.vit_wsc,
            agi = p.agi_wsc,
            int = p.int_wsc,
            mnd = p.mnd_wsc,
            chr = p.chr_wsc,
        },
    }
end

-- =====================================================================
-- Mob candidate handling
-- =====================================================================

-- Exact per-level lookup: the generated mob table carries a row for
-- EVERY level in the spawn range (the server stat function is exact,
-- so nothing is approximated). Out-of-range levels clamp to the ends.
function M.stats_at_level(entry, level)
    if level < entry.min_level then
        level = entry.min_level
    elseif level > entry.max_level then
        level = entry.max_level
    end

    return entry.levels[level]
end

-- p: { mobs = mob_db, zone = id, name = 'Mob Name', level = optional }
-- Returns { entries = {...}, pinned_level, level_min, level_max,
--           ambiguous = bool, points = { {level, stats, entry}... } }
-- `points` is the evaluation set: two points (min/max) per candidate,
-- or a single interpolated point per candidate when level is pinned.
function M.candidates(p)
    local zone_table = (p.mobs or {})[p.zone] or {}
    local entries = zone_table[p.name] or {}

    if p.level then
        local filtered = {}

        for _, entry in ipairs(entries) do
            if p.level >= entry.min_level and p.level <= entry.max_level then
                filtered[#filtered + 1] = entry
            end
        end

        -- A bad pin (checker lied / level out of range) falls back to
        -- the full candidate set rather than returning nothing.
        if #filtered > 0 then
            entries = filtered
        end
    end

    local points = {}
    local level_min, level_max

    for _, entry in ipairs(entries) do
        level_min = math.min(level_min or entry.min_level, entry.min_level)
        level_max = math.max(level_max or entry.max_level, entry.max_level)

        if p.level then
            points[#points + 1] =
            {
                level = p.level,
                stats = M.stats_at_level(entry, p.level),
                entry = entry,
            }
        else
            points[#points + 1] =
                { level = entry.min_level,
                  stats = M.stats_at_level(entry, entry.min_level),
                  entry = entry }

            if entry.max_level ~= entry.min_level then
                points[#points + 1] =
                    { level = entry.max_level,
                      stats = M.stats_at_level(entry, entry.max_level),
                      entry = entry }
            end
        end
    end

    return
    {
        entries      = entries,
        points       = points,
        pinned_level = p.level,
        level_min    = level_min,
        level_max    = level_max,
        ambiguous    = #points > 1,
    }
end

local function point_range(points, evaluate)
    local worst, best -- worst = hardest target (lowest output)

    for _, point in ipairs(points) do
        local value = evaluate(point)

        if not worst or value.metric < worst.metric then
            worst = value
        end

        if not best or value.metric > best.metric then
            best = value
        end
    end

    return worst, best
end

-- =====================================================================
-- Evaluation
-- =====================================================================

local function round1(x)
    return floor(x * 10 + 0.5) / 10
end

--[[
    M.evaluate(p) -> report

    p:
      player = {
        level, main_job ('WAR'), stats = { str=, dex=, ... },
        attack, accuracy,
        weapon = { dmg, delay, skill = 'great_axe', h2h_skill = nil },
        offhand_dmg = nil,
        crit_rate_bonus = 0, ws_acc_bonus = 0, ws_skill = nil,
      }
      haste  = output of player.haste_report() (optional)
      target = { zone =, name =, level = nil } -- vs data.mobs
               OR points/entries prebuilt via M.candidates
      data   = { mobs = mob_db, ws = ws_db }
      tp     = current TP (default 1000)
      level_correction = bool (zone-corrected)
      profile = formulas profile (default module default)

    Returns:
      target = candidates() result (with name)
      lines  = ranked { kind, text, delta (fraction or nil),
                        estimated (bool) } - highest delta first
      ws     = ranked { name, expected, expected_best, entry } vs the
               WORST candidate point (range shown when ambiguous)
]]
function M.evaluate(p)
    local player = p.player
    local tp = p.tp or 1000
    local profile = p.profile

    local target = p.target.points and p.target
        or M.candidates({
            mobs = (p.data or {}).mobs,
            zone = p.target.zone,
            name = p.target.name,
            level = p.target.level,
        })
    target.name = target.name or p.target.name

    if #target.points == 0 then
        return { target = target, lines = {}, ws = {},
                 error = 'unknown mob' }
    end

    local weapon = player.weapon
    local is_h2h = weapon.skill == 'hand_to_hand'
    local two_handed = weapon.skill == 'great_sword'
        or weapon.skill == 'great_axe' or weapon.skill == 'scythe'
        or weapon.skill == 'polearm' or weapon.skill == 'great_katana'
        or weapon.skill == 'staff'

    local weapon_rank = formulas.weapon_rank(weapon.dmg, is_h2h)

    local lines = {}

    local function add(kind, text, delta, estimated)
        lines[#lines + 1] =
        {
            kind = kind,
            text = text,
            delta = delta,
            estimated = estimated or false,
        }
    end

    -- Baseline expected white-damage swing vs one candidate point.
    local function swing(point, overrides)
        overrides = overrides or {}

        return formulas.melee_swing(
        {
            weapon_dmg       = weapon.dmg,
            fstr             = overrides.fstr or formulas.fstr(
                player.stats.str, point.stats.vit, weapon_rank, profile),
            attack           = overrides.attack or player.attack,
            defense          = point.stats.def,
            weapon           = weapon.skill,
            acc              = overrides.acc or player.accuracy,
            eva              = point.stats.eva,
            attacker_level   = player.level,
            target_level     = point.level,
            level_correction = p.level_correction,
            crit_rate        = overrides.crit_rate or formulas.crit_rate(
            {
                dex        = player.stats.dex,
                target_agi = point.stats.agi,
                bonus      = player.crit_rate_bonus,
                kind       = 'melee', -- GetCritHitRate path: floor 0
            }),
            h2h              = is_h2h,
            two_handed       = two_handed,
            profile          = profile,
        })
    end

    -- ----- 1. Accuracy: distance to the hit rate ceiling --------------
    do
        local worst = nil -- highest-evasion point

        for _, point in ipairs(target.points) do
            if not worst or point.stats.eva > worst.stats.eva then
                worst = point
            end
        end

        local cap = formulas.hit_rate_cap({ h2h = is_h2h,
                                            two_handed = two_handed,
                                            profile = profile })
        local rate = formulas.hit_rate(
        {
            acc              = player.accuracy,
            eva              = worst.stats.eva,
            attacker_level   = player.level,
            target_level     = worst.level,
            level_correction = p.level_correction,
            h2h              = is_h2h,
            two_handed       = two_handed,
            profile          = profile,
        })

        if rate >= cap then
            add('acc', string.format('Accuracy capped (%.0f%%)%s',
                cap * 100,
                target.ambiguous
                    and string.format(' even vs Lv.%d', worst.level) or ''),
                nil)
        else
            local needed = formulas.acc_for_cap(
            {
                eva              = worst.stats.eva,
                attacker_level   = player.level,
                target_level     = worst.level,
                level_correction = p.level_correction,
                h2h              = is_h2h,
                two_handed       = two_handed,
                profile          = profile,
            })
            local gap = math.ceil(needed - player.accuracy)
            local delta = cap / rate - 1 -- white damage scales with hit rate

            add('acc', string.format(
                '+%d acc to cap vs Lv.%d (%.0f%% -> %.0f%%, +%.1f%% melee)',
                gap, worst.level, rate * 100, cap * 100, delta * 100),
                delta, target.ambiguous and not target.pinned_level)
        end
    end

    -- ----- 2. Gear haste overcap --------------------------------------
    if p.haste then
        local wasted = math.max(p.haste.gear_overcap or 0,
                                p.haste.total_overcap or 0)

        if wasted > 0 then
            -- Swing rate gain if the wasted fraction were converted
            -- into useful stats instead.
            local delta = wasted / (p.haste.multiplier or 1)

            add('haste', string.format(
                '%.2f%% gear haste wasted past cap - swap for acc/att',
                wasted * 100), delta)
        end
    end

    -- ----- 3. fSTR tier distance --------------------------------------
    do
        local worst, _ = point_range(target.points, function(point)
            return { metric = -point.stats.vit, point = point }
        end)
        local point = worst.point -- highest VIT candidate

        local info = formulas.fstr_info(player.stats.str, point.stats.vit,
                                        weapon_rank, profile)

        if not info.at_cap then
            local now = swing(point)
            local next_tier = swing(point, { fstr = info.next_fstr })
            local delta = next_tier.expected / now.expected - 1

            add('fstr', string.format(
                '+%d STR -> fSTR %.2f (+%.1f%% per swing)',
                info.str_to_next, info.next_fstr, delta * 100),
                delta, target.ambiguous and not target.pinned_level)
        else
            add('fstr', 'fSTR capped vs this target', nil)
        end
    end

    -- ----- 3b. dDEX crit tier distance ---------------------------------
    do
        local worst, _ = point_range(target.points, function(point)
            return { metric = -point.stats.agi, point = point }
        end)
        local point = worst.point -- highest AGI candidate

        local info = formulas.crit_info(player.stats.dex, point.stats.agi)

        -- Informational "at cap" is noise; only a reachable tier with a
        -- real damage delta earns a ranked line.
        if not info.at_cap then
            local base_rate = formulas.crit_rate(
            {
                dex        = player.stats.dex,
                target_agi = point.stats.agi,
                bonus      = player.crit_rate_bonus,
                kind       = 'melee',
            })
            local next_rate = formulas.clamp(
                base_rate + (info.next_bonus - info.bonus), 0, 1)

            local now = swing(point, { crit_rate = base_rate })
            local bumped = swing(point, { crit_rate = next_rate })
            local delta = bumped.expected / now.expected - 1

            if delta > 0 then
                add('crit', string.format(
                    '+%d DEX -> +%.0f%% crit (+%.1f%% per swing)',
                    info.dex_to_next,
                    (info.next_bonus - info.bonus) * 100, delta * 100),
                    delta, target.ambiguous and not target.pinned_level)
            end
        end
    end

    -- ----- 4. Attack / pDIF headroom -----------------------------------
    do
        local worst, _ = point_range(target.points, function(point)
            return { metric = -point.stats.def, point = point }
        end)
        local point = worst.point -- highest DEF candidate

        local needed = formulas.attack_for_pdif_cap(
        {
            defense = point.stats.def,
            weapon  = weapon.skill,
            profile = profile,
        })

        if player.attack >= needed then
            add('attack', string.format(
                'pDIF capped vs DEF %d (att %d/%d) - trade att for acc/STR',
                point.stats.def, player.attack, needed), nil)
        else
            local now = swing(point)
            local plus = swing(point, { attack = player.attack + 10 })
            local delta = plus.expected / now.expected - 1

            add('attack', string.format(
                '+%d att to pDIF cap vs DEF %d (+%.1f%% per 10 att)',
                needed - player.attack, point.stats.def, delta * 100),
                delta, target.ambiguous and not target.pinned_level)
        end
    end

    -- ----- 5. Weapon skill ranking at current TP -----------------------
    local ws_ranked = {}

    if p.data and p.data.ws then
        for name, entry in pairs(p.data.ws) do
            local usable = entry.skill == weapon.skill

            if usable and player.main_job and #entry.jobs > 0 then
                usable = false

                for _, job in ipairs(entry.jobs) do
                    if job == player.main_job then
                        usable = true
                        break
                    end
                end
            end

            -- Real (module-corrected) skill threshold: never rank a WS
            -- the player's combat skill hasn't unlocked.
            if usable and player.ws_skill then
                usable = entry.skill_level <= player.ws_skill
            end

            -- Quest WS (unlock_id > 0, e.g. the 240-skill quests):
            -- quest completion flags are not readable from the client,
            -- so these are EXCLUDED unless the user toggles them on
            -- (/whet quest). Recommending an unobtained Decimation is
            -- worse than omitting an obtained one.
            if usable and entry.unlock_id and entry.unlock_id > 0
                and not p.assume_quest_ws then
                usable = false
            end

            local ws = usable and M.adapt_ws_params(entry) or nil

            if ws then
                local worst, best = point_range(target.points,
                    function(point)
                        local result = formulas.ws_damage(
                        {
                            weapon_dmg       = weapon.dmg,
                            offhand_dmg      = player.offhand_dmg,
                            h2h_skill        = is_h2h and weapon.h2h_skill
                                               or nil,
                            fstr             = formulas.fstr(
                                player.stats.str, point.stats.vit,
                                weapon_rank, profile),
                            stats            = player.stats,
                            ws               = ws,
                            tp               = tp,
                            attack           = player.attack,
                            defense          = point.stats.def,
                            acc              = player.accuracy,
                            eva              = point.stats.eva,
                            bonus_acc        = player.ws_acc_bonus,
                            attacker_level   = player.level,
                            target_level     = point.level,
                            level_correction = p.level_correction,
                            weapon           = weapon.skill,
                            two_handed       = two_handed,
                            target_agi       = point.stats.agi,
                            crit_bonus       = player.crit_rate_bonus,
                            profile          = profile,
                        })

                        return { metric = result.expected,
                                 result = result }
                    end)

                ws_ranked[#ws_ranked + 1] =
                {
                    name          = name,
                    expected      = worst.metric,
                    expected_best = best.metric,
                    entry         = entry,
                }
            end
        end

        table.sort(ws_ranked, function(a, b)
            if a.expected ~= b.expected then
                return a.expected > b.expected
            end
            return a.name < b.name
        end)

        if #ws_ranked > 0 then
            local top = ws_ranked[1]
            local text

            if target.ambiguous and top.expected_best > top.expected then
                text = string.format('Best WS @%d TP: %s (~%d-%d)',
                    tp, top.name, floor(top.expected),
                    floor(top.expected_best))
            else
                text = string.format('Best WS @%d TP: %s (~%d)',
                    tp, top.name, floor(top.expected))
            end

            local delta = nil

            if ws_ranked[2] and ws_ranked[2].expected > 0 then
                delta = top.expected / ws_ranked[2].expected - 1
                text = text .. string.format(' - %.0f%% over %s',
                    delta * 100, ws_ranked[2].name)
            end

            add('ws', text, delta,
                target.ambiguous and not target.pinned_level)
        end
    end

    -- ----- Rank: largest gain first, informational lines last ----------
    table.sort(lines, function(a, b)
        if (a.delta ~= nil) ~= (b.delta ~= nil) then
            return a.delta ~= nil
        end
        if a.delta == nil then
            return a.kind < b.kind
        end
        return a.delta > b.delta
    end)

    return
    {
        target = target,
        lines  = lines,
        ws     = ws_ranked,
    }
end

return M
