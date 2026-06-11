--[[
    Whetstone - config.lua

    Pure persistence core: defaults, sanitize (type-checked deep
    merge), and a Lua-literal serializer for the file fallback. The
    Ashita settings library (per-character, reload-surviving) is the
    preferred backend - whetstone.lua wires it when available - but
    every transformation here is backend-agnostic and round-trip
    tested offline.

    Persisted state:
      assume_quest_ws  /whet quest toggle
      march_override   March potency override (fraction; 0 = unset)
      buff_overrides   { [effect_id] = fraction } user-pinned magnitudes
      profile          formulas profile name
      visible          panel visibility
      window_pos       { x, y } panel position

    DELIBERATELY NOT PERSISTED: per-mob LEVEL pins. Trash spawns vary
    (a Lv.1-6 worm respawns anywhere in the band) and an immortal
    name-pin silently overrides fresh con checks forever - the v0.1.8
    field bug. Level pins are session state in whetstone.lua;
    sanitize() drops unknown keys, so the legacy pinned_levels key in
    pre-v0.1.9 settings files is dropped on load (migration).
]]

local M = {}

M.DEFAULTS =
{
    assume_quest_ws = false,
    march_override  = 0,
    buff_overrides  = {},
    profile         = 'phoenix',
    visible         = true,
    window_pos      = { x = -1, y = -1 }, -- -1 = let ImGui place it
}

local function deep_copy(value)
    if type(value) ~= 'table' then
        return value
    end

    local copy = {}

    for key, entry in pairs(value) do
        copy[key] = deep_copy(entry)
    end

    return copy
end

-- Type-checked merge of loaded state over the defaults: unknown keys
-- are dropped, type mismatches fall back to the default, map-style
-- tables (buff_overrides) accept only sane entries. A corrupt or
-- stale settings file can never poison runtime state.
function M.sanitize(loaded)
    local result = deep_copy(M.DEFAULTS)

    if type(loaded) ~= 'table' then
        return result
    end

    if type(loaded.assume_quest_ws) == 'boolean' then
        result.assume_quest_ws = loaded.assume_quest_ws
    end

    if type(loaded.march_override) == 'number'
        and loaded.march_override >= 0 and loaded.march_override <= 1 then
        result.march_override = loaded.march_override
    end

    if type(loaded.buff_overrides) == 'table' then
        for id, amount in pairs(loaded.buff_overrides) do
            if type(id) == 'number' and type(amount) == 'number'
                and amount >= -1 and amount <= 1 then
                result.buff_overrides[id] = amount
            end
        end
    end

    -- NOTE: loaded.pinned_levels (pre-v0.1.9) is deliberately ignored
    -- here - level pins are session state now (see header).

    if type(loaded.profile) == 'string' then
        result.profile = loaded.profile
    end

    if type(loaded.visible) == 'boolean' then
        result.visible = loaded.visible
    end

    if type(loaded.window_pos) == 'table'
        and type(loaded.window_pos.x) == 'number'
        and type(loaded.window_pos.y) == 'number' then
        result.window_pos =
        {
            x = loaded.window_pos.x,
            y = loaded.window_pos.y,
        }
    end

    return result
end

-- Lua-literal serializer for the file-fallback backend. Handles the
-- shapes the config actually uses: string/number/boolean scalars,
-- string and numeric keys. Deterministic key order so files diff
-- cleanly.
local function serialize_value(value, indent)
    local kind = type(value)

    if kind == 'number' or kind == 'boolean' then
        return tostring(value)
    end

    if kind == 'string' then
        return string.format('%q', value)
    end

    if kind == 'table' then
        local keys = {}

        for key in pairs(value) do
            keys[#keys + 1] = key
        end

        table.sort(keys, function(a, b)
            if type(a) == type(b) then
                return a < b
            end

            return type(a) == 'number' -- numeric keys first
        end)

        local pieces = {}

        for _, key in ipairs(keys) do
            local key_repr

            if type(key) == 'string' and key:match('^[%a_][%w_]*$') then
                key_repr = key
            elseif type(key) == 'string' then
                key_repr = '[' .. string.format('%q', key) .. ']'
            else
                key_repr = '[' .. tostring(key) .. ']'
            end

            pieces[#pieces + 1] = indent .. '    ' .. key_repr .. ' = '
                .. serialize_value(value[key], indent .. '    ')
        end

        if #pieces == 0 then
            return '{}'
        end

        return '{\n' .. table.concat(pieces, ',\n') .. ',\n'
            .. indent .. '}'
    end

    return 'nil' -- functions/userdata never belong in config
end

function M.serialize(config)
    return 'return ' .. serialize_value(config, '') .. '\n'
end

-- Deserialize a config string (sandboxed: no environment access).
-- Returns a table or nil.
function M.deserialize(text)
    if type(text) ~= 'string' then
        return nil
    end

    local chunk = loadstring(text)

    if not chunk then
        return nil
    end

    setfenv(chunk, {})

    local ok, result = pcall(chunk)

    if not ok or type(result) ~= 'table' then
        return nil
    end

    return result
end

return M
