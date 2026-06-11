--[[
    Telegraph - castbar.lua

    Cast-bar / TP-move-windup state machine: one bar per actor,
    driven by classified 0x028 actions (shared/actionpacket.lua).
    Pure display of received data - the bar NEVER guesses:

      cast bars   spell name + cast time come from the generated
                  spell table (sql/spell_list.sql castTime, ms, plus
                  enabled-module UPDATEs - soa/magic_adjustments.sql
                  etc.). An id missing from the table shows
                  "casting (id N)" with no duration - never a crash,
                  never a made-up number. Server-side cast time mods
                  (fast cast, Slow) are NOT client-readable: the bar
                  shows the table time and the debug log records
                  observed vs table for the analyzer to judge.
      ready bars  mob TP-move name + windup from the generated mob
                  skill table (sql/mob_skills.sql mob_prepare_time,
                  ms). The server only emits a readying when the
                  windup is > 0 (mobskill_state.cpp: activation 0
                  skills go straight to the finish packet).

    Clear semantics (each from the emitting source path):
      - MagicStart + interrupt FourCC   cast interrupted
        (interrupts.cpp MagicInterrupt; the 0x029 "casting is
        interrupted" line is informational - the FourCC is the signal)
      - MagicFinish from the actor      cast completed; ALSO clears a
        ready bar - the mob skill no-target / out-of-range failure
        paths emit MagicFinish with the SkillInterrupt animation
        (interrupts.cpp MobSkillNoTargetInRange/MobSkillOutOfRange)
      - SkillStart + SkillInterrupt     readying interrupted
        (interrupts.cpp AbilityInterrupt via CMobSkillState::Cleanup)
      - SkillFinish/MobSkillFinish/PetSkillFinish/AbilityFinish
                                        skill resolved
      - death (0x029, glue) / zone      bars dropped
      - the server's AI runs ONE state per entity: a new start
        replaces any live bar (outcome 'replaced' for the validator)

    on_action returns completion events carrying expected vs observed
    timing - the addon generates its own validation data (phase 4
    feeds them to telegraph_bars.log / analyze_telegraph.py).

    Zero Ashita dependencies; unit-tested offline
    (tests/test_castbar.lua). telegraph.lua owns glue and rendering.
]]

local M = {}

-- Policy knobs (estimator/display policy, not server truth)
M.POLICY =
{
    -- a bar past its duration shows as overrun this long, then drops
    -- (a finish we never saw: out of range, packet loss)
    overrun_drop_s = 3,

    -- duration-less bars (unknown ids) drop after this long
    unknown_ttl_s = 30,

    -- bounded actor table (sweep oldest beyond the cap)
    max_actors = 64,
}

function M.new()
    return
    {
        by_actor = {}, -- [actor_id] = bar
        count = 0,
    }
end

local function valid_id(actor_id)
    return type(actor_id) == 'number' and actor_id > 0
end

local function drop(s, actor_id)
    if s.by_actor[actor_id] then
        s.by_actor[actor_id] = nil
        s.count = s.count - 1
    end
end

local function sweep_oldest(s)
    if s.count <= M.POLICY.max_actors then
        return
    end

    local oldest_id, oldest_t

    for id, bar in pairs(s.by_actor) do
        if not oldest_t or bar.started_at < oldest_t then
            oldest_id, oldest_t = id, bar.started_at
        end
    end

    if oldest_id then
        drop(s, oldest_id)
    end
end

-- Close the actor's live bar (if any) and produce the validation
-- event: outcome 'finish' | 'interrupt' | 'replaced'.
local function close(s, actor_id, outcome, now)
    local bar = s.by_actor[actor_id]

    if not bar then
        return nil
    end

    drop(s, actor_id)

    return
    {
        actor      = actor_id,
        kind       = bar.kind,
        id         = bar.id,
        label      = bar.label,
        expected_s = bar.duration_s,
        observed_s = now - bar.started_at,
        outcome    = outcome,
    }
end

local function open(s, actor_id, bar, now)
    local events = {}

    local replaced = close(s, actor_id, 'replaced', now)

    if replaced then
        events[#events + 1] = replaced
    end

    bar.started_at = now
    s.by_actor[actor_id] = bar
    s.count = s.count + 1
    sweep_oldest(s)

    return events
end

-- Map one parsed action onto the bar table. ctx:
--   ctx.spell_info(id)    -> { name, cast_ms } or nil
--   ctx.mobskill_info(id) -> { name, windup_ms } or nil
--   ctx.classify          optional classifier override (tests);
--                         defaults to the shared parser's
-- Returns an array of completion events (possibly empty).
function M.on_action(s, action, ctx, now)
    if not action or not valid_id(action.actor) then
        return {}
    end

    local classify = ctx.classify

    if not classify then
        local ok, actionpacket = pcall(require, 'actionpacket')

        if not ok then
            return {}
        end

        classify = actionpacket.classify
        ctx.classify = classify
    end

    local kind, ref_id = classify(action)

    if not kind then
        return {}
    end

    local actor = action.actor

    if kind == 'cast_start' then
        local info = ref_id and ctx.spell_info
            and ctx.spell_info(ref_id) or nil

        -- unknown spell id: show it, never crash, never invent a time
        local label = (info and info.name)
            or ('casting (id ' .. tostring(ref_id) .. ')')

        return open(s, actor,
        {
            kind       = 'cast',
            id         = ref_id,
            label      = label,
            duration_s = info and info.cast_ms
                and info.cast_ms / 1000 or nil,
        }, now)
    end

    if kind == 'ready_start' then
        local info = ref_id and ctx.mobskill_info
            and ctx.mobskill_info(ref_id) or nil

        local label = (info and info.name)
            or ('skill (id ' .. tostring(ref_id) .. ')')

        return open(s, actor,
        {
            kind       = 'ready',
            id         = ref_id,
            label      = label,
            duration_s = info and info.windup_ms
                and info.windup_ms / 1000 or nil,
        }, now)
    end

    if kind == 'cast_interrupt' or kind == 'ready_interrupt' then
        local event = close(s, actor, 'interrupt', now)

        return event and { event } or {}
    end

    if kind == 'magic_finish' or kind == 'ws_finish'
        or kind == 'mobskill_finish' or kind == 'petskill_finish'
        or kind == 'ja_finish' then
        local event = close(s, actor, 'finish', now)

        return event and { event } or {}
    end

    return {}
end

-- Death (0x029 DEATH_MESSAGES target) / despawn: the actor's bar is
-- meaningless and its id is about to recycle.
function M.on_death(s, actor_id)
    drop(s, actor_id)
end

function M.on_zone_change(s)
    s.by_actor = {}
    s.count = 0
end

-- Render view: live bars sorted by remaining time (soonest first;
-- duration-less bars last by age). Prunes expired bars as a side
-- effect (overrun past POLICY.overrun_drop_s; unknown-duration bars
-- past POLICY.unknown_ttl_s).
function M.bars(s, now)
    local out = {}
    local expired = {}

    for actor_id, bar in pairs(s.by_actor) do
        local elapsed = now - bar.started_at

        if bar.duration_s then
            local remaining = bar.duration_s - elapsed

            if remaining < -M.POLICY.overrun_drop_s then
                expired[#expired + 1] = actor_id
            else
                out[#out + 1] =
                {
                    actor      = actor_id,
                    kind       = bar.kind,
                    id         = bar.id,
                    label      = bar.label,
                    duration_s = bar.duration_s,
                    remaining_s = remaining > 0 and remaining or 0,
                    fraction   = remaining > 0
                        and remaining / bar.duration_s or 0,
                    overrun    = remaining <= 0,
                    started_at = bar.started_at,
                }
            end
        else
            if elapsed > M.POLICY.unknown_ttl_s then
                expired[#expired + 1] = actor_id
            else
                out[#out + 1] =
                {
                    actor      = actor_id,
                    kind       = bar.kind,
                    id         = bar.id,
                    label      = bar.label,
                    duration_s = nil,
                    remaining_s = nil,
                    fraction   = nil,
                    overrun    = false,
                    started_at = bar.started_at,
                }
            end
        end
    end

    for _, actor_id in ipairs(expired) do
        drop(s, actor_id)
    end

    table.sort(out, function(a, b)
        if a.remaining_s and b.remaining_s then
            if a.remaining_s ~= b.remaining_s then
                return a.remaining_s < b.remaining_s
            end

            return a.actor < b.actor
        end

        if a.remaining_s then
            return true
        end

        if b.remaining_s then
            return false
        end

        if a.started_at ~= b.started_at then
            return a.started_at < b.started_at
        end

        return a.actor < b.actor
    end)

    return out
end

-- Structural assertion mirroring narrow.lua/tpledger: actor-id keys
-- only, no auxiliary lookup structures.
function M.assert_id_keyed(s)
    for key in pairs(s.by_actor) do
        if type(key) ~= 'number' then
            error('castbar key is not a server id: ' .. tostring(key))
        end
    end

    for field in pairs(s) do
        if field ~= 'by_actor' and field ~= 'count' then
            error('unexpected castbar state field: ' .. tostring(field))
        end
    end

    return true
end

return M
