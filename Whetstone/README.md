# Whetstone

Live melee damage advisor for 75-cap era FFXI private servers
(LandSandBoat-based), built as an Ashita v4 addon.

Whetstone watches your character and your current target and answers the
questions a melee actually cares about:

- Is my accuracy capped against this mob? If not, how far off am I?
- Is any of my gear haste wasted past the 25% cap?
- How far am I from the next fSTR tier (STR points to the next bump)?
- How much attack/pDIF headroom do I have before more attack stops helping?
- Which of my weapon skills hits hardest right now, at my current TP?

## Architecture

| File | Role | Status |
| --- | --- | --- |
| `formulas.lua` | Pure Lua combat math, zero Ashita dependencies | **done (Phase 1)** |
| `tests/test_formulas.lua` | Unit tests for every formula | **done (Phase 1)** |
| `tools/extract_mobs.py` | Parses LSB SQL (`mob_groups`, `mob_pools`, `mob_family_system`) into a generated Lua lookup: zone ID + mob name → level range, VIT, AGI, DEF, EVA | planned (Phase 2) |
| `player.lua` | Char stats incl. attack/defense from packet `0x061`, equipment from the Ashita inventory manager, active haste buffs from buff IDs | planned (Phase 3) |
| `advisor.lua` | Combines formulas + mob data + player state into recommendations | planned (Phase 3) |
| `ui.lua` | Compact ImGui panel | planned (Phase 4) |

Phase rule: nothing above `formulas.lua` gets built until the math
passes tests.

## Ground truth

All formulas replicate the LandSandBoat server implementation at commit
[`fdc2471`](https://github.com/LandSandBoat/server/commit/fdc24716f825de6b96a3c4c9896cd1c7295c494f):

- `scripts/globals/combat/physical_utilities.lua` — fSTR / fSTR2 (with
  weapon-rank stat windows and value caps), WSC, pDIF caps + spike +
  level correction, crit rate from dDEX
- `scripts/globals/combat/physical_hit_rate.lua` — hit rate
  (`75% + dACC/2`, 20% floor, 99%/95% ceilings, ±4 acc/level correction)
- `scripts/globals/weaponskills.lua` — the WS pipeline: legacy alpha,
  `mainBase = floor(D + fSTR + WSC·alpha)`, fTP interpolation and
  first-hit-only fTP, +100 acc on the first hit, unfloored offhand base,
  TP-varying attack/crit mods, 8-swing cap
- `src/map/entities/battleentity.cpp` — `GetWeaponDelay` haste stacking
  (magic ≤ 43.75%, ability ≤ 25%, gear ≤ 25%, total capped by the server
  `DELAY_REDUCTION_CAP`, default 80%) and weapon rank (`floor(DMG/9)`,
  H2H +3)

Where the server rolls dice (pDIF uniform roll, 1.00–1.05 melee random,
the "spike" that returns exactly 1.0), `formulas.lua` returns the
distribution bounds and the exact closed-form expected value instead, so
the advisor can rank options deterministically.

Notes on era behavior as implemented by LSB (and therefore by Whetstone):

- Player fSTR is **not floored** — it moves in 0.25 steps inside a tier.
- WS crits only happen on weapon skills with a `critVaries` table.
- Hit rate ceiling is 99% for 1H mainhand / H2H and 95% for 2H,
  offhand and ranged; floor is 20%.
- The legacy WSC alpha is 0.83 at level 75.

## Running the tests

With plain Lua (5.1+ / LuaJIT):

```sh
lua5.1 Whetstone/tests/test_formulas.lua
```

Or with [busted](https://lunarmodules.github.io/busted/):

```sh
busted Whetstone/tests/test_formulas.lua
```

Every expected value in the suite is hand-derived from the LSB source in
a comment next to the assertion — the tests are not generated from the
implementation.
