# v-park

Vehicle persistence for FiveM, built for QBCore and running on qbx_core, ESX and ox_core too.

Leave a car somewhere and it is still there after the restart, **in the same parking space** -
not approximately, not in the middle of the road, not on top of an NPC's Asea. Nothing is
spawned until somebody is near it, bodywork damage is stored and synchronised so two players
see the same dents, and job and rental vehicles can be tied to their owner being online rather
than to a clock.

There is a migration from Advanced Parking that reads your existing table, tells you exactly
what it found, and changes nothing until you say so.

---

## Contents

- [What it does](#what-it-does)
- [The tight-space problem](#the-tight-space-problem)
- [Compatibility](#compatibility)
- [Installation](#installation)
- [Commands](#commands)
- [The admin panel](#the-admin-panel)
- [Semi-persistence](#semi-persistence-job-and-rental-vehicles)
- [Cleanup by use](#cleanup-by-use)
- [Deformation](#deformation)
- [Performance](#performance)
- [Migrating from Advanced Parking](#migrating-from-advanced-parking)
- [Garage integration](#garage-integration)
- [Discord webhooks](#discord-webhooks)
- [Known limits](#known-limits-stated-plainly)
- [Documentation](#documentation)
- [Version française](#version-française)

---

## What it does

- **Vehicles stay where they were left.** Across a resource restart, a server restart, and a
  crash. Position, rotation, modifications, colours, damage, fuel, dirt, plate, extras, neons,
  livery and lock state.
- **A player's own car is kept from the moment they get in.** No command, no waiting. If the
  framework says it is theirs - **or they simply hold the keys** - it is kept, which matters
  most in the case that used to lose it: taking the car out and disconnecting a minute later.
  Persistence defaults to `owned` for exactly this reason: the cars players care about, not
  every taxi anybody has ever sat in.
- **They come back in the SAME SPACE.** A four-stage placement engine handles the tight cases:
  underground car parks, single-car garages, alleyways, MLO interiors, multi-storey ramps. It
  is the section of the config worth reading, and it has its own heading below.
- **Nothing is spawned until somebody is near it.** A database with five thousand vehicles and
  one player online has perhaps thirty entities in the world. Everything else is a row.
- **Bodywork deformation is stored and synchronised.** The dents come back, and every player
  sees the same ones - which the engine does not otherwise guarantee.
- **Job and rental vehicles can be semi-persistent.** A police cruiser survives the 06:00
  restart because the officer is still on shift, and disappears 45 minutes after they log off.
  Server downtime does not count against that timer.
- **Idle vehicles go back to a garage rather than being deleted.** A car nobody has driven in
  a fortnight is returned to the garage it came out of. Configurable, previewable, and it
  trickles rather than clearing the map in one pass.
- **An admin panel.** Search, filter and sort every persisted vehicle; teleport to one, bring
  one to you, repair, clean, refuel, unlock, rename, transfer, send to a garage, impound,
  delete - and restore from the trash when somebody deletes the wrong one.
- **A migration from Advanced Parking** that introspects your table rather than assuming a
  schema, with a scan, a dry run, a backup and a rollback.
- **Discord webhooks** for errors, staff actions and activity, on three separate channels,
  deduplicated and rate-limited so one error in a timer cannot flood a channel.
- **No hard dependency.** Framework, database driver, fuel resource, key resource, garage,
  notification system and target are all detected at runtime and all optional. `/vparkinfo`
  prints what was found.

---

## The tight-space problem

This is the reason the resource exists, so it is worth stating precisely.

A vehicle restored at the coordinates it was saved at will, on a stock setup, end up somewhere
else. **Four separate mechanisms move it**, and each needs a different answer:

| # | What moves it | The answer here |
|---|---|---|
| 1 | **Collision is not loaded yet.** The entity is created before the map streams in, so it falls, and by the time the ground arrives it is under it. The engine pops it out - into the road, usually. | Create it frozen and with collision off, wait for `HasCollisionLoadedAroundEntity`, then hand physics back. |
| 2 | **Something is already there.** Ambient traffic spawns while the server is empty and the game parks an NPC car exactly where the player left theirs. | Clear the disposable ones - empty, unowned, not ours, not a mission entity - then suppress traffic generation there for a few seconds. The vehicle is placed at its saved pose either way: it is **never moved aside**, because the only things that can be in the way are already cleared, coexisted with it, or will leave on their own. |
| 3 | **The engine ground-snaps it.** `SetVehicleOnGroundProperly` probes downwards, finds the level below in a car park, and drops the car through the floor. | Never call it. Place with `SetEntityCoordsNoOffset` at the exact saved Z, and consult the ground only when the saved Z is provably wrong - more than 1.5 m *below* it. |
| 4 | **It is in an interior.** An entity at MLO coordinates without being told which room renders through the wall or falls to the world below. | Store the interior and the room key, and force them on restore. |

On top of those, two things that are not fixes so much as design decisions:

- **`freezeUntilTouched` is on by default.** A restored vehicle stays frozen until a player
  comes near it or interacts with it. A frozen entity cannot be walked out of a tight bay by
  the physics solver over twenty minutes, cannot be nudged down a camber by passing traffic,
  and is not simulated at all - which is most of the performance story. It wakes before a
  player can reach it, so it is invisible in play.
- **When the exact spot really is blocked**, the fallback is `place` - put it exactly where it
  was anyway, frozen. For a tight space that is the *right* answer: with nothing pushing it,
  the intersection is stable, and the first player to drive it out resolves it naturally. The
  alternatives (`defer`, `ground`, `skip`) are all one config line away.

`/vparkprobe` runs the whole probe where you are standing and prints what it found, which is
how you tune `Config.Placement.probe.shrink` against your own MLO rather than guessing.

---

## Compatibility

Everything below is detected at runtime and optional. **Nothing is required except OneSync.**

| Capability | Detected |
|---|---|
| **Framework** | qb-core, qbx_core, es_extended (ESX), ox_core. First one started wins; `Config.Compat.framework` overrides. Anything else runs standalone against the Rockstar licence. |
| **Database** | oxmysql, mysql-async, ghmattimysql. Without one, vehicles live in memory for the session and it says so, loudly, once. |
| **Fuel** | rcore_fuel, ox_fuel, LegacyFuel, ps-fuel, cdn-fuel, qs-fuelstations, lj-fuel, x-fuel, okokGasStation, qb-fuel. Anything else in one line: `Config.Compat.fuelStatebag`. |
| **Keys** | qs-vehiclekeys (Quasar), qb-vehiclekeys, wasabi_carlock, mk_vehiclekeys, cd_garage, jaksam. |
| **Inventory** | qs-inventory (Quasar), ox_inventory, qb-inventory. Trunk and glovebox contents follow the plate, which we preserve exactly and refuse to change in a way that would orphan a stash. |
| **Garages** | qs-advancedgarages (Quasar), qb-garages, qbx_garages, jg-advancedgarages, cd_garage, loaf_garage, okokGarage, RxGarage. |
| **Notifications** | v-hud, ox_lib, okokNotify, qb-core, ESX, or the game's own feed. |
| **Mechanic / tuning** | jim-mechanic. Fitted parts come through the game's mod slots and need nothing; the nitrous bottle is restored explicitly, including on vehicles the framework does not own. |
| **Deformation** | Kiminaze's free `VehicleDeformation` resource, if you have it. We defer to it rather than fighting over the same statebag, and still persist what it reports. |
| **Target** | ox_target, qb-target, qtarget. Only for the optional "park here" option, which is off by default. |

**OneSync is required** and it is checked at boot. Server-created entities do not exist without
it, and a persistence resource that quietly keeps a per-client fiction is worse than one that
refuses to start. `Config.General.requireOneSync = false` if you know exactly why.

Vehicles are created with **`CREATE_VEHICLE_SERVER_SETTER`**, which registers the entity with
the server immediately and supports every vehicle type. `CreateVehicle` is an RPC: it returns a
handle before the entity exists, and everything you then do to that handle fails for a frame or
two. On a build without the setter native the RPC path is used and waited on
(`Config.Streaming.readyTimeout`), which works and is simply not as good as not having the race
at all.

A setter entity is **orphaned** until a client is within scope: registered with the server,
not present in the game world, and `DoesEntityExist` answers false for the whole of that
window. That is normal and is not waited on - the client waits for the entity itself, in the
restore handler, which is the machine it is waiting for.

> **On a txAdmin server, OneSync is set in the txAdmin settings page, not in `server.cfg`.**
> txAdmin's config validator comments the line out on every start and leaves a note saying so,
> which means the obvious place to put it is the one place it does not work. If v-park says
> OneSync is switched off on a server you believe has it on, that is why. Check the txAdmin
> settings page.

### What differs by framework

ESX has no citizenid, so the character key is the identifier - which already carries the
character suffix on a multi-character ESX and is therefore correct. ox_core uses groups rather
than jobs, and the highest-graded group stands in for the job. Only qb-core has a first-class
impound state; on ESX and ox_core `onExpiry = 'impound'` falls back to the garage and the
notification says which happened. Everything else behaves identically.

Run `/vparkinfo` to print what was actually detected on **your** server.

---

## Installation

1. Drop `v-park` into your `resources/` folder.
2. `ensure v-park` in `server.cfg`, **after** your framework and after oxmysql.
3. Make sure OneSync is on.
4. Grant yourself the admin ACE:

   ```cfg
   add_ace group.admin vpark.admin allow
   ```

5. Optional: point the Discord webhooks at a channel, in `server.cfg` rather than in
   `config.lua` - a webhook URL is a credential:

   ```cfg
   set vpark_webhook_errors "https://discord.com/api/webhooks/..."
   set vpark_webhook_admin  "https://discord.com/api/webhooks/..."
   ```

6. Optional: `setr vpark_locale "fr"` for French. It follows `qb_locale` otherwise.

The tables are created on first start. `sql/v_park.sql` is shipped for operators who would
rather import a schema by hand; with `Config.Database.autoSchema` on, importing it is optional.

There is no build step. Everything ships as source.

### Then, in game

Drive somewhere, get out, wait 45 seconds. `/vparkscan` lists what is persisted around you.
`/vparkadmin` opens the panel.

If you are coming from Advanced Parking, **read [MIGRATION.md](MIGRATION.md) before anything
else** and start with `/vparkmigrate scan`.

---

## Commands

Every command is prefixed `vpark` so nothing here can collide with a `/park` from another
resource. Rename any of them in `Config.Commands`; set `enabled = false` to remove one.

### Players

| Command | Effect |
|---|---|
| `/vpark` | Keep the vehicle you are in, or looking at, across restarts |
| `/vparkforget [id\|plate]` | Stop keeping it. The car is still there; it just will not come back |
| `/vparklist` | Your kept vehicles, with how long since each was touched |
| `/vparkfind <id\|plate>` | Set a waypoint to one of yours |
| `/vparklock <id\|plate> [on\|off]` | Lock or unlock one of yours |
| `/vparkinfo` | What v-park detected on this server |

### Staff

| Command | Effect |
|---|---|
| `/vparkadmin` | **Open the panel** |
| `/vparkadmin garages` | List the garages read from your garage resource, with their ids |
| `/vparkadmin cleanup preview` | What the idle cleanup WOULD move. Changes nothing |
| `/vparkadmin cleanup run` | Run it now |
| `/vparkgoto <id\|plate>` | Teleport to a vehicle |
| `/vparkhere <id\|plate>` | Bring a vehicle to you |
| `/vparkdelete <id\|plate>` | Remove it. Recoverable from the trash |
| `/vparkrestore <id>` | Bring one back from the trash |
| `/vparkowner <id\|plate> <player id>` | Transfer it |
| `/vparkscan [radius]` | List persisted vehicles near you |
| `/vparkzones` | List the zones where nothing persists |
| `/vparkstats` | What v-park is costing this server right now |
| `/vparksave` | Flush every pending change to the database |
| `/vparkpurge <filter> [confirm]` | Bulk removal. Always previews first |
| `/vparkprobe [model]` | Run the placement probe where you stand, and print the result |
| `/vparkwhere` | Report how far each restored vehicle near you is from where the database says it should be - per axis, plus heading, frozen, dressed and owner |
| `/vparkdiag [id\|plate]` | What the SERVER thinks. With no argument, every vehicle in the world ordered by how far it drifted from its stored place; with one, the full record - stored pose, actual pose, drift, entity and net id, and the four flags that decide whether its position may be saved. Works from the console, unlike `/vparkwhere` |
| `/vparkwhy` | Why the last twenty-five vehicles were not kept: model, plate, who offered it, and the reason. Every refusal in the adoption path used to be silent |
| `/vparkdebug` | Toggle debug logging and the on-screen overlay |
| `/vparkmigrate <scan\|dry\|run\|rollback>` | The Advanced Parking migration |

### Console only

| Command | Effect |
|---|---|
| `vparkwipe` | Delete every persisted vehicle. Asks twice, with a generated token |

`/vparkpurge` filters: `idle:<days>`, `type:<owned\|job\|rental\|claimed\|unowned\|ambient>`,
`model:<name>`, `wrecked`.

---

## The admin panel

`/vparkadmin`. It is the only NUI in the resource, it is only ever open for staff, and it sends
and paints nothing while it is closed - a player who never runs the command never loads it.

- **Search** by plate, model, owner name, owner id or vehicle id.
- **Filter**: near me, in world, idle, wrecked, semi-persistent, owned, job, unowned, **owner
  online**, **owner offline**, missing model.
- **Sort**: most recent, nearest, longest idle, plate, model - from the dropdown or by clicking
  a column header.
- **Per row**: go to it, bring it here, drop a waypoint, open its details, and behind the
  overflow menu - repair, clean, refuel, unlock, rename, set owner, send to a garage, impound,
  delete.
- **Select and act in bulk.** Tick rows, or press `A` for the whole page, and repair, clean,
  refuel, unlock, send to a garage, impound or delete the lot in one action with one
  confirmation. Capped at 100 and **refused rather than truncated** past that, because a
  truncated bulk action is the worst outcome: the operator believes it all happened.
- **A detail sheet docked beside the list**, not floating over it - it cannot cover the
  controls or the actions column, because the table reflows into the space that is left. Every
  fitted part, the colours, the damage breakdown including the deformation point count, the
  network id, and the four timestamps that decide when the vehicle expires. It names the
  vehicle it is showing, marks that vehicle's row, carries the row's actions so reading and
  acting are the same place, and stays current through the auto-refresh.
- **The rest of a row's actions open as a centred dialog** that names the vehicle, rather than
  as a dropdown hanging off the right of the table.
- **Owners read as people.** The roleplay name is resolved from the framework's own player
  table - `players.charinfo` on qb-core, `users` on ESX, `characters` on ox_core - so a vehicle
  whose owner has never been online while v-park was running still shows a name rather than a
  citizenid. One query per page, cached, and the character id stays on the second line where it
  is still searchable.
- **Keyboard**: `/` search, `R` refresh, `A` select page, arrows to page, `ESC` to back out one
  level at a time.
- **Trash tab**: everything removed in the last week, with who removed it and why, and a
  restore button that rebuilds the vehicle exactly - modifications, damage and dents included.
- **Cleanup tab**: exactly which vehicles the idle sweep would move and where to, before it
  moves anything.

The garage dropdown is populated from **your** garage resource, so it shows your garage names
rather than asking you to type an id. `Config.Panel.garages` pins the list if you would rather.

Every action re-checks the permission **on the server**. A hidden button is a convenience, not
the boundary.

The theme is `sandy` - Blaine County signage, hard edges, no rounded corners. A theme is one
CSS file in `html/css/`; nothing in `panel.css` contains a colour, so a new palette cannot
break the layout.

---

## Semi-persistence: job and rental vehicles

A job vehicle is not property and it is not scenery. A cruiser parked outside Mission Row
should still be there after the 06:00 restart, because the officer is still on shift. It should
**not** still be there tomorrow morning because somebody logged off in it at 3 am.

`Config.SemiPersistence` ties a vehicle to its owner's **presence** rather than to a clock:

```lua
job = {
    enabled = true,
    graceMinutes = 45,              -- offline for this long, and it goes
    pauseWhileServerOffline = true, -- downtime does not count against it
    onJobChange = 'grace',          -- clock off as a mechanic, the cruiser starts counting
    onExpiry = 'delete',
    protectWhenInUse = true,        -- another officer driving it keeps it
},
rental = { ... }                    -- the same, plus a hard end time your rental script sets
```

**The countdown is a counter, not a timestamp**, and that is the whole trick. The obvious
implementation - "delete it 45 minutes after last-seen" - is wrong in exactly the case this
feature exists for: a server that restarts at 06:00 and returns at 06:03 has, by that measure,
had every offline player absent all night, and every job vehicle would be gone at boot.

So the counter accumulates only while **the server is running and the owner is not**. A
three-minute restart costs three minutes of nobody's grace. Set
`pauseWhileServerOffline = false` for wall-clock behaviour if you would rather an overnight
outage clear the map.

A rental script sets a hard end time through the API and whichever comes first wins:

```lua
exports['v-park']:SetRental(vehicleId, 3600, characterId)  -- one hour left on the rental
```

---

## Cleanup by use

Section 9's expiry counts from `touched_at`, which moves whenever *anything* happens to a
vehicle. That is the right clock for "is this abandoned" and the wrong one for "does anybody
still drive this": a car parked outside its owner's house is touched constantly and has not
been driven since March.

`Config.Cleanup` counts from `last_used_at`, which moves **only when a person gets in**.

```lua
idleDays = {
    owned = 15,     -- a fortnight and a bit
    job = 7,
    rental = 3,
    claimed = 30,   -- somebody parked it deliberately. Longest.
    unowned = 5,
},
destination = 'lastGarage',        -- the garage it came out of, which we remember
fallbackGarage = 'motelgarage',
maximumPerSweep = 25,              -- it trickles; it does not clear the map in one pass
```

It **sends vehicles home, it does not delete them.** An owned car goes back to a garage - the
one it was taken from, where we know it - and the player finds it there. Vehicles named with
`/vparkrename` are exempt, because naming a car is a deliberate act.

Run `/vparkadmin cleanup preview` before switching it on. It lists exactly what would go and
where, and changes nothing.

---

## Deformation

`bodyHealth` is one number, and two cars at 600 look nothing alike: one folded at the front,
one caved in along the driver's door. Restoring the number without the shape gives a car that
comes back with its damage in the wrong place.

It is also the most common desync in FiveM: the engine hands a vehicle's damage to whoever owns
the entity and reconstructs it approximately everywhere else, so two players beside the same
wreck routinely see two different wrecks.

Both have one answer. Sample the deformation into data, store it, and have **every** client
apply that same data locally - then the dents are identical everywhere by construction rather
than by hoping the engine agrees with itself.

The published technique for this is [Kiminaze's
VehicleDeformation](https://github.com/Kiminaze/VehicleDeformation), which is MIT and worth
reading. Four things here are deliberately different:

1. **No probe pass and no spawned copy.** The reference implementation spawns a hidden copy of
   the vehicle fifty metres underground and fires ~100 synchronous LOS probes at it to work out
   which sample points sit on bodywork. It is not needed: a point that is not on bodywork
   reports no deformation, so it is never stored and never applied. The filtering is free at
   capture time.
2. **The sides are included.** The reference grid keeps only the front and rear thirds, so a
   car hit squarely in the driver's door stores nothing. This grid covers the flanks.
3. **Stored as index and magnitude**, not as two vectors - two numbers per point instead of
   six floats, which matters because this replicates to every client in scope.
4. **Seeded convergence.** The reference starts every point at 50 damage and steps by 5, up to
   50 iterations. Seeding a first guess from the target converges in single figures.

If you already run `VehicleDeformation`, we **defer to it** and still persist what it reports.
Two resources deciding what shape a car is, on different schedules, makes the car pulse.

`Config.Deformation.recaptureDelta` is the guard that stops the approximation compounding: a
restored vehicle is not re-captured until its body health actually moves.

---

## Performance

The design, in four sentences:

- **Nothing is spawned until somebody is near it.** One grid lookup per player per second, not
  a scan. Five thousand rows and one player is about thirty entities.
- **A vehicle is written when it changed and not otherwise.** Every record carries an FNV-1a
  hash of its own state; a parked car does not change, so a server with three thousand parked
  cars writes zero rows a minute.
- **A parked vehicle is not even read.** A frozen vehicle cannot move, cannot be damaged and
  cannot be occupied, so one that has not been touched since its last capture is provably
  identical to what the server already has - and the client sends nothing at all for it. On a
  fleet that is mostly parked, that is most of the sweep gone rather than reduced.
- **A frozen entity is not simulated.** With `freezeUntilTouched` on, the restored fleet at
  rest costs the client almost nothing.

Beyond that: the save sweep is sliced into quarters so the cost is a trickle rather than a
sawtooth; the expensive half of a capture - seventy-five native calls of mod slots, colours,
extras and neons - is cached against a twelve-call fingerprint and re-read only when somebody
has actually fitted something; the other expensive half, the sixty-eight deformation samples, is
cached the same way against body health, which cannot stay still while bodywork deforms, so an
undamaged car costs one native call and an unchanged one costs one too; writes are batched into one upsert per 200 vehicles inside a
transaction; the semi-persistence sweep walks an ownership index rather than the whole store;
a placement takes one snapshot of the vehicle pool and every probe reads from it; the spiral
search starts all of its shape tests before reading any of them, so forty-five candidates cost
one frame rather than forty-five; the client has **one** timer whose interval comes from how far
the nearest tracked vehicle is (200 ms in a car park, 2 s in an empty field); and there is no
`Wait(0)` in the client code outside a placement in progress and the debug overlay.

`/vparkstats` prints what it is actually costing you, which beats any number written here. It
reports an average AND a worst case over a sliding window for the streaming pass, the capture
sweep and the reconciliation, because the duration of the last pass hides a spike: a loop that
is fine ninety-nine times and terrible on the hundredth reads as fine. It also reports how many
vehicles are waiting on a client, waiting to be deleted, or queued for another restore attempt,
which is the difference between a resource that is busy and one that is stuck.

When a vehicle is not where it should be, `/vparkdiag` names the number: it prints the stored
pose, the actual pose, the distance between them, and the four flags that decide whether that
vehicle's position is allowed to be written down at all.

---

## Migrating from Advanced Parking

**Read [MIGRATION.md](MIGRATION.md).** The short version:

```
/vparkmigrate scan       find the table, print the column mapping and the row count
/vparkmigrate dry        map every row and report what WOULD be written. Changes nothing
/vparkmigrate run        do it. Copies your table to a backup first
/vparkmigrate rollback   undo the last run
```

**Your source table is only ever READ.** Nothing writes to it, drops it or renames it, so your
old script keeps working and you can run both while you decide.

Advanced Parking creates its own table and does not publish the schema, and it has changed
across its major versions. So this does not assume one: it reads `INFORMATION_SCHEMA`, maps the
columns it recognises, and **prints the ones it does not**. `Config.Migration.columnMap`
overrides any part of the mapping.

`dry` is not a formality. It is where a mismatched column shows up as four thousand vehicles at
coordinate zero.

The three Advanced Parking exports its own FAQ tells operators to add - `UpdatePlate`,
`DeleteVehicle` and `GetVehiclePosition` - are answered by v-park too, so a garage script that
already calls them keeps working after the switch.

---

## Garage integration

A garage stores a vehicle by deleting its entity. We do not hook that. Instead:

1. Every vehicle we restore carries a `vpark:id` statebag.
2. When an entity carrying one goes away and we did not remove it, we treat that as an external
   deletion and stop tracking the vehicle after a five-second grace period.
3. On load, a vehicle the framework marks as stored or impounded is skipped.

The grace period is load-bearing: several resources delete and immediately recreate a vehicle
(a repair, a colour change, a respawn into a bay), and acting instantly would forget a vehicle
that is about to come back.

**The duplication guard.** When we restore an owned vehicle we mark it as *out* in the
framework's own table. Without that, a player can have a car in the street *and* listed in
their garage, and take it out twice. `Config.Garages.markAsOut`, on by default, and there is no
good reason to turn it off.

A garage that wants an exact answer rather than an inferred one calls the export before
deleting:

```lua
exports['v-park']:Store(plateOrId, 'motelgarage')
```

---

## Discord webhooks

Three channels, because errors need to be seen by whoever fixes them, staff actions by whoever
supervises staff, and routine activity by nobody most of the time. In one channel the first
drowns in the third.

```cfg
set vpark_webhook_errors   "https://discord.com/api/webhooks/..."
set vpark_webhook_admin    "https://discord.com/api/webhooks/..."
set vpark_webhook_activity "https://discord.com/api/webhooks/..."
```

**Put the URL in `server.cfg`, not in `config.lua`.** A webhook URL is a credential: anybody
holding it can post to your channel as you, forever, with no further authentication, and
`config.lua` ends up in your repository and in the zip you send when you ask for help.

Errors are deduplicated on the message with numbers stripped and rate-limited to twelve a
minute, with the suppressed count reported in the next post. An error inside a per-second timer
posts once, not 3600 times an hour - which is the failure mode that makes people turn error
webhooks off, after which the next real error goes unread for a fortnight.

---

## Known limits, stated plainly

- **What has actually been run, and what has not.** The server half is exercised on a real
  qb-core server with oxmysql and MariaDB 11.4 before every release: **112 automated checks**
  covering boot, schema creation and upgrade, detection, every console command, the loader, the
  spatial grid, ownership, the lifecycle maths, the save pipeline, the trash, the audit log and
  the full migration cycle including backup and rollback. Several real defects have come out of
  it, including one - console commands never being audited - that had survived two releases
  because the pcall that caught it logged a single line nobody read.

  `tools/check.py` runs twenty static groups over the Lua and the stylesheets, including a
  real Lua 5.4 parse of every file, a check that the theme file sets no layout property, and a check
  that the database column list and the value list agree position by position - which is a bug
  that has shipped twice and writes every value after the mismatch into the wrong column.

  **The client half has not been driven by a human yet.** Placement, deformation, property
  capture and apply, and the admin panel all need a game client, and the automated pass cannot
  provide one. They are written carefully and reviewed, and they have not been played.
  `test-procedures/` in the repository has the procedure; reports are very welcome.

- **Only qb-core has been run at all.** qbx_core, ESX and ox_core are implemented behind the
  same adapter interface and statically verified to implement every method the bridge calls,
  but no server has run them.
- **The vehicle type is guessed for rows written before 1.0.4.** `CREATE_VEHICLE_SERVER_SETTER`
  needs a type string - `automobile`, `bike`, `boat`, `heli` and so on - which is not the
  vehicle class and is not derivable from it for every model. It is captured from a client and
  stored, but a row that predates the column, or one brought in by the migration, has only the
  class to go on. A handful of models guess wrong - the amphibious Stromberg and Toreador are
  class 6, several class 14 entries are submarines - and spawn as automobiles until somebody
  drives one, at which point the real type is stored and it is right from then on.

- **Deformation restore is approximate.** `SetVehicleDamage` is not the inverse of
  `GetVehicleDeformationAtPos`; putting a shape back is a search, and it reproduces damage that
  *reads* as the same, not the same vertices. `recaptureDelta` stops that compounding over
  repeated save cycles, and it is why re-capture is guarded rather than continuous.

- **The world probe is off by default, and that is deliberate.** A vehicle was parked at its
  saved pose, so the map allowed it, and the map has not changed - so probing world geometry can
  only produce false positives, and at the height the probe runs a kerb produces one. It is
  still there (`Config.Placement.probe.blockedBy.world`) for a map with geometry that genuinely
  moves, like a shutter a script opens and closes, parked under. Vehicles are always probed,
  through the entity pool, because ambient traffic really does park in the bay while the server
  is empty.
- **A blocked space with no free spot nearby ends in an intersection.** With the default
  `fallback = 'place'` the vehicle goes exactly where it was, frozen, possibly clipping
  geometry. That is deliberate - see the tight-space section - but it is a trade, not a
  triumph.
- **Advanced Parking's schema is not published**, so the migration introspects rather than
  knowing. It tells you what it mapped and what it could not, and `dry` exists so you check
  before committing. A schema nobody has seen may still need `Config.Migration.columnMap`.
- **Garage list auto-detection needs an export.** Several garage resources do not publish one
  on every build. When the list cannot be read it says so at boot and you set
  `Config.Panel.garages` and `Config.Cleanup.fallbackGarage` by hand - two lines.
- **`SetEntityOrphanMode` is not on every server build.** Where it is missing, vehicles are
  occasionally re-created after the engine collects them. Wasteful, not broken.
- **Trailers are stored and re-attached; towed and cargobob-carried vehicles are not**, and
  `Config.Persistence.attached` is off by default because the attachment offsets are not
  reliably reproducible across a game build change.

---

## Documentation

| File | What is in it |
|---|---|
| [CONFIG.md](CONFIG.md) | Every setting, what it trades away, and the five sections you will actually open |
| [API.md](API.md) | Every export and event another resource can call |
| [MIGRATION.md](MIGRATION.md) | The Advanced Parking migration, step by step, including what to do when it does not fit |
| [CHANGELOG.md](CHANGELOG.md) | What changed, newest first |
| [RULES.md](RULES.md) | Conventions for anyone changing the code |
| [ERROR_LOG.md](ERROR_LOG.md) | Every non-trivial bug hit while building it, with the root cause |

`config.lua` is the real documentation. Every section has a header explaining what it decides
and what it costs to change it, and Section 7 (Placement) is worth reading in full before
touching any of it.

---

## Licence

MIT with an attribution requirement. See [LICENSE](LICENSE).

---
---

# Version française

**Persistance des véhicules pour FiveM**, conçue pour QBCore et fonctionnant aussi sur
qbx_core, ESX et ox_core.

Vous laissez une voiture quelque part, elle y est toujours après le redémarrage, **dans la même
place de parking** : pas approximativement, pas au milieu de la route, pas sur le capot d'une
Asea de PNJ. Rien n'apparaît tant que personne n'est à proximité, les déformations de carrosserie
sont sauvegardées et synchronisées entre tous les joueurs, et les véhicules de métier et de
location peuvent être liés à la présence de leur propriétaire plutôt qu'à une horloge.

Une migration depuis Advanced Parking lit votre table existante, vous dit exactement ce qu'elle
y a trouvé, et ne change rien tant que vous ne le demandez pas.

## Ce que ça fait

- **Les véhicules restent où ils ont été laissés.** Position, rotation, modifications,
  couleurs, dégâts, carburant, saleté, plaque, extras, néons, livrée, verrouillage.
- **Ils reviennent DANS LA MÊME PLACE.** Un moteur de placement en quatre temps traite les cas
  serrés : parkings souterrains, garages une place, ruelles, intérieurs MLO, rampes de parkings
  à étages.
- **Rien n'apparaît tant que personne n'est à proximité.** Cinq mille véhicules en base et un
  joueur connecté, cela fait une trentaine d'entités dans le monde. Le reste, ce sont des lignes.
- **Les déformations sont sauvegardées et synchronisées.** Les bosses reviennent, et tous les
  joueurs voient les mêmes, ce que le moteur ne garantit pas autrement.
- **La voiture d'un joueur est conservée dès qu'il monte dedans.** Aucune commande, aucune
  attente. Si le framework dit qu'elle lui appartient, **ou s'il en a simplement les clés**,
  elle est conservée : c'est justement le cas qui la faisait perdre avant, sortir sa voiture et
  se déconnecter une minute plus tard. Le mode de persistance est `owned` par défaut pour cette
  raison précise.
- **Semi-persistance des véhicules de métier et de location.** Une voiture de police survit au
  redémarrage de 06h00 parce que l'agent est toujours en service, et disparaît 45 minutes après
  sa déconnexion. Le temps d'arrêt du serveur ne compte pas dans ce décompte.
- **Les véhicules inutilisés retournent au garage plutôt que d'être supprimés.** Une voiture
  que personne n'a conduite depuis quinze jours est renvoyée dans le garage d'où elle venait.
- **Un panneau admin** : rechercher, filtrer, trier, s'y téléporter, faire venir le véhicule,
  réparer, nettoyer, ravitailler, déverrouiller, renommer, transférer, envoyer au garage, mettre
  en fourrière, supprimer, et restaurer depuis la corbeille.
- **Une migration depuis Advanced Parking** qui inspecte votre table au lieu de supposer un
  schéma, avec analyse, simulation, sauvegarde et retour arrière.
- **Des webhooks Discord** pour les erreurs, les actions du staff et l'activité, sur trois
  canaux séparés, dédupliqués et limités en débit.
- **Aucune dépendance obligatoire** en dehors de OneSync. Framework, base de données, carburant,
  clés, garage, notifications et target sont tous détectés à l'exécution.

## Le problème des places étroites

C'est la raison d'être de la ressource. Quatre mécanismes différents déplacent un véhicule
restauré, et chacun demande une réponse différente :

1. **La collision n'est pas encore chargée.** L'entité est créée avant que la map ne se charge,
   elle tombe, et le moteur la repousse dans la route. *Réponse : créer gelé et sans collision,
   attendre `HasCollisionLoadedAroundEntity`, puis rendre la physique.*
2. **Il y a déjà quelque chose.** Le trafic ambiant se gare exactement là où le joueur avait
   laissé sa voiture. *Réponse : sonder le volume cible avant de placer, et ne supprimer que ce
   qui est manifestement jetable - vide, sans propriétaire, pas à nous.*
3. **Le moteur colle au sol.** `SetVehicleOnGroundProperly` trouve le niveau inférieur dans un
   parking et fait passer la voiture à travers le plancher. *Réponse : ne jamais l'appeler.*
4. **Le véhicule est dans un intérieur.** *Réponse : stocker l'intérieur et la pièce, et les
   forcer à la restauration.*

`freezeUntilTouched` est activé par défaut : un véhicule restauré reste gelé jusqu'à ce qu'un
joueur s'en approche. Une entité gelée ne peut pas être poussée hors de sa place par le solveur
physique en vingt minutes, et n'est pas simulée du tout.

`/vparkprobe` exécute la sonde là où vous vous tenez et affiche le résultat : c'est comme ça
qu'on règle `Config.Placement.probe.shrink` sur son propre MLO au lieu de deviner.

## Installation

1. Placez `v-park` dans `resources/`.
2. `ensure v-park` dans `server.cfg`, **après** votre framework et après oxmysql.
3. Vérifiez que OneSync est activé. **Sur un serveur txAdmin, OneSync se règle dans la page de
   paramètres txAdmin, pas dans `server.cfg`** : le validateur de txAdmin commente la ligne à
   chaque démarrage. Si v-park dit que OneSync est désactivé alors que vous croyez l'avoir
   activé, c'est là qu'il faut regarder.
4. Donnez-vous la permission : `add_ace group.admin vpark.admin allow`
5. Facultatif, dans `server.cfg` et **pas** dans `config.lua` :
   `set vpark_webhook_errors "https://discord.com/api/webhooks/..."`
6. Facultatif : `setr vpark_locale "fr"`.

Les tables sont créées au premier démarrage. `sql/v_park.sql` est fourni pour ceux qui préfèrent
importer à la main.

## Commandes principales

| Commande | Effet |
|---|---|
| `/vpark` | Conserver le véhicule où vous êtes, ou celui que vous regardez |
| `/vparkforget` | Ne plus le conserver. La voiture reste là, elle ne reviendra simplement pas |
| `/vparklist` | Vos véhicules conservés |
| `/vparkfind <id\|plaque>` | Point GPS vers l'un des vôtres |
| `/vparkinfo` | Ce que v-park a détecté sur ce serveur |
| `/vparkadmin` | **Ouvrir le panneau** |
| `/vparkadmin cleanup preview` | Ce que le nettoyage déplacerait. Ne change rien |
| `/vparkgoto` / `/vparkhere` | Se téléporter au véhicule / le faire venir |
| `/vparkprobe` | Tester le placement là où vous êtes |
| `/vparkdiag [id\|plaque]` | Ce que le SERVEUR pense : sans argument, tous les véhicules du monde classés par écart avec leur place enregistrée ; avec un argument, la fiche complète. Fonctionne depuis la console |
| `/vparkwhy` | Pourquoi les derniers véhicules n'ont pas été conservés |
| `/vparkmigrate scan` | Analyser la table Advanced Parking |

La liste complète est dans la section anglaise ci-dessus.

## Limites connues

- **Ce qui a réellement tourné, et ce qui n'a pas tourné.** La moitié serveur a été exercée sur
  un vrai serveur qb-core avec oxmysql : 64 vérifications automatisées couvrant le démarrage, la
  création du schéma, la détection, toutes les commandes console, le chargement, la grille
  spatiale, la propriété, le cycle de vie, la sauvegarde, la corbeille, le journal d'audit et le
  cycle complet de migration. Trois vrais défauts en sont sortis et sont corrigés.

  **La moitié client n'a pas encore été jouée par un humain.** Le placement, les déformations,
  la capture et l'application des propriétés et le panneau admin nécessitent tous un client de
  jeu. Ils sont écrits avec soin et relus, ils n'ont pas été joués. La procédure est dans
  `test-procedures/`.

- **Seul qb-core a tourné.** ESX, qbx_core et ox_core passent par le même adaptateur et sont
  vérifiés statiquement, mais aucun serveur ne les a fait tourner.
- **La restauration des déformations est approximative.** Elle reproduit des dégâts qui *se
  lisent* comme les mêmes, pas les mêmes sommets.
- **Une place bloquée sans emplacement libre à proximité finit en intersection.** Avec le
  réglage par défaut le véhicule est placé exactement où il était, gelé. C'est délibéré, mais
  c'est un compromis.
- **Le schéma d'Advanced Parking n'est pas publié**, donc la migration l'inspecte. Elle vous dit
  ce qu'elle a reconnu et ce qu'elle n'a pas reconnu.

## Documentation

`config.lua` est la vraie documentation : chaque section explique ce qu'elle décide et ce que ça
coûte de la changer. Voir aussi [CONFIG.md](CONFIG.md), [API.md](API.md) et
[MIGRATION.md](MIGRATION.md).

## Licence

MIT avec obligation d'attribution. Voir [LICENSE](LICENSE).
