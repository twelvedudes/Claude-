-----------------------------------
-- SOULS CORE
--
-- Dark Souls-style progression layer for LandSandBoat (level-75 era).
--
-- This file defines the global `xi.souls` namespace used by every other Souls
-- module (earn / death-penalty / login / the @soul command). It owns:
--   * the Souls currency (a per-character charvar)
--   * the "bloodstain" death-drop bookkeeping
--   * the catalog of purchasable cross-job unlocks and their prices
--   * the helper API the other modules call
--
-- DESIGN NOTES
--   Souls are stored in the charvar  [SOULS]Balance.
--   Each purchased unlock is recorded as a charvar  [SOULS]U:<type>:<id> = 1
--   so unlocks survive relogs and are the single source of truth.
--
--   "type" is one of: 'spell' | 'ability'
--     spell   -> granted with player:addSpell(id, { silentLog = true })
--     ability -> granted with player:addLearnedAbility(id)
--
--   See ffxi-server/README.md -> "Deep cross-job enablement" for the (optional)
--   SQL/C++ touch-ups needed if you want a job to actually CAST a spell that is
--   normally off its job list. The Lua layer below grants ownership and tracks
--   the economy; the engine's per-job cast/use gate is a separate switch.
-----------------------------------
require('modules/module_utils')
require('scripts/globals/magic')
require('scripts/globals/abilities')
-----------------------------------
local m = Module:new('souls_core')

-- Build the namespace if it does not exist yet.
xi = xi or {}
xi.souls = xi.souls or {}

-----------------------------------
-- Tunables.  Edit these to taste; lower income / higher costs = more punishing.
-----------------------------------
xi.souls.config =
{
    -- Earning (see souls_earn.lua): souls per kill = floor(mobLevel * PER_LEVEL) + FLAT,
    -- multiplied by NM_MULTIPLIER for notorious monsters.
    PER_LEVEL          = 0.6,
    FLAT               = 1,
    NM_MULTIPLIER      = 8,

    -- Death (see souls_death_penalty.lua).
    -- On death you drop your entire balance into a bloodstain at the death spot.
    -- Recover it with `@soul recover` in the same zone before you die again -
    -- dying again while a bloodstain is out destroys the old one (classic Souls).
    DROP_ON_DEATH      = true,

    -- Hard level cap reminder shown at login (cosmetic; real cap is MAX_LEVEL=75
    -- set in settings/main.lua - see ffxi-server/settings/souls-settings.lua).
    LEVEL_CAP          = 75,

    -- Free starter souls granted once, the first time a character logs in.
    STARTER_SOULS      = 0,
}

-----------------------------------
-- Charvar keys.
-----------------------------------
local VAR_BALANCE   = '[SOULS]Balance'
local VAR_SEEDED    = '[SOULS]Seeded'
local VAR_BS_AMOUNT = '[SOULS]BS:amount'
local VAR_BS_ZONE   = '[SOULS]BS:zone'

local function unlockVar(unlockType, id)
    return string.format('[SOULS]U:%s:%d', unlockType, id)
end

-----------------------------------
-- Catalog of purchasable unlocks.
--
-- key   : the short token a player types, e.g.  @soul buy utsusemi_ichi
-- type  : 'spell' | 'ability'
-- id    : engine id (xi.magic.spell.* or xi.ja.*)
-- cost  : price in souls
-- name  : display label
--
-- This is a curated, iconic cross-job starter set.  Add as many rows as you
-- like - it is plain data.  Prices are deliberately steep for a punishing feel.
-----------------------------------
xi.souls.catalog =
{
    -- White / support magic
    cure          = { type = 'spell',   id = xi.magic.spell.CURE,          cost = 150,  name = 'Cure' },
    cure_ii       = { type = 'spell',   id = xi.magic.spell.CURE_II,       cost = 600,  name = 'Cure II' },
    raise         = { type = 'spell',   id = xi.magic.spell.RAISE,         cost = 2500, name = 'Raise' },
    protect       = { type = 'spell',   id = xi.magic.spell.PROTECT,       cost = 300,  name = 'Protect' },
    dia           = { type = 'spell',   id = xi.magic.spell.DIA,           cost = 120,  name = 'Dia' },

    -- Black / elemental magic
    fire          = { type = 'spell',   id = xi.magic.spell.FIRE,          cost = 200,  name = 'Fire' },
    stoneskin     = { type = 'spell',   id = xi.magic.spell.STONESKIN,     cost = 1200, name = 'Stoneskin' },
    blaze_spikes  = { type = 'spell',   id = xi.magic.spell.BLAZE_SPIKES,  cost = 800,  name = 'Blaze Spikes' },

    -- Utility / ninjutsu
    utsusemi_ichi = { type = 'spell',   id = xi.magic.spell.UTSUSEMI_ICHI, cost = 1500, name = 'Utsusemi: Ichi' },
    sneak         = { type = 'spell',   id = xi.magic.spell.SNEAK,         cost = 250,  name = 'Sneak' },
    invisible     = { type = 'spell',   id = xi.magic.spell.INVISIBLE,     cost = 250,  name = 'Invisible' },

    -- Job abilities (cross-job)
    provoke       = { type = 'ability', id = xi.ja.PROVOKE,                cost = 400,  name = 'Provoke' },
    berserk       = { type = 'ability', id = xi.ja.BERSERK,                cost = 700,  name = 'Berserk' },
    warcry        = { type = 'ability', id = xi.ja.WARCRY,                 cost = 700,  name = 'Warcry' },
    mighty_strikes= { type = 'ability', id = xi.ja.MIGHTY_STRIKES,         cost = 4000, name = 'Mighty Strikes' },
    hundred_fists = { type = 'ability', id = xi.ja.HUNDRED_FISTS,          cost = 4000, name = 'Hundred Fists' },
    chainspell    = { type = 'ability', id = xi.ja.CHAINSPELL,             cost = 4000, name = 'Chainspell' },
}

-----------------------------------
-- Currency API
-----------------------------------
function xi.souls.getBalance(player)
    return player:getCharVar(VAR_BALANCE)
end

function xi.souls.setBalance(player, amount)
    player:setCharVar(VAR_BALANCE, math.max(0, math.floor(amount)))
end

function xi.souls.add(player, amount)
    amount = math.floor(amount)
    if amount <= 0 then
        return
    end

    xi.souls.setBalance(player, xi.souls.getBalance(player) + amount)
end

-- Returns true if the spend succeeded (player had enough).
function xi.souls.spend(player, amount)
    local balance = xi.souls.getBalance(player)
    if balance < amount then
        return false
    end

    xi.souls.setBalance(player, balance - amount)
    return true
end

-----------------------------------
-- Unlock API
-----------------------------------
function xi.souls.hasUnlock(player, entry)
    return player:getCharVar(unlockVar(entry.type, entry.id)) == 1
end

-- Grants the unlock to the player and records it.  Idempotent.
function xi.souls.grant(player, entry)
    player:setCharVar(unlockVar(entry.type, entry.id), 1)

    if entry.type == 'spell' then
        if not player:hasSpell(entry.id) then
            player:addSpell(entry.id, { silentLog = true })
        end
    elseif entry.type == 'ability' then
        if not player:hasLearnedAbility(entry.id) then
            player:addLearnedAbility(entry.id)
        end
    end
end

-- Re-apply every owned unlock (used at login so unlocks persist across wipes
-- of the engine's per-job learned lists).
function xi.souls.reapply(player)
    for _, entry in pairs(xi.souls.catalog) do
        if xi.souls.hasUnlock(player, entry) then
            xi.souls.grant(player, entry)
        end
    end
end

-----------------------------------
-- Bloodstain API (death drop / recover)
-----------------------------------
function xi.souls.dropBloodstain(player, amount)
    player:setCharVar(VAR_BS_AMOUNT, math.floor(amount))
    player:setCharVar(VAR_BS_ZONE, player:getZoneID())
end

function xi.souls.getBloodstain(player)
    return player:getCharVar(VAR_BS_AMOUNT), player:getCharVar(VAR_BS_ZONE)
end

function xi.souls.clearBloodstain(player)
    player:setCharVar(VAR_BS_AMOUNT, 0)
    player:setCharVar(VAR_BS_ZONE, 0)
end

-----------------------------------
-- Login bookkeeping
-----------------------------------
function xi.souls.seedIfNew(player)
    if player:getCharVar(VAR_SEEDED) == 0 then
        player:setCharVar(VAR_SEEDED, 1)
        if xi.souls.config.STARTER_SOULS > 0 then
            xi.souls.add(player, xi.souls.config.STARTER_SOULS)
        end
    end
end

-----------------------------------
-- Messaging helper used by every Souls module for a consistent voice.
-----------------------------------
function xi.souls.tell(player, text)
    player:printToPlayer(text, xi.msg.channel.SYSTEM_3, 'Souls')
end

return m
