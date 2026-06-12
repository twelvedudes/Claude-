# Telegraph

Mob cast bars, TP-move windup bars and a mob TP estimator for 75-cap
era FFXI private servers (LandSandBoat-based, primarily
[Phoenix](https://github.com/phoenixffxi/Phoenix)), built as an Ashita
v4 addon. Sibling to Whetstone, sharing its parser, tooling and
discipline: Phoenix source is ground truth, every claim carries a
PROVENANCE row, every formula is hand-tested offline, every extractor
is conservation-checked, every generated table is vintage-stamped.

Telegraph answers three questions in one glance:

- What is that mob casting, and how long until it lands?
- What TP move is it winding up, and how long do I have to stun it?
- How close is the mob to its next TP move? ("TP ~74%")

## Architecture

| File | Role | Status |
| --- | --- | --- |
| `shared/actionpacket.lua` | THE 0x028/0x029 parser, shared with Whetstone under one canonical require path (`actionpacket`) - bit reader round-trip-tested, every action category verified against Phoenix emitters | **done (Phase 1)** |
| `shared/tests/test_actionpacket.lua` | per-category packet fixtures vs an independent packer | **done (Phase 1)** |
| `tpledger.lua` | Exact Phoenix TP arithmetic (cited per function) + interval `[lo, hi]` ledger with cold/calibrated/stale confidence + 0x028 action mapping | **done (Phase 1)** |
| `tests/test_tpledger.lua` | hand-derived TP transcript (74 tests) + ledger lifecycle | **done (Phase 1)** |
| `castbar.lua` | one-bar-per-actor cast/windup state machine; completion events carry expected-vs-observed timing | **done (Phase 1)** |
| `tests/test_castbar.lua` | bar lifecycle, unknown-id hardening | **done (Phase 1)** |
| `tools/extract_spells.py` | Phoenix spell SQL (+ era module castTime updates) → `data/spells.lua` | **done (Phase 2)** |
| `tools/extract_mobskills.py` | Phoenix mob_skills SQL → `data/mobskills.lua` (windup, tp_free) | **done (Phase 2)** |
| Whetstone `tools/extract_mobs.py` | extended: per-entry `cmb_delay`/`h2h`/`tp_mods` for the TP feed | **done (Phase 2)** |
| `telegraph.lua` | Ashita v4 bootstrap (`/tele`, `debug`, `selftest`, `profile`, `tp`, `bars`, `panel`); every callback pcall-latched | **done (Phase 3, needs in-game shakedown)** |
| `ui.lua` | TextUnformatted-only panel (text bars - no new binding surface), version-stamped window | **done (Phase 3)** |
| `config.lua` + `tests/test_config.lua` | fixed persistence pattern (T{} defaults, sanitize, sandboxed deserializer) | **done (Phase 3)** |
| `tests/test_ui.lua` | binding contract (stub + source grep) + pure line builders | **done (Phase 3)** |
| `tools/analyze_telegraph.py` | TP_ESTIMATE / CAST_TIME / WINDUP verdicts over `/tele debug` logs | **done (Phase 4)** |
| `PROVENANCE.md` | row-per-claim ground-truth manifest | **living** |

> **Release packaging:** the generated tables (`data/spells.lua`,
> `data/mobskills.lua`, and optionally `data/mobs/`) are **gitignored
> for development but REQUIRED at runtime** (mobs/ is optional - see
> Degradation). `tools/package_release.py --addon telegraph` bundles
> them plus the shared modules into the addon folder. Do not ship the
> addon without its data.

## Ground truth

Primary: **Phoenix** (`phoenixffxi/Phoenix` @
[`0f3f8fc`](https://github.com/phoenixffxi/Phoenix/commit/0f3f8fcfcad5872874fd6050bb4befb543b2d1fa)),
the same pinned commit as Whetstone. Category semantics were verified
against the server enums and the AI-state emitters, NOT assumed from
names - the full table lives in `shared/actionpacket.lua` and
PROVENANCE.md. The load-bearing findings:

- **Casting start** is `MagicStart`(8) whose cmd_arg is the spell
  GROUP's FourCC (`'cawh'`...); the spell id rides in `result.param`.
  A cast **interrupt** is a SECOND MagicStart carrying the group's
  interrupt FourCC (`'spwh'`...) - the "casting is interrupted" chat
  line arrives separately on 0x029 (message 16).
- **TP-move readying** is `SkillStart`(7) + FourCC `'cate'` with the
  mob skill id in `result.param`; it is emitted ONLY when the skill's
  activation time is > 0. **The TP spend happens at this instant**
  (`SpendCost()` runs at state entry), not at the finish.
- **Mob skill finishes** arrive as category 11 - except skill ids
  < 256, which finish as category 3 (the player-WS category; the
  consumer disambiguates by actor), and avatar pets (13).
- **Readying implies TP ≥ 1000** (`shouldUseTPMove`) - the ledger's
  calibration clamp. Caveat: the special-skill path bypasses the
  gate; the error self-corrects at the spend it also performs.
- **The era TP curve** is the enabled `soa/tp_gain.lua` module
  override: one piecewise curve for every entity, with a genuine
  source discontinuity at delay 530→531 (155 → 145) that the
  interval propagation samples explicitly.
- Victims of player hits book `floor((curve(delay)+30) × mods)` - the
  +30 is the "mobs stay dangerous" term; mob-vs-mob and players book
  `floor(curve(delay) × mods / 3)` with no dAGI term. The dAGI
  modifier is replicated verbatim and is **structurally 1.0** (the
  source expression never reaches its advertised 50% reduction).
- Spell cast times are `spell_list.sql` castTime (ms) **after** the
  enabled era modules' UPDATEs (60 on the pinned commit - era Stone
  is 1500 ms over the base 500 ms). Mob windups are
  `mob_skills.mob_prepare_time` (ms).

### Profiles

`tpledger.lua` exposes both rule sets; `/tele profile phoenix|lsb`:

| Knob | `phoenix` (default) | `lsb` |
| --- | --- | --- |
| TP curve | single era curve (soa module) | PC/pet curve + mob curve split |
| MOB_TP_MULTIPLIER | 1.0 (tracked default) | 1.0 |

The deployed `map.MOB_TP_MULTIPLIER` is not in Phoenix's repo (same
class of caveat as Whetstone's alpha) - if `/tele debug` TP verdicts
run consistently hot/cold by one factor, that's the knob.

## The confidence model (estimator policy, not server truth)

The ledger tracks an interval `[lo, hi]` plus a flagged point
estimate per mob, keyed by entity SERVER ID with Whetstone's
narrow.lua invariants (latest-data-wins, degenerate-id refusal, name
tripwire against id recycling, zone wipe, death eviction, LRU cap):

- **cold** (`~~`): no TP move observed yet - bounds start at the full
  [0, 3000] and the panel shows the marked midpoint, never an
  unflagged guess.
- **calibrated** (`~`): a readying/finish collapsed the interval (the
  ≥ 1000 clamp + the spend's high-confidence zero point).
- **stale** (`~?`): nothing observed for 12 s - hi grows at a
  generous being-fought rate, lo decays at the server's idle Rest
  rate (-50 TP/10 s), and the marker says so.

Feeds carry parameter UNCERTAINTY as intervals: the own player's
delay is exact (equipment + era trait tables for Dual Wield/Martial
Arts, cited in telegraph.lua); unknown party members ride
`POLICY.unknown_delay` bounds; WS main-hit counts are bounded
[1, numHits] because the packet only carries the damage total.

### Degradation ladder (deliberate)

| Missing | Effect |
| --- | --- |
| `data/mobs/` | mob swing feeds use POLICY delay bounds instead of `cmb_delay`; regain/store-TP mods unknown → wider intervals, same honesty |
| WS table (never shipped) | WS feeds bound hits at [1, 8] (the server's swing cap) |
| spell/skill id missing from table | bar shows `casting (id N)` / `skill (id N)` with no duration - never a crash, never an invented number |

## Generating the data tables

```sh
python3 Telegraph/tools/extract_spells.py    --server /path/to/Phoenix \
    --out Telegraph/data/spells.lua    --source-label "phoenixffxi/Phoenix @ <commit>"
python3 Telegraph/tools/extract_mobskills.py --server /path/to/Phoenix \
    --out Telegraph/data/mobskills.lua --source-label "phoenixffxi/Phoenix @ <commit>"
python3 Whetstone/tools/extract_mobs.py      --server /path/to/Phoenix \
    --out Telegraph/data/mobs --split  --source-label "phoenixffxi/Phoenix @ <commit>"
```

Pinned-commit numbers: 893 spells (60 module castTime updates
applied; the dump's 35 commented-out rows correctly excluded), 2,546
mob skills (2,071 with windup, 155 tp-free; 1,798 commented-out
retail rows excluded), 12,625 mob entries with 2,274 carrying
tp_mods. All extractors fail loudly (`ConservationError`) on anything
they cannot account for.

## Validation plan (`/tele debug` + analyzer)

Hard rule inherited from Whetstone: **any non-Phoenix server validates
plumbing only**; the math questions are settled on Phoenix.

`/tele debug` writes `telegraph_events.log`:

- one line per bar completion - `expected_s` (table) vs `observed_s`
  (packet timing) per spell/skill, with the outcome
  (finish/interrupt/replaced);
- one line per TP-move fire - the PRE-clamp estimate (`lo/hi/best`)
  against the implied `>= 1000` truth, flagged tp_free when the spend
  does not apply.

`tools/analyze_telegraph.py` renders verdicts:

1. **TP_ESTIMATE** - at every readying/instant-finish: did the
   interval contain 1000+ (calibrated entries only)? Persistent
   misses low → a feed is undercounting (or MOB_TP_MULTIPLIER ≠ 1);
   high → overcounting.
2. **CAST_TIME** - observed cast start→finish duration vs table
   castTime per spell id. Systematic shortfalls flag mob fast-cast
   mods (out of model, server-side); a constant factor flags a
   table/units bug.
3. **WINDUP** - observed readying→finish duration vs
   mob_prepare_time per skill id (zone-script overrides surface here).

## Running the tests

```sh
lua5.1 shared/tests/test_actionpacket.lua
lua5.1 Telegraph/tests/test_tpledger.lua
lua5.1 Telegraph/tests/test_castbar.lua
lua5.1 Telegraph/tests/test_config.lua
lua5.1 Telegraph/tests/test_ui.lua
python3 Telegraph/tools/test_extract_spells.py
python3 Telegraph/tools/test_extract_mobskills.py
python3 Telegraph/tools/test_analyze_telegraph.py
```

(The Whetstone suite covers the shared-parser delegation and the
extended mob extractor.) Every expected value is hand-derived from the
server source in a comment next to the assertion - the tests are not
generated from the implementations.
