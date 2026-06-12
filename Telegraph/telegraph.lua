--[[
    Telegraph - Ashita v4 addon bootstrap.

    Mob cast bars, TP-move windup bars and a mob TP estimator for
    75-cap era FFXI private servers (Phoenix), sibling to Whetstone.

    Wires together:
      actionpacket.lua  THE shared 0x028/0x029 parser (one require
                        path, shared with Whetstone)
      castbar.lua       cast/windup bar state machine (pure)
      tpledger.lua      TP formulas + interval ledger (pure)
      ui.lua            TextUnformatted-only ImGui panel
      selftest.lua      shared check runner
      config.lua        persistence core (fixed T{} pattern)
      data/*.lua        GENERATED tables (spells, mobskills, mobs) -
                        see README "Release packaging"

    Commands:
      /tele             toggle the panel
      /tele debug       toggle validation logging to
                        telegraph_events.log (cast/ready observed vs
                        table timing, TP estimates at fire time)
      /tele selftest    exercise every Ashita glue call via the SAME
                        production paths and write
                        telegraph_selftest.log
      /tele profile <p> switch tpledger profile (phoenix | lsb)
      /tele tp          toggle the TP estimate section
      /tele bars        toggle the cast/ready bar section
      /tele panel       dump the exact state the next frame renders

    Every event callback is pcall-latched (errors land in
    telegraph_error.log ONCE, the addon stays alive and self-heals on
    recovery - the Whetstone v0.1.0 lesson). This file is Ashita glue
    and needs an in-game shakedown; everything it calls is unit-tested
    pure Lua.
]]

addon.name    = 'telegraph'
addon.author  = 'Whetstone'
addon.version = '0.1.0-beta'
addon.desc    = 'Mob cast bars, TP windup bars, TP estimator (75-cap era)'

require('common')

-- shared/?.lua: actionpacket + selftest (the canonical require names;
-- releases bundle them into the addon folder, the ../shared path makes
-- a raw git checkout work)
local addon_path = addon.path:gsub('\\', '/')
package.path = string.format(
    '%s?.lua;%sdata/?.lua;%sshared/?.lua;%s../shared/?.lua;%s',
    addon_path, addon_path, addon_path, addon_path, package.path)

local actionpacket = require('actionpacket')
local castbar      = require('castbar')
local tpledger     = require('tpledger')
local ui           = require('ui')
local selftest     = require('selftest')
local config       = require('config')

local state =
{
    debug_log     = false,
    last_status   = nil,
    latched_error = nil,
    zone          = nil,
    -- production-path counters (selftest/panel name these)
    seen_0x028    = 0,
    seen_dupes    = 0,
    parse_fails   = 0,
    bar_events    = 0,
    tp_mutations  = 0,
}

local ledger = tpledger.new()
local bars   = castbar.new()

local data = { spells = nil, mobskills = nil }
local mob_index = nil -- split layout: data/mobs/index.lua
local mob_cache = {}  -- one zone resident at a time (32-bit process)

local function load_data(name)
    local ok, result = pcall(require, name)

    if not ok then
        print(('[telegraph] missing data/%s.lua - run the extractors '
            .. '(see README)'):format(name))
        return nil
    end

    return result
end

-- =====================================================================
-- Error latch (the Whetstone one-time latch + self-heal pattern)
-- =====================================================================

local append_error -- forward declaration
local append_event_log

local error_latch = {}

local function guarded(name, fn, ...)
    -- select('#', ...) preserves nil holes (the Whetstone v0.1.2
    -- vararg-transport bug)
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

            print(('[telegraph] %s failed - latched, see '
                .. 'telegraph_error.log (will auto-retry)')
                :format(name))

            if append_error then
                append_error(name, err)
            end
        end
    elseif error_latch[name] then
        error_latch[name] = nil
        print(('[telegraph] %s recovered'):format(name))

        if state.latched_error == name then
            state.latched_error = next(error_latch)
        end
    end

    return ok
end

append_error = function(name, traceback)
    local file = io.open(addon_path .. 'telegraph_error.log', 'a')

    if file then
        file:write(string.format('=== %s %s ===\n%s\n',
            os.date('%Y-%m-%d %H:%M:%S'), name, tostring(traceback)))
        file:close()
    end
end

append_event_log = function(lines)
    if #lines == 0 then
        return
    end

    local file = io.open(addon_path .. 'telegraph_events.log', 'a')

    if file then
        for _, line in ipairs(lines) do
            file:write(line, '\n')
        end

        file:close()
    end
end

-- =====================================================================
-- Persisted user state (config.lua core, Ashita settings lib backend -
-- the whole block is the Whetstone fixed pattern)
-- =====================================================================

local cfg = config.sanitize(nil)
local settings_lib = nil
local fallback_loaded = false

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

local function apply_config()
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
    return addon_path .. 'telegraph_' .. tag .. '_settings.lua'
end

local save_warned = false

local function save_config()
    local ok, err = pcall(function()
        if settings_lib then
            settings_lib.save()
            return
        end

        local tag = character_tag()

        if not tag then
            return
        end

        local file = io.open(fallback_path(tag), 'w')

        if file then
            file:write(config.serialize(cfg))
            file:close()
        end
    end)

    if not ok and not save_warned then
        save_warned = true
        print(('[telegraph] settings save failed (%s) - state kept '
            .. 'in memory for this session'):format(tostring(err)))
    end
end

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

-- =====================================================================
-- Era trait tables for the OWN-player feed (the only attacker whose
-- delay we can know exactly). Values from sql/traits.sql @ 0f3f8fc,
-- era rows only (content_tag NULL/TOAU; ABYSSEA rows absent at 75):
--   Dual Wield (trait 18, mod 259): NIN 10@10, 15@25, 25@45, 30@65
--   Martial Arts (trait 23, mod 173): MNK 80@1..180@75; PUP (TOAU)
--   80@25, 100@50, 120@75
-- =====================================================================

local JOB_NIN, JOB_MNK, JOB_PUP = 13, 2, 18

local function dual_wield_mod(main_job, main_level, sub_job, sub_level)
    local best = 0

    local function nin(level)
        if level >= 65 then return 30 end
        if level >= 45 then return 25 end
        if level >= 25 then return 15 end
        if level >= 10 then return 10 end
        return 0
    end

    if main_job == JOB_NIN then
        best = nin(main_level or 0)
    end

    if sub_job == JOB_NIN then
        best = math.max(best, nin(sub_level or 0))
    end

    return best
end

local function martial_arts_mod(main_job, main_level, sub_job, sub_level)
    local function mnk(level)
        if level >= 75 then return 180 end
        if level >= 61 then return 160 end
        if level >= 46 then return 140 end
        if level >= 31 then return 120 end
        if level >= 16 then return 100 end
        if level >= 1 then return 80 end
        return 0
    end

    local function pup(level)
        if level >= 75 then return 120 end
        if level >= 50 then return 100 end
        if level >= 25 then return 80 end
        return 0
    end

    local best = 0

    if main_job == JOB_MNK then best = mnk(main_level or 0) end
    if main_job == JOB_PUP then best = math.max(best, pup(main_level or 0)) end
    if sub_job == JOB_MNK then best = math.max(best, mnk(sub_level or 0)) end
    if sub_job == JOB_PUP then best = math.max(best, pup(sub_level or 0)) end

    return best
end

-- =====================================================================
-- Entity / zone helpers
-- =====================================================================

local function current_zone()
    return AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0)
end

local function my_server_id()
    return AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(0)
end

-- Dynamic-entity (mob/NPC/pet) server ids encode their zone index:
-- id = 0x1000000 | (zone << 12) | index (the same encoding
-- extract_mobs.py reads back out of mob_spawn_points.mobid). Players
-- sit below 0x1000000.
local function is_mob_id(id)
    return type(id) == 'number' and id >= 0x1000000
end

-- Resolve a dynamic entity's name via its embedded index. Verifies
-- the entity's ServerId actually matches (zone-in races and id reuse
-- otherwise hand back a stranger's name).
local function entity_name_by_id(id)
    if not is_mob_id(id) then
        return nil
    end

    local index = id % 4096

    local ok, name = pcall(function()
        local entity = GetEntity(index)

        if entity == nil or entity.Name == nil or entity.Name == '' then
            return nil
        end

        if entity.ServerId ~= nil and entity.ServerId ~= id then
            return nil -- index occupied by a different entity
        end

        return entity.Name
    end)

    if ok then
        return name
    end

    return nil
end

-- One zone's mob table at a time (the Whetstone 32-bit pattern).
local function mobs_for_zone(zone)
    if not mob_index then
        return nil
    end

    if mob_cache.zone == zone then
        return mob_cache.table
    end

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
        if not error_latch[module_name] then
            error_latch[module_name] = true
            state.latched_error = state.latched_error or module_name
            print(('[telegraph] failed to load %s: %s')
                :format(module_name, tostring(zone_table)))

            if append_error then
                append_error(module_name, zone_table)
            end
        end

        return nil
    end

    collectgarbage('collect')

    mob_cache =
    {
        zone   = zone,
        module = module_name,
        table  = zone_table,
    }

    return zone_table
end

-- =====================================================================
-- tpledger ctx callbacks (production paths; the selftest exercises
-- these same closures)
-- =====================================================================

-- Mob DB row(s) for a server id -> TP params. Same-name entries can
-- sit in different pools: the delay travels as a band over every
-- candidate, tp_mods/h2h from the first (documented approximation).
local function mob_params(id)
    local name = entity_name_by_id(id)

    if not name then
        return nil
    end

    local zone_table = mobs_for_zone(state.zone)
    local entries = zone_table and zone_table[name]

    if not entries or #entries == 0 then
        return nil
    end

    local lo, hi = nil, nil

    for _, entry in ipairs(entries) do
        local delay = entry.cmb_delay or 240

        if not lo or delay < lo then lo = delay end
        if not hi or delay > hi then hi = delay end
    end

    local first = entries[1]
    local tp_mods = first.tp_mods or {}

    return
    {
        delay = { lo = lo, hi = hi, best = first.cmb_delay or 240 },
        h2h = first.h2h or false,
        store_tp = tp_mods.store_tp,
        inhibit = tp_mods.inhibit_tp,
        regain = tp_mods.regain,
        agi = nil, -- level-dependent; dAGI mod is structurally 1.0
    }
end

-- The own player is the one attacker with knowable delay: equipped
-- item ids resolve through Ashita's resource manager (client DAT
-- delay; matches item_weapon.sql on stock servers - custom items
-- excepted, README caveat). H2H server delay = DAT delay + 480
-- (itemutils.cpp convention, same row as Whetstone's PROVENANCE).
local function own_attacker_params()
    local ok, params = pcall(function()
        local memory = AshitaCore:GetMemoryManager()
        local inventory = memory:GetInventory()
        local resources = AshitaCore:GetResourceManager()

        local function equipped_item(slot)
            local entry = inventory:GetEquippedItem(slot)

            if entry == nil or entry.Index == 0 then
                return nil
            end

            local container = math.floor(entry.Index / 256)
            local index = entry.Index % 256
            local item = inventory:GetContainerItem(container, index)

            if item == nil or item.Id == nil or item.Id == 0 then
                return nil
            end

            return resources:GetItemById(item.Id)
        end

        local main = equipped_item(0)
        local sub = equipped_item(1)

        if main == nil or type(main.Delay) ~= 'number' then
            return nil
        end

        local player = memory:GetPlayer()
        local main_job = player:GetMainJob()
        local main_level = player:GetMainJobLevel()
        local sub_job = player:GetSubJob()
        local sub_level = player:GetSubJobLevel()

        local h2h = main.Skill == 1
        local delay = main.Delay

        if h2h then
            delay = delay + 480 -- SQL/server H2H base convention
        end

        -- sub WEAPON (not shield/grip): 1H weapon skill types 2-11
        local dual = false

        if not h2h and sub ~= nil and type(sub.Delay) == 'number'
            and type(sub.Skill) == 'number'
            and sub.Skill >= 2 and sub.Skill <= 11 then
            delay = delay + sub.Delay -- GetBaseDelay sums main+sub
            dual = true
        end

        return
        {
            delay = delay,
            h2h = h2h,
            dual_wield = dual,
            dual_wield_mod = dual_wield_mod(main_job, main_level,
                sub_job, sub_level),
            martial_arts = h2h and martial_arts_mod(main_job,
                main_level, sub_job, sub_level) or 0,
            single_fist = false,
            -- subtle blow gear is not modeled (no item DB here):
            -- own-feed bounds stay exact-delay / unknown-SB
            subtle_blow = 0,
        }
    end)

    if ok then
        return params
    end

    return nil
end

local function ledger_ctx()
    local me = my_server_id()

    return
    {
        zone = state.zone,
        profile = cfg.profile,
        classify = actionpacket.classify,
        is_mob = is_mob_id,
        mob_params = mob_params,
        attacker_params = function(id)
            if id == me then
                return own_attacker_params()
            end

            return nil -- party members: POLICY bounds
        end,
        mobskill_info = function(id)
            local info = data.mobskills and data.mobskills[id]

            if info then
                return { tp_free = info.tp_free or false,
                         name = info.name }
            end

            return nil
        end,
        ws_info = function()
            return nil -- no WS table here: POLICY hit bounds
        end,
    }
end

local function castbar_ctx()
    return
    {
        classify = actionpacket.classify,
        spell_info = function(id)
            local info = data.spells and data.spells[id]

            if info then
                return { name = info.name, cast_ms = info.cast_ms }
            end

            return nil
        end,
        mobskill_info = function(id)
            local info = data.mobskills and data.mobskills[id]

            if info then
                -- windup 0 = instant: no bar (the server never sends
                -- a readying for these anyway)
                return { name = info.name,
                         windup_ms = info.windup_ms > 0
                             and info.windup_ms or nil }
            end

            return nil
        end,
    }
end

-- =====================================================================
-- Debug validation logging (phase 4 analyzer raw material)
-- =====================================================================

local function log_bar_events(events, now)
    if not state.debug_log or #events == 0 then
        return
    end

    local lines = {}

    for _, event in ipairs(events) do
        lines[#lines + 1] = string.format(
            '%s t=%.3f bar kind=%s actor=%d id=%s label=%s '
            .. 'expected_s=%s observed_s=%.3f outcome=%s',
            os.date('%H:%M:%S'), now, event.kind, event.actor,
            tostring(event.id), tostring(event.label),
            event.expected_s and string.format('%.3f', event.expected_s)
                or 'n/a',
            event.observed_s, event.outcome)
    end

    append_event_log(lines)
end

-- At the instant a readying arrives the truth is TP >= 1000: log the
-- PRE-clamp estimate so the analyzer can judge the model against it.
local function log_tp_at_fire(action, kind, ref_id, now)
    if not state.debug_log then
        return
    end

    if kind ~= 'ready_start' and kind ~= 'mobskill_finish'
        and not (kind == 'ws_finish' and is_mob_id(action.actor)) then
        return
    end

    local est = tpledger.estimate(ledger, action.actor, state.zone, now)

    if not est then
        return
    end

    local skill = data.mobskills and data.mobskills[ref_id]

    append_event_log({ string.format(
        '%s t=%.3f tp_estimate_at_fire actor=%d skill=%s kind=%s '
        .. 'lo=%d hi=%d best=%d confidence=%s implied_truth=ge1000%s',
        os.date('%H:%M:%S'), now, action.actor,
        tostring(ref_id), kind, est.lo, est.hi, est.best,
        est.confidence,
        skill and skill.tp_free and ' tp_free' or '') })
end

-- =====================================================================
-- Packet events (ALWAYS on - bars and the ledger must not require
-- debug mode; every path latched)
-- =====================================================================

ashita.events.register('packet_in', 'telegraph_action_packet',
    function(event)
        if event.id ~= actionpacket.PACKET_ACTION then
            return
        end

        guarded('action_packet', function()
            state.seen_0x028 = state.seen_0x028 + 1

            if actionpacket.is_duplicate(event.data) then
                state.seen_dupes = state.seen_dupes + 1
                return
            end

            local ok, action = pcall(actionpacket.parse_action,
                event.data)

            if not ok or not action then
                state.parse_fails = state.parse_fails + 1
                return
            end

            local now = os.clock()

            -- zone tracking rides the packet path too (a zone change
            -- between frames must not feed the old zone's ledger)
            local zone = current_zone()

            if zone ~= state.zone then
                state.zone = zone
                castbar.on_zone_change(bars)
                -- tpledger wipes itself on the zone mismatch inside
                -- entry_for; nothing to do
            end

            -- the TP-at-fire log reads the PRE-event estimate, so it
            -- runs before on_action mutates the ledger
            local kind, ref_id = actionpacket.classify(action)

            if kind then
                log_tp_at_fire(action, kind, ref_id, now)
            end

            local events = castbar.on_action(bars, action,
                castbar_ctx(), now)

            state.bar_events = state.bar_events + #events
            log_bar_events(events, now)

            state.tp_mutations = state.tp_mutations
                + tpledger.on_action(ledger, action, ledger_ctx(), now)
        end)
    end)

ashita.events.register('packet_in', 'telegraph_battle_message',
    function(event)
        if event.id ~= actionpacket.PACKET_BATTLE_MESSAGE then
            return
        end

        guarded('battle_message', function()
            local message = actionpacket.parse_battle_message(event.data)

            if not message then
                return
            end

            -- death: the id is about to recycle - evict everywhere
            if actionpacket.DEATH_MESSAGES[message.message_id] then
                tpledger.forget(ledger, message.target_id)
                castbar.on_death(bars, message.target_id)
            end
        end)
    end)

-- =====================================================================
-- Frame: report assembly + draw
-- =====================================================================

local function current_target_id()
    local ok, id = pcall(function()
        local target_mgr = AshitaCore:GetMemoryManager():GetTarget()

        if target_mgr == nil then
            return nil
        end

        local slot = 0
        local ok_st, st_active = pcall(function()
            return target_mgr:GetIsSubTargetActive()
        end)

        if ok_st and st_active == 1 then
            slot = 1
        end

        local index = target_mgr:GetTargetIndex(slot)

        if index == nil or index == 0 then
            return nil
        end

        local entity = GetEntity(index)

        return entity and entity.ServerId or nil
    end)

    if ok then
        return id
    end

    return nil
end

-- Build the ui report: bars (named) + TP lines (current target first,
-- then bar actors).
local function build_report(now)
    local report = { bars = {}, tp = {} }

    if cfg.show_bars then
        for _, bar in ipairs(castbar.bars(bars, now)) do
            report.bars[#report.bars + 1] =
            {
                kind = bar.kind,
                actor_name = entity_name_by_id(bar.actor)
                    or ('id ' .. tostring(bar.actor)),
                label = bar.label,
                remaining_s = bar.remaining_s,
                duration_s = bar.duration_s,
                fraction = bar.fraction,
                overrun = bar.overrun,
            }
        end
    end

    if cfg.show_tp then
        local listed = {}

        local function add_tp(id)
            if not id or listed[id] or not is_mob_id(id) then
                return
            end

            local est = tpledger.estimate(ledger, id, state.zone, now)

            if est then
                listed[id] = true
                report.tp[#report.tp + 1] =
                {
                    name = entity_name_by_id(id)
                        or ('id ' .. tostring(id)),
                    percent = est.percent,
                    lo_percent = est.lo_percent,
                    hi_percent = est.hi_percent,
                    marker = est.marker,
                    pending = est.pending,
                    confidence = est.confidence,
                }
            end
        end

        add_tp(current_target_id())

        for _, bar in ipairs(castbar.bars(bars, now)) do
            add_tp(bar.actor)
        end
    end

    return report
end

local pos_settle = nil

ashita.events.register('d3d_present', 'telegraph_present', function()
    guarded('config_sync', function()
        ensure_config_loaded()

        if cfg.visible ~= ui.visible[1] then
            cfg.visible = ui.visible[1]
            save_config()
        end

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

    if not ui.visible[1] then
        return
    end

    local report = nil
    local status

    if not data.spells or not data.mobskills then
        status = { state = 'waiting_data' }
    else
        status = { state = 'ok' }
    end

    guarded('report_build', function()
        local zone = current_zone()

        if zone ~= state.zone then
            state.zone = zone
            castbar.on_zone_change(bars)
        end

        report = build_report(os.clock())
    end)

    status.latched_error = state.latched_error

    guarded('ui.draw', ui.draw, report, status)
end)

-- =====================================================================
-- Selftest (named production-path checks; the closures below ARE the
-- paths the packet handler and report builder run)
-- =====================================================================

local run_selftest = function()
    local expect = selftest.expect

    local checks =
    {
        { name = 'memory_manager', fn = function()
            expect(AshitaCore ~= nil, 'AshitaCore missing')
            expect(AshitaCore:GetMemoryManager() ~= nil,
                'GetMemoryManager returned nil')
            return 'present'
        end },

        { name = 'party_zone_id', fn = function()
            local zone = current_zone()
            expect(type(zone) == 'number', 'zone read failed')
            return 'zone=' .. tostring(zone)
        end },

        { name = 'player_server_id', fn = function()
            local id = my_server_id()
            expect(type(id) == 'number' and id > 0,
                'no player server id (not logged in?)')
            return ('id=%d (mob-range=%s)'):format(id,
                tostring(is_mob_id(id)))
        end },

        { name = 'player_job_levels', fn = function()
            local player = AshitaCore:GetMemoryManager():GetPlayer()
            expect(player ~= nil, 'GetPlayer returned nil')
            return ('job=%s/%s lv=%s/%s'):format(
                tostring(player:GetMainJob()),
                tostring(player:GetSubJob()),
                tostring(player:GetMainJobLevel()),
                tostring(player:GetSubJobLevel()))
        end },

        { name = 'own_attacker_params', fn = function()
            -- THE production closure the ledger's victim feeds use
            local params = own_attacker_params()

            if not params then
                return 'unavailable (no weapon resource) - feeds '
                    .. 'fall back to POLICY bounds'
            end

            return ('delay=%d h2h=%s dw=%s dw_mod=%d ma=%d'):format(
                params.delay, tostring(params.h2h),
                tostring(params.dual_wield),
                params.dual_wield_mod or 0, params.martial_arts or 0)
        end },

        { name = 'target_resolution', fn = function()
            local id = current_target_id()

            if not id then
                return 'no target selected (select a mob to test)'
            end

            return ('server_id=%d name=%s'):format(id,
                tostring(entity_name_by_id(id)))
        end },

        { name = 'entity_by_id_roundtrip', fn = function()
            -- the id -> index -> entity resolution the report builder
            -- and mob_params depend on
            local id = current_target_id()

            if not id or not is_mob_id(id) then
                return 'skipped (target a mob to test)'
            end

            local name = entity_name_by_id(id)
            expect(name ~= nil,
                'embedded-index resolution failed for ' .. id)
            return ('id=%d -> index=%d -> %s'):format(id, id % 4096,
                name)
        end },

        { name = 'data_spells', fn = function()
            expect(data.spells ~= nil, 'data/spells.lua not loaded')
            local count = 0
            for key in pairs(data.spells) do
                if type(key) == 'number' then count = count + 1 end
            end
            return ('%d spells (vintage %s)'):format(count,
                tostring(data.spells.vintage))
        end },

        { name = 'data_mobskills', fn = function()
            expect(data.mobskills ~= nil,
                'data/mobskills.lua not loaded')
            local count = 0
            for key in pairs(data.mobskills) do
                if type(key) == 'number' then count = count + 1 end
            end
            return ('%d skills (vintage %s)'):format(count,
                tostring(data.mobskills.vintage))
        end },

        { name = 'data_mobs', fn = function()
            if not mob_index then
                return 'absent (OPTIONAL: TP feeds use POLICY bounds)'
            end

            return ('split: %d entries indexed (vintage %s)'):format(
                mob_index.total_entries or -1,
                tostring(mob_index.vintage))
        end },

        { name = 'zone_mob_load', fn = function()
            if not mob_index then
                return 'skipped (no mob data)'
            end

            local zone_table = mobs_for_zone(current_zone())

            if not zone_table then
                return ('no table for zone %s (ok for cities)')
                    :format(tostring(current_zone()))
            end

            local count = 0
            for _ in pairs(zone_table) do count = count + 1 end
            return ('zone %d: %d mob names'):format(current_zone(),
                count)
        end },

        { name = 'mob_params_path', fn = function()
            local id = current_target_id()

            if not id or not is_mob_id(id) then
                return 'skipped (target a mob to test)'
            end

            local params = mob_params(id)

            if not params then
                return 'no DB row (custom mob?) - POLICY bounds'
            end

            return ('delay=[%d,%d] h2h=%s regain=%s'):format(
                params.delay.lo, params.delay.hi,
                tostring(params.h2h), tostring(params.regain))
        end },

        { name = 'packet_flow', fn = function()
            return ('0x028 seen=%d dupes=%d parse_fails=%d '
                .. 'bar_events=%d tp_mutations=%d'):format(
                state.seen_0x028, state.seen_dupes, state.parse_fails,
                state.bar_events, state.tp_mutations)
        end },

        { name = 'ledger_id_keyed', fn = function()
            tpledger.assert_id_keyed(ledger)
            return ('OK; %d entries (zone %s)'):format(ledger.count,
                tostring(ledger.zone))
        end },

        { name = 'castbar_id_keyed', fn = function()
            castbar.assert_id_keyed(bars)
            return ('OK; %d live bars'):format(bars.count)
        end },

        { name = 'settings_backend', fn = function()
            if settings_lib then
                return 'ashita settings lib (per-character)'
            end

            return 'file fallback ('
                .. (fallback_loaded and 'loaded' or 'pending character')
                .. ')'
        end },
    }

    local report = selftest.run(checks)

    local file = io.open(addon_path .. 'telegraph_selftest.log', 'w')
    if file then
        file:write(table.concat(report.lines, '\n'), '\n')
        file:close()
    end

    print(('[telegraph] selftest: %d ok, %d failed -> '
        .. 'telegraph_selftest.log'):format(report.ok, report.failed))
end

-- =====================================================================
-- Commands
-- =====================================================================

ashita.events.register('command', 'telegraph_command', function(e)
    local args = e.command:args()

    if #args == 0 or args[1] ~= '/tele' then
        return
    end

    e.blocked = true

    guarded('command:' .. tostring(args[2] or 'toggle'), function()

    if args[2] == 'debug' then
        state.debug_log = not state.debug_log
        print('[telegraph] validation logging: '
            .. (state.debug_log and 'ON -> telegraph_events.log'
                or 'OFF'))

        if state.debug_log then
            append_event_log({ string.format(
                '=== telegraph session %s version=%s profile=%s '
                .. 'vintage spells=%s mobskills=%s mobs=%s ===',
                os.date('%Y-%m-%d %H:%M:%S'), addon.version,
                cfg.profile,
                tostring(data.spells and data.spells.vintage),
                tostring(data.mobskills and data.mobskills.vintage),
                tostring(mob_index and mob_index.vintage)) })
        end
    elseif args[2] == 'selftest' then
        run_selftest()
    elseif args[2] == 'profile' then
        local name = args[3]

        if name and tpledger.PROFILES[name] then
            cfg.profile = name
            save_config()
            print('[telegraph] profile: ' .. name)
        else
            local names = {}
            for key in pairs(tpledger.PROFILES) do
                names[#names + 1] = key
            end
            table.sort(names)
            print(('[telegraph] profile is %s (available: %s)')
                :format(cfg.profile, table.concat(names, ', ')))
        end
    elseif args[2] == 'tp' then
        cfg.show_tp = not cfg.show_tp
        save_config()
        print('[telegraph] TP estimates: '
            .. (cfg.show_tp and 'ON' or 'OFF'))
    elseif args[2] == 'bars' then
        cfg.show_bars = not cfg.show_bars
        save_config()
        print('[telegraph] cast/ready bars: '
            .. (cfg.show_bars and 'ON' or 'OFF'))
    elseif args[2] == 'panel' then
        local now = os.clock()
        local live = castbar.bars(bars, now)

        print(('[telegraph] panel: visible=%s latched=%s zone=%s')
            :format(tostring(ui.visible[1]),
            tostring(state.latched_error), tostring(state.zone)))
        print(('[telegraph] panel: data spells=%s mobskills=%s '
            .. 'mob_index=%s'):format(
            tostring(data.spells ~= nil),
            tostring(data.mobskills ~= nil),
            tostring(mob_index ~= nil)))
        print(('[telegraph] panel: flow 0x028=%d dupes=%d fails=%d '
            .. 'bar_events=%d tp_mutations=%d'):format(
            state.seen_0x028, state.seen_dupes, state.parse_fails,
            state.bar_events, state.tp_mutations))
        print(('[telegraph] panel: live_bars=%d ledger_entries=%d '
            .. 'lines_rendered_last_frame=%s'):format(#live,
            ledger.count, tostring(ui.lines_rendered)))
        print(('[telegraph] panel: ids ledger=%s bars=%s ui=%s '
            .. 'ui.DRAW_VERSION=%s'):format(tostring(ledger),
            tostring(bars), tostring(ui), tostring(ui.DRAW_VERSION)))

        local target = current_target_id()

        if target then
            local est = tpledger.estimate(ledger, target, state.zone,
                now)
            print(('[telegraph] panel: target id=%s name=%s est=%s')
                :format(tostring(target),
                tostring(entity_name_by_id(target)),
                est and ('%d%%%s [%d-%d]'):format(est.percent,
                    est.marker, est.lo, est.hi) or 'none'))
        end
    else
        ui.visible[1] = not ui.visible[1]
    end
    end)
end)

-- =====================================================================
-- Load
-- =====================================================================

ashita.events.register('load', 'telegraph_load', function()
    data.spells = load_data('spells')
    data.mobskills = load_data('mobskills')

    -- mobs are OPTIONAL precision (TP feeds bound wider without them)
    local ok, index = pcall(require, 'mobs.index')

    if ok and type(index) == 'table' and index.zones then
        mob_index = index
        print(('[telegraph] split mob data: %d entries indexed')
            :format(index.total_entries or -1))
    end

    ui.version = addon.version

    -- Ashita settings library init: T{} defaults + full pcall (the
    -- Whetstone v0.1.6 first-load crash pattern)
    local ok_init, init_err = pcall(function()
        local lib = require('settings')

        assert(type(lib) == 'table' and lib.load, 'settings lib shape')

        local defaults = config.sanitize(nil)

        if type(T) == 'function' then
            defaults = T(defaults)
        end

        cfg = sanitize_in_place(lib.load(defaults))
        apply_config()

        lib.register('settings', 'telegraph_settings_update',
            function(loaded)
                pcall(function()
                    if loaded ~= nil then
                        cfg = sanitize_in_place(loaded)
                        apply_config()
                    end
                end)
            end)

        settings_lib = lib
    end)

    if not ok_init then
        settings_lib = nil
        print(('[telegraph] settings library init failed (%s) - '
            .. 'falling back to per-character file in the addon '
            .. 'folder'):format(tostring(init_err)))
    end
end)
