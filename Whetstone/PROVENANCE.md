# Whetstone provenance manifest

Ground truth: **Phoenix** `phoenixffxi/Phoenix` @ `0f3f8fc` (audited 2026-06-10).
Upstream reference: `LandSandBoat/server` @ `fdc2471` (Phoenix's combat
files are byte-identical; era behavior comes from enabled modules).

## Audit method

The full enabled-module list was taken from `modules/init.txt`:
`phoenix/sql`, `phoenix/dynamis/sql`, `custom/commands/`, three named
`custom/lua` files, `rov/`, `soa/`, `abyssea/`, `wotg/`, `phoenix/cpp`,
`phoenix/lua`, `phoenix/dynamis/cpp`, `phoenix/dynamis/lua`.

Three sweeps over exactly those paths:

1. **Every `addOverride` target** was listed and reviewed (≈100 entries:
   weapon skills, job abilities, effects, zone hooks).
2. **Direct namespace writes** were grepped by symbol
   (`pDifWeaponCapTable`, `physicalHitRate`, `calculateMeleePDIF`,
   `calculateMeleeStatFactor`, `wRatioCap`, `getSpikeRatio`,
   `calculateWSC`, `calculateTPfactor`, `calculateSwingCriticalRate`,
   `GetWeaponDelay`, `DELAY_REDUCTION`).
3. **Module SQL** was swept for statements touching every table the
   extractors consume; the extractors now ingest enabled module SQL
   themselves and fail loudly (`ConservationError`) on anything they
   cannot represent.

## Result: combat-math overrides in enabled modules

Exactly **two** Lua overrides touch the math formulas.lua replicates:

| Override | File | Effect |
| --- | --- | --- |
| `xi.combat.physicalHitRate.getPhysicalHitRateCap` | `modules/soa/lua/physical_hit_cap.lua` | flat 0.95 ceiling |
| `xi.combat.physical.pDifWeaponCapTable[...]` (direct writes) | `modules/wotg/lua/pdif_caps_revert.lua` | melee caps 2.0, ranged 3.0 |

Adjacent but out of the damage model (documented, not modeled):

| Override | File | Note |
| --- | --- | --- |
| `xi.combat.tp.calculateTPReturn` | `modules/soa/lua/tp_gain.lua` | era TP-per-hit curve — relevant if TP feed ever enters the advisor |
| `xi.effects.hasso.onEffectGain` | `modules/abyssea/lua/job_adjustments.lua` | fixes Hasso at exactly 10% 2H haste (used by player.lua) |
| `xi.job_utils.dark_knight.useLastResort` + LR effect | `modules/soa/lua/job_adjustments.lua` | era Last Resort: +15% ATTP, 2H haste = Desperate Blows merits (player.lua, estimated) |

## Function-by-function manifest

| formulas.lua | Ground truth | Module override? |
| --- | --- | --- |
| `weapon_rank` | `src/map/entities/battleentity.cpp` `GetMainWeaponRank`/`GetSubWeaponRank` | none |
| `fstr`, `fstr_ranged`, `fstr_value_caps`, `fstr_stat_diff_caps`, `fstr_info` | `scripts/globals/combat/physical_utilities.lua` `calculateMeleeStatFactor`/`calculateRangedStatFactor` | none (fractional fSTR confirmed live on Phoenix) |
| `fstr_mob` | same file, mob branch | none |
| `hit_rate`, `acc_for_cap` | `scripts/globals/combat/physical_hit_rate.lua` | **cap via `soa/physical_hit_cap.lua`** (phoenix profile) |
| `hit_rate_cap` | `getPhysicalHitRateCap` | **overridden: flat 0.95** |
| `haste`, `weapon_delay_ms` | `src/map/entities/battleentity.cpp` `GetWeaponDelay`; `settings/default/main.lua` `DELAY_REDUCTION_CAP` | none |
| `melee_pdif`, `wratio_caps_pc`, `spike_chance_pc`, `attack_for_pdif_cap` | `physical_utilities.lua` `calculateMeleePDIF`/`wRatioCapPC`/`getSpikeRatio` | **caps via `wotg/pdif_caps_revert.lua`** (phoenix profile) |
| `alpha` | `scripts/globals/weaponskills.lua` `calculateRawWSDmg` (legacy branch) | none — but see alpha caveat in README (deployed `USE_ADOULIN_WEAPON_SKILL_CHANGES` not in repo) |
| `ftp`, `tp_factor` | `weaponskills.lua` `fTP`; `physical_utilities.lua` `calculateTPfactor` | none |
| `wsc` | `physical_utilities.lua` `calculateWSC` | none |
| `crit_rate` (kind='ws', 5% floor), `crit_rate_from_dex`, `crit_info` | `physical_utilities.lua` `calculateSwingCriticalRate`/`criticalRateFromStatDiff` | none |
| `crit_rate` (kind='melee', 0 floor) | `battleutils.cpp` `GetCritHitRate`/`GetDexCritBonus` — dDEX tier curve verified IDENTICAL to the Lua WS path (0-6 +0, 7-13 +1, 14-19 +2, 20-29 +3, 30-39 +4, 40-50 dDEX−35, cap +15); only the clamp floor differs (C++ [0,100] vs Lua [5,100]) | none (swept; rov's crit hit is a WS `critVaries` param, handled by the WS extractor) |
| `ws_damage` | `weaponskills.lua` `doPhysicalWeaponskill`/`calculateRawWSDmg`/`getSingleHitDamage` | WS *parameters* via `modules/wotg/lua/weaponskills/*` (extracted, not formula changes) |
| `melee_swing` | composition of the above | — |

| player.lua datum | Ground truth |
| --- | --- |
| packet 0x061 layout | `src/map/packets/s2c/0x061_clistatus.h` |
| packet 0x062 layout (skills @0x80, 0x8000 capped flag) | `src/map/packets/s2c/0x062_clistatus2.h/.cpp` |
| `formulas.acc_from_skill` / `player_accuracy` | `battleentity.cpp` `GetAccFromSkill` / `ACC()` player branch; DEX multiplier 0.75 from `settings/default/main.lua` (deployed value unverified - beta checklist) |
| 0x028 action packet bit layout (swinglog.lua) | `src/map/packets/s2c/0x028_battle2.cpp` `pack()`; `unpackBitsBE` little-endian aggregate semantics from `src/common/utils.cpp` |
| Haste 14.65% | `scripts/globals/spells/enhancing_spell.lua` (power cap 1465/10000) — exact at capped skill |
| Hasso 10% | `modules/abyssea/lua/job_adjustments.lua` (enabled) — exact |
| Elegy −25%/−50% | `scripts/globals/spells/enfeebling_song.lua` (fixed 2500/5000; effect ID ambiguous → estimated, default Carnage) |
| Slow | dMND-scaled (white magic) / fixed Hojo tiers sharing effect 13 → estimated |
| March | skill+instrument dependent (`enhancing_song.lua`) → estimated, user-overridable |
| Last Resort 2H haste | `modules/soa/lua/job_adjustments.lua` — merit-dependent → estimated |
| Gear crit mods (advisor `crit_rate_bonus`/`crit_dmg_bonus`) | `item_mods.sql` Mod 165 `CRITHITRATE` + Mod 421 `CRIT_DMG_INCREASE` (whitelisted, exact via item DB) — out of model: Mod 964 `RANGED_CRIT_DMG_INCREASE`, Mod 563 `MAGIC_CRIT_DMG_INCREASE` (no ranged/magic crit damage in the advisor), Mod 908 `CRIT_DEF_BONUS` (mob-side; nets against crit_dmg in `melee_pdif` if ever supplied) |

| Extractor | Ground truth | Module SQL handled |
| --- | --- | --- |
| `extract_mobs.py` | `src/map/utils/mobutils.cpp`, `grades.cpp`, `battleentity.cpp` DEF()/EVA() | **ingests** `phoenix/dynamis/sql/dyna_spawn.sql` (4,924 spawns, 45 groups, 15 pools); applies `traits`/`skill_ranks` UPDATEs row-wise (`rov`/`soa` job adjustments, `pre_2014_skill_ranks`); ignores spawntype-only `mob_groups` UPDATEs (columns not consumed) |
| `extract_ws.py` | `scripts/actions/weaponskills/*`, `modules/wotg/lua/weaponskills/*`, `sql/weapon_skills.sql` | applies `wotg/tier_one_weapon_skills.sql` (tier-1 skilllevel 10) and `soa/weaponskills.sql` (ranged WS range) — 35 updates |
| `extract_items.py` | `sql/item_equipment.sql`, `item_weapon.sql`, `item_mods.sql` | applies `abyssea/job_adjustments.sql` item_equipment level fixes (6); `pxi_item_basic.sql` touches only `item_basic` flags (table not consumed) |

## Conservation guarantees

Every extractor now:

- counts INSERT statements by **prefix only** (independent of the
  full-line parser) and fails on any mismatch — the bug class that
  silently dropped 230 rows is structurally impossible;
- accounts every driving-table row as emitted or explicitly skipped
  (with a reason), and fails on imbalance;
- refuses (`ConservationError`) any module UPDATE that touches a
  consumed column unless it knows how to apply it.

Re-run this audit whenever Phoenix moves its pinned commit; the
extractors will fail loudly on new module SQL forms, but new *Lua*
combat overrides require re-running sweeps 1–2 above.
