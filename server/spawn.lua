--[[
    server/spawn.lua

    Deciding what exists in the world right now.

    -------------------------------------------------------------------------------------------
    THE WHOLE IDEA
    -------------------------------------------------------------------------------------------

    Nothing is spawned at boot. A database with five thousand vehicles and one player online
    has perhaps thirty entities in the world, and the other four thousand nine hundred and
    seventy are rows.

    That is the difference between this and a script that creates everything and hopes. Server
    entity budgets are finite, every existing entity costs network traffic to every client in
    scope, and the overwhelming majority of a persisted fleet is somewhere nobody is standing.

    Each pass:
        1. Ask each online player's grid neighbourhood what is near them.
        2. Union those into one wanted set, nearest first.
        3. Create up to `spawnsPerPass` that are wanted and not live.
        4. Remove up to `despawnsPerPass` that are live and wanted by nobody.

    All of it under a millisecond budget, yielding when it runs out.

    -------------------------------------------------------------------------------------------
    HYSTERESIS
    -------------------------------------------------------------------------------------------

    `spawnRadius` and `despawnRadius` are different numbers and MUST stay different. A player
    standing exactly on one boundary would otherwise spawn and despawn the same vehicle several
    times a second, each spawn costing a full restore. The hundred-metre gap is about three
    seconds in a fast car, which is the timescale that matters.
]]

Spawn = {}

-- id -> the tick a restore instruction was sent, for vehicles awaiting a client's answer.
local pending = {}

-- ids that failed placement in a way that says "try again later" rather than "give up".
local deferred = {}

-- id -> consecutive creation failures. Cleared on the first success. A vehicle that cannot be
-- created five times running is not going to be created on the sixth, and retrying it every
-- second forever is how one bad row fills a console.
local failures = {}

local stats = {
    spawned = 0,
    despawned = 0,
    failed = 0,
    exact = 0,
    nudged = 0,
    forced = 0,
    grounded = 0,
    passes = 0,
    lastPassMs = 0,
    reconciled = 0,
}

local function streaming()
    return (Config and Config.Streaming) or {}
end

-- ---------------------------------------------------------------------------------------
-- Players
-- ---------------------------------------------------------------------------------------

--[[
    Every online player's position and routing bucket.

    Built fresh each pass rather than cached, because a cached position is a player who
    teleported and whose vehicles are still streaming around where they used to be.

    A player whose ped does not exist yet - still connecting, still in the multicharacter
    screen - is skipped entirely. Their coordinates at that moment are the spawn point, and
    spawning every vehicle near the spawn point for everybody who is loading in is a real and
    unpleasant failure mode.
]]
local function onlinePlayers()
    local out = {}

    for _, src in ipairs(GetPlayers()) do
        src = tonumber(src)
        local ped = GetPlayerPed(src)

        if ped and ped ~= 0 and DoesEntityExist(ped) then
            local position = GetEntityCoords(ped)

            -- The spawn point, near enough. A ped that has not been placed yet reports the
            -- origin or the default spawn, and neither is where the player will be.
            if position and (position.x ~= 0.0 or position.y ~= 0.0) then
                out[#out + 1] = {
                    src = src,
                    x = position.x,
                    y = position.y,
                    z = position.z,
                    bucket = GetPlayerRoutingBucket(src) or 0,
                }
            end
        end
    end

    return out
end

Spawn.onlinePlayers = onlinePlayers

local function radiusFor(record)
    local perClass = streaming().classRadius
    if type(perClass) == 'table' then
        local specific = tonumber(perClass[record.class])
        if specific then return specific end
    end
    return tonumber(streaming().spawnRadius) or 250.0
end

--[[
    The largest radius any vehicle could be wanted at.

    The grid query has to ask for THIS, not for `spawnRadius`, because the per-class radius is
    applied afterwards as a narrowing filter. A class radius larger than the global one would
    otherwise do nothing at all: the query would already have cut the set at the smaller
    distance, and a filter can only ever remove more.

    Cached, because it is read once per player per pass and the config does not change between
    them. A resource restart rebuilds it.
]]
local queryRadiusCache

local function queryRadius()
    if queryRadiusCache then return queryRadiusCache end

    local largest = tonumber(streaming().spawnRadius) or 250.0

    local perClass = streaming().classRadius
    if type(perClass) == 'table' then
        for _, value in pairs(perClass) do
            local radius = tonumber(value)
            if radius and radius > largest then largest = radius end
        end
    end

    queryRadiusCache = largest
    return largest
end

function Spawn.invalidateRadius()
    queryRadiusCache = nil
end

-- ---------------------------------------------------------------------------------------
-- Creating
-- ---------------------------------------------------------------------------------------

--[[
    Nominate the client that will dress and place a vehicle.

    The nearest player, because they are the one whose machine certainly has the map streamed
    in around it - which is what every placement decision needs. A distant client would answer
    "the space is free" for an area it cannot see.
]]
local function nominate(record, players)
    local best, bestDistance

    for _, player in ipairs(players) do
        if player.bucket == record.bucket then
            local dx, dy = player.x - record.pos_x, player.y - record.pos_y
            local distance = dx * dx + dy * dy
            if not bestDistance or distance < bestDistance then
                best, bestDistance = player, distance
            end
        end
    end

    return best
end

--[[
    Create one vehicle in the world.

    Returns the entity, or nil.

    THE ORPHAN MODE LINE IS LICENCE TO EXIST. Without it the engine deletes a server-created
    entity as soon as no player is near it, which is a spawn-delete loop at our own radius
    boundary: we create it because a player is 240 metres away, the engine collects it because
    no client has it in scope, we create it again on the next pass. Orphan mode 2 means the
    entity lives until we say otherwise.

    It degrades silently on a build without the native, and the symptom there is vehicles that
    occasionally have to be re-created - wasteful, not broken.
]]
function Spawn.create(record, players)
    if record.invalidModel then return nil end
    if Store.isLive(record.id) then return nil end
    if pending[record.id] then return nil end

    -- Nominated BEFORE anything is created. An early return after `CreateVehicle` has to
    -- delete what it made, and the cheapest way not to get that wrong is to have nothing to
    -- delete.
    local placer = nominate(record, players or onlinePlayers())
    if not placer then return nil end

    local entity = CreateVehicle(
        record.model,
        record.pos_x, record.pos_y, record.pos_z,
        record.rot_z,
        true,   -- networked
        true    -- script-owned, so the engine does not treat it as ambient
    )

    --[[
        A HANDLE OF ZERO IS THE ONLY FAILURE. `DoesEntityExist` IS NOT ASKED HERE.

        This is the bug that multiplied vehicles across a live server, and it is worth stating
        exactly.

        `CreateVehicle` returns a handle immediately, but the entity is not registered
        synchronously: `DoesEntityExist` on that handle answers FALSE for a tick or two
        afterwards. The first version treated that as a failed creation, logged a warning, and
        returned - WITHOUT DELETING the entity it had just successfully created.

        So every pass created another one. And because `SetEntityOrphanMode(entity, 2)` tells
        the engine to keep an entity nobody is near, none of them were ever collected. The
        server filled with copies of the same car until it hit its entity limit, at which point
        `CreateVehicle` really did start returning zero and the console filled with

            WARN: could not create vehicle 0TL0UEP01QT7G (model BISON)

        several times a second. The warning was true by then; it was a symptom, not the cause.

        A zero handle is a genuine failure and nothing was created. Anything else IS created and
        is ours to manage - including ours to delete if we then decide not to keep it, which is
        what every early return below does.
    ]]
    if not entity or entity == 0 then
        failures[record.id] = (failures[record.id] or 0) + 1
        stats.failed = stats.failed + 1

        -- Logged once per vehicle rather than once per attempt. The old code warned on every
        -- pass, which on a full entity pool is a wall of identical lines that hides the one
        -- line that would have explained it.
        if failures[record.id] == 1 then
            Park.warn('could not create vehicle %s (model %s)',
                record.id, tostring(record.model_name or record.model))
        end

        if failures[record.id] >= 5 then
            Park.error('%s (%s) failed to create %d times - it will not be retried this session',
                record.id, tostring(record.model_name or record.model), failures[record.id])
            Park.error('the usual causes are an entity limit already reached, or a model this build does not have')
            record.invalidModel = true
        end

        -- Back off regardless. Retrying the same creation on the very next pass, every pass,
        -- is how a single failing vehicle becomes a wall of console output.
        deferred[record.id] = Park.ticks() + 10000
        return nil
    end

    failures[record.id] = nil

    -- Everything the server can set, set before any client is told about it.
    SetEntityRoutingBucket(entity, record.bucket or 0)

    -- Full rotation, and never a heading afterwards. See the note in client/placement.lua:
    -- setting the heading would flatten the pitch a car parked on a slope actually has.
    SetEntityCoords(entity, record.pos_x, record.pos_y, record.pos_z, false, false, false, false)
    SetEntityRotation(entity, record.rot_x, record.rot_y, record.rot_z, 2, true)

    local entityConfig = streaming().entity or {}

    if entityConfig.orphanMode ~= false and SetEntityOrphanMode then
        -- 2: keep the entity even when no player is near it. We decide when it goes.
        pcall(SetEntityOrphanMode, entity, 2)
    end

    local culling = tonumber(entityConfig.cullingRadius) or 0
    if culling > 0 and SetEntityDistanceCullingRadius then
        pcall(SetEntityDistanceCullingRadius, entity, culling)
    end

    local netId = NetworkGetNetworkIdFromEntity(entity)

    --[[
        No network id, no way for a client to find it.

        The restore instruction is addressed by network id, so an entity without one can never
        be dressed or placed - it would sit in the world as an undressed, unplaced copy that
        nothing owns. That is the same shape as the duplication bug, so it gets the same
        answer: delete what we made and report it, rather than leaving it behind.
    ]]
    if not netId or netId == 0 then
        Park.warn('%s was created but has no network id - removing it', record.id)
        DeleteEntity(entity)
        stats.failed = stats.failed + 1
        deferred[record.id] = Park.ticks() + 10000
        return nil
    end

    local state = Entity(entity).state

    -- The id is replicated to everybody in scope. It is how a client knows this entity is
    -- ours - the placement code refuses to delete a vehicle carrying one, and the panel and
    -- the API both resolve an entity to a record through it.
    state:set('vpark:id', record.id, true)

    if record.plate then
        state:set('vpark:plate', record.plate, true)
    end

    -- Deformation is applied by EVERY client, locally, which is what makes two players see
    -- the same dents. Hence a replicated bag rather than a targeted event.
    local deformation = record.properties and record.properties.deformation
    if deformation and Config.Deformation and Config.Deformation.enabled ~= false then
        state:set('vpark:deform', {
            v = record.updated_at,
            d = deformation.d,
            g = deformation.g,
        }, true)
    end

    -- Statebags another resource expects on the vehicle. Set server-side because a replicated
    -- bag can only be written by the server or the entity's owner, and at this moment there
    -- is no owner.
    if record.statebags and Config.Save and Config.Save.fields and Config.Save.fields.statebags ~= false then
        for key, value in pairs(record.statebags) do
            local ok = pcall(function() state:set(key, value, true) end)
            if not ok then
                Park.debug('could not restore statebag `%s` on %s', tostring(key), record.id)
            end
        end
    end

    Store.setLive(record.id, {
        entity = entity,
        netId = netId,
        placer = placer.src,
        placedAt = Park.ticks(),
    })

    pending[record.id] = Park.ticks()

    TriggerClientEvent('vpark:client:restore', placer.src, netId, {
        id = record.id,
        version = record.updated_at,
        position = { x = record.pos_x, y = record.pos_y, z = record.pos_z },
        rotation = { x = record.rot_x, y = record.rot_y, z = record.rot_z },
        class = record.class,
        interior = record.interior,
        room = record.room,
        frozen = true,
        properties = record.properties,
    })

    stats.spawned = stats.spawned + 1
    Park.debug('created %s (%s) for player %d', record.id, tostring(record.model_name), placer.src)

    Ownership.onRestored(record, entity, netId)

    return entity
end

-- ---------------------------------------------------------------------------------------
-- Removing
-- ---------------------------------------------------------------------------------------

--[[
    Take a vehicle out of the world without forgetting it.

    Despawning is NOT deleting: the row stays, and the vehicle comes back the moment somebody
    walks near it. The distinction matters enough that the two live in different files -
    `server/lifecycle.lua` is the one that can actually remove a vehicle from existence.
]]
function Spawn.despawn(id, reason)
    local entry = Store.live(id)
    if not entry then return false end

    -- One last read of where it actually ended up. A vehicle that was pushed, or that settled
    -- differently from where we placed it, should be written down before it goes away - or the
    -- next restore puts it back at a position that is a restart out of date.
    local record = Store.get(id)
    if record and entry.entity and DoesEntityExist(entry.entity) then
        local position = GetEntityCoords(entry.entity)
        local rotation = GetEntityRotation(entry.entity)

        if position and (position.x ~= 0.0 or position.y ~= 0.0) then
            Store.update(id, {
                pos_x = Park.coord(position.x),
                pos_y = Park.coord(position.y),
                pos_z = Park.coord(position.z),
                rot_x = Park.angle(rotation.x),
                rot_y = Park.angle(rotation.y),
                rot_z = Park.angle(rotation.z),
            })
        end
    end

    if entry.placer then
        TriggerClientEvent('vpark:client:forget', entry.placer, id)
    end

    if entry.entity and DoesEntityExist(entry.entity) then
        DeleteEntity(entry.entity)
    end

    Store.setLive(id, nil)
    pending[id] = nil

    stats.despawned = stats.despawned + 1
    Park.trace('despawned %s (%s)', id, reason or 'out of range')

    return true
end

-- ---------------------------------------------------------------------------------------
-- The pass
-- ---------------------------------------------------------------------------------------

local function wantedSet(players)
    local wanted = {}
    local order = {}

    local perPlayer = tonumber(streaming().maximumPerPlayer) or 0

    for _, player in ipairs(players) do
        local bucket = streaming().matchRoutingBucket ~= false and player.bucket or nil

        local candidates = Store.near(player.x, player.y, queryRadius(), bucket)

        -- Per-player cap, applied after sorting so the cap keeps the NEAREST rather than
        -- whichever the grid happened to iterate first.
        if perPlayer > 0 and #candidates > perPlayer then
            table.sort(candidates, function(a, b) return a.distanceSq < b.distanceSq end)
            for i = #candidates, perPlayer + 1, -1 do candidates[i] = nil end
        end

        for _, candidate in ipairs(candidates) do
            local record = candidate.record

            -- The per-class radius is applied here rather than in the query, because the
            -- query radius has to be the largest of them and the narrowing is per record.
            if candidate.distanceSq <= radiusFor(record) ^ 2 then
                local existing = wanted[record.id]
                if not existing then
                    wanted[record.id] = candidate.distanceSq
                    order[#order + 1] = record
                elseif candidate.distanceSq < existing then
                    wanted[record.id] = candidate.distanceSq
                end
            end
        end
    end

    if streaming().nearestFirst ~= false then
        table.sort(order, function(a, b)
            return (wanted[a.id] or math.huge) < (wanted[b.id] or math.huge)
        end)
    end

    return wanted, order
end

local function pass()
    local started = Park.ticks()
    local budget = tonumber(Config.Performance and Config.Performance.streamBudgetMs) or 3

    local players = onlinePlayers()

    if #players == 0 then
        -- Nobody online. Everything live is by definition wanted by nobody, and clearing it
        -- costs nothing and frees the entity budget for the next player to join.
        for id in pairs(Store.allLive()) do
            Spawn.despawn(id, 'no players online')
        end
        return
    end

    -- ------------------------------------------------------------- timeouts FIRST ---
    --
    -- Before anything else, and before the early return at the entity ceiling below, because
    -- this is the sweep that releases a leaked entity.
    --
    -- A vehicle whose nominated client never answered is still `live` and still `pending`.
    -- Clearing the pending flag without despawning it would leave the entity in the world,
    -- undressed and unplaced, forever - and once enough of those accumulate, `liveCount` hits
    -- the ceiling, the pass returns early, and this sweep never runs again. The resource stops
    -- spawning anything, permanently, with nothing in the console to say why.
    for id, sentAt in pairs(pending) do
        if Park.ticks() - sentAt > 20000 then
            pending[id] = nil
            Park.debug('no placement answer for %s after 20s - removing it and re-nominating', id)
            Spawn.despawn(id, 'no placement answer')
            stats.failed = stats.failed + 1
        end
    end

    -- ONE call, not two. An earlier draft asked for the wanted set here and asked again
    -- before the spawn loop, which built the whole candidate list twice per pass - a grid
    -- query per player, a sort, and an allocation, every second, for an answer it already
    -- had.
    local wanted, order = wantedSet(players)

    -- ------------------------------------------------------------------ despawn ---
    local despawnRadius = tonumber(streaming().despawnRadius) or 350.0
    local despawnBudget = tonumber(streaming().despawnsPerPass) or 20
    local despawned = 0

    for id in pairs(Store.allLive()) do
        if despawned >= despawnBudget then break end
        if not wanted[id] then
            local record = Store.get(id)

            if not record then
                Spawn.despawn(id, 'no record')
                despawned = despawned + 1
            else
                -- Wanted-set membership uses the spawn radius; the despawn radius is larger,
                -- so a vehicle can be unwanted and still inside the hysteresis band. Only the
                -- ones past the outer boundary actually go.
                local nearest = math.huge
                for _, player in ipairs(players) do
                    local dx, dy = player.x - record.pos_x, player.y - record.pos_y
                    local distance = dx * dx + dy * dy
                    if distance < nearest then nearest = distance end
                end

                if nearest > despawnRadius * despawnRadius then
                    Spawn.despawn(id, 'out of range')
                    despawned = despawned + 1
                end
            end
        end
    end

    -- ---------------------------------------------------------------- entity cap ---
    local maximumEntities = tonumber(streaming().maximumEntities) or 400
    if maximumEntities > 0 and Store.liveCount() >= maximumEntities then
        Park.trace('the entity ceiling of %d is reached; not creating any more this pass', maximumEntities)
        stats.lastPassMs = Park.ticks() - started
        return
    end

    -- -------------------------------------------------------------------- spawn ---
    local spawnBudget = tonumber(streaming().spawnsPerPass) or 6
    local created = 0

    --[[
        `attempted`, not `created`.

        The budget used to count successes, so a pass in which every creation FAILED counted
        zero and carried on down the whole candidate list - hundreds of attempts per second,
        each one logging. Counting attempts means a pass costs at most `spawnsPerPass` calls
        whether they work or not, which is what a budget is for.
    ]]
    local attempted = 0

    for _, record in ipairs(order) do
        if attempted >= spawnBudget then break end
        if Park.ticks() - started > budget then break end
        if Store.liveCount() >= maximumEntities and maximumEntities > 0 then break end

        if not Store.isLive(record.id) and not pending[record.id] then
            -- A vehicle that asked to be retried is retried, but not on the very next pass:
            -- whatever was blocking it a second ago is probably still there.
            local retryAt = deferred[record.id]
            if not retryAt or Park.ticks() > retryAt then
                deferred[record.id] = nil
                attempted = attempted + 1

                if Spawn.create(record, players) then
                    created = created + 1
                end
            end
        end
    end

    stats.passes = stats.passes + 1
    stats.lastPassMs = Park.ticks() - started
end

CreateThread(function()
    -- Nothing until the store is loaded and the framework has had a chance to come up.
    while not Runtime.ready() do Wait(500) end

    while true do
        Wait(tonumber(streaming().interval) or 1000)

        local ok, err = pcall(pass)
        if not ok then
            Park.error('the streaming pass raised: %s', tostring(err))
            -- Back off rather than raising once a second forever.
            Wait(5000)
        end
    end
end)

-- ---------------------------------------------------------------------------------------
-- Client answers
-- ---------------------------------------------------------------------------------------

--[[
    A client has finished placing a vehicle.

    The interesting part is `result.position`: the placement engine may have moved the vehicle
    to make it fit, and if it did, that is now where the vehicle IS and the row has to agree -
    otherwise the next restore puts it back at the blocked pose and moves it again, every
    restart, drifting a little each time.
]]
RegisterNetEvent('vpark:server:restored', function(id, result)
    local src = source
    pending[id] = nil

    if type(id) ~= 'string' or type(result) ~= 'table' then return end

    local entry = Store.live(id)
    if not entry or entry.placer ~= src then
        -- An answer from a client we did not ask. Not necessarily malicious - a re-nomination
        -- races with a late answer from the previous one - but not something to act on.
        return
    end

    if not result.ok then
        if result.retry then
            deferred[id] = Park.ticks() + 15000
        end

        Park.debug('placement of %s failed: %s', id, tostring(result.reason))
        Spawn.despawn(id, 'placement failed')
        stats.failed = stats.failed + 1
        return
    end

    entry.placedAt = Park.ticks()
    entry.frozen = result.frozen

    if result.outcome then
        stats[result.outcome] = (stats[result.outcome] or 0) + 1
    end

    if result.moved and type(result.position) == 'table' then
        Store.update(id, {
            pos_x = result.position.x,
            pos_y = result.position.y,
            pos_z = result.position.z,
            rot_z = result.heading or 0.0,
        })

        Park.debug('%s was moved to fit and its stored position was corrected', id)
    end
end)

RegisterNetEvent('vpark:server:restoreFailed', function(id, reason)
    pending[id] = nil
    if type(id) ~= 'string' then return end

    Park.debug('client could not restore %s: %s', id, tostring(reason))
    Spawn.despawn(id, 'client failed')
    stats.failed = stats.failed + 1
end)

--[[
    A player interacted with a vehicle.

    `used` distinguishes SITTING IN IT from merely interacting with it, and the distinction is
    the whole basis of Section 9c. `touched_at` moves for anything; `last_used_at` moves only
    when a person got in. A car parked outside its owner's house is touched constantly and has
    not been driven since March, and one column cannot answer both questions.

    Written as a targeted update rather than through the dirty queue, because both columns are
    deliberately outside the delta hash - see `Store.hashOf` - and marking the whole row dirty
    for a timestamp would defeat the point of the hash.
]]
RegisterNetEvent('vpark:server:touched', function(id, used)
    if type(id) ~= 'string' then return end

    local record = Store.get(id)
    if not record then return end

    local now = Park.now()
    record.touched_at = now

    -- Being touched also resets the semi-persistence countdown: somebody is using it.
    if record.offline_secs and record.offline_secs > 0 then
        record.offline_secs = 0
    end

    local sql, params

    if used then
        record.last_used_at = now
        record.warnedCleanup = nil

        sql = ('UPDATE %s SET `touched_at` = ?, `last_used_at` = ?, `offline_secs` = 0 WHERE `id` = ?')
            :format(Database.table('vehicles'))
        params = { now, now, id }
    else
        sql = ('UPDATE %s SET `touched_at` = ?, `offline_secs` = 0 WHERE `id` = ?')
            :format(Database.table('vehicles'))
        params = { now, id }
    end

    if Database.available() then
        Database.thread(function()
            Database.execute(sql, params)
        end)
    end
end)

--[[
    Delete every vehicle in the world that carries one of our ids and is not the entity we
    have registered for it.

    -------------------------------------------------------------------------------------------
    WHAT THIS IS FOR
    -------------------------------------------------------------------------------------------

    Two things, and the second is why it exists at all.

    ORPHANS. An entity we created and then lost track of - because a creation was misjudged as
    a failure, because a resource restart dropped the live table while the entities survived
    `SetEntityOrphanMode(2)`, or because something else deleted our record and not our entity.
    Nothing else will ever collect these: orphan mode is precisely an instruction not to.

    DUPLICATES. Several entities carrying the SAME `vpark:id`. That is the shape the
    multiplication bug took, and it is the one an operator actually sees: four Bisons in one
    parking space. The registered entity survives, every other copy goes.

    It runs on its own slow timer and at boot, and it is cheap: one pass over the server's
    vehicle list, a statebag read each. On a server with four hundred vehicles that is four
    hundred reads every thirty seconds.
]]
function Spawn.reconcile()
    if not GetAllVehicles then return 0 end

    local ok, all = pcall(GetAllVehicles)
    if not ok or type(all) ~= 'table' then return 0 end

    local removed = 0
    local duplicates = 0
    local orphans = 0

    for index = 1, #all do
        local entity = all[index]

        if entity and entity ~= 0 and DoesEntityExist(entity) then
            local id
            local read = pcall(function() id = Entity(entity).state['vpark:id'] end)

            if read and type(id) == 'string' then
                local record = Store.get(id)
                local live = Store.live(id)

                if not record then
                    -- Ours by its statebag, unknown to the store. Nothing will ever claim it.
                    orphans = orphans + 1
                    DeleteEntity(entity)
                    removed = removed + 1

                elseif not live then
                    -- The record exists but we have no entity registered for it, so this one
                    -- is left over. Adopting it would be tempting and wrong: it has not been
                    -- dressed or placed, and we cannot tell whether it ever was.
                    orphans = orphans + 1
                    DeleteEntity(entity)
                    removed = removed + 1

                elseif live.entity ~= entity then
                    -- A second copy of a vehicle we already have. THE ONE AN OPERATOR SEES.
                    duplicates = duplicates + 1
                    DeleteEntity(entity)
                    removed = removed + 1
                end
            end
        end

        -- Yield periodically. A server at its entity limit has a long list here, and this
        -- runs on a timer rather than in response to anything urgent.
        if index % 200 == 0 then Wait(0) end
    end

    if removed > 0 then
        Park.warn('reconciliation removed %d stray vehicle(s): %d orphan(s), %d duplicate(s)',
            removed, orphans, duplicates)
        stats.reconciled = (stats.reconciled or 0) + removed
    end

    return removed
end

CreateThread(function()
    while not Runtime.ready() do Wait(500) end

    -- Once at boot, before the first streaming pass, so a restart that left entities behind
    -- starts clean rather than adding to them.
    Wait(2000)
    pcall(Spawn.reconcile)

    while true do
        Wait((tonumber(streaming().reconcileInterval) or 30) * 1000)
        pcall(Spawn.reconcile)
    end
end)

function Spawn.stats()
    return stats
end

function Spawn.pending()
    return pending
end
