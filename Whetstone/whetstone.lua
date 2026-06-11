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
      /whet level <n>    pin the current target's level (checker info);
                         persisted per mob name
      /whet level        clear the pin (session + persisted)
      /whet march <pct>  set March potency override (e.g. 14.06)
      /whet march        clear the override
      /whet quest        toggle ranking of quest-locked WS (default off)
      /whet profile <p>  switch formulas profile (phoenix | lsb);
                         no argument prints the current one

    All user state (pins, march override, quest toggle, profile, panel
    visibility/position) persists per character via the Ashita
    settings library (config/whetstone/<char>_<server>/settings.lua),
    with a file fallback in the addon folder.
      /whet debug        toggle predicted-vs-observed swing logging to
                         <addon>/whetstone_swings.log (writes a full
                         session-state header on enable)
      /whet selftest     exercise every Ashita glue call (via the
                         SAME production paths the panel uses) and
                         write <addon>/whetstone_selftest.log
      /whet target       print raw target index / server id / name /
                         zone and whether the mob DB lookup hits
      /whet panel        dump the exact state the next frame renders
                         (booleans + table identities + draw version)

    This file is Ashita glue and needs an in-game shakedown; everything
    it calls is unit-tested pure Lua.
]]

addon.name    = 'whetstone'
addon.author  = 'Whetstone'
addon.version = '0.1.6-beta'
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
local config   = require('config')

local state =
{
    pinned_level    = nil,
    march_override  = nil,
    assume_quest_ws = false,
    debug_log       = false,
    last_report     = nil,
    last_haste      = nil,
    last_status     = nil,
    latched_error   = nil,
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

-- =====================================================================
-- Persisted user state (config.lua core, Ashita settings lib backend)
-- =====================================================================

local cfg = config.sanitize(nil) -- active config; defaults until loaded
local settings_lib = nil         -- Ashita settings library when present
local fallback_loaded = false    -- file backend loaded (lib absent)

-- The settings library keeps saving the exact table reference that
-- settings.load() returned, so sanitizing must happen IN PLACE.
local function sanitize_in_place(tbl)
    local clean = config.sanitize(tbl)

    for key in pairs(tbl) do
        tbl[key] = nil
    end

    for key, value in pairs(clean) do
        tbl[key] = value
    end

    return tbl
end

-- Push the loaded config into runtime state (reload, character switch).
local function apply_config()
    state.assume_quest_ws = cfg.assume_quest_ws
    state.march_override  = cfg.march_override > 0
                            and cfg.march_override or nil
    ui.visible[1] = cfg.visible
    ui.restore_window_pos(cfg.window_pos)
end

local function character_tag()
    local ok, name = pcall(function()
        return AshitaCore:GetMemoryManager():GetParty():GetMemberName(0)
    end)

    if ok and type(name) == 'string' and #name > 0 then
        return name
    end

    return nil
end

local function fallback_path(tag)
    return addon_path .. 'whetstone_' .. tag .. '_settings.lua'
end

local function save_config()
    if settings_lib then
        settings_lib.save()
        return
    end

    local tag = character_tag()

    if not tag then
        return -- no character yet; next change after login saves
    end

    local file = io.open(fallback_path(tag), 'w')

    if file then
        file:write(config.serialize(cfg))
        file:close()
    end
end

-- File-backend load is LAZY: the character name is not available at
-- the 'load' event, so the first frame that can read it loads the
-- per-character file. With the settings library this never runs.
local function ensure_config_loaded()
    if settings_lib or fallback_loaded then
        return
    end

    local tag = character_tag()

    if not tag then
        return
    end

    fallback_loaded = true

    local file = io.open(fallback_path(tag), 'r')

    if file then
        local text = file:read('*a')
        file:close()

        local loaded = config.deserialize(text)

        if loaded then
            cfg = config.sanitize(loaded)
        end
    end

    apply_config()
end

-- forward declarations (defined after snapshot, used by the command
-- handler closures)
local append_log
local write_session_header
local run_selftest
local snapshot -- defined after the data helpers; captured by the
               -- command handler (the /whet panel crash was this name
               -- resolving as a nil GLOBAL - third member of the
               -- upvalue-capture family after append_log and
               -- get_current_target)

-- One-time error latch: a broken subsystem (the UI especially) logs
-- its full traceback ONCE and goes quiet, instead of either spamming
-- 60 errors a second or - worse - taking the whole addon down and
-- killing packet logging with it (HorizonXI shakedown, v0.1.0-beta).
local error_latch = {}
local append_error -- forward declaration

local function guarded(name, fn, ...)
    -- FIELD BUG (v0.1.2, HorizonXI): { ... } with nil holes has
    -- undefined length, so unpack(args) DROPPED trailing arguments
    -- whenever earlier ones were nil - ui.draw received zero args on
    -- every report-less frame and rendered the catch-all forever
    -- while every command path worked. select('#', ...) preserves
    -- the exact argument count, nils included.
    local count = select('#', ...)
    local args = { ... }

    local ok, err = xpcall(
        function()
            return fn(unpack(args, 1, count))
        end,
        debug.traceback)

    if not ok then
        if not error_latch[name] then
            error_latch[name] = true
            state.latched_error = state.latched_error or name

            -- Chat scrolls away; the full traceback goes to the error
            -- file and the panel shows a persistent red ERROR line.
            print(('[whetstone] %s failed - latched, see '
                .. 'whetstone_error.log (will auto-retry)')
                :format(name))

            if append_error then
                append_error(name, err)
            end
        end
    elseif error_latch[name] then
        -- Self-heal: a transient (startup race, zone churn) must not
        -- disable a subsystem until reload. Log the recovery once.
        error_latch[name] = nil
        print(('[whetstone] %s recovered'):format(name))

        if state.latched_error == name then
            state.latched_error = next(error_latch)
        end
    end

    return ok
end

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
        -- one-time, named: a corrupt zone file must be visible, not a
        -- silently empty panel
        if not error_latch[module_name] then
            error_latch[module_name] = true
            state.latched_error = state.latched_error or module_name
            print(('[whetstone] failed to load %s: %s')
                :format(module_name, tostring(zone_table)))

            if append_error then
                append_error(module_name, zone_table)
            end
        end

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

-- THE one target reader. Used by snapshot, /whet target AND the
-- selftest closure - the v0.1.1 field bug was the selftest reading
-- the target one way while the panel read it another, so 12/12
-- passed against a path production never executed.
--
-- Canonical Ashita v4 pattern (official addons - distance, tparty,
-- skeletonkey): global GetEntity(index) from common, field access on
-- the returned entity_t.
local function get_current_target()
    local target_mgr = AshitaCore:GetMemoryManager():GetTarget()

    if target_mgr == nil then
        return { valid = false, reason = 'target manager unavailable' }
    end

    -- Use the sub-target slot while the <st> cursor is up.
    local slot = 0
    local ok_st, st_active = pcall(function()
        return target_mgr:GetIsSubTargetActive()
    end)

    if ok_st and st_active == 1 then
        slot = 1
    end

    local index = target_mgr:GetTargetIndex(slot)

    if index == nil or index == 0 then
        return { valid = false, reason = 'no target', index = 0 }
    end

    local entity = GetEntity(index)
    local name = entity and entity.Name or nil
    local server_id = (entity and entity.ServerId)
        or target_mgr:GetServerId(slot)

    if name == nil or name == '' then
        return { valid = false, reason = 'entity has no name',
                 index = index, server_id = server_id }
    end

    return
    {
        valid     = true,
        index     = index,
        server_id = server_id,
        name      = name,
        slot      = slot,
    }
end

local function current_zone()
    return AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0)
end

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

    ui.version = addon.version -- title bar: stale builds expose themselves

    -- Per-character persisted state: Ashita settings library when
    -- present (config/whetstone/<char>_<server>/settings.lua, handles
    -- character switches), file fallback otherwise.
    local ok_lib, lib = pcall(require, 'settings')

    if ok_lib and type(lib) == 'table' and lib.load then
        settings_lib = lib
        cfg = sanitize_in_place(lib.load(config.sanitize(nil)))
        apply_config()

        lib.register('settings', 'whetstone_settings_update',
            function(loaded)
                if loaded ~= nil then
                    cfg = sanitize_in_place(loaded)
                    apply_config()
                end
            end)
    else
        print('[whetstone] settings library unavailable - using '
            .. 'per-character file fallback in the addon folder')
    end

    player.attach('whetstone')
end)

ashita.events.register('command', 'whetstone_command', function(e)
    local args = e.command:args()

    if #args == 0 or args[1] ~= '/whet' then
        return
    end

    -- Block BEFORE dispatch: even if the command body errors, the
    -- game must not see '/whet ...' as a chat line.
    e.blocked = true

    -- Latched like d3d_present: a broken command logs its traceback
    -- to whetstone_error.log and the addon stays loaded (the /whet
    -- panel crash unloaded the whole addon).
    guarded('command:' .. tostring(args[2] or 'toggle'), function()

    if args[2] == 'level' then
        state.pinned_level = tonumber(args[3]) -- nil clears

        -- A pin is knowledge about the MOB: persist it per mob name so
        -- it survives reload and re-applies on retarget.
        local target = get_current_target()

        if target.valid then
            cfg.pinned_levels[target.name] = state.pinned_level
            save_config()
        end
    elseif args[2] == 'march' then
        local pct = tonumber(args[3])

        state.march_override = pct and pct / 100 or nil -- nil clears
        cfg.march_override = state.march_override or 0
        save_config()
        print('[whetstone] March override: '
            .. (pct and (pct .. '%') or 'cleared'))
    elseif args[2] == 'quest' then
        state.assume_quest_ws = not state.assume_quest_ws
        cfg.assume_quest_ws = state.assume_quest_ws
        save_config()
        print('[whetstone] quest WS ranking: '
            .. (state.assume_quest_ws and 'ON' or 'OFF'))
    elseif args[2] == 'profile' then
        local name = args[3]

        if name and formulas.PROFILES[name] then
            cfg.profile = name
            save_config()
            print('[whetstone] profile: ' .. name)
        else
            local names = {}
            for key in pairs(formulas.PROFILES) do
                names[#names + 1] = key
            end
            table.sort(names)
            print(('[whetstone] profile is %s (available: %s)')
                :format(cfg.profile, table.concat(names, ', ')))
        end
    elseif args[2] == 'debug' then
        state.debug_log = not state.debug_log
        print('[whetstone] swing logging: '
            .. (state.debug_log and 'ON -> whetstone_swings.log' or 'OFF'))

        if state.debug_log then
            write_session_header()
        end
    elseif args[2] == 'target' then
        local target = get_current_target()
        local zone = current_zone()

        print(('[whetstone] target: valid=%s reason=%s index=%s '
            .. 'server_id=%s name=%s zone=%s slot=%s'):format(
            tostring(target.valid), tostring(target.reason),
            tostring(target.index), tostring(target.server_id),
            tostring(target.name), tostring(zone),
            tostring(target.slot)))

        if target.valid then
            local mobs = mobs_for_zone(zone)
            local entries = mobs and mobs[zone]
                and mobs[zone][target.name]

            if entries then
                print(('[whetstone] mob DB: HIT - %d candidate '
                    .. 'entr%s'):format(#entries,
                    #entries == 1 and 'y' or 'ies'))
            else
                print('[whetstone] mob DB: MISS - name not in this '
                    .. "zone's table (player/NPC, custom server mob, "
                    .. 'or name mismatch)')
            end
        end
    elseif args[2] == 'panel' then
        -- Dump the EXACT state the next frame renders, plus module/
        -- table identities (the duplicate-module-instance check: the
        -- addresses printed here must match what the draw path uses).
        local target = get_current_target()
        local zone = current_zone()
        local mobs = mobs_for_zone(zone)
        local db_hit = target.valid and mobs and mobs[zone]
            and mobs[zone][target.name] ~= nil

        local snap, _, status = snapshot()

        print(('[whetstone] panel: player_ready=%s target_valid=%s '
            .. 'db_hit=%s advisor_ok=%s'):format(
            tostring(player.state.char_stats ~= nil
                and player.state.skills ~= nil),
            tostring(target.valid), tostring(db_hit),
            tostring(state.last_report ~= nil
                and state.last_report.error == nil)))
        print(('[whetstone] panel: live_status=%s/%s cached_status=%s '
            .. 'latched=%s visible=%s'):format(
            tostring(status and status.state),
            tostring(status and status.detail),
            tostring(state.last_status and state.last_status.state),
            tostring(state.latched_error), tostring(ui.visible[1])))
        print(('[whetstone] panel: ids state=%s ui=%s ui.draw=%s '
            .. 'player.state=%s version=%s'):format(
            tostring(state), tostring(ui), tostring(ui.draw),
            tostring(player.state), tostring(ui.version)))
        print('[whetstone] panel: ui.DRAW_VERSION=' ..
            tostring(ui.DRAW_VERSION))

        if snap then
            print('[whetstone] panel: snapshot builds OK this instant')
        end
    elseif args[2] == 'selftest' then
        run_selftest()
    else
        ui.visible[1] = not ui.visible[1]
    end
    end)
end)


-- Build the advisor input from live state.
-- Returns snap, haste, status - status ALWAYS set, with a distinct
-- state per failure mode so the panel never collapses everything
-- into "No target." (the v0.1.1 field bug's second half):
--   'waiting_packets' | 'no_target' | 'no_zone_data' | 'no_weapon'
--   | 'ok'
snapshot = function()
    local stats = player.state.char_stats
    local skills = player.state.skills

    if not stats or not skills then
        return nil, nil, { state = 'waiting_packets' }
    end

    player.refresh()

    local target = get_current_target()

    if not target.valid then
        return nil, nil, { state = 'no_target',
                           detail = target.reason }
    end

    local name = target.name
    local zone = current_zone()

    -- Per-zone mob table (split layout) or the monolithic fallback;
    -- loading swaps the previous zone out of the 32-bit heap.
    local mobs = mobs_for_zone(zone)

    if not mobs then
        return nil, nil, { state = 'no_zone_data', detail = zone }
    end

    local gear = player.gear_stats(player.state.equipment,
                                   data.items or {})
    local main = gear.main and gear.main.weapon

    if not main then
        local main_id = player.state.equipment[0]

        if main_id == nil then
            -- EMPTY main slot: the server equips an unarmed pseudo-
            -- weapon (itemutils.cpp do_init; charutils.cpp
            -- CheckUnarmedWeapon): H2H-capable characters get the H2H
            -- one. Client-side proxy for "has an H2H skill rank":
            -- a nonzero parsed H2H skill. Modeled as H2H either way
            -- (the no-skill case still punches: natural damage 3).
            local h2h = skills.by_name.hand_to_hand
            local h2h_value = h2h and h2h.value or 0

            main =
            {
                skill   = 'hand_to_hand',
                dmg     = h2h_value > 0 and formulas.UNARMED_H2H.dmg
                          or formulas.UNARMED.dmg,
                delay   = formulas.UNARMED_H2H.delay,
                unarmed = true,
            }
        else
            -- S2w now means EXACTLY this: an id is equipped but the
            -- item DB has no weapon for it (custom-server item or
            -- non-weapon in the slot).
            return nil, nil, { state = 'no_weapon', detail = main_id }
        end
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

    local trait_da, trait_ta = formulas.trait_multi_rates(
        JOB_NAMES[stats.main_job], stats.main_level,
        JOB_NAMES[stats.sub_job], stats.sub_level)

    return
    {
        player =
        {
            level     = stats.main_level,
            main_job  = JOB_NAMES[stats.main_job],
            sub_job   = JOB_NAMES[stats.sub_job],
            stats     = stats.stats,
            attack    = stats.attack,
            accuracy  = accuracy,
            ws_skill  = skill_value,
            -- gear crit mods are EXACT via the item DB (whitelisted
            -- Mod 165 / Mod 421), same precision class as gear haste
            crit_rate_bonus = (gear.crit_rate or 0) / 100,
            crit_dmg_bonus  = (gear.crit_dmg or 0) / 100,
            -- multi-attack on WS swings (weaponskills.lua
            -- getMultiAttacks): era traits (WAR DA / THF TA, main or
            -- sub) + exact gear mods 288/302 from the item DB
            double_attack = (trait_da + (gear.double_attack or 0)) / 100,
            triple_attack = (trait_ta + (gear.triple_attack or 0)) / 100,
            weapon    =
            {
                dmg       = main.dmg,
                delay     = main.delay,
                skill     = main.skill,
                unarmed   = main.unarmed or nil,
                -- natural damage / WS H2H handling need the skill level
                h2h_skill = main.skill == 'hand_to_hand'
                            and skill_value or nil,
                -- Martial Arts delay reduction (traits.sql via
                -- formulas; MNK/PUP only) and the 2-swing round
                martial_arts = main.skill == 'hand_to_hand'
                    and formulas.martial_arts(
                        JOB_NAMES[stats.main_job] or '?',
                        stats.main_level) or nil,
                swings_per_round = main.skill == 'hand_to_hand'
                    and formulas.H2H_SWINGS_PER_ROUND or 1,
                -- relic/mythic WS grant from the equipped weapon's
                -- item mod (ADDS_WEAPONSKILL = 355)
                adds_weaponskill = gear.main
                    and gear.main.adds_weaponskill or nil,
            },
            offhand_dmg = gear.sub and gear.sub.weapon
                and gear.sub.weapon.dmg or nil,
        },
        haste           = haste,
        -- session pin wins; otherwise the persisted per-mob pin
        target          = { zone = zone, name = name,
                            level = state.pinned_level
                                or cfg.pinned_levels[name] },
        data            = { mobs = mobs, ws = data.ws,
                            items = data.items },
        profile         = cfg.profile,
        tp              = AshitaCore:GetMemoryManager():GetParty()
            :GetMemberTP(0),
        assume_quest_ws = state.assume_quest_ws,
        -- 75-era original zones are level-corrected; post-ToAU zones
        -- mostly not. TODO: zone table; default on for now.
        level_correction = true,
    }, haste, { state = 'ok' }
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
        -- H2H-aware: includes natural damage for fist swings, so the
        -- logged base matches what the server actually rolls against
        weapon_dmg       = advisor.effective_weapon_dmg(weapon),
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

append_error = function(name, traceback)
    local file = io.open(addon_path .. 'whetstone_error.log', 'a')

    if file then
        file:write(string.format('=== %s %s ===\n%s\n',
            os.date('%Y-%m-%d %H:%M:%S'), name, tostring(traceback)))
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
        profile      = cfg.profile,
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

        { name = 'target_resolution', fn = function()
            -- THE production path: same function the panel uses. The
            -- v0.1.1 selftest read the target its own way and passed
            -- 12/12 while the panel showed "No target." forever.
            local target = get_current_target()

            if target.valid then
                return ('index=%d server_id=%s name=%s'):format(
                    target.index, tostring(target.server_id),
                    target.name)
            end

            expect(target.reason == 'no target',
                'production target read failed: '
                .. tostring(target.reason))
            return 'no target selected (select a mob to test '
                .. 'resolution)'
        end },

        { name = 'target_mob_db', fn = function()
            local target = get_current_target()

            if not target.valid then
                return 'skipped (no target)'
            end

            local zone = current_zone()
            local mobs = mobs_for_zone(zone)
            local entries = mobs and mobs[zone]
                and mobs[zone][target.name]

            if entries then
                return ('HIT: %d entries for %s in zone %d'):format(
                    #entries, target.name, zone)
            end

            return ('MISS: %s not in zone %d table (expected on '
                .. 'custom servers)'):format(target.name, zone)
        end },

        { name = 'snapshot_status', fn = function()
            -- The FULL production pipeline, status and all.
            local snap, _, status = snapshot()

            return ('state=%s detail=%s snap=%s'):format(
                tostring(status and status.state),
                tostring(status and status.detail),
                snap and 'built' or 'nil')
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

local pos_settle = nil -- frames until the moved panel position saves

ashita.events.register('d3d_present', 'whetstone_present', function()
    -- Config sync runs BEFORE the visibility early-return: closing the
    -- panel via the title-bar X must still persist visible=false.
    guarded('config_sync', function()
        ensure_config_loaded()

        if cfg.visible ~= ui.visible[1] then
            cfg.visible = ui.visible[1]
            save_config()
        end

        -- Position saves once the window stops moving for ~30 frames,
        -- not on every dragged pixel.
        local pos = ui.window_pos

        if pos then
            if pos.x ~= cfg.window_pos.x
                or pos.y ~= cfg.window_pos.y then
                cfg.window_pos.x = pos.x
                cfg.window_pos.y = pos.y
                pos_settle = 30
            elseif pos_settle then
                pos_settle = pos_settle - 1

                if pos_settle <= 0 then
                    pos_settle = nil
                    save_config()
                end
            end
        end
    end)

    if not ui.visible[1] and not state.debug_log then
        return
    end

    -- Data path: latched separately so a UI bug cannot starve
    -- swinglog expectations (and vice versa).
    guarded('advisor_update', function()
        local snap, haste, status = snapshot()

        -- Log each state TRANSITION once: permanent, spam-free proof
        -- of when the frame-time assembler runs and what it decided.
        if status and status.state ~= (state.last_status
                and state.last_status.state) then
            print(('[whetstone] panel state -> %s%s'):format(
                status.state,
                status.detail and (' (' .. tostring(status.detail) .. ')')
                    or ''))
        end

        state.last_status = status

        if snap then
            local report = advisor.evaluate(snap)

            state.last_report = report
            state.last_haste = haste
            update_expectations(snap, report)
        else
            -- NEVER render a stale report over a changed situation
            state.last_report = nil
            state.last_haste = nil
        end
    end)

    local status = state.last_status or {}
    status.latched_error = state.latched_error

    guarded('ui.draw', ui.draw, state.last_report, state.last_haste,
            status)
end)
