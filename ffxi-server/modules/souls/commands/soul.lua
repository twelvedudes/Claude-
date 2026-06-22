-----------------------------------
-- func: soul
-- desc: Player-facing Souls shop & wallet.
--
--   @soul                 show balance + bloodstain status
--   @soul list            list everything you can unlock (and the price)
--   @soul buy <key>       spend souls to permanently unlock something
--   @soul recover         reclaim your bloodstain (must be in the death zone)
--   @soul help            show this help
--
-- Lives under a `commands/` folder so LandSandBoat registers it as the in-game
-- text command `@soul`.  permission = 0 makes it available to all players.
-----------------------------------
require('modules/module_utils')

---@type TCommand
local commandObj = {}

commandObj.cmdprops =
{
    permission = 0,
    parameters = 'ss',
}

local function help(player)
    xi.souls.tell(player, 'Souls shop:')
    xi.souls.tell(player, '  @soul            - your balance & bloodstain')
    xi.souls.tell(player, '  @soul list       - what you can unlock')
    xi.souls.tell(player, '  @soul buy <key>  - unlock something')
    xi.souls.tell(player, '  @soul recover    - reclaim your bloodstain (same zone)')
end

local function showBalance(player)
    xi.souls.tell(player, string.format('Souls: %d', xi.souls.getBalance(player)))

    local bsAmount, bsZone = xi.souls.getBloodstain(player)
    if bsAmount > 0 then
        if bsZone == player:getZoneID() then
            xi.souls.tell(player, string.format('Bloodstain here: %d souls. "@soul recover" to reclaim.', bsAmount))
        else
            xi.souls.tell(player, string.format('Bloodstain elsewhere: %d souls (zone %d).', bsAmount, bsZone))
        end
    end
end

local function listCatalog(player)
    xi.souls.tell(player, 'Unlocks (key = price):')
    -- Sort keys so the list is stable/readable.
    local keys = {}
    for key in pairs(xi.souls.catalog) do
        keys[#keys + 1] = key
    end
    table.sort(keys)

    for _, key in ipairs(keys) do
        local entry = xi.souls.catalog[key]
        local owned = xi.souls.hasUnlock(player, entry) and '  [OWNED]' or ''
        xi.souls.tell(player, string.format('  %-15s %6d  %s%s', key, entry.cost, entry.name, owned))
    end
end

local function buy(player, key)
    if key == nil then
        xi.souls.tell(player, 'Usage: @soul buy <key>   (see "@soul list")')
        return
    end

    key = string.lower(key)
    local entry = xi.souls.catalog[key]
    if entry == nil then
        xi.souls.tell(player, string.format('No such unlock "%s". Try "@soul list".', key))
        return
    end

    if xi.souls.hasUnlock(player, entry) then
        xi.souls.tell(player, string.format('You already own %s.', entry.name))
        return
    end

    if not xi.souls.spend(player, entry.cost) then
        xi.souls.tell(player, string.format('Not enough souls for %s (need %d, have %d).',
            entry.name, entry.cost, xi.souls.getBalance(player)))
        return
    end

    xi.souls.grant(player, entry)
    xi.souls.tell(player, string.format('Unlocked %s! Remaining souls: %d.', entry.name, xi.souls.getBalance(player)))
end

local function recover(player)
    local bsAmount, bsZone = xi.souls.getBloodstain(player)
    if bsAmount <= 0 then
        xi.souls.tell(player, 'You have no bloodstain to recover.')
        return
    end

    if bsZone ~= player:getZoneID() then
        xi.souls.tell(player, string.format('Your bloodstain is in another zone (%d). Travel there first.', bsZone))
        return
    end

    xi.souls.add(player, bsAmount)
    xi.souls.clearBloodstain(player)
    xi.souls.tell(player, string.format('Recovered %d souls. Balance: %d.', bsAmount, xi.souls.getBalance(player)))
end

commandObj.onTrigger = function(player, sub, arg)
    sub = sub and string.lower(sub) or 'balance'

    if sub == 'balance' or sub == '' then
        showBalance(player)
    elseif sub == 'list' then
        listCatalog(player)
    elseif sub == 'buy' then
        buy(player, arg)
    elseif sub == 'recover' then
        recover(player)
    else
        help(player)
    end
end

return commandObj
