# Configuration

`config.lua` is the real documentation: every section has a header explaining what it decides
and what it costs to change it, and this file does not repeat all of that.

This is the map. It says which sections matter, what the defaults assume, and what to change
for the situations people actually run into.

---

## Contents

- [The five you will actually open](#the-five-you-will-actually-open)
- [Section 5: what persists](#section-5-what-persists)
- [Section 7: placement](#section-7-placement)
- [Section 8: streaming](#section-8-streaming)
- [Section 9: lifecycle](#section-9-lifecycle)
- [Section 9b: semi-persistence](#section-9b-semi-persistence)
- [Section 9c: cleanup by use](#section-9c-cleanup-by-use)
- [Section 11: zones](#section-11-zones)
- [Section 12 and 13: commands and permissions](#section-12-and-13-commands-and-permissions)
- [Tuning for your server size](#tuning-for-your-server-size)
- [Every section at a glance](#every-section-at-a-glance)

---

## The five you will actually open

| Section | What it decides |
|---|---|
| **5. Persistence** | Which vehicles are kept at all |
| **7. Placement** | The tight-space respawn. Read its header in full |
| **8. Streaming** | How many exist in the world at once, and how far away |
| **9b. Semi-persistence** | Job and rental vehicles tied to their owner being online |
| **12. Commands** | The names, and who may run them |

Everything else has a default that a busy roleplay server wants.

---

## Section 5: what persists

### `Config.Persistence.mode`

The single most consequential setting in the file.

| Mode | Behaviour | Table size on a busy server |
|---|---|---|
| **`'owned'`** (default) | Only vehicles that are somebody's: the framework's owned-vehicles table, **or the keys** | Hundreds |
| `'all'` | Any vehicle a player drives becomes persistent | A few thousand rows. They expire; see Section 9 |
| `'claimed'` | Nothing persists until somebody runs `/vpark`. Maximum player agency, and it makes parking a deliberate act | Small |
| `'none'` | Persistence off. Commands, API and migration still work | Zero |

`'none'` is the setting to use **while migrating**, before you flip the switch.

**The default changed in 1.0.2**, from `'all'` to `'owned'`. `'all'` persists every car anybody
drives, and on a busy server that is a table full of stolen taxis nobody will ever look for
again. Set it to `'all'` if you want stolen cars to stay where they were left.

**`'owned'` means "somebody's", not "a car".** `Config.Persistence.excludedClasses` is empty by
default, so every class is in scope: a boat, a helicopter, a plane and a bicycle are all kept when
they belong to somebody. Boats and aircraft also use the same 250 m spawn radius as everything
else - see `Config.Streaming.classRadius`, which used to cut them to 150 and made the one class of
vehicle you approach with a long clear sight line the one that appeared late.

Two settings keep `'owned'` from being uselessly strict, and both are on by default:

- **`Config.Ownership.keysGrantOwnership`** - **off**, and it should stay off on any server with
  a working owned-vehicles table. It was on by default until 1.0.11, on the stated but unchecked
  premise that `/admincar` does not register the vehicle to anybody. It does:
  `qb-adminmenu`'s SaveCar runs `INSERT INTO player_vehicles`. What the setting actually did was
  make everything that hands over keys without registering a vehicle - `/car`, dealership test
  drives, job spawners, admin spawn menus - produce permanent rows. Turn it on only if your key
  resource genuinely is the only record of who owns what.

- **`Config.Persistence.allowClaimInOwnedMode`** - `/vpark` works. A claim is neither an owned
  vehicle nor a job one, so read strictly the mode would refuse it and the park command would do
  nothing at all on a stock install.

### `settleSeconds`

```lua
settleSeconds = 45,
```

How long a vehicle must sit empty before it is written for the first time. This is not about
performance, it is about intent: without it, every car a player steps out of for four seconds
at a red light becomes a permanent fixture of the map.

### The blacklists

```lua
excludedClasses = { 13, 21 },     -- bicycles and trains. Keep them excluded
excludedModels = { 'taxi', 'firetruk' },
includedModels = {},              -- non-empty means WHITELIST, and it wins outright
excludedPlates = { 'PDM*' },      -- trailing * is a prefix match
```

A non-empty `includedModels` overrides `excludedModels` entirely. An operator who wrote a
whitelist meant "these and nothing else", and honouring the blacklist as well would produce the
surprising case of a model on both lists being refused.

Class ids are the game's own, and both ids and names work: `excludedClasses = { 13, 'train' }`
is valid. An entry that resolves to nothing is warned about at boot, by name, because a
blacklist that silently does nothing is the worst kind.

### Ceilings

```lua
maximumVehicles = 20000,        -- server-wide. 0 for none
maximumPerCharacter = 0,        -- per player. 0 for none
```

`maximumVehicles` is a safety valve rather than a tuning knob: 20000 is far above what any
server reaches, so hitting it is a signal that something is wrong. `maximumPerCharacter` is the
knob that stops one player leaving thirty cars across the map - when they exceed it, their
oldest is dropped and they are told which.

---

### `Config.Save.restoreWrecks`

An engine at or below zero is a vehicle that will never start again, and the number is stored
faithfully. Putting the number back is not the same as putting the vehicle back: the game decides
a vehicle is destroyed from its own damage model, and a car it created a second ago has none - so
a burnt-out shell came back as a working car with a bad engine reading, and drove away.

With this on, a stored wreck is restored destroyed: engine and petrol tank at the floor the game
itself uses, body at zero, undriveable.

What it does **not** do is put the charred bodywork back. That needs the vehicle to have actually
burned, and the only way to make it burn on demand damages whatever is standing next to it -
which, on a restore, is the player who triggered it.

### `Config.Save.fields.neons` and `Config.Save.neonManagers`

`fields.neons` is the one field that does not default to a boolean. It defaults to `'auto'`, which
means **off unless a resource that manages neon lights is running.**

Neon state does not survive a vehicle being destroyed and re-created, and that is the game rather
than this resource: losing it across a store-and-retrieve cycle is known FiveM behaviour, reported
independently of v-park. Nine releases of v-park went into working around it, and what they produced
was interference - a loop that switched a player's neons off two seconds after they fitted them, and
a capture that wrote a failed restore over the value the player had chosen.

So v-park defers. `neonManagers` lists the resources that own the neon lifecycle, and when one of
them is running the group switches itself on, because that resource is doing the part v-park cannot.

```lua
Config.Save.fields.neons = 'auto'
Config.Save.neonManagers = { 'jim-mechanic', 'jim_mechanic' }
```

Add your own mechanic or mod-shop script to the list. There is no cost to a name you do not run: an
absent resource simply does not match.

`true` and `false` still mean exactly what they say, and override the detection in both directions.

Which way it resolved is printed at boot and in `/vparkinfo`, and available to other resources
through the `GetSavedFields` export.

## Section 6d: the anchor

A boat is restored to the exact coordinates it was left at, and then the water moves it. That is
not a persistence bug and no amount of placement accuracy fixes it: the vehicle is where the
database says it is, and the water moves it afterwards.

```lua
Config.Anchor = {
    enabled = true,
    classes = { [14] = true },      -- 14 is Boats
    permission = 'occupant',        -- or 'owner'
    frozenWhenAnchored = false,
    automatic = false,
}
```

`classes` is why boats are the interesting case and the only one on by default. A boat has an
anchor of its own - `SET_BOAT_ANCHOR`, what the world's moored boats use - so it holds position
while still riding the swell. Every other class is held by freezing the entity outright, and a
frozen entity **ignores position writes**: an admin teleport, a tow script or a `tpm` will
silently fail on it until the anchor comes up.

`permission` decides who may drop or raise it. `'occupant'` is anybody the server watched get
into it, on the argument that somebody at the wheel can already take the boat anywhere;
`'owner'` restricts it to the owning character plus staff.

`frozenWhenAnchored` holds the boat completely still. Truer to a boat tied against a dock, wrong
for one moored in open water, and the difference is visible.

Whether a dropped anchor survives a restart is `Config.Save.fields.anchor`.

### Using it from a menu

```lua
-- client, from a radial or F1 menu
exports['v-park']:ToggleAnchor()
TriggerEvent('vpark:anchor')          -- the same thing
TriggerEvent('vpark:anchor', true)    -- drop it, explicitly

-- server, on your own authority
exports['v-park']:SetAnchored('62AEL793', true)
```

The client only ever *asks*. The server checks who is asking, stores the answer and replicates it,
and every client applies the replicated value - which is what makes two players see the same boat
in the same place.

### `Config.Streaming.movedThreshold`

Metres, from where the server last wrote a vehicle down, before moving it without driving it
counts as its new home. 0 switches it off.

Everywhere else in this resource, only a person **driving** a vehicle can change where it is
parked, because a woken vehicle is simulated and one on a camber rolls. That rule is wrong about a
tow truck, a cargobob, a forklift, another car shoving it, and a player pushing it out of a
doorway. A distance tells them apart without needing to know which happened: a roll is
centimetres, a tow is the length of a street.

Only read from a vehicle that is empty and at rest, so one mid-tow is never written down halfway
through the journey.

### `Config.Streaming.despawnGrace`

Seconds after a vehicle is created before the streaming pass may collect it again.

Every distance in that pass is measured from a player's position as the server reads it off their
ped, and that value lags a teleport. For that moment the player still reads as being where they
came from, so a vehicle created for them on arrival is judged out of range and deleted - which is
the "it appears, then vanishes when I reach for the door" report.

No legitimate case wants a vehicle created and deleted inside the same few seconds. That pattern is
churn whatever produced it, and this is the floor under it.

### `Config.Placement.airborneTolerance`

Metres above whatever is beneath it before a restored vehicle is handed back to physics instead of
being frozen. 0 switches it off.

A frozen vehicle is not simulated, which is the whole performance story and exactly wrong for one
stored while it was not on the ground - a helicopter somebody left hovering being the usual case.
`Placement.groundCorrect` deliberately exempts aircraft from being pulled down, because a
helicopter on a rooftop helipad is sixty metres above "the ground" and entirely where it should be,
so the freeze is what changes rather than the position. Above the tolerance the vehicle falls,
lands or crashes exactly as it would with no persistence resource running.

Boats are exempt: the ground under a boat is the seabed.

## Section 7: placement

**Read the header in `config.lua`.** It states the four mechanisms that move a restored vehicle
and this section is the four answers. Two settings are worth calling out here.

### `probe.shrink`

```lua
shrink = 0.88,
```

The one number an operator with an unusual MLO will need to change.

A model's bounding box is bigger than its body: it contains the wing mirrors, the aerial, the
tow hook and a margin the exporter added. Testing the raw box in a garage bay whose walls are
exactly car-width reports "blocked" every time, and the vehicle gets nudged out of a space it
fits in perfectly well.

0.88 was chosen against the tightest legitimate spaces in the base map. **Do not guess at it** -
stand in the problem space and run `/vparkprobe`, which prints the model's box, the shrink in
use, whether the space reads as free, and what the search would do instead.

- Cars nudged out of spaces they fit in → **lower** it, towards 0.80.
- Cars clipping into walls → **raise** it, towards 0.95.

### `fallback`

What happens when the probe fails and the search finds nothing.

| Value | Behaviour | When |
|---|---|---|
| **`'place'`** (default) | Put it exactly where it was, frozen. It may intersect geometry, and it will be exactly where the player left it | Tight spaces. The right answer, because with `freezeUntilTouched` nothing pushes it and the first player to drive it out resolves the intersection |
| `'defer'` | Do not place it now; keep trying on later passes | A server whose map is still loading |
| `'ground'` | Same X and Y, on the ground, keeping the heading | An outdoor-only server |
| `'skip'` | Do not place it until the player moves away and comes back | Rarely what you want |

### `freezeUntilTouched`

```lua
freezeUntilTouched = true,
wakeRadius = 30.0,
refreezeAfter = 60,
```

On by default and worth leaving on. A frozen entity is not simulated - which is most of the
performance story - and cannot be walked out of a tight bay by the physics solver over twenty
minutes. It wakes when a player comes within `wakeRadius`, opens a door, enters it or shoots
it, so it is invisible in play.

---

## Section 8: streaming

```lua
spawnRadius = 250.0,
despawnRadius = 350.0,      -- MUST be larger. The gap is hysteresis
cellSize = 200,             -- should be a little under spawnRadius
spawnsPerPass = 6,
maximumEntities = 400,
maximumPerPlayer = 60,
```

The two radii **must** differ. A player standing exactly on one boundary would otherwise spawn
and despawn the same vehicle several times a second, each spawn costing a full restore. A
hundred metres of gap is about three seconds in a fast car.

`cellSize` a little under `spawnRadius` means a query looks at a 3x3 block of cells. Smaller
cells mean more cells to visit; larger cells mean more vehicles per cell to distance-check. 200
is the flat part of that curve for a map this size.

`maximumEntities` is a safety valve. If you are hitting it, `spawnRadius` is too large for your
population density.

### Aircraft and boats

```lua
classRadius = {
    [14] = 150.0,   -- Boats
    [15] = 150.0,   -- Helicopters
    [16] = 200.0,   -- Planes
},
```

Large, expensive to stream, usually many in one place, and normally parked somewhere nobody
walks past by accident.

---

## Section 9: lifecycle

```lua
expiry = {
    owned = 0,      -- never. They belong to somebody
    job = 168,      -- one week
    rental = 72,
    claimed = 336,  -- two weeks
    unowned = 48,   -- two days
    ambient = 12,
    wrecked = 6,
},
onExpiry = 'impound',
```

Hours since anybody **touched** the vehicle - which includes a save, a repair or a passing car
nudging it. For "has anybody driven it", see Section 9c.

A wrecked vehicle expires at the **shorter** of its own timer and its ownership's, never the
longer: an owned wreck should still be cleared, and an unowned wreck should not outlive the
unowned timer just because the wrecked one is bigger.

**`onExpiry` never destroys a player's car.** An owned vehicle is handed back to the
framework - impounded on qb-core, returned to the garage on ESX and ox_core, which have no
first-class impound state - and the notification says which happened.

---

## Section 9b: semi-persistence

```lua
Config.SemiPersistence.types.job = {
    graceMinutes = 45,
    pauseWhileServerOffline = true,
    onJobChange = 'grace',
    onExpiry = 'delete',
    protectWhenInUse = true,
}
```

Ties a vehicle to its owner's **presence** rather than to a clock. See the README for the
argument; the thing to understand before changing it is `pauseWhileServerOffline`.

**With it on (default)**, the countdown accumulates only while the server is running and the
owner is not. A three-minute restart costs three minutes of nobody's grace, which is what makes
"survives a reboot" true.

**With it off**, it is wall-clock from the last touch, and an overnight outage clears every job
vehicle at boot. Legitimate on a server that restarts rarely and wants the map cleared;
surprising everywhere else.

`onJobChange`:

| Value | Behaviour |
|---|---|
| `'ignore'` | Only the grace period applies |
| `'grace'` (default) | Clocking off as a mechanic starts the countdown on the cruiser |
| `'remove'` | The cruiser goes the moment the job no longer matches |

`onOffDuty` only does anything on qb-core and qbx_core; ESX and ox_core have no duty concept
and it is ignored there.

---

## Section 9c: cleanup by use

```lua
idleDays = { owned = 15, job = 7, rental = 3, claimed = 30, unowned = 5 },
destination = 'lastGarage',
fallbackGarage = 'motelgarage',
maximumPerSweep = 25,
```

Days since anybody **got in** the vehicle. Nothing else moves that clock.

**Before switching this on**, run:

```
/vparkadmin cleanup preview
```

It lists exactly what would go and where, and changes nothing. On a server with two years of
accumulated vehicles the first sweep would otherwise move several thousand cars, and every one
of their owners would notice at once - which is what `maximumPerSweep` is for, but a preview is
cheaper than a trickle you did not expect.

`destination`:

| Value | Behaviour |
|---|---|
| **`'lastGarage'`** (default) | The garage it was taken out of, which we learn from the framework's own column at the moment we mark the vehicle as out. Falls back to `fallbackGarage` |
| `'configured'` | Always `fallbackGarage` |
| `'nearest'` | Nearest garage to where it stands, from your garage resource's list |

`fallbackGarage` must be an id **your** garage resource knows. `/vparkadmin garages` prints the
list it was able to read, which is the fastest way to find the right string.

Exemptions: vehicles somebody is near or in, vehicles inside a zone named in `exemptZones`,
vehicles named with `/vparkname`, and vehicles whose `last_used_at` is zero - which means a row
from before this feature existed or a migrated one. Treating "we have no idea" as "fifty-six
years idle" would clear the map on the first sweep after an upgrade.

---

## Section 11: zones

Places where nothing persists. Three shapes:

```lua
Config.Zones = {
    {
        type = 'circle',
        name = 'Pillbox garage',
        centre = { x = 215.0, y = -810.0, z = 30.0 },
        radius = 40.0,
        heightRange = { min = 25.0, max = 40.0 },   -- optional, and matters in a building
    },
    {
        type = 'box',
        name = 'PDM lot',
        min = { x = -60.0, y = -1120.0, z = 25.0 },
        max = { x = -20.0, y = -1080.0, z = 32.0 },
    },
    {
        type = 'poly',
        name = 'Mission Row yard',
        points = { {x=400.0,y=-1620.0}, {x=440.0,y=-1620.0},
                   {x=440.0,y=-1660.0}, {x=400.0,y=-1660.0} },
        heightRange = { min = 24.0, max = 40.0 },
    },
}
```

No PolyZone dependency. It is a good resource, it is not installed everywhere, and what we need
from it is forty lines.

`Config.ZoneOptions.autoGarages` adds a circle around every garage your garage resource knows
about, which is on by default. Turn it off if you *want* cars to persist on the garage
forecourt - some servers do, deliberately.

`/vparkzones` lists what compiled. `/vparkdebug` draws them.

---

## Section 12 and 13: commands and permissions

Every command is renameable and every one can be switched off:

```lua
Config.Commands.park = { name = 'vpark', permission = 'everyone', enabled = true }
```

A command that is off is **not registered at all** rather than registered and refusing, so it
does not appear in a chat suggestion list and does not collide with another resource that wants
the name.

Permissions:

```lua
Config.Permissions = {
    ace = 'vpark.admin',
    groups = { 'admin', 'god', 'superadmin' },
    jobs = { mechanic = 3 },       -- job at or above grade
    logRefusals = true,
}
```

**ACE is checked first and independently of the framework.** A server owner must have a way in
that does not depend on the framework being up: when qb-core fails to boot, the one thing an
admin needs is the command that tells them why.

```cfg
add_ace group.admin vpark.admin allow
```

`logRefusals` prints a console line for every refused admin command, naming the ACE. A refused
admin command is almost always a misconfigured ACE, and silence makes that take an hour to
find.

---

## Tuning for your server size

### Small (under 32 slots, a few hundred vehicles)

Defaults. Nothing to change.

### Medium (64 slots, a few thousand vehicles)

```lua
Config.Save.sweepSlices = 4          -- default
Config.Streaming.spawnsPerPass = 6   -- default
Config.Database.batchSize = 200      -- default
```

Still the defaults, which is what they were measured against.

### Large (128 slots, ten thousand or more vehicles)

```lua
Config.Save.sweepSlices = 8            -- smaller, more frequent hashing passes
Config.Save.interval = 45              -- and a longer window between full sweeps
Config.Streaming.spawnsPerPass = 4     -- flatten the spike when a player fast-travels
Config.Streaming.maximumEntities = 300
Config.Performance.streamBudgetMs = 2
Config.Cleanup.maximumPerSweep = 50    -- get through a backlog faster
```

Then watch `/vparkstats`. `lastPassMs` climbing above the budget every pass means the streaming
work does not fit, and the fix is a smaller `spawnRadius` rather than a bigger budget.

### Development server, no database

```lua
Config.Compat.database = 'none'
```

Vehicles live in memory for the session. Announced once, loudly, at boot, so nobody mistakes it
for a working configuration.

---

## Every section at a glance

| # | Section | What it decides |
|---|---|---|
| 1 | `General` | Locale, boot banner, routing bucket, the OneSync check |
| 2 | `Log` | Console verbosity, the audit table and its retention |
| 2b | `Webhooks` | Discord: errors, staff actions, activity. Three channels |
| 3 | `Compat` | Detection overrides. Leave on `auto` unless you have two of something |
| 4 | `Database` | Table prefix, schema creation, batch size, transactions, the trash |
| 5 | `Persistence` | **Which vehicles are kept at all** |
| 6 | `Save` | When and what is written. The delta design |
| 6b | `Deformation` | Bodywork shape: capture, restore, synchronisation |
| 6c | `Mechanic` | jim-mechanic: the nitrous bottle |
| 7 | `Placement` | **The tight-space respawn** |
| 8 | `Streaming` | **How many exist at once, and how far away** |
| 9 | `Lifecycle` | Expiry, eviction, external deletion |
| 9b | `SemiPersistence` | **Job and rental vehicles tied to presence** |
| 9c | `Cleanup` | Idle vehicles sent back to a garage |
| 10 | `Ownership` | Who owns what, and who may act on it |
| 11 | `Zones` | Where nothing persists |
| 12 | `Commands` | **Names, and who may run them** |
| 13 | `Permissions` | ACE, framework groups, jobs |
| 14 | `Notify` | Which events notify the player |
| 15 | `Keys` | Giving keys back on restore |
| 16 | `Inventory` | Protecting the plate-to-stash link |
| 17 | `Interaction` | Optional target option, key bind, blips |
| 17b | `Panel` | The admin panel: page size, actions, garages, theme |
| 18 | `Garages` | The stored flag, the duplication guard |
| 19 | `Migration` | Advanced Parking: tables, column map, policies |
| 20 | `Performance` | Budgets and client tick tiers |
| 21 | `Api` | Who may call the write exports |
