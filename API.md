# API

Everything another resource may call, and every event and statebag this one publishes.

Nothing here is required to use v-park. It is here so a garage can tell us it stored a car, a
rental script can sell an hour, a dealership can transfer a sale, and a mechanic job can pull a
vehicle into the world.

---

## Contents

- [Reads](#reads) - open to any resource
- [Writes](#writes) - gated
- [Advanced Parking compatibility shims](#advanced-parking-compatibility-shims)
- [Events](#events)
- [Statebags](#statebags)
- [The vehicle object](#the-vehicle-object)
- [Recipes](#recipes)

---

## Reads are open, writes are gated

Anything can ask where a vehicle is or whether it is persisted. Only a resource
`Config.Api.allowedResources` permits can change anything, and `Config.Api.allowWrites = false`
turns writing off altogether.

```lua
Config.Api = {
    allowWrites = true,
    allowedResources = {},   -- empty means any resource
    events = true,
}
```

That gate is real rather than a courtesy: `GetInvokingResource()` is told to us by the runtime
and cannot be spoofed by the caller. A server running scripts it does not fully trust can set
the list and mean it.

A refused write returns `false, reason` and logs a warning naming the resource.

---

## Reads

### `IsReady()`

```lua
if not exports['v-park']:IsReady() then return end
```

Whether the store is loaded and the timers are running. Everything else answers sensibly before
boot completes, but a read at that moment is a read of an empty store.

### `GetVehicle(reference)`

```lua
local vehicle = exports['v-park']:GetVehicle('K3M2A0Q7XZ4B')
local vehicle = exports['v-park']:GetVehicle('48ZKV921')      -- a plate works too
```

Returns [a vehicle object](#the-vehicle-object), or `nil`. `reference` is an id or a plate; the
id is tried first.

### `GetVehicleByPlate(plate)`

The same, restricted to plates. Case and padding are normalised, so `"abc 123"` and
`"ABC123  "` both find the same vehicle.

### `IsPersisted(entity)`

```lua
if exports['v-park']:IsPersisted(vehicle) then ... end
```

Whether an entity handle is one of ours. Reads the statebag, so it costs nothing and needs no
lookup.

### `GetVehicleId(entity)`

The `vpark:id` on an entity, or `nil`.

### `GetPlayerVehicles(source)`

```lua
for _, vehicle in ipairs(exports['v-park']:GetPlayerVehicles(source)) do
    print(vehicle.modelName, vehicle.plate, vehicle.coords)
end
```

Every persisted vehicle belonging to a player. Accepts a server id or a character id directly.

### `GetVehiclesNear(coords, radius, bucket)`

```lua
local near = exports['v-park']:GetVehiclesNear({ x = 215.0, y = -810.0, z = 30.0 }, 50.0)
```

Sorted nearest first, each carrying an extra `distance`. Goes through the spatial grid, so it
is a handful of table lookups rather than a scan. `bucket` is optional; omit it to match every
routing bucket.

### `GetVehiclePosition(reference)`

```lua
local coords, heading = exports['v-park']:GetVehiclePosition(plate)
```

Where a vehicle is, **whether or not it currently exists in the world**.

This is the single most useful call for a garage script. Before letting a player take a car
out, ask whether it is already standing in the street:

```lua
if exports['v-park']:GetVehiclePosition(plate) then
    -- It is already out. Do not spawn a second one.
end
```

Advanced Parking's own FAQ recommends the same check against its equivalent, for the same
reason: without it, a player takes out a second copy of a car they already have.

### `GetStats()`

```lua
local stats = exports['v-park']:GetStats()
-- { store = {...}, spawn = {...}, persist = {...}, lifecycle = {...},
--   database = {...}, webhooks = {...}, ready = true }
```

What `/vparkstats` prints, as a table. Useful for a monitoring dashboard.

### `GetSavedFields()`

```lua
local fields = exports['v-park']:GetSavedFields()

if not fields.neons then
    -- v-park is not storing neons, so this resource should.
end
```

Which property groups v-park is actually storing, as `{ [group] = true|false }`.

Resolved live rather than read off the config, because `Config.Save.fields` accepts `'auto'` as
well as a boolean. `neons` defaults to `'auto'`, which means "on where a resource that manages
neons is running" - so the config says `'auto'` and this says what that came out as, which is the
answer a mechanic or mod-shop resource needs before it decides to handle a group itself.

### `GetGarages()`

```lua
for _, garage in ipairs(exports['v-park']:GetGarages()) do
    print(garage.id, garage.label, garage.point)
end
```

The garage list read from whichever garage resource is installed. Empty when none could be
read, which is announced once at boot.

---

## Writes

All of these are subject to `Config.Api.allowWrites` and `allowedResources`.

### `Park(netId, options)`

```lua
local id = exports['v-park']:Park(netId, {
    ownerType = 'rental',        -- owned | job | rental | claimed | unowned
    owner = characterId,
    name = 'Jean Lefevre',
    job = nil,
})
```

Persist a vehicle that exists right now. Returns the new id, or `nil, reason`.

The full property capture needs a client, so the vehicle is persisted immediately with what the
server can see, and the nearest client is asked to fill in the modifications and damage. That
enrichment is not a precondition: the vehicle is already kept when this returns.

### `Forget(reference)`

Stop persisting a vehicle. **Does not delete the entity** - the car is still there and still
drivable, it simply will not come back after a restart.

### `Store(reference, garageId)`

```lua
exports['v-park']:Store(plate, 'motelgarage')
DeleteEntity(vehicle)
```

**Tell us a garage is storing this vehicle.** Call it *before* deleting the entity.

`Config.Lifecycle.forgetOnExternalDelete` infers this from the entity going away, after a
five-second grace period. This export is the exact version: no inference, no grace period, and
no window in which the streaming pass might re-create the vehicle you just deleted.

`garageId` is optional and is remembered as the vehicle's last garage, which is where the idle
cleanup sends it back to.

### `Delete(reference, reason)`

Remove a vehicle from persistence and from the world. Recoverable from the trash for
`Config.Database.trashRetentionDays` days.

Returns `ok, outcome` where outcome is `'deleted'`, `'returned'` or `'impounded'` - an owned
vehicle is handed back to its garage rather than destroyed unless you asked otherwise.

### `SetOwner(reference, characterId, ownerType, name)`

```lua
exports['v-park']:SetOwner(plate, buyerCitizenId, 'owned', 'Marie Duval')
```

Hand a persisted vehicle to somebody else. Resets the semi-persistence countdown, because the
new owner has not been offline and the previous one's absence is not theirs to inherit.

### `SetRental(reference, seconds, characterId)`

```lua
exports['v-park']:SetRental(id, 3600, characterId)   -- one hour left
exports['v-park']:SetRental(id, 0)                   -- clear the hard expiry
```

Mark a vehicle as a rental with a hard end time. `seconds` is how long the rental has **left**,
from now.

The vehicle then goes at whichever comes first: that time, or the end of the semi-persistence
grace period once the renter goes offline. Nothing in v-park can extend a rental past what your
script sold.

### `SetLabel(reference, label)`

Name a vehicle. Up to 32 characters, stored in the `vpark:label` statebag so anything reading
the entity can see it. A named vehicle is exempt from the idle cleanup.

### `SetPlate(reference, plate)`

Change a persisted vehicle's plate.

**Read this before calling it.** A stash in every modern inventory is keyed on the plate.
Changing a plate without moving the stash orphans whatever was in the boot, and the player has
no way to know it happened.

With `Config.Inventory.guardPlateChanges` on, a change that would collide with another
persisted vehicle is **refused** rather than applied, and one that would orphan a stash logs a
warning naming your resource. It returns `false, reason` so you get a truthful answer instead
of silent data loss.

### `Repair(reference)` / `Refuel(reference, level)`

Repair a vehicle completely, or set its fuel to `level` (0-100). Both bring the vehicle into
the world if it is not there, apply the change through the nearest client, and correct the
stored properties so the change survives a restart even if nobody is near it afterwards.

### `Spawn(reference)`

```lua
local entity, netId = exports['v-park']:Spawn(id)
```

Force a vehicle into the world now, wherever it is stored, and wait for it to be dressed and
placed. For a mechanic job pulling a car in, or a tow truck.

### `Despawn(reference)`

Take it out of the world without forgetting it. It comes back the moment somebody walks near.

### `Flush()`

Write every pending change to the database now. Fire and forget.

---

## Advanced Parking compatibility shims

Answered under the same names so a garage or key script that already calls them keeps working
after a migration. These are the three the Advanced Parking FAQ tells operators to add.

```lua
exports['v-park']:GetVehiclePosition(plate)     -- documented above
exports['v-park']:DeleteVehicle(entity)         -- forget it, then delete the entity
exports['v-park']:UpdatePlate(entity, plate)    -- change the plate, through the guard above
```

`UpdatePlate` on an entity that is **not** ours falls through to `SetVehicleNumberPlateText`,
which is what the original does.

---

## Events

Fired when `Config.Api.events` is on, which it is by default.

| Event | Side | Arguments |
|---|---|---|
| `vpark:server:ready` | server | `{ loaded, framework, database }` |
| `vpark:server:vehicleAdded` | server | `id, { plate, owner, ownerType }` |
| `vpark:server:vehicleRemoved` | server | `id, { plate, owner, reason, outcome }` |

```lua
AddEventHandler('vpark:server:vehicleRemoved', function(id, info)
    if info.reason == 'owner_absent' then
        -- a semi-persistent vehicle went because its owner logged off
    end
end)
```

`reason` is one of `expired`, `owner_absent`, `job_changed`, `rental_ended`, `idle_cleanup`,
`evicted`, `purge`, `admin`, or whatever a caller passed to `Delete`.

---

## Statebags

On every vehicle v-park restores. Replicated, so any client can read them.

| Key | Type | Meaning |
|---|---|---|
| `vpark:id` | string | The persisted vehicle id. Its presence means "this is ours" |
| `vpark:plate` | string | The plate, normalised |
| `vpark:label` | string | The optional name, when one is set |
| `vpark:deform` | table | `{ v = version, g = gridVersion, d = { ... } }`. Deformation data; every client applies it locally |

```lua
-- client
local id = Entity(vehicle).state['vpark:id']
if id then
    -- this vehicle is persisted
end
```

**Do not write to these.** `vpark:id` in particular is what stops the placement engine deleting
a vehicle as ambient traffic, and setting it on something we do not know about makes that
vehicle undeletable by us and invisible to everything else.

The keys carried **across** a restart are a separate, configurable list -
`Config.Save.statebagKeys` - and adding your own resource's key to it is one line:

```lua
Config.Save.statebagKeys = {
    'fuel', 'fuelLevel', 'odometer', 'hasnitro', 'noslevel',
    'myresource:something',
}
```

---

## The vehicle object

What every read returns. A **copy**, and a reduced one: handing out the live record would let a
caller mutate the store without going through the indexes.

```lua
{
    id = 'K3M2A0Q7XZ4B',
    plate = '48ZKV921',
    model = 970598228,
    modelName = 'sultanrs',
    class = 6,
    className = 'sports',

    owner = 'ABCD1234',          -- citizenid, ESX identifier, ox charId, or licence
    ownerType = 'owned',         -- owned | job | rental | claimed | unowned | ambient
    ownerName = 'Marie Duval',
    job = nil,

    coords = { x = -1042.2, y = -2745.6, z = 21.3 },
    rotation = { x = 0.0, y = 0.0, z = 118.4 },
    heading = 118.4,
    bucket = 0,
    interior = 0,

    bodyHealth = 1000.0,
    engineHealth = 1000.0,
    fuel = 74.0,
    wrecked = false,

    live = true,                 -- currently an entity in the world
    netId = 4218,                -- only when live

    lastGarage = 'motelgarage',  -- where the idle cleanup would send it
    rentalUntil = 0,             -- unix seconds, or 0

    createdAt = 1757280000,
    updatedAt = 1757283600,
    touchedAt = 1757283600,      -- anything happened to it
    lastUsedAt = 1757200000,     -- somebody got IN it

    graceRemaining = 2640,       -- seconds, or nil when not semi-persistent
}
```

`touchedAt` and `lastUsedAt` are different on purpose and the difference matters: the first
answers "is this abandoned", the second answers "does anybody still drive this". A car parked
outside its owner's house is touched constantly and has not been driven since March.

---

## Recipes

### A garage that stores a vehicle

```lua
RegisterNetEvent('mygarage:store', function(plate)
    local vehicle = exports['v-park']:GetVehicle(plate)
    if vehicle and vehicle.netId then
        exports['v-park']:Store(plate, 'motelgarage')
    end

    -- your own storing logic
end)
```

### A garage that refuses to take a car out twice

```lua
local coords = exports['v-park']:GetVehiclePosition(plate)
if coords then
    TriggerClientEvent('mygarage:alreadyOut', src, coords)
    return
end
```

### A rental script

```lua
-- the customer drives off
local id = exports['v-park']:Park(netId, {
    ownerType = 'rental',
    owner = characterId,
    name = playerName,
})

exports['v-park']:SetRental(id, hours * 3600, characterId)
```

The car survives restarts for as long as the rental runs, and goes 45 minutes after the renter
logs off even if the rental has hours left - `Config.SemiPersistence.types.rental`.

### A dealership selling a used car

```lua
exports['v-park']:SetOwner(plate, buyerCitizenId, 'owned', buyerName)
```

The persisted vehicle changes hands with the sale rather than expiring on the buyer under the
previous owner's timer.

### A mechanic job pulling a car in

```lua
local entity, netId = exports['v-park']:Spawn(plate)
if not entity then
    -- nobody near enough, or the model is not valid on this build
    return
end

-- work on it, then
exports['v-park']:Flush()
```

### Reacting to a vehicle being cleaned up

```lua
AddEventHandler('vpark:server:vehicleRemoved', function(id, info)
    if info.reason ~= 'idle_cleanup' then return end
    if not info.owner then return end

    -- tell the player in your own way, on their next login
end)
```

### Adding your own statebag to the ones that survive a restart

```lua
-- config.lua
Config.Save.statebagKeys = {
    'fuel', 'fuelLevel', 'vehicleid', 'vehicleProps', 'doorslocked',
    'odometer', 'mileage', 'jimOdo', 'hasnitro', 'noslevel',
    'vpark:label',

    'myresource:insurance',
}
```

Only scalars and tables under 2 KB are carried; anything larger is another resource's business
and not something to copy into our row.
