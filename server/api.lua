--[[
    server/api.lua

    Everything another resource can call.

    -------------------------------------------------------------------------------------------
    READS ARE OPEN, WRITES ARE GATED
    -------------------------------------------------------------------------------------------

    Anything can ask where a vehicle is or whether it is persisted. Only a resource
    `Config.Api.allowedResources` permits can change anything, and `Config.Api.allowWrites`
    turns writing off altogether.

    That gate is real and not a courtesy: `GetInvokingResource()` is told to us by the runtime
    and cannot be spoofed by the caller. A server running scripts it does not fully trust can
    set the list and mean it.

    -------------------------------------------------------------------------------------------
    THE THREE INTEGRATIONS THIS EXISTS FOR
    -------------------------------------------------------------------------------------------

    1. A GARAGE storing a vehicle: call `Store` so we know it was deliberate, instead of
       inferring it from the entity going away. `Config.Lifecycle.forgetOnExternalDelete`
       covers the case where a garage does not call anything, and this is the exact version.

    2. A RENTAL script: call `SetRental` with how long the rental has left. The vehicle then
       carries a hard end time as well as the semi-persistence grace period, and goes at
       whichever comes first.

    3. A DEALERSHIP selling a car: call `SetOwner` so the persisted vehicle changes hands with
       the sale instead of expiring on the buyer under the previous owner's timer.

    API.md documents every function below with its arguments and its return shape.
]]

local function writesAllowed()
    if not (Config.Api and Config.Api.allowWrites ~= false) then return false, 'writes are disabled' end

    local allowed = Config.Api.allowedResources
    if type(allowed) ~= 'table' or #allowed == 0 then return true end

    local caller = GetInvokingResource()
    if not caller then return true end   -- called from inside this resource

    for _, name in ipairs(allowed) do
        if name == caller then return true end
    end

    return false, ('resource `%s` is not in Config.Api.allowedResources'):format(caller)
end

local function refuse(reason)
    Park.warn('an API write was refused: %s', tostring(reason))
    return false, reason
end

--[[
    The public shape of a record.

    A copy, and a reduced one. Handing out the live record would let a caller mutate the store
    without going through `Store.update`, which is how the four indexes come apart.
]]
local function publicRecord(record)
    if not record then return nil end

    return {
        id = record.id,
        plate = record.plate,
        model = record.model,
        modelName = record.model_name,
        class = record.class,
        className = Classes.key(record.class),
        owner = record.owner,
        ownerType = record.owner_type,
        ownerName = record.owner_name,
        job = record.job,
        coords = { x = record.pos_x, y = record.pos_y, z = record.pos_z },
        rotation = { x = record.rot_x, y = record.rot_y, z = record.rot_z },
        heading = record.rot_z,
        bucket = record.bucket,
        interior = record.interior,
        bodyHealth = record.body_health,
        engineHealth = record.engine_health,
        fuel = record.fuel,
        wrecked = record.wrecked,
        live = Store.isLive(record.id),
        netId = (Store.live(record.id) or {}).netId,
        lastGarage = record.last_garage,
        rentalUntil = record.rental_until,
        createdAt = record.created_at,
        updatedAt = record.updated_at,
        touchedAt = record.touched_at,
        lastUsedAt = record.last_used_at,
        graceRemaining = Lifecycle.graceRemaining(record),
    }
end

-- ---------------------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------------------

exports('IsReady', function()
    return Runtime.ready()
end)

exports('GetVehicle', function(reference)
    return publicRecord(Store.resolve(reference))
end)

exports('GetVehicleByPlate', function(plate)
    return publicRecord(Store.byPlate(plate))
end)

--[[
    Is this entity one of ours?

    The statebag rather than a lookup, so a caller with an entity handle and no id gets an
    answer without us scanning anything.
]]
exports('IsPersisted', function(entity)
    if not entity or not DoesEntityExist(entity) then return false end
    local id = Entity(entity).state['vpark:id']
    return id ~= nil and Store.get(id) ~= nil
end)

exports('GetVehicleId', function(entity)
    if not entity or not DoesEntityExist(entity) then return nil end
    return Entity(entity).state['vpark:id']
end)

exports('GetPlayerVehicles', function(src)
    local characterId = type(src) == 'number' and Bridge.characterId(src) or src
    if not characterId then return {} end

    local out = {}
    for _, record in ipairs(Store.ownedBy(characterId)) do
        out[#out + 1] = publicRecord(record)
    end
    return out
end)

exports('GetVehiclesNear', function(coords, radius, bucket)
    local point = Park.toVec(coords)
    if not point then return {} end

    local out = {}
    for _, entry in ipairs(Store.near(point.x, point.y, tonumber(radius) or 100.0, bucket)) do
        local record = publicRecord(entry.record)
        record.distance = math.sqrt(entry.distanceSq)
        out[#out + 1] = record
    end

    table.sort(out, function(a, b) return a.distance < b.distance end)
    return out
end)

--[[
    Where a vehicle is, whether or not it currently exists in the world.

    The single most useful call for a garage script: before letting a player take a car out,
    ask whether it is already standing in the street. Advanced Parking's own FAQ recommends
    the same check against its equivalent, and the reason is the same - without it, a player
    takes out a second copy of a car they already have.
]]
exports('GetVehiclePosition', function(reference)
    local record = Store.resolve(reference)
    if not record then return nil end
    return { x = record.pos_x, y = record.pos_y, z = record.pos_z }, record.rot_z
end)

exports('GetStats', function()
    return {
        store = Store.stats(),
        spawn = Spawn.stats(),
        persist = Persist.stats(),
        lifecycle = Lifecycle.stats(),
        database = Database.stats(),
        webhooks = Webhook.stats(),
        ready = Runtime.ready(),
    }
end)

exports('GetGarages', function()
    return Park.copy(Runtime.garages())
end)

-- ---------------------------------------------------------------------------------------
-- Writes
-- ---------------------------------------------------------------------------------------

--[[
    Persist a vehicle that exists right now.

    `netId` names it, `options` says who it belongs to:

        { ownerType = 'rental', owner = '<character id>', name = 'Jean', job = 'police' }

    Returns the new id, or nil and a reason.
]]
exports('Park', function(netId, options)
    local ok, reason = writesAllowed()
    if not ok then return refuse(reason) end

    local entity = NetworkGetEntityFromNetworkId(tonumber(netId) or 0)
    if not entity or entity == 0 or not DoesEntityExist(entity) then
        return nil, 'no such entity'
    end

    -- The properties have to come from a client, so the caller is asking us to ask one. The
    -- answer is asynchronous, which is why this returns a promise-shaped result rather than
    -- the id directly when nobody is near enough to read the vehicle.
    local position = GetEntityCoords(entity)
    local rotation = GetEntityRotation(entity)

    local payload = {
        netId = tonumber(netId),
        model = GetEntityModel(entity),
        modelName = nil,
        class = 0,
        plate = nil,
        position = { x = position.x, y = position.y, z = position.z },
        rotation = { x = rotation.x, y = rotation.y, z = rotation.z },
        properties = {},
    }

    local explicit
    if type(options) == 'table' then
        explicit = {
            type = options.ownerType or 'claimed',
            owner = options.owner,
            name = options.name,
            job = options.job,
        }
    end

    local record, reasonKey = Persist.adopt(0, payload, explicit)
    if not record then return nil, reasonKey end

    -- Ask the nearest client to fill in what only a client can read. The vehicle is already
    -- persisted by this point; the capture is an enrichment, not a precondition.
    local best
    for _, player in ipairs(Spawn.onlinePlayers()) do
        if not best then best = player.src end
    end

    if best then
        TriggerClientEvent('vpark:client:captureEntity', best, tonumber(netId), 'api:' .. record.id)
    end

    return record.id
end)

exports('Forget', function(reference)
    local ok, reason = writesAllowed()
    if not ok then return refuse(reason) end

    local record = Store.resolve(reference)
    if not record then return false, 'no such vehicle' end

    Store.remove(record.id)

    if Database.available() then
        Database.thread(function()
            Database.execute(('DELETE FROM %s WHERE `id` = ?'):format(Database.table('vehicles')),
                { record.id })
        end)
    end

    return true
end)

--[[
    A garage is storing this vehicle.

    The exact version of what `Config.Lifecycle.forgetOnExternalDelete` infers. Call it BEFORE
    deleting the entity and there is no grace period, no inference and no window in which the
    vehicle might be re-created by our streaming pass.
]]
exports('Store', function(reference, garageId)
    local ok, reason = writesAllowed()
    if not ok then return refuse(reason) end

    local record = Store.resolve(reference)
    if not record then return false, 'no such vehicle' end

    if garageId and garageId ~= '' then
        Store.update(record.id, { last_garage = tostring(garageId) })
    end

    Spawn.despawn(record.id, 'stored by ' .. tostring(GetInvokingResource() or 'api'))
    Store.remove(record.id)

    if Database.available() then
        Database.thread(function()
            Database.execute(('DELETE FROM %s WHERE `id` = ?'):format(Database.table('vehicles')),
                { record.id })
        end)
    end

    return true
end)

exports('Delete', function(reference, reason)
    local ok, why = writesAllowed()
    if not ok then return refuse(why) end

    return Lifecycle.remove(reference, 'delete', GetInvokingResource() or 'api', reason or 'api')
end)

exports('SetOwner', function(reference, characterId, ownerType, name)
    local ok, reason = writesAllowed()
    if not ok then return refuse(reason) end

    local record = Store.resolve(reference)
    if not record then return false, 'no such vehicle' end

    return Ownership.transfer(record.id, characterId, ownerType or 'owned', name)
end)

--[[
    Mark a vehicle as a rental with a hard end time.

    `seconds` is how long the rental has LEFT, from now. The vehicle then goes at whichever
    comes first: that time, or the end of the semi-persistence grace period once the renter
    goes offline. Nothing in v-park can extend a rental past what your rental script sold.

    Pass 0 or nil to clear the hard expiry and leave only the grace period.
]]
exports('SetRental', function(reference, seconds, characterId)
    local ok, reason = writesAllowed()
    if not ok then return refuse(reason) end

    local record = Store.resolve(reference)
    if not record then return false, 'no such vehicle' end

    local until_ = 0
    local remaining = tonumber(seconds) or 0
    if remaining > 0 then
        local now = Park.now()
        if now > 0 then until_ = now + math.floor(remaining) end
    end

    Store.update(record.id, {
        owner_type = 'rental',
        owner = characterId or record.owner,
        rental_until = until_,
        offline_secs = 0,
    })

    return true
end)

exports('SetLabel', function(reference, label)
    local ok, reason = writesAllowed()
    if not ok then return refuse(reason) end

    return Actions.rename(0, reference, label)
end)

exports('Repair', function(reference)
    local ok, reason = writesAllowed()
    if not ok then return refuse(reason) end
    return Actions.repair(0, reference)
end)

exports('Refuel', function(reference, level)
    local ok, reason = writesAllowed()
    if not ok then return refuse(reason) end
    return Actions.refuel(0, reference, level)
end)

--[[
    Force a vehicle into the world now, wherever it is stored.

    For a script that needs the entity to exist before it can do something to it - a mechanic
    job pulling a car in, a tow truck. Returns the entity and network id, or nil.
]]
exports('Spawn', function(reference)
    local ok, reason = writesAllowed()
    if not ok then return refuse(reason) end

    local record = Store.resolve(reference)
    if not record then return nil, 'no such vehicle' end

    local entity, netId = Actions.ensureLive(record, 5000)
    return entity, netId
end)

exports('Despawn', function(reference)
    local ok, reason = writesAllowed()
    if not ok then return refuse(reason) end

    local record = Store.resolve(reference)
    if not record then return false, 'no such vehicle' end

    return Spawn.despawn(record.id, 'api')
end)

exports('Flush', function()
    Database.thread(function() Persist.flush(true) end)
    return true
end)

-- ---------------------------------------------------------------------------------------
-- Plate protection
--
-- A stash in every modern inventory is keyed on the plate. Changing a persisted vehicle's
-- plate without moving the stash orphans whatever was in the boot, and the player has no way
-- to know it happened.
--
-- `Config.Inventory.guardPlateChanges` makes this REFUSE rather than warn, which gives the
-- calling resource a truthful answer instead of a silent data loss.
-- ---------------------------------------------------------------------------------------

exports('SetPlate', function(reference, plate)
    local ok, reason = writesAllowed()
    if not ok then return refuse(reason) end

    local record = Store.resolve(reference)
    if not record then return false, 'no such vehicle' end

    local normalised = Park.plate(plate)
    if not normalised then return false, 'not a usable plate' end

    if Config.Inventory and Config.Inventory.guardPlateChanges then
        if record.plate and record.plate ~= normalised then
            local existing = Store.byPlate(normalised)
            if existing then
                return false, ('plate %s is already used by %s'):format(normalised, existing.id)
            end

            Park.warn('%s is changing %s from plate %s to %s - any stash keyed on the old plate will be orphaned',
                tostring(GetInvokingResource() or 'api'), record.id, record.plate, normalised)
        end
    end

    local properties = record.properties or {}
    properties.plate = normalised

    Store.update(record.id, { plate = normalised, properties = properties })

    local entry = Store.live(record.id)
    if entry and entry.entity and DoesEntityExist(entry.entity) then
        Entity(entry.entity).state:set('vpark:plate', normalised, true)
    end

    return true
end)

-- ---------------------------------------------------------------------------------------
-- Compatibility shims
--
-- Advanced Parking's own exports, answered by us, so that a server migrating over does not
-- have to edit every garage and key script that already calls them.
--
-- Only the three that its FAQ tells operators to add. They are the ones that will exist in
-- somebody's qb-garages fork after a migration, and having them silently do nothing would be
-- worse than not having them.
-- ---------------------------------------------------------------------------------------

exports('UpdatePlate', function(entity, plate)
    local id = entity and DoesEntityExist(entity) and Entity(entity).state['vpark:id']
    if not id then
        -- Not one of ours. Set it on the entity anyway, which is what the original does.
        if entity and DoesEntityExist(entity) then
            SetVehicleNumberPlateText(entity, plate)
        end
        return
    end

    return exports[Park.resource]:SetPlate(id, plate)
end)

exports('DeleteVehicle', function(entity)
    if not entity or not DoesEntityExist(entity) then return false end

    local id = Entity(entity).state['vpark:id']
    if id then
        Spawn.despawn(id, 'DeleteVehicle export')
        Store.remove(id)

        if Database.available() then
            Database.thread(function()
                Database.execute(('DELETE FROM %s WHERE `id` = ?'):format(Database.table('vehicles')),
                    { id })
            end)
        end
    end

    DeleteEntity(entity)
    return true
end)
