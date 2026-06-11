--[[
    Whetstone - narrow.lua

    Pure level-narrowing state: session pins + the con-check cache.
    Extracted from whetstone.lua glue after the v0.1.9 field bug
    ("every Wild Rabbit shows Lv.4 checked") so the keying rules are
    falsifiable offline (tests/test_narrow.lua).

    INVARIANTS (the spec this module exists to enforce):
      - The checked cache is keyed by entity SERVER ID and nothing
        else. There is no name-keyed level lookup in the check path:
        same-name mobs are DIFFERENT levels by design (spawn bands).
        Names are stored on entries only to INVALIDATE a recycled id
        (an id reused by a different species), never to find a level.
      - Latest check wins: a new con result for an id ALWAYS
        overwrites that id's entry, never blocked by an existing one.
      - Server id 0 / non-numeric ids are REFUSED on both write and
        read: a degenerate id source (entity lookup failing on some
        servers) must not collapse every mob onto one cache key.
      - Zone change wipes the cache (ids recycle across zones); a
        death message drops the single id (ids recycle onto respawns).

    Pins are user intent, keyed per mob NAME by design, session-only.
    They live here so resolve() owns the full precedence:
        pin > checked > nil (unconfirmed)

    Zero Ashita dependencies; fully unit-tested.
]]

local M = {}

function M.new()
    return
    {
        zone  = nil,
        by_id = {}, -- [server_id] = { level, difficulty, name, at }
        pins  = {}, -- [mob_name] = level (session only)
    }
end

local function valid_id(server_id)
    return type(server_id) == 'number' and server_id > 0
end

-- =====================================================================
-- Pins (session-only user intent, per mob name)
-- =====================================================================

function M.pin(s, name, level)
    s.pins[name] = level
end

function M.unpin(s, name)
    s.pins[name] = nil
end

function M.pin_for(s, name)
    return name ~= nil and s.pins[name] or nil
end

-- =====================================================================
-- Checked cache (per entity server id ONLY)
-- =====================================================================

-- Returns true when stored, false + reason when refused. now is an
-- optional clock value recorded on the entry.
function M.remember_check(s, zone, server_id, level, difficulty, name, now)
    if not valid_id(server_id) then
        return false, 'invalid server id ' .. tostring(server_id)
            .. ' (entity id source degenerate - not caching)'
    end

    if s.zone ~= zone then
        s.zone = zone
        s.by_id = {}
    end

    -- LATEST CHECK WINS - unconditional overwrite, by construction.
    s.by_id[server_id] =
    {
        level      = level,
        difficulty = difficulty,
        name       = name,
        at         = now,
    }

    return true
end

-- Entity-id recycling (death/despawn): drop the single id.
function M.forget(s, server_id)
    if server_id ~= nil then
        s.by_id[server_id] = nil
    end
end

-- The id-keyed read. `name` is OPTIONAL and used only as a recycling
-- tripwire: an entry recorded under a different mob name means the
-- id was reused by another species - drop it, never trust it.
function M.checked_for(s, zone, server_id, name)
    if s.zone ~= zone or not valid_id(server_id) then
        return nil
    end

    local entry = s.by_id[server_id]

    if not entry then
        return nil
    end

    if entry.name and name and entry.name ~= name then
        s.by_id[server_id] = nil -- recycled onto a different species
        return nil
    end

    return entry.level, entry
end

-- =====================================================================
-- Resolution (the ONE precedence implementation)
-- =====================================================================

-- pin > checked > nil. Returns:
--   level        narrowed level or nil
--   source       'pinned' | 'checked' | nil
--   check_level  the checked level regardless of who won (conflict
--                surfacing needs it even when a pin outranks it)
function M.resolve(s, zone, name, server_id)
    local pin = M.pin_for(s, name)
    local check = M.checked_for(s, zone, server_id, name)

    if pin then
        return pin, 'pinned', check
    end

    if check then
        return check, 'checked', check
    end

    return nil, nil, nil
end

-- =====================================================================
-- Structural assertions (regression test d)
-- =====================================================================

-- Errors if the checked cache holds any non-numeric key or the state
-- grew a name-keyed level index. Tests call this after every
-- scenario; glue may call it in a selftest.
function M.assert_id_keyed(s)
    for key in pairs(s.by_id) do
        if type(key) ~= 'number' then
            error('checked cache key is not a server id: '
                .. tostring(key))
        end
    end

    for field in pairs(s) do
        if field ~= 'zone' and field ~= 'by_id' and field ~= 'pins' then
            error('unexpected narrowing state field: ' .. tostring(field))
        end
    end

    return true
end

return M
