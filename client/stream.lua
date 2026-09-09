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

--[[
    id -> { group = true } for property groups the last restore could NOT apply.

    A group that failed leaves the vehicle showing something other than what is stored, and the next
    capture would read that back and write it over the good value. Measured on a live server: a
    vehicle with `stored neons 1,1,1,1` came back dark, and one capture later the row said
    `stored neons 0,0,0,0`. A failed restore was eating the data it failed to restore.

    `Stream.snapshot` drops these groups from its report. The server treats an absent field as
    "no news" and keeps what it has.
]]
local unverified = {}


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
--[[
    ================================================================================================
    THE HOLD. FREEZE IT ON SIGHT, ON EVERY CLIENT, BEFORE ANYTHING ELSE HAPPENS TO IT.
    ================================================================================================

    A server-created entity is simulated by a client from the moment it arrives, and the
    collision around it may not have streamed in yet. So it falls. By the time the ground
    exists, the vehicle is beneath it - which is how a car parked on a driveway comes back a
    few metres away and under the map.

    The placement pass freezes it too, but that runs after `waitForEntity`, after the model
    check, after taking control and after the properties. Seconds later. The vehicle has
    already gone through the floor, and the placement then carefully positions something that
    is somewhere else entirely.

    So the server sets `vpark:hold` as part of the same replicated write that carries the
    vehicle's id, and this freezes it the moment the bag lands - on EVERY client, not just the
    one the server nominated, because any of them may be the one simulating the fall.

    -------------------------------------------------------------------------------------------
    IT ONLY EVER FREEZES
    -------------------------------------------------------------------------------------------

    Never the reverse. Unfreezing is the placement's decision - it is the only thing that knows
    whether this vehicle should stay frozen - and the server clears the bag once the vehicle is
    placed so that a client coming into scope later does not freeze a car somebody is driving.
]]
AddStateBagChangeHandler('vpark:hold', '', function(bagName, _, value)
    if value ~= true then return end

    CreateThread(function()
        --[[
            The entity may not exist on this client yet: the bag and the entity arrive
            together and which lands first is not guaranteed.

            `Wait(0)` rather than a longer poll, and that is the point of this handler. Every
            frame between the entity arriving and the freeze is a frame it can fall in, so the
            wait is as tight as it can be for the first second and only then backs off.
        ]]
        local entity
        local deadline = Park.ticks() + 10000
        local started = Park.ticks()

        repeat
            entity = GetEntityFromStateBagName(bagName)
            if entity and entity > 0 then break end
            Wait(Park.ticks() - started < 1000 and 0 or 100)
        until Park.ticks() > deadline

        if not entity or entity == 0 or not DoesEntityExist(entity) then return end

        FreezeEntityPosition(entity, true)
    end)
end)

RegisterNetEvent('vpark:client:restore', function(netId, data)
    if type(data) ~= 'table' or type(netId) ~= 'number' then return end

    CreateThread(function()
        --[[
            EXACTLY ONE ANSWER LEAVES THIS THREAD, WHATEVER HAPPENS BELOW.

            The server holds the vehicle in `pending` until it hears back, and a thread that
            raises without answering leaves it there for the full twenty-second timeout before
            it is despawned and re-nominated. On a client with a mod that breaks one of these
            natives, that is every vehicle, every time - a fleet that visibly flickers.
        ]]
        local answered = false

        local function answer(event, ...)
            if answered then return end
            answered = true
            TriggerServerEvent(event, ...)
        end

        local entity = waitForEntity(netId, 12000)

        if not entity then
            answer('vpark:server:restoreFailed', data.id, 'no_entity')
            return
        end

        -- The model can read as 0 for a frame or two after an entity replicates, and every
        -- dimension-based decision below would then be taken against a model of size zero.
        local ready = Park.ticks() + 5000
        while GetEntityModel(entity) == 0 and Park.ticks() < ready do Wait(50) end

        SetEntityAsMissionEntity(entity, true, true)

        -- Belt and braces with the hold handler above: if the bag has not landed on this
        -- client yet, this is the same instruction a few milliseconds later.
        FreezeEntityPosition(entity, true)

        --[[
            ============================================================================
            NETWORK CONTROL FIRST. EVERYTHING BELOW WRITES TO THE ENTITY.
            ============================================================================

            THIS IS WHY VEHICLES CAME BACK THE WRONG COLOUR.

            `SetVehicleColours`, `SetVehicleMod` and every other property native applied to an
            entity this client does not own are applied LOCALLY and then overwritten by the
            owner's next synchronisation. The car looks right for a moment on the machine that
            dressed it and is stock everywhere else, including for the player standing next to
            it - and the next capture reads a stock car and writes that over the real one.

            Until 1.0.7 control was requested inside `Placement.place`, which runs AFTER the
            properties. So on any vehicle where the request took a moment - which is most of
            them, because a freshly created server entity has no owner yet - the entire dress
            was written into the void.

            A restore that cannot get control is not attempted. Reporting success would mean
            accepting a stock car and then saving it; the server keeps the vehicle where it is
            and asks again.
        ]]
        if not Placement.takeControl(entity, 5000) then
            Park.debug('no control of %s yet - leaving it held and asking again',
                tostring(data.id))
            answer('vpark:server:restored', data.id,
                { ok = false, reason = 'no_control', retry = true })
            return
        end

        --[[
            Properties BEFORE placement. Fitting a body kit changes the model's dimensions, and
            the probe has to measure the car that will exist rather than the one that does.

            Through pcall, because a raise here used to mean NO ANSWER AT ALL. The server waits
            twenty seconds for one, then despawns the vehicle and nominates somebody else - so
            one bad property on one car showed up in play as a car that appeared, vanished, and
            appeared again.
        ]]
        local dressed = true

        if type(data.properties) == 'table' then
            local ok, _, failed = pcall(Properties.apply, entity, data.properties,
                { version = data.version })

            dressed = ok
            unverified[data.id] = type(failed) == 'table' and next(failed) and failed or nil
            if not dressed then
                Park.debug('could not apply properties to %s - placing it anyway, and it will '
                    .. 'not be captured until it has been dressed', tostring(data.id))
            end
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

            -- The server's own list of the vehicles it is holding near this one. See
            -- `neighboursOf` on the server: it replaces a statebag read that had to win a race.
            neighbours = data.neighbours,
        })


        if result.ok then
            tracked[data.id] = {
                id = data.id,
                entity = entity,
                netId = netId,
                model = GetEntityModel(entity),
                frozen = result.frozen,
                position = result.position,

                -- What the DATABASE asked for, kept alongside where the placement actually
                -- put it. The two are the same on a healthy restore and the difference is the
                -- only number that matters when they are not. Read by `Stream.audit`.
                saved = data.position,
                savedRotation = data.rotation,
                -- What body health was at restore. `Deformation.shouldRecapture` compares
                -- against this, which is what stops the approximation compounding over
                -- repeated save cycles.
                restoredHealth = GetVehicleBodyHealth(entity),

                --[[
                    What the neons are SUPPOSED to be, kept so the tick below can put them back.

                    The value is lost repeatedly and for more than one reason - ownership moving,
                    a restore that did not take, an engine state change - and seven releases were
                    spent trying to work out which. Holding the answer and re-asserting it costs
                    four native reads every couple of seconds on a vehicle that has neons, and does
                    not care which of those it was.
                ]]
                neonsWanted = type(data.properties) == 'table' and data.properties.neonEnabled or nil,
                neonsColour = type(data.properties) == 'table' and data.properties.neonColor or nil,

                --[[
                    Whether this vehicle currently looks the way the database says it does.

                    A vehicle whose properties could not be applied is a STOCK car standing
                    where a modified one belongs. Capturing it would write that stock state
                    back over the real one and the modifications would be gone for good - "it
                    is not how it was before", permanently, from one failed apply.

                    So an undressed vehicle reports nothing at all until an apply succeeds.
                    See `Stream.snapshot`.
                ]]
                dressed = dressed,
            }
            trackedCount = trackedCount + 1
            byNet[netId] = data.id
        end

        answer('vpark:server:restored', data.id, result)
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

    --[[
        Cleared unconditionally, and NOT gated on the entity still existing.

        This event arrives BECAUSE the server is deleting the entity, so by the time we handle
        it `DoesEntityExist` has often already gone false - and 1.0.1's existence check meant
        the caches were then never cleared for exactly the vehicles most likely to have their
        handle handed to something else. Both of these only touch local tables.
    ]]
    if record.entity then
        Deformation.clear(record.entity)
    end

    if record.netId then byNet[record.netId] = nil end
    tracked[id] = nil
    unverified[id] = nil
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
                    --
                    -- The caches MUST be dropped here as well as in `vpark:client:forget`.
                    -- This is the path a vehicle takes when the server restarts or the engine
                    -- culls it, and a cache entry left against a freed handle is one the game
                    -- can hand to an entirely different vehicle.
                    if record.entity then
                        Deformation.clear(record.entity)
                    end

                    if record.netId then byNet[record.netId] = nil end
                    tracked[id] = nil
                    unverified[id] = nil
                    trackedCount = trackedCount - 1
                else
                    local distance = #(GetEntityCoords(record.entity) - playerPosition)
                    if distance < nearestDistance then nearestDistance = distance end

                    --[[
                        SOMETHING ELSE CHANGED THIS VEHICLE.

                        A repair from txAdmin, a mechanic script, a collision handled by another
                        resource: none of them tell v-park anything, and the capture sweep would
                        not look at a frozen vehicle at all. Body health is one native call per
                        tracked vehicle per tick and it moves for a repair and for damage alike.

                        Reported the moment it moves, which is what makes "fix it and drive off"
                        stick. Before this, the repair was noticed at the next sweep - up to thirty
                        seconds later, and never at all if the vehicle despawned first.
                    ]]
                    --[[
                        THE NEONS ARE HELD, NOT HOPED FOR.

                        Checked every couple of seconds on a vehicle that is meant to have them lit,
                        and put back when they have drifted. Four native reads, and only for
                        vehicles whose stored state says the lights should be on.

                        This is what the seven previous attempts were reaching for one mechanism at
                        a time: the value goes out for several different reasons, at several
                        different moments, and holding it is cheaper than identifying them.
                    ]]
                    --[[
                        AND ONLY WHEN THERE IS SOMETHING TO HOLD, AND NOBODY IS HOLDING IT.

                        1.0.31 held the neons at the stored value every two seconds. The stored
                        value was all-off, so v-park switched the neons OFF two seconds after
                        anybody fitted them - which made them impossible to install at all. Every
                        visit to a mod shop was undone by this loop before the player left the bay.

                        Two conditions, and both are obvious in hindsight. There is nothing to hold
                        unless at least one light is meant to be ON: holding "off" is not restoring
                        a state, it is overwriting whatever somebody is doing. And a vehicle with
                        somebody in it is a vehicle whose neons that person owns, so nothing here
                        touches it.
                    ]]
                    --[[
                        SOMEBODY IS IN IT AND THE NEONS JUST CHANGED.

                        A mod shop is the one place neons are deliberately altered, and nothing else
                        in this resource notices it: no wake, no entry, no damage. So without this
                        the change waits for the capture sweep, up to thirty seconds - and the whole
                        point of the immediate-write path is that nothing waits.

                        Only checked while a player is sitting in the vehicle, which is the only
                        time the value can legitimately change.
                    ]]
                    if not IsVehicleSeatFree(record.entity, -1) then
                        local now = 0
                        for index = 0, 3 do
                            if IsVehicleNeonLightEnabled(record.entity, index) then
                                now = now + (2 ^ index)
                            end
                        end

                        if record.neonSeen ~= nil and record.neonSeen ~= now then
                            Stream.dirty(id)
                        end

                        record.neonSeen = now
                    else
                        record.neonSeen = nil
                    end

                    local wantsNeons = false
                    if record.neonsWanted then
                        for _, value in ipairs(record.neonsWanted) do
                            if value == true then wantsNeons = true break end
                        end
                    end

                    if wantsNeons and IsVehicleSeatFree(record.entity, -1)
                        and (record.neonsAt or 0) < Park.ticks() then
                        record.neonsAt = Park.ticks() + 2000

                        local drifted = false
                        for index = 0, 3 do
                            if IsVehicleNeonLightEnabled(record.entity, index)
                                ~= (record.neonsWanted[index + 1] == true) then
                                drifted = true
                                break
                            end
                        end

                        if drifted and Properties.applyNeons then
                            pcall(Properties.applyNeons, record.entity, {
                                neonEnabled = record.neonsWanted,
                                neonColor = record.neonsColour,
                            })

                            --[[
                                A vehicle that needs correcting once has had its state dropped by
                                the engine, which is ordinary. One that needs it five times is
                                being actively fought, and that is worth a line in the SERVER log -
                                where the operator is looking, which took three attempts to get
                                right.
                            ]]
                            record.neonFixes = (record.neonFixes or 0) + 1

                            if record.neonFixes == 5 then
                                local got = {}
                                for index = 0, 3 do
                                    got[index + 1] =
                                        IsVehicleNeonLightEnabled(record.entity, index) and 1 or 0
                                end

                                TriggerServerEvent('vpark:server:neonFailed', id, {
                                    wanted = (function()
                                        local out = {}
                                        for index = 1, 4 do
                                            out[index] =
                                                record.neonsWanted[index] == true and 1 or 0
                                        end
                                        return out
                                    end)(),
                                    got = got,
                                    control = NetworkHasControlOfEntity
                                        and NetworkHasControlOfEntity(record.entity) or false,
                                    owner = NetworkGetEntityOwner
                                        and NetworkGetEntityOwner(record.entity) or -1,
                                    exists = true,
                                })
                            end
                        end
                    end

                    local health = GetVehicleBodyHealth(record.entity)

                    if record.seenHealth == nil then
                        record.seenHealth = health
                    elseif math.abs(health - record.seenHealth) >= 1.0 then
                        record.seenHealth = health
                        Stream.dirty(id)
                    end

                    if shouldWake(record, playerPosition) then
                        if Placement.wake(record.entity) then
                            record.frozen = false
                            record.awaySince = nil
                            -- Awake means it can move and be damaged again, so it is worth
                            -- capturing again. Through `Stream.dirty`, which also offers the
                            -- new state to the server instead of waiting for the next sweep.
                            Stream.dirty(id)
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
    if record then
        Stream.dirty(id)
        if record.frozen and Placement.wake(vehicle) then
            record.frozen = false
        end
    end

    -- Somebody got in. From here on this vehicle's position is worth recording: see the note
    -- in `Stream.snapshot` about why a merely WOKEN vehicle's position is not.
    record.driven = true

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
    if record then
        Stream.dirty(id)
        if record.frozen and Placement.wake(victim) then
            record.frozen = false
        end
    end
end)

-- ---------------------------------------------------------------------------------------
-- Queries other files need
-- ---------------------------------------------------------------------------------------

--[[
    Compare where every restored vehicle SHOULD be with where it actually is.

    Written because five releases of reasoning about this produced five different theories and
    the reports stayed the same shape: "not quite in the right place". A number per vehicle,
    per axis, ends that.

    Returns a list, worst first. `/vparkwhere` prints it.
]]
function Stream.audit()
    local out = {}
    local count = 0

    for id, record in pairs(tracked) do
        if record.entity and DoesEntityExist(record.entity) and record.saved then
            local at = GetEntityCoords(record.entity)
            local want = vector3(record.saved.x, record.saved.y, record.saved.z)

            local rotation = GetEntityRotation(record.entity, 2)
            local wantRotation = record.savedRotation or {}

            count = count + 1
            out[count] = {
                id = id,
                model = GetDisplayNameFromVehicleModel(record.model or 0),
                delta = #(at - want),
                dx = at.x - want.x,
                dy = at.y - want.y,
                dz = at.z - want.z,
                dHeading = Park.angleDelta(rotation.z, wantRotation.z or 0.0),
                frozen = record.frozen == true,
                dressed = record.dressed ~= false,
                mine = NetworkGetEntityOwner(record.entity) == PlayerId(),
            }
        end
    end

    table.sort(out, function(a, b) return a.delta > b.delta end)
    return out
end

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
--[[
    Mark a tracked vehicle as worth capturing again.

    Called when anything happens that could change it: a player entering it, damage, a wake, an
    admin action. Everything else leaves it clean.
]]
--[[
    ================================================================================================
    A CHANGE IS SENT NOW, NOT AT THE NEXT SWEEP.
    ================================================================================================

    Marking a vehicle dirty used to mean "the next capture will notice", and the next capture is up
    to thirty seconds away, followed by a flush up to fifteen seconds after that. Fit neons, walk
    away, and the modification could be forty-five seconds from the database - or never in it, if
    the vehicle despawned first.

    So the moment something changes, the client offers the new state. Debounced, because a visit to
    a mod shop changes a dozen things in a few seconds and one message at the end of it is the same
    information as twelve.

    The server re-checks everything and rate-limits by `Config.Save.triggerCooldown`, so this is a
    hint about WHEN to look, never a claim that must be believed.
]]

local lastPush = {}
local trailing = {}

-- How long after a send another change is folded into a single follow-up rather than sent on its
-- own. NOT a delay before the first send: see below.
local PUSH_WINDOW = 1500

local function sendNow(id)
    local record = tracked[id]
    if not record or not record.entity or not DoesEntityExist(record.entity) then return end

    local snapshot = Stream.snapshot(id)
    if not snapshot then return end

    lastPush[id] = Park.ticks()
    TriggerServerEvent('vpark:server:changed', id, snapshot)
end

--[[
    ================================================================================================
    THE FIRST CHANGE GOES AT ONCE. ONLY THE ONES BEHIND IT WAIT.
    ================================================================================================

    1.0.26 waited 1.5 seconds before sending anything, to collapse a mod shop visit into one
    message. That is the right instinct and the wrong edge: it made EVERY change late, including
    the single change somebody makes and then immediately drives away from. Repair a car, teleport
    off, and the send never happened.

    Leading edge instead. The first change is sent immediately - no timer, no wait - and anything
    that follows within `PUSH_WINDOW` is folded into one trailing send at the end of the window. A
    mod shop still costs two messages rather than twenty, and a single change costs nothing but the
    message itself.

    This is the same shape as the parked position report, which has always been instant and which
    the tester confirms works: "quand on quitte le vehicule et part aussitot la position est bien
    enregistree".
]]
local function pushChange(id)
    local now = Park.ticks()
    local last = lastPush[id]

    if not last or (now - last) >= PUSH_WINDOW then
        sendNow(id)
        return
    end

    -- Inside the window. One follow-up covers everything that happens in it.
    if trailing[id] then return end
    trailing[id] = true

    local wait = PUSH_WINDOW - (now - last)

    CreateThread(function()
        Wait(wait)
        trailing[id] = nil
        sendNow(id)
    end)
end

Stream.pushChange = pushChange

--[[
    ================================================================================================
    WHAT THIS CLIENT SEES ON THE VEHICLE, RIGHT NOW.
    ================================================================================================

    Three property bugs in three releases, and every one of them cost a round trip to work out
    whether the value was wrong on the way IN or on the way OUT. The database settled two of them in
    one query each; this is the other half of that question, asked of the live vehicle.

    `/vparkprops` prints these beside what the server has stored, so a property that does not
    survive is diagnosed in one reading instead of a release.
]]
RegisterNetEvent('vpark:client:props', function(token)
    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)

    if not vehicle or vehicle == 0 then
        vehicle = GetVehiclePedIsIn(ped, true)
    end

    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        TriggerServerEvent('vpark:server:props', token, nil)
        return
    end

    local neons = {}
    for index = 0, 3 do
        neons[index + 1] = IsVehicleNeonLightEnabled(vehicle, index) and 1 or 0
    end

    local windows, doors = {}, {}
    for index = 0, 7 do
        windows[index + 1] = IsVehicleWindowIntact(vehicle, index) and 1 or 0
    end
    for index = 0, 5 do
        doors[index + 1] = IsVehicleDoorDamaged(vehicle, index) and 1 or 0
    end

    local red, green, blue = GetVehicleNeonLightsColour(vehicle)

    local _, trackedId = Stream.byEntity(vehicle)

    local ok, bagId = pcall(function() return Entity(vehicle).state['vpark:id'] end)
    if not ok then bagId = nil end

    TriggerServerEvent('vpark:server:props', token, {
        id = trackedId,
        bag = bagId,
        model = GetDisplayNameFromVehicleModel(GetEntityModel(vehicle)),
        plate = GetVehicleNumberPlateText(vehicle),
        neons = neons,
        neonColour = { red or 0, green or 0, blue or 0 },
        windows = windows,
        doors = doors,
        bodyHealth = math.floor(GetVehicleBodyHealth(vehicle) + 0.5),
        engine = IsVehicleEngineOn(vehicle) and 1 or 0,
    })
end)

function Stream.dirty(id)
    local record = tracked[id]
    if not record then return end

    record.captureClean = false
    pushChange(id)
end

function Stream.snapshot(id)
    local record = tracked[id]
    if not record or not record.entity or not DoesEntityExist(record.entity) then return nil end

    --[[
        THE BIGGEST SAVING IN THE RESOURCE, AND THE SIMPLEST.

        A frozen vehicle is not simulated. Nothing can move it, nothing can damage it, and
        nobody can be inside it - the wake triggers fire before any of that is possible. So a
        frozen vehicle that has not been touched since its last capture is, provably, identical
        to what the server already has.

        Returning nil is not an error and not a failure: the server treats an absent snapshot
        as "no news", which is exactly what this is. On a server whose persisted fleet is mostly
        parked, this is most of the sweep cost gone - not reduced, gone.

        `captureClean` is cleared by `Stream.dirty`, which every wake, entry and damage handler
        calls.
    ]]
    --[[
        AND THE BODY HEALTH HAS NOT MOVED.

        The frozen-and-clean shortcut is right about everything v-park does to a vehicle, and blind
        to everything anything ELSE does to it. Repair a parked car with txAdmin and nothing here
        notices: the vehicle is still frozen, still clean by our own reckoning, so it is never
        re-captured and the old damage sits in the database waiting to be re-applied. Which is
        exactly the report - fix it, walk away, come back, and the dents are on it again.

        Body health is one native call and it moves for a repair and for damage alike, so it closes
        both directions.
    ]]
    local health = GetVehicleBodyHealth(record.entity)
    local settled = record.lastHealth == nil or math.abs(health - record.lastHealth) < 1.0

    if record.frozen and record.captureClean and settled then
        return nil
    end

    record.lastHealth = health

    --[[
        AN UNDRESSED VEHICLE HAS NOTHING TO SAY, AND MUST NOT SAY IT.

        `Properties.apply` failing leaves a stock car where a modified one belongs. Capturing
        that would overwrite the stored modifications with the model's defaults, which is
        losing them - not for this session, for good.

        Nil is not an error here: the server treats an absent snapshot as "no news", which is
        exactly right. The vehicle is re-dressed on its next restore and starts reporting
        again then.
    ]]
    if record.dressed == false then
        return nil
    end

    local entity = record.entity
    --[[
        ASKED BEFORE THE CAPTURE, NOT AFTER IT.

        `Deformation.read` is the most expensive part of a snapshot - sixty-eight native calls -
        and this decision was being made AFTER paying for it, then throwing the answer away. The
        answer does not depend on the capture, so there is no reason to.
    ]]
    local recapture = Deformation.shouldRecapture(entity, record.restoredHealth)

    local properties = Properties.capture(entity, { skipDeformation = not recapture })
    if not properties then return nil end

    local position = GetEntityCoords(entity)
    local rotation = GetEntityRotation(entity, 2)

    -- Clean until something touches it again.
    record.captureClean = true

    --[[
        A VEHICLE NOBODY HAS DRIVEN DOES NOT REPORT WHERE IT IS.

        Every vehicle near a player is woken - that is what makes it drivable before somebody
        reaches it - and a woken vehicle is simulated. Simulated on a camber, or nudged by
        traffic streaming in beside it, it rolls. One report had a car five metres from where it
        was parked with the placement reading 6 mm off: the car was exactly where the database
        said, and the database had been told about the roll.

        The stored position should answer "where did somebody leave this", and only a person
        driving it can change that answer. So position and rotation are omitted entirely until
        somebody has sat in it - the server treats an absent field as "no news" and keeps what
        it has, which is the pose the vehicle was parked in.

        Everything else in the snapshot is still reported: damage, fuel, dirt and modifications
        all change without anybody getting in.
    ]]
    local moved = record.driven == true

    --[[
        A GROUP THE RESTORE COULD NOT APPLY IS NOT REPORTED AS TRUTH.

        See `unverified` at the top of this file. The vehicle is showing something other than what
        is stored for these, so reporting what it shows would write the failure into the database
        and make it permanent - which is what turned `stored neons 1,1,1,1` into
        `stored neons 0,0,0,0` one capture after a restore that came back dark.

        Dropping the keys means the server keeps what it has, and the next restore tries again with
        the value the player actually chose.
    ]]
    local doubtful = unverified[id]

    if doubtful then
        for group in pairs(doubtful) do
            for _, key in ipairs(Schema.keys[group] or {}) do
                properties[key] = nil
            end
        end
    end

    --[[
        AND NEITHER DOES IT REPORT WHETHER ITS NEONS ARE ON.

        The same argument as the position above, and it took seven releases to notice that it was
        the same argument. ONLY A PERSON IN THE VEHICLE CAN TURN NEONS ON OR OFF. Everything else
        that changes them - the engine dropping the state as ownership migrates, a restore that did
        not take, a client that never had control - is the game losing the value, not somebody
        choosing it.

        So they are left out until somebody has sat in it, and the server keeps what it has. That is
        what makes this permanent rather than one more handshake: there is no path by which a dark
        vehicle nobody has touched can report itself dark and overwrite the player's own setting.

        Every previous attempt tried to DETECT the failure and suppress the report. This does not
        need to detect anything, which is why it is the last one.
    ]]
    --[[
        `driven` is set on the client that was nominated to place the vehicle, and a player fitting
        neons at a mod shop is very often not that client - so the flag alone would refuse to report
        the very change it exists to allow.

        Somebody in the driver's seat right now is the same fact, observable from any machine.
    ]]
    local theirs = record.driven == true or not IsVehicleSeatFree(entity, -1)

    if not theirs then
        for _, key in ipairs(Schema.keys.neons or {}) do
            properties[key] = nil
        end
    end

    return {
        id = id,
        properties = properties,
        statebags = Properties.captureStatebags(entity),
        position = moved and { x = Park.coord(position.x), y = Park.coord(position.y), z = Park.coord(position.z) } or nil,
        rotation = moved and { x = Park.angle(rotation.x), y = Park.angle(rotation.y), z = Park.angle(rotation.z) } or nil,
        interior = GetInteriorFromEntity(entity),
        room = GetRoomKeyFromEntity(entity),
        frozen = record.frozen == true,

        -- Fills in `vehicle_type` for a row written before 1.0.4. The server writes it once
        -- and then ignores this field; see `Persist.applySnapshot`.
        vehicleType = GetVehicleType and GetVehicleType(entity) or nil,
    }
end
