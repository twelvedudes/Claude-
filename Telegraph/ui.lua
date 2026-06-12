--[[
    Telegraph - ui.lua

    Cast/ready bars + TP estimate panel. Pure rendering of a report
    the glue prepares; zero data logic here.

    Ashita v4 ImGui binding discipline inherited from Whetstone's
    field bugs (ui.lua v0.1.1-v0.1.7):
      - require('imgui'); no global
      - by-ref args are Lua tables (M.visible = { true })
      - End() runs UNCONDITIONALLY after Begin
      - the ONLY text call is TextUnformatted (Text/TextColored
        format-interpret their single string argument: '% p' renders
        pointer hex, '%s' renders literally) - color via
        PushStyleColor/PopStyleColor. tests/test_ui.lua greps this
        file to keep it that way.
      - bars are TEXT ([######....]) - no new binding surface to
        shake down

    Report shape (built by telegraph.lua each frame):
      bars = { { kind = 'cast'|'ready', actor_name, label,
                 remaining_s?, duration_s?, fraction?, overrun } }
      tp   = { { name, percent, lo_percent, hi_percent, marker,
                 pending, confidence } }
    status = { state = 'ok'|'waiting_data'|'idle', detail?,
               latched_error? }
]]

local imgui = require('imgui')

local M = {}

M.visible = { true }
M.version = nil -- set by telegraph.lua at load; shown in the title bar

M.window_pos = nil
local pending_pos = nil

function M.restore_window_pos(pos)
    if pos and pos.x and pos.x >= 0 then
        pending_pos = { pos.x, pos.y }
    end
end

-- Stamped into /tele panel output: a state string without its [T#]
-- tag means an old ui.lua is running somewhere.
M.DRAW_VERSION = 'tele-draw-v1-unformatted'

-- Text lines emitted by the LAST completed draw (the Whetstone
-- 'all-green dump + empty panel' lesson: /tele panel prints this).
M.lines_rendered = 0

local COLOR_CAST    = { 0.55, 0.80, 1.00, 1.0 }
local COLOR_READY   = { 1.00, 0.55, 0.40, 1.0 }
local COLOR_OVERRUN = { 0.75, 0.75, 0.75, 1.0 }
local COLOR_INFO    = { 0.70, 0.70, 0.70, 1.0 }
local COLOR_TP_HOT  = { 1.00, 0.45, 0.45, 1.0 }
local COLOR_TP      = { 0.80, 0.95, 0.60, 1.0 }
local COLOR_STALE   = { 0.85, 0.85, 0.55, 1.0 }
local COLOR_ERROR   = { 1.00, 0.35, 0.35, 1.0 }

M.BAR_WIDTH = 14
M.MAX_BARS = 6
M.MAX_TP_LINES = 6

local lines_this_frame = 0

local function text(color, value)
    imgui.PushStyleColor(ImGuiCol_Text, color)
    imgui.TextUnformatted(tostring(value))
    imgui.PopStyleColor(1)
    lines_this_frame = lines_this_frame + 1
end

-- Pure text bar: fraction 0..1 -> '[####......]'; nil fraction ->
-- '[??????????]' (unknown duration). Exposed for offline tests.
function M.bar_text(fraction, width)
    width = width or M.BAR_WIDTH

    if fraction == nil then
        return '[' .. string.rep('?', width) .. ']'
    end

    if fraction < 0 then fraction = 0 end
    if fraction > 1 then fraction = 1 end

    local filled = math.floor(fraction * width + 0.5)

    return '[' .. string.rep('#', filled)
        .. string.rep('.', width - filled) .. ']'
end

-- Pure line builders (offline-tested; draw only colors them)
function M.bar_line(bar)
    local time_part = ''

    if bar.remaining_s then
        time_part = string.format(' %.1fs', bar.remaining_s)
    end

    if bar.overrun then
        time_part = ' ...' -- past the table duration, finish unseen
    end

    if bar.kind == 'ready' then
        return string.format('%s READYING: %s %s%s',
            bar.actor_name or '?', bar.label,
            M.bar_text(bar.fraction), time_part)
    end

    return string.format('%s: casting %s %s%s',
        bar.actor_name or '?', bar.label,
        M.bar_text(bar.fraction), time_part)
end

function M.tp_line(entry)
    -- 'Mob Name TP ~74% [40-110%]' - the marker is the confidence
    -- flag (never an unflagged guess); the band shows when it is
    -- wider than the point
    local band = ''

    if entry.lo_percent and entry.hi_percent
        and entry.hi_percent > entry.lo_percent then
        band = string.format(' [%d-%d%%]', entry.lo_percent,
            entry.hi_percent)
    end

    local pending = entry.pending and ' (readying!)' or ''

    return string.format('%s TP %s%d%%%s%s', entry.name or '?',
        entry.marker or '~~', entry.percent or 0, band, pending)
end

local STATE_TEXT =
{
    waiting_data = '[T1] Data tables missing - run the extractors '
        .. '(see README).',
    idle         = '[T2] No tracked casts, windups or TP yet.',
}

local function draw_body(report, status)
    status = status or {}

    if status.latched_error then
        text(COLOR_ERROR, string.format(
            'ERROR (latched): %s - see telegraph_error.log',
            status.latched_error))
    end

    if not report or ((not report.bars or #report.bars == 0)
        and (not report.tp or #report.tp == 0)) then
        if STATE_TEXT[status.state] then
            text(COLOR_INFO, STATE_TEXT[status.state])
        elseif status.state == 'ok' then
            text(COLOR_INFO, '[T2] No tracked casts, windups or TP yet.')
        else
            text(COLOR_ERROR, string.format(
                '[T?] no status reached the panel (state=%s) - '
                .. 'report this line', tostring(status.state)))
        end

        return
    end

    for index, bar in ipairs(report.bars or {}) do
        if index > M.MAX_BARS then
            break
        end

        local color = COLOR_CAST

        if bar.overrun then
            color = COLOR_OVERRUN
        elseif bar.kind == 'ready' then
            color = COLOR_READY
        end

        text(color, M.bar_line(bar))
    end

    if report.tp and #report.tp > 0 then
        if report.bars and #report.bars > 0 then
            imgui.Separator()
        end

        for index, entry in ipairs(report.tp) do
            if index > M.MAX_TP_LINES then
                break
            end

            local color = COLOR_TP

            if entry.confidence == 'stale' then
                color = COLOR_STALE
            elseif (entry.percent or 0) >= 100 then
                color = COLOR_TP_HOT
            end

            text(color, M.tp_line(entry))
        end
    end
end

function M.draw(report, status)
    if not M.visible[1] then
        M.lines_rendered = 0
        return
    end

    lines_this_frame = 0

    imgui.SetNextWindowSize({ 380, 0 }, ImGuiCond_FirstUseEver)

    if pending_pos then
        imgui.SetNextWindowPos(pending_pos, ImGuiCond_Always)
        pending_pos = nil
    end

    -- Version in the title bar so a stale build exposes itself;
    -- '###Telegraph' keeps the window identity stable across versions.
    local title = string.format('Telegraph %s###Telegraph',
        M.version or 'dev')

    if imgui.Begin(title, M.visible, ImGuiWindowFlags_NoScrollbar) then
        draw_body(report, status)
    end

    local x, y = imgui.GetWindowPos()

    if type(x) == 'number' and type(y) == 'number' then
        M.window_pos = { x = x, y = y }
    end

    imgui.End()

    M.lines_rendered = lines_this_frame
end

return M
