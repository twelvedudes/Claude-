--[[
    Whetstone - swinglog.lua

    Predicted-vs-observed damage logging for beta validation
    (/whet debug). Parses incoming 0x028 action packets, extracts
    melee rounds and weapon skills against the player's current
    predictions, and emits log lines suitable for offline comparison
    (E[pDIF] distribution, hit rates, WS averages).

    Bit layout replicated from Phoenix
    src/map/packets/s2c/0x028_battle2.cpp pack()/unpack(), starting at
    bit 40 (after the 4-byte header + 1-byte workSize):

        actor id 32 | trg_sum 6 | res_sum 4 | cmd_no 4 | cmd_arg 32 |
        info 32 | per target: id 32, result count 4 | per result:
        reaction 3, kind 2, animation 12, info 5, distortion 2,
        knockback 3, param 17 (damage), message 10, modifier 31,
        add-effect flag 1 [+ 6/4/17/10], spikes flag 1 [+ 6/4/14/10]

    unpackBitsBE (despite the name) reads bits from a LITTLE-ENDIAN
    byte aggregate; read_bits below matches it exactly and is verified
    by a round-trip test against an independent packer.

    Categories (cmd_no): 1 = melee attack round, 3 = weapon skill
    finish. Melee messages: 1 hit, 67 crit, 15/63 miss-ish variants.

    Everything here is pure Lua; whetstone.lua owns the file I/O.
]]

local M = {}

local floor = math.floor

M.CATEGORY_MELEE = 1
M.CATEGORY_WS    = 3

M.MSG_HIT  = 1
M.MSG_CRIT = 67
M.MSG_MISS = 15

-- =====================================================================
-- Monotonic millisecond stamps + duplicate-packet rejection
-- =====================================================================

-- Injectable monotonic clock (seconds, ms resolution): os.clock is
-- process-monotonic under Ashita; tests substitute their own.
M.clock = os.clock

-- Wall time for humans + a monotonic t= for analysis: wall HH:MM:SS
-- can repeat/jump, t never does, so de-dup and interval analysis ride
-- t while the log stays readable.
local function stamp()
    return string.format('%s t=%.3f', os.date('%H:%M:%S'), M.clock())
end

-- FIELD FINDING (v0.1.7 log, Horizon): identical action packets were
-- observed parsed 2-3x within the same second (3 identical hit18+miss
-- pairs at 07:10:20; 12,14,12,14 at 07:10:27) - with 15+ addons
-- loaded, packet re-injection makes the same raw payload arrive more
-- than once. A genuine repeat of the SAME payload (same damage rolls
-- on every hit) inside 200ms is overwhelmingly unlikely (swing rounds
-- are seconds apart; multi-hits share one packet), so the raw payload
-- string within a 200ms window is the de-dup key.
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

-- Returns { actor, category, action_id, targets = { { id, results =
-- { { reaction, animation, damage, message, ... } } } } } or nil.
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
    take(32) -- recast/info

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
-- Predicted-vs-observed collection
-- =====================================================================

-- expectations: set by the addon every time the advisor runs:
--   { swing = melee_swing result, target_name, target_level_range,
--     ws = { [action_id] = { name, expected } } }
M.expectations = nil

function M.set_expectations(expectations)
    M.expectations = expectations
end

-- Feed a parsed action. Returns an array of log lines (possibly
-- empty); the caller decides where they go.
-- player_id: the local player's server id; only their actions count.
--
-- LINE SEMANTICS (mirrored in README + tools/analyze_swings.py):
--   melee: one line PER SWING RESULT. 'hit'/'crit' lines are landed
--     swings; 'miss' lines log observed=0. predicted_mean is the
--     PER-ATTEMPT expectation (includes hit rate); predicted_landed
--     is the per-LANDED-swing mean (crit-blended, no hit rate) -
--     landed observations compare against predicted_landed.
--   ws: one line PER USE (attempt). observed totals the landed hits
--     (0 when everything whiffed), hits=landed/rolled. predicted_mean
--     is the per-attempt expectation including hit rates, so ws
--     compares attempt-to-attempt as-is.
function M.observe(action, player_id)
    if not action or action.actor ~= player_id or not M.expectations then
        return {}
    end

    local lines = {}
    local when = stamp()

    if action.category == M.CATEGORY_MELEE then
        local predicted = M.expectations.swing

        -- landed-swing mean: attempt expectation with the hit-rate
        -- factor removed (melee_swing: expected = base * E[pDIF] * hr)
        local landed_mean = -1

        if predicted and predicted.hit_rate and predicted.hit_rate > 0 then
            landed_mean = predicted.expected / predicted.hit_rate
        end

        for _, target in ipairs(action.targets) do
            for _, result in ipairs(target.results) do
                local outcome = 'hit'

                if result.message == M.MSG_CRIT then
                    outcome = 'crit'
                elseif result.message == M.MSG_MISS then
                    outcome = 'miss'
                elseif result.message ~= M.MSG_HIT then
                    outcome = 'other:' .. result.message
                end

                -- base and spike feed tools/analyze_swings.py:
                -- observed/base reconstructs pDIF per swing, and the
                -- spike outcome lands at exactly 1.0 x base.
                lines[#lines + 1] = string.format(
                    '%s melee %s observed=%d predicted_mean=%.1f '
                    .. 'predicted_landed=%.1f base=%d spike=%.3f '
                    .. 'pdif_range=%.3f-%.3f hit_rate=%.2f '
                    .. 'crit_rate=%.3f target=%s',
                    when, outcome, result.damage,
                    predicted and predicted.expected or -1,
                    landed_mean,
                    predicted and predicted.base or -1,
                    predicted and predicted.pdif.spike_chance or -1,
                    predicted and predicted.pdif.lower or -1,
                    predicted and predicted.pdif.upper or -1,
                    predicted and predicted.hit_rate or -1,
                    predicted and predicted.crit_rate or -1,
                    M.expectations.target_name or '?')
            end
        end
    elseif action.category == M.CATEGORY_WS then
        local ws_table = M.expectations.ws or {}
        local predicted = ws_table[action.action_id]

        for _, target in ipairs(action.targets) do
            local total = 0
            local rolled = 0
            local landed = 0

            for _, result in ipairs(target.results) do
                total = total + (result.damage or 0)
                rolled = rolled + 1

                if result.message ~= M.MSG_MISS then
                    landed = landed + 1
                end
            end

            lines[#lines + 1] = string.format(
                '%s ws id=%d name=%s observed=%d predicted_mean=%s '
                .. 'hits=%d/%d target=%s',
                when, action.action_id,
                predicted and predicted.name or '?', total,
                predicted and string.format('%.1f', predicted.expected)
                    or 'n/a',
                landed, rolled,
                M.expectations.target_name or '?')
        end
    end

    return lines
end

-- =====================================================================
-- Session header (full assumed state, written when /whet debug starts)
-- =====================================================================

-- Effects that are KNOWN to matter but are not in the haste model;
-- their presence gets an explicit warning instead of silence.
M.WARN_EFFECTS =
{
    [251] = 'Food: server-side att/def are included in 0x061, but the '
        .. 'ACCURACY model uses gear acc only - food acc is NOT counted',
    -- scripts/enum/effect.lua: MADRIGAL = 199, HUNTERS_ROLL = 320.
    -- Both add accuracy the 0x061 packet does NOT carry and the gear-
    -- only acc model cannot see: hit-rate verdicts (HIT_CEILING) from
    -- a session with either active are tainted.
    [199] = 'Madrigal: song accuracy is invisible to the acc model - '
        .. 'hit-rate verdicts from this session are tainted',
    [320] = "Hunter's Roll: roll accuracy is invisible to the acc "
        .. 'model - hit-rate verdicts from this session are tainted',
}

-- p:
--   version, profile        addon version string, profile name
--   stats                   parsed 0x061 (jobs, stats, attack, defense)
--   skills                  parsed 0x062 (by_name)
--   weapon_skill            mainhand skill name ('great_axe')
--   accuracy                derived accuracy in use
--   haste                   player.haste_report() output
--   gear_pieces             player.gear_stats().pieces
--   buffs                   raw active effect id array
--   known_buffs             player.BUFFS table (for classification)
--   target_name, pinned_level, level_range {lo, hi}
-- Returns an array of header lines.
function M.session_header(p)
    local lines = {}

    local function add(format, ...)
        lines[#lines + 1] = string.format(format, ...)
    end

    add('=== whetstone session %s ===', os.date('%Y-%m-%d %H:%M:%S'))
    add('version=%s profile=%s', p.version or '?', p.profile or 'phoenix')

    -- Data vintage: which server commit the loaded tables came from,
    -- so a log is interpretable after the tables move.
    if p.vintage then
        add('data_vintage items=%s ws=%s mobs=%s',
            tostring(p.vintage.items or '?'),
            tostring(p.vintage.ws or '?'),
            tostring(p.vintage.mobs or '?'))
    end

    local stats = p.stats or {}
    local s = stats.stats or {}

    add('player job=%s/%s lv=%d attack=%d defense=%d',
        tostring(stats.main_job), tostring(stats.sub_job),
        stats.main_level or 0, stats.attack or 0, stats.defense or 0)
    add('stats str=%d dex=%d vit=%d agi=%d int=%d mnd=%d chr=%d',
        s.str or 0, s.dex or 0, s.vit or 0, s.agi or 0,
        s['int'] or 0, s.mnd or 0, s.chr or 0)

    local skill = p.skills and p.skills.by_name
        and p.skills.by_name[p.weapon_skill or '']

    add('weapon=%s skill=%d%s derived_accuracy=%d',
        tostring(p.weapon_skill), skill and skill.value or -1,
        skill and (skill.capped and ' (capped)' or ' (UNCAPPED)') or '',
        p.accuracy or -1)

    if p.haste then
        add('haste magic=%.4f%s ability=%.4f gear=%.4f (exact) '
            .. 'multiplier=%.4f overcap=%.4f',
            p.haste.magic or 0,
            p.haste.magic_estimated and '~' or '',
            p.haste.ability or 0, p.haste.gear or 0,
            p.haste.multiplier or 1, p.haste.gear_overcap or 0)
    end

    for _, piece in ipairs(p.gear_pieces or {}) do
        if piece.haste and piece.haste > 0 then
            add('gear_haste %s=%s %.2f%%', piece.slot, piece.name,
                piece.haste * 100)
        end
    end

    -- Conditional (latent) mods are OUT OF MODEL: the item DB flags
    -- pieces whose item_latents rows touch a model-relevant mod, and
    -- their presence taints predictions whenever the (unreadable)
    -- condition holds.
    for _, piece in ipairs(p.gear_pieces or {}) do
        if piece.latent_mods and #piece.latent_mods > 0 then
            add('WARNING latent gear %s=%s conditional mods (%s) are '
                .. 'NOT in the model - predictions may be off while '
                .. 'the latent condition holds', piece.slot, piece.name,
                table.concat(piece.latent_mods, ','))
        end
    end

    local known = p.known_buffs or {}
    local unaccounted = {}

    for _, id in ipairs(p.buffs or {}) do
        if known[id] then
            local buff = known[id]
            add('buff %d=%s %s%.4f%s', id, buff.name, buff.category
                and (buff.category .. ' ') or '', buff.amount or 0,
                buff.estimated and ' ~est' or '')
        elseif M.WARN_EFFECTS[id] then
            add('WARNING effect %d active: %s', id, M.WARN_EFFECTS[id])
        else
            unaccounted[#unaccounted + 1] = id
        end
    end

    if #unaccounted > 0 then
        add('WARNING unaccounted effect ids (not in haste/damage '
            .. 'model): %s', table.concat(unaccounted, ','))
    end

    if p.target_name then
        if p.pinned_level then
            add('target=%s pinned_level=%d', p.target_name,
                p.pinned_level)
        elseif p.checked_level then
            add('target=%s checked_level=%d (0x029 con result)',
                p.target_name, p.checked_level)
        elseif p.level_range then
            add('target=%s level_range=%d-%d UNPINNED '
                .. '(predictions use worst case)', p.target_name,
                p.level_range[1], p.level_range[2])
        else
            add('target=%s', p.target_name)
        end
    end

    add('=== end header ===')

    return lines
end

return M
