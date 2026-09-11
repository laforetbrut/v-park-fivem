-- Author: vyrriox
--[[
    client/track.lua

    Noticing which vehicles matter, and answering the server when it asks about one.

    -------------------------------------------------------------------------------------------
    THE SERVER DECIDES; THIS FILE ONLY REPORTS
    -------------------------------------------------------------------------------------------

    Nothing here persists anything. It observes that a player got out of a car, runs the shared
    rules to see whether the server would care, and if so sends one message. The server then
    makes the decision again, from its own state, and stores the result.

    Running the rules locally first is not a trust decision - the server re-checks everything -
    it is a traffic decision. On a busy server, players get in and out of vehicles constantly,
    and most of those vehicles are bicycles, blacklisted models or cars inside a garage zone.
    Filtering those here means the server never hears about them.

    -------------------------------------------------------------------------------------------
    WHY EXIT AND NOT ENTRY
    -------------------------------------------------------------------------------------------

    A vehicle becomes interesting when somebody LEAVES it somewhere, not when they get in. The
    settle timer in `Config.Persistence.settleSeconds` is the difference between "parked" and
    "stopped at a red light and hopped out for four seconds", and it is measured from the exit.
]]

Track = {}

-- The vehicle the player is currently in, and when they got in.
local current = { entity = nil, netId = nil, since = 0 }

-- Vehicles this client has left and is waiting out the settle timer on.
-- entity -> { at, netId, model }
local settling = {}

local function performance()
    return (Config and Config.Performance) or {}
end

-- ---------------------------------------------------------------------------------------
-- The local pre-check
-- ---------------------------------------------------------------------------------------

--[[
    Would the server plausibly want this vehicle?

    Deliberately incomplete: the client does not know who owns the vehicle, so `ownership` is
    left out and the mode check is skipped. Everything the client CAN answer - class, model,
    plate, health, zone - is answered here, and those five reject the overwhelming majority of
    what a player touches in an evening.
]]
local function worthReporting(vehicle)
    if not DoesEntityExist(vehicle) then return false end
    if not IsEntityAVehicle(vehicle) then return false end

    -- A vehicle we already restored is already known. Reporting it again would be harmless
    -- and pointless.
    if Stream.byEntity(vehicle) then return false end

    local model = GetEntityModel(vehicle)
    local position = GetEntityCoords(vehicle)

    local allowed = Rules.check({
        model = model,
        modelName = GetDisplayNameFromVehicleModel(model),
        class = GetVehicleClass(vehicle),
        plate = GetVehicleNumberPlateText(vehicle),
        bodyHealth = GetVehicleBodyHealth(vehicle),
        engineHealth = GetVehicleEngineHealth(vehicle),
        position = { x = position.x, y = position.y, z = position.z },
    })

    return allowed
end

Track.worthReporting = worthReporting

--[[
    Everything the server needs to create a record for a vehicle it has never seen.

    Sent once, when the settle timer expires. It is the largest message this resource sends and
    it is sent at most once per vehicle per session.
]]
local function describe(vehicle)
    if not DoesEntityExist(vehicle) then return nil end

    local position = GetEntityCoords(vehicle)
    local rotation = GetEntityRotation(vehicle, 2)
    local model = GetEntityModel(vehicle)

    return {
        netId = NetworkGetNetworkIdFromEntity(vehicle),
        model = model,
        modelName = GetDisplayNameFromVehicleModel(model),
        class = GetVehicleClass(vehicle),
        plate = Park.plate(GetVehicleNumberPlateText(vehicle)),

        --[[
            The type string `CREATE_VEHICLE_SERVER_SETTER` needs, read off the live entity.

            The server cannot work this out for itself - there is no server native that maps a
            model to a type - and getting it wrong is a vehicle that gets created and never
            becomes real. `Classes.setterType` falls back to a guess from the class when this
            is missing, which is what happens for every row written before 1.0.4.
        ]]
        vehicleType = GetVehicleType and GetVehicleType(vehicle) or nil,
        position = { x = Park.coord(position.x), y = Park.coord(position.y), z = Park.coord(position.z) },
        rotation = { x = Park.angle(rotation.x), y = Park.angle(rotation.y), z = Park.angle(rotation.z) },
        interior = GetInteriorFromEntity(vehicle),
        room = GetRoomKeyFromEntity(vehicle),
        properties = Properties.capture(vehicle),
        statebags = Properties.captureStatebags(vehicle),
    }
end

Track.describe = describe

-- ---------------------------------------------------------------------------------------
-- Entering and leaving
-- ---------------------------------------------------------------------------------------

--[[
    Vehicles this client has already offered on entry, so getting in and out of the same car
    repeatedly is one message rather than one per entry.

    Not cleared on exit: the point is to offer each vehicle once per session.
]]
-- entity -> { plate, at }. See the note in `onEnter`; it is not a plain "already asked" set.
local offeredOnEntry = {}

--[[
    DECLARED ABOVE ITS CALLERS, AND THAT IS NOT A STYLE CHOICE.

    `local function f` binds the name on the line it appears on and not before. This lived below
    `onEnter` from 1.0.16 until 1.0.22, so the call in `onEnter` resolved to a global, the global
    was nil, and GETTING INTO A VEHICLE RAISED - every time, on every client, for six releases.

    Everything below that call is what did not happen: the on-entry offer, so a vehicle the player
    owned was never kept the moment they sat in it, and `vpark:server:touched`, so the server never
    learned the vehicle had been driven. The parse is valid, so nothing caught it until
    `tools/check.py` group 20 was written to.

    -------------------------------------------------------------------------------------------
    IS THIS VEHICLE ONE V-PARK KEEPS, AND WHAT IS ITS ID?
    -------------------------------------------------------------------------------------------

    THE STATEBAG, NOT THE TRACKED TABLE. THIS DISTINCTION COST A RELEASE.

    `Stream.byEntity` answers from `tracked`, which is populated by the `vpark:client:restore`
    handler - and that instruction is sent to ONE client, the one the server nominated to dress
    and place the vehicle. Every other client has an empty `tracked` for it.

    So a player who gets into a vehicle that was restored for somebody else - which is most
    vehicles, on a server with more than one player, and any vehicle at all after the nominated
    client has driven off - was invisible to every check written against `tracked`. Getting out
    of it reported nothing, and the parked position was never sent.

    That is what "almost, but one of them still went back to an old place" was: the fix worked
    when the player happened to be the placer and did nothing when they were not.

    `vpark:id` is a REPLICATED statebag. Every client in scope has it, and a player who has just
    spent time sitting in the vehicle has certainly had it for a while. It is the right question
    to ask here.
]]
local function vparkId(vehicle)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return nil end

    -- The tracked table first: it is a table lookup, and on the nominated client it is already
    -- the answer.
    local record, id = Stream.byEntity(vehicle)
    if id then return id, record end

    local ok, bagId = pcall(function() return Entity(vehicle).state['vpark:id'] end)
    if ok and type(bagId) == 'string' then return bagId, nil end

    return nil, nil
end

local function onEnter(vehicle)
    if current.entity ~= vehicle then
        current.entity = vehicle
        current.netId = NetworkGetNetworkIdFromEntity(vehicle)
        current.since = Park.ticks()
        current.id = nil
    end

    -- Getting in cancels a pending settle: the car is not parked, it is being driven.
    settling[vehicle] = nil

    local id, record = vparkId(vehicle)

    if id then
        --[[
            NOTHING V-PARK KEEPS STAYS FROZEN WHILE SOMEBODY IS SITTING IN IT.

            A restored vehicle is frozen so it cannot fall through the map before it is placed,
            and `FreezeEntityPosition` does exactly what it says: THE ENTITY IGNORES POSITION
            WRITES. That is the 1.0.9 lesson, and it applies to every other resource too - an
            admin teleport, a `tpm`, a noclip, a tow script. The car simply stays where it was
            while the player arrives somewhere else, with nothing in any log to explain it.

            The wake in `Stream.lua` handles this already on the client that was nominated to
            place the vehicle, and only there: it is keyed on that client's own restore table.
            This is keyed on the REPLICATED statebag, so it runs on whichever machine the player
            is actually on - the same distinction that cost a release in 1.0.16.

            Unconditional, and cheap: unfreezing an entity that is not frozen does nothing.
        ]]
        --[[
            EXCEPT AN ANCHORED ONE. Getting into a moored boat does not unmoor it: the anchor is
            what the player asked for and the command is how they take it back. The position-write
            problem this unfreeze exists to solve is why `Config.Anchor.classes` is boats only by
            default - the game's own boat anchor does not freeze the entity at all.
        ]]
        if not (Anchor and Anchor.isAnchored and Anchor.isAnchored(vehicle)) then
            FreezeEntityPosition(vehicle, false)
        end

        -- Driven, so its position becomes worth recording. See `Stream.snapshot`. Only on the
        -- client that tracks it; the others have nothing to mark and do not capture it.
        if record then
            record.driven = true
            record.frozen = false
        end

        -- `true`: somebody got IN it. See `Config.Cleanup` for why that is a different fact
        -- from the vehicle merely having been interacted with.
        if current.id ~= id then
            current.id = id
            TriggerServerEvent('vpark:server:touched', id, true)
        end
        return
    end

    --[[
        Not one of ours yet. Offer it on ENTRY, so that a vehicle this player owns is kept
        from the moment they sit in it rather than forty-five seconds after they walk away
        from it.

        The SERVER decides. It checks the framework's owned-vehicles table, then the key
        resource, and adopts only if the car is genuinely theirs; anything else is ignored and
        goes through the ordinary settle path on exit. `Config.Persistence.ownedImmediately`
        is the switch.

        Offered only when the local rules would allow it at all, so a bicycle, a blacklisted
        model or a car inside a garage zone costs nothing.

        -------------------------------------------------------------------------------------
        WHY THE OFFER EXPIRES RATHER THAN BEING MADE ONCE
        -------------------------------------------------------------------------------------

        1.0.1 offered a given vehicle once per session and never again. Two things break on
        that, and the first was reported:

          - OWNERSHIP CAN ARRIVE AFTER YOU SIT DOWN. Get into a car, then get the keys -
            `/admincar`, a mate handing them over, a dealership finishing a sale. The offer
            was already made and refused, and nothing would ever ask again, so the car was
            not kept.

          - ENTITY HANDLES ARE REUSED. The table is keyed on the handle, so a vehicle that
            despawned could hand its "already offered" mark to an entirely different car.

        So the mark carries a time and the plate that was offered. A different plate on the
        same handle is a different vehicle and is offered immediately; the same plate is
        re-offered after `retrySeconds`. On a car nobody owns that is one small event a
        minute while somebody sits in it, and it stops the moment they get out.
    ]]
    if not (Config.Persistence and Config.Persistence.ownedImmediately ~= false) then return end
    if not worthReporting(vehicle) then return end

    local plate = GetVehicleNumberPlateText(vehicle)
    local previous = offeredOnEntry[vehicle]
    local retry = tonumber(Config.Persistence and Config.Persistence.entryOfferRetrySeconds) or 60

    --[[
        FAST WHILE THEY HAVE JUST SAT DOWN, SLOW AFTER THAT.

        Ownership arrives after you sit down more often than before it: `/admincar`, a mate handing
        over keys, a dealership finishing a sale. The offer is refused the first time because the
        car is nobody's yet, and until now the next attempt was a full retry window away - so
        `/admincar` left you waiting, which was reported as "il devrait etre persistant aussitot".

        For the first `entryOfferBurstSeconds` after getting in, the offer is repeated every
        `entryOfferBurstRetry` seconds. That is the window in which somebody runs a command to make
        the car theirs. After it, the ordinary retry takes over, so a player sitting in a car nobody
        owns costs one small message a minute rather than one every few seconds forever.
    ]]
    local since = current.since and (Park.ticks() - current.since) or math.huge
    local burstFor = (tonumber(Config.Persistence and Config.Persistence.entryOfferBurstSeconds) or 30) * 1000

    if since < burstFor then
        retry = tonumber(Config.Persistence and Config.Persistence.entryOfferBurstRetry) or 3
    end

    if previous and previous.plate == plate and Park.ticks() - previous.at < retry * 1000 then
        return
    end

    offeredOnEntry[vehicle] = { plate = plate, at = Park.ticks() }

    local payload = describe(vehicle)
    if payload then
        payload.onEntry = true
        TriggerServerEvent('vpark:server:candidate', payload)
    end
end

local function onExit(vehicle)
    current.entity = nil
    current.netId = nil
    current.id = nil

    --[[
        ============================================================================
        A VEHICLE WE ALREADY KEEP IS WRITTEN DOWN THE MOMENT IT IS PARKED.
        ============================================================================

        THIS IS THE MOMENT THE ANSWER IS KNOWN, AND UNTIL 1.0.14 NOTHING USED IT.

        `worthReporting` below answers false for a vehicle v-park already tracks - correctly,
        because that check is about whether to ADOPT something new. So getting out of a
        persisted vehicle did nothing at all, and where it had just been parked was left to be
        discovered later by one of two things:

          - the periodic capture sweep, which runs in quarters and may be seconds away;
          - the final pose read when the vehicle despawns, which asks the SERVER for the
            entity's coordinates.

        Both fail in the same case, and it is the ordinary one: park, get out, walk or drive
        away. The sweep has not come round yet, and by the time the vehicle leaves the
        streaming radius no client has it in scope any more - so the server-side read returns
        nothing and the position stays whatever it was BEFORE the drive. The vehicle then comes
        back where it used to live rather than where it was left, which is the "sometimes it
        saves the wrong place, and if I leave quickly it does not save at all" report.

        The client that was driving it is the one machine that certainly knows where it ended
        up, and this is the instant it stops changing. One small message, once, per vehicle
        parked.
    ]]
    local trackedId, tracked = vparkId(vehicle)

    if trackedId then
        local position = GetEntityCoords(vehicle)
        local rotation = GetEntityRotation(vehicle, 2)

        if position and (position.x ~= 0.0 or position.y ~= 0.0) then
            TriggerServerEvent('vpark:server:parked', trackedId, {
                x = Park.coord(position.x),
                y = Park.coord(position.y),
                z = Park.coord(position.z),
            }, {
                x = Park.angle(rotation.x),
                y = Park.angle(rotation.y),
                z = Park.angle(rotation.z),
            })

            --[[
                And it stops reporting its position again until somebody drives it.

                The rule from 1.0.13 is that only a driven vehicle says where it is, because a
                merely woken one is simulated and rolls. `driven` was set when the player got
                in and nothing cleared it, so after they got out the vehicle carried on
                reporting a position that physics was still free to change.

                The pose above is the answer. Everything after it is drift.

                Only on the client that tracks it - the others have no record to clear, and no
                snapshot to suppress either, because the server only ever asks the nearest
                client and that request names the vehicles it may answer about.
            ]]
            if tracked then tracked.driven = false end
        end

        --[[
            And nothing below applies to it.

            What follows is the ADOPTION path: the settle timer that decides whether a vehicle
            v-park does not know about is worth keeping. This one it already keeps, so running
            that would end in an offer the server refuses as "already ours" - harmless, and
            still a message per parked vehicle for no reason.
        ]]
        return
    end

    if not worthReporting(vehicle) then return end

    settling[vehicle] = {
        at = Park.ticks(),
        netId = NetworkGetNetworkIdFromEntity(vehicle),
        model = GetEntityModel(vehicle),
    }
end

--[[
    The settle sweep.

    Runs on the same timer as everything else on this client. A vehicle that has been sitting
    for `settleSeconds` with nobody in it, in a place the rules allow, is reported once.

    Re-checking the rules at the end rather than only at the start matters: a player can get
    out, push the car into a garage zone, and the car is then no longer a candidate. Checking
    only at exit would persist it anyway.
]]
local function sweepSettling()
    if next(settling) == nil then return end

    local settleMs = (tonumber(Config.Persistence and Config.Persistence.settleSeconds) or 45) * 1000

    for vehicle, entry in pairs(settling) do
        if not DoesEntityExist(vehicle) then
            settling[vehicle] = nil
        elseif (Park.ticks() - entry.at) >= settleMs then
            settling[vehicle] = nil

            -- Somebody got back in during the timer, from another client. Not parked.
            if not IsVehicleSeatFree(vehicle, -1) then
                -- Nothing to do; whoever is driving it will report it when they leave.
            elseif worthReporting(vehicle) then
                local payload = describe(vehicle)
                if payload then
                    TriggerServerEvent('vpark:server:candidate', payload)
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------
-- The timer
--
-- One timer, shared with nothing, at the tier interval. It watches for the local player
-- getting in and out of a vehicle and sweeps the settle list.
--
-- `IsPedInAnyVehicle` polled at 200 ms is deliberately used instead of the entered/exited
-- game events: the events do not fire for every way a player can leave a vehicle - a ragdoll
-- ejection, a teleport, a resource moving the ped - and a missed exit means a car that is
-- never persisted with no way to notice.
-- ---------------------------------------------------------------------------------------

CreateThread(function()
    while not Compat.characterLoaded() do Wait(1000) end

    while true do
        local tiers = performance().clientTiers
        local interval = 500
        if type(tiers) == 'table' and tiers[1] then
            interval = tonumber(tiers[1].interval) or 500
        end

        Wait(interval)

        local ped = PlayerPedId()
        local vehicle = GetVehiclePedIsIn(ped, false)

        if vehicle ~= 0 and DoesEntityExist(vehicle) then
            if current.entity ~= vehicle then
                if current.entity then onExit(current.entity) end
                onEnter(vehicle)
            else
                --[[
                    STILL SITTING IN IT, AND IT STILL IS NOT OURS.

                    `onEnter` offers the vehicle once, when the door closes. That is the wrong
                    and only moment, because OWNERSHIP CAN ARRIVE WHILE SOMEBODY IS SITTING
                    THERE: `/admincar` is run from the driver's seat and writes the row from
                    under us, and so does a dealership finishing a sale or a mate handing the
                    keys over.

                    Until 1.0.13 nothing asked again. The vehicle became the player's and
                    v-park did not notice until they got out and the forty-five second settle
                    timer expired - so `/admincar` looked like it did nothing and `/vpark` was
                    the only thing that worked, which is exactly how it was reported.

                    `onEnter` already keeps a timestamped mark per vehicle and honours
                    `entryOfferRetrySeconds`, so calling it again is free until that expires.
                ]]
                onEnter(vehicle)
            end
        elseif current.entity then
            local left = current.entity
            onExit(left)
        end

        sweepSettling()
    end
end)

-- ---------------------------------------------------------------------------------------
-- Answering the server
-- ---------------------------------------------------------------------------------------

--[[
    The server wants the current state of some vehicles it is tracking.

    It asks the client that is nearest, because only a client can read a vehicle's
    modifications and damage. The reply is one message containing every requested snapshot, so
    a sweep over forty vehicles is one round trip rather than forty.

    `ids` is a list. A snapshot that comes back nil - the entity went away between the request
    and the reply - is simply absent from the answer, and the server treats an absent snapshot
    as "no news", not as "deleted".
]]
RegisterNetEvent('vpark:client:capture', function(ids, token)
    if type(ids) ~= 'table' then return end

    local out = {}

    for _, asked in ipairs(ids) do
        --[[
            An entry is `{ id, storedBodyHealth }`.

            The second value is the reference the deformation drift guard needs. The server sends
            it because a client that did not place the vehicle has no idea what body health it was
            restored at, and without a reference it would re-measure the dents on every sweep and
            walk them. See `foreignSnapshot` in `client/stream.lua`.

            A bare string is still read, so nothing here depends on both halves of the resource
            having been reloaded.
        ]]
        local id, reference

        if type(asked) == 'table' then
            id, reference = asked[1], tonumber(asked[2])
        elseif type(asked) == 'string' then
            id = asked
        end

        if type(id) == 'string' then
            local snapshot = Stream.snapshot(id, reference)
            if snapshot then
                out[#out + 1] = snapshot
            end
        end
    end

    TriggerServerEvent('vpark:server:captured', out, token)
end)

--[[
    The server wants one specific vehicle captured by network id, whether or not we are
    tracking it.

    Used by `/vpark`, by the admin panel and by the API: all three can name a vehicle the
    client has never been told about.
]]
--[[
    Resolved through the state bag first, exactly as `waitForEntity` in `client/stream.lua` is
    and for the same reason: `NetworkDoesNetworkIdExist` asks the object manager for an object
    this client may not have, and says so in the console every time it does not.
]]
local function entityFor(netId)
    if type(netId) ~= 'number' or netId <= 0 then return 0 end

    local entity = GetEntityFromStateBagName(('entity:%d'):format(netId))
    if entity and entity ~= 0 and DoesEntityExist(entity) then return entity end

    if NetworkDoesNetworkIdExist(netId) then
        entity = NetToVeh(netId)
        if entity and entity ~= 0 and DoesEntityExist(entity) then return entity end
    end

    return 0
end

RegisterNetEvent('vpark:client:captureEntity', function(netId, token)
    local entity = entityFor(netId)

    if entity == 0 or not DoesEntityExist(entity) then
        TriggerServerEvent('vpark:server:capturedEntity', nil, token)
        return
    end

    TriggerServerEvent('vpark:server:capturedEntity', describe(entity), token)
end)

--[[
    Apply a property change the server has decided on, to a vehicle we can reach.

    Used by the admin panel's repair, clean and refuel actions. The server tells the nearest
    client what to do rather than doing it itself, because none of those are server-side
    natives.
]]
RegisterNetEvent('vpark:client:mutate', function(netId, action, value)
    local entity = entityFor(netId)
    if entity == 0 or not DoesEntityExist(entity) then return end

    if not Placement.takeControl(entity, 2000) then return end

    if action == 'repair' then
        Properties.repair(entity)
    elseif action == 'clean' then
        SetVehicleDirtLevel(entity, 0.0)
    elseif action == 'refuel' then
        Compat.setFuel(entity, tonumber(value) or 100.0)
    elseif action == 'unlock' then
        SetVehicleDoorsLocked(entity, 1)
        SetVehicleDoorsLockedForAllPlayers(entity, false)
    elseif action == 'lock' then
        SetVehicleDoorsLocked(entity, 2)
    elseif action == 'freeze' then
        FreezeEntityPosition(entity, value ~= false)
    end
end)

function Track.currentVehicle()
    return current.entity
end
