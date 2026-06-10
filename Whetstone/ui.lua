--[[
    Whetstone - ui.lua

    Compact one-glance ImGui panel. Renders an advisor report: target
    line (with level range until narrowed), then the ranked delta
    lines - each one a change plus its expected gain. Estimated values
    are marked with '~'.

    Pure rendering: all numbers come from advisor.evaluate(). Needs an
    in-game shakedown pass like all Ashita glue.
]]

local M = {}

M.visible = { true }

local COLOR_GAIN      = { 0.55, 1.00, 0.55, 1.0 }
local COLOR_INFO      = { 0.70, 0.70, 0.70, 1.0 }
local COLOR_ESTIMATED = { 1.00, 0.85, 0.45, 1.0 }
local COLOR_HEADER    = { 0.95, 0.95, 1.00, 1.0 }

local MAX_LINES = 6

function M.draw(report, haste)
    if not M.visible[1] then
        return
    end

    imgui.SetNextWindowSize({ 360, 0 }, ImGuiCond_FirstUseEver)

    if not imgui.Begin('Whetstone', M.visible,
                       ImGuiWindowFlags_NoScrollbar) then
        imgui.End()
        return
    end

    if not report then
        imgui.TextColored(COLOR_INFO, 'No target.')
        imgui.End()
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

        imgui.TextColored(COLOR_HEADER, label)

        if target.ambiguous then
            imgui.SameLine()
            imgui.TextColored(COLOR_INFO, '[check to narrow]')
        end

        imgui.Separator()
    end

    if report.error then
        imgui.TextColored(COLOR_INFO, report.error)
        imgui.End()
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

        imgui.TextColored(color, prefix .. line.text)
    end

    -- Haste summary footer (gear exact, magic estimated)
    if haste then
        imgui.Separator()

        local text = string.format('Haste %.1f%%%s (gear %.2f%% exact)',
            haste.total * 100,
            haste.magic_estimated and ' ~est' or '',
            haste.gear * 100)

        imgui.TextColored(
            haste.magic_estimated and COLOR_ESTIMATED or COLOR_INFO, text)
    end

    imgui.End()
end

return M
