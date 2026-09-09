--[[
    shared/schema.lua

    What a stored vehicle IS: the list of property groups, which config toggle gates each one,
    and the order they are applied in on restore.

    -------------------------------------------------------------------------------------------
    WHY THIS IS A TABLE AND NOT A HUNDRED IF STATEMENTS
    -------------------------------------------------------------------------------------------

    The client captures properties, the client applies them, the server strips the ones the
    config turned off, and the size guard drops groups in a defined order when a row is too
    big. That is four places that must agree on what a "group" is. When they were four
    separate lists, turning off `Config.Save.neons` stopped the capture and not the apply, and
    a restored vehicle got its neons from whatever the last vehicle in that entity slot had.

    -------------------------------------------------------------------------------------------
    APPLY ORDER IS NOT ARBITRARY
    -------------------------------------------------------------------------------------------

    The game has real ordering constraints and getting them wrong produces a vehicle that
    looks almost right, which is worse than one that looks wrong:

      1. `SetVehicleModKit(vehicle, 0)` MUST run before any `SetVehicleMod`. Without it every
         mod call silently does nothing. This is the single most common bug in vehicle
         property code.
      2. Wheel TYPE must be set before wheel MODS. Setting the type resets the fitted wheels
         to the default for that type, so doing it afterwards wipes them.
      3. Custom paint (`SetVehicleCustomPrimaryColour`) must come after the colour indices,
         because setting an index clears the custom flag.
      4. Extras must come before body health, because toggling an extra on a damaged panel
         restores the panel.
      5. Damage last, always. Everything above it can undo damage; nothing below it can.

    `order` below encodes that. Do not reorder it without reading this list again.
]]

Schema = {}

--[[
    The groups.

        key      the group name, used in Config.Save.fields and in the size guard
        gate     the Config.Save.fields key that switches it off. nil means never optional.
        order    apply order, ascending. Ties are applied in table order, which is fine
                 because a tie means the two do not interact.
        cost     rough serialised bytes, used by the size guard to decide what to drop
                 first. Measured on a fully modified Sultan RS, rounded up.
]]
Schema.groups = {
    { key = 'identity',      gate = nil,             order = 10,  cost = 60 },
    { key = 'modkit',        gate = nil,             order = 20,  cost = 0 },
    { key = 'wheelType',     gate = 'modifications', order = 30,  cost = 10 },
    { key = 'modifications', gate = 'modifications', order = 40,  cost = 620 },
    { key = 'colours',       gate = 'colours',       order = 50,  cost = 70 },
    { key = 'customPaint',   gate = 'customPaint',   order = 60,  cost = 90 },
    { key = 'windowTint',    gate = 'windowTint',    order = 70,  cost = 20 },
    { key = 'xenon',         gate = 'xenon',         order = 80,  cost = 30 },
    { key = 'neons',         gate = 'neons',         order = 90,  cost = 80 },
    { key = 'tyreSmoke',     gate = 'tyreSmoke',     order = 100, cost = 40 },
    { key = 'livery',        gate = 'livery',        order = 110, cost = 30 },
    { key = 'extras',        gate = 'extras',        order = 120, cost = 90 },
    { key = 'plate',         gate = 'plate',         order = 130, cost = 40 },
    { key = 'lockState',     gate = 'lockState',     order = 140, cost = 20 },
    { key = 'roofState',     gate = 'roofState',     order = 150, cost = 20 },
    { key = 'engineState',   gate = 'engineState',   order = 160, cost = 20 },
    { key = 'fuel',          gate = 'fuel',          order = 170, cost = 20 },
    { key = 'oil',           gate = 'oil',           order = 180, cost = 20 },
    { key = 'dirt',          gate = 'dirt',          order = 190, cost = 20 },
    { key = 'health',        gate = 'health',        order = 200, cost = 60 },
    { key = 'doorsOpen',     gate = 'doorsOpen',     order = 210, cost = 40 },
    { key = 'damage',        gate = 'damage',        order = 220, cost = 140 },
    -- After `damage` and after `health`, both of which reset the bodywork when they are
    -- applied. Deforming a panel first and then setting body health smooths the dent back
    -- out, which looks exactly like the deformation never being restored at all.
    { key = 'deformation',   gate = 'deformation',   order = 225, cost = 220 },
    { key = 'statebags',     gate = 'statebags',     order = 230, cost = 200 },
}

--[[
    Which property keys belong to which group.

    This is the mapping the size guard and the config gate both use. A key not listed here is
    stored and restored unconditionally, which is correct for the few - `model` above all -
    that a vehicle cannot exist without.
]]
Schema.keys = {
    identity      = { 'model' },
    wheelType     = { 'wheels' },
    modifications = {
        'modSpoilers', 'modFrontBumper', 'modRearBumper', 'modSideSkirt', 'modExhaust',
        'modFrame', 'modGrille', 'modHood', 'modFender', 'modRightFender', 'modRoof',
        'modEngine', 'modBrakes', 'modTransmission', 'modHorns', 'modSuspension',
        'modArmor', 'modNitrous', 'modTurbo', 'modSubwoofer', 'modSmokeEnabled',
        'modHydraulics', 'modXenon', 'modFrontWheels', 'modBackWheels',
        'modCustomTiresF', 'modCustomTiresR', 'modPlateHolder', 'modVanityPlate',
        'modTrimA', 'modOrnaments', 'modDashboard', 'modDial', 'modDoorSpeaker',
        'modSeats', 'modSteeringWheel', 'modShifterLeavers', 'modAPlate', 'modSpeakers',
        'modTrunk', 'modHydrolic', 'modEngineBlock', 'modAirFilter', 'modStruts',
        'modArchCover', 'modAerials', 'modTrimB', 'modTank', 'modWindows', 'modDoorR',
        'modLivery', 'modRoofLivery', 'modLightbar',
        'wheelWidth', 'wheelSize', 'bulletProofTyres', 'driftTyres',
    },
    colours       = { 'color1', 'color2', 'pearlescentColor', 'wheelColor',
                      'interiorColor', 'dashboardColor' },
    -- `modColor1` and `modColor2` are the WHOLE answer from `GET_VEHICLE_MOD_COLOR_*`:
    -- { paintType, colour, pearlescent } and { paintType, colour }. `paintType1` and
    -- `paintType2` are what rows written before 1.0.9 have, and are still read.
    customPaint   = { 'modColor1', 'modColor2', 'paintType1', 'paintType2',
                      'customPrimary', 'customSecondary' },
    windowTint    = { 'windowTint' },
    xenon         = { 'xenonColor' },
    neons         = { 'neonEnabled', 'neonColor' },
    tyreSmoke     = { 'tyreSmokeColor' },
    livery        = { 'livery', 'roofLivery' },
    extras        = { 'extras' },
    plate         = { 'plate', 'plateIndex' },
    lockState     = { 'lockState' },
    roofState     = { 'roofState' },
    engineState   = { 'engineOn' },
    fuel          = { 'fuelLevel' },
    oil           = { 'oilLevel' },
    dirt          = { 'dirtLevel' },
    health        = { 'bodyHealth', 'engineHealth', 'tankHealth' },
    doorsOpen     = { 'doorsOpen' },
    damage        = { 'windows', 'doors', 'tyres' },
    deformation   = { 'deformation' },
    statebags     = { 'statebags' },
}

--[[
    Groups in the order the size guard drops them when a row exceeds
    `Config.Save.maximumRowBytes`.

    Statebags first because they are another resource's data and the least ours to keep.
    Modifications last of the droppable groups, because a car that comes back stock is the
    most visible possible failure and the one worth trying hardest to avoid.

    `identity`, `plate` and `health` are absent on purpose: a row without them is not a
    vehicle, and dropping them to fit would store a lie.
]]
Schema.dropOrder = { 'statebags', 'deformation', 'damage', 'doorsOpen', 'tyreSmoke', 'neons', 'extras', 'modifications' }

-- ---------------------------------------------------------------------------------------
-- Derived tables, built once
-- ---------------------------------------------------------------------------------------

local byKey            -- property key -> group key
local ordered          -- groups sorted by `order`
local gateOf           -- group key -> Config.Save.fields key

local function build()
    byKey = {}
    gateOf = {}
    ordered = {}

    for _, group in ipairs(Schema.groups) do
        ordered[#ordered + 1] = group
        gateOf[group.key] = group.gate

        for _, key in ipairs(Schema.keys[group.key] or {}) do
            byKey[key] = group.key
        end
    end

    table.sort(ordered, function(a, b) return a.order < b.order end)
end

local function derived()
    if not byKey then build() end
end

function Schema.groupOf(propertyKey)
    derived()
    return byKey[propertyKey]
end

function Schema.ordered()
    derived()
    return ordered
end

--[[
    Is a group switched on in the config?

    A group with no gate is always on. A gate naming a `Config.Save.fields` key that does not
    exist is treated as ON, not off: a typo in the config should not silently stop storing
    modifications, and the check script catches the typo separately.
]]
--[[
    `'auto'` means "on where something else is handling this properly".

    Only neons use it today. See the note on `Config.Save.fields.neons`: the state does not survive a
    vehicle being re-created, that is the game rather than this resource, and v-park attempting it
    anyway interfered with the mod shops that do it well. So it defers, and says so at boot.
]]
local function autoEnabled()
    local managers = (Config and Config.Save and Config.Save.neonManagers) or {}

    for _, resource in ipairs(managers) do
        if Park.started(resource) then return true, resource end
    end

    return false
end

Schema.autoEnabled = autoEnabled

function Schema.enabled(groupKey)
    derived()

    local gate = gateOf[groupKey]
    if not gate then return true end

    local fields = Config and Config.Save and Config.Save.fields
    if type(fields) ~= 'table' then return true end
    if fields[gate] == nil then return true end

    if fields[gate] == 'auto' then return (autoEnabled()) end

    return fields[gate] == true
end

--[[
    Strip every property belonging to a switched-off group.

    Runs on the SERVER, on the way in, not on the client. The client captures everything: it
    is cheaper to capture a value than to check a config for it, and doing the filtering
    server-side means changing `Config.Save.fields` takes effect on the next save rather than
    on the next client restart.
]]
function Schema.filter(properties)
    if type(properties) ~= 'table' then return properties end
    derived()

    for key in pairs(properties) do
        local group = byKey[key]
        if group and not Schema.enabled(group) then
            properties[key] = nil
        end
    end

    return properties
end

--[[
    Remove groups until the encoded size fits, in `dropOrder`.

    Returns the properties, the number of groups dropped and the list of their names, so the
    caller can log exactly what a vehicle lost rather than "it was too big".
]]
function Schema.fit(properties, maximumBytes)
    if type(properties) ~= 'table' then return properties, 0, {} end

    maximumBytes = tonumber(maximumBytes) or 0
    if maximumBytes <= 0 then return properties, 0, {} end

    if #Park.encode(properties) <= maximumBytes then
        return properties, 0, {}
    end

    derived()

    local dropped = {}

    for _, groupKey in ipairs(Schema.dropOrder) do
        local keys = Schema.keys[groupKey]
        if keys then
            local removedAny = false
            for _, key in ipairs(keys) do
                if properties[key] ~= nil then
                    properties[key] = nil
                    removedAny = true
                end
            end

            if removedAny then
                dropped[#dropped + 1] = groupKey
                if #Park.encode(properties) <= maximumBytes then
                    return properties, #dropped, dropped
                end
            end
        end
    end

    -- Everything droppable is gone and it still does not fit. The caller decides; there is
    -- nothing left here that can be removed without storing something untrue.
    return properties, #dropped, dropped
end
