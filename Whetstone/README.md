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
| `tools/extract_mobs.py` | Phoenix SQL → mob lookup (VIT/AGI/DEF/EVA, exact row per level in each spawn range) | **done (Phase 2/5)** |
| `tools/extract_ws.py` | Phoenix WS scripts/era modules → weapon skill database | **done (Phase 3)** |
| `tools/extract_items.py` | Phoenix item SQL → equipment database (exact gear haste, att/acc/stats, weapon D/delay/skill) | **done (Phase 3)** |
| `tools/test_extract_*.py` | Unit tests for each extractor | **done** |
| `player.lua` | Char stats (`0x061`), combat skills (`0x062`), equipment via Ashita inventory, haste from buff IDs + item DB | **done (Phase 3/5)** |
| `tests/test_player.lua` | Unit tests for the pure parts of player.lua | **done (Phase 3)** |
| `tests/test_ui.lua` | ImGui binding contract tests (require, End pairing, hidden) | **done (v0.1.1)** |
| `advisor.lua` | Ranked actionable deltas from formulas + generated data + player state | **done (Phase 4)** |
| `tests/test_advisor.lua` | Routing guard, disambiguation, ranking, WS gating tests | **done (Phase 4/5)** |
| `ui.lua` | One-glance ImGui panel (renders advisor output) | **done; v4 binding verified vs official addons + stub-tested** |
| `swinglog.lua` | `/whet debug` predicted-vs-observed logging (0x028 action parser) | **done (Phase 5, needs in-game shakedown)** |
| `whetstone.lua` | Ashita v4 bootstrap (`/whet`, `level`, `march`, `quest`, `profile`, `debug`, `target`, `selftest`) | **shaking down in the field (v0.1.x)** |
| `config.lua` | Persisted user state: defaults, type-checked sanitize, sandboxed (de)serializer; Ashita settings lib backend wired in whetstone.lua | **done (v0.1.6)** |
| `tests/test_config.lua` | Save/load round-trip, sanitize hardening, sandbox safety | **done (v0.1.6)** |
| `PROVENANCE.md` | Function-by-function ground-truth manifest + full enabled-module audit | **done** |

> **Release packaging:** the generated tables (`data/mobs.lua`,
> `data/weaponskills.lua`, `data/items.lua`) are **gitignored for
> development but REQUIRED at runtime** — a release zip must bundle
> them. Run the three extractor commands below against the pinned
> Phoenix commit and ship the `data/` directory inside the addon
> folder. Do not ship the formula engine without its data.

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
extractor emits **an exact stat row for every level in the range** -
the stat function is exact and cheap, so nothing downstream ever
approximates between rows:

```lua
[103] = { -- Valkurm Dunes
    ['Damselfly'] = {
        { min_level = 22, max_level = 23, mjob = 'WAR', sjob = 'WAR',
          family = 'Fly', nm = false, group = 12,
          levels = {
              [22] = { vit = 22, agi = 26, def = 92, eva = 76 },
              [23] = { vit = 22, agi = 26, def = 95, eva = 79 },
          } },
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

## Phase 3: WS database, item database, player state

### Weapon skill extractor

`tools/extract_ws.py` builds the WS database from the server's own
dated era parameters, in priority order:

1. `modules/wotg/lua/weaponskills/*.lua` — Phoenix's pre-WotG
   (2007-11-19) overrides (158 weapon skills)
2. `scripts/actions/weaponskills/*.lua` — upstream baseline for the
   rest (50), taking only unconditional assignments, which excludes the
   `USE_ADOULIN_WEAPON_SKILL_CHANGES` blocks automatically
3. `sql/weapon_skills.sql` — WS id, weapon type, required skill level,
   skillchain properties, job availability

Params (`numHits`, `ftpMod`, `str_wsc`, `atkVaries`, `critVaries`, ...)
are emitted verbatim from the server scripts; MP-drain style specials
get `kind = 'special'`. Spot-verified transcripts: era Sturmwind is
`str_wsc 0.3, atkVaries { 1.00, 1.25, 1.50 }`; era Asuran Fists is
8 hits at `0.1/0.1` with `accVaries` — Phoenix's numbers, not wiki's.

### Item extractor

`tools/extract_items.py` joins `item_equipment` + `item_weapon` +
`item_mods` into one equipment table: level, job/slot masks, weapon
D/delay/skill, and a whitelisted mod set — **exact gear haste**
(Mod 384, 10000-based: Swift Belt = 400 = 4%), att/acc/stats, DA/TA,
Store TP, Dual Wield, Martial Arts. This is what makes "gear haste
overcap" and "swap ring for attack" advice exact rather than guessed.
Full Phoenix run: 15,398 items (5,129 weapons, 2,153 with gear haste).
Phoenix's `pxi_item_basic.sql` era module only touches flags, so the
base tables are authoritative for stats. `--all-mods` dumps everything
for debugging.

### player.lua and the haste precision model

`player.lua` keeps a strict split between what is known and what is
guessed:

- **Gear haste is exact**: equipped item IDs join against the item DB.
- **Magic haste is estimated only where the source says so**: the
  magnitudes were audited in Phoenix's own spell scripts. Haste is
  14.65% (power cap 1465/10000 in `enhancing_spell.lua`) - exact at
  capped enhancing skill, the 75-era norm. Elegy powers are fixed in
  source (Battlefield 25%, Carnage 50%) but share one effect ID, so
  the buff stays estimated with a Carnage default. March
  (skill+instrument) and Slow (dMND/Hojo tiers) are genuinely
  caster-dependent. Overrides
  (`haste_from_buffs(buffs, { [214] = 0.140625 })`) clear the flag.
- **Ability haste**: Hasso is exactly 10% (fixed in the enabled
  abyssea module); Haste Samba and Desperate-Blows Last Resort are
  estimated.

Everything except the small Ashita glue block (`attach`, packet event +
inventory/buff reads) is pure Lua and unit-tested: packet `0x061`
parsing (layout from Phoenix `0x061_clistatus.h`, including signed
stat bonuses), buff classification, gear aggregation, and the
`haste_report` integration with `formulas.haste`.

## Generating the data tables

```sh
python3 Whetstone/tools/extract_mobs.py  --server /path/to/Phoenix \
    --out Whetstone/data/mobs --split     --source-label "phoenixffxi/Phoenix @ <commit>"
python3 Whetstone/tools/extract_ws.py    --server /path/to/Phoenix \
    --out Whetstone/data/weaponskills.lua --source-label "phoenixffxi/Phoenix @ <commit>"
python3 Whetstone/tools/extract_items.py --server /path/to/Phoenix \
    --out Whetstone/data/items.lua        --source-label "phoenixffxi/Phoenix @ <commit>"
```

All three are fast (seconds) and the outputs load in Lua 5.1. Remember:
**these files ship in the release zip** even though they are gitignored.

## Cleanup phase (v0.1.6)

- **Persistent user state** (`config.lua`): level pins (per mob name —
  a pin is knowledge about the mob, so it re-applies on retarget),
  March override, quest toggle, formulas profile, panel visibility and
  position all survive `/addon reload` and relog, per character, via
  the Ashita settings library (file fallback in the addon folder).
  Loading is sanitized (type-checked merge over defaults) and
  deserialization is sandboxed — a corrupt or malicious settings file
  can neither poison runtime state nor execute code. `/whet profile
  phoenix|lsb` switches the formulas profile live.
- **WS multi-attack procs**: weapon skill swings roll Double/Triple
  Attack exactly like `weaponskills.lua getMultiAttacks` (exclusive
  TA-then-DA chain, max 2 proc events, 8-swing cap), as an expectation
  `E[extras] = ta*2 + (1-ta)*da` per swing. Trait DA/TA (WAR 10%@25,
  THF 5%@55, sub job at sub level — from `traits.sql`, era rows only)
  combine with exact gear mods 288/302 from the item DB and feed both
  the Best-WS ranking and the `/whet debug` WS predictions.
- **Magic/hybrid WS are never ranked wrong**: pure magic WS
  (`doMagicWeaponskill`) and HYBRID WS (physical dispatch with
  `ele`/`includemab`/`hybridWS` params — Tachi: Jinpu/Kagero, Red
  Lotus Blade class) are excluded from the damage ranking and listed
  with a `(magic - out of model)` / `(hybrid - out of model)` tag
  instead of a misleading number.
- **Conditional/latent mods surfaced**: `item_latents.sql` (1,977
  conditional rows) is ingested under conservation accounting; items
  whose latents touch model-relevant mods are flagged in the item DB
  and the `/whet debug` session header WARNS for each equipped
  latent-bearing piece. Madrigal (199) and Hunter's Roll (320) joined
  the food warning: accuracy the model cannot see taints hit-rate
  verdicts, and the header now says so.

## Phase 6: pre-beta hardening

- **Crit rate model completed**: the C++ auto-attack path
  (`GetCritHitRate`/`GetDexCritBonus`) was verified tier-identical to
  the Lua WS path already implemented; the one divergence - melee
  clamps to [0%, 100%] while WS clamps to [5%, 100%] - is modeled via
  `crit_rate{ kind = 'melee' | 'ws' }`. `crit_info` reports DEX
  distance to the next dDEX tier and the advisor emits a ranked
  `+N DEX -> +1% crit` line when a tier is reachable (suppressed at
  the +15% cap). Module sweep found no crit overrides.
- **32-bit memory**: `extract_mobs.py --split` writes one file per
  zone plus `data/mobs/index.lua`; the addon loads only the current
  zone's table on demand and unloads the previous one
  (`package.loaded` clear + `collectgarbage`), logging the Lua heap
  before/after in debug mode. Conservation balances ACROSS the split:
  per-zone sums are asserted against extraction accounting at
  generation time, and a deliberate row-loss test proves the check
  fires.
- **Experiment tooling**: `/whet debug` now opens with a full
  session-state header (stats, parsed skills + capped flags, per-piece
  gear haste, buff classification with warnings for food and any
  unaccounted effect IDs, target pin state); swing lines carry
  `base=`/`spike=` so pDIF is reconstructable per swing;
  `--singletons-out` lists exact-stat validation targets (minLevel ==
  maxLevel mobs in the starting zones - 145 on Phoenix); and
  `tools/analyze_swings.py` turns a log into per-checklist verdicts
  (HIT_CEILING with Wilson 95% CI separating the 95-vs-99 question,
  PDIF_BOUNDS, SPIKE frequency, WS_MEAN with an explicit
  Adoulin-alpha-pattern detector) - each PASS / FAIL /
  INSUFFICIENT_DATA with swing counts.
- **Release**: `tools/package_release.py` builds
  `whetstone-v<ver>-beta.zip` (addon + all generated tables +
  regeneration instructions) and REFUSES to package without the data
  tables. `/whet selftest` exercises every Ashita glue call
  (inventory slots, item id resolution, target/party/buffs, packet
  state, data tables, zone mob load) and writes
  `whetstone_selftest.log` so shakedown failures name the exact call.

## Phase 5: real accuracy, WS gating, swing logging

- **Real base accuracy from packet `0x062`** (skill_base[64] at offset
  0x80, 0x8000 = capped flag). The advisor's flagship "acc to cap"
  number is derived from the player's ACTUAL combat skill through the
  server's `GetAccFromSkill` curve + DEX x 0.75 + gear - an
  assumed-capped skill would be maximally wrong at launch, when
  everyone levels with lagging skill. The panel waits for 0x062 rather
  than guess.
- **WS availability gating**: only weapon skills the player can use
  are ranked - matching weapon, job list, and the module-corrected
  `skilllevel` threshold against the REAL parsed skill. Quest-locked
  WS (`unlock_id > 0`; the 240-skill quests like Decimation) are
  excluded by default because quest flags are not client-readable;
  `/whet quest` toggles them on for players who have them.
- **`/whet debug` swing logging** (`swinglog.lua`): parses 0x028
  action packets (bit reader round-trip-tested against an independent
  packer replicating the server's `packBitsBE`) and appends
  predicted-vs-observed lines per melee swing / WS to
  `whetstone_swings.log` for offline validation.

## Phase 4: advisor and panel

`advisor.lua` emits **ranked actionable deltas** - each line a concrete
change plus its expected gain, sorted largest first; informational
state ("pDIF capped - trade att for acc") sorts last:

```
+90 acc to cap vs Lv.25 (50% -> 95%, +90.0% melee)
+1 STR -> fSTR 13.75 (+0.4% per swing)
+88 att to pDIF cap vs DEF 300 (+1.1% per 10 att)
Best WS @1000 TP: heavy_strike (~412) - 28% over true_strike
```

Design points:

- **atkVaries/fTP routing guard**: the WS database is a verbatim
  transcript, and `adapt_ws_params` routes each param down the same
  path `weaponskills.lua` does - `ftpMod` to the damage multiplier,
  `atkVaries` to the pDIF attack input, never merged. A regression
  test computes the same WS both ways and asserts the wiki-blurred
  version differs.
- **Mob disambiguation**: same-name spawns with different level rows
  are evaluated as a candidate SET; every metric uses the worst-case
  point and is flagged (`~`) until something narrows it. `/whet level
  <n>` (checker/widescan) pins the level and reads the EXACT generated
  stat row for that level - no interpolation anywhere.
- Lines marked `~` depend on an estimate (unnarrowed level range or
  estimated magic haste); exact lines are unmarked.

## Conservation checks

All three extractors structurally prevent silent row loss:

- INSERT statements are counted by **prefix only**, independent of the
  full-line parser; any mismatch raises `ConservationError`.
- Every driving-table row is emitted or explicitly skip-counted, and
  the books must balance (e.g. the full mob run accounts for all
  101,586 spawn rows).
- Enabled module SQL (`modules/init.txt`) is ingested: Dynamis spawns
  (4,924 rows) come from `dyna_spawn.sql`, era weapon-skill SQL
  updates are applied, and any module UPDATE touching a consumed
  column that the extractor cannot apply fails the build.

## Beta validation plan

Hard rule: **any non-Phoenix server validates plumbing only** -
packets parse, inventory and target APIs behave, lookups hit, the
panel renders. It never validates math: custom servers run custom
formulas, and "the numbers looked right on server X" is evidence about
server X. The four math questions below are settled exclusively on
Phoenix, where one `/whet debug` parse session covers all of them.

Checklist (compare `whetstone_swings.log` against predictions):

1. **Legacy alpha** - WS damage at fixed TP vs a known mob: predicted
   `mainBase` uses alpha 0.83 @75. If observed WS averages run ~+10%
   hot on WSC-heavy skills, the server has Adoulin WS changes on ->
   flip `legacy_alpha` in the phoenix profile.
2. **E[pDIF] distribution** - a few hundred melee swings vs one
   pinned-level target: observed damage/base should fill
   `pdif_range` (the logged lower-upper bounds x 1.00-1.05) with a
   ~1/3 spike at exactly 1.0 x base near wRatio 1, and the mean should
   match `predicted_mean` within sampling error.
3. **Haste pin** - cast Haste only, count swing timestamps: delay
   multiplier should match 1 - 0.1465 exactly (capped-skill caster).
   A 15.00% server would show up over a long enough sample.
4. **95% cap** - acc-capped vs a trivially low-evasion mob: miss rate
   converges to 5% (never ~1%, which would mean the 99% cap is live
   and the soa module is off).

Also verify during plumbing shakedown: the DEX-to-accuracy multiplier
(`dex_acc_multiplier` 0.75 vs the pre-ToAU 0.5 - Phoenix's deployed
setting is not in their repo) by comparing the equip-screen accuracy
against `formulas.player_accuracy` for the same gear.

## Running the tests

```sh
lua5.1 Whetstone/tests/test_formulas.lua       # or: busted ...
lua5.1 Whetstone/tests/test_player.lua
lua5.1 Whetstone/tests/test_advisor.lua
lua5.1 Whetstone/tests/test_swinglog.lua
lua5.1 Whetstone/tests/test_selftest.lua
lua5.1 Whetstone/tests/test_ui.lua
python3 Whetstone/tools/test_extract_mobs.py
python3 Whetstone/tools/test_extract_ws.py
python3 Whetstone/tools/test_extract_items.py
python3 Whetstone/tools/test_analyze_swings.py
python3 Whetstone/tools/test_package_release.py
```

Every expected value in these suites is hand-derived from the server
source in a comment next to the assertion — the tests are not generated
from the implementations.
