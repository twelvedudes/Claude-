-----------------------------------
-- SOULS - EARN
--
-- Awards souls to the killer (and participating party members) on every mob
-- death, scaled by the mob's level.  Uses the global mob-death hook that fires
-- once per eligible party member: xi.mob.onMobDeathEx.
-----------------------------------
require('modules/module_utils')
require('scripts/globals/mobs')
-----------------------------------
local m = Module:new('souls_earn')

m:addOverride('xi.mob.onMobDeathEx', function(mob, player, isKiller, isWeaponSkillKill)
    super(mob, player, isKiller, isWeaponSkillKill)

    -- Only living players get souls.  Pets / trusts / fellows are skipped because
    -- the hook hands us the owning player for those cases anyway.
    if player == nil then
        return
    end

    local cfg    = xi.souls.config
    local level  = mob:getMainLvl()
    local amount = math.floor(level * cfg.PER_LEVEL) + cfg.FLAT

    if mob:isNM() then
        amount = amount * cfg.NM_MULTIPLIER
    end

    if amount <= 0 then
        return
    end

    xi.souls.add(player, amount)
    xi.souls.tell(player, string.format('+%d souls  (balance: %d)', amount, xi.souls.getBalance(player)))
end)

return m
