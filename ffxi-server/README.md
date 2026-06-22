# Ashen Era — a custom FFXI private server

A self-hostable **Final Fantasy XI** private server built on
[LandSandBoat](https://github.com/LandSandBoat/server) (the open-source FFXI
server emulator, GPLv3), tuned into a **classic level-75, vanilla-rates,
deliberately punishing** experience — with one big twist:

> ### The Souls system 🔥
> Any character, regardless of job, can unlock **any** spell or job ability —
> but every unlock **costs Souls**. You earn Souls by killing monsters and you
> **drop them all when you die** (a Dark Souls–style *bloodstain* you must
> travel back and reclaim, or lose forever). Death also wipes EXP the
> retail way. High risk, high stakes.

---

## What's in this folder

```
ffxi-server/
├── README.md                 ← you are here
├── setup.sh                  ← clones LSB, installs modules, applies settings
├── docker-compose.yml        ← db + connect + world + search + map
├── .env.example              ← DB credentials
├── settings/
│   └── souls-settings.lua     ← documented level-75 / death settings
└── modules/
    ├── init.txt              ← which modules to load
    └── souls/
        ├── lua/
        │   ├── souls_core.lua            ← xi.souls: currency, unlocks, catalog
        │   ├── souls_earn.lua            ← gain souls on every mob kill
        │   ├── souls_death_penalty.lua   ← drop souls into a bloodstain on death
        │   └── souls_login.lua           ← MOTD, re-apply unlocks, cap notice
        └── commands/
            └── soul.lua                  ← the in-game "@soul" shop command
```

> Note: this repo also contains an unrelated `FocusFlow` iOS app at the root.
> Everything for the game server lives under `ffxi-server/` and is independent.

---

## Two things you must know first

1. **You still need the retail game client.** LandSandBoat (and this project)
   is *only the server*. The game's maps, models, music and UI belong to Square
   Enix and are **not** — and cannot legally be — included here. Each player
   connects with their own legitimately-installed FFXI client, pointed at your
   server. Running your own private *server* with LSB is exactly what the
   project is for; redistributing SE's client/assets is not.

2. **This works best on a machine you control.** A small Linux box, a home PC,
   or a VPS. The server is several always-on processes plus a database; Docker
   keeps that tidy. (If you cloned this from a throwaway cloud sandbox, that
   sandbox can't *be* the live server — copy this folder to real hardware.)

---

## Prerequisites

- **Docker** + **Docker Compose v2** (`docker compose version`).
- ~**20 GB** free disk and a few GB of RAM (the DB import + build are chunky).
- **git**, and outbound internet for the first build (it clones LSB and pulls
  base images).
- Ports openable to your players: `54001/tcp`, `54002/tcp`, `54230/tcp+udp`,
  `54231/tcp` (game), and `8088/tcp` (world API). DB `3306` stays internal.

---

## Quick start

```bash
cd ffxi-server

# 1. Clone LandSandBoat, install the Souls modules, apply level-75 settings.
./setup.sh

# 2. Set your database password.
cp .env.example .env
$EDITOR .env            # change SQL_PASSWORD

# 3. Provide navmeshes (see the section below) into ./server/navmeshes

# 4. Build + launch everything. First run compiles the server and imports the
#    database, so it takes a while.
docker compose up -d --build

# Watch progress:
docker compose logs -f map
```

When `connect`, `world`, `search` and `map` are all up, the server is live.

### Create an account

LandSandBoat ships an account tool. With the stack running:

```bash
docker compose exec connect ./xi_connect --account
```

Follow the prompts to create a username/password (and, if you like, flag it as
a GM account). That's what players type at the client's login screen.

### Point a client at it

In your retail FFXI client install, set the login/lobby host to your server's
IP (most people use the community **xiloader** + a `boot` config, or edit
`ffxi-bootmod`/registry as the LSB wiki describes). The canonical, current
instructions live in the LandSandBoat wiki under **Client Setup** — follow
those for whichever loader you use.

---

## Navmeshes

Mobs use **navmeshes** for pathing. They aren't generated at build time. Easiest
options:

- Grab the prebuilt navmeshes that LandSandBoat publishes (their docker README
  documents a `meshes` image / release), and drop the files into
  `ffxi-server/server/navmeshes/`.
- Or generate them yourself with the tools in `server/tools/` (slower).

The `map` service bind-mounts `./server/navmeshes`, so anything you put there is
picked up on restart. The server still runs without them, but mob movement will
be poor — treat this as required for a real deployment.

---

## The Souls system — how it plays

| Action | Effect |
|---|---|
| Kill a monster | `+souls`, scaled by the mob's level (NMs pay out far more) |
| Die | Drop **all** carried souls into a **bloodstain** where you fell; balance → 0; EXP lost the retail way |
| `@soul recover` | Reclaim your bloodstain — **only if you're back in the zone you died in** |
| Die again first | The old bloodstain is destroyed. Gone. |
| `@soul buy <key>` | Spend souls to permanently unlock a spell/ability for your character — *any job* |

### In-game commands

```
@soul                 your balance + bloodstain status
@soul list            everything you can unlock, with prices
@soul buy <key>       unlock something (e.g. @soul buy utsusemi_ichi)
@soul recover         reclaim your bloodstain (same zone)
@soul help            command help
```

### Tuning it

All knobs live at the top of
[`modules/souls/lua/souls_core.lua`](modules/souls/lua/souls_core.lua) in
`xi.souls.config`:

- `PER_LEVEL`, `FLAT`, `NM_MULTIPLIER` — the earning curve. Lower = more brutal.
- `DROP_ON_DEATH` — set `false` to keep souls on death (turns off the bloodstain).
- `STARTER_SOULS` — free souls on first login (default `0`).

The **catalog** of purchasable unlocks is the `xi.souls.catalog` table in the
same file — it's plain data. Add rows freely:

```lua
my_unlock = { type = 'spell',   id = xi.magic.spell.BLIZZARD, cost = 250, name = 'Blizzard' },
another   = { type = 'ability', id = xi.ja.SNEAK_ATTACK,      cost = 900, name = 'Sneak Attack' },
```

`type` is `'spell'` (granted via `addSpell`) or `'ability'` (via
`addLearnedAbility`). IDs come from the engine's `xi.magic.spell.*` and
`xi.ja.*` constants.

Era/rate settings (level cap, EXP loss, gil) are documented in
[`settings/souls-settings.lua`](settings/souls-settings.lua); `setup.sh` applies
the level-75 cap and full EXP loss automatically.

---

## Deep cross-job enablement (important caveat)

The Souls modules **fully** implement the economy: earning, the bloodstain
death-drop and recovery, persistent per-character unlocks, the shop UI, and
granting ownership of spells/abilities via LSB's real Lua API
(`addSpell` / `addLearnedAbility`).

What the Lua layer **cannot** do by itself is override the engine's
**per-job cast/use gate**. FFXI's C++ core checks a spell/ability against the
character's job + level before letting it fire. So after a Warrior buys *Cure*,
they *own* it, but the engine may still refuse the cast because WAR isn't on
Cure's job list. To make cross-job use actually fire you choose one of:

- **Data tweak (no recompile):** relax the job-level requirements in the
  `spell_list` table (and ability equivalents) so the spells you sell are
  castable by any job. Lowest-effort; broadest blast radius.
- **C++ module (recompile):** add a small `modules/custom/cpp` module that
  hooks the cast/ability validation and allows it when the character owns the
  matching `[SOULS]U:*` charvar. Most surgical; keeps everyone else vanilla.

Both are documented on the LandSandBoat **Module Guide** wiki. This is called
out honestly because it needs in-game testing on your hardware — it's the one
piece this repo can't verify for you from a headless checkout.

---

## Operating it

```bash
docker compose ps                 # what's running
docker compose logs -f map        # tail a process
docker compose restart map        # bounce a process after editing Lua
docker compose down               # stop everything (DB data persists in a volume)
docker compose up -d --build      # rebuild after C++/module changes
```

Lua module edits are picked up on a `map` restart — no rebuild needed. C++ or
SQL changes need `--build` and (for SQL) re-running `setup_database`.

---

## Credits & license

- **[LandSandBoat](https://github.com/LandSandBoat/server)** — the FFXI server
  emulator this is built on, licensed **GPLv3**. Anything you derive from it
  inherits that license; keep it open.
- *Final Fantasy XI* is © Square Enix. This project is a fan-run server
  emulator and is not affiliated with or endorsed by Square Enix. Bring your
  own legitimately-owned client.
