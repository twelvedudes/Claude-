-----------------------------------
-- SOULS - DEATH PENALTY (Bloodstain)
--
-- Dark Souls rule: when you die you drop ALL carried souls into a bloodstain at
-- the spot you fell.  Return to that zone and `@soul recover` to reclaim them.
-- Die again before recovering and the old bloodstain is lost forever.
--
-- This stacks on top of the harsh vanilla EXP_RETAIN = 0 (full EXP loss) set in
-- ffxi-server/settings/souls-settings.lua, so death is genuinely punishing.
-----------------------------------
require('modules/module_utils')
require('scripts/globals/player')
-----------------------------------
local m = Module:new('souls_death_penalty')

m:addOverride('xi.player.onPlayerDeath', function(player)
    super(player)

    if not xi.souls.config.DROP_ON_DEATH then
        return
    end

    local carried = xi.souls.getBalance(player)
    if carried <= 0 then
        -- Dying with nothing carried still destroys any stale bloodstain.
        xi.souls.clearBloodstain(player)
        return
    end

    -- Dropping a new bloodstain overwrites (destroys) the previous one.
    xi.souls.dropBloodstain(player, carried)
    xi.souls.setBalance(player, 0)

    xi.souls.tell(player, string.format(
        'You died and dropped %d souls. Return to this zone and use "@soul recover".',
        carried))
end)

return m
