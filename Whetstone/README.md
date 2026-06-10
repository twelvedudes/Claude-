# Whetstone

Live melee damage advisor for 75-cap era FFXI private servers
(LandSandBoat-based, primarily [Phoenix](https://github.com/phoenixffxi/Phoenix)),
built as an Ashita v4 addon.

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
| `formulas.lua` | Pure Lua combat math, zero Ashita dependencies, server profiles | **done (Phase 1)** |
| `tests/test_formulas.lua` | Unit tests for every formula | **done (Phase 1)** |
| `tools/extract_mobs.py` | Phoenix SQL → generated Lua mob lookup (level range, VIT/AGI/DEF/EVA at min and max level) | **done (Phase 2)** |
| `tools/test_extract_mobs.py` | Unit tests for the extractor | **done (Phase 2)** |
| `player.lua` | Char stats incl. attack/defense from packet `0x061`, equipment from the Ashita inventory manager, active haste buffs from buff IDs | planned (Phase 3) |
| `advisor.lua` | Combines formulas + mob data + player state into recommendations | planned (Phase 3) |
| `ui.lua` | Compact ImGui panel | planned (Phase 4) |

## Ground truth

Primary: **Phoenix** (`phoenixffxi/Phoenix` @
[`0f3f8fc`](https://github.com/phoenixffxi/Phoenix/commit/0f3f8fcfcad5872874fd6050bb4befb543b2d1fa)).
Phoenix's core combat files are byte-identical to upstream LandSandBoat
(`LandSandBoat/server` @ `fdc2471`); its era behavior comes from modules
enabled in `modules/init.txt`:

- `modules/soa/lua/physical_hit_cap.lua` — melee hit ceiling reverted to
  a flat **95%** for every weapon class (undoes the Dec 2014 99% raise)
- `modules/wotg/lua/pdif_caps_revert.lua` — pDIF caps reverted to the
  pre-ToAU-2H-update values: **2.0 for every melee weapon**, 3.0 for
  archery/marksmanship/throwing

Formula sources:

- `scripts/globals/combat/physical_utilities.lua` — fSTR / fSTR2 (with
  weapon-rank stat windows and value caps), WSC, pDIF curves + spike +
  level correction, crit rate from dDEX
- `scripts/globals/combat/physical_hit_rate.lua` — hit rate
  (`75% + dACC/2`, 20% floor, ±4 acc/level correction)
- `scripts/globals/weaponskills.lua` — the WS pipeline: legacy alpha,
  `mainBase = floor(D + fSTR + WSC·alpha)`, fTP interpolation and
  first-hit-only fTP, +100 acc on the first hit, unfloored offhand base,
  TP-varying attack/crit mods, 8-swing cap
- `src/map/entities/battleentity.cpp` — `GetWeaponDelay` haste stacking
  (magic ≤ 43.75%, ability ≤ 25%, gear ≤ 25%, total capped by the server
  `DELAY_REDUCTION_CAP`, default 80%) and weapon rank (`floor(DMG/9)`,
  H2H +3)
- `src/map/utils/mobutils.cpp` — mob stat calculation (see Phase 2)

### Server profiles

`formulas.lua` exposes both rule sets as profiles; every function
accepts `profile = 'phoenix' | 'lsb' | <custom table>`:

| Knob | `phoenix` (default) | `lsb` |
| --- | --- | --- |
| Hit ceiling (1H main / H2H) | 0.95 | 0.99 |
| Hit ceiling (2H / offhand) | 0.95 | 0.95 |
| Melee pDIF caps | 2.0 (all) | 3.25–4.0 per weapon |
| Ranged pDIF caps | 3.0 | 3.25–3.5 |
| WSC alpha | legacy (0.83 @ 75) | 1.0 (Adoulin rules) |
| fSTR | fractional (LSB-ism) | fractional |
| Delay reduction cap | 80% | 80% |

Notes:

- **pDIF RNG model** (verified identical in Phoenix and upstream): one
  spike roll that returns exactly 1.0, a 50/50 coin flip for the upper
  bound's floor (0.5 or 0), then a **single uniform draw** between the
  bounds, times the 1.00–1.05 melee random factor. `melee_pdif().expected`
  is the exact closed-form mean of that process — it is *not* a
  max-of-two-uniforms model.
- **Fractional fSTR** is a genuine LSB/Phoenix behavior (no floor on the
  player value, so it moves in 0.25 steps). Strict-era forks compute
  integer fSTR — AirSkyBoat's `GetFSTR` uses C++ integer division
  (truncation toward zero, validated against `AirSkyBoat/AirSkyBoat`
  `battleutils.cpp`). Set `fstr_integer = true` in a custom profile for
  those servers.
- **Alpha caveat**: Phoenix's deployed `settings/main.lua` is not in
  their repo; the tracked default leaves Adoulin WS changes on, but
  their ToAU-era WS overrides and 75 cap imply the legacy alpha path.
  The `phoenix` profile assumes legacy; flip `legacy_alpha` if in-game
  parses say otherwise.
- AirSkyBoat itself uses a different (2013-model, C++-side) pDIF
  implementation and is **not** covered by these profiles — Phoenix is
  the target. The profile table makes adding such a model possible
  later without touching callers.

## Phase 2: mob database extractor

`tools/extract_mobs.py` parses a Phoenix checkout and replicates
`mobutils.cpp` `CalculateMobStats`:

- `stat = familyStat(speciesRank, lvl) + mainJobStat(grade, lvl) + subJobStat`,
  where the subjob contribution uses `GetSubJobStats` in original/RoZ
  zones below sub level 50 and a flat `/2` elsewhere (sub level = main
  level, the `INCLUDE_MOB_SJ` default)
- `DEF = max(1, 8 + VIT/2 + GetBaseDefEva(defRank, lvl) + traits + mods)`
- `EVA = max(1, GetBaseDefEva(bestEvasionSkillRank(mJob, sJob), lvl) + AGI/2 + traits + mods)`
- job traits (`traits.sql`, highest qualifying rank per trait across
  main+sub) and flat `mob_pool_mods` / `mob_species_mods` DEF/EVA
  overrides are included; `is_mob_mod` rows are ignored

Because stats derive from job + family + level, and every spawn has a
level *range* (`mob_spawn_points.minLevel/maxLevel` on Phoenix), the
extractor emits **stats at both the minimum and maximum level** of each
mob entry rather than a single value:

```lua
[103] = { -- Valkurm Dunes
    ['Damselfly'] = {
        { min_level = 22, max_level = 23, mjob = 'WAR', sjob = 'WAR',
          family = 'Fly', nm = false, group = 12,
          min = { vit = 22, agi = 26, def = 92, eva = 76 },
          max = { vit = 22, agi = 26, def = 95, eva = 79 } },
    },
},
```

Generate (full run takes ~3s, ~3 MB of Lua across 232 zones / ~11,400
entries; the generated file is not committed):

```sh
python3 Whetstone/tools/extract_mobs.py \
    --server /path/to/Phoenix \
    --out Whetstone/data/mobs.lua \
    --source-label "phoenixffxi/Phoenix @ <commit>"
```

Known simplifications: `MOB_STAT_MULTIPLIER`/`NM_STAT_MULTIPLIER`
assumed 1.0 (server defaults), spawn-script mods not applied, float
slopes evaluated in double precision.

## Phase 3 notes

Phoenix ships its complete pre-WotG weapon skill parameters in
`modules/wotg/lua/weaponskills/*.lua` (fTP tables, stat mods, hit
counts, crit/attack "varies with TP" tables, dated 2007-11-19) — that is
the WS database `advisor.lua` should be generated from, not upstream's
`scripts/actions/weaponskills/`.

## Running the tests

```sh
lua5.1 Whetstone/tests/test_formulas.lua       # or: busted Whetstone/tests/test_formulas.lua
python3 Whetstone/tools/test_extract_mobs.py
```

Every expected value in both suites is hand-derived from the server
source in a comment next to the assertion — the tests are not generated
from the implementations.
