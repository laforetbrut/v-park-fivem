--[[
    server/persist.lua

    Turning a vehicle in the world into a row, and doing it as rarely as possible.

    -------------------------------------------------------------------------------------------
    THE DELTA DESIGN, WHICH IS THE WHOLE PERFORMANCE STORY
    -------------------------------------------------------------------------------------------

    A parked car does not change. Its position, its modifications, its damage and its fuel are
    all the same this minute as last minute, and writing them again is a database round trip
    that accomplishes nothing.

    So every vehicle carries a hash of its own state - `Store.hashOf` - and is written when the
    hash moves and not otherwise. A server with three thousand parked cars and nobody driving
    writes zero rows a minute. The same server with forty people driving writes forty.

    The hash deliberately excludes `updated_at`, `touched_at` and `offline_secs`, all of which
    change constantly by design. Including any of them would make every vehicle dirty on every
    sweep, which is exactly the behaviour the hash exists to prevent.

    -------------------------------------------------------------------------------------------
    WHY THE SWEEP IS SLICED
    -------------------------------------------------------------------------------------------

    Hashing everything at once every thirty seconds produces a thirty-second sawtooth: twenty-
    nine seconds of nothing and one spike. `Config.Save.sweepSlices` cuts the tracked set into
    N parts and does one part per tick, N times as often, for the same coverage at a quarter of
    the peak. The database sees a steady trickle instead of a burst.

    -------------------------------------------------------------------------------------------
    WHY THE SERVER ASKS A CLIENT
    -------------------------------------------------------------------------------------------

    Modifications, damage, deformation and fuel cannot be read server-side. There is no native
    for any of them. So the server asks the client nearest a vehicle for a snapshot, in
    batches - one message per client per sweep tick, carrying every vehicle that client is
    near, rather than one message per vehicle.
]]

Persist = {}

-- Outstanding capture requests: token -> { ids, sentAt, src }
local requests = {}
local nextToken = 0

-- Vehicles whose immediate-write cooldown has not expired. id -> tick.
local cooldown = {}

-- The rotating slice cursor for the sweep.
local sliceCursor = 0

local flushing = false

local stats = {
    written = 0,
    batches = 0,
    skipped = 0,
    captures = 0,
    lastFlushMs = 0,
    lastFlushRows = 0,
}

local function saveConfig()
    return (Config and Config.Save) or {}
end

-- ---------------------------------------------------------------------------------------
-- Creating a record from a client report
-- ---------------------------------------------------------------------------------------

--[[
    A client says a vehicle has been parked long enough to matter.

    Everything the client said is re-checked here. The client ran the same rules before
    sending, which is a traffic optimisation and not a trust decision: a modified client can
    send anything, so the server decides again from its own config and its own view of who the
    player is.
]]
RegisterNetEvent('vpark:server:candidate', function(payload)
    local src = source
    if type(payload) ~= 'table' then return end
    if not Runtime.ready() then return end

    --[[
        An ON-ENTRY offer is accepted only for a vehicle that is already the player's.

        The client sends one the moment a player sits in a vehicle it does not already know
        about. Accepting all of them would make the settle timer meaningless - every car
        anybody touches would be kept instantly, including the one they hopped into at a red
        light.

        So the server checks the owned-vehicles table, then the key resource, and ignores the
        offer otherwise. The vehicle still goes through the ordinary settle path when they get
        out.

        `Config.Persistence.ownedImmediately` is the switch, and the client already honours it
        before sending; this is the same check on the side that decides.
    ]]
    if payload.onEntry then
        if not (Config.Persistence and Config.Persistence.ownedImmediately ~= false) then return end

        local plate = Park.plate(payload.plate)
        if not plate then return end

        local row = Bridge.ownedByPlate(plate)
        local owned = row ~= nil and row.owner ~= nil

        -- Or the player holds the keys, which since 1.0.2 is ownership in its own right. See
        -- `Config.Ownership.keysGrantOwnership`: an admin-spawned car, a dealership demo or a
        -- car a mate handed over is theirs, and losing it on a restart was reported as a bug.
        if not owned and Config.Ownership and Config.Ownership.keysGrantOwnership ~= false then
            owned = Ownership.hasKeys(src, payload.plate or plate)
        end

        if not owned then return end

        -- Theirs, and out of the garage. Keep it now.
        Persist.adopt(src, payload)
        return
    end

    Persist.adopt(src, payload)
end)

--[[
    Turn a described vehicle into a persisted record.

    `explicit` forces an ownership kind, and is how `/vpark`, the API and a rental script all
    produce something other than the default resolution.

    Returns the record, or nil and a refusal reason.
]]
function Persist.adopt(src, payload, explicit)
    if type(payload) ~= 'table' or type(payload.model) ~= 'number' then
        return nil, 'refuse.unknown'
    end

    local netId = tonumber(payload.netId)
    if not netId then return nil, 'refuse.unknown' end

    local entity = NetworkGetEntityFromNetworkId(netId)
    if not entity or entity == 0 or not DoesEntityExist(entity) then
        return nil, 'refuse.gone'
    end

    -- Already ours. Not an error: two clients can report the same vehicle, and a player can
    -- run /vpark in a car that is already persisted.
    local existingId = Entity(entity).state['vpark:id']
    if existingId and Store.get(existingId) then
        return Store.get(existingId), nil, true
    end

    --[[
        AN ENTITY WE CREATED IS NEVER A NEW VEHICLE.

        A vehicle of ours that has not been dressed yet carries no `vpark:id` statebag, so a
        player who gets into one during that window looks to the client exactly like somebody
        getting into an ambient car. Adopting it writes a second row for a vehicle that already
        has one, under whatever plate the model happened to spawn with - and then both rows
        stream, and there are two cars.

        Cheap, exact, and it does not depend on the statebag having been set.
    ]]
    if entity and Spawn.owns and Spawn.owns(entity) then
        Park.debug('refusing to adopt entity %d: it is already ours as %s',
            entity, tostring(Spawn.owns(entity)))
        return nil, 'refuse.already_ours'
    end

    local plate = Park.plate(payload.plate)
    local existing = plate and Store.byPlate(plate)
    if existing then
        -- The same plate is already persisted somewhere else. That is either a duplicated
        -- vehicle - which is a problem for whichever resource made two - or the same car
        -- having been re-created without us noticing. Updating the existing record rather
        -- than adding a second is the only answer that cannot produce two of the car.
        Park.debug('plate %s is already persisted as %s - updating it instead of adding a row',
            plate, existing.id)
        Persist.applySnapshot(existing.id, payload)
        return existing
    end

    local owner, ownerType, ownerName, job = Ownership.resolve(plate, src, explicit)

    local position = Park.toVec(payload.position)
    if not position then return nil, 'refuse.unknown' end

    local properties = payload.properties or {}

    local allowed, reason, detail = Rules.check({
        model = payload.model,
        modelName = payload.modelName,
        -- The class comes from the client, which is the only side that can read it. A
        -- payload without one is treated as class 0 rather than refused: the class only
        -- decides expiry and streaming radius, and a wrong default is recoverable where a
        -- refused vehicle is not.
        class = tonumber(payload.class) or 0,
        plate = plate,
        ownership = ownerType,
        bodyHealth = properties.bodyHealth,
        engineHealth = properties.engineHealth,
        position = position,
    })

    if not allowed then
        return nil, reason, detail
    end

    -- The framework says this vehicle is in a garage. Persisting it would produce a car in
    -- the street that the garage also thinks it has, which the player can then take out
    -- twice.
    local lastGarage
    if plate then
        local row = Bridge.ownedByPlate(plate)

        if row then
            if Config.Garages and Config.Garages.respectStoredFlag ~= false and Bridge.isStored(row) then
                return nil, 'refuse.in_garage'
            end

            -- Remember where it came from while the framework still says. Section 9c sends
            -- an idle vehicle back to this garage, and this is the only moment the answer
            -- exists: taking it out clears the column.
            if type(row.garage) == 'string' and row.garage ~= '' then
                lastGarage = row.garage
            end
        end
    end

    -- Ceilings.
    local maximum = tonumber(Config.Persistence.maximumVehicles) or 0
    if maximum > 0 and Store.count() >= maximum then
        if not Lifecycle.evictOldest(nil) then
            return nil, 'refuse.server_full'
        end
    end

    local perCharacter = tonumber(Config.Persistence.maximumPerCharacter) or 0
    if perCharacter > 0 and owner and Store.countOwnedBy(owner) >= perCharacter then
        if (Config.Lifecycle.eviction or 'oldest') == 'refuse' then
            return nil, 'refuse.your_limit'
        end
        if not Lifecycle.evictOldest(owner) then
            return nil, 'refuse.your_limit'
        end
    end

    local rotation = payload.rotation or { x = 0.0, y = 0.0, z = 0.0 }
    local now = Park.now()

    Schema.filter(properties)

    local record = {
        id = Park.id(),
        plate = plate,
        model = payload.model,
        model_name = payload.modelName,
        class = tonumber(payload.class) or 0,
        -- Only ever a string the setter native accepts; see `Classes.setterType`.
        vehicle_type = (type(payload.vehicleType) == 'string'
            and Classes.validSetterTypes[payload.vehicleType]) and payload.vehicleType or nil,
        owner = owner,
        owner_type = ownerType,
        owner_name = ownerName,
        job = job,
        pos_x = Park.coord(position.x),
        pos_y = Park.coord(position.y),
        pos_z = Park.coord(position.z),
        rot_x = Park.angle(rotation.x or 0.0),
        rot_y = Park.angle(rotation.y or 0.0),
        rot_z = Park.angle(rotation.z or 0.0),
        bucket = GetEntityRoutingBucket(entity) or 0,
        interior = tonumber(payload.interior) or 0,
        room = tonumber(payload.room) or 0,
        properties = properties,
        statebags = payload.statebags,
        body_health = tonumber(properties.bodyHealth) or 1000.0,
        engine_health = tonumber(properties.engineHealth) or 1000.0,
        fuel = tonumber(properties.fuelLevel),
        wrecked = (tonumber(properties.engineHealth) or 1000) <= 0,
        offline_secs = 0,
        rental_until = 0,
        last_garage = lastGarage,
        source = explicit and 'manual' or 'auto',
        created_at = now,
        updated_at = now,
        touched_at = now,
        -- Somebody was in it a moment ago; that IS a use. Leaving this at zero would make
        -- every newly parked vehicle look permanently idle to the Section 9c sweep.
        last_used_at = now,
    }

    Persist.guardSize(record)

    Store.add(record, true)

    --[[
        REGISTERED BEFORE IT IS MARKED, AND THE MARKING CANNOT RAISE.

        Same rule as `Spawn.create`, and for the same reason. The statebag write used to come
        first, unprotected, on an entity that belongs to a client - which is the one kind of
        entity whose statebag write can fail. If it raised, the record was in the store and
        nothing was registered as live, so the next streaming pass found a persisted vehicle
        with no entity and CREATED ONE. The player then had two: the car they were sitting in,
        and a copy of it.

        Registering first means the worst case is a vehicle in the world without our statebag
        on it - it is still ours, still saved, still streamed - rather than a duplicate.
    ]]
    Store.setLive(record.id, {
        entity = entity,
        netId = netId,
        placer = src,
        placedAt = Park.ticks(),
        adopted = true,
        -- A player is sitting in it. It exists. See the note in `sweepVanishing`.
        seen = true,
    })

    -- Marking it means the placement code will never delete it as ambient, and a restart can
    -- adopt it rather than duplicating it.
    local marked = pcall(function() Entity(entity).state:set('vpark:id', record.id, true) end)
    if not marked then
        Park.debug('%s was adopted but could not be marked - it is still ours', record.id)
    end

    Park.debug('adopted %s (%s, %s) as %s', record.id, tostring(record.model_name),
        tostring(plate), ownerType)

    if Config.Api and Config.Api.events then
        TriggerEvent('vpark:server:vehicleAdded', record.id, {
            plate = record.plate,
            owner = record.owner,
            ownerType = record.owner_type,
        })
    end

    return record
end

--[[
    Drop a group from a record until it fits the configured row cap.

    A single badly behaved resource can put a hundred kilobytes into a statebag, and one such
    vehicle must not be able to fail a batch insert and take every other vehicle in the batch
    with it. `Schema.fit` decides what goes, in a defined order; this logs what went.
]]
function Persist.guardSize(record)
    local maximum = tonumber(saveConfig().maximumRowBytes) or 0
    if maximum <= 0 then return end

    local encoded = #Park.encode(record.properties)
    if record.statebags then encoded = encoded + #Park.encode(record.statebags) end
    if encoded <= maximum then return end

    -- Statebags first, on their own, because they are another resource's data and the least
    -- ours to keep.
    if record.statebags then
        record.statebags = nil
        if #Park.encode(record.properties) <= maximum then
            Park.warn('%s exceeded %d bytes; its statebags were dropped', record.id, maximum)
            return
        end
    end

    local _, dropped, names = Schema.fit(record.properties, maximum)
    if dropped > 0 then
        Park.warn('%s exceeded %d bytes; dropped: %s', record.id, maximum, table.concat(names, ', '))
    end
end

-- ---------------------------------------------------------------------------------------
-- Snapshots
-- ---------------------------------------------------------------------------------------

--[[
    Fold a client's snapshot into a record.

    Everything is clamped or type-checked, because this is client-supplied data. The worst a
    hostile client can do through here is lie about the state of a vehicle it is standing next
    to, which it could do anyway by driving it - so the checks are about robustness rather
    than about trust.
]]
function Persist.applySnapshot(id, snapshot)
    local record = Store.get(id)
    if not record or type(snapshot) ~= 'table' then return false end

    --[[
        Keep the server's idea of frozen current.

        `Spawn.despawn` reads the final pose only for a vehicle that could have moved, and a
        frozen one provably could not - see the note there. The client is the only thing that
        knows when a vehicle was woken, and this is the message it was already sending.
    ]]
    if type(snapshot.frozen) == 'boolean' then
        local entry = Store.live(id)
        if entry then entry.frozen = snapshot.frozen end
    end

    local patch = {}

    local position = Park.toVec(snapshot.position)
    if position and Park.isFinite(position.x) and Park.isFinite(position.y) and Park.isFinite(position.z) then
        -- A position at the origin is a vehicle whose coordinates were not readable, not a
        -- vehicle at the origin. Writing it would move a car to the middle of the ocean.
        if math.abs(position.x) > 0.5 or math.abs(position.y) > 0.5 then
            patch.pos_x = Park.coord(position.x)
            patch.pos_y = Park.coord(position.y)
            patch.pos_z = Park.coord(position.z)
        end
    end

    local rotation = snapshot.rotation
    if type(rotation) == 'table' then
        patch.rot_x = Park.angle(tonumber(rotation.x) or record.rot_x)
        patch.rot_y = Park.angle(tonumber(rotation.y) or record.rot_y)
        patch.rot_z = Park.angle(tonumber(rotation.z) or record.rot_z)
    end

    if type(snapshot.interior) == 'number' then patch.interior = snapshot.interior end
    if type(snapshot.room) == 'number' then patch.room = snapshot.room end

    --[[
        Fill in the setter type for a row that predates it.

        Written ONCE, when it is missing, and never overwritten: a row that already carries a
        type has one that a client read off the real entity, and there is nothing a later
        capture could improve. This is how rows written before 1.0.4 and rows brought in by the
        Advanced Parking migration stop relying on the class guess - the first time anybody
        drives one, it is corrected for good.
    ]]
    if not record.vehicle_type and type(snapshot.vehicleType) == 'string'
        and Classes.validSetterTypes[snapshot.vehicleType] then
        patch.vehicle_type = snapshot.vehicleType
    end

    if type(snapshot.properties) == 'table' then
        local properties = Schema.filter(snapshot.properties)

        -- A snapshot with no deformation means "not re-read", not "no damage". Keeping the
        -- stored one is what makes `Deformation.shouldRecapture` work: without this line the
        -- drift guard would silently erase every dent it declined to re-measure.
        if properties.deformation == nil and record.properties then
            properties.deformation = record.properties.deformation
        end

        patch.properties = properties
        patch.body_health = tonumber(properties.bodyHealth) or record.body_health
        patch.engine_health = tonumber(properties.engineHealth) or record.engine_health
        patch.fuel = tonumber(properties.fuelLevel)
        patch.wrecked = (tonumber(properties.engineHealth) or 1000) <= 0
    end

    if snapshot.statebags ~= nil then
        patch.statebags = type(snapshot.statebags) == 'table' and snapshot.statebags or nil
    end

    local changed = Store.update(id, patch)

    if changed then
        Persist.guardSize(record)
    end

    return changed
end

--[[
    A client has answered a capture request.
]]
RegisterNetEvent('vpark:server:captured', function(snapshots, token)
    local src = source
    local request = requests[token]

    if not request then return end
    if request.src ~= src then return end

    requests[token] = nil

    if type(snapshots) ~= 'table' then return end

    local changed = 0
    for _, snapshot in ipairs(snapshots) do
        if type(snapshot) == 'table' and type(snapshot.id) == 'string' then
            -- Only vehicles this client was actually asked about. Without this check a client
            -- could volunteer a snapshot for any vehicle on the server.
            if request.allowed[snapshot.id] then
                if Persist.applySnapshot(snapshot.id, snapshot) then
                    changed = changed + 1
                end
            end
        end
    end

    stats.captures = stats.captures + 1
    Park.trace('captured %d vehicle(s) from %d, %d changed', #snapshots, src, changed)
end)

--[[
    Ask a client for snapshots of some vehicles.

    One message per client per tick, carrying every id that client is nearest to. The token
    ties the answer back to the question and bounds what the answer may talk about.
]]
local function requestCapture(src, ids)
    if #ids == 0 then return end

    nextToken = nextToken + 1
    local token = nextToken

    local allowed = {}
    for _, id in ipairs(ids) do allowed[id] = true end

    requests[token] = { src = src, ids = ids, allowed = allowed, sentAt = Park.ticks() }

    TriggerClientEvent('vpark:client:capture', src, ids, token)
end

-- ---------------------------------------------------------------------------------------
-- The sweep
-- ---------------------------------------------------------------------------------------

--[[
    One slice of the live set, hashed and captured.

    Only LIVE vehicles are swept: a vehicle that is not in the world cannot have changed, and
    its row is already what it is. That is what keeps the sweep proportional to how busy the
    server is rather than to how large the table is.
]]
local function sweep()
    local slices = math.max(1, math.floor(tonumber(saveConfig().sweepSlices) or 4))
    sliceCursor = (sliceCursor % slices) + 1

    local players = Spawn.onlinePlayers()
    if #players == 0 then return end

    -- Group the vehicles due this slice by the client nearest them, so each client gets one
    -- message listing everything it is responsible for.
    local perClient = {}
    local index = 0

    for id, entry in pairs(Store.allLive()) do
        index = index + 1

        if (index % slices) + 1 == sliceCursor then
            local record = Store.get(id)

            if record and entry.entity and DoesEntityExist(entry.entity) then
                local best, bestDistance

                for _, player in ipairs(players) do
                    if player.bucket == record.bucket then
                        local dx, dy = player.x - record.pos_x, player.y - record.pos_y
                        local distance = dx * dx + dy * dy
                        if not bestDistance or distance < bestDistance then
                            best, bestDistance = player.src, distance
                        end
                    end
                end

                if best then
                    local list = perClient[best]
                    if not list then
                        list = {}
                        perClient[best] = list
                    end
                    list[#list + 1] = id
                end
            end
        end
    end

    for src, ids in pairs(perClient) do
        requestCapture(src, ids)
    end

    -- Requests nobody answered. A client that disconnected mid-sweep leaves one behind, and
    -- without this the table grows for the life of the server.
    for token, request in pairs(requests) do
        if Park.ticks() - request.sentAt > 30000 then
            requests[token] = nil
        end
    end
end

-- ---------------------------------------------------------------------------------------
-- The flush
-- ---------------------------------------------------------------------------------------

--[[
    Build the upsert for a batch, and collect its parameters.

    Returns `sql, values`.

    -------------------------------------------------------------------------------------------
    WHY A NIL VALUE BECOMES A LITERAL `NULL` IN THE SQL RATHER THAN A `?` AND A NIL PARAMETER
    -------------------------------------------------------------------------------------------

    Most of a vehicle's columns are nullable and most vehicles leave several of them nil:
    `owner_name`, `job`, `statebags`, `trailer_id`, `last_garage`, `model_name` on a server that
    could not resolve one.

    An earlier version appended every value to one flat table with `values[#values + 1] = v`.
    That is broken the moment any `v` is nil, because `#` on a table with a hole is UNDEFINED -
    the length operator may return the index before the hole, after it, or anything between.
    Measured on a real insert: two vehicles produced six correct values followed by a hundred
    and twenty-eight nulls, in the wrong order, and MariaDB answered

        Incorrect integer value: 'MIG00001' for column `v_park_vehicles`.`class`

    because the plate had landed in the class column. Every row in that batch was lost, silently
    apart from that one line, and it would have happened on almost every batch on a live server.

    Writing `NULL` into the statement instead means the parameter list is only ever appended to
    with a non-nil value, so it is dense by construction and the length operator is meaningful
    again. `NULL` is a keyword, not data - nothing operator-supplied or player-supplied reaches
    the statement text.

    RULES.md already said "never a nil in an array literal". This is the same rule, one level
    down, and it is now enforced by construction rather than by remembering.
]]
local function upsertBatch(batch)
    local columns = Store.columns
    local columnCount = #columns

    local quoted = {}
    local updates = {}

    for _, column in ipairs(columns) do
        quoted[#quoted + 1] = ('`%s`'):format(column)

        -- The primary key and the creation time are never updated by an upsert: a row that
        -- already exists keeps the moment it was created, and the id is what matched it.
        if column ~= 'id' and column ~= 'created_at' then
            updates[#updates + 1] = ('`%s` = VALUES(`%s`)'):format(column, column)
        end
    end

    local rows = {}
    local values = {}
    local cursor = 0

    for index = 1, #batch do
        local row = Store.toValues(batch[index])
        local parts = {}

        for column = 1, columnCount do
            local value = row[column]

            if value == nil then
                parts[column] = 'NULL'
            else
                parts[column] = '?'
                cursor = cursor + 1
                values[cursor] = value
            end
        end

        rows[index] = '(' .. table.concat(parts, ', ') .. ')'
    end

    local sql = ('INSERT INTO %s (%s) VALUES %s ON DUPLICATE KEY UPDATE %s'):format(
        Database.table('vehicles'),
        table.concat(quoted, ', '),
        table.concat(rows, ', '),
        table.concat(updates, ', ')
    )

    return sql, values
end

--[[
    Write every dirty vehicle.

    One `INSERT ... ON DUPLICATE KEY UPDATE` per batch. An upsert rather than an update because
    a newly adopted vehicle and a changed one take the same path, and branching on which is
    which is a state to get wrong.

    A row is only cleared from the dirty set when the write SUCCEEDED. A failed batch leaves
    every vehicle in it dirty, and the next flush tries again - which is the correct behaviour
    for a database that has briefly gone away.
]]
--[[
    Write every dirty vehicle without yielding and without awaiting.

    THE SHUTDOWN PATH. `Persist.flush` yields between batches and awaits every statement, and
    neither is safe inside `onResourceStop`: the scheduler may never run again to deliver an
    awaited callback, and a yield at that moment can simply never resume.

    So this builds the same batches and fires them, in one pass, with no yield anywhere. It
    returns how many rows it handed to the driver, which is not quite the same as how many were
    written - but the driver drains its own queue on shutdown, and this is as close to a
    guarantee as the runtime offers.
]]
function Persist.flushNow()
    if not Database.available() then return 0 end

    local dirty, dirtyCount = Store.dirty()
    if dirtyCount == 0 then return 0 end

    local batchSize = math.max(1, math.floor(tonumber(Config.Database.batchSize) or 200))
    local written = 0

    local batch = {}

    local function fireBatch()
        if #batch == 0 then return end

        local sql, values = upsertBatch(batch)

        if Database.fire(sql, values) then
            written = written + #batch
        end

        batch = {}
    end

    for id in pairs(dirty) do
        local record = Store.get(id)
        if record then
            batch[#batch + 1] = record
            if #batch >= batchSize then fireBatch() end
        end
        Store.clearDirty(id)
    end

    fireBatch()

    stats.written = stats.written + written
    return written
end

function Persist.flush(force)
    if flushing and not force then return 0 end
    if not Database.available() then
        -- In memory mode the dirty set has nowhere to go. Clearing it stops it growing
        -- without bound over a long session.
        for id in pairs(Store.dirty()) do Store.clearDirty(id) end
        return 0
    end

    local dirty, dirtyCount = Store.dirty()
    if dirtyCount == 0 then return 0 end

    flushing = true
    local started = Park.ticks()

    local batchSize = math.max(1, math.floor(tonumber(Config.Database.batchSize) or 200))
    local written = 0

    local batch = {}
    local ids = {}

    local function writeBatch()
        if #batch == 0 then return end

        local sql, values = upsertBatch(batch)
        local ok = Database.execute(sql, values) ~= nil

        if ok then
            for _, id in ipairs(ids) do Store.clearDirty(id) end
            written = written + #batch
            stats.batches = stats.batches + 1
        else
            Park.error('a batch of %d vehicle(s) failed to write - they stay queued', #batch)
        end

        batch = {}
        ids = {}
    end

    for id in pairs(dirty) do
        local record = Store.get(id)

        if not record then
            Store.clearDirty(id)
        else
            batch[#batch + 1] = record
            ids[#ids + 1] = id

            if #batch >= batchSize then
                writeBatch()
                Wait(0)
            end
        end
    end

    writeBatch()

    stats.written = stats.written + written
    stats.lastFlushMs = Park.ticks() - started
    stats.lastFlushRows = written

    flushing = false

    if written > 0 then
        Park.trace('flushed %d vehicle(s) in %d ms', written, stats.lastFlushMs)
    end

    return written
end

-- ---------------------------------------------------------------------------------------
-- Immediate triggers
-- ---------------------------------------------------------------------------------------

--[[
    Write one vehicle now, subject to its cooldown.

    The cooldown is what stops a vehicle being rammed repeatedly from writing a row per impact.
    The first write goes through; the rest are collapsed and picked up by the sweep.
]]
function Persist.touch(id, trigger)
    local triggers = saveConfig().triggers or {}
    if trigger and triggers[trigger] == false then return false end

    local record = Store.get(id)
    if not record then return false end

    local cooldownMs = (tonumber(saveConfig().triggerCooldown) or 10) * 1000
    local last = cooldown[id]

    if last and (Park.ticks() - last) < cooldownMs then
        Store.markDirty(id)
        stats.skipped = stats.skipped + 1
        return false
    end

    cooldown[id] = Park.ticks()
    Store.markDirty(id)

    return true
end

--[[
    A player disconnected. Everything they were in gets written where it stands.

    Without this, a crash at 03:00 costs the player their car. It is occasionally written in
    the middle of the motorway, which `Config.Placement` handles far better than losing it
    would be handled.
]]
function Persist.onPlayerDropped(src)
    if not (saveConfig().triggers or {}).onDisconnect then return end

    for id, entry in pairs(Store.allLive()) do
        if entry.placer == src then
            Store.markDirty(id)
        end
    end

    Database.thread(function()
        Persist.flush()
    end)
end

-- ---------------------------------------------------------------------------------------
-- Timers
-- ---------------------------------------------------------------------------------------

CreateThread(function()
    while not Runtime.ready() do Wait(500) end

    local slices = math.max(1, math.floor(tonumber(saveConfig().sweepSlices) or 4))
    local interval = (tonumber(saveConfig().interval) or 30) * 1000 / slices

    while true do
        Wait(interval)

        local ok, err = pcall(sweep)
        if not ok then
            Park.error('the save sweep raised: %s', tostring(err))
            Wait(5000)
        end
    end
end)

CreateThread(function()
    while not Runtime.ready() do Wait(500) end

    while true do
        Wait((tonumber(saveConfig().flushInterval) or 15) * 1000)

        local ok, err = pcall(Persist.flush)
        if not ok then
            Park.error('the flush raised: %s', tostring(err))
            Wait(5000)
        end
    end
end)

function Persist.stats()
    return stats
end
