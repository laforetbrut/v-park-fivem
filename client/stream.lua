--[[
    client/stream.lua
    Author: vyrriox

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

--[[
    ================================================================================================
    EVERY CLIENT KNOWS ABOUT EVERY VEHICLE, NOT JUST THE ONE THAT PLACED IT.
    ================================================================================================

    `tracked` above is this client's own restore book: it holds only the vehicles THIS client was
    nominated to dress and place. That is correct for placing one, and it was quietly wrong for
    everything else, in two ways that both showed up in testing with three players.

    1. A CAR THAT READS AS A WALL. `vpark:hold` freezes a restored vehicle on EVERY client, because
       any of them may be the one simulating its fall. Only the nominated client ever unfreezes it,
       and only from `tracked`. So on every other machine the vehicle stayed frozen for good - and
       a frozen entity on the client that OWNS it is not simulated at all. Drive into a parked car
       whose entity has migrated to you and it does not move, does not take the hit and cannot be
       towed: "il reste tres solide comme de la piere". Nothing in any log, because nothing failed.

    2. A CAPTURE NOBODY COULD ANSWER. The save sweep asks the client NEAREST a vehicle, and for a
       vehicle being driven it asks the occupant. Neither is necessarily the client that placed it,
       and a client with no `tracked` entry answered nothing at all - silently, since an absent
       snapshot means "no news". So on a busy server, tuning, damage and repairs done to a car
       somebody else's client had placed never reached the database: "une custom n'a pas survecu au
       reboot", "vehicules repare au reboot serveur".

    So this second index exists, on every client, built from the REPLICATED `vpark:id` statebag -
    the same source `client/track.lua` uses, and for the same reason. It carries no per-vehicle
    knowledge, because a client that did not place a vehicle has none: what it can do is unfreeze
    what it can see, and read the entity when asked.
]]
local foreign = {}
local foreignCount = 0

--[[
    Foreign vehicles somebody has actually sat in on this machine.

    The reason position is withheld from a snapshot is that only a person driving a vehicle can
    change where it is parked - see `Stream.snapshot`. On a tracked vehicle that fact lives on
    the record; a foreign one has no record, and without this the position of a car driven by
    anybody other than the client that placed it was never written down at all.
]]
local foreignDriven = {}

-- id -> the body health this client last saw, so a repair or a collision done to a vehicle
-- somebody else's machine placed is noticed here too. One native call per vehicle per tick,
-- which is what the tracked pass already pays for the same reason.
local foreignHealth = {}

--[[
    id -> true once the ground probe under this vehicle has answered.

    Freezing is a PER-CLIENT flag, so a helicopter dropped back into physics by the client that
    placed it stays frozen on every other machine - and a frozen copy ignores the position updates
    the owner is sending, so those players watch it hang in the sky while it is really on the
    ground. The same probe therefore runs here, once per vehicle, until it answers.
]]
local foreignGround = {}

local function forgetForeign(id)
    if foreign[id] == nil then return end
    foreign[id] = nil
    foreignCount = foreignCount - 1
end

AddStateBagChangeHandler('vpark:id', '', function(bagName, _, value)
    if type(value) ~= 'string' then
        -- The server cleared it: the vehicle is no longer one of ours. Which id it was is not
        -- in the message, so the entry is left for the tick to prune when the handle goes.
        return
    end

    CreateThread(function()
        --[[
            The bag can land before the entity does, exactly as in `waitForEntity`. Polled
            through `GetEntityFromStateBagName` rather than the network id, so this costs no
            object-manager warnings.
        ]]
        local entity
        local deadline = Park.ticks() + 10000

        repeat
            entity = GetEntityFromStateBagName(bagName)
            if entity and entity > 0 and DoesEntityExist(entity) then break end
            Wait(100)
        until Park.ticks() > deadline

        if not entity or entity == 0 or not DoesEntityExist(entity) then return end

        if foreign[value] == nil then foreignCount = foreignCount + 1 end
        foreign[value] = entity
    end)
end)

--[[
    Hand physics back, whatever it takes.

    `Placement.wake` asks for network control first, which is right for the client that placed
    the vehicle: it wants to own it, hold the pose and watch for an ejection. It is also allowed
    to fail, and a failure there used to mean the entity stayed frozen.

    Freezing is a per-client flag, so a client that keeps it frozen is the whole of bug 1 above.
    Control refused is a reason to unfreeze locally anyway, not a reason to give up: the worst
    case is that this client's copy is simulated by somebody else, which is the normal state of
    every other vehicle in the game.
]]
local function ensureAwake(entity)
    if not DoesEntityExist(entity) then return false end

    -- Moored on purpose. See `client/anchor.lua`.
    if Anchor and Anchor.isAnchored and Anchor.isAnchored(entity) then return false end

    -- Already ours to push around. The common case by a wide margin, and it is why the state bag
    -- read below costs nothing on a busy pass.
    if not IsEntityPositionFrozen(entity) then return true end

    --[[
        NOT WHILE THE SERVER IS STILL HOLDING IT.

        `vpark:hold` means "this vehicle has been created and not yet placed", and the freeze it
        asks for is the one thing standing between a server-created entity and the ground it has
        not streamed in yet. Unfreezing during that window is how a car parked on a driveway comes
        back under the map - the failure the hold was written for in 1.0.7.

        The server clears the bag the moment the placement finishes, on both the success and the
        gave-up paths, so this is a window of a few seconds and never a permanent refusal.
    ]]
    local ok, hold = pcall(function() return Entity(entity).state['vpark:hold'] end)
    if ok and hold == true then return false end

    if Placement.wake(entity) then return true end

    FreezeEntityPosition(entity, false)
    return true
end

Stream.ensureAwake = ensureAwake

--[[
    The same wake decision as the tracked pass, for a vehicle this client did not place.

    UNFREEZING ONLY, AND DELIBERATELY. Re-freezing is left to the client that placed it, because
    a frozen entity IGNORES POSITION WRITES - so a client that freezes a copy it does not own
    stops following the owner and shows the car where it used to be. The one exception is a
    vehicle this client actually owns, which is the only case where freezing it is the same
    decision the placer would make.
]]
local function mirrorPass(playerPosition)
    local wakeRadius = tonumber(Config.Placement and Config.Placement.wakeRadius) or 30.0
    local refreezeAfter = tonumber(Config.Placement and Config.Placement.refreezeAfter) or 0
    local nearest = math.huge

    for id, entity in pairs(foreign) do
        if not DoesEntityExist(entity) then
            forgetForeign(id)
            foreignDriven[id] = nil
            foreignHealth[id] = nil
            foreignGround[id] = nil
        elseif tracked[id] then
            -- This client placed it after all. Its own record is the authority.
            forgetForeign(id)
            foreignDriven[id] = nil
            foreignHealth[id] = nil
            foreignGround[id] = nil
        else
            local distance = #(GetEntityCoords(entity) - playerPosition)
            if distance < nearest then nearest = distance end

            --[[
                A REPAIR OR A COLLISION HANDLED BY ANYTHING ELSE, NOTICED HERE TOO.

                The tracked pass does this for the vehicles this client placed, and until now a
                txAdmin repair on a car placed by another machine reached the database only when
                the sweep next happened to ask this client - up to thirty seconds, and never if
                the vehicle despawned first. Body health is one native call and it moves for a
                repair and for damage alike.
            ]]
            local health = GetVehicleBodyHealth(entity)

            if foreignHealth[id] == nil then
                foreignHealth[id] = health
            elseif math.abs(health - foreignHealth[id]) >= 1.0 then
                foreignHealth[id] = health
                Stream.dirty(id)
            end

            -- Frozen in mid-air on this client. See `foreignGround`.
            if not foreignGround[id] and IsEntityPositionFrozen(entity) then
                local up = Placement.airborne(entity)

                if up ~= nil then
                    foreignGround[id] = true
                    if up then ensureAwake(entity) end
                end
            end

            if distance < wakeRadius then
                ensureAwake(entity)
            elseif refreezeAfter > 0 and distance > wakeRadius * 1.5
                and NetworkHasControlOfEntity and NetworkHasControlOfEntity(entity) then
                -- Ours to simulate and nobody near it, so it costs simulation for nothing.
                -- `Placement.sleep` refuses a vehicle that is moving or occupied.
                Placement.sleep(entity)
            end
        end
    end

    return nearest
end


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
--[[
    THROUGH THE STATE BAG, NOT THROUGH THE NETWORK ID.

    `NetworkDoesNetworkIdExist` asks the object manager for an object that is not there yet,
    and the object manager says so in the client console:

        Warning: [entity] GetNetworkObject: no object by ID 65533

    Once per poll, every 50 ms, per vehicle being restored - which is a wall of yellow in F8
    for as long as three vehicles are waiting on collision. The warning is harmless and it is
    not ours to silence, so the answer is not to ask that question.

    `GetEntityFromStateBagName` answers the same one without touching the object manager, and
    the bag we need is already there: the server sets `vpark:hold` and `vpark:id` on the entity
    in the same replicated write that carries it. The native is kept as a fallback for a build
    where the bag route comes back empty, but only every second rather than every 50 ms.
]]
local function waitForEntity(netId, timeoutMs)
    local deadline = Park.ticks() + (timeoutMs or 10000)
    local bagName = ('entity:%d'):format(netId)
    local nextNativeAsk = 0

    while Park.ticks() < deadline do
        local entity = GetEntityFromStateBagName(bagName)

        if (not entity or entity == 0) and Park.ticks() >= nextNativeAsk then
            nextNativeAsk = Park.ticks() + 1000

            if NetworkDoesNetworkIdExist(netId) then
                entity = NetToVeh(netId)
            end
        end

        if entity and entity ~= 0 and DoesEntityExist(entity) then
            return entity
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
            local ok, applied, failed = pcall(Properties.apply, entity, data.properties,
                { version = data.version })

            -- A local withheld group cannot protect a snapshot from another client.
            -- Keep the server's existing undressed guard up when extras never verified.
            dressed = ok and applied ~= false and not (type(failed) == 'table' and failed.extras)
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


        --[[
            WAIT FOR THE BODYWORK TO STOP MOVING, THEN READ WHAT IT SETTLED AT.

            The deformation apply converges by hitting the panels and measuring between blows, on
            its own thread, over about a tenth of a second. Every blow lowers body health. So the
            number this vehicle will sit at is not known when `Properties.apply` returns, and a
            reference taken then is a value the car held on the way past.

            The placement above already took longer than the deformation's budget in almost every
            case, so this normally does not wait at all.
        ]]
        if Deformation and Deformation.busy then
            local settleBy = Park.ticks() + 3000
            while Deformation.busy(entity) and Park.ticks() < settleBy do Wait(25) end
        end

        local settledHealth = GetVehicleBodyHealth(entity)

        -- Told to the server as well as remembered here. `record.dressed` stops THIS client
        -- reporting a stock car as the truth; `entry.undressed` on the server stops every other
        -- client doing it, which matters now that any of them can be asked. See `applySnapshot`.
        result.dressed = dressed

        --[[
            And the settled health goes with it, because every OTHER client needs it too.

            The capture sweep asks whichever client is nearest, and only this one watched the
            restore happen. Without the number, another client comparing the live health against
            the STORED one would see the gap the restore itself opened - stored 600, live 560
            because its own dents were put back on it - decide the car had taken new damage, and
            write 560 down. The row would walk towards zero one restore at a time.
        ]]
        result.health = Park.round(settledHealth, 1)

        if result.ok then
            tracked[data.id] = {
                id = data.id,
                entity = entity,
                netId = netId,
                model = GetEntityModel(entity),
                frozen = result.frozen,

                -- The ground probe could not answer during the placement, so the tick asks
                -- again. See `groundUnknown` in `Placement.place`.
                groundUnknown = result.groundUnknown == true,

                position = result.position,

                -- What the DATABASE asked for, kept alongside where the placement actually
                -- put it. The two are the same on a healthy restore and the difference is the
                -- only number that matters when they are not. Read by `Stream.audit`.
                saved = data.position,
                savedRotation = data.rotation,
                --[[
                    WHAT THE BODY HEALTH SETTLED AT, once the restore had finished putting the
                    stored damage back on it.

                    Not the stored number: applying a car's own damage lowers its health below what
                    was stored, and that is correct rather than a fault - the stored 600 describes a
                    dented car, and a dented car reads lower than 600 the moment the dents exist.

                    Not a read taken before the deformation had converged either, which is what the
                    `settledHealth` wait above is for.

                    Everything measures against this. `Deformation.shouldRecapture` asks whether the
                    car has taken damage the restore did not put there, and so does the health group
                    in `Stream.snapshot` - which is what stops both the dents and the number walking
                    over repeated save cycles.
                ]]
                restoredHealth = settledHealth,

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
        if Anchor and Anchor.forget then Anchor.forget(record.entity) end
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

            --[[
                Resolved once for the whole pass rather than per vehicle, because with
                `Config.Save.fields.neons = 'auto'` this asks the game for a resource state.

                Off by default. When it is off, v-park does not read, hold or report the neons
                of anything - see the note on that config field for why nine releases of trying
                ended in deferring to the mod shops that do it well.
            ]]
            local neonsEnabled = Schema.enabled('neons')

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
                        if Anchor and Anchor.forget then Anchor.forget(record.entity) end
                    end

                    if record.netId then byNet[record.netId] = nil end
                    tracked[id] = nil
                    unverified[id] = nil
                    trackedCount = trackedCount - 1
                else
                    local distance = #(GetEntityCoords(record.entity) - playerPosition)
                    if distance < nearestDistance then nearestDistance = distance end

                    --[[
                        ================================================================================
                        WHAT THIS TICK DOES FOR EVERY VEHICLE V-PARK IS HOLDING.
                        ================================================================================

                        Three things, and they accumulated one release at a time - which is visible
                        in the history and was worth tidying into one place.

                        1. BODY HEALTH. A repair from txAdmin, a mechanic script or a collision
                           handled elsewhere tells v-park nothing, and the capture sweep does not
                           look at a frozen vehicle at all. One native call, and it moves for a
                           repair and for damage alike, so the change is reported at once instead
                           of up to thirty seconds later - or never, if the vehicle despawned.

                        2. NEONS CHANGING WHILE SOMEBODY IS IN IT. A mod shop is the one place the
                           value is deliberately altered and nothing else notices it. Only a state
                           that is seen to MOVE counts: presence is not intent, and treating it as
                           intent destroyed the stored value at the moment somebody checked it.

                        3. NEONS DRIFTING WHILE NOBODY IS. The engine loses the state for several
                           different reasons at several different moments - losing it across a
                           store-and-retrieve cycle is known FiveM behaviour - so it is put back
                           rather than diagnosed. Only when at least one light is meant to be ON,
                           and never while somebody is sitting in the vehicle.
                    ]]
                    if neonsEnabled and not IsVehicleSeatFree(record.entity, -1) then
                        local now = 0
                        for index = 0, 3 do
                            if IsVehicleNeonLightEnabled(record.entity, index) then
                                now = now + (2 ^ index)
                            end
                        end

                        --[[
                            ================================================================================
                            SOMEBODY CHANGING THE NEONS IS NOT THE SAME AS SOMEBODY BEING PRESENT.
                            ================================================================================

                            1.0.32 let any occupied vehicle report its neons, on the reasoning that
                            the person sitting in it owns them. That is true of somebody who changes
                            something and false of somebody who gets in TO LOOK - which is what a
                            player does when checking whether their neons survived. Getting in fired
                            an immediate report of the state the failed restore had left, and the
                            stored value went to zero at the exact moment it was being inspected.

                            The same mistake as 1.0.29's guard, in a different place. Presence is
                            not intent, and the way to tell them apart is to watch for the state
                            actually moving.

                            `neonsWanted` moves with it, or the tick below would put the old value
                            back the moment the player got out - fighting them over the change they
                            had just made.
                        ]]
                        if record.neonSeen ~= nil and record.neonSeen ~= now then
                            record.neonsChosen = true

                            local wanted = {}
                            for index = 0, 3 do
                                wanted[index + 1] = IsVehicleNeonLightEnabled(record.entity, index)
                            end
                            record.neonsWanted = wanted

                            Stream.dirty(id)
                        end

                        record.neonSeen = now
                    else
                        record.neonSeen = nil
                    end

                    local wantsNeons = false
                    if not neonsEnabled then record.neonsWanted = nil end
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

                    --[[
                        THE GROUND PROBE, ASKED AGAIN UNTIL IT ANSWERS.

                        A vehicle placed at the far edge of the streaming radius is placed over a
                        map this client has not loaded, so `GetGroundZFor_3dCoord` answers nothing
                        and the airborne check at placement time cannot run. A helicopter left
                        hovering then stayed frozen in the sky until a player walked into the wake
                        radius, which is exactly what was reported: "il reste bloquer dans le ciel
                        jusqu'a temps qu'on s'en approche de tres pres".

                        One probe per tick per vehicle, and only while the answer is unknown -
                        which stops being true the first time the map underneath exists.
                    ]]
                    if record.groundUnknown and record.frozen then
                        local airborne = Placement.airborne(record.entity)

                        if airborne ~= nil then
                            record.groundUnknown = false

                            if airborne and ensureAwake(record.entity) then
                                Park.debug('%s was frozen in mid-air - handing it back to physics',
                                    tostring(id))
                                record.frozen = false
                            end
                        end
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

        --[[
            And then the vehicles this client can see but did not place. Separate from the pass
            above because it shares none of its per-vehicle state - see `foreign`.

            It also contributes to `nearestDistance`, so a player standing in a car park somebody
            else's client filled ticks at the car-park rate rather than the empty-field one.
        ]]
        if foreignCount > 0 then
            local nearest = mirrorPass(GetEntityCoords(PlayerPedId()))
            if nearest < nearestDistance then nearestDistance = nearest end
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

    --[[
        THE STATE BAG, NOT `byNet`.

        `byNet` only knows the vehicles this client placed, and the player getting into a car is
        very often not that client. Keyed on the replicated bag this runs on whichever machine
        the driver is on, which is the same correction `client/track.lua` made in 1.0.16 and the
        same one the damage handler below needed.

        It also removes a nil index that had been sitting one line below a guard that existed
        precisely because the record can be absent.
    ]]
    local ok, id = pcall(function() return Entity(vehicle).state['vpark:id'] end)
    if not ok or type(id) ~= 'string' then return end

    ensureAwake(vehicle)

    local record = tracked[id]

    if record then
        record.frozen = false
        -- Somebody got in. From here on this vehicle's position is worth recording: see the
        -- note in `Stream.snapshot` about why a merely WOKEN vehicle's position is not.
        record.driven = true
        Stream.dirty(id)
    else
        foreignDriven[id] = true
    end

    -- Being entered is also the moment a vehicle stops being parked, so the server is told
    -- immediately rather than on the next sweep. The `true` marks it as USED rather than
    -- merely touched, which is the clock the cleanup sweep in Section 9c counts from.
    TriggerServerEvent('vpark:server:touched', id, true)
end)

--[[
    Damage. A frozen car that is rammed should move, or the collision reads as hitting a wall.
]]
--[[
    KEYED ON THE STATE BAG, NOT ON THIS CLIENT'S RESTORE BOOK.

    `byNet` is only populated on the client that placed the vehicle, and the client that rams a
    parked car is whichever one is driving. So on every other machine this handler used to find
    nothing and return - which is the moment the report describes: you drive into a persistent
    vehicle and it does not move, because it is still frozen on your machine and your machine is
    the one simulating it.

    The unfreeze is unconditional and comes first. Whether we are also tracking it decides
    whether there is anything to mark dirty, and that is a separate question.
]]
AddEventHandler('gameEventTriggered', function(name, args)
    if name ~= 'CEventNetworkEntityDamage' then return end

    local victim = args and args[1]
    if not victim or not DoesEntityExist(victim) then return end
    if GetEntityType(victim) ~= 2 then return end

    local ok, bagId = pcall(function() return Entity(victim).state['vpark:id'] end)
    if not ok or type(bagId) ~= 'string' then return end

    ensureAwake(victim)

    local record = tracked[bagId]
    if record then
        record.frozen = false
        Stream.dirty(bagId)
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
--[[
    ================================================================================================
    IT ANSWERS FOR EVERYTHING IN FRONT OF YOU, NOT ONLY WHAT THIS CLIENT PLACED.
    ================================================================================================

    `tracked` is this client's own restore book, and it was the only thing this walked. With three
    players each client had placed a fraction of what it could see, so the command answered "no
    restored vehicles are being tracked on this client" to a player standing in a car park full of
    them - which two testers reported as the command simply not working.

    `wanted` is the stored pose per id, sent by the server with the question. A vehicle this client
    placed still uses its own copy, because that is the pose the placement was actually given and
    it cannot have been changed since by anything the server did not also see.
]]
function Stream.audit(wanted)
    local out = {}
    local count = 0
    local seen = {}

    local function add(id, entity, want, wantHeading, frozen, dressed, placedHere)
        if not entity or not DoesEntityExist(entity) or not want then return end

        local at = GetEntityCoords(entity)
        local target = vector3(want.x, want.y, want.z)
        local rotation = GetEntityRotation(entity, 2)

        count = count + 1
        seen[id] = true
        out[count] = {
            id = id,
            model = GetDisplayNameFromVehicleModel(GetEntityModel(entity)),
            delta = #(at - target),
            dx = at.x - target.x,
            dy = at.y - target.y,
            dz = at.z - target.z,
            dHeading = Park.angleDelta(rotation.z, wantHeading or 0.0),
            frozen = frozen,
            dressed = dressed,
            mine = NetworkGetEntityOwner(entity) == PlayerId(),
            placedHere = placedHere,
        }
    end

    for id, record in pairs(tracked) do
        add(id, record.entity, record.saved, (record.savedRotation or {}).z,
            record.frozen == true, record.dressed ~= false, true)
    end

    if type(wanted) == 'table' then
        for id, entity in pairs(foreign) do
            if not seen[id] then
                -- `dressed` is unknowable from here: only the client that applied the properties
                -- knows whether they went on. Reported as yes rather than as a doubt, because a
                -- doubt on every foreign vehicle would drown the ones that are really undressed.
                add(id, entity, wanted[id], (wanted[id] or {}).h,
                    IsEntityPositionFrozen(entity), true, false)
            end
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

--[[
    A vehicle this client did not place is sent the same way.

    `Stream.snapshot` decides which of the two paths applies, so the only thing needed here is
    to stop requiring a tracked record. Without this a repair or a respray on a car somebody
    else's machine placed waited for the sweep - which is the promise this whole section exists
    to keep, made to half the vehicles on the server.

    No reference health is passed, deliberately: this send happens because something is known to
    have changed, which is exactly when the dents are worth re-measuring.
]]
local function sendNow(id)
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
--[[
    ================================================================================================
    CAN THIS VEHICLE HAVE NEONS SET ON IT AT ALL, AND DO THEY STAY?
    ================================================================================================

    Nine releases have gone into neon persistence by reasoning about which mechanism drops the value
    and fixing that one. Every fix was plausible, several were real bugs, and the feature still does
    not work - which means the reasoning has been running ahead of the evidence for a long time.

    So this stops reasoning. It writes the neons on the vehicle the player is in, with nothing else
    involved, and reads the answer back three times: immediately, after a second, and after three.
    Then it reports all of it to the server, with the conditions that could plausibly matter -
    whether the entity is frozen, who owns it, whether this client has control, whether the mod kit
    call succeeded.

    That answers, in one command, a question nine releases have only been able to guess at: is
    setting a neon on a vehicle v-park restored even possible, and if it is, when does it come
    undone? Run it on a freshly restored vehicle and the answer is in the server log.

    It changes the vehicle it is run on, deliberately - it is a test, not an inspection.
]]
RegisterNetEvent('vpark:client:neontest', function()
    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)
    if not vehicle or vehicle == 0 then vehicle = GetVehiclePedIsIn(ped, true) end

    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        TriggerServerEvent('vpark:server:neontest', { error = 'no vehicle' })
        return
    end

    local function read()
        local out = {}
        for index = 0, 3 do
            out[index + 1] = IsVehicleNeonLightEnabled(vehicle, index) and 1 or 0
        end
        return table.concat(out, ',')
    end

    local report = {
        before = read(),
        frozen = IsEntityPositionFrozen and IsEntityPositionFrozen(vehicle) or 'unknown',
        controlBefore = NetworkHasControlOfEntity and NetworkHasControlOfEntity(vehicle) or false,
        owner = NetworkGetEntityOwner and NetworkGetEntityOwner(vehicle) or -1,
        engine = IsVehicleEngineOn(vehicle),
        model = GetDisplayNameFromVehicleModel(GetEntityModel(vehicle)),
        plate = GetVehicleNumberPlateText(vehicle),
    }

    CreateThread(function()
        -- Control first, then the mod kit, then the lights. The order the game wants.
        if Placement and Placement.takeControl then Placement.takeControl(vehicle, 1000) end
        report.controlAfter = NetworkHasControlOfEntity
            and NetworkHasControlOfEntity(vehicle) or false

        SetVehicleModKit(vehicle, 0)

        for index = 0, 3 do SetVehicleNeonLightEnabled(vehicle, index, true) end
        SetVehicleNeonLightsColour(vehicle, 255, 0, 255)

        report.immediately = read()

        Wait(1000)
        report.afterOneSecond = read()

        Wait(2000)
        report.afterThreeSeconds = read()
        report.stillFrozen = IsEntityPositionFrozen and IsEntityPositionFrozen(vehicle) or 'unknown'

        TriggerServerEvent('vpark:server:neontest', report)
    end)
end)

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

    --[[
        THE PAINT, BECAUSE A COLOUR REPORT WITHOUT IT IS UNFALSIFIABLE.

        A tester wrote "doute sur la bonne couleur (lors d'un teste avec le chrome)", and there is
        no way to turn a doubt like that into a yes or a no by reasoning: chrome is a paint TYPE on
        one API and a colour INDEX on another, v-park writes both, and which of them the mod shop
        used is not knowable from here. So all of it is reported side by side with what is stored,
        and one reading settles which of the two is wrong.
    ]]
    local primary, secondary = GetVehicleColours(vehicle)
    local pearlescent, wheelColour = GetVehicleExtraColours(vehicle)

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
        engineHealth = math.floor(GetVehicleEngineHealth(vehicle) + 0.5),
        engine = IsVehicleEngineOn(vehicle) and 1 or 0,

        --[[
            THE TYRE SMOKE, BECAUSE A TESTER SAYS IT DOES NOT SURVIVE AND THE CODE SAYS IT SHOULD.

            "au reboot la fumee des pneus ne survit pas". Reading the apply path says otherwise:
            the mod kit is set, `ToggleVehicleMod(20, ...)` runs with the modifications, and
            `SetVehicleTyreSmokeColor` runs after it, which is the order every implementation in
            the ecosystem uses.

            Reasoning further would be doing what nine releases of neon fixes did. The two values
            are printed side by side with what is stored instead, and one reading says whether the
            toggle, the colour, or the capture of either is what goes.
        ]]
        smokeOn = IsToggleModOn(vehicle, 20) and 1 or 0,
        smokeColour = { GetVehicleTyreSmokeColor(vehicle) },

        colours = { primary or -1, secondary or -1 },
        modColor1 = { GetVehicleModColor_1(vehicle) },
        modColor2 = { GetVehicleModColor_2(vehicle) },
        extraColours = { pearlescent or -1, wheelColour or -1 },
        customPrimary = GetIsVehiclePrimaryColourCustom(vehicle)
            and { GetVehicleCustomPrimaryColour(vehicle) } or nil,
        customSecondary = GetIsVehicleSecondaryColourCustom(vehicle)
            and { GetVehicleCustomSecondaryColour(vehicle) } or nil,
    })
end)

function Stream.dirty(id)
    local record = tracked[id]

    -- A foreign vehicle has no `captureClean` to clear, because it has no frozen-and-clean
    -- shortcut to be let through: `foreignSnapshot` always reads the vehicle.
    if record then record.captureClean = false end

    pushChange(id)
end

--[[
    ================================================================================================
    WHAT A CLIENT THAT DID NOT PLACE THIS VEHICLE CAN HONESTLY SAY ABOUT IT.
    ================================================================================================

    The save sweep asks whichever client is NEAREST a vehicle, and for one being driven it asks the
    occupant. Neither is necessarily the client that placed it, and until now a client with no
    `tracked` entry answered nothing - silently, because an absent snapshot means "no news". Every
    modification, repair and dent on a car placed by somebody else's machine went unrecorded.

    Modifications, colours and damage are part of the network sync tree, so this client is looking at
    the real vehicle and not a local guess: what it reads is what the owner has. Three things it
    genuinely cannot know, and each is left out rather than guessed:

      the deformation reference   Whether the dents are worth re-measuring depends on what body
                                  health was when the vehicle was restored, which only the placing
                                  client saw. THE SERVER SENDS IT: `reference` is the stored body
                                  health, and comparing live health against that is the same
                                  question `Deformation.shouldRecapture` asks, asked with the one
                                  number this client is missing.

      the neons                   Only a person in the vehicle can choose them, and this client has
                                  no record of anybody having done so. Reporting them would be the
                                  1.0.29 mistake with a different table underneath it.

      whether it was dressed      A restore that could not apply its properties leaves a stock car,
                                  and reporting that would overwrite the real one. Only the placing
                                  client knows. So a vehicle that IS being tracked somewhere else
                                  and failed to dress can still be reported here - which is the one
                                  case this path is weaker than the other, and it is bounded: the
                                  placing client is the nearest client for the whole of a failed
                                  restore, because it was chosen for being nearest.
]]
local function foreignSnapshot(id, reference)
    local entity = foreign[id]
    if not entity or not DoesEntityExist(entity) then return nil end

    local recapture = Deformation.shouldRecapture(entity, tonumber(reference))

    local properties = Properties.capture(entity, { skipDeformation = not recapture })
    if not properties then return nil end

    -- Named rather than merely absent: a snapshot REPLACES the stored properties, so a group
    -- dropped without being named is a group deleted. See the note in `Stream.snapshot`, which
    -- also explains why the anchor is in here.
    local withheld = { neons = true }
    if not recapture then
        withheld.deformation = true
        withheld.health = true
    end
    if properties.anchored ~= true then withheld.anchor = true end

    for _, key in ipairs(Schema.keys.neons or {}) do
        properties[key] = nil
    end

    local moved = foreignDriven[id] == true
    local position = moved and GetEntityCoords(entity) or nil
    local rotation = moved and GetEntityRotation(entity, 2) or nil

    -- Where it is standing while nobody is driving it. Same rule and same reason as the one in
    -- `Stream.snapshot`: this is the client a tow truck's driver is on far more often than the
    -- one that placed the vehicle.
    local resting, restingRotation

    if not moved
        and IsVehicleSeatFree(entity, -1)
        and GetEntitySpeed(entity) < 0.5 then
        resting = GetEntityCoords(entity)
        restingRotation = GetEntityRotation(entity, 2)
    end

    return {
        id = id,
        properties = properties,
        withheld = withheld,
        statebags = Properties.captureStatebags(entity),
        position = position and
            { x = Park.coord(position.x), y = Park.coord(position.y), z = Park.coord(position.z) } or nil,
        rotation = rotation and
            { x = Park.angle(rotation.x), y = Park.angle(rotation.y), z = Park.angle(rotation.z) } or nil,
        resting = resting and
            { x = Park.coord(resting.x), y = Park.coord(resting.y), z = Park.coord(resting.z) } or nil,
        restingRotation = restingRotation and
            { x = Park.angle(restingRotation.x), y = Park.angle(restingRotation.y),
              z = Park.angle(restingRotation.z) } or nil,
        interior = GetInteriorFromEntity(entity),
        room = GetRoomKeyFromEntity(entity),
        vehicleType = GetVehicleType and GetVehicleType(entity) or nil,
    }
end

function Stream.snapshot(id, reference)
    local record = tracked[id]

    -- Not one this client placed. It can still be looked at: see `foreignSnapshot`.
    if not record then return foreignSnapshot(id, reference) end

    if not record.entity or not DoesEntityExist(record.entity) then return nil end

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

    -- External scripts can change extras without moving or damaging a frozen vehicle.
    if record.frozen and record.captureClean and settled
        and Properties.extrasMatch(record.entity, record.lastExtras) then
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
    record.lastExtras = properties.extras

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
        ================================================================================================
        AND WHERE IT IS STANDING, WHEN SOMETHING HAS CLEARLY CARRIED IT SOMEWHERE ELSE.
        ================================================================================================

        A tow truck moves a vehicle without anybody sitting in it. So does a cargobob, a forklift,
        another car shoving it, and a player pushing it out of a doorway. All three testers reported
        the same result: the vehicle goes back where it was picked up at the next restart.

        The first attempt at this read the position on the SERVER, and that is the one read that
        cannot answer: a server-side entity's position is maintained by its network owner, so once
        nobody is simulating it the value comes back as the position the server created it at. The
        note over `poseIfFresh` has said so since 1.0.15, which is why the parked report has always
        come from the client.

        So it comes from the client too. This is a REPORT, not a decision: the server compares it
        against what it has stored, applies the threshold, and checks that the player sending it is
        actually standing near the position they are describing. See `applySnapshot`.

        Only from a vehicle that is empty and has stopped. One mid-tow would otherwise be written
        down at a point on the journey rather than where it was put down.
    ]]
    local resting
    local restingRotation

    if not moved
        and IsVehicleSeatFree(entity, -1)
        and GetEntitySpeed(entity) < 0.5 then
        resting = position
        restingRotation = rotation
    end

    --[[
        A GROUP THE RESTORE COULD NOT APPLY IS NOT REPORTED AS TRUTH.

        See `unverified` at the top of this file. The vehicle is showing something other than what
        is stored for these, so reporting what it shows would write the failure into the database
        and make it permanent - which is what turned `stored neons 1,1,1,1` into
        `stored neons 0,0,0,0` one capture after a restore that came back dark.

        Dropping the keys means the server keeps what it has, and the next restore tries again with
        the value the player actually chose.
    ]]
    --[[
        ================================================================================================
        A WITHHELD GROUP IS NAMED, BECAUSE LEAVING IT OUT DELETES IT.
        ================================================================================================

        Three places in this function drop keys from a report, and all three are commented as "the
        server treats an absent field as no news and keeps what it has". That was the intention and
        it was not what happened. `Persist.applySnapshot` assigns the snapshot's property table over
        the stored one - `record.properties = patch.properties`, a replacement and not a merge - so a
        key that was left out was a key deleted from the database.

        Which means every guard written to PROTECT a value was quietly destroying it:

          the unverified groups   A restore that could not apply the neons dropped them from the
                                  next report so the failure could not be written down. The failure
                                  was not written down; the value was deleted instead.

          the neons              Withheld until somebody is seen to change them, so that a car
                                  nobody has touched cannot report itself dark. It reported nothing,
                                  and nothing overwrote the player's own setting anyway.

          the server's own guard  `unverifiedNeons` in `applySnapshot` does the same thing to the
                                  same keys, one layer down, with the same result.

        Deformation escaped it because somebody hit this once and wrote a single line by hand to
        carry it across. That line is the correct behaviour for all of them, and this is that line
        generalised: the groups being withheld are NAMED in the snapshot, and the server copies them
        from what it already has.

        Naming them rather than merging everything absent, because absence genuinely means "gone"
        for some keys - `customPrimary` is not sent by a car that is no longer custom-painted, and
        merging it back would repaint the car on its next restore.
    ]]
    local withheld = {}

    --[[
        THE HEALTH IS WITHHELD BY THE SAME TEST AS THE DENTS, BECAUSE IT IS THE SAME NUMBER.

        `recapture` is false while the vehicle's body health is where the restore left it, which
        means nothing has hit it since. Reporting the health then would write down the value the
        restore itself produced - lower than what is stored, because putting a car's own dents,
        broken windows and burst tyres back on it lowers the number - and the next restore would
        start from there. A car parked, passed and restarted often enough walked towards zero.

        The previous attempt at this wrote the stored health back onto the vehicle at the end of
        `Properties.apply`. It flattened the dents, because raising body health smooths bodywork,
        which is the one thing `shared/schema.lua` has said about this group from the start.

        So the vehicle is left alone and the REPORT is what changes. A repair or a real collision
        moves the health by far more than `recaptureDelta` and is reported at once, which is what
        the "a repair is noticed immediately" case tests.
    ]]
    if not recapture then
        withheld.deformation = true
        withheld.health = true
    end

    --[[
        AND AN ANCHOR IS NEVER RAISED BY A CAPTURE.

        `Anchor.stored` reports `true` or nothing, never `false` - see the note at the top of
        `client/anchor.lua`. Nothing is what a boat reports when it is genuinely not anchored AND
        what it reports when this client simply cannot tell: not streamed in far enough, ownership
        somewhere else, or `IsBoatAnchoredAndFrozen` answering only for the frozen variant.

        Since a snapshot REPLACES the stored properties, nothing would delete the anchor - so a
        boat moored on Friday would come up by itself on the first capture that could not see it.
        Naming the group instead means the stored value stands, and the only thing that raises an
        anchor is a person asking for it, which goes straight to `Actions.setAnchor`.
    ]]
    if properties.anchored ~= true then withheld.anchor = true end

    local doubtful = unverified[id]

    if doubtful then
        for group in pairs(doubtful) do
            for _, key in ipairs(Schema.keys[group] or {}) do
                properties[key] = nil
            end
            withheld[group] = true
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
        REPORTED ONLY AFTER SOMEBODY HAS ACTUALLY CHANGED THEM.

        Not "has been driven", and not "somebody is in it". Both of those are true of a player who
        gets in to check whether their neons survived, and reporting then is how the stored value
        was destroyed at the exact moment it was being inspected.

        `neonsChosen` is set by the tick above, and only when the state is observed to MOVE while
        somebody is in the driver's seat. That is the only event in the game that means a person
        decided something about this vehicle's neons.

        Everything else - a restore that did not take, ownership moving, the engine dropping the
        state, which FiveM is known to do when a vehicle is stored and taken out again - leaves the
        stored value alone, and the tick puts the lights back.
    ]]
    if record.neonsChosen ~= true then
        for _, key in ipairs(Schema.keys.neons or {}) do
            properties[key] = nil
        end
        withheld.neons = true
    end

    return {
        id = id,
        properties = properties,
        withheld = next(withheld) and withheld or nil,
        statebags = Properties.captureStatebags(entity),
        position = moved and { x = Park.coord(position.x), y = Park.coord(position.y), z = Park.coord(position.z) } or nil,
        rotation = moved and { x = Park.angle(rotation.x), y = Park.angle(rotation.y), z = Park.angle(rotation.z) } or nil,

        -- Where it is standing while nobody is driving it. See the note above.
        resting = resting and
            { x = Park.coord(resting.x), y = Park.coord(resting.y), z = Park.coord(resting.z) } or nil,
        restingRotation = restingRotation and
            { x = Park.angle(restingRotation.x), y = Park.angle(restingRotation.y),
              z = Park.angle(restingRotation.z) } or nil,
        interior = GetInteriorFromEntity(entity),
        room = GetRoomKeyFromEntity(entity),
        frozen = record.frozen == true,

        -- Fills in `vehicle_type` for a row written before 1.0.4. The server writes it once
        -- and then ignores this field; see `Persist.applySnapshot`.
        vehicleType = GetVehicleType and GetVehicleType(entity) or nil,
    }
end
