# Telegraph provenance manifest

Ground truth: **Phoenix** `phoenixffxi/Phoenix` @ `0f3f8fc` (audited
2026-06-11), the same pinned commit as Whetstone's manifest. Enabled
modules from `modules/init.txt` (see Whetstone/PROVENANCE.md for the
full module audit method; the sweeps below were re-run for the TP /
action-packet surface).

## Module audit (TP + action surface)

Sweeps over the enabled module paths for every symbol Telegraph
replicates (`calculateTPReturn`, `calculateTPGainOnPhysicalDamage`,
`getSingleMeleeHitTPReturn`, `getModifiedDelayAndCanZanshin`,
`castTime`, `mob_skills`, `REGAIN`, `STORETP`, `SUBTLE_BLOW`,
`addTP`, `health.tp`):

| Override | File | Effect |
| --- | --- | --- |
| `xi.combat.tp.calculateTPReturn` | `modules/soa/lua/tp_gain.lua` | **the era TP curve**: ONE piecewise function for every entity (the upstream PC/mob split is collapsed). This is the only TP-math override in the enabled module set. |

Enabled-module **SQL** touching consumed tables:

| File | Statements | Consumed-column impact |
| --- | --- | --- |
| `modules/soa/sql/magic_adjustments.sql` | 54 `UPDATE spell_list` | castTime/mpCost/recastTime — **castTime applied** by extract_spells.py |
| `modules/wotg/sql/job_adjustments.sql` | 7 `UPDATE spell_list` | castTime/mpCost/jobs — **castTime applied** |
| `modules/abyssea/sql/job_adjustments.sql` | 6 `UPDATE spell_list` | castTime — **applied** |
| `modules/rov/sql/job_adjustments.sql` | 1 `UPDATE spell_list` | jobs only — ignored (column not consumed) |
| `modules/abyssea/sql/era_spell_enmity.sql` | 198 `UPDATE spell_list` | CE/VE only — ignored (columns not consumed) |
| `modules/phoenix/sql/limbus/limbus_pools.sql` | 179 `INSERT mob_pools` | ingested by the (extended) mob extractor like every module insert |
| (none) | — | **no enabled module touches `mob_skills`** |

## 0x028 / 0x029 parsing (shared/actionpacket.lua)

| Datum | Ground truth |
| --- | --- |
| 0x028 bit layout (header 40 bits, then actor 32 / trg_sum 6 / res_sum 4 / cmd_no 4 / cmd_arg 32 / info 32; per result 85 bits + optional 37/35-bit blocks) | `src/map/packets/s2c/0x028_battle2.cpp` `pack()`; little-endian bit aggregate semantics from `src/common/utils.cpp` `packBitsBE`/`unpackBitsBE` (round-trip-tested against an independent packer) |
| Action categories (cmd_no) | `src/map/enums/action/category.h` `ActionCategory` — verified against every EMITTER below, not assumed from names |
| `BasicAttack` cmd_arg is FourCC `'atk0'`, only `MagicFinish` emits `recast` in info, per-category `kind` values | `src/map/action/action.cpp` `normalize()` |
| FourCC numeric values (cast/interrupt schedulers) | `src/map/enums/four_cc.h` (byte-swapped LE) |
| Casting start: `MagicStart`(8), cmd_arg = spell-GROUP cast FourCC (`'cawh'`…), **spell id in result.param**, message 3 (non-PC) / 327 (PC) | `src/map/ai/states/magic_state.cpp` `Cast()`; `CSpell::getFourCC` (`src/map/spell.cpp`) |
| Cast interrupt: a SECOND `MagicStart` whose cmd_arg is the group's interrupt FourCC (`'spwh'`…), spell id in param; the "casting is interrupted" line goes out on **0x029** (`MsgBasic::IsInterrupted = 16`) "despite the system supporting interrupted message in the action packet" | `src/map/entities/battleentity.cpp` `OnCastInterrupted`; `src/map/action/interrupts.cpp` `MagicInterrupt`/`MagicParalyzed`/`MagicIntimidated` |
| Magic finish: `MagicFinish`(4), cmd_arg = **spell id directly** (uint16) | `battleentity.cpp` `OnCastFinished` |
| TP-move readying: `SkillStart`(7), cmd_arg = `FourCC::SkillUse` `'cate'`, **mob skill id in result.param**, message `ReadiesWeaponskill`(43) — zeroed (packet still sent) under `SKILLFLAG_NO_START_MSG`(0x010); emitted ONLY when activation time > 0 | `src/map/ai/states/mobskill_state.cpp` (also `weaponskill_state.cpp` for player WS, same shape) |
| Readying interrupt: `SkillStart`(7) with cmd_arg = `FourCC::SkillInterrupt` `'spte'`, empty self-targeted result | `interrupts.cpp` `AbilityInterrupt`, called from `CMobSkillState::Cleanup` when not completed |
| Mob skill finish category: avatar pets → `PetSkillFinish`(13); **skill id < 256 → `SkillFinish`(3)** (the player-WS category — consumers disambiguate by actor); else `MobSkillFinish`(11); cmd_arg = skill id | `battleentity.cpp` `OnMobSkillFinished` |
| Mob skill failure paths after a readying (no target in range / out of range) resolve as `MagicFinish` with `SkillInterrupt` animation — a ready-bar clear signal, NOT a TP restore (the state completed; `reduceTpOnInterrupt` never runs) | `interrupts.cpp` `MobSkillNoTargetInRange`/`MobSkillOutOfRange`; completion flow in `mobskill_state.cpp` `Update`/`Cleanup` |
| Job abilities: category from `abilities.sql` `actionType` (default 6 `AbilityFinish`; Dancer 14 / RuneFencer 15 rows exist), cmd_arg = **raw ability id** | `battleentity.cpp` `OnAbility` (`action.actionid = PAbility->getID()`); `sql/abilities.sql` |
| Message ids (hit 1, magic dmg 2, cast-self 3, miss 15, interrupted 16, shadows 31, dodge 32, countered 33, readies 43, crit 67, skill dmg 185/188/189, burst 252, secondary 264, evade 282, cast-target 327) | `src/map/enums/msg_basic.h` |
| 0x029 battle message layout | `src/map/packets/s2c/0x029_battle_message.h` (shared with Whetstone player.lua, which now delegates here) |
| Death messages 6 (`DefeatsTarget`) / 20 (`FallsToGround`), target = the dying mob | `mobentity.cpp` `OnDeath` — ids recycle onto respawns, so death evicts every id-keyed cache |
| Duplicate-packet rejection (raw payload, 200 ms window) | Whetstone v0.1.7 field finding (re-injection with many addons loaded); state lives in the ONE shared module instance |

## TP estimator (tpledger.lua)

| tpledger.lua datum | Ground truth |
| --- | --- |
| TP-per-hit curve (`tp_return`, phoenix profile) | `modules/soa/lua/tp_gain.lua` (ENABLED) — verbatim piecewise: >530: 145+(d−530)·35/470; >480: 130+(d−480)·15/30; >450: 115+(d−450)·15/30; >180: 50+(d−180)·65/270; else 50+(d−180)·15/180; floored. The curve is **discontinuous at 530→531** (155 → 145); interval propagation samples the edge points explicitly |
| `lsb` profile dual curve (PC/pet branch) | `scripts/globals/combat/tp.lua` `calculateTPReturn` upstream |
| Delay modification (`modified_delay`) | `tp.lua` `getModifiedDelayAndCanZanshin`: dual wield `((delay·(100−DW))/100)/2`; mob H2H `max(delay/2, 48)` ("Mobs are not affected at all by Martial Arts"); PC H2H `(delay−MA)/2` floor 48 (single fist `−MA` floor 96); × `max((100+DELAYP)/100, 0.85)`, floored. **DELAYP is applied by the Lua even though `modifier.h` claims it "does not affect tp gain"** — the Lua is what runs |
| Attacker swing gain | `tp.lua` `getSingleMeleeHitTPReturn`: `floor(curve(modified) · (1 + STORETP/100))`; Meikyo zeroes (out of model for mobs); Zanshin/Ikishoten PC-only |
| Victim hit gain | `tp.lua` `calculateTPGainOnPhysicalDamage`: mob struck by non-mob `floor((base+30) · inhibit · dAGI · sb · storeTP)` (+30 cited to wiki.ffo.jp/html/2621.html in source); mob-vs-mob & non-mob victims `floor(base · inhibit · sb · storeTP · (1/3))` (NO dAGI term). Called from `battleutils.cpp` `TakePhysicalDamage` strictly inside `damage > 0` — **0-damage / miss / parry / shadow results feed nothing** |
| dAGI modifier replicated verbatim | `clamp(200 − (dAGI+30)/200, 0.5, 1)` — **structurally 1.0** for every achievable spread (dropping below 1 needs dAGI > 39770; the adjacent comment promises 50% at +70 but the expression does not deliver it). Replicated as-written; test pins it |
| Subtle Blow sign | `(100 − SB1 + SB2)/100`, SB1 capped 50, combined floor 0.25 — **SB2 as written RAISES the modifier**; era entities have no `SUBTLE_BLOW_II`(973). Replicated verbatim |
| Victim magic gain | `tp.lua` `calculateTPGainOnMagicalDamage` (mob 100-base / else 50-base), awarded by `battleutils.cpp` `CalculateMagicDamage` for `canTargetEnemy && damage > 0` — ledger feeds only on messages 2/252 (MagicDamage / MagicBurstDamage) |
| WS victim gain | `battleutils.cpp` `TakeWeaponskillDamage`: ONE `addTP(tpHitsLanded · targetTPMult · base)` — **extra DA/TA hits do NOT feed the victim** (`extraHitsLanded` rides bonusTP for the attacker only, `weaponskills.lua` `takeWeaponskillDamage`). The packet carries only the damage total, so landed-main-hit count is bounded `[1, numHits]` from the WS table |
| Counter TP | `battleentity.cpp` attack round counter branch: `TakePhysicalDamage(counterer, originalAttacker, …, giveTPtoVictim=true, giveTPtoAttacker=false, isCounter=true)` — message 33 on a MOB's action = the mob took counter damage and books VICTIM tp from the counterer's delay; the countering entity books nothing |
| `addTP` | `battleentity.cpp` `CBattleEntity::addTP`: positive gains lose gainer-side `INHIBIT_TP`% (int16 trunc), × `map.MOB_TP_MULTIPLIER` (int16 trunc), clamp [0, 3000]. Tracked default 1.0 (`settings/default/map.lua`); the **deployed** value is not client-readable — README caveat |
| Spend on skill use happens at **state ENTRY** (the readying), not the finish | `mobskill_state.cpp` `SpendCost()` called from `OnEnter`: `m_spentTP = health.tp; health.tp = 0` unless `SKILLFLAG_NO_TP_COST`(0x004, `isTpFreeSkill`). Sekkanoki/Meikyo branches (−1000 instead) are charm/SAM-mob edge cases, OUT OF MODEL (documented). Activation-0 skills never emit a readying — their spend lands on the finish packet |
| Readying ⇒ TP ≥ 1000 (calibration clamp) | `mobentity.cpp` `shouldUseTPMove`: hard `health.tp < 1000 → false`; controller threshold rolls 1000–3000 (`mob_controller.cpp`). **CAVEAT**: the `MOBMOD_SPECIAL_SKILL` path (`TrySpecialSkill`) bypasses the gate, and 2hr scripts can fire skills directly — a special-skill readying can over-clamp; the error self-corrects at the spend it also performs |
| Interrupt restore | `mobskill_state.cpp` `reduceTpOnInterrupt`: only when a prevent-action effect (stun class) interrupted — `floor(round(spent/3))` at ≥ 2900 else `floor(spent/4)`; other interrupt causes keep the spend (0). Cause is not client-readable: ledger bounds [0, restore(hi)] |
| Regain | `status_effect_container.cpp` `TickRegen`: `addTP(REGAIN − REGAIN_DOWN)`, ticked every 3 s (`zone_entities.cpp` `m_EffectCheckTime`), **mobs only while engaged** (`objtype != TYPE_MOB || IsEngaged()`). Mod 368 (`modifier.h`: value ×10 — 20 = 2% TP/tick) from mob mods |
| Idle TP decay | `mob_controller.cpp` `DoRoamTick` + `battleentity.cpp` `Rest(0.1)`: `addTP(−50)` every ≥ 10 s while unengaged and resting allowed — the stale-entity lo-decay rate |
| Mob auto-attack delay / H2H | `sql/mob_pools.sql` `cmbDelay` / `cmbSkill` (1 = hand_to_hand), loaded in `mobutils.cpp` (`setBaseDelay(cmbDelay)`, `setSkillType(cmbSkill)`); mob ranged base delay fixed at 300 (`mobutils.cpp:1071`) |
| TP-relevant mob mod ids (extractor whitelist) | `src/map/modifier.h`: STORETP 73, SUBTLE_BLOW 289, SUBTLE_BLOW_II 973, INHIBIT_TP 488, REGAIN 368 |
| Era TP percent display (1000 = 100%, cap 300%) | `health.tp` is 0–3000 server-side; the 75-era client displayed 0–300% — `estimate().percent = best/10` |

### Out of model (documented, deliberate)

- **Mob script TP writes** (`mob:setTP(...)`, gambits): per-mob zone
  scripts can move TP arbitrarily; the confidence model (bounds +
  staleness) absorbs the drift and the next readying re-calibrates.
- **Charm / mob-vs-mob feeds**: the 1/3 path is implemented and tested
  but `on_action` skips mob-actor→mob-target feeds (allegiance is not
  reliably client-readable).
- **TP-drain mob skills / additional-effect TP drain**: not modeled.
- **Additional-effect (enspell) and spike damage**: no TP in source
  (they never pass through `TakePhysicalDamage`).
- **Occult Acumen**: PC-only spell TP, irrelevant to mob entries.
- **Meikyo/Sekkanoki −1000 spends**: SAM-mob/charm edge cases.

## Cast/ready bars (castbar.lua)

| Datum | Ground truth |
| --- | --- |
| Spell cast time | `sql/spell_list.sql` `castTime` (milliseconds; `spell.cpp` loads with `std::chrono::milliseconds`), with enabled-module castTime UPDATEs applied (table above). Server-side modifiers (`battleutils.cpp` `CalculateSpellCastTime`: fast cast, SIRD gear, mob mods, Quick Magic procs) are NOT client-readable — the bar shows the table value and `/tele debug` logs observed vs table for the analyzer |
| Mob skill windup | `sql/mob_skills.sql` `mob_prepare_time` (milliseconds; `battleutils.cpp` `setActivationTime`). Zone scripts can override per-mob (`luautils::OnMobSkillReadyTime`) — same observed-vs-table treatment |
| Readying only emitted when windup > 0 | `mobskill_state.cpp`: `if (m_castTime > 0s)` guards the SkillStart push; instant skills jump to the finish |
| One bar per actor | the server AI runs one state per entity (`ai_container`); a second start replaces the live bar (outcome `replaced` in validation events) |
| Bar-clear signal set | the four source paths in the parsing table: interrupt FourCCs, finishes, the MagicFinish failure paths, death/zone |

## Extractors (Phase 2)

| Extractor | Ground truth | Module SQL handled | Pinned-commit run |
| --- | --- | --- | --- |
| `Telegraph/tools/extract_spells.py` | `sql/spell_list.sql` (spellid, name, castTime in **ms** — `spell.cpp` loads with `std::chrono::milliseconds`) | applies every castTime UPDATE from the enabled modules (60 applied: soa/magic_adjustments 47+, wotg, abyssea); 206 non-consumed-column updates ignored (CE/VE, jobs, mpCost-only); an applied-class update matching NO spell raises | 893 spells (the dump's other 35 `INSERT` lines are commented out — prefix counter skips comments, books balance) |
| `Telegraph/tools/extract_mobskills.py` | `sql/mob_skills.sql` (mob_skill_id, name, `mob_prepare_time` ms → `setActivationTime`, `mob_skill_flag` & 0x004 → `isTpFreeSkill`) — flag cells use `SET @SKILLFLAG_*` variables, resolved with a loud failure on unknown forms | no enabled module touches mob_skills (collection still runs; any future UPDATE on a consumed column raises) | 2,546 skills (2,071 with windup, 155 tp-free; 1,798 commented-out retail rows correctly excluded) |
| `Whetstone/tools/extract_mobs.py` (extended) | adds `mob_pools.cmbSkill/cmbDelay` (`mobutils.cpp` weapon setup) and TP mods 73/289/368/488/973 from `mob_pool_mods`/`mob_species_mods` (is_mob_mod = 0 rows only) to every entry | unchanged (dyna + limbus pool inserts flow through the same row parser) | 12,625 entries / 101,586 spawn rows accounted; 2,274 entries carry tp_mods |

Generated tables are vintage-stamped (`vintage = 'phoenixffxi/Phoenix
@ 0f3f8fc'`) and load in Lua 5.1; like Whetstone's they are gitignored
but REQUIRED at runtime (release zips bundle them).

## Phase status

| File | Role | Status |
| --- | --- | --- |
| `shared/actionpacket.lua` | THE 0x028/0x029 parser (both addons; one require path) | **done (Phase 1)** |
| `shared/tests/test_actionpacket.lua` | per-category round-trip fixtures vs an independent packer | **done (Phase 1)** |
| `Telegraph/tpledger.lua` | TP formulas (exact, cited) + interval ledger + action mapping | **done (Phase 1)** |
| `Telegraph/tests/test_tpledger.lua` | hand-derived formula transcript + ledger lifecycle | **done (Phase 1)** |
| `Telegraph/castbar.lua` | cast/windup bar state machine | **done (Phase 1)** |
| `Telegraph/tests/test_castbar.lua` | bar lifecycle, unknown-id hardening | **done (Phase 1)** |
| `Telegraph/tools/extract_spells.py` + tests | spell id → name/castTime (+ module updates) | **done (Phase 2)** |
| `Telegraph/tools/extract_mobskills.py` + tests | skill id → name/windup/tp_free | **done (Phase 2)** |
| Whetstone `tools/extract_mobs.py` extension | cmbDelay/cmbSkill + TP mob mods per entry | **done (Phase 2)** |
| `Telegraph/telegraph.lua` + ui/selftest/config | glue (pcall-latched), TextUnformatted UI, `/tele` | Phase 3 |
| `Telegraph/tools/analyze_telegraph.py` | TP_ESTIMATE / CAST_TIME verdicts | Phase 4 |
