--[[
    shared/classes.lua

    The vehicle class table, and the small amount of reasoning this resource does about what
    kind of thing a vehicle is.

    Shared because the server decides expiry and streaming radius by class from a stored
    number, and the client decides probe geometry by class from the live entity. Both must
    agree on what class 15 means, and there is exactly one place that says so.

    The class ids are the game's own (`GET_VEHICLE_CLASS`), not ours. They are stable across
    every game build and are the only vehicle taxonomy that is.
]]

Classes = {}

--[[
    ============================================================================================
    THE OTHER TAXONOMY: THE SERVER SETTER TYPE
    ============================================================================================

    `CREATE_VEHICLE_SERVER_SETTER` takes a TYPE STRING, and it is not the class. It is one of

        automobile  bike  boat  heli  plane  submarine  trailer  train
        quadbike  blimp  submarinecar  amphibious_automobile  amphibious_quadbike  heli_blade

    and the resource needs it because that native is the only reliable way to create a vehicle
    from the server. See the note in server/spawn.lua.

    -------------------------------------------------------------------------------------------
    THIS MAP IS THE FALLBACK, NOT THE ANSWER
    -------------------------------------------------------------------------------------------

    The real answer comes from `GetVehicleType` on a client, which reads it off the model, and
    is stored per vehicle. This map exists for the two cases where that answer is not available:
    a row written by a version before 1.0.4, and a row imported by the Advanced Parking
    migration, which has a class and no type.

    It is a guess, and for a small number of models it is a wrong one - an amphibious Stromberg
    is class 6 and type `amphibious_automobile`, the Toreador likewise, and several class 14
    entries are `submarine` rather than `boat`. Those spawn as automobiles and misbehave until
    somebody drives one, at which point the real type is captured and stored and it is right
    from then on.

    Erring towards `automobile` is deliberate: it is the type that works for the overwhelming
    majority of models, and a wrong guess costs one restore rather than a missing vehicle.
]]
Classes.setterTypes = {
    [8]  = 'bike',      -- motorcycles
    [13] = 'bike',      -- bicycles: the game models them as bikes, not as their own type
    [14] = 'boat',
    [15] = 'heli',
    [16] = 'plane',
    [21] = 'train',
}

--[[
    Every type the native will accept. Anything else is refused rather than passed through,
    because a bad type string is a vehicle that never appears and no error that says why.
]]
Classes.validSetterTypes = {
    automobile = true, bike = true, boat = true, heli = true, plane = true,
    submarine = true, trailer = true, train = true, quadbike = true, blimp = true,
    submarinecar = true, amphibious_automobile = true, amphibious_quadbike = true,
    heli_blade = true,
}

--[[
    The type string to create this vehicle with.

    `stored` is what a client captured, and it wins whenever it is one the native accepts.
]]
function Classes.setterType(class, stored)
    if type(stored) == 'string' and Classes.validSetterTypes[stored] then
        return stored
    end

    return Classes.setterTypes[tonumber(class) or -1] or 'automobile'
end

--[[
    id -> a short lowercase key, and a locale key for display.

    The key is what appears in a config, in a command argument and in the audit log. The
    label goes through `L()` so it can be translated; the key never is, because an operator
    typing `/vparkscan class:emergency` should not have to type it in French.
]]
Classes.list = {
    [0]  = { key = 'compact',      label = 'class.compact' },
    [1]  = { key = 'sedan',        label = 'class.sedan' },
    [2]  = { key = 'suv',          label = 'class.suv' },
    [3]  = { key = 'coupe',        label = 'class.coupe' },
    [4]  = { key = 'muscle',       label = 'class.muscle' },
    [5]  = { key = 'classic',      label = 'class.classic' },
    [6]  = { key = 'sports',       label = 'class.sports' },
    [7]  = { key = 'super',        label = 'class.super' },
    [8]  = { key = 'motorcycle',   label = 'class.motorcycle' },
    [9]  = { key = 'offroad',      label = 'class.offroad' },
    [10] = { key = 'industrial',   label = 'class.industrial' },
    [11] = { key = 'utility',      label = 'class.utility' },
    [12] = { key = 'van',          label = 'class.van' },
    [13] = { key = 'cycle',        label = 'class.cycle' },
    [14] = { key = 'boat',         label = 'class.boat' },
    [15] = { key = 'helicopter',   label = 'class.helicopter' },
    [16] = { key = 'plane',        label = 'class.plane' },
    [17] = { key = 'service',      label = 'class.service' },
    [18] = { key = 'emergency',    label = 'class.emergency' },
    [19] = { key = 'military',     label = 'class.military' },
    [20] = { key = 'commercial',   label = 'class.commercial' },
    [21] = { key = 'train',        label = 'class.train' },
    [22] = { key = 'openwheel',    label = 'class.openwheel' },
}

--[[
    Classes that are not driven on the ground.

    They matter in exactly two places: the ground check in the placement engine must not fire
    for them (a helicopter on a rooftop helipad is 60 metres above the ground and correct),
    and the trailer logic must never consider them.
]]
Classes.airborne = { [15] = true, [16] = true }
Classes.aquatic = { [14] = true }

--[[
    Classes with no meaningful modification set worth storing.

    A bicycle has no engine, no fuel and no mod slots. Storing an empty modifications blob for
    one is 400 wasted bytes per row, and there are a lot of bicycles.
]]
Classes.simple = { [13] = true }

function Classes.key(class)
    local entry = Classes.list[class]
    return entry and entry.key or ('class' .. tostring(class))
end

function Classes.label(class)
    local entry = Classes.list[class]
    if not entry then return Classes.key(class) end
    return L(entry.label)
end

--[[
    Resolve a class from either its id or its key, so a config and a command argument can
    both accept `emergency` or `18`.

    Returns nil for anything unrecognised, and the caller decides whether that is an error.
    It usually is: a config naming a class that does not exist is a typo, and silently
    matching nothing is how a blacklist appears to be ignored.
]]
function Classes.resolve(value)
    if type(value) == 'number' then
        return Classes.list[value] and value or nil
    end

    if type(value) ~= 'string' then return nil end

    local asNumber = tonumber(value)
    if asNumber then
        return Classes.list[asNumber] and asNumber or nil
    end

    local wanted = value:lower()
    for id, entry in pairs(Classes.list) do
        if entry.key == wanted then return id end
    end

    return nil
end

--[[
    Turn a config list of classes into a set, accepting ids and keys in the same list.

    An unresolvable entry is warned about once, at boot, naming the value. A blacklist that
    silently does nothing is the worst failure mode a blacklist has.
]]
function Classes.setFrom(list, context)
    local out = {}
    if type(list) ~= 'table' then return out end

    for _, value in ipairs(list) do
        local class = Classes.resolve(value)
        if class then
            out[class] = true
        else
            Park.warn("%s lists '%s', which is not a vehicle class - it will match nothing",
                context or 'a config list', tostring(value))
        end
    end

    return out
end
