# Souls modules

LandSandBoat custom modules implementing the Ashen Era "Souls" progression.
They hook the engine through LSB's documented module override system
(`Module:addOverride`) — no core files are forked.

| File | Hook | Purpose |
|---|---|---|
| `souls/lua/souls_core.lua` | — | Defines the global `xi.souls` namespace: currency, unlock catalog, bloodstain bookkeeping, helper API. **Must load first.** |
| `souls/lua/souls_earn.lua` | `xi.mob.onMobDeathEx` | Awards souls per kill, scaled by mob level (NM bonus). |
| `souls/lua/souls_death_penalty.lua` | `xi.player.onPlayerDeath` | Drops all carried souls into a bloodstain; resets balance. |
| `souls/lua/souls_login.lua` | `xi.player.onGameIn` | Seeds new chars, re-applies owned unlocks, shows MOTD + balance. |
| `souls/commands/soul.lua` | `@soul` command | Player wallet + shop (`balance` / `list` / `buy` / `recover`). |

Load order is set in [`init.txt`](init.txt); `souls_core` is listed first
because the others reference `xi.souls.*` at runtime.

Install: run `../setup.sh`, which copies this `souls/` folder into your LSB
checkout's `modules/` directory and appends the entries to the checkout's
`modules/init.txt`. To tune gameplay, edit `xi.souls.config` and
`xi.souls.catalog` in `souls/lua/souls_core.lua`.

See the parent [`../README.md`](../README.md) for the full guide, including the
"Deep cross-job enablement" caveat about the engine's per-job cast gate.
