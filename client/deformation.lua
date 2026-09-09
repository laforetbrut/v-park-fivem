--[[
    client/deformation.lua

    Bodywork deformation: reading it off a vehicle, putting it back, and making every player
    see the same dents.

    -------------------------------------------------------------------------------------------
    WHY THIS FILE EXISTS AT ALL
    -------------------------------------------------------------------------------------------

    `bodyHealth` is a single number. Two cars at 600 body health can look completely different:
    one folded at the front, one caved in along the driver's door. Restoring the number and not
    the shape gives you a car that comes back from a restart with its damage in the wrong
    place, or - worse - with no visible damage and an engine that behaves as though it has some.

    Deformation is also the single most common desync in FiveM. The engine syncs a vehicle's
    damage state to whoever owns the entity and reconstructs it approximately elsewhere, so two
    players standing beside the same wreck routinely see two different wrecks.

    Both problems have the same answer: sample the deformation into data, store it, and have
    EVERY client apply that same data locally. Then the dents are identical everywhere by
    construction rather than by hoping the engine agrees with itself.

    -------------------------------------------------------------------------------------------
    HOW IT WORKS
    -------------------------------------------------------------------------------------------

    `GetVehicleDeformationAtPos(vehicle, x, y, z)` answers how far the bodywork at a local
    offset has moved. It is the only read access the game gives us.

    `SetVehicleDamage(vehicle, x, y, z, damage, radius, focus)` pushes the bodywork in at an
    offset. It is the only write access, and it is not the inverse of the read: there is no
    "set deformation to exactly this", only "hit it here this hard". So putting a saved shape
    back is a search - hit it, measure, hit it harder, until the measurement matches.

    Capture:
        1. Build a deterministic grid of offsets from the model's bounding box.
        2. Read the deformation at each, project it onto the inward axis so that a panel
           pushed IN counts and a reflection or a wobble does not.
        3. Keep the points over a threshold, as (grid index, magnitude) pairs.

    Restore:
        1. Rebuild the same grid from the same model. The index is enough to know where.
        2. For each stored point, apply damage until the measured deformation reaches the
           stored magnitude, or the iteration budget runs out.

    -------------------------------------------------------------------------------------------
    WHAT THIS DOES DIFFERENTLY FROM THE KNOWN IMPLEMENTATION
    -------------------------------------------------------------------------------------------

    The published technique for this - Kiminaze's VehicleDeformation, which is MIT and worth
    reading - establishes the approach above. Four things here are deliberately different:

    1. NO PROBE PASS, AND NO SPAWNED COPY. The reference implementation spawns a hidden copy
       of the vehicle fifty metres underground and fires roughly a hundred synchronous LOS
       probes at it to work out which grid points sit on bodywork. That is an entity creation
       and a hundred blocking shape tests the first time any player sees any model.

       It is not needed. A grid point that is not on bodywork reports no deformation, so it is
       never stored, so it is never applied. The filtering happens for free at capture time.
       The cost of dropping the probe pass is nothing; the saving is the whole hitch.

    2. THE SIDES ARE INCLUDED. The reference grid keeps only points with |y| > 0.55 - the
       front and rear thirds - so a car hit squarely in the driver's door stores no
       deformation at all. This grid covers the flanks, which is where a T-bone lands.

    3. STORED AS INDEX AND MAGNITUDE, NOT AS TWO VECTORS. The grid is derived from the model,
       so both sides can regenerate it; the offset does not need storing. That is two numbers
       per point instead of six floats, which matters because this data goes in a statebag
       that replicates to every client in scope.

    4. SEEDED CONVERGENCE. The reference starts every point at 50 damage and steps by 5, up to
       50 iterations, yielding a frame each time. The relationship between the damage argument
       and the resulting deformation is close enough to linear over the useful range to seed a
       first guess from the target, and then correct. It converges in single-figure iterations.

    -------------------------------------------------------------------------------------------
    THE ONE THING TO KNOW BEFORE TRUSTING IT
    -------------------------------------------------------------------------------------------

    Apply is APPROXIMATE. It reproduces a shape that reads as the same damage, not the same
    vertices. So a capture taken from a vehicle we ourselves restored is a copy of a copy, and
    doing that repeatedly drifts - each round trip exaggerates the dents slightly.

    `Deformation.shouldRecapture` is the guard: a restored vehicle is not re-captured until its
    body health has actually moved by a meaningful amount, meaning it took NEW damage. A car
    that is parked and never touched keeps its original capture forever, however many restarts
    it sits through.
]]

Deformation = {}

-- model hash -> the offset grid for that model. Built once per model per session.
local gridCache = {}

-- entity -> the version of the deformation we last applied to it. Stops a statebag update
-- being re-applied every time the handler fires for an unrelated key.
local appliedVersion = {}

-- Vehicles this client is currently deforming, so two overlapping applications on the same
-- entity cannot fight each other.
local applying = {}

--[[
    ================================================================================================
    THE EXPENSIVE READ, GUARDED BY A CHEAP ONE
    ================================================================================================

    Reading a deformation is `GRID_SIZE` calls to `GetVehicleDeformationAtPos` - 68 of them - and
    it ran on every capture of every vehicle in range, on every sweep, whether the vehicle had
    been touched or not.

    `Properties.capture` already works this way for the other expensive half of a snapshot: the
    seventy-odd calls that read mod slots, colours, extras and neons sit behind a twelve-call
    fingerprint and are re-read only when somebody has actually fitted something. Deformation had
    no such guard, so it was the whole cost of a capture on a fleet that is mostly parked.

    THE FINGERPRINT IS BODY HEALTH, AND IT IS ONE NATIVE CALL. Bodywork cannot deform without body
    health moving - it is the number the engine derives from exactly the damage this file samples -
    so a vehicle whose body health has not changed since the last read has the same dents it had
    then, and the cached answer is not an approximation of the truth, it IS the last truth.

    Keyed by entity handle, which the engine reuses, so the model is stored alongside and a
    mismatch throws the entry away. `Deformation.clear` drops it on every path that lets go of a
    vehicle - see the note on `tuningFingerprint` in client/properties.lua for what a stale cache
    against a reused handle did in 1.0.1.
]]
local lastRead = {}

--[[
    Body health, rounded, or nil when it cannot be read.

    Rounded because the engine returns a float that wobbles in the last decimal places on a
    vehicle nobody is touching, and a fingerprint that flaps is not a fingerprint.
]]
local function healthPrint(vehicle)
    local ok, health = pcall(GetVehicleBodyHealth, vehicle)
    if not ok or type(health) ~= 'number' then return nil end
    return math.floor(health * 10.0 + 0.5)
end

local function options()
    local config = (Config and Config.Deformation) or {}
    return config
end

local function enabled()
    return options().enabled ~= false
end

-- ---------------------------------------------------------------------------------------
-- The grid
-- ---------------------------------------------------------------------------------------

--[[
    The normalised sampling grid, in model-space fractions of the bounding box.

    Read it as a lattice over the outside of the car. Each entry is { x, y, z } in the range
    -1 to 1, where y is front-to-back, x is left-to-right and z is bottom-to-top.

    THE SHAPE OF THIS LIST IS PART OF THE STORAGE FORMAT. A stored deformation refers to its
    points by index, so reordering, inserting or removing an entry silently reinterprets every
    row already in the database. If it ever has to change, it changes with a new
    `Config.Deformation.gridVersion` and the loader treats the old version as unreadable
    rather than as wrong - a car with no dents is a much smaller problem than a car with
    somebody else's.
]]
local GRID_VERSION = 1

local GRID = {}

do
    -- Front and rear: the full width, two heights. Where most collisions land.
    for _, y in ipairs({ 1.0, 0.75, -0.75, -1.0 }) do
        for _, x in ipairs({ -1.0, -0.5, 0.0, 0.5, 1.0 }) do
            for _, z in ipairs({ -0.35, 0.15 }) do
                GRID[#GRID + 1] = { x = x, y = y, z = z }
            end
        end
    end

    -- The flanks: both sides, four points along the length, two heights. This is the band the
    -- reference grid leaves out, and it is where a side impact and a scrape against a wall
    -- both show up.
    for _, x in ipairs({ -1.0, 1.0 }) do
        for _, y in ipairs({ 0.45, 0.15, -0.15, -0.45 }) do
            for _, z in ipairs({ -0.3, 0.2 }) do
                GRID[#GRID + 1] = { x = x, y = y, z = z }
            end
        end
    end

    -- The roof and bonnet line: a rollover and a heavy front impact both deform downwards,
    -- and nothing above catches it.
    for _, y in ipairs({ 0.6, 0.2, -0.2, -0.6 }) do
        for _, x in ipairs({ -0.6, 0.0, 0.6 }) do
            GRID[#GRID + 1] = { x = x, y = y, z = 0.75 }
        end
    end
end

local GRID_SIZE = #GRID

Deformation.gridVersion = GRID_VERSION
Deformation.gridSize = GRID_SIZE

--[[
    The grid for a model, in real model-space metres.

    Derived from `GetModelDimensions`, which answers without the model being loaded for a
    model the game knows, and which is the same on every client for a given model - so two
    clients generate identical grids and a stored index means the same place to both.
]]
local function gridFor(model)
    local cached = gridCache[model]
    if cached then return cached end

    local min, max = GetModelDimensions(model)

    -- A model the game does not know answers with zeroes. Deforming it is meaningless and
    -- storing a grid of zeroes would put every point at the origin, where they would all
    -- report the same value.
    if not min or not max or (max.x - min.x) <= 0.01 then
        gridCache[model] = false
        return false
    end

    local centreX, centreY, centreZ = (max.x + min.x) * 0.5, (max.y + min.y) * 0.5, (max.z + min.z) * 0.5
    local halfX, halfY, halfZ = (max.x - min.x) * 0.5, (max.y - min.y) * 0.5, (max.z - min.z) * 0.5

    local points = {}
    for i = 1, GRID_SIZE do
        local n = GRID[i]
        points[i] = vector3(
            centreX + n.x * halfX,
            centreY + n.y * halfY,
            centreZ + n.z * halfZ
        )
    end

    gridCache[model] = points
    return points
end

Deformation.gridFor = gridFor

-- ---------------------------------------------------------------------------------------
-- Capture
-- ---------------------------------------------------------------------------------------

--[[
    Project `v` onto the axis pointing from the sample point towards the vehicle's centre.

    WHY PROJECT AT ALL. `GetVehicleDeformationAtPos` returns a displacement vector, and a
    panel can be displaced in directions that are not damage: a wing mirror hanging, a bonnet
    lifted, floating point noise. Only the component pushing INWARD is a dent, and the inward
    direction at a sample point is the direction from that point towards the middle of the car.

    Taking the raw length instead stores the noise, and the noise is what makes a parked car's
    deformation hash flap and re-save every sweep.
]]
local function inwardMagnitude(deformation, point)
    if not deformation then return 0.0 end

    local axis = -point
    local length = #axis
    if length < 0.001 then return 0.0 end

    local projected = dot(deformation, axis / length)

    -- Negative means the panel moved outward. Not damage as far as we are concerned.
    if projected <= 0 then return 0.0 end
    return projected
end

--[[
    Read the deformation off a vehicle.

    Returns nil when there is nothing worth storing, which is the overwhelmingly common case.

    IT USED TO COST THE WHOLE GRID TO FIND THAT OUT - sixty-eight calls to
    `GetVehicleDeformationAtPos`, on every vehicle in range, on every sweep, to establish that a
    car nobody has crashed has no dents. Two gates below answer that for one native call instead:
    body health at full means no deformed panel anywhere, and body health unchanged since the last
    read means the same dents as the last read. See the note over `lastRead`.

    The returned shape is a flat array of alternating index and quantised magnitude:

        { 12, 34, 51, 18, ... }   -- point 12 is dented 0.34m, point 51 is dented 0.18m

    Flat and integer, because it is what encodes smallest and what a statebag replicates
    fastest. `Deformation.pairs` reads it back.
]]
function Deformation.capture(vehicle)
    if not enabled() then return nil end
    if not DoesEntityExist(vehicle) then return nil end

    local model = GetEntityModel(vehicle)

    --[[
        GATE ONE: IS THERE ANY BODYWORK DAMAGE AT ALL?

        One native call. A vehicle at full body health has no deformed panel anywhere on it, so
        the sixty-eight reads below can only return zeroes, and returning nil now is the same
        answer for one sixty-eighth of the cost.

        This is the common case by a wide margin. Most vehicles a server holds have never been
        crashed, and every one of them was paying the full grid every sweep.
    ]]
    local health = healthPrint(vehicle)
    local pristine = tonumber(options().pristineHealth) or 999.0

    if health and health >= math.floor(pristine * 10.0 + 0.5) then
        lastRead[vehicle] = { model = model, health = health, flat = false }
        return nil
    end

    --[[
        GATE TWO: HAS ANYTHING CHANGED SINCE THE LAST READ?

        Bodywork cannot deform without body health moving, so an unchanged fingerprint means
        unchanged dents and the previous answer still stands. See the note over `lastRead`.

        The model guard is the handle-reuse guard: a cache entry keyed on a freed handle can be
        handed to a completely different vehicle.
    ]]
    local cached = lastRead[vehicle]
    if health and cached and cached.model == model and cached.health == health then
        if cached.flat == false then return nil end
        return cached.flat
    end

    local points = gridFor(model)
    if not points then return nil end

    local threshold = tonumber(options().threshold) or 0.05
    local scale = tonumber(options().quantiseScale) or 100.0

    local out = {}
    local count = 0

    for i = 1, GRID_SIZE do
        local point = points[i]
        local raw = GetVehicleDeformationAtPos(vehicle, point.x, point.y, point.z)
        local magnitude = inwardMagnitude(raw, point)

        if magnitude > threshold then
            count = count + 2
            out[count - 1] = i
            -- Quantised to centimetres. Below that is not visible and is not stable between
            -- two reads of the same undamaged panel.
            out[count] = math.floor(magnitude * scale + 0.5)
        end
    end

    if count == 0 then
        -- Only ever cached against a fingerprint that was readable. An entry stored with a nil
        -- health would match every later call, because `nil == nil`, and would freeze this
        -- answer for the life of the handle.
        if health then lastRead[vehicle] = { model = model, health = health, flat = false } end
        return nil
    end

    -- A cap, because a vehicle that has been rolled down a hill can light up most of the
    -- grid, and a statebag is not the place for an unbounded array. The deepest dents are
    -- the ones that read, so keep those.
    local maximum = tonumber(options().maximumPoints) or 48
    if count / 2 > maximum then
        out = Deformation.trim(out, maximum)
    end

    if health then lastRead[vehicle] = { model = model, health = health, flat = out } end

    return out
end

--[[
    Keep only the `maximum` deepest points.

    Sorting pairs out of a flat array means rebuilding it, which is why this is separate and
    only runs in the rare case that hits the cap.
]]
function Deformation.trim(flat, maximum)
    local list = {}
    for i = 1, #flat, 2 do
        list[#list + 1] = { index = flat[i], magnitude = flat[i + 1] }
    end

    table.sort(list, function(a, b)
        if a.magnitude == b.magnitude then return a.index < b.index end
        return a.magnitude > b.magnitude
    end)

    local out = {}
    for i = 1, math.min(maximum, #list) do
        out[#out + 1] = list[i].index
        out[#out + 1] = list[i].magnitude
    end

    -- Re-sorted by index so that two captures of the same damage encode identically and the
    -- delta hash does not see a change that is only an ordering difference.
    local pairsList = {}
    for i = 1, #out, 2 do
        pairsList[#pairsList + 1] = { out[i], out[i + 1] }
    end
    table.sort(pairsList, function(a, b) return a[1] < b[1] end)

    local sorted = {}
    for _, entry in ipairs(pairsList) do
        sorted[#sorted + 1] = entry[1]
        sorted[#sorted + 1] = entry[2]
    end

    return sorted
end

function Deformation.pairs(flat)
    local out = {}
    if type(flat) ~= 'table' then return out end

    for i = 1, #flat - 1, 2 do
        local index = tonumber(flat[i])
        local magnitude = tonumber(flat[i + 1])
        if index and magnitude and index >= 1 and index <= GRID_SIZE then
            out[#out + 1] = { index = index, magnitude = magnitude }
        end
    end

    return out
end

-- ---------------------------------------------------------------------------------------
-- Restore
-- ---------------------------------------------------------------------------------------

--[[
    Seed a damage value for a target deformation magnitude.

    `SetVehicleDamage`'s `damage` argument and the deformation it produces are not documented
    and are not linear, but over the useful range - dents between 2 cm and 60 cm - they track
    closely enough that a linear seed lands within one or two corrections instead of the ten
    to fifty a fixed start needs.

    The constants are `Config.Deformation.seedBase` and `seedGain` so a server whose vehicles
    are mostly add-ons with unusual proportions can retune without editing this file. The
    defaults were fitted against the base game's compacts, sedans, SUVs and muscle cars.
]]
local function seedDamage(targetMetres)
    local base = tonumber(options().seedBase) or 20.0
    local gain = tonumber(options().seedGain) or 90.0
    return base + targetMetres * gain
end

--[[
    Put a stored deformation back onto a vehicle.

    Runs in its own thread with a time budget, because it is a search: each point is hit,
    measured and hit again until it is deep enough. Budgeted rather than iteration-capped
    because the cost per iteration depends on how many points there are, and what matters to a
    player is that the frame does not stall - not how many corrections it took.

    Returns immediately; the deformation appears over the next few frames. That is correct
    behaviour and not a compromise: the vehicle is normally still frozen and settling when
    this starts, and a player cannot see the difference between instant and 200 ms.
]]
function Deformation.apply(vehicle, flat, version)
    if not enabled() then return end
    if not DoesEntityExist(vehicle) then return end

    local entries = Deformation.pairs(flat)
    if #entries == 0 then return end

    local points = gridFor(GetEntityModel(vehicle))
    if not points then return end

    -- Two applications on one entity would each measure the other's work and over-correct.
    if applying[vehicle] then return end
    applying[vehicle] = true

    local scale = tonumber(options().quantiseScale) or 100.0
    local tolerance = tonumber(options().tolerance) or 0.03
    local budgetMs = tonumber(options().applyBudgetMs) or 120
    local maximumPasses = tonumber(options().maximumPasses) or 12

    CreateThread(function()
        local deadline = Park.ticks() + budgetMs
        local state = {}

        for i, entry in ipairs(entries) do
            state[i] = {
                point = points[entry.index],
                target = entry.magnitude / scale,
                damage = nil,
            }
        end

        local pass = 0
        local outstanding = #state

        while outstanding > 0 and pass < maximumPasses and Park.ticks() < deadline do
            if not DoesEntityExist(vehicle) then break end

            outstanding = 0
            pass = pass + 1

            for _, item in ipairs(state) do
                if not item.done then
                    local current = inwardMagnitude(
                        GetVehicleDeformationAtPos(vehicle, item.point.x, item.point.y, item.point.z),
                        item.point
                    )

                    if current >= item.target - tolerance then
                        item.done = true
                    else
                        -- First pass seeds from the target; later passes correct by the
                        -- remaining shortfall, which is what makes this converge rather
                        -- than crawl up in fixed steps.
                        if item.damage == nil then
                            item.damage = seedDamage(item.target)
                        else
                            item.damage = item.damage + seedDamage(item.target - current) * 0.6
                        end

                        SetVehicleDamage(
                            vehicle,
                            item.point.x, item.point.y, item.point.z,
                            item.damage,
                            item.damage,
                            true
                        )

                        outstanding = outstanding + 1
                    end
                end
            end

            Wait(0)
        end

        applying[vehicle] = nil

        -- The shape just changed, so anything cached about it is describing the car as it was
        -- before this ran.
        lastRead[vehicle] = nil

        if version then
            appliedVersion[vehicle] = version
        end

        Park.trace('deformation applied to %d in %d passes (%d points)', vehicle, pass, #state)
    end)
end

--[[
    Should this vehicle be re-captured?

    THE DRIFT GUARD. Apply is approximate, so capturing from a vehicle we restored and storing
    that produces a slightly different shape, and doing it every save sweep walks the damage
    away from what the player actually did to the car.

    So a restored vehicle is not re-captured until its body health has moved by more than
    `Config.Deformation.recaptureDelta` from where it was when we restored it, which only
    happens when it takes real new damage.

    `restoredAt` is the body health recorded at restore time. nil means this vehicle was never
    restored by us - it is a car somebody has been driving - and its deformation is its own.
]]
function Deformation.shouldRecapture(vehicle, restoredHealth)
    if not enabled() then return false end
    if not DoesEntityExist(vehicle) then return false end
    if restoredHealth == nil then return true end

    local delta = tonumber(options().recaptureDelta) or 20.0
    local current = GetVehicleBodyHealth(vehicle)

    return math.abs(current - restoredHealth) > delta
end

function Deformation.clear(vehicle)
    appliedVersion[vehicle] = nil
    applying[vehicle] = nil
    lastRead[vehicle] = nil
end


function Deformation.appliedAt(vehicle)
    return appliedVersion[vehicle]
end

-- ---------------------------------------------------------------------------------------
-- Synchronisation
--
-- The statebag is the shared source of truth, and every client applies it locally. That is
-- what makes two players see the same dents: they are not relying on the engine to agree
-- about a damage model, they are both running the same instructions.
--
-- The bag carries a VERSION as well as the data. Without one there is no way to tell an
-- update apart from a re-delivery of the value we already applied, and the handler fires on
-- both - so a car would be re-deformed every time any client came into scope, compounding the
-- approximation each time.
-- ---------------------------------------------------------------------------------------

--[[
    Defer entirely to Kiminaze's VehicleDeformation when it is installed.

    It writes the same kind of data to a statebag called `deformation` on the same entities.
    Two resources both deciding what shape a car is, on different schedules, produces a car
    that visibly pulses. Whoever is already there wins, and we stop touching deformation
    apart from storing what their export reports so that it survives a restart.
]]
local externalResource

local function external()
    if externalResource ~= nil then return externalResource end

    if options().deferToVehicleDeformation ~= false and Park.started('VehicleDeformation') then
        externalResource = 'VehicleDeformation'
        Park.log('VehicleDeformation is installed - deferring deformation handling to it')
    else
        externalResource = false
    end

    return externalResource
end

Deformation.external = external

AddStateBagChangeHandler('vpark:deform', '', function(bagName, _, value)
    if not enabled() or external() then return end
    if type(value) ~= 'table' then return end

    CreateThread(function()
        local entity

        -- The entity may not exist on this client yet: the bag arrives with the entity, and
        -- which lands first is not guaranteed. Wait for it, briefly, and give up quietly.
        local deadline = Park.ticks() + 10000
        repeat
            entity = GetEntityFromStateBagName(bagName)
            if entity and entity > 0 then break end
            Wait(100)
        until Park.ticks() > deadline

        if not entity or entity == 0 or not DoesEntityExist(entity) then return end

        local version = tonumber(value.v) or 0
        if appliedVersion[entity] == version then return end

        -- Wait for the vehicle to be a vehicle. A freshly created entity reports its model
        -- as 0 for a frame or two, and `GetModelDimensions(0)` gives us a grid of zeroes.
        local ready = Park.ticks() + 5000
        while GetEntityModel(entity) == 0 and Park.ticks() < ready do Wait(50) end

        appliedVersion[entity] = version
        Deformation.apply(entity, value.d, version)
    end)
end)

--[[
    Read deformation through whichever implementation is in charge.

    Used by the capture path so that a server running VehicleDeformation still gets its damage
    persisted by us - we store what their export reports, in their format, and hand it back to
    them on restore. Interoperating beats competing.
]]
function Deformation.read(vehicle)
    if external() then
        local data = Park.try(function()
            return exports.VehicleDeformation:GetVehicleDeformation(vehicle)
        end)
        if type(data) == 'table' and #data > 0 then
            return { external = true, points = data }
        end
        return nil
    end

    local flat = Deformation.capture(vehicle)
    if not flat then return nil end
    return { g = GRID_VERSION, d = flat }
end

--[[
    Write deformation through whichever implementation is in charge.
]]
function Deformation.write(vehicle, stored, version)
    if type(stored) ~= 'table' then return end

    if stored.external then
        Park.try(function()
            exports.VehicleDeformation:SetVehicleDeformation(vehicle, stored.points)
        end)
        return
    end

    -- A capture from a different grid version cannot be interpreted. Ignoring it leaves an
    -- undamaged car, which is a far smaller error than applying somebody else's dents.
    if (tonumber(stored.g) or 0) ~= GRID_VERSION then
        Park.debug('ignoring a deformation stored under grid version %s (we are on %d)',
            tostring(stored.g), GRID_VERSION)
        return
    end

    Deformation.apply(vehicle, stored.d, version)
end
