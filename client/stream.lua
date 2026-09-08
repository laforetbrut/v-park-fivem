--[[
    client/stream.lua

    What the client does with a vehicle the server has just created for it, and the single
    timer that wakes and re-freezes them.

    -------------------------------------------------------------------------------------------
    WHO DOES THE WORK, AND WHY IT IS ONE CLIENT AND NOT ALL OF THEM
    -------------------------------------------------------------------------------------------

    Modifications, colours, damage and position are part of a vehicle's network sync tree: the
    entity's OWNER writes them and every other client receives them. So exactly one client
    should apply them, and the rest should do nothing.

    Deformation is the exception. It is not reliably synced - which is the whole reason
    `client/deformation.lua` exists - so every client applies that locally, from a statebag.

    Electing the one client is done on the SERVER, by naming it. The server knows who is
    nearest, it sends the restore instruction to that player alone, and it re-elects if no
    answer comes back. The alternative - every client racing to take control and whoever wins
    does the work - produces two clients placing one entity, which fight, and a vehicle that
    visibly jitters between two poses.

    -------------------------------------------------------------------------------------------
    THE COST WHEN NOTHING IS HAPPENING
    -------------------------------------------------------------------------------------------

    One timer. Its interval comes from `Config.Performance.clientTiers` and is chosen by how
    far the nearest tracked vehicle is, so a player in an empty field wakes every two seconds
    and a player in a full car park wakes five times a second. There is no `Wait(0)` anywhere
    in this resource's client code outside a placement in progress.
]]

Stream = {}

-- id -> { entity, netId, frozen, model, position, health, restoredHealth }
local tracked = {}
local trackedCount = 0

-- netId -> id, so an entity event can find its record without a scan.
local byNet = {}

local nearestDistance = math.huge

local function performance()
    return (Config and Config.Performance) or {}
end

-- ---------------------------------------------------------------------------------------
-- The restore instruction
-- ---------------------------------------------------------------------------------------

--[[
    Wait for a network id to become an entity on this client.

    The instruction can arrive before the entity does: the server creates it and tells us in
    the same tick, and the entity replicates on its own schedule. Giving up quietly after the
    timeout is correct - the server re-elects somebody else when no answer comes back.
]]
local function waitForEntity(netId, timeoutMs)
    local deadline = Park.ticks() + (timeoutMs or 10000)

    while Park.ticks() < deadline do
        if NetworkDoesNetworkIdExist(netId) then
            local entity = NetToVeh(netId)
            if entity and entity ~= 0 and DoesEntityExist(entity) then
                return entity
            end
        end
        Wait(50)
    end

    return nil
end

--[[
    The server has created a vehicle and elected this client to dress and place it.

    `data` carries everything needed and nothing else: the pose, the class, the interior, and
    the property table. It is deliberately a targeted event rather than a statebag, because
    only one client acts on it and a statebag would replicate the property blob to everybody
    in scope for no reason.
]]
RegisterNetEvent('vpark:client:restore', function(netId, data)
    if type(data) ~= 'table' or type(netId) ~= 'number' then return end

    CreateThread(function()
        local entity = waitForEntity(netId, 12000)

        if not entity then
            TriggerServerEvent('vpark:server:restoreFailed', data.id, 'no_entity')
            return
        end

        -- The model can read as 0 for a frame or two after an entity replicates, and every
        -- dimension-based decision below would then be taken against a model of size zero.
        local ready = Park.ticks() + 5000
        while GetEntityModel(entity) == 0 and Park.ticks() < ready do Wait(50) end

        SetEntityAsMissionEntity(entity, true, true)

        -- Properties BEFORE placement. Two reasons: fitting a body kit changes the model's
        -- dimensions, and the probe has to measure the car that will exist rather than the
        -- one that does; and a vehicle is invisible for these few frames anyway because it is
        -- still a collisionless ghost.
        if type(data.properties) == 'table' then
            Properties.apply(entity, data.properties, { version = data.version })
        end

        local result = Placement.place(entity, {
            id = data.id,
            model = GetEntityModel(entity),
            position = data.position,
            rotation = data.rotation,
            class = data.class,
            interior = data.interior,
            room = data.room,
            frozen = data.frozen,
        })

        if result.ok then
            tracked[data.id] = {
                id = data.id,
                entity = entity,
                netId = netId,
                model = GetEntityModel(entity),
                frozen = result.frozen,
                position = result.position,
                -- What body health was at restore. `Deformation.shouldRecapture` compares
                -- against this, which is what stops the approximation compounding over
                -- repeated save cycles.
                restoredHealth = GetVehicleBodyHealth(entity),
            }
            trackedCount = trackedCount + 1
            byNet[netId] = data.id
        end

        TriggerServerEvent('vpark:server:restored', data.id, result)
    end)
end)

--[[
    The server is taking a vehicle away.

    We do not delete it: the server created it and the server deletes it. All this does is
    stop tracking it, so the wake loop does not keep looking at an entity that is about to
    stop existing.
]]
RegisterNetEvent('vpark:client:forget', function(id)
    local record = tracked[id]
    if not record then return end

    if record.entity and DoesEntityExist(record.entity) then
        Deformation.clear(record.entity)
    end

    if record.netId then byNet[record.netId] = nil end
    tracked[id] = nil
    trackedCount = trackedCount - 1
end)

-- ---------------------------------------------------------------------------------------
-- Waking and re-freezing
--
-- A frozen vehicle is not simulated. That is most of the performance story on a server with
-- three thousand parked cars, and it is also what stops one drifting out of a tight parking
-- space over twenty minutes of being nudged by passing traffic.
--
-- It has to be invisible in play, which means waking BEFORE a player can touch it rather
-- than when they do.
-- ---------------------------------------------------------------------------------------

local function shouldWake(record, playerPosition)
    if not record.frozen then return false end
    if not record.entity or not DoesEntityExist(record.entity) then return false end

    local wakeRadius = tonumber(Config.Placement and Config.Placement.wakeRadius) or 30.0
    local position = GetEntityCoords(record.entity)

    return #(position - playerPosition) < wakeRadius
end

local function shouldSleep(record, playerPosition)
    if record.frozen then return false end
    if not record.entity or not DoesEntityExist(record.entity) then return false end

    local refreezeAfter = tonumber(Config.Placement and Config.Placement.refreezeAfter) or 0
    if refreezeAfter <= 0 then return false end

    local wakeRadius = tonumber(Config.Placement and Config.Placement.wakeRadius) or 30.0
    local position = GetEntityCoords(record.entity)

    -- The hysteresis. Re-freezing at the same radius that woke it means a player standing on
    -- the boundary freezes and unfreezes the same car several times a second.
    if #(position - playerPosition) < wakeRadius * 1.5 then
        record.awaySince = nil
        return false
    end

    if not record.awaySince then
        record.awaySince = Park.ticks()
        return false
    end

    return (Park.ticks() - record.awaySince) > refreezeAfter * 1000
end

--[[
    The interval for the next tick, from how far the nearest tracked vehicle is.

    The tier table is walked in order and the first tier whose distance covers us wins, so the
    config reads top-down from closest to furthest and an operator adding a tier does not have
    to think about ordering.
]]
local function tickInterval()
    local tiers = performance().clientTiers
    if type(tiers) ~= 'table' then return 1000 end

    for _, tier in ipairs(tiers) do
        if nearestDistance <= (tonumber(tier.distance) or math.huge) then
            return tonumber(tier.interval) or 1000
        end
    end

    return 2000
end

CreateThread(function()
    -- Nothing before the character exists. A restore aimed at a player still in the
    -- multicharacter screen would be placed relative to a ped that is about to move.
    while not Compat.characterLoaded() do Wait(1000) end

    while true do
        local interval = tickInterval()
        Wait(interval)

        if trackedCount > 0 then
            local playerPosition = GetEntityCoords(PlayerPedId())
            nearestDistance = math.huge

            for id, record in pairs(tracked) do
                if not record.entity or not DoesEntityExist(record.entity) then
                    -- The entity went away without us being told. The server owns that fact,
                    -- so we only stop tracking locally and let it find out on its own schedule.
                    if record.netId then byNet[record.netId] = nil end
                    tracked[id] = nil
                    trackedCount = trackedCount - 1
                else
                    local distance = #(GetEntityCoords(record.entity) - playerPosition)
                    if distance < nearestDistance then nearestDistance = distance end

                    if shouldWake(record, playerPosition) then
                        if Placement.wake(record.entity) then
                            record.frozen = false
                            record.awaySince = nil
                        end
                    elseif shouldSleep(record, playerPosition) then
                        if Placement.sleep(record.entity) then
                            record.frozen = true
                            record.awaySince = nil
                        end
                    end
                end
            end
        else
            nearestDistance = math.huge
        end
    end
end)

-- ---------------------------------------------------------------------------------------
-- Immediate wake triggers
--
-- The distance check above wakes a vehicle before a player reaches it. These cover the cases
-- where a player interacts with one at a distance, or faster than the tick.
-- ---------------------------------------------------------------------------------------

--[[
    Entering a vehicle. The one case where a frozen car would be unmistakably wrong: the
    player gets in, presses W, and nothing happens.

    `CEventNetworkPlayerEnteredVehicle` fires for the local player only, which is what we
    want - a remote player entering a frozen car is handled by the owner client's own copy of
    this handler.
]]
AddEventHandler('gameEventTriggered', function(name, args)
    if name ~= 'CEventNetworkPlayerEnteredVehicle' then return end

    local vehicle = args and args[2]
    if not vehicle or not DoesEntityExist(vehicle) then return end

    local netId = NetworkGetNetworkIdFromEntity(vehicle)
    local id = byNet[netId]
    if not id then return end

    local record = tracked[id]
    if record and record.frozen then
        if Placement.wake(vehicle) then
            record.frozen = false
        end
    end

    -- Being entered is also the moment a vehicle stops being parked, so the server is told
    -- immediately rather than on the next sweep. The `true` marks it as USED rather than
    -- merely touched, which is the clock the cleanup sweep in Section 9c counts from.
    TriggerServerEvent('vpark:server:touched', id, true)
end)

--[[
    Damage. A frozen car that is rammed should move, or the collision reads as hitting a wall.
]]
AddEventHandler('gameEventTriggered', function(name, args)
    if name ~= 'CEventNetworkEntityDamage' then return end

    local victim = args and args[1]
    if not victim or not DoesEntityExist(victim) then return end
    if GetEntityType(victim) ~= 2 then return end

    local netId = NetworkGetNetworkIdFromEntity(victim)
    local id = byNet[netId]
    if not id then return end

    local record = tracked[id]
    if record and record.frozen then
        if Placement.wake(victim) then
            record.frozen = false
        end
    end
end)

-- ---------------------------------------------------------------------------------------
-- Queries other files need
-- ---------------------------------------------------------------------------------------

function Stream.record(id)
    return tracked[id]
end

function Stream.byEntity(entity)
    if not entity or not DoesEntityExist(entity) then return nil end
    local netId = NetworkGetNetworkIdFromEntity(entity)
    local id = byNet[netId]
    if not id then return nil end
    return tracked[id], id
end

function Stream.count()
    return trackedCount
end

function Stream.all()
    return tracked
end

function Stream.nearest()
    return nearestDistance
end

--[[
    Capture the current state of a tracked vehicle, for the save path.

    The deformation is only re-read when it is worth re-reading - see
    `Deformation.shouldRecapture` - and the record's `restoredHealth` is what that decision is
    made against.
]]
function Stream.snapshot(id)
    local record = tracked[id]
    if not record or not record.entity or not DoesEntityExist(record.entity) then return nil end

    local entity = record.entity
    local properties = Properties.capture(entity)
    if not properties then return nil end

    if not Deformation.shouldRecapture(entity, record.restoredHealth) then
        properties.deformation = nil
    end

    local position = GetEntityCoords(entity)
    local rotation = GetEntityRotation(entity, 2)

    return {
        id = id,
        properties = properties,
        statebags = Properties.captureStatebags(entity),
        position = { x = Park.coord(position.x), y = Park.coord(position.y), z = Park.coord(position.z) },
        rotation = { x = Park.angle(rotation.x), y = Park.angle(rotation.y), z = Park.angle(rotation.z) },
        interior = GetInteriorFromEntity(entity),
        room = GetRoomKeyFromEntity(entity),
        frozen = record.frozen == true,
    }
end
