# Migrating from Advanced Parking

Moving a server to v-park without losing anybody's car.

**Read this before running `/vparkmigrate run`.** The first three steps change nothing, and the
third exists specifically so that you find out about a problem before it is in your table.

---

## The short version

```
/vparkmigrate scan       find the table, print the column mapping, count the rows
/vparkmigrate dry        map every row and report what WOULD be written. Changes nothing
/vparkmigrate run        do it. Copies your source table to a backup first
/vparkmigrate rollback   undo the last run
```

Run them in that order. Read the output of each before running the next.

---

## Two guarantees, up front

**1. Your source table is only ever READ.**

Nothing in v-park writes to it, drops it, renames it or truncates it. Advanced Parking keeps
working exactly as before, and you can run both resources side by side while you decide - they
do not share a table, a statebag or a command name.

That means the migration is not a one-way door. If v-park does not suit you, stop it, start
Advanced Parking, and nothing has been lost.

**2. Nothing is written until you type `run`.**

`scan` and `dry` are read-only. `dry` does the entire conversion in memory and reports the
result without touching a row.

---

## Why this does not hardcode a schema

Advanced Parking creates its own table and does not publish the schema. Its documentation says
only that the table "is automatically added by the script if it does not exist", and the layout
has changed across its major versions.

A migration written against one remembered column layout would work on one version of one
server and fail **silently** everywhere else - and "fail silently" here means importing a
thousand vehicles with no modifications, or at coordinates read out of the wrong column.

So this reads `INFORMATION_SCHEMA.COLUMNS`, matches what it finds against a table of known
names, and **prints both what it matched and what it did not**. You get to check the mapping
before anything happens, and `Config.Migration.columnMap` overrides any part of it.

---

## Step 1: scan

```
/vparkmigrate scan
```

Typical output:

```
[v-park] found table `advancedparking`
[v-park] it holds 4127 row(s)
[v-park] 14 column(s) in the source table
[v-park] mapping:
[v-park]     bodyHealth    <- bodyhealth
[v-park]     created       <- created
[v-park]     engineHealth  <- enginehealth
[v-park]     fuel          <- fuel
[v-park]     heading       <- heading
[v-park]     id            <- id
[v-park]     model         <- model
[v-park]     owner         <- owner
[v-park]     plate         <- plate
[v-park]     position      <- position
[v-park]     properties    <- properties
[v-park]     updated       <- updated
[v-park] unmatched source columns (ignored): trailer, version
[v-park] the mapping is usable. Run the dry run next.
```

### What to check

- **Is the table the right one?** If you have several, the first name in
  `Config.Migration.tables` that exists wins. Reorder that list, or add yours to it.
- **Are `model` and `position` mapped?** They are the only two a vehicle cannot exist without.
  Everything else degrades gracefully.
- **Is anything in "unmatched" something you wanted?** In the example above, `trailer` is
  ignored - v-park stores trailers under its own scheme and will re-learn the attachment the
  first time somebody drives the truck.

### When it finds nothing

```
[v-park] no Advanced Parking table was found.
[v-park] reason: none of the candidate table names exist in this database
[v-park] if yours has a different name, add it to Config.Migration.tables.
```

Find the real name with:

```sql
SHOW TABLES LIKE '%park%';
```

and add it to the top of `Config.Migration.tables`.

### When the mapping is wrong

Override the columns it got wrong, and only those:

```lua
Config.Migration.columnMap = {
    position   = 'coords',
    properties = 'vehicle_data',
    owner      = 'citizenid',
}
```

Anything left `nil` is still detected. A name that is not a column of the table is reported as
an error rather than silently ignored.

---

## Step 2: dry run

```
/vparkmigrate dry
```

```
[v-park] migration: 4127 source row(s) read
[v-park] migration: 4019 would be imported
[v-park] migration: 61 reference a model this game build does not have (policy: skip)
[v-park] migration: 38 skipped: position is at the origin
[v-park] migration: 9 skipped: no usable model
[v-park] migration: nothing was changed. Run `vparkmigrate run` when the numbers above look right.
```

### This step is not a formality

It is where a mismatched column shows up. The three numbers to look at:

| What you see | What it means |
|---|---|
| **"would be imported" is close to the row count** | Good. Proceed. |
| **"position is at the origin" is large** | The position column is wrong, or the format is one we did not recognise. A row at exactly 0,0 is a row whose coordinates were never written - importing it would put a car in the middle of the ocean forever, so they are skipped. Fix `columnMap.position` and run `dry` again. |
| **"no usable model" is large** | The model column is wrong. Check `columnMap.model`. |
| **"reference a model this game build does not have"** | Add-on vehicles whose resource is not currently started. See below. |

### Add-on models

`Config.Migration.invalidModels` decides:

- **`'skip'`** (default) - do not migrate them, and list them. The usual cause is an add-on car
  that has since been removed, and restoring it would be a vehicle nobody can see.
- **`'import'`** - migrate anyway. Right during a *temporary* removal: the vehicles sit in the
  table, are never spawned, and start working again the moment the add-on comes back.

Note that `IsModelValid` is a client native. On most server builds it is absent, this check
cannot run, and every row is imported regardless of the setting - which is the honest outcome,
because the server genuinely has no model index. The streaming pass then declines to create
anything whose model is missing and says so once.

### Unknown owners

`Config.Migration.unknownOwners`:

- **`'keep'`** (default) - migrate with the raw owner string preserved. If that character comes
  back, or if the identifier format simply differs from what we expected, the vehicle re-matches
  on its own. The least destructive option.
- **`'orphan'`** - migrate with no owner. They get the `unowned` expiry, which is two days by
  default, so **check `Config.Lifecycle.expiry.unowned` before choosing this**.
- **`'skip'`** - do not migrate them at all.

---

## Step 3: run

```
/vparkmigrate run
```

Before writing anything it copies your source table:

```
[v-park] migration: backed up 4127 row(s) to `v_park_migration_backup`
```

That backup is a plain `CREATE TABLE ... AS SELECT * FROM ...`, so its shape is whatever your
source table's shape is. It is not deleted by the migration, by the rollback, or by the
retention sweep - it stays until you drop it yourself.

Then it imports in batches, flushing each one, yielding between them so a large table does not
stall the server.

### If v-park already has vehicles

```
[v-park] migration: v-park already holds 240 vehicle(s).
[v-park] migration: run `run force` if you are sure. Duplicates are skipped by plate and position either way.
```

This refusal stops the common accident of running the migration twice and doubling every
vehicle. `Config.Migration.refuseWhenPopulated = false` removes it.

Duplicate detection runs regardless of the flag: a row is skipped when its plate is already
persisted, **or** when a vehicle of the same model is already persisted within half a metre of
the same position. So a forced second run is idempotent - the refusal is belt and braces.

### After it finishes

1. **Stop Advanced Parking.** Remove `ensure AdvancedParking` from `server.cfg`. Do not delete
   the folder yet.
2. **Restart the server.** v-park loads the migrated rows into its store at boot.
3. **Walk around.** `/vparkscan 200` lists what is persisted near you. `/vparkadmin` shows the
   whole table.
4. **Check a car in a tight space.** Find a vehicle somebody parked in a garage or an alley and
   confirm it came back in the space rather than beside it. `/vparkprobe` while standing there
   tells you what the placement engine sees.
5. **Leave it a day** before deleting the Advanced Parking folder or dropping the backup table.

### Remove the fixDeleteVehicle shim

Advanced Parking asks you to add this to your framework's `fxmanifest.lua`:

```lua
shared_script "@AdvancedParking/fixDeleteVehicle.lua"
```

**Remove that line** once Advanced Parking is stopped. A `shared_script` pointing at a resource
that is not started stops the resource that references it from loading, which on a framework is
a server that does not boot.

v-park needs no equivalent shim. It notices an entity going away through its own statebag, and
the three exports the Advanced Parking FAQ tells operators to add - `UpdatePlate`,
`DeleteVehicle` and `GetVehiclePosition` - are answered by v-park under the same names, so a
garage or key script that already calls them keeps working after you change the resource name:

```lua
exports["v-park"]:GetVehiclePosition(plate)
exports["v-park"]:DeleteVehicle(entity)
exports["v-park"]:UpdatePlate(entity, plate)
```

---

## Step 4: rollback, if you need it

```
/vparkmigrate rollback
```

```
[v-park] rolled back 4019 migrated vehicle(s)
[v-park] the source table was never modified and is untouched
[v-park] the backup in `v_park_migration_backup` is still there
```

It removes every record marked `source = 'migrated'` that was created by the last run, and
leaves everything else - including vehicles persisted normally since the migration - alone.

It does **not** restore the backup into your source table, because your source table was never
written to. The backup exists for the case where you have since deleted the source table and
want the original data back by hand.

---

## What is not migrated, and why

| Not carried across | Why |
|---|---|
| **Advanced Parking's own vehicle ids** | v-park generates its own, which are time-sortable and carry their identity in a statebag before any write happens. Nothing outside Advanced Parking referenced its ids. |
| **Interior and room** | Its table does not appear to store them. v-park re-learns them the first time each vehicle is saved after the migration, so a car in an MLO garage is correct from its second save onwards - and the placement engine's collision gate handles the first restore regardless. |
| **Deformation** | Different technique, different data. Vehicles come back with their stored body health and no dents until they take new damage, at which point v-park captures its own. |
| **`last_used_at`** | Its table does not record when somebody last *drove* a vehicle. Migrated rows are seeded with the migration time, so the Section 9c idle cleanup starts counting from today rather than sending a thousand cars to the garage on its first sweep. |
| **Trailer attachments** | Re-learned the first time somebody drives the truck. |

---

## Configuration reference

Everything in `Config.Migration`:

```lua
Config.Migration = {
    -- Table names to look for, in order. First one that exists wins.
    tables = {
        'advancedparking', 'AdvancedParking', 'advanced_parking',
        'advancedparking_vehicles', 'parked_vehicles', 'kimi_parking',
    },

    -- Override detection. Only set what you need to correct.
    columnMap = {
        -- id, plate, model, owner, position, rotation, properties,
        -- fuel, bodyHealth, engineHealth, created, updated
    },

    batchSize = 250,          -- rows per batch; it yields between them
    backup = true,            -- copy the source table before writing. Leave it on
    invalidModels = 'skip',   -- 'skip' | 'import'
    unknownOwners = 'keep',   -- 'keep' | 'orphan' | 'skip'
    refuseWhenPopulated = true,
}
```

---

## Troubleshooting

**"column mapping failed: table `x` has no readable columns"**
The database user cannot read `INFORMATION_SCHEMA` for that table. Grant `SELECT` on the
schema, or set every column explicitly in `columnMap` - detection is the only thing that needs
the introspection.

**Everything imported but the cars are all in the road**
The positions came through and the placement engine could not use them. Stand where one should
be and run `/vparkprobe`. If it reports the space as blocked by geometry, lower
`Config.Placement.probe.shrink` towards 0.80 and try again. If it reports it free, the saved Z
is probably wrong - check `Config.Placement.groundTolerance`.

**Everything imported but nothing spawns**
Check `/vparkinfo` for the framework and database lines, then `/vparkstats` for the streaming
counters. A `failed` count that climbs with every pass usually means the models are not valid
on this build - see the add-on section above.

**The migration ran twice**
It is idempotent by plate and position, so the second run imported nothing. Confirm with
`/vparkstats`; if the count doubled anyway, `/vparkmigrate rollback` removes everything from
the most recent run.

**A specific vehicle did not come across**
`dry` reports skips by reason but not by row. Find it in your source table and check its model
and position columns by hand; the three reasons a row is skipped are an unusable model, a
position at the origin, and being a duplicate of something v-park already has.

---

## Getting help

Open an issue with:

- the full output of `/vparkmigrate scan` (it contains no personal data)
- the full output of `/vparkmigrate dry`
- your framework and database driver, from `/vparkinfo`

The scan output is almost always enough to see what went wrong.
