--[[
    client/placement.lua

    Putting a vehicle back exactly where it was, including in places it barely fits.

    Read `Config.Placement`'s header first. It states the four mechanisms that move a restored
    vehicle away from its saved coordinates; this file is the four answers.

    -------------------------------------------------------------------------------------------
    WHY THE WORK HAPPENS HERE AND NOT ON THE SERVER
    -------------------------------------------------------------------------------------------

    The server creates the entity, because that is the only way a vehicle exists for everybody.
    But the server cannot see the map: it has no collision, no object pool, no shape tests and
    no `FreezeEntityPosition`. Every question that decides where a car actually goes can only
    be answered by a machine that has the world streamed in.

    So the sequence is:

        server   create the entity at the saved pose, frozen, marked with our statebag
        client   take control, kill its collision, measure the space, decide the final pose
        client   move it, restore collision, wait for the map, unfreeze, watch it settle
        client   report the pose back
        server   store the pose if it changed

    The window between creation and the client finishing is the dangerous one, and it is why
    the entity is created with collision off and frozen: for those few hundred milliseconds it
    is a ghost that cannot fall, cannot be hit, and cannot push anything.

    -------------------------------------------------------------------------------------------
    WHY `SetVehicleOnGroundProperly` IS NEVER CALLED
    -------------------------------------------------------------------------------------------

    It is what almost every script reaches for and it is the direct cause of the "my car came
    back in the street" bug. It probes downwards for ground and snaps to it. In an underground
    car park it finds the level below and drops the car through the floor; on a ramp it flattens
    the pitch; in a garage with a shallow lip it lands the car half-buried.

    We place with `SetEntityCoordsNoOffset`, which puts the entity exactly where it is told and
    nowhere else, and only consult the ground when the saved Z is provably wrong.
]]

Placement = {}

-- Shape test flags. The game's own bit values; grouped here so the config can speak in
-- English and this file can speak in bits.
local FLAG_MAP      = 1
local FLAG_VEHICLES = 2
local FLAG_PEDS     = 4 | 8
local FLAG_OBJECTS  = 16

local function options()
    return (Config and Config.Placement) or {}
end

local function probeOptions()
    return options().probe or {}
end

local function blockFlags()
    local blockedBy = probeOptions().blockedBy or {}
    local flags = 0

    if blockedBy.world ~= false then flags = flags | FLAG_MAP end
    if blockedBy.objects ~= false then flags = flags | FLAG_OBJECTS end
    if blockedBy.peds == true then flags = flags | FLAG_PEDS end

    -- Vehicles are deliberately NOT in the shape test. They are checked against the entity
    -- pool instead, a few functions down, because the pool gives us the blocking vehicle's
    -- handle - and knowing WHICH vehicle is in the way is the difference between deleting an
    -- ambient car and refusing to touch a player's.
    return flags
end

-- ---------------------------------------------------------------------------------------
-- Geometry
-- ---------------------------------------------------------------------------------------

local dimensionCache = {}

--[[
    A model's half-extents and centre offset, in model space.

    Cached per model. `GetModelDimensions` answers for a model the game knows without it being
    loaded, which matters because the probe runs before the vehicle exists on this client.
]]
local function dimensions(model)
    local cached = dimensionCache[model]
    if cached then return cached end

    local min, max = GetModelDimensions(model)
    if not min or not max then return nil end

    local entry = {
        half = vector3((max.x - min.x) * 0.5, (max.y - min.y) * 0.5, (max.z - min.z) * 0.5),
        centre = vector3((max.x + min.x) * 0.5, (max.y + min.y) * 0.5, (max.z + min.z) * 0.5),
    }

    if entry.half.x <= 0.01 or entry.half.y <= 0.01 then return nil end

    dimensionCache[model] = entry
    return entry
end

Placement.dimensions = dimensions

--[[
    Rotate a model-space offset by a heading, into world space.

    Only the heading, not the full rotation. Pitch and roll change where the corners of the box
    are by centimetres on a car parked on a camber, and accounting for them would mean a full
    matrix for a difference smaller than `Config.Placement.probe.shrink` already allows for.
]]
local function rotateFlat(offset, heading)
    local radians = math.rad(heading)
    local cos, sin = math.cos(radians), math.sin(radians)
    return vector3(
        offset.x * cos - offset.y * sin,
        offset.x * sin + offset.y * cos,
        offset.z
    )
end

--[[
    The world-space centre of a model placed at `position` facing `heading`.

    A vehicle's origin is not its centre: it sits near the rear axle on most models. Testing a
    box around the origin tests a volume that is offset from the car by up to a metre, which is
    exactly enough to report a free bay as blocked and a blocked bay as free.
]]
local function boxCentre(model, position, heading)
    local dims = dimensions(model)
    if not dims then return nil end

    local offset = rotateFlat(dims.centre, heading)
    return vector3(position.x + offset.x, position.y + offset.y, position.z + offset.z), dims
end

-- ---------------------------------------------------------------------------------------
-- The probe
-- ---------------------------------------------------------------------------------------

--[[
    Every vehicle whose bounding box overlaps the target volume.

    The entity pool rather than a shape test, for three reasons: it is exact where a shape
    test is a sample, it costs nothing near a car park where a shape test costs the same
    everywhere, and it hands back the entity so the caller can decide what that vehicle is.

    `ignore` is the vehicle being placed, which is always inside its own volume.
]]
local function overlappingVehicles(centre, half, heading, ignore, margin)
    margin = margin or 0.0

    local reach = math.max(half.x, half.y) + margin + 6.0
    local reachSq = reach * reach

    local out = {}

    for _, vehicle in ipairs(GetGamePool('CVehicle')) do
        if vehicle ~= ignore and DoesEntityExist(vehicle) then
            local other = GetEntityCoords(vehicle)
            local dx, dy = other.x - centre.x, other.y - centre.y

            if dx * dx + dy * dy < reachSq then
                -- Into the target box's own frame, so the test is an axis-aligned comparison
                -- against the half-extents rather than two rotated boxes.
                local radians = math.rad(-heading)
                local cos, sin = math.cos(radians), math.sin(radians)
                local localX = dx * cos - dy * sin
                local localY = dx * sin + dy * cos
                local localZ = other.z - centre.z

                local otherDims = dimensions(GetEntityModel(vehicle))
                local otherHalf = otherDims and otherDims.half or vector3(2.0, 2.0, 1.0)

                if math.abs(localX) < half.x + otherHalf.x + margin
                    and math.abs(localY) < half.y + otherHalf.y + margin
                    and math.abs(localZ) < half.z + otherHalf.z + margin then
                    out[#out + 1] = vehicle
                end
            end
        end
    end

    return out
end

Placement.overlappingVehicles = overlappingVehicles

--[[
    Is this vehicle one we may delete to make room?

    The rule is deliberately narrow. Everything that is not provably disposable is protected,
    because deleting a car somebody cares about to make room for one nobody is looking at is
    the worst thing this resource could do.

    Disposable means ALL of:
        - nobody is in it, in any seat
        - it is not one of ours (no `vpark:id`)
        - it is not a mission entity
        - it has no network owner that is a real player near it, or it has no player at all
]]
local function isAmbient(vehicle)
    if not DoesEntityExist(vehicle) then return false end

    -- Anybody inside, in any seat, and it is somebody's business.
    for seat = -1, GetVehicleMaxNumberOfPassengers(vehicle) do
        local occupant = GetPedInVehicleSeat(vehicle, seat)
        if occupant and occupant ~= 0 and DoesEntityExist(occupant) then
            return false
        end
    end

    -- One of ours. Never deleted here: the collision between two persisted vehicles is
    -- resolved by claim age, on the server, not by whichever one spawned second.
    local ok, id = pcall(function() return Entity(vehicle).state['vpark:id'] end)
    if ok and id ~= nil then return false end

    if IsEntityAMissionEntity(vehicle) then return false end

    -- A vehicle a script owns and marked as not-to-be-deleted.
    if DecorExistOn(vehicle, 'Player_Vehicle') then return false end

    return true
end

Placement.isAmbient = isAmbient

--[[
    Is the volume free?

    Returns `free, reason, blocker`.

        free      boolean
        reason    'clear' | 'vehicle' | 'world'
        blocker   the entity, when the reason is 'vehicle'

    The world test is a box shape test, polled to completion. It is asynchronous by design in
    the engine, so a bounded poll is the correct way to read it; the bound exists because a
    shape test that never resolves - which happens when the area is not streamed - must not
    hang the placement thread forever.
]]
function Placement.probe(model, position, heading, ignore)
    if probeOptions().enabled == false then
        return true, 'clear'
    end

    local centre, dims = boxCentre(model, position, heading)
    if not centre then
        -- No dimensions means an unknown model. Refusing to place it would be worse than
        -- placing it blind: the vehicle exists and has to go somewhere.
        return true, 'clear'
    end

    local shrink = tonumber(probeOptions().shrink) or 0.88
    local headroom = tonumber(probeOptions().headroom) or 0.15

    --[[
        THE SHRINK, and why it is not 1.0.

        A model's bounding box is bigger than its body: it contains the wing mirrors, the
        aerial, the tow hook and a margin the exporter added. Testing the raw box in a garage
        bay whose walls are exactly car-width reports blocked every single time, and the
        vehicle gets pushed out of a space it fits in perfectly well.

        0.88 was chosen against the tightest legitimate spaces in the base map. It is a
        config value because an operator with a custom MLO may need to move it.
    ]]
    local half = vector3(
        dims.half.x * shrink,
        dims.half.y * shrink,
        dims.half.z * shrink + headroom * 0.5
    )

    -- Vehicles first: cheaper, exact, and it produces the actionable answer.
    if (probeOptions().blockedBy or {}).vehicles ~= false then
        local blockers = overlappingVehicles(centre, half, heading, ignore, 0.0)
        if #blockers > 0 then
            return false, 'vehicle', blockers[1]
        end
    end

    local flags = blockFlags()
    if flags == 0 then
        return true, 'clear'
    end

    --[[
        The three size arguments are HALF-extents, measured from the centre.

        That is the community reading of an undocumented native, and it is the single
        assumption the world half of this probe rests on. If it were wrong - if they were full
        extents - the tested box would be twice the size of the car and almost every tight
        space would report as blocked.

        `/vparkprobe` is how it gets checked rather than guessed at: stand in a space the car
        demonstrably fits in and see whether it reads FREE. Obviously free spaces reading as
        BLOCKED, consistently and everywhere, is the tell.
    ]]
    local handle = StartShapeTestBox(
        centre.x, centre.y, centre.z + headroom * 0.5,
        half.x, half.y, half.z,
        0.0, 0.0, heading,
        2,          -- rotation order; 2 is the one that matches a heading in degrees
        flags,
        ignore or 0,
        4           -- the standard options value for a box test
    )

    -- Poll. A shape test resolves within a frame or two when the area is streamed, and never
    -- when it is not - which is why the bound exists and why running out of it means "free".
    -- An unstreamed area cannot be blocked by anything the player can see.
    local result, hit = 0, false
    for _ = 1, 20 do
        result, hit = GetShapeTestResult(handle)
        if result ~= 1 then break end
        Wait(0)
    end

    if result == 2 and hit then
        return false, 'world'
    end

    return true, 'clear'
end

-- ---------------------------------------------------------------------------------------
-- Clearing the way
-- ---------------------------------------------------------------------------------------

--[[
    Delete disposable vehicles occupying the target volume.

    THE FIX FOR THE MOST COMMON COMPLAINT about every persistence script: ambient traffic
    spawns while the server is empty, the game happily parks an NPC car exactly where a player
    left theirs, and the restored vehicle lands on top of it.

    Returns how many were removed.
]]
function Placement.clearAmbient(model, position, heading, ignore)
    local clear = options().clear or {}
    if clear.ambientVehicles == false then return 0 end

    local centre, dims = boxCentre(model, position, heading)
    if not centre then return 0 end

    local margin = tonumber(clear.radius) or 1.5
    local removed = 0

    for _, vehicle in ipairs(overlappingVehicles(centre, dims.half, heading, ignore, margin)) do
        if isAmbient(vehicle) then
            -- Control is required before a delete will take on a networked entity, and it is
            -- not always granted immediately. Asking once and deleting anyway is correct: the
            -- delete is a no-op without control, and the next placement pass tries again.
            NetworkRequestControlOfEntity(vehicle)
            SetEntityAsMissionEntity(vehicle, true, true)
            DeleteVehicle(vehicle)

            if not DoesEntityExist(vehicle) then
                removed = removed + 1
            end
        end
    end

    if removed > 0 then
        Park.debug('cleared %d ambient vehicle(s) from a parking space', removed)
    end

    return removed
end

--[[
    Stop the game putting new ambient traffic where we have just placed something.

    Without it, the game notices four seconds later that a bay is empty - it does not count
    our vehicle, because it did not create it - and parks an NPC car in it, half inside ours.

    `SetRoadsInArea` with `false` suppresses vehicle generation. It is reverted after the
    configured window, and the revert is unconditional so an error in between cannot leave a
    permanent traffic hole in somebody's map.
]]
function Placement.suppressTraffic(position, radius)
    local clear = options().clear or {}
    local seconds = tonumber(clear.suppressTrafficSeconds) or 0
    if seconds <= 0 then return end

    radius = radius or 8.0

    CreateThread(function()
        SetRoadsInArea(
            position.x - radius, position.y - radius, position.z - radius,
            position.x + radius, position.y + radius, position.z + radius,
            false, false
        )

        Wait(seconds * 1000)

        SetRoadsBackToOriginal(
            position.x - radius, position.y - radius, position.z - radius,
            position.x + radius, position.y + radius, position.z + radius
        )
    end)
end

-- ---------------------------------------------------------------------------------------
-- The search
-- ---------------------------------------------------------------------------------------

--[[
    Find a free pose near the saved one.

    Order matters and it is not the obvious one:

        1. The saved pose itself.
        2. The saved X and Y at a different HEIGHT, up and down.
        3. Rings outwards, at the saved height.

    Height before sideways, because the most common reason a saved pose is blocked in a
    multi-storey car park is that the Z drifted by a floor - the vehicle was saved mid-fall,
    or the map changed. The right answer there is one floor up, not two metres sideways into
    the next bay, and a search that goes sideways first finds a wrong answer that looks right.

    Returns `position, heading` or nil.
]]
function Placement.search(model, position, heading, ignore)
    local search = options().search or {}
    if search.enabled == false then return nil end

    local step = tonumber(search.step) or 1.25
    local maximum = tonumber(search.maximumRadius) or 6.0
    local perRing = math.max(1, math.floor(tonumber(search.perRing) or 8))
    local keepHeading = search.keepHeading ~= false
    local vertical = tonumber(search.verticalRetry) or 0

    if vertical > 0 then
        for _, dz in ipairs({ vertical, -vertical, vertical * 2, -vertical * 2 }) do
            local candidate = vector3(position.x, position.y, position.z + dz)
            if Placement.probe(model, candidate, heading, ignore) then
                Park.debug('placed %.2f m vertically from the saved position', dz)
                return candidate, heading
            end
        end
    end

    local ring = step
    while ring <= maximum do
        for i = 0, perRing - 1 do
            local angle = (i / perRing) * math.pi * 2.0
            local candidate = vector3(
                position.x + math.cos(angle) * ring,
                position.y + math.sin(angle) * ring,
                position.z
            )

            -- Keeping the heading is what makes the result look parked rather than crashed.
            -- A car at forty degrees to the kerb reads as abandoned mid-accident, however
            -- geometrically valid the spot is.
            local candidateHeading = heading
            if not keepHeading then
                candidateHeading = math.deg(angle) + 90.0
            end

            if Placement.probe(model, candidate, candidateHeading, ignore) then
                Park.debug('placed %.2f m from the saved position', ring)
                return candidate, candidateHeading
            end
        end

        ring = ring + step
    end

    return nil
end

-- ---------------------------------------------------------------------------------------
-- The ground check
-- ---------------------------------------------------------------------------------------

--[[
    Correct a saved Z only when it is PROVABLY wrong.

    Provably wrong means more than `groundTolerance` BELOW the ground. A vehicle above the
    ground is on a ramp, a rooftop, a car park level or a bridge, and all four are correct
    positions that a naive ground snap destroys. A vehicle below it was saved while falling
    through the map and has no correct Z to restore.

    Aircraft and boats are exempt: a helicopter on a rooftop helipad is sixty metres above
    "the ground" and entirely where it should be.
]]
function Placement.groundCorrect(model, position, class)
    if options().groundCheck == false then return position end
    if Classes.airborne[class] or Classes.aquatic[class] then return position end

    local tolerance = tonumber(options().groundTolerance) or 1.5

    local found, groundZ = GetGroundZFor_3dCoord(position.x, position.y, position.z + 2.0, false)
    if not found then
        -- No ground under the saved position at all. The map may not be streamed here yet, in
        -- which case the saved Z is the best information available and touching it would be
        -- guessing.
        return position
    end

    if position.z < groundZ - tolerance then
        Park.debug('saved Z was %.2f m below the ground, correcting', groundZ - position.z)
        return vector3(position.x, position.y, groundZ + 0.5)
    end

    return position
end

-- ---------------------------------------------------------------------------------------
-- Placing
-- ---------------------------------------------------------------------------------------

--[[
    Take network control of an entity, waiting briefly for it.

    Every write below needs it. Requesting once and proceeding is not enough: the request is
    asynchronous and the grant arrives a frame or several later, and a `SetEntityCoords` sent
    before it is silently discarded, which is how a vehicle ends up at the coordinates the
    server created it at rather than the ones we computed.
]]
local function takeControl(entity, timeoutMs)
    if NetworkGetEntityOwner(entity) == PlayerId() then return true end

    local deadline = Park.ticks() + (timeoutMs or 2000)

    while Park.ticks() < deadline do
        NetworkRequestControlOfEntity(entity)
        if NetworkHasControlOfEntity(entity) then return true end
        Wait(0)
    end

    return NetworkHasControlOfEntity(entity)
end

Placement.takeControl = takeControl

--[[
    Wait for the map to exist around an entity.

    ANSWER TO PROBLEM 1 in the config header. An entity created before its collision streams
    in is standing on nothing: it falls, and by the time the ground arrives it is underneath
    it, and the engine resolves that by popping it out somewhere approximately correct.

    `RequestCollisionAtCoord` asks for the collision; `HasCollisionLoadedAroundEntity` says
    when it is there. The timeout is a ceiling and not a delay - the loop ends the moment the
    answer is yes, which on a client already standing there is the first iteration.

    Returns whether collision actually loaded. False is not a failure: it means nobody is close
    enough to stream the map, in which case the vehicle stays frozen, which is correct.
]]
local function waitForCollision(entity, position)
    local timeout = tonumber(options().collisionTimeout) or 8000
    local deadline = Park.ticks() + timeout

    while Park.ticks() < deadline do
        if not DoesEntityExist(entity) then return false end

        RequestCollisionAtCoord(position.x, position.y, position.z)

        if HasCollisionLoadedAroundEntity(entity) then
            return true
        end

        Wait(50)
    end

    return false
end

--[[
    Watch a just-unfrozen vehicle for being ejected.

    The last line of defence, and the one that catches everything the probe did not predict. If
    the vehicle moves more than `ejectDistance` within `ejectWatchMs` of being handed physics,
    something is pushing it out - an intersection the box test sampled past, a piece of
    collision that streamed in late - and the right response is to put it back and leave it
    frozen rather than to let it slide into the road.
]]
local function watchForEjection(entity, target)
    local watchMs = tonumber(options().ejectWatchMs) or 1500
    if watchMs <= 0 then return end

    local distance = tonumber(options().ejectDistance) or 2.0
    local deadline = Park.ticks() + watchMs

    CreateThread(function()
        while Park.ticks() < deadline do
            if not DoesEntityExist(entity) then return end

            local now = GetEntityCoords(entity)
            if #(now - target) > distance then
                Park.debug('a restored vehicle was being ejected - putting it back and freezing it')
                takeControl(entity, 500)
                SetEntityCoordsNoOffset(entity, target.x, target.y, target.z, false, false, false)
                FreezeEntityPosition(entity, true)
                return
            end

            Wait(100)
        end
    end)
end

--[[
    The whole sequence, for one vehicle.

    `data` carries what the server knows:
        model, position { x, y, z }, rotation { x, y, z }, class,
        interior, room, frozen

    Returns a table describing what happened, which the caller reports back so the server can
    store a corrected pose and so `/vparkstats` can count the outcomes.
]]
function Placement.place(entity, data)
    if not DoesEntityExist(entity) then
        return { ok = false, reason = 'gone' }
    end

    local model = data.model or GetEntityModel(entity)
    local saved = vector3(data.position.x, data.position.y, data.position.z)
    local rotation = data.rotation or { x = 0.0, y = 0.0, z = 0.0 }
    local heading = rotation.z or 0.0

    if not takeControl(entity, 3000) then
        -- Somebody else owns it and is presumably doing this same work. Leaving it alone is
        -- correct; two clients placing one entity fight.
        return { ok = false, reason = 'no_control' }
    end

    -- The ghost window. Collision off and frozen means the entity cannot fall, cannot be hit
    -- and cannot push anything while we work out where it belongs.
    FreezeEntityPosition(entity, true)
    SetEntityCollision(entity, false, false)
    SetVehicleEngineOn(entity, false, true, true)

    -- ANSWER TO PROBLEM 4: an entity at interior coordinates without being told which room is
    -- outside the interior looking in. It renders through the wall, or falls to the world
    -- below. Done before the move, because the room is a property of where it is going.
    if options().restoreInterior ~= false and data.interior and data.interior ~= 0 then
        local interior = GetInteriorAtCoords(saved.x, saved.y, saved.z)
        if interior and interior ~= 0 then
            LoadInterior(interior)
            if data.room and data.room ~= 0 then
                ForceRoomForEntity(entity, interior, data.room)
            end
        end
    end

    local target = Placement.groundCorrect(model, saved, data.class or -1)

    -- ANSWER TO PROBLEM 2: something is already there.
    Placement.clearAmbient(model, target, heading, entity)

    local free, reason, blocker = Placement.probe(model, target, heading, entity)
    local outcome = 'exact'

    if not free then
        if reason == 'vehicle' and blocker and isAmbient(blocker) then
            -- A second clearing attempt: the first pass may have failed to get control in
            -- time, and a disposable vehicle is worth asking twice about.
            Placement.clearAmbient(model, target, heading, entity)
            free = Placement.probe(model, target, heading, entity)
        end

        if not free then
            local found, foundHeading = Placement.search(model, target, heading, entity)
            if found then
                target = found
                heading = foundHeading
                outcome = 'nudged'
            else
                local fallback = options().fallback or 'place'

                if fallback == 'defer' then
                    SetEntityCollision(entity, true, true)
                    return { ok = false, reason = 'blocked', retry = true }
                end

                if fallback == 'skip' then
                    SetEntityCollision(entity, true, true)
                    return { ok = false, reason = 'blocked', retry = false }
                end

                if fallback == 'ground' then
                    local hasGround, groundZ = GetGroundZFor_3dCoord(target.x, target.y, target.z + 3.0, false)
                    if hasGround then
                        target = vector3(target.x, target.y, groundZ + 0.5)
                    end
                    outcome = 'grounded'
                else
                    -- 'place': put it exactly where it was and leave it frozen. With
                    -- `freezeUntilTouched` on this is stable indefinitely - nothing pushes a
                    -- frozen entity - and the first player to drive it out resolves the
                    -- intersection naturally. For a tight space it is the RIGHT answer, which
                    -- is why it is the default.
                    outcome = 'forced'
                end
            end
        end
    end

    -- ANSWER TO PROBLEM 3: exact placement, no ground snap, full rotation.
    --
    -- `SetEntityRotation`, and NOT a `SetEntityHeading` after it. Heading sets the yaw and, on
    -- several builds, zeroes the pitch and roll with it - which is precisely what storing the
    -- full rotation was for. A car parked on a hill has a real pitch, and flattening it is the
    -- most visible way to get a restore subtly wrong.
    SetEntityCoordsNoOffset(entity, target.x, target.y, target.z, false, false, false)
    SetEntityRotation(entity, rotation.x or 0.0, rotation.y or 0.0, heading, 2, true)

    SetEntityCollision(entity, true, true)

    local collisionLoaded = waitForCollision(entity, target)

    -- Re-assert the pose after the map arrives. Streaming collision in around an entity can
    -- nudge it, and the nudge happens after the placement, so a pose set before is not
    -- necessarily the pose you have after.
    SetEntityCoordsNoOffset(entity, target.x, target.y, target.z, false, false, false)
    SetEntityRotation(entity, rotation.x or 0.0, rotation.y or 0.0, heading, 2, true)

    -- Note for anybody editing below this line: `SetVehicleOnGroundProperly` does NOT belong
    -- here, however much the vehicle looks like it wants it. See the file header.

    Placement.suppressTraffic(target, 8.0)

    local settleDelay = tonumber(options().settleDelay) or 250
    if settleDelay > 0 then Wait(settleDelay) end

    -- Whether physics is handed back at all is `freezeUntilTouched`. When it is on, the
    -- vehicle stays frozen until a player interacts with it, which costs no simulation and
    -- cannot drift out of a tight space over twenty minutes of being nudged by traffic.
    local keepFrozen = options().freezeUntilTouched ~= false or data.frozen == true

    if collisionLoaded and not keepFrozen then
        FreezeEntityPosition(entity, false)
        watchForEjection(entity, target)
    else
        FreezeEntityPosition(entity, true)
    end

    SetVehicleDoorsShut(entity, true)
    SetVehicleUndriveable(entity, false)

    return {
        ok = true,
        outcome = outcome,
        frozen = keepFrozen or not collisionLoaded,
        collision = collisionLoaded,
        position = { x = Park.coord(target.x), y = Park.coord(target.y), z = Park.coord(target.z) },
        heading = Park.angle(heading),
        moved = #(target - saved) > 0.05,
    }
end

--[[
    Wake a frozen vehicle: hand physics back.

    Called when a player gets close and looks at it, opens a door, or shoots it. Separate from
    `place` because it is the cheap common case and must not re-run any of the above.
]]
function Placement.wake(entity)
    if not DoesEntityExist(entity) then return false end
    if not IsEntityPositionFrozen(entity) then return false end

    if not takeControl(entity, 1000) then return false end

    local before = GetEntityCoords(entity)
    FreezeEntityPosition(entity, false)
    watchForEjection(entity, before)

    return true
end

function Placement.sleep(entity)
    if not DoesEntityExist(entity) then return false end
    if IsEntityPositionFrozen(entity) then return false end

    -- Only freeze something that is actually at rest. Freezing a rolling car stops it dead in
    -- mid-air, which is the single most obvious artefact this feature could produce.
    local restSpeed = tonumber(options().restSpeed) or 0.15
    if GetEntitySpeed(entity) > restSpeed then return false end

    for seat = -1, GetVehicleMaxNumberOfPassengers(entity) do
        local occupant = GetPedInVehicleSeat(entity, seat)
        if occupant and occupant ~= 0 then return false end
    end

    if not takeControl(entity, 500) then return false end

    FreezeEntityPosition(entity, true)
    return true
end
