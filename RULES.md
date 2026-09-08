# Project Rules & AI/IDE Instructions

The single source of truth for anyone — human or assistant — working on this resource.
Read it before changing anything.

## 1. Project Identity

| Field | Value |
|---|---|
| Project name | v-park |
| Resource name | `v-park` |
| Version | Whatever `fxmanifest.lua` says. Do not restate it here. |
| Tech stack | Lua 5.4 (`lua54 'yes'`), one NUI for the admin panel, optional MySQL |
| Author | vyrriox |
| Hard dependencies | **OneSync, and nothing else.** That is a feature; defend it. |
| Optional, all runtime-detected | qb-core, qbx_core, es_extended, ox_core, oxmysql, mysql-async, ghmattimysql, rcore_fuel, ox_fuel, LegacyFuel, ps-fuel, cdn-fuel, qs-fuelstations, lj-fuel, x-fuel, okokGasStation, qb-fuel, qs-vehiclekeys, qb-vehiclekeys, wasabi_carlock, mk_vehiclekeys, cd_garage, jaksam, qs-advancedgarages, qb-garages, jg-advancedgarages, qs-inventory, ox_inventory, qb-inventory, v-hud, ox_lib, okokNotify, jim-mechanic, VehicleDeformation, ox_target, qb-target, qtarget |

**The server owns every decision; the client observes and reports.** No number a client sends
is trusted. The client runs the shared rules before reporting so the server hears less traffic,
and the server runs them again from its own state before acting. Every new net event must fit
that split.

**There is one NUI and there will not be a second.** The admin panel is it, it is staff-only,
and it loads nothing while closed. A feature that "needs" HTML for players needs a different
design.

## 2. Git Workflow

- `main` is the only long-lived branch. Ordinary changes go straight to it.
- Feature branches `feat/<slug>`, fixes `fix/<slug>`, when a change wants review first.
- Commit messages: `type: lowercase summary` — `feat`, `fix`, `docs`, `perf`, `refactor`,
  `chore`. Present tense, no trailing full stop.
- **Never** put AI/assistant attribution in a commit, a comment, or any file.
- **Never** commit personal information. Git identity is the GitHub noreply address.
- **Never** commit `test-procedures/`, `.claude/` or `CLAUDE.md` — gitignored.
- Releases are cut by the maintainer. A contributor never bumps the version.
- Release titles: `vX.Y.Z — Short subtitle`, subtitle from the first CHANGELOG bullet.
- **`python tools/check.py` before every commit.** It exits non-zero when anything fails.

## 3. Code Conventions

**Language.** All code, comments and log lines in **English**. User-facing text goes in
`locales/en.lua` **and** `locales/fr.lua`, never inline. The two files must stay key-for-key
identical, with matching format specifiers — the check script enforces both.

**Naming.** Lua locals `camelCase`. The globals this resource defines are `Park`, `Locale`,
`Locales`, `L`, `Config`, `Classes`, `Zones`, `Schema`, `Rules`, `Compat`, `Bridge`,
`Deformation`, `Properties`, `Placement`, `Stream`, `Track`, `Panel`, `Database`, `Store`,
`Runtime`, `Ownership`, `Spawn`, `Persist`, `Lifecycle`, `Actions`, `Webhook`, `Migrate`,
`Commands`. Config keys: `PascalCase` sections, `camelCase` fields. Database columns are
`snake_case` and the record fields carry the **same names**, so the write path is a straight
mapping. Events are `vpark:side:name`.

**Architecture rules.**

- Framework, database, fuel, key, garage, inventory, notification and target code lives in
  `bridge/` or `server/database.lua`, behind a `Compat.*` (client) or `Bridge.*` (server)
  function with a `Config.Compat` entry. **Never a resource name in a feature file.**
- Anything both sides must agree on lives in `shared/`. `Rules.check`, `Zones.at`,
  `Schema.enabled` and `Classes.key` are all called from both, and computing any of them twice
  is how the two drift and start disagreeing about a boundary.
- A missing optional dependency degrades, never errors. Choose the fail direction on purpose
  and write it down: no readable key resource means **no** keys (fail closed, so nobody moves
  somebody else's car); an unknown clock charges **no** time; an unreadable garage list
  produces **no** auto-zones and says so at boot.
- **No per-player loop on the server.** One streaming pass, one save sweep, one flush, one
  lifecycle sweep, one semi-persistence sweep, one cleanup sweep. Everything else is
  event-driven.
- **Two `Wait(0)` loops in the client**, both conditional: one inside a placement in progress,
  one inside the debug overlay while `/vparkdebug` is on. Anything else that thinks it needs a
  per-frame loop is wrong; use the tier model in `Config.Performance.clientTiers`.
- Every server timer starts `while not Runtime.ready() do Wait(500) end`. A sweep that starts
  early runs against an empty store and concludes that every vehicle has vanished.
- Every operation that can be done from a command, the panel and the API is implemented **once**
  in `server/actions.lua`. Three implementations is one that forgets to write an audit row.

**Gotchas already paid for — all of these are in ERROR_LOG.md with the full story.**

- **`goto` is a reserved word.** So is every other Lua keyword, and a bare table key that is one
  is a parse error that takes the whole file down. Check 10 in `tools/check.py`.
- **`type(x) == 'function'` is the wrong gate.** A function that has crossed a resource
  boundary is a TABLE with a `__call` metamethod. Use `Park.callable`. Check 5 enforces it.
- **`SetVehicleOnGroundProperly` drops vehicles through car park floors.** It is never called
  and check 6 enforces that. Placement is `SetEntityCoordsNoOffset` at the exact saved Z.
- **`SetVehicleModKit(vehicle, 0)` before any `SetVehicleMod`.** Without it every mod call
  silently does nothing and the car comes back stock.
- **Wheel type before wheel mods.** Setting the type resets the fitted wheels to its default.
- **Colour indices before custom paint.** `SetVehicleColours` clears the custom flag.
- **Extras before body health.** Toggling an extra repairs the panel it is on.
- **Damage last, deformation after damage AND after health.** Setting body health smooths the
  bodywork, so a dent applied before it is ironed out a line later.
- **`IsModelValid`, `GetDisplayNameFromVehicleModel` and `IsModelInCdimage` are client
  natives.** Guard them on the server; they degrade to "we cannot know".
- **`os`, `io` and `package` are server-only.** The client clock is `GetCloudTimeAsInt()`, and
  it returns **0** for the first frames after joining. `Park.now()` returns 0 for "unknown" and
  every timer refuses to charge against it.
- **Nothing in `onResourceStop` yields or awaits.** Use `Persist.flushNow()` and
  `Database.fire()`.
- **CFX spells some natives `Colour` and some `Color`, inconsistently and by build.** Interior
  colour, dashboard colour and xenon colour all go through `Properties.native`.
- **A statebag arrives before or after its entity, unpredictably.** Every handler waits for
  `GetEntityFromStateBagName` with a bounded timeout, and for `GetEntityModel` to stop
  answering 0.
- **Never `Set-Content -Encoding utf8`** on Windows PowerShell 5.1 — it writes a BOM, and a BOM
  breaks the Lua parse. Check 2 fails on one.
- **Never a nil in an array literal.** `#` on a table with a hole is undefined.
- **A section assignment ends with `}`, not `},`.** `Config.X = { ... }` is a statement.

## 4. The database

- Every table is prefixed, and the prefix comes from `Config.Database.prefix`. **Nothing outside
  the prefix is ever written**, with one explicit exception: the framework's owned-vehicles
  table, one column at a time, only through `Bridge.markOut`, `Bridge.returnToGarage` and
  `Bridge.impound`, and only when the config asks for it.
- The Advanced Parking table is **read only**. Never written, dropped or renamed.
- `Database.table()` is the only way a table name is produced, and it validates and backticks
  the identifier. Values are always parameters, never concatenated.
- Schema changes are **forward-only and additive**. Add a column; never drop or rename one. A
  server that downgrades keeps a column it no longer writes, which is inert and far better than
  a downgrade that loses data.
- `Store.columns`, the runtime `CREATE TABLE` in `server/database.lua` and `sql/v_park.sql` must
  agree. Check 7 enforces it.

## 5. The check script

`python tools/check.py`. Ten check groups, every one of which exists because the thing it checks
has actually gone wrong:

1. Lua 5.4 syntax, with a real parser
2. No byte order marks
3. Locale parity, keys and format specifiers
4. Every `L()` key exists
5. No `type(x) == 'function'` gate under `bridge/` or `server/`
6. No `SetVehicleOnGroundProperly`
7. `Store.columns` matches the SQL and the runtime schema
8. Every Lua file is in the manifest, and every manifest entry exists
9. Every `Schema` gate exists in `Config.Save.fields`
10. No reserved word as a bare table key

Adding a check is cheap and adding one after a bug is the point. `lupa` is optional; without it
check 1 is skipped with a warning, and CI should have it.

## 6. The NUI

- `html/panel.css` is **structure only** and contains no colour. `html/css/<theme>.css` is
  colour only. That split is what makes "a theme is one file" true rather than aspirational.
- **No border radius anywhere.** Not a style preference, a rule: a rounded rectangle with a soft
  shadow and a gradient is the default shape of every generated interface and reads as one on
  sight. Depth comes from overlap and a hard offset shadow.
- Body text at **7:1 or better** against the sheet, and anything interactive with a border you
  can see without looking for it. See the ERROR_LOG entry from 2026-09-08 22:30.
- **`textContent`, never `innerHTML`.** Every value on the page came from a database row, and a
  database row contains whatever a player typed into a vehicle label.
- The page loads nothing and paints nothing while closed. `SetNuiFocus(false, false)` is
  released in `close()`, on ESCAPE, and unconditionally in `onResourceStop`.
- No framework, no build step, no webfont. A webfont that fails to load shifts the layout the
  first time somebody opens the panel on a bad connection.

## 7. Documentation

- `config.lua` is the primary documentation. Every section carries a header saying what it
  decides and what it costs to change; a setting without a reason is a setting nobody will
  touch correctly.
- `README.md` is bilingual: English, then French.
- Update `CHANGELOG.md` on anything a server operator would notice.
- Log every non-trivial error in `ERROR_LOG.md`, with the root cause and the rule that came out
  of it. Check it before working in an area where a past error was recorded.
- Prose in this project avoids em dashes and emoji. That is a style rule for sentences, not a
  character ban, and it does not override an established structural convention.
