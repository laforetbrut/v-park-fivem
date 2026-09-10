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
    A snapshot of every vehicle in the world, taken once and reused for a whole placement.

    -------------------------------------------------------------------------------------------
    WHY THIS EXISTS
    -------------------------------------------------------------------------------------------

    A blocked placement runs the probe once for the saved pose, again for up to four vertical
    retries, and again for every candidate the spiral search offers - which at the shipped
    settings is five rings of eight, so up to forty-five probes. Each one used to call
    `GetGamePool('CVehicle')`, allocate a table of every vehicle on the server, and read
    `GetEntityCoords` and `GetModelDimensions` for all of them.

    On a busy street with two hundred vehicles in the pool, that is nine thousand coordinate
    reads and forty-five table allocations to place one car.

    The snapshot reads the pool ONCE, at the start of the placement, and every probe below
    reads from it. Positions are read once too, which is correct as well as cheap: every probe
    in a single placement should be measuring against the same world, not against one that
    moved between candidates.
]]
local snapshot

local function takeSnapshot(ignore)
    local pool = GetGamePool('CVehicle')
    local entries = {}
    local count = 0

    for index = 1, #pool do
        local vehicle = pool[index]

        if vehicle ~= ignore and DoesEntityExist(vehicle) then
            local position = GetEntityCoords(vehicle)
            local dims = dimensions(GetEntityModel(vehicle))

            count = count + 1
            entries[count] = {
                entity = vehicle,
                x = position.x,
                y = position.y,
                z = position.z,
                half = dims and dims.half or vector3(2.0, 2.0, 1.0),
            }
        end
    end

    snapshot = { entries = entries, count = count, ignore = ignore }
    return snapshot
end

--[[
    Open and close a placement batch.

    Everything between them shares one view of the world. `endBatch` is called unconditionally
    in the caller's cleanup, because a snapshot left behind would be used by the NEXT placement
    and would describe a world that has moved on.
]]
--[[
    `neighbours` is the server's list of network ids of the vehicles IT is holding near the one
    being placed. Resolved to entities once, here, rather than per overlap test - a placement runs
    dozens of probes and the answer cannot change while it does.

    See `neighboursOf` in server/spawn.lua for why the server sends this at all.
]]
function Placement.beginBatch(ignore, neighbours)
    local shot = takeSnapshot(ignore)

    if type(neighbours) == 'table' and shot then
        local ours = {}

        --[[
            THROUGH THE STATE BAG FIRST. `NetworkGetEntityFromNetworkId` asks the object manager
            for an object this client may not have, and it says so in the console every time:

                Warning: [entity] GetNetworkObject: no object by ID 65533

            A placement resolves every neighbour the server named, and most of a car park's worth
            of neighbours are not streamed in on the client doing the placing - so the common case
            was a burst of warnings per restore. `GetEntityFromStateBagName` answers the same
            question quietly, and every vehicle in this list has a bag: the server set `vpark:id`
            on it. The native stays as the fallback for a build where the bag route is empty.
        ]]
        for _, netId in ipairs(neighbours) do
            local entity = GetEntityFromStateBagName(('entity:%d'):format(netId))

            if not entity or entity == 0 then
                local ok, resolved = pcall(NetworkGetEntityFromNetworkId, netId)
                entity = ok and resolved or nil
            end

            -- Not streamed in on this client, so it is not in the pool either and there is
            -- nothing to exclude.
            if entity and entity ~= 0 then ours[entity] = true end
        end

        shot.ours = ours
    end
end

function Placement.endBatch()
    snapshot = nil
end

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

    -- The batch snapshot when there is one, a fresh read when there is not. A caller outside
    -- a placement - the probe command, the API - still works and simply pays for its own scan.
    local source = snapshot
    if not source or source.ignore ~= ignore then
        source = takeSnapshot(ignore)
    end

    for index = 1, source.count do
        local entry = source.entries[index]
        do
            local dx, dy = entry.x - centre.x, entry.y - centre.y

            if dx * dx + dy * dy < reachSq then
                -- Into the target box's own frame, so the test is an axis-aligned comparison
                -- against the half-extents rather than two rotated boxes.
                local radians = math.rad(-heading)
                local cos, sin = math.cos(radians), math.sin(radians)
                local localX = dx * cos - dy * sin
                local localY = dx * sin + dy * cos
                local localZ = entry.z - centre.z

                local otherHalf = entry.half

                if math.abs(localX) < half.x + otherHalf.x + margin
                    and math.abs(localY) < half.y + otherHalf.y + margin
                    and math.abs(localZ) < half.z + otherHalf.z + margin then

                    --[[
                        OUR OWN VEHICLES ARE NOT OBSTACLES. SAME ARGUMENT AS THE MAP.

                        A persisted vehicle standing at its saved pose was standing there when
                        every other persisted vehicle nearby was saved. They coexisted. Two
                        cars parked in adjacent bays are not in each other's way and never
                        were - and the box tested here is bigger than the body, because it
                        contains the mirrors and a margin the exporter added, so two cars
                        parked thirty centimetres apart overlap in it.

                        The measured symptom, from `/vparkwhere` on three cars parked together:

                            0TL1XPC029AV2  PREMIER  off by 1.250 m  dx -1.250  dy 0  dz 0

                        1250 mm on one axis and nothing on the other two is not drift. It is
                        exactly `Config.Placement.search.step`: the probe called the bay
                        blocked because a neighbour's box overlapped, the search moved the car
                        one ring outwards, and `moved` sent that position back to be saved.

                        1.0.8 took the map out of this test for the same reason. This is the
                        other half: neither the world nor our own fleet can have changed since
                        the vehicle was parked. What is left is what genuinely can have
                        arrived - ambient traffic, and cars other players are driving.

                        Asked HERE rather than while building the snapshot, and that matters:
                        a statebag read per vehicle in the pool would be two hundred reads per
                        placement on a busy street. Only a handful of vehicles ever overlap,
                        and only those are asked.
                    ]]
                    -- The server's list first: it is authoritative and it is a table lookup.
                    -- The statebag second, because it also covers a vehicle restored after that
                    -- list was built.
                    local mine = source.ours and source.ours[entry.entity] == true

                    if not mine then
                        local ok, id = pcall(function()
                            return Entity(entry.entity).state['vpark:id']
                        end)
                        mine = ok and id ~= nil
                    end

                    if not mine then
                        out[#out + 1] = entry.entity
                    end
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
    The world-space endpoints of the rays that trace a model's footprint.

    -------------------------------------------------------------------------------------------
    WHY RAYS AND NOT A BOX SHAPE TEST
    -------------------------------------------------------------------------------------------

    v1.0.0 used `StartShapeTestBox`, whose three size arguments are undocumented. The community
    reading is that they are half-extents; if that reading were wrong the tested volume would be
    twice the size of the car and almost every tight space would report as blocked. The release
    had to carry that as a stated limit, which is not a good place for the resource's headline
    feature to be.

    Rays have no such ambiguity. A ray is two points, and nothing about it is open to
    interpretation. Six of them trace the footprint: the four sides at body height, and the two
    diagonals so that a pillar standing in the middle of an otherwise clear bay is caught.

    They are also cheaper than they look. The engine runs shape tests asynchronously, so all six
    - and all of the spiral search's candidates as well - are started together and read together,
    which is what `Placement.probeMany` below is for.

    What this trades away: an obstacle floating entirely inside the footprint without touching a
    side or a diagonal is missed. For a vehicle-sized volume that is a very small object in a
    very particular place, and the settle watch catches the consequence anyway.
]]
local function perimeterRays(model, position, heading, out)
    local centre, dims = boxCentre(model, position, heading)
    if not centre then return 0 end

    local shrink = tonumber(probeOptions().shrink) or 0.88
    local halfX = dims.half.x * shrink
    local halfY = dims.half.y * shrink

    -- Body height rather than the middle of the bounding box: the box includes the aerial and
    -- the roof, and a ray through the roofline hits the ceiling of every underground car park.
    local z = centre.z - dims.half.z * 0.35

    local radians = math.rad(heading)
    local cos, sin = math.cos(radians), math.sin(radians)

    local function corner(lx, ly)
        return vector3(
            centre.x + lx * cos - ly * sin,
            centre.y + lx * sin + ly * cos,
            z
        )
    end

    local frontLeft  = corner(-halfX,  halfY)
    local frontRight = corner( halfX,  halfY)
    local backLeft   = corner(-halfX, -halfY)
    local backRight  = corner( halfX, -halfY)

    local count = 0
    local function ray(from, to)
        count = count + 1
        out[count] = { from = from, to = to }
    end

    ray(frontLeft, frontRight)   -- across the nose
    ray(backLeft, backRight)     -- across the tail
    ray(frontLeft, backLeft)     -- down the left flank
    ray(frontRight, backRight)   -- down the right flank
    ray(frontLeft, backRight)    -- the two diagonals, for anything standing in the middle
    ray(frontRight, backLeft)

    return count
end

--[[
    Is the volume free?

    Returns `free, reason, blocker`.

        free      boolean
        reason    'clear' | 'vehicle' | 'world'
        blocker   the entity, when the reason is 'vehicle'
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

    -- The world. Six rays, started together and read together after one yield.
    local rays = {}
    local count = perimeterRays(model, position, heading, rays)
    if count == 0 then return true, 'clear' end

    local handles = {}
    for index = 1, count do
        local ray = rays[index]
        handles[index] = StartShapeTestRay(
            ray.from.x, ray.from.y, ray.from.z,
            ray.to.x, ray.to.y, ray.to.z,
            flags, ignore or 0, 0
        )
    end

    -- One yield for all six rather than a poll per ray. A shape test resolves within a frame
    -- or two when the area is streamed and never when it is not, so a bounded read is right;
    -- reading them as a group is what makes it one frame instead of six.
    Wait(0)

    for index = 1, count do
        local result, hit = GetShapeTestResult(handles[index])

        if result == 1 then
            -- Not resolved yet. One more frame, once, for the whole group.
            Wait(0)
            result, hit = GetShapeTestResult(handles[index])
        end

        if result == 2 and hit then
            return false, 'world'
        end
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

    -- ------------------------------------------------------------ the candidates ---
    --
    -- Built as one ordered list rather than tested as they are generated. Order IS the
    -- preference: vertical retries first, then rings outwards, and the first free candidate
    -- in this list is the one that gets used.
    local candidates = {}
    local count = 0

    local function add(x, y, z, candidateHeading, note)
        count = count + 1
        candidates[count] = {
            position = vector3(x, y, z),
            heading = candidateHeading,
            note = note,
        }
    end

    if vertical > 0 then
        for _, dz in ipairs({ vertical, -vertical, vertical * 2, -vertical * 2 }) do
            add(position.x, position.y, position.z + dz, heading, ('%.2f m vertically'):format(dz))
        end
    end

    local ring = step
    while ring <= maximum do
        for i = 0, perRing - 1 do
            local angle = (i / perRing) * math.pi * 2.0

            -- Keeping the heading is what makes the result look parked rather than crashed.
            -- A car at forty degrees to the kerb reads as abandoned mid-accident, however
            -- geometrically valid the spot is.
            local candidateHeading = keepHeading and heading or (math.deg(angle) + 90.0)

            add(position.x + math.cos(angle) * ring,
                position.y + math.sin(angle) * ring,
                position.z,
                candidateHeading,
                ('%.2f m away'):format(ring))
        end

        ring = ring + step
    end

    if count == 0 then return nil end

    -- ------------------------------------------------------------ the cheap pass ---
    --
    -- Vehicles first, for every candidate, with no yield at all: it reads the batch snapshot
    -- and is pure arithmetic. On a busy street this alone rejects most of the list, and every
    -- candidate it rejects is a group of six rays never started.
    local dims = dimensions(model)
    local shrink = tonumber(probeOptions().shrink) or 0.88
    local headroom = tonumber(probeOptions().headroom) or 0.15
    local checkVehicles = (probeOptions().blockedBy or {}).vehicles ~= false

    local surviving = {}
    local survivors = 0

    for index = 1, count do
        local candidate = candidates[index]
        local blocked = false

        if checkVehicles and dims then
            local centre = boxCentre(model, candidate.position, candidate.heading)
            if centre then
                local half = vector3(
                    dims.half.x * shrink,
                    dims.half.y * shrink,
                    dims.half.z * shrink + headroom * 0.5
                )
                blocked = #overlappingVehicles(centre, half, candidate.heading, ignore, 0.0) > 0
            end
        end

        if not blocked then
            survivors = survivors + 1
            surviving[survivors] = candidate
        end
    end

    if survivors == 0 then return nil end

    local flags = blockFlags()
    if flags == 0 then
        -- Nothing to ask the world. The first survivor wins.
        Park.debug('placed %s from the saved position', surviving[1].note)
        return surviving[1].position, surviving[1].heading
    end

    -- ----------------------------------------------------------- the world pass ---
    --
    -- THE REASON THIS FUNCTION WAS REWRITTEN FOR 1.0.1.
    --
    -- Every surviving candidate's six rays are STARTED before any of them is read. The engine
    -- runs shape tests asynchronously, so forty-five candidates cost one yield rather than
    -- forty-five - which is the difference between a placement that resolves in two frames and
    -- one that visibly takes most of a second on a busy street.
    --
    -- Capped, because starting several hundred shape tests in one frame is its own problem.
    -- The cap is generous next to the shipped ring settings and exists so an operator who sets
    -- a very large `maximumRadius` gets a slower search rather than a stalled frame.
    local budget = math.min(survivors, 64)

    local started = {}
    for index = 1, budget do
        local candidate = surviving[index]
        local rays = {}
        local rayCount = perimeterRays(model, candidate.position, candidate.heading, rays)

        local handles = {}
        for r = 1, rayCount do
            local ray = rays[r]
            handles[r] = StartShapeTestRay(
                ray.from.x, ray.from.y, ray.from.z,
                ray.to.x, ray.to.y, ray.to.z,
                flags, ignore or 0, 0
            )
        end

        started[index] = { candidate = candidate, handles = handles, count = rayCount }
    end

    Wait(0)

    for index = 1, budget do
        local entry = started[index]
        local blocked = false

        for r = 1, entry.count do
            local result, hit = GetShapeTestResult(entry.handles[r])

            if result == 1 then
                -- Not resolved. One extra frame for the whole set, once, then read again.
                Wait(0)
                result, hit = GetShapeTestResult(entry.handles[r])
            end

            if result == 2 and hit then
                blocked = true
                break
            end
        end

        if not blocked then
            Park.debug('placed %s from the saved position', entry.candidate.note)
            return entry.candidate.position, entry.candidate.heading
        end
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

    --[[
        WHERE THIS MODEL'S ORIGIN SITS WHEN ITS WHEELS ARE ON THE GROUND.

        `GetEntityCoords` answers the entity's ORIGIN, not the point it touches the road, and
        the two are a different distance apart for every model - about 0.6 m for a saloon, over
        a metre for a truck. `-min.z` is that distance, and `min.z` is `centre.z - half.z`.

        Getting this from the model rather than assuming a constant is what lets the check
        below be tight enough to be useful without dragging a legitimately raised vehicle down.
    ]]
    local dims = dimensions(model)
    local rest = groundZ + (dims and (dims.half.z - dims.centre.z) or 0.5)

    if position.z < groundZ - tolerance then
        Park.debug('saved Z was %.2f m below the ground, correcting', groundZ - position.z)
        return vector3(position.x, position.y, rest)
    end

    --[[
        AND THE OTHER DIRECTION, WHICH IS THE ONE THAT WAS MISSING.

        This only ever pushed a buried vehicle up. A vehicle ABOVE the ground was left alone,
        on the reasoning that it might be on a ramp or a roof - and `GetGroundZFor_3dCoord`
        already answers with the ramp or the roof, so that reasoning was wrong.

        What it actually did was make a floating vehicle permanent. The search would offer a
        candidate three and a half metres up, the probe would call it clear because nothing is
        ever up there, the vehicle would be placed and frozen, and the airborne position saved.
        Nothing in the entire path would then ever bring it down again.

        The tolerance is deliberately generous. A car on a steep camber or a kerb is within a
        few tens of centimetres of its resting height; anything more than a metre and a half
        above where this model rests on the surface beneath it is not parked, it is hovering.
    ]]
    if position.z > rest + tolerance then
        Park.debug('%.2f m above where this model rests on the ground, correcting down',
            position.z - rest)
        return vector3(position.x, position.y, rest)
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
    ================================================================================================
    PUT AN ENTITY EXACTLY WHERE IT IS TOLD, INCLUDING WHEN IT IS FROZEN.
    ================================================================================================

    THIS IS WHY NO VEHICLE EVER CAME BACK IN QUITE THE RIGHT PLACE.

    `FREEZE_ENTITY_POSITION` fixes an entity's matrix, and a position written to a frozen entity
    is not reliably applied - the freeze is holding the matrix that the write is trying to
    change. Every coordinate write in this file was made against an entity that this same file
    had frozen a few lines earlier.

    For most of this resource's life that was survivable, because the vehicle was not frozen
    when it arrived: it fell, the placement unfroze nothing because nothing was frozen, the
    write landed, and the result was roughly right. 1.0.7 fixed the falling by freezing the
    vehicle on arrival through a replicated statebag - which was correct, and which turned
    "roughly right" into "wherever the server first created it", on every vehicle. That is what
    "none of them come back in the right place" was.

    So every pose write goes through here: unfreeze, write, kill any velocity, freeze again.
    There is no `Wait` between the three, so no physics tick happens in the window and the
    entity cannot fall through it.

    `wasFrozen` is passed rather than read back, because `IsEntityPositionFrozen` is not
    available on every build and the caller always knows.
]]
local function setPose(entity, position, rotation, heading, wasFrozen)
    if wasFrozen then FreezeEntityPosition(entity, false) end

    SetEntityCoordsNoOffset(entity, position.x, position.y, position.z, false, false, false)

    if rotation then
        SetEntityRotation(entity, rotation.x or 0.0, rotation.y or 0.0, heading or 0.0, 2, true)
    end

    -- A frozen entity keeps whatever velocity it had when it was frozen, and hands it straight
    -- back the moment it is released. Zeroing it is what stops a restored vehicle twitching
    -- forward the first time somebody opens its door.
    SetEntityVelocity(entity, 0.0, 0.0, 0.0)
    SetEntityAngularVelocity(entity, 0.0, 0.0, 0.0)

    if wasFrozen then FreezeEntityPosition(entity, true) end
end

Placement.setPose = setPose

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
                -- `false`: this watch only runs for a vehicle that was handed back to physics,
                -- so it is not frozen. It is from here on.
                setPose(entity, target, nil, nil, false)
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

    -- One view of the world for the whole placement. See `Placement.beginBatch`: without it
    -- every probe and every search candidate re-scanned the entire vehicle pool.
    Placement.beginBatch(entity, data and data.neighbours)

    local ok, result = pcall(Placement.placeInner, entity, data)

    -- Unconditionally, including after a raise. A snapshot left behind would be used by the
    -- next placement and would describe a world that has moved on.
    Placement.endBatch()

    if not ok then
        Park.error('placement raised: %s', tostring(result))
        return { ok = false, reason = 'raised' }
    end

    return result
end

function Placement.placeInner(entity, data)
    local model = data.model or GetEntityModel(entity)
    local saved = vector3(data.position.x, data.position.y, data.position.z)
    local rotation = data.rotation or { x = 0.0, y = 0.0, z = 0.0 }
    local heading = rotation.z or 0.0

    --[[
        NOT BEING ABLE TO REFINE THE PLACEMENT IS NOT A FAILED PLACEMENT.

        The server created this vehicle at its saved coordinates and heading - those were
        arguments to the creation native - so a vehicle we never touch is already exactly where
        it was left. Everything below only REFINES that: it corrects a buried Z, clears ambient
        traffic out of the bay, and finds the nearest free spot when the exact one is occupied.

        Until 1.0.5 this returned a failure, and the server answered a failure by deleting the
        vehicle. Two clients contending for one entity, or a control request that took longer
        than three seconds on a busy server, therefore produced delete-and-recreate on a loop:
        the vehicle flickered, and the churn is most of what a server feels as lag from a
        persistence resource.

        So: report success, say the placement was not refined, and leave the vehicle where the
        server put it. That is the right answer and it is also the answer the player wants.
    ]]
    --[[
        Control is normally already held: the restore handler takes it before it applies a
        single property, because a property written without control is written into the void.
        This is the re-check, and it is cheap when we have it.

        Losing it between there and here means another client took the entity, which is a
        thing that can happen while a player walks up to a car. Not being able to refine the
        placement is NOT a failed restore - the server created this vehicle at its saved
        coordinates, so it is already where it belongs - so this reports success and says the
        refinement did not happen.
    ]]
    if not takeControl(entity, 2000) then
        return {
            ok = true,
            outcome = 'unrefined',
            frozen = true,
            collision = true,
            position = { x = Park.coord(saved.x), y = Park.coord(saved.y), z = Park.coord(saved.z) },
            heading = Park.angle(heading),
            moved = false,
        }
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

    --[[
        THE LAST WORD ON HEIGHT, AFTER THE SEARCH HAS HAD ITS SAY.

        `groundCorrect` ran on the saved pose at the top of this function. If the search then
        moved the vehicle, that answer was about a different place - and the search is the
        thing that used to put vehicles in the sky. Running it once more over whatever was
        finally chosen is what makes "no vehicle is ever left floating" a property of the code
        rather than of the configuration.

        Idempotent, so on the overwhelmingly common path where nothing moved it is one ground
        probe that changes nothing.
    ]]
    if outcome ~= 'exact' then
        target = Placement.groundCorrect(model, target, data.class or -1)
    end

    -- ANSWER TO PROBLEM 3: exact placement, no ground snap, full rotation.
    --
    -- `SetEntityRotation`, and NOT a `SetEntityHeading` after it. Heading sets the yaw and, on
    -- several builds, zeroes the pitch and roll with it - which is precisely what storing the
    -- full rotation was for. A car parked on a hill has a real pitch, and flattening it is the
    -- most visible way to get a restore subtly wrong.
    -- Through `setPose`, which unfreezes for the write. The entity was frozen at the top of
    -- this function and, since 1.0.7, was very likely frozen before that by the hold statebag.
    setPose(entity, target, rotation, heading, true)

    SetEntityCollision(entity, true, true)

    local collisionLoaded = waitForCollision(entity, target)

    -- Re-assert the pose after the map arrives. Streaming collision in around an entity can
    -- nudge it, and the nudge happens after the placement, so a pose set before is not
    -- necessarily the pose you have after.
    setPose(entity, target, rotation, heading, true)

    -- Note for anybody editing below this line: `SetVehicleOnGroundProperly` does NOT belong
    -- here, however much the vehicle looks like it wants it. See the file header.

    Placement.suppressTraffic(target, 8.0)

    local settleDelay = tonumber(options().settleDelay) or 250
    if settleDelay > 0 then Wait(settleDelay) end


    -- Whether physics is handed back at all is `freezeUntilTouched`. When it is on, the
    -- vehicle stays frozen until a player interacts with it, which costs no simulation and
    -- cannot drift out of a tight space over twenty minutes of being nudged by traffic.
    local keepFrozen = options().freezeUntilTouched ~= false or data.frozen == true

    --[[
        EXCEPT IN MID-AIR, WHERE FREEZING IT IS THE BUG.

        A vehicle stored while it was not on the ground - a helicopter somebody left hovering
        being the usual one - comes back at those coordinates and, frozen, hangs there for good.
        `Placement.groundCorrect` will not pull it down because aircraft are exempt from that
        check, and rightly so: a helicopter on a rooftop helipad is sixty metres above "the
        ground" and exactly where it belongs.

        So the check is on the freeze rather than the position. Handed its physics back, the
        vehicle falls and lands or crashes, which is what would happen with no persistence
        resource running at all.

        A failed ground probe leaves the freeze alone. The map may simply not be streamed here
        yet, and guessing in that state is how vehicles end up under it.
    ]]
    local tolerance = tonumber(options().airborneTolerance) or 5.0
    local airborne = nil

    if keepFrozen and tolerance > 0 and not Classes.aquatic[data.class] then
        airborne = Placement.airborne(entity, tolerance)

        if airborne == true then
            Park.debug('%s is more than %.1f m above the ground - not freezing it there',
                tostring(data.id), tolerance)
            keepFrozen = false
        end
    end

    if collisionLoaded and not keepFrozen then
        FreezeEntityPosition(entity, false)
        watchForEjection(entity, target)
    else
        FreezeEntityPosition(entity, true)
    end

    --[[
        THE ANCHOR GOES DOWN HERE, AFTER THE POSE IS FINAL.

        `Properties.apply` runs before this function and only records what the anchor SHOULD be -
        see the note there. This is the first moment the vehicle is where it belongs, which is the
        only place it makes sense to moor it to.
    ]]
    if Anchor and Anchor.settle then Anchor.settle(entity) end

    SetVehicleDoorsShut(entity, true)

    -- NOT on a stored wreck. A vehicle whose engine was destroyed is restored destroyed - see
    -- `applyWreck` in `client/properties.lua` - and this line was quietly handing it back as a
    -- working car one step later, which is half of "il respawn tout neuf".
    if GetVehicleEngineHealth(entity) > 0 then
        SetVehicleUndriveable(entity, false)
    end

    --[[
        ============================================================================
        HOLD IT TO THE EXACT POSE, AND MEAN IT.
        ============================================================================

        Everything above places the vehicle and then trusts it to stay placed. It mostly does,
        and "mostly" is what "they are not quite in the right place" is made of.

        A vehicle can move by a few centimetres between the coordinates being set and the
        freeze taking hold: collision streams in underneath it and the engine resolves the
        intersection, a vehicle materialises alongside and pushes it, the suspension settles.
        None of that is far enough to look broken and all of it is far enough to look wrong -
        and once the vehicle is frozen there, that is where it stays, and the next capture
        writes it down.

        1.0.7 checked once, before the freeze, and only acted past half a metre. Both were
        wrong: half a metre is enormous for something that is supposed to be exact, and before
        the freeze is before most of the movement.

        So: after the freeze, twice, two centimetres. Re-asserting a pose on a frozen entity
        costs three natives and nothing else, and the vehicle is then where the database says
        it is - not approximately, exactly.

        Only for a vehicle that stays frozen. One that was handed back to physics is meant to
        settle, and holding it would be fighting the thing we just asked for.
    ]]
    if keepFrozen or not collisionLoaded then
        for _ = 1, 2 do
            Wait(150)

            local at = GetEntityCoords(entity)
            if not at then break end

            if #(at - target) > 0.02 then
                Park.debug('%s moved %.3f m after placement - re-asserting the pose',
                    tostring(data.id), #(at - target))

                setPose(entity, target, rotation, heading, true)
            end
        end
    end

    return {
        ok = true,
        outcome = outcome,
        --[[
            `nil` means the ground probe could not answer, which is the common case when the
            vehicle is placed at the far edge of the streaming radius: the map under it is not
            loaded on this client yet, so there is nothing to measure against.

            That was the whole of the helicopter report. The probe failed at 250 m, the vehicle
            stayed frozen, and nothing ever asked again - so it hung in the sky "jusqu'a temps
            qu'on s'en approche de tres pres", which is where the wake radius finally reached it.
            The tick asks again for as long as the answer is unknown. See `groundUnknown`.
        ]]
        groundUnknown = (airborne == nil),
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
--[[
    Is this vehicle more than `tolerance` metres above whatever is beneath it?

    `true`, `false`, or `nil` when the probe could not answer at all - which is not a detail. A
    failed probe usually means the map under the vehicle is not streamed in on this client yet,
    and treating that as "it is on the ground" is how a helicopter ends up frozen in the sky at
    the edge of the streaming radius with nothing left to ask the question again.
]]
function Placement.airborne(entity, tolerance)
    if not DoesEntityExist(entity) then return nil end

    tolerance = tonumber(tolerance) or tonumber(options().airborneTolerance) or 5.0
    if tolerance <= 0 then return false end

    local at = GetEntityCoords(entity)
    local found, groundZ = GetGroundZFor_3dCoord(at.x, at.y, at.z, false)

    if not found then return nil end

    return (at.z - groundZ) > tolerance
end

function Placement.wake(entity)
    if not DoesEntityExist(entity) then return false end

    -- An anchor is a deliberate instruction to stay put, so nothing here overrides it. Raising
    -- it is a person's decision and `Anchor.raise` is the only thing that makes it.
    if Anchor and Anchor.isAnchored and Anchor.isAnchored(entity) then return false end

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
