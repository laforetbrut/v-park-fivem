--[[
    client/properties.lua

    Reading everything off a vehicle, and putting it all back.

    -------------------------------------------------------------------------------------------
    THE APPLY ORDER IS THE WHOLE FILE
    -------------------------------------------------------------------------------------------

    Capture is mechanical: call a hundred getters, put the answers in a table. Nothing can go
    subtly wrong.

    Apply is not. The game has real ordering constraints, none of them documented, and getting
    one wrong produces a vehicle that looks ALMOST right - which is worse than one that looks
    wrong, because nobody reports it and everybody notices it.

    Every one of these was paid for:

    1. `SetVehicleModKit(vehicle, 0)` MUST run before any `SetVehicleMod`. Without it every mod
       call silently does nothing and returns nothing. This is the single most common bug in
       vehicle property code anywhere, and the symptom is a car that comes back stock.

    2. Wheel TYPE resets the fitted wheels to that type's default. So type first, then the
       front and back wheel mods. Backwards, and every custom rim is wiped by the line that
       was supposed to make it possible.

    3. `SetVehicleColours` clears the custom-paint flag. So indices first, then
       `SetVehicleCustomPrimaryColour`. Backwards, and a custom-painted car comes back in the
       nearest stock colour.

    4. Toggling an extra on a damaged panel REPAIRS that panel. So extras before body health,
       or a car with a broken bonnet and an extra fitted comes back with a healthy bonnet.

    5. Damage LAST, always. Everything above can undo damage; nothing below it can.

    6. Deformation after damage AND after health, for the same reason as 4: setting body
       health smooths the bodywork, and a dent applied before it is a dent that is ironed out
       a line later.

    `shared/schema.lua` encodes this order as numbers, and `Schema.ordered()` is what the
    restore path walks. This file implements each step.
]]

Properties = {}

--[[
    Property name -> the game's mod slot index.

    Module level, and not built inside `capture`, because `apply` reads it too and a vehicle
    can be restored on a client that has never captured one. Building it in the capture path
    left `apply` with a nil table on a fresh client, and the symptom was a car that streamed in
    stock the first time and correctly modified every time after - which reads as a race and is
    not one.

    Slots 18, 20 and 22 are absent on purpose: they are TOGGLE mods, set with a different
    native, and putting them in this table would call `SetVehicleMod` with a boolean.

    Slots 21 (unused) and 49 (lightbar) behave differently across builds; 49 is included
    because emergency vehicles use it and a missing lightbar on a restored cruiser is very
    visible.
]]
local MOD_SLOTS = {
    modSpoilers = 0, modFrontBumper = 1, modRearBumper = 2, modSideSkirt = 3,
    modExhaust = 4, modFrame = 5, modGrille = 6, modHood = 7, modFender = 8,
    modRightFender = 9, modRoof = 10, modEngine = 11, modBrakes = 12,
    modTransmission = 13, modHorns = 14, modSuspension = 15, modArmor = 16,
    modNitrous = 17, modSubwoofer = 19, modFrontWheels = 23, modBackWheels = 24,
    modPlateHolder = 25, modVanityPlate = 26, modTrimA = 27, modOrnaments = 28,
    modDashboard = 29, modDial = 30, modDoorSpeaker = 31, modSeats = 32,
    modSteeringWheel = 33, modShifterLeavers = 34, modAPlate = 35, modSpeakers = 36,
    modTrunk = 37, modHydrolic = 38, modEngineBlock = 39, modAirFilter = 40,
    modStruts = 41, modArchCover = 42, modAerials = 43, modTrimB = 44, modTank = 45,
    modWindows = 46, modDoorR = 47, modLivery = 48, modLightbar = 49,
}

Properties.MOD_SLOTS = MOD_SLOTS

--[[
    entity -> { fingerprint, tuning }

    The tuning half of a capture - every mod slot, the colours, the extras, the neons, the
    wheels - is about seventy-five native calls and describes things that only change at a
    mechanic. The rest of a capture is thirty calls and describes things that change while
    somebody drives.

    So the expensive half is cached against a cheap fingerprint, and re-read only when the
    fingerprint moves. A parked car being swept costs the fingerprint plus the dynamic half;
    the seventy-five calls happen when somebody has actually fitted something.

    Bounded by `Config.Performance.propertyCache`, evicted oldest-first, and cleared for an
    entity when it stops existing.
]]
local tuningCache = {}
local tuningOrder = {}
local tuningCount = 0

local function cacheLimit()
    return math.max(16, math.floor(tonumber(Config.Performance and Config.Performance.propertyCache) or 200))
end

local function rememberTuning(vehicle, fingerprint, tuning)
    if not tuningCache[vehicle] then
        tuningCount = tuningCount + 1
        tuningOrder[tuningCount] = vehicle
    end

    -- The model is stored alongside and checked on the way out. See `tuningFingerprint`.
    tuningCache[vehicle] = {
        fingerprint = fingerprint,
        model = GetEntityModel(vehicle),
        tuning = tuning,
    }

    -- Evict oldest-first once over the limit. A plain table would grow for the life of the
    -- session on a server where players drive a lot of different vehicles.
    local limit = cacheLimit()
    if tuningCount > limit then
        local drop = tuningCount - limit
        for index = 1, drop do
            local victim = tuningOrder[index]
            if victim and tuningCache[victim] then tuningCache[victim] = nil end
        end

        local shifted = {}
        local count = 0
        for index = drop + 1, tuningCount do
            count = count + 1
            shifted[count] = tuningOrder[index]
        end
        tuningOrder = shifted
        tuningCount = count
    end
end

function Properties.forget(vehicle)
    if tuningCache[vehicle] then tuningCache[vehicle] = nil end
end

--[[
    A cheap summary of everything the tuning half describes.

    Sixteen native calls chosen to move whenever anything in that half does: the identity of
    the vehicle, the colour indices, the custom paint, the wheel type, the livery, the window
    tint, three sample mod slots across the visual, performance and wheel ranges, the turbo
    toggle, and the neon state.

    It is not a hash of the whole thing and does not need to be. Fitting a spoiler changes slot
    0; fitting an engine changes slot 11; a respray changes the colours. The one case it would
    miss is a mod changing in a slot nothing samples while every sampled value stays identical,
    which requires a deliberate effort to construct.

    -------------------------------------------------------------------------------------------
    THE MODEL AND THE PLATE ARE IN HERE FOR A REASON. DO NOT TAKE THEM OUT.
    -------------------------------------------------------------------------------------------

    The cache is keyed on the entity handle, and the game REUSES entity handles. A vehicle that
    despawns frees its handle, and the next vehicle created can be given the same number.

    1.0.1 sampled only the tuning values, so a cache entry survived that reuse: handle 1234 was
    a custom-painted Sultan, handle 1234 became a Bison, the two agreed on every sampled value,
    and the cache hit stamped the Sultan's paint onto the Bison. That car was then SAVED in the
    wrong colour, so it also came back wrong - which is why the report was "wrong colours when
    it loads, and the same on restore". It was one bug, seen twice.

    Note also that custom RGB paint is sampled here. It is invisible to `GetVehicleColours`,
    which keeps answering the underlying index while a custom colour is displayed, so without
    these four calls a respray from indexed to custom would not move the fingerprint at all.
]]
local function tuningFingerprint(vehicle)
    local primary, secondary = GetVehicleColours(vehicle)
    local pearlescent, wheelColour = GetVehicleExtraColours(vehicle)

    local custom = ''
    if GetIsVehiclePrimaryColourCustom(vehicle) then
        local r, g, b = GetVehicleCustomPrimaryColour(vehicle)
        custom = ('%d,%d,%d'):format(r or 0, g or 0, b or 0)
    end
    if GetIsVehicleSecondaryColourCustom(vehicle) then
        local r, g, b = GetVehicleCustomSecondaryColour(vehicle)
        custom = custom .. ('/%d,%d,%d'):format(r or 0, g or 0, b or 0)
    end

    -- The paint type, which `GetVehicleColours` cannot see: a car resprayed from metallic to
    -- matte in the same colour has identical indices and a different paint type.
    local paintType = GetVehicleModColor_1(vehicle) or 0

    return ('%d.%s.%d.%d.%d.%d.%d.%d.%d.%d.%d.%d.%s.%s.%s.%d'):format(
        GetEntityModel(vehicle) or 0,
        tostring(GetVehicleNumberPlateText(vehicle) or ''),
        primary or 0, secondary or 0,
        pearlescent or 0, wheelColour or 0,
        GetVehicleWheelType(vehicle) or 0,
        GetVehicleLivery(vehicle) or -1,
        GetVehicleWindowTint(vehicle) or 0,
        GetVehicleMod(vehicle, 0) or -1,
        GetVehicleMod(vehicle, 11) or -1,
        GetVehicleMod(vehicle, 23) or -1,
        tostring(IsToggleModOn(vehicle, 18)),
        tostring(IsVehicleNeonLightEnabled(vehicle, 0)),
        custom,
        paintType
    )
end

Properties.fingerprint = tuningFingerprint

--[[
    Call whichever of two native spellings this game build actually has.

    CFX is inconsistent about `Colour` and `Color`, and which one exists varies by build. A
    call to the absent spelling is a nil call that takes down whatever was capturing, so every
    affected native goes through here.

    Returns nil when neither exists, which every caller treats as "not stored".
]]
function Properties.native(british, american, ...)
    local fn = _G[british] or _G[american]
    if not fn then return nil end

    local ok, result = pcall(fn, ...)
    if not ok then return nil end
    return result
end

-- ---------------------------------------------------------------------------------------
-- Capture
-- ---------------------------------------------------------------------------------------

--[[
    Read every property off a vehicle.

    Captures EVERYTHING regardless of `Config.Save.fields`. The filtering is done server-side,
    on the way in, for two reasons: a getter is cheaper than a config lookup, and it means
    changing what is stored takes effect on the next save rather than on the next time every
    client restarts.
]]
--[[
    `options.skipDeformation` leaves the deformation out entirely.

    Not a micro-optimisation: `Deformation.read` is the most expensive thing in a capture, and
    `Stream.snapshot` knows before it asks whether it is going to keep the answer - a restored
    vehicle whose body health has not moved is not re-captured, because apply is approximate and
    re-capturing a restored shape walks the damage. It used to read the deformation and then throw
    it away, which is the whole cost for none of the benefit.
]]
function Properties.capture(vehicle, options)
    if not DoesEntityExist(vehicle) then return nil end

    local properties = {}

    properties.model = GetEntityModel(vehicle)
    properties.plate = Park.plate(GetVehicleNumberPlateText(vehicle))
    properties.plateIndex = GetVehicleNumberPlateTextIndex(vehicle)
    properties.lockState = GetVehicleDoorLockStatus(vehicle)

    properties.bodyHealth = Park.round(GetVehicleBodyHealth(vehicle), 1)
    properties.engineHealth = Park.round(GetVehicleEngineHealth(vehicle), 1)
    properties.tankHealth = Park.round(GetVehiclePetrolTankHealth(vehicle), 1)
    properties.dirtLevel = Park.round(GetVehicleDirtLevel(vehicle), 1)
    properties.oilLevel = Park.round(GetVehicleOilLevel(vehicle), 2)

    properties.fuelLevel = Compat.getFuel(vehicle)

    properties.engineOn = GetIsVehicleEngineRunning(vehicle)

    -- Convertibles only. 0 up, 1 lowering, 2 down, 3 raising. The two transitional states are
    -- stored as the state they are heading for, because a roof frozen mid-fold is not a thing
    -- to restore.
    local roof = GetConvertibleRoofState(vehicle)
    if roof == 1 then roof = 2 elseif roof == 3 then roof = 0 end
    properties.roofState = roof

    -- ------------------------------------------------------------------- colours ---
    local primary, secondary = GetVehicleColours(vehicle)
    properties.color1 = primary
    properties.color2 = secondary

    local pearlescent, wheelColour = GetVehicleExtraColours(vehicle)
    properties.pearlescentColor = pearlescent
    properties.wheelColor = wheelColour

    --[[
        CFX is inconsistent about `Colour` and `Color` on exactly these two, and which
        spelling exists depends on the game build. Calling the wrong one is a nil call that
        takes the whole capture with it, so both are tried and neither is assumed.

        `Properties.native` at the top of this file is the helper; it returns nil rather than
        raising when neither spelling is present, and a nil colour is simply not stored.
    ]]
    properties.interiorColor = Properties.native('GetVehicleInteriorColour', 'GetVehicleInteriorColor', vehicle)
    properties.dashboardColor = Properties.native('GetVehicleDashboardColour', 'GetVehicleDashboardColor', vehicle)

    --[[
        THE WHOLE ANSWER, NOT THE FIRST THIRD OF IT.

        `GET_VEHICLE_MOD_COLOR_1` returns THREE values - the paint type, the colour within that
        type, and the pearlescent colour - and `GET_VEHICLE_MOD_COLOR_2` returns two. Storing
        only the paint type and then feeding the setter a colour index from
        `GetVehicleColours`, which is a DIFFERENT colour space entirely, is how a restored
        vehicle came back in a colour nobody had ever chosen.

        See `applyColours` for the other half of it, and for why the order there matters.
    ]]
    properties.modColor1 = { GetVehicleModColor_1(vehicle) }
    properties.modColor2 = { GetVehicleModColor_2(vehicle) }

    -- The paint types on their own, still written for anything reading the old keys.
    properties.paintType1 = properties.modColor1[1]
    properties.paintType2 = properties.modColor2[1]

    -- Custom RGB paint is a SEPARATE thing from the colour index, and only present when the
    -- flag says so. Reading it unconditionally returns the last custom colour the entity slot
    -- ever had, which is somebody else's car.
    if GetIsVehiclePrimaryColourCustom(vehicle) then
        properties.customPrimary = { GetVehicleCustomPrimaryColour(vehicle) }
    end
    if GetIsVehicleSecondaryColourCustom(vehicle) then
        properties.customSecondary = { GetVehicleCustomSecondaryColour(vehicle) }
    end

    properties.windowTint = GetVehicleWindowTint(vehicle)
    properties.xenonColor = Properties.native('GetVehicleXenonLightsColour', 'GetVehicleXenonLightsColor', vehicle) or 255
    properties.tyreSmokeColor = { GetVehicleTyreSmokeColor(vehicle) }

    -- --------------------------------------------------------------------- neons ---
    local neonEnabled = {}
    for index = 0, 3 do
        neonEnabled[index + 1] = IsVehicleNeonLightEnabled(vehicle, index)
    end
    properties.neonEnabled = neonEnabled
    properties.neonColor = { GetVehicleNeonLightsColour(vehicle) }

    -- -------------------------------------------------------------------- extras ---
    -- The game's own convention is inverted and it is worth writing down: an extra that is
    -- TURNED ON is stored as 0, and one turned off as 1, because that is what
    -- `SetVehicleExtra` takes. Storing the intuitive way round and inverting on apply is the
    -- same information and one more place to get it backwards.
    local extras = {}
    for index = 1, 20 do
        if DoesExtraExist(vehicle, index) then
            extras[tostring(index)] = IsVehicleExtraTurnedOn(vehicle, index) and 0 or 1
        end
    end
    properties.extras = extras

    -- ------------------------------------------------------------- modifications ---
    --
    -- The expensive half. Read from cache when the fingerprint says nothing about it has
    -- changed, which on a parked car is always.
    local fingerprint = tuningFingerprint(vehicle)
    local cached = tuningCache[vehicle]

    -- The model is checked separately as well as being inside the fingerprint. It costs one
    -- comparison, and a cache that can hand one vehicle's paint to another is the single worst
    -- thing this file could do: the wrong value is then written to the database as the truth.
    if cached and cached.fingerprint == fingerprint and cached.model == GetEntityModel(vehicle) then
        for key, value in pairs(cached.tuning) do
            properties[key] = value
        end

        -- Everything below the tuning block still runs: damage, doors, deformation and the
        -- dynamic values are cheap and change while somebody is driving.
        goto tuningDone
    end

    do
    properties.wheels = GetVehicleWheelType(vehicle)

    -- CFX additions rather than base game natives, and absent on an old build. A nil here is
    -- simply not stored, and the vehicle comes back on its wheel type's default geometry.
    if GetVehicleWheelWidth then
        properties.wheelWidth = Park.round(GetVehicleWheelWidth(vehicle), 3)
    end
    if GetVehicleWheelSize then
        properties.wheelSize = Park.round(GetVehicleWheelSize(vehicle), 3)
    end

    for name, slot in pairs(MOD_SLOTS) do
        properties[name] = GetVehicleMod(vehicle, slot)
    end

    -- Toggle mods answer a boolean and are set with a different native. Kept separate for
    -- that reason and for no other.
    properties.modTurbo = IsToggleModOn(vehicle, 18)
    properties.modSmokeEnabled = IsToggleModOn(vehicle, 20)
    properties.modXenon = IsToggleModOn(vehicle, 22)

    properties.modCustomTiresF = GetVehicleModVariation(vehicle, 23)
    properties.modCustomTiresR = GetVehicleModVariation(vehicle, 24)

    properties.bulletProofTyres = GetVehicleTyresCanBurst(vehicle) == false
    properties.driftTyres = GetDriftTyresEnabled and GetDriftTyresEnabled(vehicle) or false

    properties.livery = GetVehicleLivery(vehicle)
    properties.roofLivery = GetVehicleRoofLivery and GetVehicleRoofLivery(vehicle) or -1

    -- Remember the expensive half against the fingerprint that produced it.
    do
        local tuning = {}
        for _, group in ipairs({ 'modifications', 'colours', 'customPaint', 'windowTint',
                                 'xenon', 'neons', 'tyreSmoke', 'livery', 'extras',
                                 'wheelType' }) do
            for _, key in ipairs(Schema.keys[group] or {}) do
                tuning[key] = properties[key]
            end
        end
        rememberTuning(vehicle, fingerprint, tuning)
    end
    end

    ::tuningDone::

    -- -------------------------------------------------------------------- damage ---
    local windows = {}
    for index = 0, 7 do
        -- Rolling the window up first is the reference implementation's trick and it is
        -- correct: a window that is merely DOWN reads as not intact, and storing that as
        -- smashed means every car with an open window comes back with broken glass.
        RollUpWindow(vehicle, index)
        if not IsVehicleWindowIntact(vehicle, index) then
            windows[#windows + 1] = index
        end
    end
    properties.windows = windows

    local doors = {}
    for index = 0, 5 do
        if IsVehicleDoorDamaged(vehicle, index) then
            doors[#doors + 1] = index
        end
    end
    properties.doors = doors

    -- 1 punctured, 2 completely burst, 3 broken off the axle. Three different states and
    -- three different repairs, so they are stored as the state and not as a boolean.
    local tyres = {}
    for index = 0, 7 do
        if IsVehicleTyreBurst(vehicle, index, false) then
            if IsVehicleWheelBrokenOff and IsVehicleWheelBrokenOff(vehicle, index) then
                tyres[tostring(index)] = 3
            else
                tyres[tostring(index)] = IsVehicleTyreBurst(vehicle, index, true) and 2 or 1
            end
        end
    end
    properties.tyres = tyres

    -- Which doors are standing open, and how far. Only stored when the config asks for it,
    -- because most servers want a parked car to have its doors shut.
    local doorsOpen = {}
    for index = 0, 5 do
        local ratio = GetVehicleDoorAngleRatio(vehicle, index)
        if type(ratio) == 'number' and ratio > 0.01 then
            doorsOpen[tostring(index)] = Park.round(ratio, 2)
        end
    end
    properties.doorsOpen = doorsOpen

    -- --------------------------------------------------------------- deformation ---
    if not (type(options) == 'table' and options.skipDeformation) then
        properties.deformation = Deformation.read(vehicle)
    end

    return properties
end

--[[
    The statebag keys the config asked to carry, read off the entity.

    Separate from `capture` because the server writes them back itself - a replicated statebag
    can only be set by the server or by the entity's owner, and the restore path is
    server-side.
]]
function Properties.captureStatebags(vehicle)
    if not DoesEntityExist(vehicle) then return nil end

    local wanted = (Config and Config.Save and Config.Save.statebagKeys) or {}
    if #wanted == 0 then return nil end

    local state = Entity(vehicle).state
    local out = {}
    local found = false

    for _, key in ipairs(wanted) do
        local ok, value = pcall(function() return state[key] end)
        if ok and value ~= nil then
            -- Only scalars and small tables. A statebag holding a large structure is another
            -- resource's business and not something to copy into our row.
            local kind = type(value)
            if kind == 'number' or kind == 'string' or kind == 'boolean' then
                out[key] = value
                found = true
            elseif kind == 'table' and #Park.encode(value) < 2048 then
                out[key] = value
                found = true
            end
        end
    end

    if not found then return nil end
    return out
end

-- ---------------------------------------------------------------------------------------
-- Apply
-- ---------------------------------------------------------------------------------------

local function applyModifications(vehicle, properties)
    -- STEP 1. Without this every SetVehicleMod below is a silent no-op.
    SetVehicleModKit(vehicle, 0)

    -- STEP 2. Wheel type first: setting it resets the fitted wheels to that type's default,
    -- so anything fitted before this line is thrown away by it.
    if type(properties.wheels) == 'number' then
        SetVehicleWheelType(vehicle, properties.wheels)
    end

    for name, slot in pairs(MOD_SLOTS) do
        local value = properties[name]
        if type(value) == 'number' and value >= -1 then
            -- The two wheel slots take a variation flag as well, and it is a separate stored
            -- property because a custom tyre and a stock one can be the same mod index.
            if slot == 23 then
                SetVehicleMod(vehicle, slot, value, properties.modCustomTiresF == true)
            elseif slot == 24 then
                SetVehicleMod(vehicle, slot, value, properties.modCustomTiresR == true)
            else
                SetVehicleMod(vehicle, slot, value, false)
            end
        end
    end

    if properties.modTurbo ~= nil then ToggleVehicleMod(vehicle, 18, properties.modTurbo == true) end
    if properties.modSmokeEnabled ~= nil then ToggleVehicleMod(vehicle, 20, properties.modSmokeEnabled == true) end
    if properties.modXenon ~= nil then ToggleVehicleMod(vehicle, 22, properties.modXenon == true) end

    -- Wheel geometry, after the wheels themselves. Only on a vehicle whose type supports it;
    -- writing a width to a model that has none produces wheels the size of the car.
    if type(properties.wheelWidth) == 'number' and properties.wheelWidth > 0 and SetVehicleWheelWidth then
        SetVehicleWheelWidth(vehicle, properties.wheelWidth)
    end
    if type(properties.wheelSize) == 'number' and properties.wheelSize > 0 and SetVehicleWheelSize then
        SetVehicleWheelSize(vehicle, properties.wheelSize)
    end

    if properties.bulletProofTyres ~= nil then
        SetVehicleTyresCanBurst(vehicle, not properties.bulletProofTyres)
    end
    if properties.driftTyres ~= nil and SetDriftTyresEnabled then
        SetDriftTyresEnabled(vehicle, properties.driftTyres == true)
    end
end

local function applyColours(vehicle, properties)
    --[[
        ==============================================================================
        THE PAINT TYPES FIRST, THEN THE COLOURS. THIS ORDER IS THE FIX.
        ==============================================================================

        THIS IS WHY VEHICLES CHANGED COLOUR ON THEIR OWN.

        `SET_VEHICLE_MOD_COLOR_1` and `SET_VEHICLE_COLOURS` write the same paint through two
        different APIs, and whichever runs last wins. Until 1.0.9 the colours were set first
        and the mod colours second - so the mod colours won.

        And the mod colours were being fed nonsense. The capture stored only the FIRST of the
        three values `GET_VEHICLE_MOD_COLOR_1` returns, and the apply then filled the other two
        in from somewhere else entirely:

            SetVehicleModColor_1(vehicle, paintType1, color1, 0)
                                          ^ correct  ^ from GetVehicleColours, a different
                                                       colour space
                                                            ^ a literal zero, wiping the
                                                              pearlescent colour

        So the last thing to touch the paint was a call with two wrong arguments out of three.
        The car came back in a colour nobody had chosen - and then the capture read that colour
        and wrote it to the database, so it was wrong from then on without anybody touching it.
        That is the "they change colour on their own" report, and it is why it never settled.

        The whole triple is stored now and applied first, and `SetVehicleColours` runs after it
        to set the primary and secondary indices, which is the order every other property
        implementation in the ecosystem uses.
    ]]
    local mod1 = properties.modColor1
    if type(mod1) == 'table' and type(mod1[1]) == 'number' then
        SetVehicleModColor_1(vehicle, mod1[1], mod1[2] or 0, mod1[3] or 0)
    elseif type(properties.paintType1) == 'number' then
        -- A row written before 1.0.9 has the paint type and nothing else. Set the type and
        -- leave the colour to `SetVehicleColours` below rather than inventing the rest.
        SetVehicleModColor_1(vehicle, properties.paintType1, 0, 0)
    end

    local mod2 = properties.modColor2
    if type(mod2) == 'table' and type(mod2[1]) == 'number' then
        SetVehicleModColor_2(vehicle, mod2[1], mod2[2] or 0)
    elseif type(properties.paintType2) == 'number' then
        SetVehicleModColor_2(vehicle, properties.paintType2, 0)
    end

    if type(properties.color1) == 'number' and type(properties.color2) == 'number' then
        SetVehicleColours(vehicle, properties.color1, properties.color2)
    end

    if type(properties.pearlescentColor) == 'number' and type(properties.wheelColor) == 'number' then
        SetVehicleExtraColours(vehicle, properties.pearlescentColor, properties.wheelColor)
    end

    if type(properties.interiorColor) == 'number' then
        Properties.native('SetVehicleInteriorColour', 'SetVehicleInteriorColor',
            vehicle, properties.interiorColor)
    end
    if type(properties.dashboardColor) == 'number' then
        Properties.native('SetVehicleDashboardColour', 'SetVehicleDashboardColor',
            vehicle, properties.dashboardColor)
    end

end

local function applyCustomPaint(vehicle, properties)
    -- STEP 3. After the indices, because setting an index clears the custom flag. This is why
    -- customPaint is its own schema group with its own order number.
    local primary = properties.customPrimary
    if type(primary) == 'table' and #primary == 3 then
        SetVehicleCustomPrimaryColour(vehicle, primary[1], primary[2], primary[3])
    end

    local secondary = properties.customSecondary
    if type(secondary) == 'table' and #secondary == 3 then
        SetVehicleCustomSecondaryColour(vehicle, secondary[1], secondary[2], secondary[3])
    end
end

local function applyExtras(vehicle, properties)
    -- STEP 4. Before body health, because toggling an extra repairs the panel it is on.
    if type(properties.extras) ~= 'table' then return end

    for key, value in pairs(properties.extras) do
        local index = tonumber(key)
        if index then
            -- The inverted convention, unwound here and nowhere else: stored 0 means on, and
            -- `SetVehicleExtra`'s second argument means "disable".
            SetVehicleExtra(vehicle, index, tonumber(value) == 1)
        end
    end
end

local function applyDamage(vehicle, properties)
    -- STEP 5. Last of the visual state, because everything above repairs things.
    if type(properties.windows) == 'table' then
        for _, index in ipairs(properties.windows) do
            SmashVehicleWindow(vehicle, index)
        end
    end

    if type(properties.doors) == 'table' then
        for _, index in ipairs(properties.doors) do
            -- The third argument is `deleteDoor`. TRUE removes the door outright, which is
            -- what every other property implementation in the ecosystem does and what
            -- `IsVehicleDoorDamaged` reports afterwards, so it is what round-trips.
            --
            -- FALSE makes the door hang off its hinge, which looks better and does NOT
            -- round-trip: the next capture reads it as intact and the damage is lost.
            SetVehicleDoorBroken(vehicle, index, true)
        end
    end

    if type(properties.tyres) == 'table' then
        for key, state in pairs(properties.tyres) do
            local index = tonumber(key)
            local level = tonumber(state)
            if index and level then
                if level == 3 then
                    -- Broken off entirely. Burst it completely first, or the wheel comes off
                    -- an intact tyre and the model glitches.
                    SetVehicleTyreBurst(vehicle, index, false, 1000.0)
                    BreakOffVehicleWheel(vehicle, index, true, true, true, false)
                else
                    SetVehicleTyreBurst(vehicle, index, level == 1, 1000.0)
                end
            end
        end
    end
end

--[[
    Apply a captured property set to a vehicle.

    `options.skipDeformation` exists for the panel's repair action, which wants everything
    else restored and the dents left out.
]]
function Properties.apply(vehicle, properties, options)
    if not DoesEntityExist(vehicle) then return false end
    if type(properties) ~= 'table' then return false end

    options = options or {}

    local enabledGroup = Schema.enabled

    -- The vehicle must not be repairing itself underneath us while we build it. Some game
    -- builds tick a slow auto-repair on a vehicle nobody is in, which quietly undoes the
    -- damage we are about to apply.
    if SetVehicleAutoRepairDisabled then
        SetVehicleAutoRepairDisabled(vehicle, true)
    end

    if enabledGroup('modifications') then
        applyModifications(vehicle, properties)
    else
        -- Even with modifications off, the mod kit must be set or the plate index and a few
        -- other calls below behave inconsistently between builds.
        SetVehicleModKit(vehicle, 0)
    end

    if enabledGroup('colours') then applyColours(vehicle, properties) end
    if enabledGroup('customPaint') then applyCustomPaint(vehicle, properties) end

    if enabledGroup('windowTint') and type(properties.windowTint) == 'number' then
        SetVehicleWindowTint(vehicle, properties.windowTint)
    end

    if enabledGroup('xenon') and type(properties.xenonColor) == 'number' then
        Properties.native('SetVehicleXenonLightsColour', 'SetVehicleXenonLightsColor',
            vehicle, properties.xenonColor)
    end

    if enabledGroup('neons') then
        if type(properties.neonEnabled) == 'table' then
            for index = 0, 3 do
                SetVehicleNeonLightEnabled(vehicle, index, properties.neonEnabled[index + 1] == true)
            end
        end
        local colour = properties.neonColor
        if type(colour) == 'table' and #colour == 3 then
            SetVehicleNeonLightsColour(vehicle, colour[1], colour[2], colour[3])
        end
    end

    if enabledGroup('tyreSmoke') then
        local smoke = properties.tyreSmokeColor
        if type(smoke) == 'table' and #smoke == 3 then
            SetVehicleTyreSmokeColor(vehicle, smoke[1], smoke[2], smoke[3])
        end
    end

    if enabledGroup('livery') then
        if type(properties.livery) == 'number' and properties.livery >= 0 then
            SetVehicleLivery(vehicle, properties.livery)
        end
        if type(properties.roofLivery) == 'number' and properties.roofLivery >= 0 and SetVehicleRoofLivery then
            SetVehicleRoofLivery(vehicle, properties.roofLivery)
        end
    end

    if enabledGroup('extras') then applyExtras(vehicle, properties) end

    if enabledGroup('plate') then
        if properties.plate then
            SetVehicleNumberPlateText(vehicle, properties.plate)
        end
        if type(properties.plateIndex) == 'number' then
            SetVehicleNumberPlateTextIndex(vehicle, properties.plateIndex)
        end
    end

    if enabledGroup('lockState') and type(properties.lockState) == 'number' then
        SetVehicleDoorsLocked(vehicle, properties.lockState)
    end

    if enabledGroup('roofState') and type(properties.roofState) == 'number' then
        -- Instant, not animated: an animated fold on a car that has just appeared looks like
        -- a glitch rather than a feature.
        SetConvertibleRoof(vehicle, true)
        if properties.roofState == 2 then
            LowerConvertibleRoof(vehicle, true)
        else
            RaiseConvertibleRoof(vehicle, true)
        end
    end

    if enabledGroup('engineState') then
        local on = properties.engineOn == true
        SetVehicleEngineOn(vehicle, on, true, true)
    else
        SetVehicleEngineOn(vehicle, false, true, true)
    end

    if enabledGroup('fuel') and type(properties.fuelLevel) == 'number' then
        Compat.setFuel(vehicle, properties.fuelLevel)
    end

    if enabledGroup('oil') and type(properties.oilLevel) == 'number' then
        SetVehicleOilLevel(vehicle, properties.oilLevel)
    end

    if enabledGroup('dirt') and type(properties.dirtLevel) == 'number' then
        SetVehicleDirtLevel(vehicle, properties.dirtLevel + 0.0)
    end

    if enabledGroup('health') then
        if type(properties.bodyHealth) == 'number' then
            SetVehicleBodyHealth(vehicle, properties.bodyHealth + 0.0)
        end
        if type(properties.engineHealth) == 'number' then
            SetVehicleEngineHealth(vehicle, properties.engineHealth + 0.0)
        end
        if type(properties.tankHealth) == 'number' then
            SetVehiclePetrolTankHealth(vehicle, properties.tankHealth + 0.0)
        end
    end

    if enabledGroup('doorsOpen') and type(properties.doorsOpen) == 'table' then
        for key, ratio in pairs(properties.doorsOpen) do
            local index = tonumber(key)
            if index then
                SetVehicleDoorOpen(vehicle, index, false, true)
                SetVehicleDoorControl(vehicle, index, 1, tonumber(ratio) or 1.0)
            end
        end
    else
        SetVehicleDoorsShut(vehicle, true)
    end

    if enabledGroup('damage') then applyDamage(vehicle, properties) end

    if enabledGroup('deformation') and not options.skipDeformation then
        Deformation.write(vehicle, properties.deformation, options.version)
    end

    return true
end

-- ---------------------------------------------------------------------------------------
-- Repair
--
-- Used by the admin panel and by the API. Not the same as `SetVehicleFixed`: that repairs the
-- mesh and leaves burst tyres and a dead battery on some builds, and it does not touch the
-- deformation data we are carrying for the vehicle.
-- ---------------------------------------------------------------------------------------

function Properties.repair(vehicle)
    if not DoesEntityExist(vehicle) then return false end

    SetVehicleFixed(vehicle)
    SetVehicleDeformationFixed(vehicle)
    SetVehicleUndriveable(vehicle, false)

    SetVehicleBodyHealth(vehicle, 1000.0)
    SetVehicleEngineHealth(vehicle, 1000.0)
    SetVehiclePetrolTankHealth(vehicle, 1000.0)

    for index = 0, 7 do
        SetVehicleTyreFixed(vehicle, index)
    end
    for index = 0, 7 do
        FixVehicleWindow(vehicle, index)
    end

    SetVehicleDirtLevel(vehicle, 0.0)
    SetVehicleEngineOn(vehicle, false, true, true)

    Deformation.clear(vehicle)

    return true
end
