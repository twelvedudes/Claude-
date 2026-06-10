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
                         <addon>/whetstone_swings.log

    This file is Ashita glue and needs an in-game shakedown; everything
    it calls is unit-tested pure Lua.
]]

addon.name    = 'whetstone'
addon.author  = 'Whetstone'
addon.version = '0.5.0'
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

local JOB_NAMES = { 'WAR', 'MNK', 'WHM', 'BLM', 'RDM', 'THF', 'PLD',
                    'DRK', 'BST', 'BRD', 'RNG', 'SAM', 'NIN', 'DRG',
                    'SMN', 'BLU', 'COR', 'PUP', 'DNC', 'SCH', 'GEO',
                    'RUN' }

local TWO_HANDED =
{
    great_sword = true, great_axe = true, scythe = true,
    polearm = true, great_katana = true, staff = true,
}

local state =
{
    pinned_level    = nil,
    march_override  = nil,
    assume_quest_ws = false,
    debug_log       = false,
    last_report     = nil,
    last_haste      = nil,
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
    elseif args[2] == 'quest' then
        state.assume_quest_ws = not state.assume_quest_ws
        print('[whetstone] quest WS ranking: '
            .. (state.assume_quest_ws and 'ON' or 'OFF'))
    elseif args[2] == 'debug' then
        state.debug_log = not state.debug_log
        print('[whetstone] swing logging: '
            .. (state.debug_log and 'ON -> whetstone_swings.log' or 'OFF'))
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

    if not stats or not skills or not data.mobs then
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
        data            = data,
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

    swinglog.set_expectations(
    {
        target_name = report.target.name,
        swing = formulas.melee_swing(
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
            two_handed       = TWO_HANDED[weapon.skill] or false,
            h2h              = weapon.skill == 'hand_to_hand',
        }),
        ws = ws_by_id,
    })
end

local function append_log(lines)
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
