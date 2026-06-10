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
function M.observe(action, player_id)
    if not action or action.actor ~= player_id or not M.expectations then
        return {}
    end

    local lines = {}
    local stamp = os.date('%H:%M:%S')

    if action.category == M.CATEGORY_MELEE then
        local predicted = M.expectations.swing

        for _, target in ipairs(action.targets) do
            for _, result in ipairs(target.results) do
                local outcome = 'hit'

                if result.message == M.MSG_CRIT then
                    outcome = 'crit'
                elseif result.message ~= M.MSG_HIT then
                    outcome = 'other:' .. result.message
                end

                lines[#lines + 1] = string.format(
                    '%s melee %s observed=%d predicted_mean=%.1f '
                    .. 'pdif_range=%.3f-%.3f hit_rate=%.2f target=%s',
                    stamp, outcome, result.damage,
                    predicted and predicted.expected or -1,
                    predicted and predicted.pdif.lower or -1,
                    predicted and predicted.pdif.upper or -1,
                    predicted and predicted.hit_rate or -1,
                    M.expectations.target_name or '?')
            end
        end
    elseif action.category == M.CATEGORY_WS then
        local ws_table = M.expectations.ws or {}
        local predicted = ws_table[action.action_id]

        for _, target in ipairs(action.targets) do
            local total = 0

            for _, result in ipairs(target.results) do
                total = total + (result.damage or 0)
            end

            lines[#lines + 1] = string.format(
                '%s ws id=%d name=%s observed=%d predicted_mean=%s '
                .. 'target=%s',
                stamp, action.action_id,
                predicted and predicted.name or '?', total,
                predicted and string.format('%.1f', predicted.expected)
                    or 'n/a',
                M.expectations.target_name or '?')
        end
    end

    return lines
end

return M
