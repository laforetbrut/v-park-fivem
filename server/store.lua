-- Author: vyrriox
--[[
    server/store.lua

    Every persisted vehicle the server knows about, indexed so that the questions this resource
    asks a thousand times a minute are cheap.

    -------------------------------------------------------------------------------------------
    WHY THERE IS AN IN-MEMORY INDEX AT ALL
    -------------------------------------------------------------------------------------------

    The streaming pass asks, every second, for every online player: which persisted vehicles
    are within 250 metres of this point. Asking the database that is a query per player per
    second forever, and no index makes it free.

    So the table is loaded once at boot and kept in memory. It is not a cache - there is no
    version of this where the database is consulted for a read - it is the working set, and the
    database is where it is written down. A server with twenty thousand vehicles holds perhaps
    twelve megabytes here, which is nothing, and answers every question without leaving Lua.

    -------------------------------------------------------------------------------------------
    THE FOUR INDEXES
    -------------------------------------------------------------------------------------------

        vehicles    id -> record. The authority.
        cells       cell key -> set of ids. The spatial grid; what makes streaming a lookup.
        byPlate     plate -> id. For matching against framework-owned vehicles and for
                    every command that takes a plate.
        byOwner     owner -> set of ids. For per-player limits and `/vparklist`.
        byType      ownership kind -> set of ids. For the sweeps and the panel's filters.

    `byType` was added in 1.0.1. The semi-persistence sweep runs every minute and only ever
    cares about two kinds; without the index it walked every row in the store to find them,
    which on a twenty-thousand vehicle server is twenty thousand iterations a minute to look at
    perhaps forty vehicles.

    Every write goes through `Store.index` and `Store.unindex` so the four cannot drift apart.
    That is the entire reason those two functions exist rather than each caller updating what
    it happens to remember about.
]]

Store = {}

local vehicles = {}
local cells = {}
local byPlate = {}
local byOwner = {}
local byType = {}

local count = 0

-- ids whose row differs from what is in the database. Flushed by `server/persist.lua`.
local dirty = {}
local dirtyCount = 0
local dirtyRevision = 0

-- id -> { entity, netId, placedAt, placer }. Only the vehicles currently in the world.
local live = {}
local liveCount = 0

local function cellSize()
    return tonumber(Config.Streaming and Config.Streaming.cellSize) or 200
end

-- ---------------------------------------------------------------------------------------
-- Indexing
-- ---------------------------------------------------------------------------------------

local function cellOf(record)
    return Park.cellKey(record.pos_x, record.pos_y, cellSize())
end

Store.cellOf = cellOf

local function index(record)
    local cell = cellOf(record)
    record.cell = cell

    local bucket = cells[cell]
    if not bucket then
        bucket = {}
        cells[cell] = bucket
    end
    bucket[record.id] = true

    if record.plate then
        byPlate[record.plate] = record.id
    end

    if record.owner then
        local owned = byOwner[record.owner]
        if not owned then
            owned = {}
            byOwner[record.owner] = owned
        end
        owned[record.id] = true
    end

    local kind = record.owner_type or 'unowned'
    local typed = byType[kind]
    if not typed then
        typed = {}
        byType[kind] = typed
    end
    typed[record.id] = true
    record.indexedType = kind
end

local function unindex(record)
    local bucket = cells[record.cell]
    if bucket then
        bucket[record.id] = nil
        if next(bucket) == nil then cells[record.cell] = nil end
    end

    if record.plate and byPlate[record.plate] == record.id then
        byPlate[record.plate] = nil
    end

    if record.owner then
        local owned = byOwner[record.owner]
        if owned then
            owned[record.id] = nil
            if next(owned) == nil then byOwner[record.owner] = nil end
        end
    end

    -- `indexedType` and not `owner_type`: a record whose kind has just been changed must be
    -- removed from the set it is actually IN, not from the one it is moving to.
    local typed = byType[record.indexedType or record.owner_type or 'unowned']
    if typed then
        typed[record.id] = nil
    end
end

Store.index = index
Store.unindex = unindex

-- ---------------------------------------------------------------------------------------
-- The record
-- ---------------------------------------------------------------------------------------

--[[
    Build a record from a database row.

    The row's column names and the record's field names are the same on purpose. One naming
    scheme means the write path is a straight mapping and there is no translation table to
    fall out of step with the schema.

    `properties` and `statebags` arrive as JSON text and are decoded here, once, rather than on
    every read. That decode is the single most expensive thing about loading, which is why the
    boot loader batches it.
]]
function Store.fromRow(row)
    if type(row) ~= 'table' or not row.id then return nil end

    return {
        id = row.id,
        plate = Park.plate(row.plate),
        model = tonumber(row.model) or 0,
        model_name = row.model_name,
        class = tonumber(row.class) or 0,
        -- Empty string reads as "not captured yet", the same as NULL. See
        -- `Classes.setterType`.
        vehicle_type = (row.vehicle_type ~= '' and row.vehicle_type) or nil,
        owner = row.owner,
        owner_type = row.owner_type or 'unowned',
        owner_name = row.owner_name,
        job = row.job,
        pos_x = tonumber(row.pos_x) or 0.0,
        pos_y = tonumber(row.pos_y) or 0.0,
        pos_z = tonumber(row.pos_z) or 0.0,
        rot_x = tonumber(row.rot_x) or 0.0,
        rot_y = tonumber(row.rot_y) or 0.0,
        rot_z = tonumber(row.rot_z) or 0.0,
        cell = tonumber(row.cell) or 0,
        bucket = tonumber(row.bucket) or 0,
        interior = tonumber(row.interior) or 0,
        room = tonumber(row.room) or 0,
        --[[
            FILTERED ON THE WAY IN, NOT ONLY ON THE WAY OUT.

            A group being off was enforced when a vehicle was first kept and when a client
            reported a change, and nowhere in between - so a row written while a group was ON
            kept its values for good once the group was turned off.

            That is not inert. Turning a group off is what an operator does to stop a group
            misbehaving, and the stale value sits in the row waiting to be handed back the day
            it is turned on again - a value the player never chose, restored months later. It
            also counts towards the row's size budget, and shows up in `/vparkprops` as
            something stored, which reads as the setting not having taken.

            One pass over a table of at most two dozen keys, once per row, at load.
        ]]
        properties = Schema.filter(Park.decode(row.properties) or {}),
        statebags = Park.decode(row.statebags),
        trailer_id = row.trailer_id,
        body_health = tonumber(row.body_health) or 1000.0,
        engine_health = tonumber(row.engine_health) or 1000.0,
        fuel = tonumber(row.fuel),
        wrecked = tonumber(row.wrecked) == 1,
        offline_secs = tonumber(row.offline_secs) or 0,
        rental_until = tonumber(row.rental_until) or 0,
        hash = tonumber(row.hash) or 0,
        source = row.source or 'auto',
        created_at = tonumber(row.created_at) or 0,
        updated_at = tonumber(row.updated_at) or 0,
        touched_at = tonumber(row.touched_at) or 0,
        last_used_at = tonumber(row.last_used_at) or 0,
        last_garage = row.last_garage,
    }
end

--[[
    The values that go into an INSERT or UPDATE, in a fixed order.

    Fixed because the batch writer builds one statement with N sets of placeholders, and every
    row must contribute its values in the same order. A table iteration would not guarantee
    that; a list does.

    THIS LIST CONTAINS NILS, AND THAT IS NOT A DEFECT. Most vehicles leave `owner_name`, `job`,
    `statebags`, `trailer_id` and `last_garage` empty, and a nil is how a NULL column is
    expressed here.

    So it must be read BY INDEX, from 1 to `#Store.columns`, and never with `ipairs` or `#`.
    `ipairs` stops at the first hole and `#` is undefined over one. `upsertBatch` in
    server/persist.lua is the only caller and its header carries the full account of what
    happened when this was got wrong.
]]
Store.columns = {
    'id', 'plate', 'model', 'model_name', 'class', 'vehicle_type',
    'owner', 'owner_type', 'owner_name', 'job',
    'pos_x', 'pos_y', 'pos_z', 'rot_x', 'rot_y', 'rot_z',
    'cell', 'bucket', 'interior', 'room',
    'properties', 'statebags', 'trailer_id',
    'body_health', 'engine_health', 'fuel', 'wrecked',
    'offline_secs', 'rental_until',
    'hash', 'source', 'created_at', 'updated_at', 'touched_at',
    'last_used_at', 'last_garage',
}

function Store.toValues(record)
    return {
        record.id,
        record.plate,
        record.model,
        record.model_name,
        record.class,
        record.vehicle_type,
        record.owner,
        record.owner_type,
        record.owner_name,
        record.job,
        record.pos_x, record.pos_y, record.pos_z,
        record.rot_x, record.rot_y, record.rot_z,
        record.cell, record.bucket, record.interior, record.room,
        Park.encode(record.properties),
        record.statebags and Park.encode(record.statebags) or nil,
        record.trailer_id,
        record.body_health, record.engine_health, record.fuel,
        record.wrecked and 1 or 0,
        record.offline_secs or 0,
        record.rental_until or 0,
        record.hash, record.source,
        record.created_at, record.updated_at, record.touched_at,
        record.last_used_at or 0, record.last_garage,
    }
end

--[[
    The hash that decides whether a vehicle needs writing.

    DELIBERATELY NOT EVERYTHING. Position, rotation, the property table, health, fuel and
    ownership are in it. `updated_at`, `touched_at`, `last_used_at` and `offline_secs` are
    NOT: they change constantly by design, and including them would make every vehicle dirty
    on every sweep, which is exactly the behaviour the hash exists to avoid.

    `touched_at` still gets written, on its own cheap path, when a player actually touches
    something. That is a targeted single-column update rather than a full row.
]]
function Store.hashOf(record)
    return Park.hash({
        plate = record.plate, model = record.model, modelName = record.model_name,
        class = record.class, ownerName = record.owner_name, source = record.source,
        p = { record.pos_x, record.pos_y, record.pos_z },
        r = { record.rot_x, record.rot_y, record.rot_z },
        b = record.bucket,
        i = record.interior,
        m = record.room,
        o = record.owner,
        t = record.owner_type,
        -- In the hash, or the backfill in `Persist.applySnapshot` would update the record in
        -- memory and never mark it dirty, so the column would be re-guessed from the class on
        -- every restart forever. Adding it also means the first boot after upgrading writes
        -- every row once, which is how the column gets filled in at all.
        vt = record.vehicle_type,
        j = record.job,
        h = { record.body_health, record.engine_health },
        f = record.fuel,
        w = record.wrecked,
        pr = record.properties,
        sb = record.statebags,
        tr = record.trailer_id,
        ru = record.rental_until,
        lg = record.last_garage,
    })
end

-- ---------------------------------------------------------------------------------------
-- Reading
-- ---------------------------------------------------------------------------------------

function Store.get(id)
    return vehicles[id]
end

function Store.count()
    return count
end

function Store.liveCount()
    return liveCount
end

function Store.all()
    return vehicles
end

function Store.byPlate(plate)
    local normalised = Park.plate(plate)
    if not normalised then return nil end
    local id = byPlate[normalised]
    return id and vehicles[id] or nil
end

function Store.ownedBy(owner)
    local out = {}
    local owned = byOwner[owner]
    if not owned then return out end

    for id in pairs(owned) do
        local record = vehicles[id]
        if record then out[#out + 1] = record end
    end

    return out
end

function Store.countOwnedBy(owner)
    local owned = byOwner[owner]
    if not owned then return 0 end
    return Park.count(owned)
end

--[[
    Every record of a given ownership kind.

    What the semi-persistence sweep walks instead of the whole store, and what the panel's
    ownership filters use. `kinds` is a list, so the sweep asks for `{ 'job', 'rental' }` in one
    call rather than iterating twenty thousand rows to find forty.
]]
function Store.ofTypes(kinds)
    local out = {}
    local count = 0

    for _, kind in ipairs(kinds) do
        local typed = byType[kind]
        if typed then
            for id in pairs(typed) do
                local record = vehicles[id]
                if record then
                    count = count + 1
                    out[count] = record
                end
            end
        end
    end

    return out, count
end

function Store.countOfType(kind)
    local typed = byType[kind]
    if not typed then return 0 end
    return Park.count(typed)
end

--[[
    Resolve a vehicle from whatever an operator typed.

    An id, a plate, or the id of a vehicle the player is looking at - handled by the caller.
    Ids are 12 to 14 characters of base 36 and plates are at most 8, so the two are
    distinguishable, but an exact id match is tried first regardless because a plate that
    happens to look like an id is somebody's problem and should not be ambiguous.
]]
function Store.resolve(reference)
    if type(reference) ~= 'string' or reference == '' then return nil end

    local direct = vehicles[reference:upper()]
    if direct then return direct end

    direct = vehicles[reference]
    if direct then return direct end

    return Store.byPlate(reference)
end

--[[
    Every persisted vehicle within `radius` of a point, in one routing bucket.

    THE HOT PATH. Called once per online player per streaming pass.

    The grid narrows to a 3x3 block of cells - nine table lookups - and only the vehicles
    inside those cells get a distance computation. On a map-wide table of twenty thousand
    vehicles, a query near Legion Square touches perhaps forty.

    Flat distance, not 3D: the grid is flat, and a vehicle thirty metres below the player in a
    car park is in the same cell and should be considered. The caller applies a 3D check when
    it needs one.
]]
function Store.near(x, y, radius, bucket)
    local out = {}
    local size = cellSize()
    local radiusSq = radius * radius

    for _, key in ipairs(Park.cellsAround(x, y, radius, size)) do
        local bucketCell = cells[key]
        if bucketCell then
            for id in pairs(bucketCell) do
                local record = vehicles[id]
                if record and (bucket == nil or record.bucket == bucket) then
                    local dx, dy = record.pos_x - x, record.pos_y - y
                    local distanceSq = dx * dx + dy * dy
                    if distanceSq <= radiusSq then
                        out[#out + 1] = { record = record, distanceSq = distanceSq }
                    end
                end
            end
        end
    end

    return out
end

-- ---------------------------------------------------------------------------------------
-- Writing
-- ---------------------------------------------------------------------------------------

function Store.markDirty(id)
    if not vehicles[id] then return end
    dirtyRevision = dirtyRevision + 1
    if not dirty[id] then dirtyCount = dirtyCount + 1 end
    -- A write acknowledgment clears only the revision that it actually serialized.
    dirty[id] = dirtyRevision
end

function Store.dirty()
    return dirty, dirtyCount
end

function Store.clearDirty(id, revision)
    if not dirty[id] or (revision ~= nil and dirty[id] ~= revision) then return end
    dirty[id] = nil
    dirtyCount = dirtyCount - 1
end

--[[
    Add a record that is not yet in the store.

    `fresh` says whether it needs an INSERT rather than an UPDATE. The loader passes false; a
    newly parked vehicle passes true.
]]
function Store.add(record, fresh)
    if type(record) ~= 'table' or not record.id then return nil end
    if vehicles[record.id] then return vehicles[record.id] end

    local now = Park.now()
    record.created_at = record.created_at ~= 0 and record.created_at or now
    record.updated_at = record.updated_at ~= 0 and record.updated_at or now
    record.touched_at = record.touched_at ~= 0 and record.touched_at or now
    -- A vehicle that has just been parked HAS been used: somebody was in it a moment ago.
    -- Starting this at zero would make every newly adopted vehicle instantly overdue for the
    -- cleanup sweep, which is the sort of bug that removes a thousand cars at 4am.
    record.last_used_at = (record.last_used_at or 0) ~= 0 and record.last_used_at or now

    vehicles[record.id] = record
    count = count + 1

    index(record)

    if fresh then
        record.hash = Store.hashOf(record)
        Store.markDirty(record.id)
    end

    return record
end

--[[
    Apply a patch to a record and re-index if anything indexed changed.

    Returns whether the record is now different from what the database holds, so the caller can
    decide whether it is worth a write. The hash is computed here and nowhere else.
]]
function Store.update(id, patch)
    local record = vehicles[id]
    if not record then return false end
    if type(patch) ~= 'table' then return false end

    local reindex = false

    if patch.pos_x ~= nil or patch.pos_y ~= nil then reindex = true end
    if patch.plate ~= nil and patch.plate ~= record.plate then reindex = true end
    if patch.owner ~= nil and patch.owner ~= record.owner then reindex = true end
    if patch.owner_type ~= nil and patch.owner_type ~= record.owner_type then reindex = true end

    if reindex then unindex(record) end

    for key, value in pairs(patch) do
        record[key] = value
    end

    if reindex then index(record) end

    local hash = Store.hashOf(record)
    if hash ~= record.hash then
        record.hash = hash
        record.updated_at = Park.now()
        Store.markDirty(id)
        return true
    end

    return false
end

--[[
    Remove a record from the store.

    Does NOT delete the row: `server/lifecycle.lua` owns that, because a removal has to decide
    between the trash, the garage and an impound, and this file has no business knowing about
    any of them.
]]
function Store.remove(id)
    local record = vehicles[id]
    if not record then return nil end

    unindex(record)
    vehicles[id] = nil
    count = count - 1

    Store.clearDirty(id)
    Store.setLive(id, nil)

    return record
end

-- ---------------------------------------------------------------------------------------
-- What is in the world
-- ---------------------------------------------------------------------------------------

--[[
    ================================================================================================
    WHAT A LIVE ENTRY IS ALLOWED TO CARRY, AND WHO IS ALLOWED TO SAY SO
    ================================================================================================

    A live entry is the server's record of a vehicle that exists in the world right now. It is
    created by `Store.setLive` and then written to, in place, by `server/spawn.lua` - and only by
    `server/spawn.lua`, which is checked.

    THIS LIST EXISTS BECAUSE THE FIELDS ON IT HAVE COST THREE RELEASES BETWEEN THEM.

    1.0.14 set `driven` to record that a vehicle had been used, not knowing that `driven` was
    also the flag permitting the despawn to re-read the entity's position - so the correct parked
    position was written and then overwritten with a stale one seconds later. One word doing two
    jobs, and the second job undid the first.

    That is not a mistake anybody makes reading thirteen undocumented booleans off a table. So
    each one is written down here with who sets it, who reads it, and what clears it, and
    `tools/check.py` group 16 fails the build on any field that is not.

    ------------------------------------------------------------------------------------------
    IDENTITY - set once at creation, never changed
    ------------------------------------------------------------------------------------------

    entity        The script handle. `Spawn.create` writes it before anything else can happen to
                  the vehicle; nothing else ever writes it.
    netId         The network id, needed to address a client. Written by `dress` once the entity
                  is configured, and by `Persist.adopt` for a vehicle that already existed.
    placer        The client nominated to dress and place it. Read when re-sending a restore and
                  when telling that client to forget the vehicle.
    placedAt      When it was created. Diagnostics only.
    spawnX        Where the server created it, which is the value a stale server-side read
    spawnY        returns - so it is what makes a stale read detectable. Written by
    spawnZ        `Spawn.create`, and again whenever a vehicle is recorded as having been moved
                  without being driven, because otherwise `poseIfFresh` keeps measuring against
                  the original spot and every later sweep rewrites the same row. Read only by
                  `poseIfFresh`. Absent on an adopted vehicle,
                  because the server did not place that one.
    adopted       True when the vehicle already existed and we took it over, rather than having
                  created it. Distinguishes the two paths in the panel and the logs.

    ------------------------------------------------------------------------------------------
    PROGRESS - how far through being restored it is
    ------------------------------------------------------------------------------------------

    ready         Dressed, addressable, and handed to a client. Set by `dress`.
    seen          The entity has been observed to exist at least once. REQUIRED before the
                  lifecycle sweep may conclude something else deleted it - an orphaned setter
                  entity answers false to `DoesEntityExist` by design, and without this a vehicle
                  that had not reached a client yet would have its row deleted.
    restoreAt     Tick at which to send the restore instruction again, after a client answered
                  that it could not take network control. Cleared when it is sent or succeeds.
    restoreTries  How many times that has happened. Capped at three.

    ------------------------------------------------------------------------------------------
    POSITION - who is allowed to say where this vehicle is
    ------------------------------------------------------------------------------------------

    These four decide whether the despawn re-reads the entity's pose, and they are the ones to
    think hardest about. The rule they encode: THE STORED POSITION CHANGES WHEN A PERSON MOVES
    THE VEHICLE, AND NOT OTHERWISE.

    frozen        Whether the vehicle is frozen. A frozen vehicle cannot have moved. Set from the
                  placement result and updated from every snapshot.
    driven        Somebody has sat in it since it was restored. Waking is not driving: every
                  vehicle near a player is woken, and a woken vehicle is simulated and rolls.
                  Only this permits a pose to be read back.
    parked        The client that was driving has reported the final pose. That report is better
                  information than anything the server can read, so it BLOCKS the despawn read
                  entirely. Cleared when somebody gets in again.
    nudged        The placement stood the vehicle aside because its bay was occupied. It is not
                  where it belongs, so its position must not be written down. Cleared when
                  somebody drives it.

    ------------------------------------------------------------------------------------------
    AUTHORSHIP - who is allowed to speak for this vehicle
    ------------------------------------------------------------------------------------------

    unverifiedNeons
                  Set for every saved neon selection during restore. Cleared by a successful
                  restore acknowledgment or matching proof from the current network owner. While it is set,
                  `Persist.applySnapshot` drops the neon keys from any snapshot, so a vehicle that
                  came back dark cannot write that failure over the player's own value. It lives
                  here rather than on the client because the capture is asked of whichever client is
                  nearest, and only the server has one view of that.

    restoredHealth
                  What body health the vehicle settled at after the restore had put its stored
                  damage back on it, reported by the placing client and sent to whichever client
                  the capture sweep asks. It is LOWER than the stored number by design: broken
                  windows, burst tyres and deformed panels are what the engine derives body health
                  from, so a car stored at 600 reads below 600 once its own damage exists again.
                  Both drift guards measure against it - the deformation's and the health group's -
                  because a client comparing live health against the STORED number would see the
                  gap the restore itself opened, call it new damage, and write the lower value
                  down. Absent until a restore reports one, and `record.body_health` is the
                  fallback.

    undressed     Set when a restore is sent, and cleared when the placing client reports that the
                  properties actually went on. While it is set, `Persist.applySnapshot` ignores the
                  properties in EVERY snapshot, whoever sent it - a vehicle that has been created
                  but not yet dressed is a stock car, and a capture of it would overwrite the
                  modifications it is about to be given. Same argument as `unverifiedNeons` and the
                  same reason for living here: the capture is asked of whichever client is nearest,
                  and only that client's own restore book knows what it has dressed. A restore that
                  reports `dressed = false` leaves it set, because the vehicle really is stock and
                  the next restore is what fixes that, not a capture.

    occupant      The player the server watched get into it, set by `vpark:server:touched` only
                  after reading, on the server, that their ped was within ten metres of the
                  entity. It is the fallback proof for a parked report that arrives after every
                  client has lost scope, at which point there is nothing left to measure. An id
                  is not a secret - `vpark:id` is replicated - so a handler that takes one on
                  trust lets any client speak for any vehicle it has ever seen.
]]
Store.liveFields = {
    entity = true, netId = true, placer = true, placedAt = true, adopted = true,
    spawnX = true, spawnY = true, spawnZ = true,
    ready = true, seen = true, restoreAt = true, restoreTries = true,
    frozen = true, driven = true, parked = true, nudged = true,
    occupant = true,
    unverifiedNeons = true, undressed = true, restoredHealth = true,
}

function Store.setLive(id, entry)
    if live[id] and not entry then
        live[id] = nil
        liveCount = liveCount - 1
    elseif not live[id] and entry then
        live[id] = entry
        liveCount = liveCount + 1
    elseif entry then
        live[id] = entry
    end
end

function Store.live(id)
    return live[id]
end

function Store.allLive()
    return live
end

function Store.isLive(id)
    return live[id] ~= nil
end

-- ---------------------------------------------------------------------------------------
-- Loading
-- ---------------------------------------------------------------------------------------

--[[
    Read the whole table into memory, in pages.

    Paged rather than one `SELECT *` because a table with twenty thousand rows and a property
    blob each is roughly forty megabytes of result, and some MySQL drivers hand that back as
    one allocation that stalls the server thread for several seconds during boot.

    Rows whose model is not valid on this game build are loaded but flagged. They are never
    spawned - there is nothing to spawn - and they are not deleted either, because the usual
    reason a model is invalid is an add-on that is temporarily out of the resources folder,
    and deleting a player's car because a stream failed to start is unforgivable.
]]
function Store.load()
    if not Database.available() then
        Park.warn('running in memory: nothing was loaded and nothing will be saved')
        return 0
    end

    local page = 0
    local pageSize = 1000
    local loaded = 0
    local invalid = 0

    while true do
        local rows = Database.query(
            ('SELECT * FROM %s ORDER BY `id` LIMIT ? OFFSET ?'):format(Database.table('vehicles')),
            { pageSize, page * pageSize }
        )

        if type(rows) ~= 'table' or #rows == 0 then break end

        for _, row in ipairs(rows) do
            local record = Store.fromRow(row)
            if record then
                --[[
                    Is the model real on this build?

                    `IsModelValid` is a CLIENT native. On the server it is nil, so the check
                    degrades to "we cannot know", which is the honest answer: the server has
                    no model index and never has. On a build that does expose it, the answer
                    is used; on one that does not, nothing is flagged and nothing is lost -
                    the streaming pass simply fails to create the vehicle and says so once.
                ]]
                if IsModelValid and not IsModelValid(record.model) then
                    record.invalidModel = true
                    invalid = invalid + 1
                end

                Store.add(record, false)
                loaded = loaded + 1
            end
        end

        page = page + 1

        -- Yield between pages. A boot that blocks the server thread for four seconds looks
        -- like a crash to txAdmin and to anybody watching the console.
        Wait(0)
    end

    if invalid > 0 then
        Park.warn('%d vehicle(s) reference a model this game build does not have', invalid)
        Park.warn('they are kept, not deleted - the usual cause is an add-on that is not started')
    end

    Park.log('loaded %d vehicle(s) into %d grid cell(s)', loaded, Park.count(cells))

    return loaded
end

-- ---------------------------------------------------------------------------------------
-- Statistics
-- ---------------------------------------------------------------------------------------

function Store.stats()
    local byType = {}
    local wrecked = 0
    local invalid = 0

    for _, record in pairs(vehicles) do
        byType[record.owner_type] = (byType[record.owner_type] or 0) + 1
        if record.wrecked then wrecked = wrecked + 1 end
        if record.invalidModel then invalid = invalid + 1 end
    end

    return {
        total = count,
        live = liveCount,
        dirty = dirtyCount,
        cells = Park.count(cells),
        byType = byType,
        wrecked = wrecked,
        invalidModel = invalid,
    }
end
