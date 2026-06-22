-----------------------------------
-- SOULS - LOGIN
--
-- On game-in: seed new characters, re-apply owned unlocks (so they survive any
-- engine-side resets), and show the server's Dark Souls flavour MOTD + balance.
-----------------------------------
require('modules/module_utils')
require('scripts/globals/player')
-----------------------------------
local m = Module:new('souls_login')

m:addOverride('xi.player.onGameIn', function(player, firstLogin, zoning)
    super(player, firstLogin, zoning)

    -- Don't spam the MOTD on zone transfers - only on a real login.
    if zoning then
        return
    end

    xi.souls.seedIfNew(player)
    xi.souls.reapply(player)

    -- Slight delay so the messages land after the zone is fully populated,
    -- mirroring the announce_player_login example module.
    player:timer(2500, function(p)
        xi.souls.tell(p, '=== Vana\'diel: Ashen Era (Lv.' .. xi.souls.config.LEVEL_CAP .. ' cap) ===')
        xi.souls.tell(p, 'Every spell and ability can be unlocked by ANY job - for a price in souls.')
        xi.souls.tell(p, string.format('Souls: %d.  Type "@soul" for the shop.', xi.souls.getBalance(p)))

        local bsAmount, bsZone = xi.souls.getBloodstain(p)
        if bsAmount > 0 then
            if bsZone == p:getZoneID() then
                xi.souls.tell(p, string.format('A bloodstain holding %d souls lingers in this zone. "@soul recover".', bsAmount))
            else
                xi.souls.tell(p, string.format('You left a bloodstain with %d souls in another zone.', bsAmount))
            end
        end
    end)
end)

return m
