--[[
    Whetstone - ui.lua

    Compact one-glance ImGui panel. Renders an advisor report: target
    line (with level range until narrowed), then the ranked delta
    lines - each one a change plus its expected gain. Estimated values
    are marked with '~'.

    Ashita v4 ImGui binding semantics (verified against the official
    AshitaXI/Ashita-v4beta addons - equipmon, imguistyle, tparty):
      - there is NO global `imgui`: require('imgui') is mandatory
        (HorizonXI shakedown crash, v0.1.0-beta)
      - by-ref arguments are Lua tables (M.visible = { true })
      - imgui.End() runs UNCONDITIONALLY after Begin, whatever Begin
        returned (canonical `if Begin(...) then ... end End()` shape)
      - ImGuiWindowFlags_* / ImGuiCond_* are globals provided by Ashita
      - sizes and colors are plain Lua tables

    Pure rendering: all numbers come from advisor.evaluate(). The
    binding is swappable (tests preload a recording stub).
]]

local imgui = require('imgui')

local M = {}

M.visible = { true }
M.version = nil -- set by whetstone.lua at load; shown in the title bar

-- Stamped into /whet panel output: if the field ever reports a state
-- string without its [S#] tag, an old ui.lua is running somewhere.
M.DRAW_VERSION = 'draw-v3-tagged'

local COLOR_GAIN      = { 0.55, 1.00, 0.55, 1.0 }
local COLOR_INFO      = { 0.70, 0.70, 0.70, 1.0 }
local COLOR_ESTIMATED = { 1.00, 0.85, 0.45, 1.0 }
local COLOR_HEADER    = { 0.95, 0.95, 1.00, 1.0 }
local COLOR_ERROR     = { 1.00, 0.35, 0.35, 1.0 }

local MAX_LINES = 6

-- FIELD BUG (v0.1.4): ImGui Text/TextColored are printf-style; the
-- advisor's lines are full of literal '%' ('+90.0% melee'), which
-- fired conversions live ('% p' -> pointer hex, '% e' -> 3.78e-244)
-- and is a crash waiting on '% s'. EVERY dynamic string goes through
-- the '%s' format slot; nothing user-influenced is ever a format
-- string. (tests/test_ui.lua greps this file to enforce it.)
local function text(color, value)
    imgui.TextColored(color, '%s', value)
end

-- Every snapshot failure mode renders DISTINCTLY, and every branch
-- carries a permanent [S#] tag so rendered text identifies its code
-- path forever (the v0.1.2 field bug rendered an untagged catch-all
-- that was indistinguishable from the v0.1.1 string).
--   [S1] waiting for char packets   [S2] no target
--   [S2z] no zone data              [S2w] weapon not in item DB
--   [S3] target not in mob DB       [S4] advisor output
--   [S?] catch-all (status missing entirely - transport bug)
local STATE_TEXT =
{
    waiting_packets = '[S1] Waiting for char data - change zones or '
        .. 'jobs once to trigger 0x061/0x062.',
    no_target       = '[S2] No target.',
}

-- Window body, only rendered when Begin() returned true.
local function draw_body(report, haste, status)
    status = status or {}

    -- A latched subsystem error outranks everything: stale-looking
    -- silence is how the last bug hid.
    if status.latched_error then
        text(COLOR_ERROR, string.format(
            'ERROR (latched): %s - see whetstone_error.log',
            status.latched_error))
    end

    if not report then
        if status.state == 'no_zone_data' then
            text(COLOR_INFO, string.format(
                '[S2z] No mob data for zone %s.',
                tostring(status.detail)))
        elseif status.state == 'no_weapon' then
            text(COLOR_INFO, string.format(
                '[S2w] Mainhand not in item DB (id %s).',
                tostring(status.detail)))
        elseif STATE_TEXT[status.state] then
            text(COLOR_INFO, STATE_TEXT[status.state])
        else
            -- Reaching here means draw received NO status at all:
            -- that is a transport bug upstream, and it must say so
            -- instead of impersonating the no-target state.
            text(COLOR_ERROR, string.format(
                '[S?] no status reached the panel (state=%s) - '
                .. 'report this line', tostring(status.state)))
        end

        return
    end

    -- Target header with range disambiguation
    local target = report.target

    if target then
        local label = target.name or '?'

        if target.pinned_level then
            label = string.format('%s (Lv.%d)', label, target.pinned_level)
        elseif target.level_min then
            if target.level_min == target.level_max then
                label = string.format('%s (Lv.%d)', label, target.level_min)
            else
                label = string.format('%s (Lv.%d-%d%s)', label,
                    target.level_min, target.level_max,
                    target.ambiguous and ', unconfirmed' or '')
            end
        end

        text(COLOR_HEADER, '[S4] ' .. label)

        if target.ambiguous then
            imgui.SameLine()
            text(COLOR_INFO, '[check to narrow]')
        end

        imgui.Separator()
    end

    if report.error then
        if report.error == 'unknown mob' then
            text(COLOR_INFO, string.format(
                '[S3] Target: %s (not in mob DB for this zone)',
                tostring(report.target and report.target.name or '?')))
        else
            text(COLOR_INFO, '[S3] ' .. report.error)
        end

        return
    end

    -- Ranked delta lines
    for index, line in ipairs(report.lines) do
        if index > MAX_LINES then
            break
        end

        local color = COLOR_INFO

        if line.delta and line.delta > 0 then
            color = line.estimated and COLOR_ESTIMATED or COLOR_GAIN
        end

        local prefix = line.estimated and '~ ' or '  '

        text(color, prefix .. line.text)
    end

    -- Haste summary footer (gear exact, magic estimated)
    if haste then
        imgui.Separator()

        local footer = string.format('Haste %.1f%%%s (gear %.2f%% exact)',
            haste.total * 100,
            haste.magic_estimated and ' ~est' or '',
            haste.gear * 100)

        text(haste.magic_estimated and COLOR_ESTIMATED or COLOR_INFO,
             footer)
    end
end

function M.draw(report, haste, status)
    if not M.visible[1] then
        return
    end

    imgui.SetNextWindowSize({ 360, 0 }, ImGuiCond_FirstUseEver)

    -- Version in the title bar so a stale build exposes itself on
    -- sight; '###Whetstone' keeps the window identity stable across
    -- version changes.
    local title = string.format('Whetstone %s###Whetstone',
        M.version or 'dev')

    -- Canonical Ashita v4 shape: End() runs regardless of Begin().
    if imgui.Begin(title, M.visible,
                   ImGuiWindowFlags_NoScrollbar) then
        draw_body(report, haste, status)
    end

    imgui.End()
end

return M
