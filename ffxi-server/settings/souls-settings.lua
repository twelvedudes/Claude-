-----------------------------------
-- "Ashen Era" settings overrides
--
-- These are the values to change in your LandSandBoat checkout to get the
-- vanilla, retail-like, level-75-cap, punishing experience. They are NOT a
-- drop-in file (LSB loads settings from settings/default/*.lua); they document
-- exactly which keys to edit and to what. setup.sh applies the level cap and
-- death settings automatically; the rest are optional flavour you can tune.
--
-- Apply by editing the matching keys in:
--     settings/default/main.lua
--     settings/default/map.lua
-----------------------------------

-- ===== settings/default/main.lua =====
main_overrides =
{
    -- Classic 75-era cap. Lowering MAX_LEVEL disables the higher Limit Break
    -- quests so 75 is the true ceiling.
    MAX_LEVEL          = 75,
    INITIAL_LEVEL_CAP  = 50,   -- players still cap at 50 until the G1/G2 limit quests, exactly like retail

    -- Keep it vanilla / retail-like: no boosted rates.
    EXP_RATE           = 1.000,
    GIL_RATE           = 1.000,

    -- Harsh start: retail-accurate trickle of starting gil, no free maps/warps.
    START_GIL          = 10,
    ALL_MAPS           = 0,
    UNLOCK_OUTPOST_WARPS = 0,

    -- Retail subjob/advanced-job gating (the Souls system is the ONLY shortcut
    -- across jobs; base job mechanics stay authentic).
    SUBJOB_QUEST_LEVEL = 18,
    ADVANCED_JOB_LEVEL = 30,
}

-- ===== settings/default/map.lua =====
map_overrides =
{
    -- Full EXP loss on death (0 = lose all de-levellable EXP). This is what
    -- makes the Souls bloodstain mechanic bite: you lose EXP here AND drop
    -- your souls on the floor.
    EXP_RETAIN     = 0,
    EXP_LOSS_RATE  = 1.0,
    EXP_LOSS_LEVEL = 31,    -- retail: no EXP loss below 31

    -- Vanilla combat pacing.
    EXP_RATE       = 1.0,
    CAPACITY_RATE  = 1.0,
    FAME_MULTIPLIER = 1.00,
}
