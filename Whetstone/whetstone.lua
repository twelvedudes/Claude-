--[[
    Whetstone - Ashita v4 addon bootstrap.

    Wires together:
      formulas.lua  pure combat math (server profiles)
      player.lua    0x061 stats, equipment, buffs
      advisor.lua   ranked actionable deltas
      ui.lua        one-glance ImGui panel
      data/*.lua    GENERATED tables (mobs, weaponskills, items) -
                    required at runtime, see README "Release packaging"

    Commands:
      /whet              toggle the panel
      /whet level <n>    pin the current target's level (checker info)
      /whet level        clear the pin
      /whet march <pct>  set March potency override (e.g. 14.06)

    This file is Ashita glue and needs an in-game shakedown; everything
    it calls is unit-tested pure Lua.
]]

addon.name    = 'whetstone'
addon.author  = 'Whetstone'
addon.version = '0.4.0'
addon.desc    = 'Live melee damage advisor (75-cap era, Phoenix)'

require('common')

local addon_path = addon.path:gsub('\\', '/')
package.path = string.format('%s?.lua;%sdata/?.lua;%s',
    addon_path, addon_path, package.path)

local formulas = require('formulas')
local player   = require('player')
local advisor  = require('advisor')
local ui       = require('ui')

local data = { mobs = nil, ws = nil, items = nil }

local function load_data(name)
    local ok, result = pcall(require, name)

    if not ok then
        print(('[whetstone] missing data/%s.lua - run the extractors '
            .. '(see README)'):format(name))
        return nil
    end

    return result
end

local state =
{
    pinned_level   = nil,
    march_override = nil,
    last_report    = nil,
    last_haste     = nil,
}

ashita.events.register('load', 'whetstone_load', function()
    data.mobs  = load_data('mobs')
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
    else
        ui.visible[1] = not ui.visible[1]
    end
end)

-- Build the advisor input from live state. Returns nil without a
-- valid melee target / parsed char stats.
local function snapshot()
    local stats = player.state.char_stats

    if not stats or not data.mobs then
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

    local gear = player.gear_stats(player.state.equipment,
                                   data.items or {})
    local main = gear.main and gear.main.weapon

    if not main then
        return nil
    end

    local overrides = nil
    if state.march_override then
        overrides = { [214] = state.march_override }
    end

    local haste = player.haste_report(
    {
        buffs      = player.state.buffs,
        equipment  = player.state.equipment,
        item_db    = data.items or {},
        two_handed = main.skill == 'great_sword'
            or main.skill == 'great_axe' or main.skill == 'scythe'
            or main.skill == 'polearm' or main.skill == 'great_katana'
            or main.skill == 'staff',
        overrides  = overrides,
    }, formulas)

    -- NOTE: 0x061 carries attack/defense but not accuracy; until the
    -- 0x062 skill packet is parsed, accuracy = gear acc + DEX/2 + an
    -- assumed capped combat skill for the player's level. Marked
    -- estimated in a later pass; good enough to rank deltas.
    local assumed_skill = 200 + (stats.main_level - 60) * 5
    local skill_acc = assumed_skill > 200
        and (200 + (assumed_skill - 200) * 0.9) or assumed_skill
    local accuracy = math.floor(
        skill_acc + stats.stats.dex * 0.5 + (gear.acc or 0))

    return
    {
        player =
        {
            level     = stats.main_level,
            main_job  = ({ 'WAR', 'MNK', 'WHM', 'BLM', 'RDM', 'THF',
                           'PLD', 'DRK', 'BST', 'BRD', 'RNG', 'SAM',
                           'NIN', 'DRG', 'SMN', 'BLU', 'COR', 'PUP',
                           'DNC', 'SCH', 'GEO', 'RUN' })[stats.main_job],
            stats     = stats.stats,
            attack    = stats.attack,
            accuracy  = accuracy,
            weapon    =
            {
                dmg   = main.dmg,
                delay = main.delay,
                skill = main.skill,
            },
            offhand_dmg = gear.sub and gear.sub.weapon
                and gear.sub.weapon.dmg or nil,
        },
        haste  = haste,
        target = { zone = zone, name = name,
                   level = state.pinned_level },
        data   = data,
        tp     = AshitaCore:GetMemoryManager():GetParty()
            :GetMemberTP(0),
        -- 75-era original zones are level-corrected; post-ToAU zones
        -- mostly not. TODO: zone table; default on for now.
        level_correction = true,
    }, haste
end

ashita.events.register('d3d_present', 'whetstone_present', function()
    if not ui.visible[1] then
        return
    end

    local ok, snap, haste = pcall(snapshot)

    if ok and snap then
        local ok_eval, report = pcall(advisor.evaluate, snap)

        if ok_eval then
            state.last_report = report
            state.last_haste = haste
        end
    end

    ui.draw(state.last_report, state.last_haste)
end)
