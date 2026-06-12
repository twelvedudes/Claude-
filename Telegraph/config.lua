--[[
    Telegraph - config.lua

    Pure persistence core: defaults, sanitize (type-checked deep
    merge), and a Lua-literal serializer for the file fallback - the
    same fixed pattern as Whetstone's config.lua (the v0.1.6/v0.1.7
    field lessons: T{} defaults for the Ashita settings lib, pcall'd
    init, sandboxed deserialization). telegraph.lua wires the backend.

    Persisted state:
      visible      panel visibility
      window_pos   { x, y } panel position (-1 = let ImGui place it)
      profile      tpledger profile name ('phoenix' | 'lsb')
      show_tp      render the TP estimate section
      show_bars    render the cast/ready bar section

    Debug logging is deliberately session-only (a forgotten debug flag
    must not silently grow log files across reloads).
]]

local M = {}

M.DEFAULTS =
{
    visible    = true,
    window_pos = { x = -1, y = -1 },
    profile    = 'phoenix',
    show_tp    = true,
    show_bars  = true,
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
-- are dropped, type mismatches fall back to the default. A corrupt or
-- stale settings file can never poison runtime state.
function M.sanitize(loaded)
    local result = deep_copy(M.DEFAULTS)

    if type(loaded) ~= 'table' then
        return result
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

    if type(loaded.profile) == 'string' then
        result.profile = loaded.profile
    end

    if type(loaded.show_tp) == 'boolean' then
        result.show_tp = loaded.show_tp
    end

    if type(loaded.show_bars) == 'boolean' then
        result.show_bars = loaded.show_bars
    end

    return result
end

-- Lua-literal serializer for the file-fallback backend (deterministic
-- key order so files diff cleanly).
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
