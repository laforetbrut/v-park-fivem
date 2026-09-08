--[[
    server/actions.lua

    Everything that can be DONE to a persisted vehicle, in one place.

    -------------------------------------------------------------------------------------------
    WHY THIS IS NOT IN THE COMMANDS FILE OR IN THE PANEL
    -------------------------------------------------------------------------------------------

    Every operation has three callers: a chat command, the admin panel, and an export. If each
    implemented its own, the panel's delete and the command's delete would drift, and the one
    that drifted would be the one that forgot to write an audit row.

    So: one implementation each, here, and all three callers are thin. The permission check is
    inside the operation and not in the caller, for the same reason - a panel that hides a
    button is a convenience, and the security boundary has to be somewhere a hidden button
    cannot be un-hidden.

    -------------------------------------------------------------------------------------------
    THE SHAPE
    -------------------------------------------------------------------------------------------

    Every function takes `(src, ...)` and returns `ok, messageKeyOrDetail`. `src` is 0 for the
    console, which passes every permission check. The message key is a locale key so the caller
    decides how to present it - a chat line, a notification, or a panel toast.
]]

Actions = {}

-- ---------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------

local function requireAdmin(src)
    if Bridge.isAdmin(src) then return true end

    if Config.Permissions and Config.Permissions.logRefusals then
        Park.warn('%s (%s) was refused an admin action - check `add_ace group.admin %s allow`',
            GetPlayerName(src) or 'unknown', tostring(src),
            tostring(Config.Permissions and Config.Permissions.ace))
    end

    return false
end

Actions.requireAdmin = requireAdmin

--[[
    The record a reference points at, and whether `src` may act on it.

    One function because every operation needs both and doing them separately is how an
    operation ends up checking the permission of one vehicle and acting on another.
]]
local function target(src, reference, adminOnly)
    local record = Store.resolve(reference)
    if not record then return nil, 'error.unknown_vehicle' end

    if adminOnly then
        if not requireAdmin(src) then return nil, 'error.no_permission' end
        return record
    end

    local allowed = Ownership.mayAct(src, record)
    if not allowed then return nil, 'error.not_yours' end

    return record
end

Actions.target = target

--[[
    A vehicle that exists in the world right now, spawning it first if it does not.

    Several operations - repair, refuel, bring - need an entity, and a vehicle nobody is near
    does not have one. Rather than refusing, the vehicle is created on demand and the caller
    gets a handle.

    Returns entity, netId, or nil.
]]
local function ensureLive(record, timeoutMs)
    local entry = Store.live(record.id)
    if entry and entry.entity and DoesEntityExist(entry.entity) then
        return entry.entity, entry.netId
    end

    local entity = Spawn.create(record)
    if not entity then return nil end

    -- Give the elected client a moment to dress it. An operation applied in the same tick as
    -- creation is applied to a stock car that is about to be overwritten by the restore.
    local deadline = Park.ticks() + (timeoutMs or 3000)
    while Park.ticks() < deadline do
        local live = Store.live(record.id)
        if live and live.placedAt and live.placedAt > 0 and not Spawn.pending()[record.id] then
            break
        end
        Wait(100)
    end

    local live = Store.live(record.id)
    if live and live.entity and DoesEntityExist(live.entity) then
        return live.entity, live.netId
    end

    return nil
end

Actions.ensureLive = ensureLive

--[[
    Ask the client nearest a vehicle to do something to it that only a client can do.

    Repair, clean, refuel and the lock toggles are all client-side natives. The server picks
    who runs them, which is the same nomination the spawn path uses and for the same reason:
    only a machine with the map streamed in can act on the entity.
]]
local function askClient(record, netId, action, value)
    local entry = Store.live(record.id)
    local src = entry and entry.placer

    if not src or not GetPlayerName(src) then
        -- Whoever placed it has gone. The nearest online player will do.
        local best, bestDistance
        for _, player in ipairs(Spawn.onlinePlayers()) do
            local dx, dy = player.x - record.pos_x, player.y - record.pos_y
            local distance = dx * dx + dy * dy
            if not bestDistance or distance < bestDistance then
                best, bestDistance = player.src, distance
            end
        end
        src = best
    end

    if not src then return false end

    TriggerClientEvent('vpark:client:mutate', src, netId, action, value)
    return true
end

Actions.askClient = askClient

-- ---------------------------------------------------------------------------------------
-- Movement
-- ---------------------------------------------------------------------------------------

--[[
    Teleport the player TO a vehicle.

    Placed beside it rather than on it: dropping a player inside a car's collision box either
    ejects them or puts them in the driver's seat, and neither is what "take me to it" means.
    Two and a half metres to the left of the vehicle's own right vector is the passenger side,
    which is where you would walk up to it from.
]]
function Actions.teleportTo(src, reference)
    local record, err = target(src, reference, true)
    if not record then return false, err end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false, 'error.no_ped' end

    -- Route the player into the vehicle's bucket first, or they arrive at the right
    -- coordinates in the wrong instance and see nothing.
    if (record.bucket or 0) ~= (GetPlayerRoutingBucket(src) or 0) then
        SetPlayerRoutingBucket(src, record.bucket or 0)
    end

    local heading = math.rad(record.rot_z or 0.0)
    local offsetX = math.cos(heading) * 2.5
    local offsetY = math.sin(heading) * 2.5

    SetEntityCoords(ped, record.pos_x + offsetX, record.pos_y + offsetY, record.pos_z + 0.5,
        false, false, false, false)

    -- The vehicle is almost certainly not in the world yet: the player has just arrived from
    -- somewhere else and the streaming pass has not run. Creating it immediately means it is
    -- already there when their screen fades in.
    Database.thread(function()
        ensureLive(record, 5000)
    end)

    Database.audit('teleport_to', Bridge.characterId(src), Bridge.name(src), record.id, nil)
    Webhook.admin('teleport', src, record.plate or record.id, { model = record.model_name })

    return true, 'notify.teleported_to'
end

--[[
    Bring a vehicle TO the player.

    The vehicle is moved rather than re-created, when it exists, so that anybody sitting in it
    comes along and its damage does not go through a restore cycle.

    It is placed in front of the player, on their heading, which is the only placement that
    does not require the player to turn round to see the result.
]]
function Actions.bringHere(src, reference)
    local record, err = target(src, reference, true)
    if not record then return false, err end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false, 'error.no_ped' end

    local position = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)

    local radians = math.rad(heading)
    local x = position.x + math.sin(-radians) * -4.5
    local y = position.y + math.cos(-radians) * 4.5
    local z = position.z

    local bucket = GetPlayerRoutingBucket(src) or 0

    Store.update(record.id, {
        pos_x = Park.coord(x),
        pos_y = Park.coord(y),
        pos_z = Park.coord(z),
        rot_x = 0.0,
        rot_y = 0.0,
        rot_z = Park.angle(heading),
        bucket = bucket,
        interior = 0,
        room = 0,
        touched_at = Park.now(),
    })

    local entry = Store.live(record.id)

    if entry and entry.entity and DoesEntityExist(entry.entity) then
        SetEntityRoutingBucket(entry.entity, bucket)
        SetEntityCoords(entry.entity, x, y, z, false, false, false, false)
        SetEntityRotation(entry.entity, 0.0, 0.0, heading, 2, true)

        -- Tell the requesting client to run the placement sequence on it where it now is, so
        -- the same collision gate and settle logic applies as on a fresh restore. Without it,
        -- a vehicle brought into a tight space is dropped rather than placed.
        TriggerClientEvent('vpark:client:restore', src, entry.netId, {
            id = record.id,
            version = record.updated_at,
            position = { x = x, y = y, z = z },
            rotation = { x = 0.0, y = 0.0, z = heading },
            class = record.class,
            interior = 0,
            room = 0,
            frozen = false,
        })
    else
        Database.thread(function()
            ensureLive(record, 5000)
        end)
    end

    Database.audit('bring', Bridge.characterId(src), Bridge.name(src), record.id, nil)
    Webhook.admin('bring', src, record.plate or record.id, { model = record.model_name })

    return true, 'notify.brought_here'
end

-- ---------------------------------------------------------------------------------------
-- Condition
-- ---------------------------------------------------------------------------------------

function Actions.repair(src, reference)
    local record, err = target(src, reference, true)
    if not record then return false, err end

    local entity, netId = ensureLive(record)
    if not entity then return false, 'error.not_in_world' end

    askClient(record, netId, 'repair')

    -- The stored properties are corrected too, so that a repair survives a restart even if
    -- nobody is near the vehicle when the next sweep runs.
    local properties = record.properties or {}
    properties.bodyHealth = 1000.0
    properties.engineHealth = 1000.0
    properties.tankHealth = 1000.0
    properties.dirtLevel = 0.0
    properties.windows = {}
    properties.doors = {}
    properties.tyres = {}
    properties.deformation = nil

    Store.update(record.id, {
        properties = properties,
        body_health = 1000.0,
        engine_health = 1000.0,
        wrecked = false,
        touched_at = Park.now(),
    })

    -- Clear the replicated deformation so every client drops the dents rather than keeping
    -- them until the entity is re-created.
    if entity and DoesEntityExist(entity) then
        Entity(entity).state:set('vpark:deform', nil, true)
    end

    Database.audit('repair', Bridge.characterId(src), Bridge.name(src), record.id, nil)
    Webhook.admin('repair', src, record.plate or record.id, { model = record.model_name })

    return true, 'notify.repaired'
end

function Actions.clean(src, reference)
    local record, err = target(src, reference, true)
    if not record then return false, err end

    local entity, netId = ensureLive(record)
    if not entity then return false, 'error.not_in_world' end

    askClient(record, netId, 'clean')

    local properties = record.properties or {}
    properties.dirtLevel = 0.0
    Store.update(record.id, { properties = properties, touched_at = Park.now() })

    return true, 'notify.cleaned'
end

function Actions.refuel(src, reference, level)
    local record, err = target(src, reference, true)
    if not record then return false, err end

    level = Park.clamp(tonumber(level) or 100.0, 0.0, 100.0)

    local entity, netId = ensureLive(record)
    if entity then
        askClient(record, netId, 'refuel', level)

        -- The replicated statebag too: several fuel resources read it rather than the native,
        -- and a client-side write would not reach them.
        local key = (Config.Compat and Config.Compat.fuelStatebag) or 'fuel'
        Entity(entity).state:set(key, level, true)
    end

    local properties = record.properties or {}
    properties.fuelLevel = level
    Store.update(record.id, { properties = properties, fuel = level, touched_at = Park.now() })

    Webhook.admin('refuel', src, record.plate or record.id, { level = level })

    return true, 'notify.refuelled'
end

function Actions.setLock(src, reference, locked)
    local record, err = target(src, reference, false)
    if not record then return false, err end

    local entity, netId = ensureLive(record)
    if entity then
        askClient(record, netId, locked and 'lock' or 'unlock', nil)
    end

    local properties = record.properties or {}
    properties.lockState = locked and 2 or 1
    Store.update(record.id, { properties = properties, touched_at = Park.now() })

    return true, locked and 'notify.locked' or 'notify.unlocked'
end

-- ---------------------------------------------------------------------------------------
-- Ownership and labels
-- ---------------------------------------------------------------------------------------

function Actions.setOwner(src, reference, targetSrc)
    local record, err = target(src, reference, true)
    if not record then return false, err end

    targetSrc = tonumber(targetSrc)
    if not targetSrc or not GetPlayerName(targetSrc) then return false, 'error.no_such_player' end

    local characterId = Bridge.characterId(targetSrc)
    if not characterId then return false, 'error.character_not_loaded' end

    Ownership.transfer(record.id, characterId, 'owned', Bridge.name(targetSrc))

    Database.audit('set_owner', Bridge.characterId(src), Bridge.name(src), record.id,
        { to = characterId })
    Webhook.admin('owner', src, record.plate or record.id, {
        to = Bridge.name(targetSrc),
        model = record.model_name,
    })

    Bridge.notify(targetSrc, 'adminAction',
        L('notify.given_vehicle', record.model_name or L('vehicle.unknown')), 'success')

    return true, 'notify.owner_set'
end

--[[
    Give a vehicle a name.

    Stored as a statebag rather than a column, so that anything reading the entity - a HUD, a
    target label - can see it without knowing about our schema.
]]
function Actions.rename(src, reference, label)
    local record, err = target(src, reference, false)
    if not record then return false, err end

    label = Park.trim(tostring(label or ''))
    if #label > 32 then label = label:sub(1, 32) end

    local statebags = record.statebags or {}

    if label == '' then
        statebags['vpark:label'] = nil
    else
        statebags['vpark:label'] = label
    end

    Store.update(record.id, { statebags = statebags, touched_at = Park.now() })

    local entry = Store.live(record.id)
    if entry and entry.entity and DoesEntityExist(entry.entity) then
        Entity(entry.entity).state:set('vpark:label', label ~= '' and label or nil, true)
    end

    return true, 'notify.renamed'
end

-- ---------------------------------------------------------------------------------------
-- Removal
-- ---------------------------------------------------------------------------------------

function Actions.delete(src, reference)
    local record, err = target(src, reference, true)
    if not record then return false, err end

    local plate = record.plate
    local model = record.model_name

    local ok = Lifecycle.remove(record.id, 'delete', Bridge.characterId(src) or 'console', 'admin')
    if not ok then return false, 'error.unknown_vehicle' end

    Database.audit('delete', Bridge.characterId(src), Bridge.name(src), record.id, { plate = plate })
    Webhook.admin('delete', src, plate or record.id, { model = model })

    return true, 'notify.deleted'
end

function Actions.impound(src, reference)
    local record, err = target(src, reference, true)
    if not record then return false, err end

    local ok, outcome = Lifecycle.remove(record.id, 'impound',
        Bridge.characterId(src) or 'console', 'admin_impound')

    if not ok then return false, 'error.unknown_vehicle' end

    Webhook.admin('impound', src, record.plate or record.id, { outcome = outcome })

    return true, outcome == 'impounded' and 'notify.impounded_ok' or 'notify.returned_ok'
end

--[[
    Send a vehicle to a named garage.

    This is the operation with the most ways to be subtly wrong, so it is explicit about all
    of them:

      - The vehicle must be OWNED by somebody. A garage is a place on an account; an unowned
        car has no account to put it in, and silently deleting one because an admin picked
        "send to garage" would be a surprise. It refuses instead.

      - The garage id is passed to the framework verbatim. We do not validate it against the
        garage resource's list, because that list is read through an export that not every
        build has, and refusing a valid garage because we could not read the list would be
        worse than accepting an invalid one - which the garage resource itself will report.

      - The vehicle is removed from the world and from persistence in the same operation. A
        car that is in a garage AND in the street is the duplication bug this whole area of
        the resource exists to prevent.
]]
function Actions.toGarage(src, reference, garageId)
    local record, err = target(src, reference, true)
    if not record then return false, err end

    if record.owner_type ~= 'owned' or not record.plate then
        return false, 'error.not_owned_no_garage'
    end

    local schema = Bridge.ownedTable()
    if not schema or not schema.storedColumn then
        return false, 'error.no_garage_support'
    end

    garageId = Park.trim(tostring(garageId or ''))

    -- Write the garage name where the framework keeps it, then mark it stored. Two columns on
    -- qb-core and ESX, one on ox_core where the column IS the garage name.
    if garageId ~= '' and schema.garageColumn then
        Database.execute(
            ('UPDATE `%s` SET `%s` = ? WHERE `%s` = ?')
                :format(schema.table, schema.garageColumn, schema.plate),
            { garageId, record.plate }
        )
    end

    if not Bridge.returnToGarage(record.plate, garageId ~= '' and garageId or nil) then
        return false, 'error.garage_failed'
    end

    Spawn.despawn(record.id, 'sent to garage')
    Store.remove(record.id)

    if Database.available() then
        Database.execute(('DELETE FROM %s WHERE `id` = ?'):format(Database.table('vehicles')),
            { record.id })
    end

    Database.audit('to_garage', Bridge.characterId(src), Bridge.name(src), record.id,
        { garage = garageId, plate = record.plate })
    Webhook.admin('toGarage', src, record.plate, { garage = garageId, model = record.model_name })

    if record.owner then
        local ownerSrc = Ownership.sourceOf(record.owner)
        if ownerSrc then
            Bridge.notify(ownerSrc, 'adminAction',
                L('notify.sent_to_garage', record.model_name or L('vehicle.unknown'),
                    garageId ~= '' and garageId or L('garage.default')), 'info')
        end
    end

    return true, 'notify.sent_to_garage_ok'
end

function Actions.restore(src, reference)
    if not requireAdmin(src) then return false, 'error.no_permission' end

    local ok, reason = Lifecycle.restore(reference, Bridge.characterId(src) or 'console')
    if not ok then return false, 'error.' .. tostring(reason) end

    Webhook.admin('restore', src, reference, nil)

    return true, 'notify.restored'
end

-- ---------------------------------------------------------------------------------------
-- Parking and forgetting, for players
-- ---------------------------------------------------------------------------------------

--[[
    `/vpark`: persist the vehicle the player is sitting in, or looking at.

    Goes through the same adoption path as an automatic one, with an explicit ownership kind
    of 'claimed', so a claimed vehicle gets the claimed expiry rather than the abandoned one.
]]
function Actions.park(src, payload)
    if not Runtime.ready() then return false, 'error.not_ready' end

    local record, reason, detail = Persist.adopt(src, payload, 'claimed')

    if not record then
        return false, reason or 'refuse.unknown', detail
    end

    Webhook.activity('parked', 'Vehicle parked', nil, {
        { name = 'Plate', value = tostring(record.plate or '-'), inline = true },
        { name = 'Model', value = tostring(record.model_name or '-'), inline = true },
        { name = 'By', value = Bridge.name(src), inline = true },
    })

    return true, 'notify.parked', record
end

--[[
    `/vparkforget`: stop persisting a vehicle.

    Does NOT delete the entity. The car is still there and still drivable; it simply will not
    come back after a restart. That distinction matters and the notification says so.
]]
function Actions.forget(src, reference)
    local record, err = target(src, reference, false)
    if not record then return false, err end

    Store.remove(record.id)

    if Database.available() then
        Database.thread(function()
            Database.execute(('DELETE FROM %s WHERE `id` = ?'):format(Database.table('vehicles')),
                { record.id })
        end)
    end

    local entry = Store.live(record.id)
    if entry and entry.entity and DoesEntityExist(entry.entity) then
        Entity(entry.entity).state:set('vpark:id', nil, true)
    end

    Store.setLive(record.id, nil)

    Database.audit('forget', Bridge.characterId(src), Bridge.name(src), record.id, nil)

    return true, 'notify.forgotten'
end
