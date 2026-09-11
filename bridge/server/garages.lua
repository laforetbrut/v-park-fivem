-- Author: vyrriox
-- Garage resource adapters. Read exports only; never execute another resource's config.

local function garageVector(value)
    local kind = type(value)
    if kind ~= 'table' and kind ~= 'vector3' and kind ~= 'vector4' then return nil end
    local x, y, z
    if kind == 'table' then
        x, y, z = tonumber(value.x or value[1]), tonumber(value.y or value[2]), tonumber(value.z or value[3])
    else
        x, y, z = value.x, value.y, value.z
    end
    if not x or not y or not z then return nil end
    if x ~= x or y ~= y or z ~= z or math.abs(x) == math.huge
        or math.abs(y) == math.huge or math.abs(z) == math.huge then return nil end
    return Park.vec(x, y, z)
end

function Bridge.garagePoint(garage)
    local coords = type(garage.coords) == 'table' and garage.coords or {}
    -- Quasar nests its spawn and menu positions. Prefer the bay, with the menu as fallback.
    return garageVector(coords.spawnCoords) or garageVector(garage.spawnPoint)
        or garageVector(garage.takeVehicle) or garageVector(coords.menuCoords)
        or garageVector(garage.coords) or garageVector(garage.location) or garageVector(garage.Location)
end

Bridge.garageReaders = {
    {
        resource = 'qs-advancedgarages',
        read = function()
            -- Quasar keeps its garages in a shared config table exposed through an export on
            -- recent builds. Older builds have no export at all, which is why the failure
            -- path here is a warning and not an error.
            local list = Park.try(function() return exports['qs-advancedgarages']:GetGarages() end)
            if type(list) ~= 'table' then return nil end

            local out = {}
            for key, garage in pairs(list) do
                if type(garage) == 'table' then
                    local point = Bridge.garagePoint(garage)
                    if point then
                        out[#out + 1] = {
                            id = tostring(garage.id or key), label = garage.label or key, point = point,
                        }
                    end
                end
            end
            return out
        end,
    },
    {
        resource = 'qb-garages',
        read = function()
            -- qb-garages publishes `Garages` as a shared global inside its own state, which
            -- is not reachable from here. Its config file is, and reading a Lua file we do
            -- not own is not something this resource does. So: the export if there is one.
            local list = Park.try(function() return exports['qb-garages']:GetGarages() end)
            if type(list) ~= 'table' then return nil end

            local out = {}
            for key, garage in pairs(list) do
                local point = Park.toVec(garage.takeVehicle or garage.putVehicle or garage.spawnPoint)
                if point then
                    out[#out + 1] = { id = tostring(key), label = garage.label or key, point = point }
                end
            end
            return out
        end,
    },
    {
        resource = 'jg-advancedgarages',
        read = function()
            local list = Park.try(function() return exports['jg-advancedgarages']:GetGarages() end)
            if type(list) ~= 'table' then return nil end

            local out = {}
            for key, garage in pairs(list) do
                local point = Park.toVec(garage.parkingSpots and garage.parkingSpots[1]
                    or garage.garageLocation or garage.coords)
                if point then
                    out[#out + 1] = { id = tostring(garage.id or key), label = garage.label or key, point = point }
                end
            end
            return out
        end,
    },
}

function Bridge.isGarageResource(resource)
    for _, reader in ipairs(Bridge.garageReaders) do
        if reader.resource == resource then return true end
    end
    return false
end
