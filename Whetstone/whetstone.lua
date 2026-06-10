--[[
    Whetstone - Ashita v4 addon bootstrap.

    Wires together:
      formulas.lua  pure combat math (server profiles)
      player.lua    0x061 stats, 0x062 skills, equipment, buffs
      advisor.lua   ranked actionable deltas
      ui.lua        one-glance ImGui panel
      swinglog.lua  /whet debug predicted-vs-observed logging
      data/*.lua    GENERATED tables (mobs, weaponskills, items) -
                    required at runtime, see README "Release packaging"

    Commands:
      /whet              toggle the panel
      /whet level <n>    pin the current target's level (checker info)
      /whet level        clear the pin
      /whet march <pct>  set March potency override (e.g. 14.06)
      /whet quest        toggle ranking of quest-locked WS (default off)
      /whet debug        toggle predicted-vs-observed swing logging to
                         <addon>/whetstone_swings.log (writes a full
                         session-state header on enable)
      /whet selftest     exercise every Ashita glue call and write
                         <addon>/whetstone_selftest.log

    This file is Ashita glue and needs an in-game shakedown; everything
    it calls is unit-tested pure Lua.
]]

addon.name    = 'whetstone'
addon.author  = 'Whetstone'
addon.version = '0.1.0-beta'
addon.desc    = 'Live melee damage advisor (75-cap era, Phoenix)'

require('common')

local addon_path = addon.path:gsub('\\', '/')
package.path = string.format('%s?.lua;%sdata/?.lua;%s',
    addon_path, addon_path, package.path)

local formulas = require('formulas')
local player   = require('player')
local advisor  = require('advisor')
local ui       = require('ui')
local swinglog = require('swinglog')
local selftest = require('selftest')

local state =
{
    pinned_level    = nil,
    march_override  = nil,
    assume_quest_ws = false,
    debug_log       = false,
    last_report     = nil,
    last_haste      = nil,
}

local data = { mobs = nil, ws = nil, items = nil }
local mob_index = nil -- split layout: data/mobs/index.lua
local mob_cache = {}  -- one zone resident at a time (32-bit process)

local function load_data(name)
    local ok, result = pcall(require, name)

    if not ok then
        print(('[whetstone] missing data/%s.lua - run the extractors '
            .. '(see README)'):format(name))
        return nil
    end

    return result
end

-- forward declarations (defined after snapshot, used by the command
-- handler closures)
local append_log
local write_session_header
local run_selftest

-- One zone's mob table at a time: the full world is ~4 MB of source
-- that parses into far more than that as Lua structures inside FFXI's
-- 32-bit address space. Loads on demand, unloads the previous zone,
-- and logs the Lua heap before/after in debug mode.
local function mobs_for_zone(zone)
    if data.mobs then -- monolithic data/mobs.lua fallback
        return data.mobs
    end

    if not mob_index then
        return nil
    end

    if mob_cache.zone == zone then
        return mob_cache.wrapped
    end

    local before_kb = collectgarbage('count')

    if mob_cache.module then
        package.loaded[mob_cache.module] = nil
    end

    mob_cache = {}
    collectgarbage('collect')

    local info = mob_index.zones and mob_index.zones[zone]

    if not info then
        return nil
    end

    local module_name = 'mobs.' .. info.file
    local ok, zone_table = pcall(require, module_name)

    if not ok then
        return nil
    end

    collectgarbage('collect')
    local after_kb = collectgarbage('count')

    mob_cache =
    {
        zone    = zone,
        module  = module_name,
        wrapped = { [zone] = zone_table },
    }

    if state.debug_log and append_log then
        append_log({ string.format(
            '%s zoneload zone=%d entries=%d lua_heap_kb %.0f -> %.0f',
            os.date('%H:%M:%S'), zone, info.entries or -1,
            before_kb, after_kb) })
    end

    return mob_cache.wrapped
end

local JOB_NAMES = { 'WAR', 'MNK', 'WHM', 'BLM', 'RDM', 'THF', 'PLD',
                    'DRK', 'BST', 'BRD', 'RNG', 'SAM', 'NIN', 'DRG',
                    'SMN', 'BLU', 'COR', 'PUP', 'DNC', 'SCH', 'GEO',
                    'RUN' }

local TWO_HANDED =
{
    great_sword = true, great_axe = true, scythe = true,
    polearm = true, great_katana = true, staff = true,
}

ashita.events.register('load', 'whetstone_load', function()
    -- Prefer the split per-zone layout; fall back to monolithic.
    local ok, index = pcall(require, 'mobs.index')

    if ok and type(index) == 'table' and index.zones then
        mob_index = index
        print(('[whetstone] split mob data: %d entries indexed')
            :format(index.total_entries or -1))
    else
        data.mobs = load_data('mobs')
    end

    data.ws    = load_data('weaponskills')
    data.items = load_data('items')

    player.attach('whetstone')
end)

ashita.events.register('command', 'whetstone_command', function(e)
    local args = e.command:args()

    if #args == 0 or args[1] ~= '/whet' then
        return
    end

    e.blocked = true

    if args[2] == 'level' then
        state.pinned_level = tonumber(args[3]) -- nil clears
    elseif args[2] == 'march' and tonumber(args[3]) then
        state.march_override = tonumber(args[3]) / 100
    elseif args[2] == 'quest' then
        state.assume_quest_ws = not state.assume_quest_ws
        print('[whetstone] quest WS ranking: '
            .. (state.assume_quest_ws and 'ON' or 'OFF'))
    elseif args[2] == 'debug' then
        state.debug_log = not state.debug_log
        print('[whetstone] swing logging: '
            .. (state.debug_log and 'ON -> whetstone_swings.log' or 'OFF'))

        if state.debug_log then
            write_session_header()
        end
    elseif args[2] == 'selftest' then
        run_selftest()
    else
        ui.visible[1] = not ui.visible[1]
    end
end)

-- Build the advisor input from live state. Returns nil without a
-- valid melee target / parsed char packets (0x061 AND 0x062 both
-- arrive at zone-in; no accuracy guessing - if skills are not parsed
-- yet, we wait rather than mislead).
local function snapshot()
    local stats = player.state.char_stats
    local skills = player.state.skills

    if not stats or not skills then
        return nil
    end

    player.refresh()

    local target_manager = AshitaCore:GetMemoryManager():GetTarget()
    local target_index = target_manager:GetTargetIndex(0)

    if target_index == 0 then
        return nil
    end

    local entity = AshitaCore:GetMemoryManager():GetEntity()
    local name = entity:GetName(target_index)
    local zone = AshitaCore:GetMemoryManager():GetParty()
        :GetMemberZone(0)

    if not name or name == '' then
        return nil
    end

    -- Per-zone mob table (split layout) or the monolithic fallback;
    -- loading swaps the previous zone out of the 32-bit heap.
    local mobs = mobs_for_zone(zone)

    if not mobs then
        return nil
    end

    local gear = player.gear_stats(player.state.equipment,
                                   data.items or {})
    local main = gear.main and gear.main.weapon

    if not main then
        return nil
    end

    local two_handed = TWO_HANDED[main.skill] or false

    local overrides = nil
    if state.march_override then
        overrides = { [214] = state.march_override }
    end

    local haste = player.haste_report(
    {
        buffs      = player.state.buffs,
        equipment  = player.state.equipment,
        item_db    = data.items or {},
        two_handed = two_handed,
        overrides  = overrides,
    }, formulas)

    -- REAL accuracy from the 0x062 skill packet: launch players level
    -- with lagging skill, and assuming a capped skill would make the
    -- flagship "acc to cap" number confidently wrong for exactly them.
    local skill_entry = skills.by_name[main.skill]
    local skill_value = skill_entry and skill_entry.value or 0

    local accuracy = formulas.player_accuracy(
    {
        skill       = skill_value,
        dex         = stats.stats.dex,
        acc_mod     = gear.acc or 0,
        two_handed  = two_handed,
        twohand_acc = 0,
    })

    return
    {
        player =
        {
            level     = stats.main_level,
            main_job  = JOB_NAMES[stats.main_job],
            stats     = stats.stats,
            attack    = stats.attack,
            accuracy  = accuracy,
            ws_skill  = skill_value,
            -- gear crit mods are EXACT via the item DB (whitelisted
            -- Mod 165 / Mod 421), same precision class as gear haste
            crit_rate_bonus = (gear.crit_rate or 0) / 100,
            crit_dmg_bonus  = (gear.crit_dmg or 0) / 100,
            weapon    =
            {
                dmg   = main.dmg,
                delay = main.delay,
                skill = main.skill,
            },
            offhand_dmg = gear.sub and gear.sub.weapon
                and gear.sub.weapon.dmg or nil,
        },
        haste           = haste,
        target          = { zone = zone, name = name,
                            level = state.pinned_level },
        data            = { mobs = mobs, ws = data.ws,
                            items = data.items },
        tp              = AshitaCore:GetMemoryManager():GetParty()
            :GetMemberTP(0),
        assume_quest_ws = state.assume_quest_ws,
        -- 75-era original zones are level-corrected; post-ToAU zones
        -- mostly not. TODO: zone table; default on for now.
        level_correction = true,
    }, haste
end

-- Refresh swinglog expectations from the latest advisor pass.
local function update_expectations(snap, report)
    if not state.debug_log or not snap or not report then
        return
    end

    -- Worst-case candidate point, mirroring the advisor's math.
    local worst

    for _, point in ipairs(report.target.points or {}) do
        if not worst or point.stats.eva > worst.stats.eva then
            worst = point
        end
    end

    if not worst then
        return
    end

    local weapon = snap.player.weapon
    local rank = formulas.weapon_rank(weapon.dmg,
                                      weapon.skill == 'hand_to_hand')

    local ws_by_id = {}
    for _, ranked in ipairs(report.ws or {}) do
        ws_by_id[ranked.entry.id] =
            { name = ranked.name, expected = ranked.expected }
    end

    -- The logged prediction must include crits: observations do.
    local crit_rate = formulas.crit_rate(
    {
        dex        = snap.player.stats.dex,
        target_agi = worst.stats.agi,
        bonus      = snap.player.crit_rate_bonus,
        kind       = 'melee',
    })

    local swing = formulas.melee_swing(
    {
        weapon_dmg       = weapon.dmg,
        fstr             = formulas.fstr(snap.player.stats.str,
                                         worst.stats.vit, rank),
        attack           = snap.player.attack,
        defense          = worst.stats.def,
        weapon           = weapon.skill,
        acc              = snap.player.accuracy,
        eva              = worst.stats.eva,
        attacker_level   = snap.player.level,
        target_level     = worst.level,
        level_correction = snap.level_correction,
        crit_rate        = crit_rate,
        crit_dmg_bonus   = snap.player.crit_dmg_bonus,
        two_handed       = TWO_HANDED[weapon.skill] or false,
        h2h              = weapon.skill == 'hand_to_hand',
    })
    swing.crit_rate = crit_rate

    swinglog.set_expectations(
    {
        target_name = report.target.name,
        swing       = swing,
        ws          = ws_by_id,
    })
end

append_log = function(lines)
    if #lines == 0 then
        return
    end

    local file = io.open(addon_path .. 'whetstone_swings.log', 'a')

    if file then
        for _, line in ipairs(lines) do
            file:write(line, '\n')
        end

        file:close()
    end
end

-- Dump the full assumed state at the top of a debug session so every
-- swing line in the log can be interpreted offline.
write_session_header = function()
    local ok, snap = pcall(snapshot)
    local gear = player.gear_stats(player.state.equipment,
                                   data.items or {})

    local level_range = nil
    if state.last_report and state.last_report.target
        and state.last_report.target.level_min then
        level_range = { state.last_report.target.level_min,
                        state.last_report.target.level_max }
    end

    append_log(swinglog.session_header(
    {
        version      = addon.version,
        profile      = 'phoenix',
        stats        = player.state.char_stats or {},
        skills       = player.state.skills,
        weapon_skill = ok and snap and snap.player.weapon.skill or nil,
        accuracy     = ok and snap and snap.player.accuracy or nil,
        haste        = ok and snap and snap.haste or nil,
        gear_pieces  = gear.pieces,
        buffs        = player.state.buffs,
        known_buffs  = player.BUFFS,
        target_name  = ok and snap and snap.target.name or nil,
        pinned_level = state.pinned_level,
        level_range  = level_range,
    }))
end

-- /whet selftest: exercise every Ashita glue call and write a readable
-- diagnostic report, so shakedown failures name the exact call that
-- misbehaved instead of failing silently.
run_selftest = function()
    local expect = selftest.expect

    local checks =
    {
        { name = 'memory_manager', fn = function()
            expect(AshitaCore ~= nil, 'AshitaCore missing')
            expect(AshitaCore:GetMemoryManager() ~= nil,
                'GetMemoryManager returned nil')
            return 'present'
        end },

        { name = 'inventory_equipped_slots', fn = function()
            local inventory = AshitaCore:GetMemoryManager():GetInventory()
            expect(inventory ~= nil, 'GetInventory returned nil')

            local populated = 0
            for slot = 0, 15 do
                local entry = inventory:GetEquippedItem(slot)
                expect(entry ~= nil,
                    'GetEquippedItem(' .. slot .. ') returned nil')
                if entry.Index ~= 0 then
                    populated = populated + 1
                end
            end
            return populated .. '/16 slots populated'
        end },

        { name = 'equipment_item_ids', fn = function()
            local equipment = {}
            local inventory = AshitaCore:GetMemoryManager():GetInventory()
            local resolved = 0
            for slot = 0, 15 do
                local entry = inventory:GetEquippedItem(slot)
                if entry and entry.Index ~= 0 then
                    local container = math.floor(entry.Index / 256)
                    local index = entry.Index % 256
                    local item = inventory:GetContainerItem(container, index)
                    expect(item ~= nil, ('GetContainerItem(%d, %d) nil')
                        :format(container, index))
                    if item.Id and item.Id > 0 then
                        resolved = resolved + 1
                    end
                end
            end
            return resolved .. ' item ids resolved'
        end },

        { name = 'target_manager', fn = function()
            local target = AshitaCore:GetMemoryManager():GetTarget()
            expect(target ~= nil, 'GetTarget returned nil')
            return 'target_index=' .. tostring(target:GetTargetIndex(0))
        end },

        { name = 'party_info', fn = function()
            local party = AshitaCore:GetMemoryManager():GetParty()
            expect(party ~= nil, 'GetParty returned nil')
            return ('zone=%s tp=%s server_id=%s'):format(
                tostring(party:GetMemberZone(0)),
                tostring(party:GetMemberTP(0)),
                tostring(party:GetMemberServerId(0)))
        end },

        { name = 'player_buffs', fn = function()
            local buffs = AshitaCore:GetMemoryManager():GetPlayer()
                :GetBuffs()
            expect(buffs ~= nil, 'GetBuffs returned nil')
            return 'readable'
        end },

        { name = 'packet_0x061_received', fn = function()
            expect(player.state.char_stats ~= nil,
                'no 0x061 parsed yet - change jobs or zone to trigger')
            return 'lv' .. player.state.char_stats.main_level
        end },

        { name = 'packet_0x062_received', fn = function()
            expect(player.state.skills ~= nil,
                'no 0x062 parsed yet - change jobs or zone to trigger')
            return 'skills parsed'
        end },

        { name = 'data_weaponskills', fn = function()
            expect(data.ws ~= nil, 'data/weaponskills.lua not loaded')
            local count = 0
            for _ in pairs(data.ws) do count = count + 1 end
            return count .. ' weapon skills'
        end },

        { name = 'data_items', fn = function()
            expect(data.items ~= nil, 'data/items.lua not loaded')
            return 'loaded'
        end },

        { name = 'data_mobs', fn = function()
            expect(mob_index ~= nil or data.mobs ~= nil,
                'neither split index nor monolithic mobs loaded')
            if mob_index then
                return ('split: %d entries indexed'):format(
                    mob_index.total_entries or -1)
            end
            return 'monolithic'
        end },

        { name = 'zone_mob_load', fn = function()
            local zone = AshitaCore:GetMemoryManager():GetParty()
                :GetMemberZone(0)
            local mobs = mobs_for_zone(zone)
            expect(mobs ~= nil,
                'no mob table for current zone ' .. tostring(zone))
            local count = 0
            for _ in pairs(mobs[zone] or {}) do count = count + 1 end
            return ('zone %d: %d mob names'):format(zone, count)
        end },
    }

    local report = selftest.run(checks)

    local file = io.open(addon_path .. 'whetstone_selftest.log', 'w')
    if file then
        file:write(table.concat(report.lines, '\n'), '\n')
        file:close()
    end

    print(('[whetstone] selftest: %d ok, %d failed -> '
        .. 'whetstone_selftest.log'):format(report.ok, report.failed))
end

ashita.events.register('packet_in', 'whetstone_swing_packet',
    function(event)
        if not state.debug_log or event.id ~= 0x028 then
            return
        end

        local ok, action = pcall(swinglog.parse_action, event.data)

        if not ok or not action then
            return
        end

        local player_id = AshitaCore:GetMemoryManager():GetParty()
            :GetMemberServerId(0)

        local ok_obs, lines = pcall(swinglog.observe, action, player_id)

        if ok_obs then
            append_log(lines)
        end
    end)

ashita.events.register('d3d_present', 'whetstone_present', function()
    if not ui.visible[1] and not state.debug_log then
        return
    end

    local ok, snap, haste = pcall(snapshot)

    if ok and snap then
        local ok_eval, report = pcall(advisor.evaluate, snap)

        if ok_eval then
            state.last_report = report
            state.last_haste = haste
            update_expectations(snap, report)
        end
    end

    ui.draw(state.last_report, state.last_haste)
end)
