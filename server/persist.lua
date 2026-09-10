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

-- Vehicles with a write already scheduled for the end of their cooldown. See `Persist.touch`.
local deferred = {}

-- The rotating slice cursor for the sweep.
local sliceCursor = 0

local flushing = false

local stats = {
    -- See `Park.timing`: the average and the worst case of the capture sweep, which is the
    -- loop that touches every live vehicle.
    sweepMs = Park.timing(),

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
--[[
    ================================================================================================
    WHY A VEHICLE WAS NOT KEPT
    ================================================================================================

    Every refusal in this file used to be a bare `return`. A vehicle that was not kept produced no
    log line, no message and no record of any kind, so the only report available to anybody was
    "it did not work" - and the only answer available to me was a guess. This resource has already
    paid for that once: five releases of theories about vehicles being in the wrong place ended the
    day `/vparkwhere` printed a number.

    So every refusal is written down here with its reason, and `/vparkdiag` prints the last of
    them. One command after the thing that did not work, and the guessing is over.

    A ring of the last few, not a growing list: this is a diagnostic for something that just
    happened, and a table that grows for the life of the server is a leak.
]]
local refusals = {}
local REFUSAL_MEMORY = 25

local function refused(src, payload, reason, detail)
    local plate = type(payload) == 'table' and payload.plate or nil

    refusals[#refusals + 1] = {
        at = Park.now(),
        src = src,
        who = Bridge.name and Bridge.name(src) or tostring(src),
        plate = type(plate) == 'string' and plate or '?',
        model = type(payload) == 'table' and payload.modelName or '?',
        reason = reason or 'refuse.unknown',
        detail = detail,
    }

    while #refusals > REFUSAL_MEMORY do table.remove(refusals, 1) end

    Park.debug('not keeping %s (%s) for %s: %s%s',
        tostring(plate), tostring(type(payload) == 'table' and payload.modelName or '?'),
        tostring(src), tostring(reason), detail and (' - ' .. tostring(detail)) or '')

    return nil, reason, detail
end

-- The last refusals, newest first. `/vparkdiag` prints them.
function Persist.refusals()
    local out = {}
    for index = #refusals, 1, -1 do out[#out + 1] = refusals[index] end
    return out
end

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
        if not (Config.Persistence and Config.Persistence.ownedImmediately ~= false) then
            return refused(src, payload, 'refuse.owned_immediately_off')
        end

        local plate = Park.plate(payload.plate)
        if not plate then return refused(src, payload, 'refuse.no_plate') end

        local row = Bridge.ownedByPlate(plate)
        local owned = row ~= nil and row.owner ~= nil

        -- Or the player holds the keys, which since 1.0.2 is ownership in its own right. See
        -- `Config.Ownership.keysGrantOwnership`: an admin-spawned car, a dealership demo or a
        -- car a mate handed over is theirs, and losing it on a restart was reported as a bug.
        if not owned and Config.Ownership and Config.Ownership.keysGrantOwnership ~= false then
            owned = Ownership.hasKeys(src, payload.plate or plate)
        end

        --[[
            NOT THEIRS AS FAR AS THE FRAMEWORK KNOWS, WHICH IS THE ORDINARY CASE.

            Somebody sitting in a car they do not own, which is most cars. Recorded rather than
            logged loudly, because the vehicle still goes through the settle path on exit and
            nothing has gone wrong - but it is also the exact answer to "I bought a car and it was
            not kept", so it must be findable.

            `detail` names the table that was consulted, because when the answer is wrong it is
            usually the schema and not the row.
        ]]
        if not owned then
            return refused(src, payload, 'refuse.not_owned',
                (Bridge.ownedTable() or {}).table or 'no owned table detected')
        end

        -- Theirs, and out of the garage. Keep it now.
        local record, reason, detail = Persist.adopt(src, payload)
        if not record then return refused(src, payload, reason, detail) end
        return
    end

    local record, reason, detail = Persist.adopt(src, payload)
    if not record then return refused(src, payload, reason, detail) end
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

    --[[
        ============================================================================================
        THE POSITION IN THE MESSAGE MUST BE WHERE THE ENTITY ACTUALLY IS.
        ============================================================================================

        The position is the value that becomes a row, and it comes from the client. Without checking
        it, a player beside any adoptable vehicle could register that vehicle as persisted AT
        COORDINATES OF THEIR CHOOSING, anywhere on the map, permanently: inside a wall, under the
        sea, in the sky. Both sides of the comparison here are read on the server, so neither is a
        value the client chose.

        The payload was generated from this very entity, so an honest offer is within centimetres.
        Ten metres allows for the vehicle rolling between the client building the message and the
        server reading it.

        --------------------------------------------------------------------------------------------
        AND WHY THE PLAYER'S OWN POSITION IS NO LONGER PART OF IT
        --------------------------------------------------------------------------------------------

        1.0.19 also required the offering PLAYER to be within fifteen metres of the entity. That was
        a mistake, and its shape is one this project keeps making: IT DEPENDS ON A POSITION THE
        SERVER MAY NOT HAVE YET.

        A ped's position reaches the server by sync. A vehicle bought from a dealership is spawned
        at the shop's spawn point while the buyer is still standing in the showroom, and
        `TaskWarpPedIntoVehicle` moves them on the client with the server finding out afterwards -
        a gap wider than fifteen metres in qb-vehicleshop's own config. So a legitimate purchase
        could be refused for being too far from the car the player was sitting in.

        It also bought almost nothing. Adopting a vehicle does not make it the offerer's -
        `Ownership.resolve` reads the owner from the framework row - so the worst a distant offer
        could do was keep a car that would have been kept anyway.

        A weaker check that cannot refuse an honest purchase beats a stronger one that can.
    ]]
    local claimed = Park.toVec(payload.position)
    local actually = Spawn.entityPosition and Spawn.entityPosition(entity) or nil

    local trusted = claimed

    if claimed and actually then
        local dx = claimed.x - actually.x
        local dy = claimed.y - actually.y
        local dz = claimed.z - actually.z

        --[[
            DISAGREEMENT CORRECTS THE VALUE. IT DOES NOT REFUSE THE VEHICLE.

            1.0.19 and 1.0.20 both refused here, and refusing was wrong for the same reason twice:
            A REFUSAL LOSES A VEHICLE, AND EVERY OTHER OUTCOME DOES NOT. The server's reading can
            be stale - it is maintained by the entity's network owner, and for a vehicle another
            resource created with the setter native it can sit at the spawn point indefinitely -
            so a disagreement is at least as likely to mean `the server is behind` as `the client
            is lying`, and one of those two readings is not worth a car.

            So the unforgeable value wins and the vehicle is kept either way. The exploit this
            exists for - registering a vehicle at coordinates of the sender's choosing - is
            stopped just as dead by ignoring the claim as by refusing the offer. And if the server
            reading was the stale one, the first capture after somebody drives the car corrects it,
            which is a self-healing wrong answer rather than a missing car.
        ]]
        if (dx * dx + dy * dy + dz * dz) > (10.0 * 10.0) then
            Park.debug('%s was offered %.0f m from where the server reads it - using the server',
                tostring(payload.plate), math.sqrt(dx * dx + dy * dy + dz * dz))
            trusted = actually
        end
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
        -- `true`: the position in this payload was measured against the entity above, so it may
        -- say where the vehicle is. Without that, a plate collision would be a way to move a car
        -- that the driven rule in `applySnapshot` would otherwise refuse.
        Persist.applySnapshot(existing.id, payload, true)
        return existing
    end

    local owner, ownerType, ownerName, job = Ownership.resolve(plate, src, explicit)

    -- `trusted`, not the payload: see the note above about which reading wins when they disagree.
    local position = trusted
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
        -- A player is sitting in it. It exists, and it has been driven - both of which the
        -- despawn needs before it will read a final pose back. See `Spawn.despawn`.
        seen = true,
        driven = true,
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
--[[
    `proven` says the caller has already established that whoever supplied this snapshot is
    entitled to say where the vehicle is. Only `Persist.adopt` passes it, and only after checking
    that the player offering the vehicle is standing next to the entity they are offering.

    Everything else leaves it out, and then the position is accepted ONLY for a vehicle the server
    itself believes somebody has driven. See the note over the position below for why that matters.
]]
function Persist.applySnapshot(id, snapshot, proven, src)
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

    --[[
        ================================================================================================
        A PARKED VEHICLE'S POSITION CANNOT BE CHANGED THROUGH A CAPTURE. NOT BY ANYBODY.
        ================================================================================================

        The client already works this way and says so in `Stream.snapshot`: position and rotation are
        omitted entirely until somebody has sat in the vehicle, because every vehicle near a player
        is woken, a woken vehicle is simulated, and a simulated vehicle on a camber rolls. The
        stored position answers `where did somebody leave this`, and only a person driving it can
        change that answer.

        THAT RULE WAS ONLY EVER ENFORCED ON THE CLIENT, which means it was not enforced. The server
        asks a client for snapshots of every vehicle near it and hands over the list of ids to
        report on - so a modified client did not even need to know an id to relocate a stranger's
        parked car to anywhere on the map. It is the hole 1.0.17 closed in the parked report,
        reached through a different door, and a wider one: there, an id had to be known.

        So the same rule, on the side that decides. A position is accepted when the server itself
        believes the vehicle has been driven - and getting in has been proven since 1.0.17 - or when
        the caller has proven the reporter's standing some other way.

        This changes no honest behaviour whatsoever. It is the client's own documented rule, written
        where a lie cannot get past it.
    ]]
    local live = Store.live(id)
    local mayMove = proven == true or (live ~= nil and live.driven == true)

    local position = mayMove and Park.toVec(snapshot.position) or nil
    if position and Park.isFinite(position.x) and Park.isFinite(position.y) and Park.isFinite(position.z) then
        -- A position at the origin is a vehicle whose coordinates were not readable, not a
        -- vehicle at the origin. Writing it would move a car to the middle of the ocean.
        if math.abs(position.x) > 0.5 or math.abs(position.y) > 0.5 then
            --[[
                A MOVE OF A FEW CENTIMETRES IS NOT A MOVE.

                A vehicle that has been woken - which every vehicle near a player has been - is
                simulated again, and simulation settles it. Measured with `/vparkwhere` on cars
                that had been restored correctly: seventeen millimetres on one, three on
                another. Each of those was being written back as the new truth, and the next
                restore put the car there, and it settled again.

                Individually invisible and cumulatively exactly the complaint: "it is not quite
                where I left it". A stored position should change when somebody DRIVES the car,
                not because physics breathed on it.

                Five centimetres is below anything a person can see and far above anything
                settling produces. A genuine drive clears it in the first metre.
            ]]
            local moved = math.abs(position.x - (record.pos_x or 0.0))
                + math.abs(position.y - (record.pos_y or 0.0))
                + math.abs(position.z - (record.pos_z or 0.0))

            if moved > 0.05 then
                patch.pos_x = Park.coord(position.x)
                patch.pos_y = Park.coord(position.y)
                patch.pos_z = Park.coord(position.z)
            end
        end
    end

    --[[
        The same argument as the position, one line up.

        A vehicle settling on its suspension changes its pitch and roll by fractions of a
        degree, and writing that back means the next restore sets a rotation the car will
        settle out of again. Half a degree is well under what anybody can see and well over
        anything settling produces.
    ]]
    -- The same gate. A rotation is a pose too, and a car spun in place is still a car moved.
    local rotation = mayMove and snapshot.rotation or nil
    if type(rotation) == 'table' then
        local turned = math.abs(Park.angleDelta(tonumber(rotation.x) or record.rot_x, record.rot_x))
            + math.abs(Park.angleDelta(tonumber(rotation.y) or record.rot_y, record.rot_y))
            + math.abs(Park.angleDelta(tonumber(rotation.z) or record.rot_z, record.rot_z))

        if turned > 0.5 then
            patch.rot_x = Park.angle(tonumber(rotation.x) or record.rot_x)
            patch.rot_y = Park.angle(tonumber(rotation.y) or record.rot_y)
            patch.rot_z = Park.angle(tonumber(rotation.z) or record.rot_z)
        end
    end

    --[[
        ================================================================================================
        SOMETHING CARRIED IT SOMEWHERE ELSE WITHOUT ANYBODY DRIVING IT.
        ================================================================================================

        A tow truck, a cargobob, a forklift, another car shoving it, a player pushing it out of a
        doorway. All deliberate, none of them involves sitting in the vehicle, and all of them were
        undone at the next restart because `mayMove` above is the only door a position had.

        The rule `mayMove` protects is worth keeping: a woken vehicle is simulated, one on a camber
        rolls, and a stored position should answer "where did somebody leave this". A DISTANCE tells
        a roll from a tow without needing to know which happened - centimetres against the length of
        a street - and it is checked here, on the side that decides, against what is stored.

        Two things bound what a modified client can do with this. The reporter has already been
        proven to be near the ENTITY by the caller, and the position they describe has to be
        somewhere they are actually standing, which the server reads off their own ped. So the worst
        available abuse is moving a car you are standing next to, to where you are standing - which
        is what driving it would achieve anyway, and slower.
    ]]
    local resting = snapshot.resting

    if not patch.pos_x and type(resting) == 'table'
        and type(resting.x) == 'number' and type(resting.y) == 'number'
        and type(resting.z) == 'number' then

        local threshold = tonumber((Config.Streaming or {}).movedThreshold) or 10.0

        if threshold > 0 then
            local dx = resting.x - (record.pos_x or 0.0)
            local dy = resting.y - (record.pos_y or 0.0)
            local dz = resting.z - (record.pos_z or 0.0)

            if (dx * dx + dy * dy + dz * dz) >= (threshold * threshold) then
                local here = proven == true or src == nil
                    or (Spawn.playerIsNearPosition
                        and Spawn.playerIsNearPosition(src, resting, 60.0) == true)

                if here then
                    Park.log('%s was moved %.1f m without being driven - writing where it now is',
                        id, math.sqrt(dx * dx + dy * dy + dz * dz))

                    patch.pos_x = Park.coord(resting.x)
                    patch.pos_y = Park.coord(resting.y)
                    patch.pos_z = Park.coord(resting.z)

                    local turn = snapshot.restingRotation
                    if type(turn) == 'table' then
                        patch.rot_x = Park.angle(tonumber(turn.x) or record.rot_x)
                        patch.rot_y = Park.angle(tonumber(turn.y) or record.rot_y)
                        patch.rot_z = Park.angle(tonumber(turn.z) or record.rot_z)
                    end

                    --[[
                        The live entry's spawn position moves with it, or `poseIfFresh` keeps
                        measuring against where the server created the entity and every later
                        sweep writes this same row again.
                    ]]
                    if live then
                        live.spawnX, live.spawnY, live.spawnZ = resting.x, resting.y, resting.z
                    end
                end
            end
        end
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

    --[[
        NOTHING IS ACCEPTED ABOUT A VEHICLE THAT HAS NOT BEEN DRESSED YET. See `sendRestore`.

        The window is normally a second or two, between the entity being created and the client
        that was nominated for it reporting back. It becomes permanent only when the apply actually
        failed, which is the case where a capture would be writing the failure into the database -
        the state this guard exists to keep out.

        Position and rotation are still taken from the snapshot above: where a vehicle is has
        nothing to do with whether its paint went on.
    ]]
    local liveEntry = Store.live(id)
    local dressed = not (liveEntry and liveEntry.undressed)

    if not dressed and snapshot.properties ~= nil then
        Park.trace('%s is not dressed yet - ignoring the properties in this snapshot', id)
    end

    if dressed and type(snapshot.properties) == 'table' then
        local properties = Schema.filter(snapshot.properties)

        --[[
            ================================================================================================
            A GROUP THE RESTORE HAS NOT PROVED IS NOT ACCEPTED FROM ANYBODY.
            ================================================================================================

            The client that restores a vehicle knows whether its neons actually held, and 1.0.28 had
            it drop them from its own report when they had not. That was right and it was not
            enough, for the reason that cost a release in 1.0.16: THE CAPTURE IS ASKED OF WHICHEVER
            CLIENT IS NEAREST, and every other client's idea of what is unproven is empty.

            So the flag lives here, where there is one of it. It is set when a restore is sent for a
            vehicle whose neons are on, and cleared either by the restoring client saying they held
            or by somebody getting into the vehicle - at which point whatever they do to it is
            deliberate.

            While it is set, a snapshot's neon keys are dropped and the stored value stands. That is
            what stops a vehicle that came back dark from writing its own failure into the database,
            which is what made this bug permanent rather than intermittent.
        ]]
        --[[
            WITHHELD, THEN CARRIED ACROSS. The two halves have to happen in that order and both
            have to happen, because the assignment at the bottom of this block REPLACES the stored
            property table rather than merging into it. Dropping a key here without putting the
            stored one back is deleting it - see the note on `withheld` in `Stream.snapshot`, which
            is the bug this shape was written to fix.
        ]]
        local withheld = type(snapshot.withheld) == 'table' and snapshot.withheld or {}

        local live = Store.live(id)

        if live and live.unverifiedNeons then
            for _, key in ipairs(Schema.keys.neons or {}) do
                properties[key] = nil
            end
            withheld.neons = true
        end

        if record.properties then
            for group in pairs(withheld) do
                for _, key in ipairs(Schema.keys[group] or {}) do
                    properties[key] = record.properties[key]
                end
            end
        end

        --[[
            A snapshot with no deformation means "not re-read", not "no damage". Keeping the stored
            one is what makes `Deformation.shouldRecapture` work: without this line the drift guard
            would silently erase every dent it declined to re-measure.
        ]]
        if properties.deformation == nil and record.properties then
            properties.deformation = record.properties.deformation
        end

        --[[
            ================================================================================================
            AND A DEFORMATION OF NO POINTS IS ONLY BELIEVED FROM A CAR THAT READS AS UNDAMAGED.
            ================================================================================================

            An empty list is now a real answer - it is how a repair clears the dents, see
            `Deformation.read` - and that makes it something worth being careful about, because it is
            also what a client reports when it looks at a damaged car whose dents have not been put
            back yet.

            That window exists. The deformation apply converges on its own thread over about a tenth
            of a second, and since the capture sweep asks whichever client is NEAREST rather than the
            one that placed the vehicle, a second player standing next to a car being restored can be
            asked about it in exactly that window. Believing them would erase the dents for good.

            Body health settles it without needing to know any of that. The engine derives it from
            the same damage this data describes, so a car with dents cannot read as pristine, and a
            car that reads as pristine cannot have any. The one number both sides already carry is
            therefore the whole guard: no dents is accepted from a car at full health and from
            nothing else.
        ]]
        local deformation = properties.deformation

        if type(deformation) == 'table' and type(deformation.d) == 'table' and #deformation.d == 0
            and record.properties and record.properties.deformation then

            local pristine = tonumber(Config.Deformation and Config.Deformation.pristineHealth) or 999.0
            local reported = tonumber(properties.bodyHealth)

            if reported and reported < pristine then
                properties.deformation = record.properties.deformation
                Park.trace('%s reported no dents at %.1f body health - keeping the stored ones',
                    id, reported)
            end
        end

        --[[
            An empty deformation is stored as an absence. They restore identically - no points to
            apply either way - and one of them is not a key in every row of the table. What matters
            is that this runs AFTER the two rules above: an empty list first does its job of
            replacing the stored dents, and is only then tidied away.
        ]]
        if type(properties.deformation) == 'table'
            and type(properties.deformation.d) == 'table'
            and #properties.deformation.d == 0 then
            properties.deformation = nil
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
--[[
    ================================================================================================
    A CLIENT SAYING "THIS ONE CHANGED, TAKE IT NOW"
    ================================================================================================

    The capture sweep asks about a vehicle roughly every thirty seconds, and the flush runs every
    fifteen. So fitting neons, respraying a car or breaking a window and then walking away could
    take the better part of a minute to reach the database - and if the vehicle despawned first, it
    never got there at all.

    Nobody should have to wait for a modification to be saved. The client already knows the exact
    moment something changed, because `Stream.dirty` is called by every wake, entry and damage
    handler, so it says so instead of waiting to be asked.

    PROVEN THE SAME WAY AS EVERY OTHER CLIENT MESSAGE. The vehicle must be one we are holding, and
    the sender must be next to it, read on the server from two positions the client does not
    supply. See `Spawn.playerIsNear`.

    Rate limiting is `Config.Save.triggerCooldown`, applied by `Persist.touch` below: a client
    shouting about the same vehicle repeatedly gets one write and the rest are folded into the
    sweep.
]]
RegisterNetEvent('vpark:server:changed', function(id, snapshot)
    local src = source

    if type(id) ~= 'string' or type(snapshot) ~= 'table' then return end
    if not Runtime.ready() then return end

    local entry = Store.live(id)
    if not entry then return end

    if Spawn.playerIsNear and Spawn.playerIsNear(src, entry.entity, 30.0) == false then return end

    Persist.applySnapshot(id, snapshot, nil, src)
    Persist.touch(id, 'onExit')
end)

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
                if Persist.applySnapshot(snapshot.id, snapshot, nil, src) then
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
--[[
    Each entry is `{ id, storedBodyHealth }` rather than a bare id.

    The body health is the reference the client's deformation drift guard measures against. The
    client that PLACED a vehicle remembers what it was restored at; every other client does not,
    and this sweep asks whichever client is nearest. Sending the number is what lets any of them
    answer without re-measuring - and re-measuring an approximation is what walks the dents.
]]
local function requestCapture(src, ids)
    if #ids == 0 then return end

    nextToken = nextToken + 1
    local token = nextToken

    local allowed = {}
    for _, asked in ipairs(ids) do allowed[asked[1]] = true end

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
    local sweepStartedAt = Park.ticks()
    local slices = math.max(1, math.floor(tonumber(saveConfig().sweepSlices) or 4))
    sliceCursor = (sliceCursor % slices) + 1

    local players = Spawn.onlinePlayers()
    if #players == 0 then return end

    --[[
        Group the vehicles due this slice by the client nearest them, so each client gets one
        message listing everything it is responsible for.

        A VEHICLE SOMEBODY IS DRIVING IS TREATED DIFFERENTLY, IN BOTH HALVES OF THAT SENTENCE.

        `due this slice`: it is due EVERY slice. The slice exists so that three thousand parked
        cars are not hashed at once, and a parked car has nothing to say - it is provably
        identical to the last capture. A car being driven is the one thing in the live set whose
        position is changing, and it is at most one per player, so the whole reason for slicing
        does not apply to it. Every 30 seconds becomes every 7.5, for a handful of vehicles.

        `the client nearest them`: nearest is computed from the STORED position, which for a car
        being driven is where the drive STARTED. Drive further than the streaming radius and the
        capture was asked of a client that does not have the vehicle in scope, so it answered
        nothing about it - silently, because a client that cannot see a vehicle is not an error.
        The vehicle then had nothing written for it until it was parked, and if the parked report
        never arrived - the player disconnected at the wheel - the drive was lost.

        The occupant is the exact answer, not an estimate: they are sitting in it.
    ]]
    local perClient = {}
    local index = 0

    for id, entry in pairs(Store.allLive()) do
        index = index + 1

        local driving = entry.driven == true and entry.occupant ~= nil

        if driving or (index % slices) + 1 == sliceCursor then
            local record = Store.get(id)

            if record and entry.entity and DoesEntityExist(entry.entity) then
                local best, bestDistance

                if driving then
                    best = entry.occupant
                else
                    for _, player in ipairs(players) do
                        if player.bucket == record.bucket then
                            local dx, dy = player.x - record.pos_x, player.y - record.pos_y
                            local distance = dx * dx + dy * dy
                            if not bestDistance or distance < bestDistance then
                                best, bestDistance = player.src, distance
                            end
                        end
                    end
                end

                if best then
                    local list = perClient[best]
                    if not list then
                        list = {}
                        perClient[best] = list
                    end
                    -- The reference the client's drift guards measure against: what the health
                    -- SETTLED at after the restore, not what is stored. See `restoredHealth` in
                    -- Store.liveFields for why those are different on purpose.
                    list[#list + 1] = { id, entry.restoredHealth or record.body_health }
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

    Park.observe(stats.sweepMs, Park.ticks() - sweepStartedAt)
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
        --[[
            DEFERRED, NOT DROPPED.

            This used to mark the row dirty and leave it for the sweep, which is up to thirty
            seconds away - so a second change inside the cooldown looked to the player like
            nothing had been saved at all. Reported exactly that way: "faut attendre 10 secondes,
            si on se tp loin aussitot rien est enregistre".

            The cooldown is here to stop a vehicle being rammed repeatedly from writing a row per
            impact. It does that just as well by collapsing everything in the window into ONE
            write at the end of it, and that write actually happens.
        ]]
        Store.markDirty(id)
        stats.skipped = stats.skipped + 1

        if not deferred[id] then
            deferred[id] = true

            SetTimeout(cooldownMs - (Park.ticks() - last) + 50, function()
                deferred[id] = nil

                if Store.get(id) then
                    cooldown[id] = Park.ticks()
                    Database.thread(function() Persist.flushNow() end)
                end
            end)
        end

        return false
    end

    cooldown[id] = Park.ticks()
    Store.markDirty(id)

    --[[
        AND WRITTEN NOW, WHICH IS THE ENTIRE POINT OF THIS FUNCTION.

        Marking dirty only queues the row for the next flush, fifteen seconds away by default, so
        `Config.Save.triggers` promised an immediate write and delivered a slightly earlier one.
        The whole mechanism was also dead code: nothing in the resource called `Persist.touch`,
        so none of `onExit`, `onDamage`, `onLockChange` or `onOwnerChange` did anything at all.

        The cooldown above is what keeps this safe - a vehicle being rammed repeatedly collapses
        into one write and the sweep picks up the rest.
    ]]
    Database.thread(function()
        Persist.flushNow()
    end)

    return true
end

--[[
    A player disconnected. Everything they were in gets written where it stands.

    Without this, a crash at 03:00 costs the player their car. It is occasionally written in
    the middle of the motorway, which `Config.Placement` handles far better than losing it
    would be handled.
]]
--[[
    A player disconnected. Write down what they were responsible for before the answer is gone.

    `placer` WAS THE WRONG PLAYER, and it is the same mistake 1.0.16 was made of: the placer is
    the client the server nominated to dress and place the vehicle, not the person who was
    driving it. Those are the same client only on a single-player test, and they stop being the
    same the moment the placer drives away. So a player who got into somebody else's restored
    vehicle and then disconnected at the wheel marked nothing dirty and flushed nothing.

    `occupant` is who the server watched get in, which is the person whose disconnect actually
    loses information. Both are marked now: the placer because the vehicle is about to lose the
    client responsible for it, the occupant because they were the one moving it.

    What this flushes is what the store already holds, which is the last capture - it does not
    read a new position. That is why the sweep above puts a driven vehicle in every slice: this
    trigger can only save what something else has already captured, so the value of it is set by
    how recent that capture is.
]]
function Persist.onPlayerDropped(src)
    if not (saveConfig().triggers or {}).onDisconnect then return end

    for id, entry in pairs(Store.allLive()) do
        if entry.placer == src or entry.occupant == src then
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
