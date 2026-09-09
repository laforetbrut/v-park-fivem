--[[
    server/spawn.lua

    Deciding what exists in the world right now.

    -------------------------------------------------------------------------------------------
    THE WHOLE IDEA
    -------------------------------------------------------------------------------------------

    Nothing is spawned at boot. A database with five thousand vehicles and one player online
    has perhaps thirty entities in the world, and the other four thousand nine hundred and
    seventy are rows.

    That is the difference between this and a script that creates everything and hopes. Server
    entity budgets are finite, every existing entity costs network traffic to every client in
    scope, and the overwhelming majority of a persisted fleet is somewhere nobody is standing.

    Each pass:
        1. Ask each online player's grid neighbourhood what is near them.
        2. Union those into one wanted set, nearest first.
        3. Create up to `spawnsPerPass` that are wanted and not live.
        4. Remove up to `despawnsPerPass` that are live and wanted by nobody.

    All of it under a millisecond budget, yielding when it runs out.

    -------------------------------------------------------------------------------------------
    HYSTERESIS
    -------------------------------------------------------------------------------------------

    `spawnRadius` and `despawnRadius` are different numbers and MUST stay different. A player
    standing exactly on one boundary would otherwise spawn and despawn the same vehicle several
    times a second, each spawn costing a full restore. The hundred-metre gap is about three
    seconds in a fast car, which is the timescale that matters.
]]

Spawn = {}

-- id -> the tick a restore instruction was sent, for vehicles awaiting a client's answer.
local pending = {}

-- ids that failed placement in a way that says "try again later" rather than "give up".
local deferred = {}

-- id -> consecutive creation failures. Cleared on the first vehicle that actually reaches a
-- client. A vehicle that cannot be spawned five times running is not going to be spawned on
-- the sixth, and retrying it every second forever is how one bad row fills a console.
local failures = {}

--[[
    ============================================================================================
    THE TWO BOOKS OF HANDLES. READ THIS BEFORE CHANGING ANYTHING IN THIS FILE.
    ============================================================================================

    `Store.live` records the vehicles that are in the world and working. It is indexed by
    vehicle id and it is what the rest of the resource reads.

    These two are indexed by ENTITY HANDLE, and they exist because 1.0.2 and 1.0.3 both leaked
    entities that nothing could find.

    `ours`       every handle CreateVehicle has ever handed us that we have not finished with.
                 Written before anything else can happen to the entity, so an entity that fails
                 at any later step is still findable. The reconciliation sweep reads it.

    `condemned`  handles we have decided to remove and have not yet SEEN removed.

    -------------------------------------------------------------------------------------------
    WHY `condemned` CANNOT JUST BE A DELETE CALL
    -------------------------------------------------------------------------------------------

    Two facts that together caused the leak:

      - `DeleteEntity` on an entity that is not ready raises, and the entity survives. It is in
        the log as `script error in native 00000000faa3d236`.

      - `DoesEntityExist` answers false for an entity that is NOT READY YET as well as for one
        that is gone. So immediately after a failed delete we cannot tell "deleted" from "not
        born yet", and every version so far assumed the former.

    The consequence was an undressed, unmarked copy of the car left in the world on every
    failed creation - carrying no `vpark:id` statebag, because setting it was the step that
    failed - so the reconciliation sweep, which looked only at that statebag, could not see a
    single one of them. They piled up on the vehicle's saved coordinates until a player
    teleported there and got into one instead of their own car: different colour, different
    plate, no keys.

    So a condemned handle stays condemned until `GetAllVehicles` stops listing it. That is the
    only source of truth that does not lie about an entity in this state.
]]
local ours = {}
local condemned = {}

--[[
    Until when the reconciliation sweep also reads statebags.

    Set at boot. See the note inside `Spawn.reconcile`: after this, everything of ours is in
    `ours`, and the only thing a statebag read can find is an entity from a previous start of
    the resource - which by then there has been ample opportunity to collect.
]]
local bootWindow = 0

-- Forward-declared so that `Spawn.create` can call something defined below it. Assigned, not
-- redeclared, further down; writing `local function` twice would give two different upvalues
-- and the call above would reach neither.
local dress
local noteFailure

--[[
    Tell a client to dress and place a vehicle.

    Its own function because it is sent twice: once when the vehicle is created, and again if
    the client answers that it could not take network control of it. See the note on the
    re-ask in the `vpark:server:restored` handler.
]]
--[[
    ================================================================================================
    THE SERVER TELLS THE CLIENT WHICH VEHICLES ARE OURS. IT DOES NOT LEAVE IT TO GUESS.
    ================================================================================================

    A persisted vehicle standing at its saved pose was standing there when every other persisted
    vehicle nearby was saved. They coexisted, so they are not in each other's way, and the client
    must not treat one as an obstacle to placing another. The box the client tests with is bigger
    than the bodywork, so two cars parked thirty centimetres apart overlap in it and the search
    then moves one of them a metre and a quarter - which is the `1.250 m` reported from
    `/vparkwhere` and the reason the search has shipped disabled since 1.0.11.

    1.0.11 answered the question with the `vpark:id` statebag, which is correct and was not
    enough: a replicated statebag arrives asynchronously, and several vehicles restored at once are
    placed before their neighbours' bags have landed. A fix that depends on winning a network race
    is not a fix, and the search was switched off rather than shipped unreliable.

    THE SERVER ALREADY KNOWS THE ANSWER. It knows every vehicle it is holding and where each one
    is, with no race and nothing to wait for, so it says so in the restore instruction itself. The
    statebag check stays as the second line - it is right whenever the bag has landed, and it also
    covers a vehicle restored after this message was built.

    A vehicle that has no network id yet is left out, and that is not a gap: an entity the server
    cannot address is an entity no client has streamed in, so it is not in the client's vehicle
    pool and cannot be an obstacle.
]]
local function neighboursOf(record)
    local list = {}

    local radius = tonumber((Config.Placement or {}).neighbourRadius) or 30.0

    -- `Store.near` hands back { record, distanceSq } wrappers, not bare records.
    for _, near in ipairs(Store.near(record.pos_x, record.pos_y, radius, record.bucket)) do
        local other = near.record

        if other and other.id ~= record.id then
            local entry = Store.live(other.id)

            if entry then
                local id = entry.netId

                -- Recorded when the vehicle was dressed. Between being created and being
                -- dressed there is a window where the entity exists and the id has not been
                -- written down yet, so ask the engine rather than skip it.
                if not id and entry.entity then
                    local ok, answer = pcall(NetworkGetNetworkIdFromEntity, entry.entity)
                    if ok and answer and answer ~= 0 then id = answer end
                end

                if id then list[#list + 1] = id end
            end
        end
    end

    return list
end

--[[
    Does this record carry neons that are switched on?

    Only those need the guard: a vehicle whose neons are off has nothing to lose if a capture reports
    them off. See the note in `Persist.applySnapshot`.
]]
local function hasNeonsOn(record)
    local properties = record and record.properties
    if type(properties) ~= 'table' then return false end
    if type(properties.neonEnabled) ~= 'table' then return false end

    for _, value in ipairs(properties.neonEnabled) do
        if value == true then return true end
    end

    return false
end

local function sendRestore(record, src, netId)
    -- Not to be believed about its neons until the client that places it says they held.
    local entry = Store.live(record.id)
    if entry and hasNeonsOn(record) then entry.unverifiedNeons = true end

    --[[
        AND NOT TO BE BELIEVED ABOUT ANYTHING ELSE UNTIL SOMEBODY HAS DRESSED IT.

        A vehicle that has been created but not yet had its properties applied is a STOCK car
        standing where a modified one belongs. The client doing the dressing knows that and says
        nothing until it has finished - `record.dressed` in `client/stream.lua`.

        Every OTHER client's idea of what has been dressed is empty, and since the capture sweep
        asks whichever client is nearest, one of them can be asked about a vehicle in exactly that
        window. It would read a stock car and report it in good faith, and the modifications would
        be gone from the database for good.

        So the fact lives here, where there is one of it, exactly as the neon guard does and for
        exactly the same reason. Cleared by the placing client reporting that the apply worked.
    ]]
    if entry then entry.undressed = true end

    TriggerClientEvent('vpark:client:restore', src, netId, {
        neighbours = neighboursOf(record),
        id = record.id,
        version = record.updated_at,
        position = { x = record.pos_x, y = record.pos_y, z = record.pos_z },
        rotation = { x = record.rot_x, y = record.rot_y, z = record.rot_z },
        class = record.class,
        interior = record.interior,
        room = record.room,
        frozen = true,
        properties = record.properties,
    })
end

local stats = {
    spawned = 0,
    despawned = 0,
    failed = 0,
    exact = 0,
    nudged = 0,
    forced = 0,
    grounded = 0,
    passes = 0,
    lastPassMs = 0,

    -- See `Park.timing`. The last duration on its own says almost nothing about a loop that
    -- runs forever; these two say whether it costs anything and whether it ever stalls.
    passMs = Park.timing(),
    reconcileMs = Park.timing(60),
    reconciled = 0,
}

local function streaming()
    return (Config and Config.Streaming) or {}
end

--[[
    Read an entity's pose without being able to raise.

    -------------------------------------------------------------------------------------------
    WHY THESE EXIST
    -------------------------------------------------------------------------------------------

    `DoesEntityExist` answering true is NOT a guarantee that the next native will succeed. A
    server-created entity that no client currently has in scope is registered but has no
    synchronisation state, and reads against it raise:

        script error in native 00000000635e5289: Tried to access invalid entity: 143624

    Observed on a live server the moment a player drove away from a group of restored vehicles.
    The raise propagated out of `Spawn.despawn`, out of the streaming pass, and killed the pass
    for that tick - which is how a resource stops streaming entirely while looking healthy.

    Every server-side entity read now goes through one of these. A nil answer means "could not
    read it", which every caller already handles by leaving the stored value alone.
]]
local function safeCoords(entity)
    if not entity or entity == 0 then return nil end
    local ok, position = pcall(GetEntityCoords, entity)
    if not ok or not position then return nil end
    if position.x == 0.0 and position.y == 0.0 then return nil end
    return position
end

local function safeRotation(entity)
    if not entity or entity == 0 then return nil end
    local ok, rotation = pcall(GetEntityRotation, entity)
    if not ok then return nil end
    return rotation
end

--[[
    ================================================================================================
    IS THIS SERVER-SIDE POSITION A FACT, OR IS IT JUST WHERE WE PUT THE CAR?
    ================================================================================================

    A server-side entity's position is maintained by its network owner. Once the driver has walked
    away and ownership has lapsed, the value the server holds stops being updated - and what it is
    stale AT is the position the server created the entity with. So a stale read does not look like
    an error. It looks like a perfectly ordinary position, and it is the position from BEFORE the
    drive.

    That is the 1.0.15 bug exactly: a correct parked position, written by the client that was
    driving, overwritten seconds later on despawn by a read that had never moved. Three flags on
    the live entry currently stand between that read and the row, and they work - but they are a
    heuristic about who might have moved the vehicle, not a test of whether the number is real.

    This is the test. We know what the stale value would be, because we wrote it: it is the
    position the entity was created at. If the read has not moved from there, it carries no
    information and is refused. If it has moved, something simulated the vehicle and the value is
    a fact.

    The one thing it gets wrong is a vehicle driven away and returned to within a few centimetres
    of where it started, whose real position is then refused - and refusing it leaves the stored
    position, which in that case is correct anyway. A false negative that costs nothing is the
    right side to be wrong on.

    Returns the position and rotation, or nil.
]]
local function poseIfFresh(entry)
    if not entry or not entry.entity then return nil end

    local position = safeCoords(entry.entity)
    if not position then return nil end

    local sx, sy, sz = tonumber(entry.spawnX), tonumber(entry.spawnY), tonumber(entry.spawnZ)

    -- Nothing to compare against, so nothing can be proven either way. An adopted vehicle has
    -- no spawn position because the server did not place it; its position was read from the
    -- world in the first place, which is the case this test is not about.
    if sx and sy and sz then
        local dx, dy, dz = position.x - sx, position.y - sy, position.z - sz

        -- Five centimetres, the same threshold the writer uses to decide a position changed.
        if (dx * dx + dy * dy + dz * dz) < (0.05 * 0.05) then
            return nil
        end
    end

    return position, safeRotation(entry.entity)
end

local function safeExists(entity)
    if not entity or entity == 0 then return false end
    local ok, exists = pcall(DoesEntityExist, entity)
    return ok and exists == true
end

local function safeDelete(entity)
    if not entity or entity == 0 then return end
    pcall(DeleteEntity, entity)
end

Spawn.safeCoords = safeCoords
Spawn.safeRotation = safeRotation

--[[
    Give up an entity for good.

    Condemned UNCONDITIONALLY, including when the delete appears to succeed, because at this
    moment we cannot tell whether it did - see the note on `condemned`. The sweep clears it
    when `GetAllVehicles` stops listing the handle, and not before.
]]
local function release(entity)
    if not entity or entity == 0 then return end

    ours[entity] = nil
    condemned[entity] = condemned[entity] or Park.ticks()

    pcall(DeleteEntity, entity)
end

Spawn.release = release

--[[
    Is this entity one we created?

    Asked by the adoption path. A vehicle of ours that a player gets into before it has been
    dressed carries no `vpark:id` statebag yet, so the client cannot tell it apart from an
    ambient car - and offering it as a new candidate would write a SECOND row for a vehicle
    that already has one, with whatever random plate the model spawned with.

    That is how one car became two records and two records became four vehicles.
]]
function Spawn.owns(entity)
    if not entity or entity == 0 then return nil end
    return ours[entity]
end

--[[
    Wait for an RPC-created entity to become one the natives will accept.

    -------------------------------------------------------------------------------------------
    THE FALLBACK PATH ONLY. NEVER CALL THIS ON A SERVER-SETTER ENTITY.
    -------------------------------------------------------------------------------------------

    `CreateVehicle` returns a handle synchronously and the entity is NOT usable when it does.
    For a frame or two afterwards every native against that handle fails:

        script error in native 000000009e35dab6: Tried to access invalid entity: 135949

    1.0.1 saw `DoesEntityExist` answer false in that window and concluded the test was
    worthless. 1.0.2 wrapped the configuration in a pcall so the failure was survivable, and
    treated it as the vehicle's fault: warn, delete, back off, try again. The vehicle never
    spawned, and every attempt leaked a copy. Waiting is the right answer on THAT path.

    IT IS THE WRONG ANSWER ON THE OTHER ONE, and 1.0.4 applied it to both. The CFX
    documentation on server setter natives:

        "Server setter natives immediately and guaranteed register an entity with the server,
         but the entity is initially orphaned - it will not be simulated nor exist in the game
         world until a suitable client is within scope."

    So `DoesEntityExist` on a setter entity is false BY DESIGN until a client takes ownership.
    Waiting three seconds for it and then deleting the vehicle meant deleting it at about the
    moment a client had streamed it in, which on a live server read as vehicles appearing and
    vanishing again - and sitting in the wrong place while they were there, because the restore
    instruction that dresses and places them was never sent.

    Bounded, because an entity nobody ever takes ownership of never becomes ready and this must
    not be an unbounded loop. The one extra frame after it first answers true is deliberate:
    existing and being fully assigned are one tick apart, and the natives want the second one.
]]
local function waitUntilReady(entity, timeoutMs)
    local deadline = Park.ticks() + (tonumber(timeoutMs) or 3000)

    while Park.ticks() < deadline do
        if safeExists(entity) then
            Wait(0)
            return safeExists(entity)
        end
        Wait(0)
    end

    return false
end

-- ---------------------------------------------------------------------------------------
-- Players
-- ---------------------------------------------------------------------------------------

--[[
    Every online player's position and routing bucket.

    Built fresh each pass rather than cached, because a cached position is a player who
    teleported and whose vehicles are still streaming around where they used to be.

    A player whose ped does not exist yet - still connecting, still in the multicharacter
    screen - is skipped entirely. Their coordinates at that moment are the spawn point, and
    spawning every vehicle near the spawn point for everybody who is loading in is a real and
    unpleasant failure mode.
]]
local function onlinePlayers()
    local out = {}

    for _, src in ipairs(GetPlayers()) do
        src = tonumber(src)
        local ped = GetPlayerPed(src)

        if ped and ped ~= 0 and DoesEntityExist(ped) then
            local position = GetEntityCoords(ped)

            -- The spawn point, near enough. A ped that has not been placed yet reports the
            -- origin or the default spawn, and neither is where the player will be.
            if position and (position.x ~= 0.0 or position.y ~= 0.0) then
                out[#out + 1] = {
                    src = src,
                    x = position.x,
                    y = position.y,
                    z = position.z,
                    bucket = GetPlayerRoutingBucket(src) or 0,
                }
            end
        end
    end

    return out
end

Spawn.onlinePlayers = onlinePlayers

local function radiusFor(record)
    local perClass = streaming().classRadius
    if type(perClass) == 'table' then
        local specific = tonumber(perClass[record.class])
        if specific then return specific end
    end
    return tonumber(streaming().spawnRadius) or 250.0
end

--[[
    The largest radius any vehicle could be wanted at.

    The grid query has to ask for THIS, not for `spawnRadius`, because the per-class radius is
    applied afterwards as a narrowing filter. A class radius larger than the global one would
    otherwise do nothing at all: the query would already have cut the set at the smaller
    distance, and a filter can only ever remove more.

    Cached, because it is read once per player per pass and the config does not change between
    them. A resource restart rebuilds it.
]]
local queryRadiusCache

local function queryRadius()
    if queryRadiusCache then return queryRadiusCache end

    local largest = tonumber(streaming().spawnRadius) or 250.0

    local perClass = streaming().classRadius
    if type(perClass) == 'table' then
        for _, value in pairs(perClass) do
            local radius = tonumber(value)
            if radius and radius > largest then largest = radius end
        end
    end

    queryRadiusCache = largest
    return largest
end

function Spawn.invalidateRadius()
    queryRadiusCache = nil
end

-- ---------------------------------------------------------------------------------------
-- Creating
-- ---------------------------------------------------------------------------------------

--[[
    Nominate the client that will dress and place a vehicle.

    The nearest player, because they are the one whose machine certainly has the map streamed
    in around it - which is what every placement decision needs. A distant client would answer
    "the space is free" for an area it cannot see.
]]
local function nominate(record, players)
    local best, bestDistance

    for _, player in ipairs(players) do
        if player.bucket == record.bucket then
            local dx, dy = player.x - record.pos_x, player.y - record.pos_y
            local distance = dx * dx + dy * dy
            if not bestDistance or distance < bestDistance then
                best, bestDistance = player, distance
            end
        end
    end

    return best
end

--[[
    One vehicle failed to spawn. Decide when, or whether, to try it again.

    -------------------------------------------------------------------------------------------
    THE BACKOFF ESCALATES, AND IT STOPS
    -------------------------------------------------------------------------------------------

    A flat ten seconds was not enough. A vehicle whose model this build does not have, or whose
    entity never becomes ready, fails identically every time, so a flat retry is an infinite
    loop with a delay in it - one that creates and deletes an entity on every turn, and on the
    console reads as a vehicle spawning over and over.

    10s, 20s, 40s, 80s, then stop and say so once. Cleared only when a vehicle actually reaches
    a client, in `dress`.
]]
noteFailure = function(record, why)
    local count = (failures[record.id] or 0) + 1
    failures[record.id] = count

    stats.failed = stats.failed + 1

    -- Once per vehicle, not once per attempt. The old code warned on every pass, which is a
    -- wall of identical lines hiding the one line that would have explained it.
    if count == 1 then
        Park.warn('could not spawn %s (model %s): %s',
            record.id, tostring(record.model_name or record.model), tostring(why))
    end

    if count >= 5 then
        Park.error('%s (%s) failed to spawn %d times running - it will not be retried this session',
            record.id, tostring(record.model_name or record.model), count)
        Park.error('the usual causes are a model this build does not have, or an entity limit already reached')
        record.invalidModel = true
        deferred[record.id] = nil
        return
    end

    deferred[record.id] = Park.ticks() + math.min(120000, 10000 * (2 ^ (count - 1)))
end

--[[
    Everything that is done to a vehicle after it is created.

    -------------------------------------------------------------------------------------------
    TWO HALVES, AND ONLY ONE OF THEM IS ALLOWED TO MATTER
    -------------------------------------------------------------------------------------------

    A server-setter entity is registered and ORPHANED: it does not exist in the game world
    until a client is within scope, so the natives that touch a world entity - the pose, the
    routing bucket - may refuse. The natives that touch its SERVER-SIDE record - the statebags
    - work regardless, because the server owns them.

    1.0.4 ran the whole thing under one pcall, so a pose write that failed on an orphaned
    entity took the identity statebag down with it and the vehicle was thrown away as
    unconfigurable.

    So: the world half is best effort and its failure is not reported, and the statebag half
    decides whether this worked. The pose is not lost by that - the position and heading were
    arguments to the creation native, and the client's placement pass sets the full rotation
    from the restore instruction a moment later, which is where the pose is settled anyway.
]]
local function configure(entity, record)
    --[[
        The world half. Best effort.

        Full rotation, and never a heading afterwards. See the note in client/placement.lua:
        setting the heading would flatten the pitch a car parked on a slope actually has.
    ]]
    pcall(function()
        SetEntityCoords(entity, record.pos_x, record.pos_y, record.pos_z, false, false, false, false)
        SetEntityRotation(entity, record.rot_x, record.rot_y, record.rot_z, 2, true)
    end)

    pcall(SetEntityRoutingBucket, entity, record.bucket or 0)

    local entityConfig = streaming().entity or {}

    if entityConfig.orphanMode ~= false and SetEntityOrphanMode then
        -- 2: keep the entity even when no player is near it. We decide when it goes.
        pcall(SetEntityOrphanMode, entity, 2)
    end

    local culling = tonumber(entityConfig.cullingRadius) or 0
    if culling > 0 and SetEntityDistanceCullingRadius then
        pcall(SetEntityDistanceCullingRadius, entity, culling)
    end

    --[[
        The server-side half. THIS is what has to work.

        The id is replicated to everybody in scope. It is how a client knows this entity is
        ours - the placement code refuses to delete a vehicle carrying one, and the panel and
        the API both resolve an entity to a record through it. A vehicle without it is a
        vehicle nothing can identify, which is the shape of every leak this resource has had.
    ]]
    local identified = pcall(function()
        local state = Entity(entity).state

        state:set('vpark:id', record.id, true)

        --[[
            HOLD IT STILL BEFORE ANY CLIENT CAN SIMULATE IT.

            This is what stops a restored vehicle ending up under the map.

            A server-created entity arrives on a client and is simulated immediately, and the
            collision around it may not have streamed in yet - so it falls, and by the time the
            ground exists it is beneath it. The placement pass freezes it, but that runs after
            `waitForEntity`, after the model check and after the properties, which is seconds
            later. The vehicle has already gone through the floor by then, and the placement
            then carefully positions a vehicle that is somewhere else entirely.

            A replicated bag is the documented answer for server-setter entities, and it is the
            only one that acts on EVERY client rather than the one we nominated - which matters,
            because any of them may be the one simulating the fall. See the handler in
            client/stream.lua: it freezes on sight and never unfreezes, and the server clears
            this once the vehicle is placed.
        ]]
        state:set('vpark:hold', true, true)

        if record.plate then
            state:set('vpark:plate', record.plate, true)
        end

        -- Deformation is applied by EVERY client, locally, which is what makes two players see
        -- the same dents. Hence a replicated bag rather than a targeted event.
        --[[
            An empty `d` is a real answer - "this car has no dents" - and it is stored as one so
            that a repair can clear the dents at all. See `Deformation.read`. There is still
            nothing to replicate for it: every client would receive a list of no points and apply
            none of them.
        ]]
        local deformation = record.properties and record.properties.deformation
        local hasPoints = type(deformation) == 'table'
            and ((type(deformation.d) == 'table' and #deformation.d > 0) or deformation.external == true)

        if deformation and hasPoints and Config.Deformation and Config.Deformation.enabled ~= false then
            state:set('vpark:deform', {
                v = record.updated_at,
                d = deformation.d,
                g = deformation.g,
            }, true)
        end
    end)

    -- Statebags another resource expects on the vehicle. Individually protected, and never a
    -- reason to throw the vehicle away: a missing third-party bag is that resource's problem.
    if record.statebags and Config.Save and Config.Save.fields and Config.Save.fields.statebags ~= false then
        for key, value in pairs(record.statebags) do
            local ok = pcall(function() Entity(entity).state:set(key, value, true) end)
            if not ok then
                Park.debug('could not restore statebag `%s` on %s', tostring(key), record.id)
            end
        end
    end

    return identified
end

--[[
    Put one vehicle into the world. The native call, and nothing else.

    -------------------------------------------------------------------------------------------
    WHY THIS IS `CreateVehicleServerSetter` AND NOT `CreateVehicle`
    -------------------------------------------------------------------------------------------

    THIS IS THE ROOT CAUSE OF THE MULTIPLICATION, AND 1.0.1, 1.0.2 AND 1.0.3 ALL MISSED IT.

    Server-side `CreateVehicle` is an RPC. It returns a handle immediately, but the entity is
    not created until a client has been asked to make it and has answered. Until that round
    trip completes the handle refers to nothing, and every native against it fails:

        script error in native 000000009e35dab6: Tried to access invalid entity: 135949

    That window is where all three previous releases went wrong. 1.0.1 saw `DoesEntityExist`
    answer false in it and concluded the check was worthless. 1.0.2 wrapped the configuration
    in a pcall and treated the failure as the vehicle's fault - warn, delete, back off, retry -
    so the vehicle never spawned, and each attempt left an undressed copy behind because the
    delete failed for the same reason the configuration did. 1.0.3 changed nothing here.

    `CreateVehicleServerSetter` is not an RPC. The CFX documentation is explicit: server setter
    natives "immediately and guaranteed register an entity with the server", orphaned until a
    client comes into scope. There is no window. It also supports every vehicle type rather
    than automobiles alone, which is a second bug fixed by the same line: a boat or a
    helicopter created through the RPC path is exactly the kind of vehicle that never became
    real.

    The price is the type string, which the server cannot work out for itself. See
    `Classes.setterType` and the `vehicle_type` column.

    `CreateVehicle` remains as a fallback for a build without the setter native, with the wait
    in `waitUntilReady` behind it. That combination is what the rest of the ecosystem does, and
    it works; it is simply not as good as not having the race at all.
]]
local function spawnEntity(record)
    local heading = record.rot_z or 0.0

    if CreateVehicleServerSetter then
        local kind = Classes.setterType(record.class, record.vehicle_type)

        local ok, entity = pcall(CreateVehicleServerSetter,
            record.model, kind,
            record.pos_x, record.pos_y, record.pos_z,
            heading)

        -- `true`: the entity is registered and orphaned, and must NOT be waited on.
        if ok and entity and entity ~= 0 then return entity, true end

        Park.debug('the setter native did not create %s as `%s` - falling back', record.id, kind)
    end

    local ok, entity = pcall(CreateVehicle,
        record.model,
        record.pos_x, record.pos_y, record.pos_z,
        heading,
        true,   -- networked
        true)   -- script-owned, so the engine does not treat it as ambient

    -- `false`: an RPC handle, which refers to nothing until a client has answered.
    if ok and entity and entity ~= 0 then return entity, false end

    return nil, false
end

--[[
    Create one vehicle in the world.

    Returns the entity, or nil.

    THE ORPHAN MODE LINE IS LICENCE TO EXIST. Without it the engine deletes a server-created
    entity as soon as no player is near it, which is a spawn-delete loop at our own radius
    boundary: we create it because a player is 240 metres away, the engine collects it because
    no client has it in scope, we create it again on the next pass. Orphan mode 2 means the
    entity lives until we say otherwise.

    It degrades silently on a build without the native, and the symptom there is vehicles that
    occasionally have to be re-created - wasteful, not broken.
]]
function Spawn.create(record, players)
    if record.invalidModel then return nil end
    if Store.isLive(record.id) then return nil end
    if pending[record.id] then return nil end

    -- Nominated BEFORE anything is created. An early return after `CreateVehicle` has to
    -- delete what it made, and the cheapest way not to get that wrong is to have nothing to
    -- delete.
    local placer = nominate(record, players or onlinePlayers())
    if not placer then return nil end

    local entity, viaSetter = spawnEntity(record)

    --[[
        A HANDLE OF ZERO IS THE ONLY FAILURE HERE.

        `spawnEntity` has already tried the setter native and, if this build lacks it, the RPC
        one. Nothing came back, so nothing was created and there is nothing to clean up.

        Every other answer IS an entity, and it is ours - including ours to delete if we later
        decide not to keep it, which is what `release` is for. 1.0.1 tested `DoesEntityExist`
        here instead, saw the false it answers for a frame or two after an RPC creation,
        concluded the creation had failed, and returned WITHOUT deleting what it had made.
    ]]
    if not entity or entity == 0 then
        noteFailure(record, 'the game would not create it')
        return nil
    end

    --[[
        WRITTEN DOWN BEFORE ANYTHING ELSE CAN HAPPEN TO IT.

        In both books, in this order, and before a single other native touches the entity:

          `ours`       so that whatever goes wrong from here on, the handle can still be found
                       and deleted. This is what was missing: an entity that failed before its
                       statebag was set existed in the world and appeared in no index at all.

          `Store.live` so that the next streaming pass does not create a second one.

          `pending`    so that the timeout sweep collects it if the thread below never
                       finishes.
    ]]
    ours[entity] = record.id

    Store.setLive(record.id, {
        entity = entity,
        placer = placer.src,
        placedAt = Park.ticks(),
        -- Not usable yet. `ready` becomes true when a client has been told to restore it.
        ready = false,

        --[[
            WHERE THE SERVER PUT IT. This is what a stale server-side read returns, so it is
            what makes a stale read detectable. See `poseIfFresh`.
        ]]
        spawnX = record.pos_x,
        spawnY = record.pos_y,
        spawnZ = record.pos_z,
    })

    pending[record.id] = Park.ticks()

    -- The entity is not usable for another frame or two. Everything else happens on its own
    -- thread so the streaming pass keeps its millisecond budget.
    CreateThread(function() dress(record, entity, placer.src, viaSetter) end)

    return entity
end

--[[
    Wait for the entity, then configure it and hand it to a client.

    Runs on its own thread, once per created vehicle. Every exit from here either leaves a
    working vehicle registered or releases the handle: there is no path that leaves an entity
    in the world and nothing pointing at it.
]]
dress = function(record, entity, placerSrc, viaSetter)
    --[[
        THE SETTER PATH IS NOT WAITED ON, AND THAT IS THE WHOLE OF THIS FIX.

        A setter entity is registered the moment the native returns - that is its guarantee -
        and orphaned until a client comes into scope. `DoesEntityExist` is therefore false by
        design, and 1.0.4 waited three seconds for it and then deleted the vehicle. On a live
        server that read as vehicles appearing and disappearing again, because the delete
        landed at about the moment a client had streamed the entity in.

        The waiting that this vehicle genuinely needs happens on the CLIENT, in
        `vpark:client:restore`, which already waits up to twelve seconds for the entity to
        arrive before dressing and placing it. That is the right place for it: the client is
        the machine the entity is waiting for.
    ]]
    local ready = viaSetter or waitUntilReady(entity, tonumber(streaming().readyTimeout) or 5000)

    --[[
        Still ours?

        The wait above yields, and a despawn - the player drove off, an admin deleted it, the
        server emptied - can happen while it does. Acting on a stale entity here would put a
        vehicle back in the world that something has already decided should not be.
    ]]
    local entry = Store.live(record.id)
    if not entry or entry.entity ~= entity then
        release(entity)
        return
    end

    if not ready then
        Park.warn('%s did not become a usable entity in time - removing it', record.id)
        pcall(Spawn.despawn, record.id, 'entity never became ready')
        noteFailure(record, 'the entity never became usable')
        return
    end

    -- `configure` answers whether the IDENTITY was set, not whether every native worked. On an
    -- orphaned entity the world-facing half is expected to refuse; see its header.
    local ok, configured = pcall(configure, entity, record)
    configured = ok and configured

    local gotId, netId = pcall(NetworkGetNetworkIdFromEntity, entity)
    if not gotId then netId = nil end

    --[[
        A configuration that raised, or an entity with no network id, is not usable.

        No network id means no client can ever be told to dress or place it: the restore
        instruction is addressed by network id. Either way the answer is the same - despawn,
        which releases the handle, and back off.
    ]]
    if not configured or not netId or netId == 0 then
        Park.warn('%s was created but could not be %s - removing it',
            record.id, configured and 'addressed' or 'configured')

        pcall(Spawn.despawn, record.id, 'configuration failed')
        noteFailure(record, configured and 'it had no network id' or 'it could not be configured')
        return
    end

    entry.netId = netId
    entry.ready = true

    --[[
        Whether the entity is real YET is not a failure and is not waited on - see `dress`.
        It is worth knowing at debug level, because "the client never took it" and "the client
        took it immediately" are the two ends of every streaming question this resource gets
        asked, and the answer is one line in the log rather than a guess.
    ]]
    if safeExists(entity) then
        entry.seen = true
    else
        Park.trace('%s is registered and not yet in the world - the client will pick it up', record.id)
    end

    -- It exists, it is dressed and a client can be told about it. THIS is a success, and it is
    -- the only place the failure counter is cleared.
    failures[record.id] = nil

    sendRestore(record, placerSrc, netId)

    stats.spawned = stats.spawned + 1
    Park.debug('created %s (%s) for player %d', record.id, tostring(record.model_name), placerSrc)

    Ownership.onRestored(record, entity, netId)
end

-- ---------------------------------------------------------------------------------------
-- Removing
-- ---------------------------------------------------------------------------------------

--[[
    Take a vehicle out of the world without forgetting it.

    Despawning is NOT deleting: the row stays, and the vehicle comes back the moment somebody
    walks near it. The distinction matters enough that the two live in different files -
    `server/lifecycle.lua` is the one that can actually remove a vehicle from existence.
]]
function Spawn.despawn(id, reason)
    local entry = Store.live(id)
    if not entry then return false end

    --[[
        THE BOOKKEEPING COMES FIRST AND CANNOT FAIL.

        Everything below this point touches an entity, and touching a server-side entity can
        raise - see `safeCoords`. An earlier version read the pose first and cleared the state
        last, so a raise left the vehicle registered as live with an entity that was on its way
        out. Nothing ever cleared it, the streaming pass died on the same vehicle every tick,
        and the resource stopped streaming while looking perfectly healthy.

        Clearing first means the worst case is a vehicle whose final position was not saved -
        it comes back where it was a minute ago - rather than a resource that has stopped.
    ]]
    local entity = entry.entity
    local placer = entry.placer

    Store.setLive(id, nil)
    pending[id] = nil
    deferred[id] = nil

    --[[
        One last read of where it actually ended up - BUT ONLY IF IT COULD HAVE MOVED.

        A vehicle that is still frozen has not moved. It cannot: a frozen entity is not
        simulated, nothing can push it, and the wake handlers unfreeze it before a player can
        touch it. Its stored position is already the truth.

        Reading it anyway was a slow drift. Placement settles an entity by a few centimetres,
        collision streaming in nudges it, and each of those was read back and written down on
        every despawn - so a car parked and passed a hundred times moved a little further each
        time, and "it is not quite where I left it" is a complaint that builds rather than
        appears.

        So the pose is re-read only for a vehicle that was awake, which is the only kind that
        can have gone anywhere. Best effort even then, through the safe accessors: an entity
        nobody has in scope may not answer.
    ]]
    local record = Store.get(id)
    --[[
        `driven`: somebody has sat in it since it was restored.

        A vehicle that was merely WOKEN has not been driven, and waking is what happens to
        every vehicle a player walks past. A woken vehicle is simulated and can roll on a
        camber, so reading its pose back here would record the roll as the place its owner
        left it. Only a person driving it can change where it lives.

        `nudged`: it is standing in a spot the search invented rather than the one it belongs
        in, so reading it back would write that spot down. See the `restored` handler.
    ]]
    --[[
        `parked`: the client that was driving already told us exactly where it left this, in
        `vpark:server:parked`. That report is better information than anything readable here.

        A server-side entity's position is maintained by its network owner, so once the driver
        has walked away the value this function would read is stale - and stale at the position
        the server created the entity with, which is the position from before the drive. Reading
        it would replace a correct answer with an old one.
    ]]
    local couldHaveMoved = entry.driven == true and entry.seen == true
        and not entry.nudged and not entry.parked

    if record and couldHaveMoved and safeExists(entity) then
        -- `poseIfFresh` rather than a bare read: see its note. The flags above say who MIGHT
        -- have moved it; this says whether the number actually moved.
        local position, rotation = poseIfFresh(entry)

        if position and rotation then
            Store.update(id, {
                pos_x = Park.coord(position.x),
                pos_y = Park.coord(position.y),
                pos_z = Park.coord(position.z),
                rot_x = Park.angle(rotation.x),
                rot_y = Park.angle(rotation.y),
                rot_z = Park.angle(rotation.z),
            })
        end
    end

    if placer then
        pcall(TriggerClientEvent, 'vpark:client:forget', placer, id)
    end

    -- Through `release`, not a bare delete. An entity that cannot be read may still exist, and
    -- a delete that silently did not take is the leak this whole version is about; `release`
    -- keeps the handle until `GetAllVehicles` agrees it is gone.
    release(entity)

    stats.despawned = stats.despawned + 1
    Park.trace('despawned %s (%s)', id, reason or 'out of range')

    return true
end

-- ---------------------------------------------------------------------------------------
-- The pass
-- ---------------------------------------------------------------------------------------

local function wantedSet(players)
    local wanted = {}
    local order = {}

    local perPlayer = tonumber(streaming().maximumPerPlayer) or 0

    for _, player in ipairs(players) do
        local bucket = streaming().matchRoutingBucket ~= false and player.bucket or nil

        local candidates = Store.near(player.x, player.y, queryRadius(), bucket)

        -- Per-player cap, applied after sorting so the cap keeps the NEAREST rather than
        -- whichever the grid happened to iterate first.
        if perPlayer > 0 and #candidates > perPlayer then
            table.sort(candidates, function(a, b) return a.distanceSq < b.distanceSq end)
            for i = #candidates, perPlayer + 1, -1 do candidates[i] = nil end
        end

        for _, candidate in ipairs(candidates) do
            local record = candidate.record

            -- The per-class radius is applied here rather than in the query, because the
            -- query radius has to be the largest of them and the narrowing is per record.
            if candidate.distanceSq <= radiusFor(record) ^ 2 then
                local existing = wanted[record.id]
                if not existing then
                    wanted[record.id] = candidate.distanceSq
                    order[#order + 1] = record
                elseif candidate.distanceSq < existing then
                    wanted[record.id] = candidate.distanceSq
                end
            end
        end
    end

    if streaming().nearestFirst ~= false then
        table.sort(order, function(a, b)
            return (wanted[a.id] or math.huge) < (wanted[b.id] or math.huge)
        end)
    end

    return wanted, order
end

local function pass()
    local started = Park.ticks()
    local budget = tonumber(Config.Performance and Config.Performance.streamBudgetMs) or 3

    local players = onlinePlayers()

    if #players == 0 then
        -- Nobody online. Everything live is by definition wanted by nobody, and clearing it
        -- costs nothing and frees the entity budget for the next player to join.
        for id in pairs(Store.allLive()) do
            pcall(Spawn.despawn, id, 'no players online')
        end
        return
    end

    -- ------------------------------------------------------------- timeouts FIRST ---
    --
    -- Before anything else, and before the early return at the entity ceiling below, because
    -- this is the sweep that releases a leaked entity.
    --
    -- A vehicle whose nominated client never answered is still `live` and still `pending`.
    -- Clearing the pending flag without despawning it would leave the entity in the world,
    -- undressed and unplaced, forever - and once enough of those accumulate, `liveCount` hits
    -- the ceiling, the pass returns early, and this sweep never runs again. The resource stops
    -- spawning anything, permanently, with nothing in the console to say why.
    for id, sentAt in pairs(pending) do
        if Park.ticks() - sentAt > 20000 then
            pending[id] = nil
            Park.debug('no placement answer for %s after 20s - removing it and re-nominating', id)
            -- Individually protected. One vehicle that cannot be despawned must not stop the
            -- other three hundred from being.
            pcall(Spawn.despawn, id, 'no placement answer')
            stats.failed = stats.failed + 1
        end
    end

    --[[
        Vehicles waiting to be asked again.

        A client that could not take network control of a vehicle answered without dressing it,
        and the vehicle is standing frozen where the server put it. This is the second ask.
        Capped at three by the handler that sets `restoreAt`.
    ]]
    for id, entry in pairs(Store.allLive()) do
        if entry.restoreAt and Park.ticks() >= entry.restoreAt and not pending[id] then
            entry.restoreAt = nil

            local record = Store.get(id)
            if record and entry.netId and entry.placer then
                pending[id] = Park.ticks()
                sendRestore(record, entry.placer, entry.netId)
            end
        end
    end

    -- ONE call, not two. An earlier draft asked for the wanted set here and asked again
    -- before the spawn loop, which built the whole candidate list twice per pass - a grid
    -- query per player, a sort, and an allocation, every second, for an answer it already
    -- had.
    local wanted, order = wantedSet(players)

    -- ------------------------------------------------------------------ despawn ---
    local despawnRadius = tonumber(streaming().despawnRadius) or 350.0
    local despawnBudget = tonumber(streaming().despawnsPerPass) or 20
    local despawned = 0

    for id, entry in pairs(Store.allLive()) do
        if despawned >= despawnBudget then break end
        if not wanted[id] then
            local record = Store.get(id)

            if not record then
                pcall(Spawn.despawn, id, 'no record')
                despawned = despawned + 1
            else
--[[
                    ================================================================================
                    A VEHICLE SOMEBODY IS SITTING IN IS NEVER OUT OF RANGE.
                    ================================================================================

                    This measured the distance from each player to `record.pos_x` - THE STORED
                    POSITION, which is where the vehicle was last written down, not where it is.
                    For a car being driven those are different, and they diverge at the speed of
                    the car.

                    So: buy a car, drive away fast, and a few seconds later the stored position is
                    350 m behind you. The pass finds nothing near it, calls it out of range, and
                    DELETES THE CAR YOU ARE DRIVING. It comes back at the stored position the next
                    time anybody goes near there, which is the report: it vanishes and reappears at
                    the spawn point.

                    Two answers, and both are needed. The entity's own position when the server can
                    read it, because for a car with a driver in it that value is live and correct -
                    it is maintained by the network owner, who is the driver. And an occupant check,
                    because a vehicle with somebody in it must not be collected whatever any
                    distance says.
                ]]
                if entry.occupant and Bridge.playerName(entry.occupant) then
                    goto nextDespawn
                end

                local where = safeCoords(entry.entity)

                local fromX = where and where.x or record.pos_x
                local fromY = where and where.y or record.pos_y

                local nearest = math.huge
                for _, player in ipairs(players) do
                    local dx, dy = player.x - fromX, player.y - fromY
                    local distance = dx * dx + dy * dy
                    if distance < nearest then nearest = distance end
                end

                if nearest > despawnRadius * despawnRadius then
                    pcall(Spawn.despawn, id, 'out of range')
                    despawned = despawned + 1
                end
            end
        end

        ::nextDespawn::
    end

    -- ---------------------------------------------------------------- entity cap ---
    local maximumEntities = tonumber(streaming().maximumEntities) or 400
    if maximumEntities > 0 and Store.liveCount() >= maximumEntities then
        Park.trace('the entity ceiling of %d is reached; not creating any more this pass', maximumEntities)
        stats.lastPassMs = Park.ticks() - started
        return
    end

    -- -------------------------------------------------------------------- spawn ---
    local spawnBudget = tonumber(streaming().spawnsPerPass) or 6
    local created = 0

    --[[
        `attempted`, not `created`.

        The budget used to count successes, so a pass in which every creation FAILED counted
        zero and carried on down the whole candidate list - hundreds of attempts per second,
        each one logging. Counting attempts means a pass costs at most `spawnsPerPass` calls
        whether they work or not, which is what a budget is for.
    ]]
    local attempted = 0

    --[[
        How many vehicles are created and not yet handed to a client.

        A ceiling on this is a ceiling on how wrong things can go at once. Each one holds an
        entity that is not usable yet, and if something is preventing entities from becoming
        ready - a server at its limit, a client that has stopped acknowledging - then creating
        another six every second makes it worse rather than better.
    ]]
    local waiting = 0
    for _ in pairs(pending) do waiting = waiting + 1 end

    local waitingCeiling = math.max(spawnBudget * 2, 8)

    for _, record in ipairs(order) do
        if attempted >= spawnBudget then break end
        if waiting >= waitingCeiling then break end
        if Park.ticks() - started > budget then break end
        if Store.liveCount() >= maximumEntities and maximumEntities > 0 then break end

        if not Store.isLive(record.id) and not pending[record.id] then
            -- A vehicle that asked to be retried is retried, but not on the very next pass:
            -- whatever was blocking it a second ago is probably still there.
            local retryAt = deferred[record.id]
            if not retryAt or Park.ticks() > retryAt then
                deferred[record.id] = nil
                attempted = attempted + 1

                -- Individually protected, for the same reason as the despawns above. A model
                -- that raises on creation must cost one candidate, not the whole pass.
                local ok, entity = pcall(Spawn.create, record, players)

                if ok and entity then
                    created = created + 1
                    waiting = waiting + 1
                elseif not ok then
                    Park.error('creating %s raised: %s', record.id, tostring(entity))
                    -- It may have been created before it raised. Despawn covers both cases:
                    -- registered-and-created, and registered-and-not.
                    pcall(Spawn.despawn, record.id, 'creation raised')
                    deferred[record.id] = Park.ticks() + 30000
                end
            end
        end
    end

    stats.passes = stats.passes + 1
    stats.lastPassMs = Park.ticks() - started
    Park.observe(stats.passMs, stats.lastPassMs)
end

CreateThread(function()
    -- Nothing until the store is loaded and the framework has had a chance to come up.
    while not Runtime.ready() do Wait(500) end

    while true do
        Wait(tonumber(streaming().interval) or 1000)

        local ok, err = pcall(pass)
        if not ok then
            Park.error('the streaming pass raised: %s', tostring(err))

            --[[
                A pass that raised may have left something behind, so sweep immediately rather
                than waiting up to `reconcileInterval` for the scheduled one.

                This is the belt to the fix's braces. Every individual create and despawn is
                protected now, so a raise here should be impossible - but "should be
                impossible" is what the last two releases said about the vehicle that
                multiplied, and a sweep costs one walk of the vehicle pool.
            ]]
            pcall(Spawn.reconcile)

            -- Back off rather than raising once a second forever.
            Wait(5000)
        end
    end
end)

-- ---------------------------------------------------------------------------------------
-- Client answers
-- ---------------------------------------------------------------------------------------

--[[
    A client has finished placing a vehicle.

    The interesting part is `result.position`: the placement engine may have moved the vehicle
    to make it fit, and if it did, that is now where the vehicle IS and the row has to agree -
    otherwise the next restore puts it back at the blocked pose and moves it again, every
    restart, drifting a little each time.
]]
RegisterNetEvent('vpark:server:restored', function(id, result)
    local src = source

    if type(id) ~= 'string' or type(result) ~= 'table' then return end

    local entry = Store.live(id)
    if not entry or entry.placer ~= src then
        -- An answer from a client we did not ask. Not necessarily malicious - a re-nomination
        -- races with a late answer from the previous one - but not something to act on.
        return
    end

    --[[
        CLEARED HERE, AFTER THE CHECK, AND NOT BEFORE IT. `restoreFailed` below has always done
        it in this order; this one did not, and both halves of that mattered.

        `pending` is what the 20-second sweep collects a stuck vehicle by. Clearing it for an
        answer we are about to discard means the vehicle is never collected and never
        re-nominated: it stays in the world undressed and unplaced, counting towards
        `liveCount`. Enough of those and the ceiling is reached, the pass returns early, and the
        resource stops spawning anything with nothing in the console to say why - which is the
        failure the sweep's own note warns about.

        Two ways to get there. The honest one is the race the comment above describes: a
        re-nominated vehicle's flag cleared by the PREVIOUS client's late answer, so if the new
        nomination also goes quiet nothing collects it. The other is that this ran before any
        check at all, so any client could clear the flag for any id it knew by sending this
        message - and ids are not secret.
    ]]
    pending[id] = nil

    --[[
        The properties are believable again once the client that applied them says they went on.
        `dressed == false` leaves the guard up: the vehicle IS a stock car, and the next restore is
        what will fix it, not a capture of the wrong state.
    ]]
    if result.ok and result.dressed ~= false then
        entry.undressed = nil
    end

    if not result.ok then
        --[[
            ONLY ONE ANSWER DELETES THE VEHICLE, AND IT IS THE ONE THAT SAYS IT IS NOT THERE.

            Every other failure means the client could not REFINE a vehicle that the server had
            already created at its saved coordinates - so the vehicle is exactly where it
            belongs, and deleting it achieves nothing except making it disappear.

            Until 1.0.5 every failure despawned. A client that could not take control in time,
            a bay the search could not find room in, a raise inside the placement: all three
            deleted a correctly placed vehicle, and the streaming pass then created it again a
            second later. That loop is the flicker, and the create-delete churn behind it is
            most of what a server feels as lag from a persistence resource.

            `blocked` with `retry` is a real answer worth deferring - the bay was full and may
            not be in fifteen seconds - but the vehicle STAYS while we wait.
        ]]
        if result.reason == 'gone' then
            Park.debug('%s was gone before the client could place it', id)
            pcall(Spawn.despawn, id, 'entity gone')
            stats.failed = stats.failed + 1
            return
        end

        --[[
            NO CONTROL MEANS THE VEHICLE WAS NEVER DRESSED, SO WE ASK AGAIN.

            The client takes network control before it writes a single property, because a
            property written without control is written into the void - which is what made
            vehicles come back the wrong colour. So an answer of `no_control` is not a vehicle
            that was placed imperfectly, it is a vehicle that was not touched at all.

            Accepting it would leave a stock car standing where a modified one belongs, and
            the next capture would write that stock state over the real one. So the vehicle
            stays exactly where it is - held frozen by `vpark:hold`, at the coordinates the
            server created it at - and we ask again in a moment.

            Three tries. A freshly created entity has no owner and the first request usually
            wins; needing four means something else is holding it, and asking forever is the
            churn every other fix in this file exists to stop. After the third the vehicle is
            simply left alone: correctly placed, undressed, and never captured, because the
            client never tracked it.
        ]]
        local tries = (entry.restoreTries or 0) + 1
        entry.restoreTries = tries
        entry.seen = true

        if result.retry and tries <= 3 then
            entry.restoreAt = Park.ticks() + 4000
            Park.debug('%s: %s on try %d - asking again', id, tostring(result.reason), tries)
            return
        end

        Park.debug('%s could not be refined (%s) - keeping it where the server put it',
            id, tostring(result.reason))

        entry.restoreAt = nil
        entry.placedAt = Park.ticks()
        entry.frozen = false

        -- The hold comes off even though we gave up. The vehicle is at the coordinates the
        -- server created it at, which is where it belongs; leaving the bag set would re-freeze
        -- it on every client that later came into scope, including under a player driving it.
        pcall(function() Entity(entry.entity).state:set('vpark:hold', nil, true) end)

        stats.forced = (stats.forced or 0) + 1
        return
    end

    entry.placedAt = Park.ticks()
    entry.frozen = result.frozen

    -- The client only answers after `waitForEntity` succeeded, so this is proof the entity
    -- genuinely exists. See the note in `sweepVanishing`.
    entry.seen = true

    -- Dressed and placed. Nothing left to ask.
    entry.restoreAt = nil
    entry.restoreTries = nil

    --[[
        RE-ASSERT THE ORPHAN MODE, NOW THAT THE ENTITY DEFINITELY EXISTS.

        `SET_ENTITY_ORPHAN_MODE` with KeepEntity is the only thing standing between a parked
        vehicle and the engine collecting it the moment no player is near - it is, in the CFX
        documentation's words, what guarantees the server will not delete it.

        It is set during configuration as well, but that runs against an entity that is
        registered and orphaned, and a call that quietly did nothing there would not be noticed
        until vehicles started vanishing from empty streets. This costs one native per restore
        and removes the doubt.
    ]]
    if SetEntityOrphanMode and (streaming().entity or {}).orphanMode ~= false then
        pcall(SetEntityOrphanMode, entry.entity, 2)
    end

    --[[
        The vehicle is placed, so the hold comes off.

        Left set, it would re-freeze the vehicle on every client that later came into scope -
        including a car somebody is driving, which would stop dead under them. Cleared here,
        the freezing that remains is the placement's own, which is the one that knows whether
        this vehicle should stay frozen.
    ]]
    pcall(function() Entity(entry.entity).state:set('vpark:hold', nil, true) end)

    if result.outcome then
        stats[result.outcome] = (stats[result.outcome] or 0) + 1
    end

    --[[
        ================================================================================
        A PLACE THE SEARCH INVENTED IS NEVER WRITTEN DOWN.
        ================================================================================

        The search runs when the saved bay is occupied, and it answers with the nearest spot
        that is not. That answer is a way to avoid two cars overlapping for the next few
        minutes. IT IS NOT WHERE THE VEHICLE BELONGS, and saving it means the vehicle never
        goes home again - the invented spot becomes the saved spot, and the next restore starts
        from there.

        Measured, with `/vparkwhere`, on three cars parked together:

            0TL1YS402S8YV  off by 1.250 m   dx +0.000  dy -1.250  dz +0.000
            0TL1YSE03933L  off by 1.250 m   dx +1.250  dy +0.000  dz +0.000

        1250 mm is exactly `Config.Placement.search.step`. Each of those cars had been moved
        one ring outwards, in a different direction, and the move had been written to the
        database - so they were not going to come back on their own.

        1.0.8 stopped the map from triggering that, and 1.0.11 stopped our own parked
        neighbours from triggering it. This is the line that means a future false positive
        costs one restore rather than the vehicle's real position: the car may stand in the
        wrong spot until the obstruction goes away, and the database still knows where it
        lives.

        A ground correction IS written, because that is a real correction to a stored Z that
        was wrong - it comes back as `grounded` or as `exact` with a moved Z, never as
        `nudged`.
    ]]
    if result.moved and result.outcome ~= 'nudged' and type(result.position) == 'table' then
        Store.update(id, {
            pos_x = result.position.x,
            pos_y = result.position.y,
            pos_z = result.position.z,
            rot_z = result.heading or 0.0,
        })

        Park.debug('%s was corrected to %s and its stored position was updated',
            id, tostring(result.outcome))

    elseif result.moved and result.outcome == 'nudged' then
        --[[
            And it must stay left alone.

            The despawn reads the final pose back for any vehicle that could have moved, and a
            vehicle standing in a spot the search invented has moved - so without this flag the
            invented spot would be written down the moment the player walked away, which is
            the whole thing this is preventing, one step later.

            Cleared when somebody actually drives it, in `vpark:server:touched`: a car that has
            been driven is wherever the driver left it, and that is a real position.
        ]]
        entry.nudged = true

        Park.debug('%s was moved aside to fit; its stored position is left alone so it can '
            .. 'go back when the way is clear', id)
    end
end)

RegisterNetEvent('vpark:server:restoreFailed', function(id, reason)
    local src = source
    if type(id) ~= 'string' then return end

    -- Only the client we actually asked. Without this any player could despawn any vehicle on
    -- the server by name - which the streaming pass would put straight back, so it is a waste
    -- of everybody's bandwidth rather than a way to destroy anything, but it is still not a
    -- message we should act on.
    local entry = Store.live(id)
    if not entry or entry.placer ~= src then return end

    pending[id] = nil

    Park.debug('client could not restore %s: %s', id, tostring(reason))
    pcall(Spawn.despawn, id, 'client failed')

    --[[
        Backed off, and not simply retried.

        The usual cause is `no_entity`: the client waited twelve seconds and the entity never
        arrived in its scope. Recreating it immediately asks the same client the same question
        and gets the same answer, which is a create-delete loop at one vehicle per second -
        the churn a server feels as lag.

        A record, not a counter, because this is a transient condition: the player walks
        closer, or another one arrives, and it works.
    ]]
    deferred[id] = Park.ticks() + 20000

    stats.failed = stats.failed + 1
end)

--[[
    A player interacted with a vehicle.

    `used` distinguishes SITTING IN IT from merely interacting with it, and the distinction is
    the whole basis of Section 9c. `touched_at` moves for anything; `last_used_at` moves only
    when a person got in. A car parked outside its owner's house is touched constantly and has
    not been driven since March, and one column cannot answer both questions.

    Written as a targeted update rather than through the dirty queue, because both columns are
    deliberately outside the delta hash - see `Store.hashOf` - and marking the whole row dirty
    for a timestamp would defeat the point of the hash.
]]
--[[
    A client has parked a vehicle we keep, and is telling us where.

    Sent once, the instant the driver gets out. It exists because that is the moment the answer
    is known and stops changing, and because both of the other ways of finding it out fail in
    the ordinary case of parking and leaving: the capture sweep may be seconds away, and the
    final read on despawn asks the server for coordinates no client has in scope any more.

    -------------------------------------------------------------------------------------------
    WHAT IS CHECKED, AND WHY THAT IS ENOUGH
    -------------------------------------------------------------------------------------------

    A client may only speak for a vehicle that is live, and only from close enough to have been
    sitting in it a moment ago. That bounds the damage to something a player could do anyway by
    driving the vehicle there, which is not damage.

    The distance is generous - a bike is left at speed and the ped lands some way from it - and
    it is checked at all so that a client cannot report a position for a vehicle on the other
    side of the map.
]]
--[[
    ================================================================================================
    A CLIENT MAY ONLY SPEAK FOR A VEHICLE IT IS ACTUALLY NEXT TO
    ================================================================================================

    `vpark:server:touched` and `vpark:server:parked` are net events, which means ANY client can
    trigger them for ANY id, and an id is not a secret: `vpark:id` is a replicated statebag, so
    every client that has ever been near a vehicle knows its id and keeps knowing it.

    The parked handler checked that the REPORTED POSITION was within 50 m of the reporting
    player's ped. That sounds like a proximity check and is not one, because the attacker chooses
    the reported position: send your own coordinates and the check passes from anywhere on the
    map. Any persistent vehicle whose id you had ever seen could be dragged to your feet, for
    good, from across the world - and `touched` needed no proof at all, so it could be used to
    mark a vehicle driven and make the despawn overwrite a correct position with a stale one,
    which is the 1.0.15 bug turned into a tool.

    `touched` also writes a row on every call, so it was a database write per message from an
    unauthenticated client.

    This is the proof, and it is the one an attacker cannot fabricate: THE DISTANCE BETWEEN THE
    PLAYER'S PED AND THE VEHICLE ENTITY, both read on the server. Neither value comes from the
    message. It is readable exactly when a client has the vehicle in scope, which is exactly when
    a player is sitting in it or standing beside it - so the honest path always passes, and a
    report from the other side of the map never does.

    Returns:
      true   proven next to it
      false  proven NOT next to it
      nil    could not tell, because the server cannot read the entity right now
]]
--[[
    How far the player is from a point, in three dimensions. The one place the distance is
    measured, so the two rules built on it below cannot drift apart.

    Returns the distance, or nil when either end cannot be read.
]]
local function pedDistanceTo(src, where)
    if not where then return nil end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end

    local who = safeCoords(ped)
    if not who then return nil end

    local dx, dy, dz = who.x - where.x, who.y - where.y, who.z - where.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--[[
    Is this player standing next to this entity?

    Both positions are read on the server, so neither comes from the client being checked. That
    is the whole point: see `nearEnoughToSpeakFor` below for the argument, and `Persist.adopt`
    for the other caller.

    true proven near, false proven not, nil could not tell.
]]
--[[
    An entity's position as the SERVER sees it, or nil when it cannot be read.

    A thin wrapper so callers outside this file get the safe read - the pcall, and the rejection of
    a reading at the origin, which means `could not read it` rather than `it is at the origin`.
    `Persist.adopt` uses it to check a client's claim about where a vehicle is against where the
    vehicle actually is.

    Reliable for an entity a client owns and has in scope, which is every entity anybody is
    offering. See `poseIfFresh` for the case it is NOT reliable in and what to do about that.
]]
function Spawn.entityPosition(entity)
    return safeCoords(entity)
end

function Spawn.playerIsNear(src, entity, metres)
    if not entity or entity == 0 then return nil end

    -- Not a connected player at all, which is a refusal and not an unknown. Kept separate from
    -- the nil below on purpose: `nil` means the positions could not be read and the caller is
    -- entitled to fall back to another proof, and a message from nobody is not that case.
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end

    local distance = pedDistanceTo(src, safeCoords(entity))
    if not distance then return nil end

    if distance <= (metres or 30.0) then return true end

    Park.debug('%d spoke for an entity %.0f m away - refused', src, distance)
    return false
end

--[[
    ================================================================================================
    A CLIENT MAY ONLY SPEAK FOR A VEHICLE IT IS ACTUALLY NEXT TO
    ================================================================================================

    `vpark:server:touched` and `vpark:server:parked` are net events, which means ANY client can
    trigger them for ANY id, and an id is not a secret: `vpark:id` is a replicated statebag, so
    every client that has ever been near a vehicle knows its id and keeps knowing it.

    The parked handler checked that the REPORTED POSITION was within 50 m of the reporting
    player's ped. That sounds like a proximity check and is not one, because the attacker chooses
    the reported position: send your own coordinates and the check passes from anywhere on the
    map. Any persistent vehicle whose id you had ever seen could be dragged to your feet, for
    good, from across the world - and `touched` needed no proof at all, so it could be used to
    mark a vehicle driven and make the despawn overwrite a correct position with a stale one,
    which is the 1.0.15 bug turned into a tool.

    `touched` also writes a row on every call, so it was a database write per message from an
    unauthenticated client.

    This is the proof, and it is the one an attacker cannot fabricate: THE DISTANCE BETWEEN THE
    PLAYER'S PED AND THE VEHICLE ENTITY, both read on the server. Neither value comes from the
    message. It is readable exactly when a client has the vehicle in scope, which is exactly when
    a player is sitting in it or standing beside it - so the honest path always passes, and a
    report from the other side of the map never does.

    Returns:
      true   proven next to it
      false  proven NOT next to it
      nil    could not tell, because the server cannot read the entity right now
]]
local function nearEnoughToSpeakFor(src, entry, metres, record)
    local answer = Spawn.playerIsNear(src, entry and entry.entity, metres)
    if answer ~= nil then return answer end

    --[[
        WHEN THE ENTITY CANNOT BE READ, MEASURE AGAINST THE ROW INSTEAD OF REFUSING.

        A deliberate trade, and it is the safer half of it. Refusing an unreadable entity would
        be the stricter rule and it risks the worst bug this resource has had: a legitimate
        `somebody got in` refused means the drive that follows is discarded and the vehicle comes
        back where it used to live. Five releases went into stopping that.

        The row's position is where the vehicle was left, which is where a player getting into it
        is standing - a real reference point the sender does not supply, just a looser one. The
        radius is widened to allow for a drive that has already happened without a report. What
        it gives up is precision; what it keeps is the part that matters, that a report from the
        other side of the map is refused.
    ]]
    if not record then return nil end

    local x, y, z = tonumber(record.pos_x), tonumber(record.pos_y), tonumber(record.pos_z)
    if not (Park.isFinite(x) and Park.isFinite(y) and Park.isFinite(z)) then return nil end

    local distance = pedDistanceTo(src, { x = x, y = y, z = z })
    if not distance then return nil end

    if distance <= math.max(metres or 30.0, 150.0) then return true end

    Park.debug('%d spoke for a vehicle %.0f m from its row - refused', src, distance)
    return false
end

RegisterNetEvent('vpark:server:parked', function(id, position, rotation)
    local src = source

    if type(id) ~= 'string' or type(position) ~= 'table' then return end

    local record = Store.get(id)
    local entry = Store.live(id)
    if not record or not entry then return end

    local x = tonumber(position.x)
    local y = tonumber(position.y)
    local z = tonumber(position.z)

    if not (Park.isFinite(x) and Park.isFinite(y) and Park.isFinite(z)) then return end
    if math.abs(x) < 0.5 and math.abs(y) < 0.5 then return end

    -- Close enough to have been in it. `GetEntityCoords` on the ped rather than on the vehicle:
    -- the vehicle may already be out of the server's reach, which is the whole point of this.
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end

    local ok, at = pcall(GetEntityCoords, ped)
    if not ok or not at then return end

    local dx, dy = at.x - x, at.y - y
    if (dx * dx + dy * dy) > (50.0 * 50.0) then
        Park.debug('%s: a parked report from %d came from %.0f m away - ignored',
            id, src, math.sqrt(dx * dx + dy * dy))
        return
    end

    --[[
        AND THE REPORTER MUST BE ABLE TO SPEAK FOR THIS VEHICLE.

        The distance test above compares the ped to the REPORTED position, which the sender
        chooses - it stops a report that contradicts itself and nothing else. This one compares
        the ped to the VEHICLE, on the server, using two values the sender does not supply.

        When the entity cannot be read - the player has stepped out and every client has lost
        scope in the same instant - fall back to `occupant`, which is who the server recorded
        getting in. Both are unforgeable, so one of them always answers.
    ]]
    local proven = nearEnoughToSpeakFor(src, entry, 30.0, record)

    if proven == false then return end
    if proven == nil and entry.occupant ~= src then
        Park.debug('%s: a parked report from %d that cannot be checked and was not the occupant',
            id, src)
        return
    end

    local patch = { pos_x = Park.coord(x), pos_y = Park.coord(y), pos_z = Park.coord(z) }

    if type(rotation) == 'table' then
        patch.rot_x = Park.angle(tonumber(rotation.x) or record.rot_x)
        patch.rot_y = Park.angle(tonumber(rotation.y) or record.rot_y)
        patch.rot_z = Park.angle(tonumber(rotation.z) or record.rot_z)
    end

    Store.update(id, patch)

    --[[
        THIS IS THE LAST WORD ON WHERE THIS VEHICLE IS, AND NOTHING MAY OVERWRITE IT.

        `parked` marks the pose as reported by the machine that was driving, at the moment the
        answer stopped changing. The despawn must not then read the entity's server-side
        coordinates over the top of it - see the note on `couldHaveMoved`, and the reason is
        worth stating here too because this line is what stops it.

        A server-side entity's position is maintained by its NETWORK OWNER. Once the driver has
        walked away and ownership has lapsed, the value the server holds is stale, and what it
        is stale AT is the position the server created the entity with - which is the position
        from BEFORE the drive.

        So 1.0.14 sent the correct position at the door and then, seconds later, overwrote it
        with the old one on the way out. The vehicle came back where it used to live, which is
        the same symptom 1.0.14 set out to fix.

        Cleared when somebody gets in again: from that moment the vehicle can move and this
        report is no longer the truth.
    ]]
    --[[
        WRITTEN NOW, NOT AT THE NEXT SWEEP.

        Getting out of a vehicle is the moment its position stops changing, and the moment a player
        expects it to be saved. `Config.Save.triggers.onExit` has always said so, and until now
        nothing called the function that honours it.
    ]]
    if Persist and Persist.touch then Persist.touch(id, 'onExit') end

    entry.parked = true
    entry.seen = true
    entry.nudged = nil

    -- Single use. `occupant` is permission to speak for this vehicle once, granted when the
    -- server watched somebody get in, and spent here. Otherwise it stands until the entry is
    -- dropped, and a player id is reused by the server the moment its slot is - so a standing
    -- permission outlives the person it was granted to.
    entry.occupant = nil

    Park.debug('%s was parked at %.2f, %.2f, %.2f', id, x, y, z)
end)

--[[
    The client that placed a vehicle says its neons held after all.

    Proven the same way as every other client message: the vehicle must be one we hold and the
    sender must be next to it.
]]
--[[
    A client saying it could not make a vehicle's neons hold.

    Logged at WARN so it appears on a server running at the default level, and with everything that
    decides the answer: what was asked for, what the game reported afterwards, whether that client
    had network control, and who the engine thinks owns the entity.

    This is the line that three releases of this bug have been missing, and the reason it was
    missing twice is that it was written on the client and looked for on the server.
]]
RegisterNetEvent('vpark:server:neonFailed', function(id, detail)
    local src = source

    if type(id) ~= 'string' or type(detail) ~= 'table' then return end

    local entry = Store.live(id)
    if not entry then return end
    if Spawn.playerIsNear and Spawn.playerIsNear(src, entry.entity, 60.0) == false then return end

    local function list(values)
        if type(values) ~= 'table' then return '?' end
        local out = {}
        for _, value in ipairs(values) do out[#out + 1] = tostring(value) end
        return table.concat(out, ',')
    end

    Park.warn('%s: neons would not hold on client %d - wanted %s, got %s, control %s, owner %s, '
        .. 'entity %s', id, src, list(detail.wanted), list(detail.got),
        tostring(detail.control), tostring(detail.owner), tostring(detail.exists))
end)

RegisterNetEvent('vpark:server:verified', function(id, group)
    local src = source

    if type(id) ~= 'string' or group ~= 'neons' then return end

    local entry = Store.live(id)
    if not entry then return end

    if Spawn.playerIsNear and Spawn.playerIsNear(src, entry.entity, 30.0) == false then return end

    entry.unverifiedNeons = nil
end)

RegisterNetEvent('vpark:server:touched', function(id, used)
    local src = source

    if type(id) ~= 'string' then return end

    local record = Store.get(id)
    if not record then return end

    --[[
        PROVEN BEFORE ANYTHING IS WRITTEN. See `nearEnoughToSpeakFor`.

        This handler took an id on trust and then marked the vehicle driven, unfrozen and no
        longer parked - which is permission for the despawn to overwrite a correct position with
        a stale one, the 1.0.15 bug turned into a tool. It also wrote a database row on every
        call, so it was one write per message from an unauthenticated client.

        A vehicle that is not in the world is not a vehicle anybody just got into, so that is
        refused outright. Ten metres, because the claim being made is `I am inside it` - widened
        to the row's position and a looser radius when the entity itself cannot be read, which
        `nearEnoughToSpeakFor` explains and argues for.
    ]]
    local entry = Store.live(id)
    if not entry then return end
    if nearEnoughToSpeakFor(src, entry, 10.0, record) ~= true then return end

    --[[
        Somebody got IN it, so it is awake and it can move.

        The strongest signal there is, and the earliest: it arrives when the door closes rather
        than on the next capture sweep. `Spawn.despawn` reads the final pose only for a vehicle
        that could have moved, and without this a player who got in, drove off and left the
        streaming radius between two sweeps would have the drive discarded.
    ]]
    if used then
        -- Who the server watched get in. The only thing left to check a parked report against
        -- once every client has lost scope and there is no distance to measure.
        entry.occupant = src

        --[[
            THE NEON GUARD IS NOT LIFTED BY SOMEBODY SITTING DOWN.

            It was, on the reasoning that whatever a person does to a vehicle they are in is
            deliberate. That is true of a person who changes something and false of the far more
            common one who gets in TO LOOK - which is exactly what a tester does, and it handed the
            capture permission to write the dark vehicle over the stored value at the one moment
            somebody was checking whether it had survived.

            The guard now lifts only when the client that placed the vehicle reports the neons
            actually held. Until then the stored value stands, which is the whole point of it. A
            player turning their own neons off still works: that happens after a successful restore,
            and a successful restore clears the guard.
        ]]

        entry.frozen = false
        entry.seen = true

        -- Driven, so wherever it ends up IS its position - including if the restore had had to
        -- stand it aside, and including overriding the last parked report.
        entry.driven = true
        entry.nudged = nil
        entry.parked = nil

        -- Somebody is driving it. Nothing may freeze it again.
        if entry.entity then
            pcall(function() Entity(entry.entity).state:set('vpark:hold', nil, true) end)
        end
    end

    local now = Park.now()
    record.touched_at = now

    -- Being touched also resets the semi-persistence countdown: somebody is using it.
    if record.offline_secs and record.offline_secs > 0 then
        record.offline_secs = 0
    end

    local sql, params

    if used then
        record.last_used_at = now
        record.warnedCleanup = nil

        sql = ('UPDATE %s SET `touched_at` = ?, `last_used_at` = ?, `offline_secs` = 0 WHERE `id` = ?')
            :format(Database.table('vehicles'))
        params = { now, now, id }
    else
        sql = ('UPDATE %s SET `touched_at` = ?, `offline_secs` = 0 WHERE `id` = ?')
            :format(Database.table('vehicles'))
        params = { now, id }
    end

    if Database.available() then
        Database.thread(function()
            Database.execute(sql, params)
        end)
    end
end)

--[[
    Delete every vehicle in the world that carries one of our ids and is not the entity we
    have registered for it.

    -------------------------------------------------------------------------------------------
    WHAT THIS IS FOR
    -------------------------------------------------------------------------------------------

    Two things, and the second is why it exists at all.

    ORPHANS. An entity we created and then lost track of - because a creation was misjudged as
    a failure, because a resource restart dropped the live table while the entities survived
    `SetEntityOrphanMode(2)`, or because something else deleted our record and not our entity.
    Nothing else will ever collect these: orphan mode is precisely an instruction not to.

    DUPLICATES. Several entities carrying the SAME `vpark:id`. That is the shape the
    multiplication bug took, and it is the one an operator actually sees: four Bisons in one
    parking space. The registered entity survives, every other copy goes.

    It runs on its own slow timer and at boot, and it is cheap: one pass over the server's
    vehicle list, a statebag read each. On a server with four hundred vehicles that is four
    hundred reads every thirty seconds.
]]
function Spawn.reconcile()
    if not GetAllVehicles then return 0 end

    local startedAt = Park.ticks()

    local ok, all = pcall(GetAllVehicles)
    if not ok or type(all) ~= 'table' then return 0 end

    local removed = 0
    local duplicates = 0
    local orphans = 0
    local unmarked = 0

    -- What the engine says is actually in the world. The only answer that does not lie about
    -- an entity in the not-ready state - see the note on `condemned`.
    local present = {}
    for index = 1, #all do present[all[index]] = true end

    for index = 1, #all do
        local entity = all[index]

        --[[
            OUR OWN BOOK IS ASKED FIRST, AND THE STATEBAG SECOND.

            The statebag is set during configuration, so an entity that failed BEFORE that step
            carries nothing at all. Every version up to 1.0.3 asked only the statebag, which
            meant the sweep could not see the exact entities the bug was producing - an
            undressed copy with a random plate, sitting on the vehicle's saved coordinates.

            `ours` is written the instant `CreateVehicle` returns, so it covers them. The
            statebag still matters for entities left behind by a PREVIOUS start of the
            resource, which our book cannot know about.
        ]]
        local id = ours[entity]
        local marked = false

        --[[
            The statebag is only asked for during the boot window, and that is a real saving.

            `GetAllVehicles` returns EVERY vehicle on the server, ambient traffic included -
            several hundred on a busy one, several thousand on a bad one. Reading a statebag
            off each of them, every fifteen seconds, forever, to find entities that our own
            book already knows about is most of what this sweep used to cost.

            The statebag answers one question our book cannot: which entities were left behind
            by a PREVIOUS start of this resource, whose handles we never saw. That question is
            only meaningful just after boot, and after that every entity of ours is in `ours`
            because we put it there.
        ]]
        if not id and Park.ticks() < bootWindow then
            local read = pcall(function() id = Entity(entity).state['vpark:id'] end)
            marked = read and type(id) == 'string'
            if not marked then id = nil end
        end

        if type(id) == 'string' then
            local record = Store.get(id)
            local live = Store.live(id)

            if not record then
                -- Ours, unknown to the store. Nothing will ever claim it.
                orphans = orphans + 1
                release(entity)
                removed = removed + 1

            elseif not live then
                -- The record exists but we have no entity registered for it, so this one is
                -- left over. Adopting it would be tempting and wrong: we cannot tell whether
                -- it was ever dressed or placed.
                orphans = orphans + 1
                release(entity)
                removed = removed + 1

            elseif live.entity ~= entity then
                -- A second copy of a vehicle we already have. THE ONE AN OPERATOR SEES.
                duplicates = duplicates + 1
                if not marked then unmarked = unmarked + 1 end
                release(entity)
                removed = removed + 1
            end
        end

        -- Yield periodically. A server at its entity limit has a long list here, and this
        -- runs on a timer rather than in response to anything urgent.
        if index % 200 == 0 then Wait(0) end
    end

    --[[
        The condemned list. Handles we have asked the engine to delete and have not yet seen
        it delete.

        This is where a failed `DeleteEntity` is finally noticed. A handle the engine no longer
        lists is genuinely gone and is forgotten; one it still lists is asked again.
    ]]
    local stuck = 0
    for entity, since in pairs(condemned) do
        if not present[entity] then
            condemned[entity] = nil

        elseif Park.ticks() - since > 120000 then
            -- Two minutes of asking. Say it once, loudly, and stop: a handle that will not go
            -- is a bug worth knowing about and not one worth spinning on forever.
            Park.error('entity %d would not delete after two minutes - giving up on it', entity)
            condemned[entity] = nil

        else
            stuck = stuck + 1
            pcall(DeleteEntity, entity)
        end
    end

    if removed > 0 then
        Park.warn('reconciliation removed %d stray vehicle(s): %d orphan(s), %d duplicate(s), %d of them unmarked',
            removed, orphans, duplicates, unmarked)
        stats.reconciled = (stats.reconciled or 0) + removed
    end

    if stuck > 0 then
        Park.debug('%d condemned entity(ies) are still in the world and were asked again', stuck)
    end

    stats.condemned = stuck

    Park.observe(stats.reconcileMs, Park.ticks() - startedAt)

    return removed
end

CreateThread(function()
    while not Runtime.ready() do Wait(500) end

    -- Long enough for several sweeps to have looked at everything, short enough that the
    -- steady-state cost arrives quickly. See the note inside `Spawn.reconcile`.
    bootWindow = Park.ticks() + 120000

    -- Once at boot, before the first streaming pass, so a restart that left entities behind
    -- starts clean rather than adding to them.
    Wait(2000)
    pcall(Spawn.reconcile)

    while true do
        Wait((tonumber(streaming().reconcileInterval) or 30) * 1000)
        pcall(Spawn.reconcile)
    end
end)

--[[
    How many vehicles are in each of the three states that can go wrong.

    `pending`   created and not yet confirmed by a client. A handful at a time is the streaming
                pass working; a number that only grows means clients are not answering.
    `condemned` handles the engine has been asked to delete and has not. Should be zero, or
                briefly non-zero between a despawn and the next reconciliation sweep.
    `waiting`   vehicles whose restore is going to be asked for again, because a client could
                not take network control of them.
]]
function Spawn.health()
    local pendingCount, waiting = 0, 0

    for _ in pairs(pending) do pendingCount = pendingCount + 1 end

    for _, entry in pairs(Store.allLive()) do
        if entry.restoreAt then waiting = waiting + 1 end
    end

    local condemnedCount = 0
    for _ in pairs(condemned) do condemnedCount = condemnedCount + 1 end

    return pendingCount, condemnedCount, waiting
end

function Spawn.stats()
    return stats
end

function Spawn.pending()
    return pending
end

--[[
    Everything the server knows about one vehicle it is holding, for `/vparkdiag`.

    Five releases were spent guessing at the contents of a live entry, because there was no way
    to look at one. `/vparkwhere` ended that from inside the game - a player reported `1.250 m`
    and that number named the cause in one reading. This is the same idea from the console: the
    flags that decide where a vehicle is allowed to be saved, next to where it actually is.

    The natives stay in this file so they go through the safe wrappers. A read that fails is
    reported as unreadable rather than raising, because a diagnostic that can kill the resource
    is worse than no diagnostic.
]]
function Spawn.inspect(id)
    local entry = Store.live(id)
    if not entry then return nil end

    local position = safeCoords(entry.entity)
    local rotation = safeRotation(entry.entity)

    local report = {
        entity = entry.entity,
        netId = entry.netId,
        exists = safeExists(entry.entity),
        placer = entry.placer,
        placedAt = entry.placedAt,
        adopted = entry.adopted == true,

        ready = entry.ready == true,
        seen = entry.seen == true,
        retryAt = entry.restoreAt,
        retries = entry.restoreTries or 0,

        frozen = entry.frozen == true,
        driven = entry.driven == true,
        parked = entry.parked == true,
        nudged = entry.nudged == true,

        occupant = entry.occupant,
    }

    -- The same condition the despawn uses, reported rather than acted on. If this says `no`
    -- and a vehicle is still being saved in the wrong place, the fault is not in the despawn.
    report.wouldReadPose = report.driven and report.seen
        and not report.nudged and not report.parked

    if position then
        report.x = Park.coord(position.x)
        report.y = Park.coord(position.y)
        report.z = Park.coord(position.z)
    end

    if rotation then
        report.heading = Park.angle(rotation.z)
    end

    return report
end
