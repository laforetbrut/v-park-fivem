--[[
    server/runtime.lua

    Boot order, and the one flag every timer in this resource waits on.

    -------------------------------------------------------------------------------------------
    WHY BOOT ORDER NEEDS A FILE
    -------------------------------------------------------------------------------------------

    Six things have to happen in a fixed order and each one is useless without the one before:

        1. OneSync is checked. Without it, server-created entities do not work, and every
           other step would build a per-client fiction that looks like it works.
        2. The framework is detected. Ownership resolution needs it.
        3. The database driver connects and the schema is built.
        4. The zone list is compiled, including any auto-detected garages - which need the
           framework and the garage resource to be up.
        5. The store is loaded from the database.
        6. Only then do the streaming, save and lifecycle timers start.

    Every timer in this resource begins `while not Runtime.ready() do Wait(500) end`. That one
    line is what makes the order above true rather than aspirational: a sweep that started
    early would run against an empty store and conclude that every vehicle had vanished.

    -------------------------------------------------------------------------------------------
    SHUTDOWN
    -------------------------------------------------------------------------------------------

    `onResourceStop` flushes. It is the single most important five lines in the resource: a
    restart that does not flush loses up to `Config.Save.flushInterval` seconds of every
    vehicle that moved, and the symptom is cars that come back where they were a minute ago.
]]

Runtime = {}

local state = {
    ready = false,
    bootedAt = 0,
    loaded = 0,
    oneSync = false,
    version = 'unknown',
}

function Runtime.ready()
    return state.ready
end

function Runtime.state()
    return state
end

-- ---------------------------------------------------------------------------------------
-- OneSync
-- ---------------------------------------------------------------------------------------

--[[
    Is OneSync on?

    Returns `'on'`, `'off'` or `'unknown'`, and the third value is the reason this function is
    longer than it looks like it should be.

    OneSync is reported under three different convars depending on the build - `onesync_enabled`
    on modern ones, `onesync` carrying a mode name, `onesync_enableInfinity` on older ones - and
    a server that reports it under only one of them still has OneSync.

    More awkwardly, a server that has never SET any of them reads all three as their defaults,
    which is indistinguishable from a server that set them to off. On a current FXServer with a
    valid licence key OneSync is on by default and nothing appears in `server.cfg`, so treating
    "nothing is set" as "off" would refuse to boot on a perfectly good server - which is a worse
    outcome than the problem this check exists to catch.

    So: an explicit off is an off, an explicit on is an on, and silence is `'unknown'` and gets
    a loud warning rather than a refusal.
]]
local function oneSyncState()
    local enabled = GetConvar('onesync_enabled', '')
    local infinity = GetConvar('onesync_enableInfinity', '')
    local mode = GetConvar('onesync', '')

    if enabled == 'true' or infinity == 'true' then return 'on' end
    if mode ~= '' and mode ~= 'off' and mode ~= 'false' then return 'on' end

    -- An explicit off, from whichever convar this build actually uses.
    if enabled == 'false' or mode == 'off' or mode == 'false' then return 'off' end

    return 'unknown'
end

-- ---------------------------------------------------------------------------------------
-- Garage zones
-- ---------------------------------------------------------------------------------------

--[[
    Read the garage list out of whichever garage resource is installed, and turn each into a
    blocked zone.

    This is a READ of another resource's config table through its exports or its shared state.
    It is not a hook, it changes nothing, and when the shape is not what we expect it does
    nothing and says so - rather than silently producing zero zones and leaving an operator
    wondering why cars persist on their garage forecourt.

    Every garage resource stores its list differently, so each is a small adapter.
]]
local GARAGE_READERS = {
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
                local point = Park.toVec(garage.takeVehicle or garage.spawnPoint or garage.coords
                    or garage.location or garage.Location)
                if point then
                    out[#out + 1] = { id = tostring(garage.id or key), label = garage.label or key, point = point }
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

--[[
    Which garage resource is installed, and what it calls its garages.

    Returned as a list of { id, label, point }. The panel uses the ids and labels for its
    "send to garage" dropdown; the zone compiler uses the points.
]]
function Runtime.garages()
    if state.garages then return state.garages end

    local configured = Config.Compat and Config.Compat.garages

    for _, reader in ipairs(GARAGE_READERS) do
        if Park.started(reader.resource) and (configured == 'auto' or configured == reader.resource) then
            local ok, list = pcall(reader.read)

            if ok and type(list) == 'table' and #list > 0 then
                state.garageResource = reader.resource
                state.garages = list
                Park.log('read %d garage(s) from %s', #list, reader.resource)
                return state.garages
            end

            Park.warn('%s is installed but its garage list could not be read', reader.resource)
            Park.warn('add your garages to Config.Zones by hand, and to Config.Panel.garages')
        end
    end

    state.garages = {}
    return state.garages
end

function Runtime.garageResource()
    Runtime.garages()
    return state.garageResource
end

local function compileZones()
    local extra = {}

    if Config.ZoneOptions and Config.ZoneOptions.autoGarages ~= false then
        local radius = tonumber(Config.ZoneOptions.autoGarageRadius) or 25.0

        for _, garage in ipairs(Runtime.garages()) do
            extra[#extra + 1] = {
                type = 'circle',
                name = 'garage: ' .. tostring(garage.label or garage.id),
                centre = garage.point,
                radius = radius,
                source = 'garage',
            }
        end
    end

    local count = Zones.compile(extra)
    Park.log('%d blocked zone(s) compiled (%d from garages)', count, #extra)
end

-- ---------------------------------------------------------------------------------------
-- The banner
-- ---------------------------------------------------------------------------------------

local function banner()
    if not (Config.General and Config.General.banner ~= false) then return end

    local compat = Bridge.summary()
    local store = Store.stats()

    print('^2[v-park]^7 ------------------------------------------------------------')
    print(('^2[v-park]^7 v%s by vyrriox'):format(state.version))
    print(('^2[v-park]^7 framework: ^5%s^7   database: ^5%s^7   keys: ^5%s^7')
        :format(compat.framework, Database.driver(), compat.keys))
    print(('^2[v-park]^7 %d vehicle(s) loaded, %d cell(s), mode ^5%s^7')
        :format(store.total, store.cells, tostring(Config.Persistence and Config.Persistence.mode)))

    if Database.memory() then
        print('^3[v-park]^7 IN MEMORY: nothing will survive a server restart')
    end

    if state.oneSync ~= 'on' then
        print(('^3[v-park]^7 OneSync: %s'):format(tostring(state.oneSync)))
    end

    if state.garageResource then
        print(('^2[v-park]^7 garages: ^5%s^7 (%d)'):format(state.garageResource, #Runtime.garages()))
    end

    print('^2[v-park]^7 /vparkinfo for detail, /vparkadmin for the panel')
    print('^2[v-park]^7 ------------------------------------------------------------')
end

-- ---------------------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------------------

CreateThread(function()
    state.version = GetResourceMetadata(Park.resource, 'version', 0) or 'unknown'

    -- 1. OneSync.
    local oneSync = oneSyncState()
    state.oneSync = oneSync

    if oneSync == 'off' then
        if Config.General and Config.General.requireOneSync ~= false then
            Park.error('OneSync is switched off, and v-park cannot work without it.')
            Park.error('Server-created entities need it; without it nothing would exist for other players.')
            Park.error('Enable OneSync, or set Config.General.requireOneSync = false to start anyway.')
            return
        end

        Park.warn('OneSync is switched off. Running anyway, because the config says to.')
        Park.warn('Expect vehicles that exist for one player and not for others.')

    elseif oneSync == 'unknown' then
        -- Nothing set either way. Almost always a current server with OneSync on by default
        -- and nothing about it in server.cfg, so this warns rather than refusing.
        Park.warn('could not tell whether OneSync is enabled - no onesync convar is set')
        Park.warn('carrying on, because that is the normal state of a server that leaves it at its default')
        Park.warn('if vehicles exist for one player and not for others, that is why')
    end

    -- 2. Framework. Given a moment first: on a cold boot every resource starts in the same
    -- second and qb-core's core object is not ready in ours.
    Wait(1000)
    Bridge.boot()

    -- 3. Database and schema.
    Database.boot()

    -- 4. Zones, which need the garage resource to be up.
    Wait(1000)
    compileZones()

    -- 5. The store.
    state.loaded = Store.load()

    -- 6. Go.
    state.bootedAt = Park.now()
    state.ready = true

    banner()

    if Config.Api and Config.Api.events then
        TriggerEvent('vpark:server:ready', {
            loaded = state.loaded,
            framework = Bridge.kind(),
            database = Database.driver(),
        })
    end
end)

-- ---------------------------------------------------------------------------------------
-- Shutdown
--
-- The most important handler in the resource.
-- ---------------------------------------------------------------------------------------

AddEventHandler('onResourceStop', function(resource)
    if resource ~= Park.resource then return end
    if not state.ready then return end

    -- Everything currently in the world gets its position written down. A vehicle that has
    -- been pushed since its last sweep would otherwise come back where it was a minute ago.
    for id, entry in pairs(Store.allLive()) do
        if entry.entity and DoesEntityExist(entry.entity) then
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
    end

    -- `flushNow`, not `flush`. The awaiting version yields between batches, and a yield
    -- inside onResourceStop can simply never resume - the scheduler is not guaranteed to run
    -- again. See its header.
    local written = Persist.flushNow()
    Park.log('shutting down: %d vehicle(s) handed to the database', written)
end)

AddEventHandler('onResourceStop', function(resource)
    -- Somebody else's resource stopping. If it was our framework or our database, say so
    -- rather than letting the next hundred queries fail quietly.
    if resource == Bridge.resource() then
        Park.warn('%s has stopped - ownership resolution will degrade until it is back', resource)
    end
end)

--[[
    A resource we detected has started after us.

    Re-running detection means a server that starts oxmysql late, or a framework that was
    restarted, does not need v-park restarted too.
]]
AddEventHandler('onResourceStart', function(resource)
    if not state.ready then return end
    if resource == Park.resource then return end

    if resource == Bridge.resource() then
        Park.log('%s restarted - re-detecting the framework', resource)
        Bridge.boot()
    end
end)
