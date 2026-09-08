--[[
    bridge/client/compat.lua

    Runtime detection of everything optional, on the client side.

    Loaded FIRST of the client files, because every one below it asks this what is installed.
    No file above this one names a resource: they call `Compat.notify(...)`, `Compat.fuel(...)`
    and so on, and this file decides what that means on this server.

    -------------------------------------------------------------------------------------------
    THE DETECTION CONTRACT
    -------------------------------------------------------------------------------------------

    Detection runs once, lazily, on first use rather than at load. A resource that starts
    after us must still be found, and `GetResourceState` at file-load time reports 'starting'
    for half of them.

    Anything not found degrades to a working fallback. There is no path through this file that
    produces an error because something is absent, and `/vparkinfo` prints what was chosen so
    that "it is not notifying" has a one-command answer.
]]

Compat = {}

local detected = {}     -- capability -> resolved provider name, or false for "none found"

local function forced(key)
    local value = Config and Config.Compat and Config.Compat[key]
    if type(value) ~= 'string' or value == '' or value == 'auto' then return nil end
    return value
end

--[[
    The configured resource name for a known dependency, or its standard name.

    Exists so an operator who renamed `ox_lib` to `ox_lib_v3` has one line to change rather
    than a search-and-replace through the resource.
]]
local function resourceName(key, fallback)
    local named = Config and Config.Compat and Config.Compat.resources and Config.Compat.resources[key]
    if type(named) == 'string' and named ~= '' then return named end
    return fallback
end

--[[
    First started resource from a list, or nil.
]]
local function firstStarted(candidates)
    for _, name in ipairs(candidates) do
        if Park.started(name) then return name end
    end
    return nil
end

-- ---------------------------------------------------------------------------------------
-- Framework
--
-- The client needs far less from a framework than the server does: whether the character is
-- loaded, and what job they hold for the permission-shaped bits of the UI. Everything that
-- matters is decided server-side.
-- ---------------------------------------------------------------------------------------

local frameworkObject
local frameworkKind

local FRAMEWORKS = {
    { kind = 'qbx', resource = function() return resourceName('qbx', 'qbx_core') end },
    { kind = 'qb',  resource = function() return resourceName('qb', 'qb-core') end },
    { kind = 'ox',  resource = function() return resourceName('ox', 'ox_core') end },
    { kind = 'esx', resource = function() return resourceName('esx', 'es_extended') end },
}

local function resolveFramework()
    if frameworkKind ~= nil then return end

    local force = forced('framework')
    if force == 'standalone' then
        frameworkKind = false
        return
    end

    for _, entry in ipairs(FRAMEWORKS) do
        local resource = entry.resource()

        if (not force or force == entry.kind) and Park.started(resource) then
            local object

            if entry.kind == 'qb' or entry.kind == 'qbx' then
                object = Park.try(function() return exports[resource]:GetCoreObject() end)
            elseif entry.kind == 'esx' then
                -- ESX has published three different ways to get its object over the years.
                -- The export is the current one; the event is what most servers still run.
                object = Park.try(function() return exports[resource]:getSharedObject() end)
                if type(object) ~= 'table' then
                    TriggerEvent('esx:getSharedObject', function(shared) object = shared end)
                end
            elseif entry.kind == 'ox' then
                -- ox_core's core object IS its exports table. There is nothing to fetch.
                object = exports[resource]
            end

            if object ~= nil then
                frameworkObject = object
                frameworkKind = entry.kind
                Park.debug('framework detected: %s (%s)', entry.kind, resource)
                return
            end
        end
    end

    if force then
        Park.warn("Config.Compat.framework is '%s' but that framework was not found - running standalone", force)
    end

    frameworkKind = false
end

function Compat.framework()
    resolveFramework()
    return frameworkKind or 'standalone'
end

function Compat.core()
    resolveFramework()
    return frameworkObject
end

--[[
    Is the character loaded?

    Used to hold back the first streaming handshake until the player actually exists. Joining
    a qb-core server puts you in a spectator camera for several seconds during which
    `PlayerPedId()` is valid, `GetEntityCoords` answers, and every one of those answers is a
    lie about where the character will be.

    Standalone has no such state, so it answers true once the ped exists and is not the
    initial dummy.
]]
function Compat.characterLoaded()
    resolveFramework()

    if frameworkKind == 'qb' or frameworkKind == 'qbx' then
        local data = Park.try(function() return frameworkObject.Functions.GetPlayerData() end)
        return type(data) == 'table' and data.citizenid ~= nil
    end

    if frameworkKind == 'esx' then
        local data = Park.try(function() return frameworkObject.GetPlayerData() end)
        return type(data) == 'table' and (data.identifier ~= nil or data.job ~= nil)
    end

    if frameworkKind == 'ox' then
        local loaded = Park.try(function() return exports[resourceName('ox', 'ox_core')]:GetPlayerData() end)
        return type(loaded) == 'table' and loaded.charId ~= nil
    end

    local ped = PlayerPedId()
    return ped ~= 0 and DoesEntityExist(ped)
end

-- ---------------------------------------------------------------------------------------
-- Notifications
-- ---------------------------------------------------------------------------------------

--[[
    Order matters, and it is deliberate.

    v-hud first: a server running it has already chosen a notification style, per player, in
    that resource's own settings menu. Putting our messages anywhere else means two visual
    languages on one screen, and the player's theme choice silently not applying to us.

    Then ox_lib, then okokNotify, then the framework's own, then our native toast.
]]
local NOTIFY_PROVIDERS = {
    { key = 'v-hud',  test = function() return Park.started('v-hud') end },
    { key = 'ox_lib', test = function() return Park.started(resourceName('oxLib', 'ox_lib')) end },
    { key = 'okok',   test = function() return Park.started('okokNotify') end },
    { key = 'qb',     test = function() return Park.started(resourceName('qb', 'qb-core'))
                                            or Park.started(resourceName('qbx', 'qbx_core')) end },
    { key = 'esx',    test = function() return Park.started(resourceName('esx', 'es_extended')) end },
}

local function resolveNotify()
    if detected.notify ~= nil then return detected.notify end

    local force = forced('notify')
    if force then
        detected.notify = force
        return detected.notify
    end

    for _, provider in ipairs(NOTIFY_PROVIDERS) do
        if provider.test() then
            detected.notify = provider.key
            return detected.notify
        end
    end

    detected.notify = 'native'
    return detected.notify
end

--[[
    Show a message. `kind` is 'success', 'error', 'warn' or 'info'.

    Every provider is called through pcall. A notification system that changed its signature
    must not be able to break a save confirmation - the vehicle was saved either way, and the
    player finding out is the less important half.
]]
function Compat.notify(message, kind)
    if not (Config and Config.Notify and Config.Notify.enabled) then return end
    if type(message) ~= 'string' or message == '' then return end

    kind = kind or 'info'
    local duration = (Config.Notify.duration) or 4000
    local provider = resolveNotify()

    if provider == 'v-hud' then
        -- v-hud's kinds are primary | success | error. 'warn' and 'info' have no direct
        -- equivalent, so they map to the two that read closest rather than being dropped.
        local mapped = kind
        if kind == 'warn' then mapped = 'error'
        elseif kind == 'info' then mapped = 'primary' end

        if pcall(function()
            exports['v-hud']:Notify(message, mapped, duration)
        end) then return end
    elseif provider == 'ox_lib' then
        local ok = pcall(function()
            exports[resourceName('oxLib', 'ox_lib')]:notify({
                title = 'v-park',
                description = message,
                type = kind == 'warn' and 'warning' or kind,
                duration = duration,
            })
        end)
        if ok then return end
    elseif provider == 'okok' then
        if pcall(function()
            exports['okokNotify']:Alert('v-park', message, duration, kind == 'warn' and 'warning' or kind)
        end) then return end
    elseif provider == 'qb' then
        -- qb-core's own event, which every qb build has, rather than the export that only
        -- some of them do.
        if pcall(function()
            TriggerEvent('QBCore:Notify', message, kind == 'warn' and 'error' or kind, duration)
        end) then return end
    elseif provider == 'esx' then
        if pcall(function()
            TriggerEvent('esx:showNotification', message)
        end) then return end
    end

    -- The native fallback, and the last resort for every provider above that threw.
    Compat.nativeNotify(message, kind)
end

--[[
    The built-in toast, drawn with the game's own notification system.

    Not a NUI, not a DrawText loop: `SetNotificationTextEntry` puts it in the same feed the
    game uses for its own messages, so it stacks and expires without this resource having to
    own a thread.
]]
function Compat.nativeNotify(message, kind)
    local prefix = '~s~'
    if kind == 'success' then prefix = '~g~'
    elseif kind == 'error' then prefix = '~r~'
    elseif kind == 'warn' then prefix = '~y~' end

    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(prefix .. message)
    EndTextCommandThefeedPostTicker(false, true)
end

-- ---------------------------------------------------------------------------------------
-- Fuel
--
-- The one property half the ecosystem stores outside the vehicle. Three mechanisms exist:
--
--   1. The game's own `GetVehicleFuelLevel`, which most fuel resources also keep in sync.
--   2. A statebag on the entity, which is what everything written since about 2022 uses.
--   3. A resource export, which is what LegacyFuel and its forks use.
--
-- We read all three in that order of trust and write all three, because a server running
-- ox_fuel and a legacy garage script needs both to agree.
-- ---------------------------------------------------------------------------------------

--[[
    rcore_fuel is FIRST, and that is not alphabetical.

    It is the one provider in this list that actively reconciles the fuel level on its own
    tick: a level written through the native or through a statebag it does not recognise is
    overwritten from its own store within a second or two. Detected second, we would write the
    right number, it would write over it, and the vehicle would come back with a tank that had
    nothing to do with what was saved.

    So when rcore_fuel is installed, its export IS the fuel level, and everything else is a
    best-effort echo written alongside it for the HUDs that read the native.
]]
local FUEL_PROVIDERS = {
    { key = 'rcore_fuel',     resource = 'rcore_fuel',     export = 'GetFuel', setter = 'SetFuel', statebag = 'fuel' },
    { key = 'ox_fuel',        resource = 'ox_fuel',        statebag = 'fuel' },
    { key = 'LegacyFuel',     resource = 'LegacyFuel',     export = 'GetFuel', setter = 'SetFuel' },
    { key = 'ps-fuel',        resource = 'ps-fuel',        export = 'GetFuel', setter = 'SetFuel' },
    { key = 'cdn-fuel',       resource = 'cdn-fuel',       export = 'GetFuel', setter = 'SetFuel' },
    { key = 'lj-fuel',        resource = 'lj-fuel',        export = 'GetFuel', setter = 'SetFuel' },
    { key = 'x-fuel',         resource = 'x-fuel',         export = 'GetFuel', setter = 'SetFuel' },
    { key = 'qs-fuelstations',resource = 'qs-fuelstations',export = 'GetFuel', setter = 'SetFuel' },
    { key = 'okokGasStation', resource = 'okokGasStation', statebag = 'fuel' },
    { key = 'qb-fuel',        resource = 'qb-fuel',        export = 'GetFuel', setter = 'SetFuel' },
}

local fuelProvider

local function resolveFuel()
    if fuelProvider ~= nil then return fuelProvider end

    local force = forced('fuel')

    if force == 'none' or force == 'native' then
        fuelProvider = { key = force }
        return fuelProvider
    end

    for _, provider in ipairs(FUEL_PROVIDERS) do
        if (not force or force == provider.key) and Park.started(provider.resource) then
            fuelProvider = provider
            Park.debug('fuel provider detected: %s', provider.key)
            return fuelProvider
        end
    end

    fuelProvider = { key = 'native' }
    return fuelProvider
end

--[[
    The statebag key to read and write, which the config can override for a resource we do
    not know about. That one line is the whole of "supports every fuel script".
]]
local function fuelStatebagKey()
    local configured = Config and Config.Compat and Config.Compat.fuelStatebag
    if type(configured) == 'string' and configured ~= '' then return configured end
    local provider = resolveFuel()
    return provider.statebag
end

--[[
    Read the fuel level, from the most authoritative source available.

    The order is: the provider's own export, then the statebag, then the native. That order is
    the opposite of what it was in the first draft, and the reason is rcore_fuel: a resource
    that keeps its own store and reconciles the statebag on a tick will, in the window between
    a refuel and its next tick, have a statebag that is stale by up to a full tank. The export
    is never stale, because it is what the tick reads from.

    For a provider with no export - ox_fuel, okokGasStation - the statebag IS the store, and
    the first branch simply does not apply.
]]
function Compat.getFuel(vehicle)
    if not DoesEntityExist(vehicle) then return nil end

    local provider = resolveFuel()

    if provider.export then
        local value = Park.try(function() return exports[provider.resource][provider.export](nil, vehicle) end)
        if type(value) == 'number' and value >= 0 then return Park.round(value, 2) end
    end

    local key = fuelStatebagKey()
    if key then
        local value = Entity(vehicle).state[key]
        if type(value) == 'number' and value >= 0 then return Park.round(value, 2) end
    end

    local native = GetVehicleFuelLevel(vehicle)
    if type(native) == 'number' and native >= 0 then return Park.round(native, 2) end

    return nil
end

--[[
    Write the fuel level everywhere that might be read.

    All three, always, and in this order: the native and the decor first, then the statebag,
    then the provider's setter. The setter goes last because it is the one whose write the
    provider itself will honour, and anything written after it is what a competing resource
    would see.

    `_Fuel_Level` is a decor rather than a statebag and it is set unconditionally. It is what
    LegacyFuel and every fork of it reads, it is what several HUDs read, and setting a decor
    on a vehicle that has no such decor registered is a no-op rather than an error.

    THE RE-ASSERT. A provider that reconciles on a timer - rcore_fuel is the one this was
    written for - can overwrite our value with its own stored one within a second or two of a
    vehicle being created, because from its point of view a brand new entity has no record and
    defaults. So for a provider with a setter, the write is repeated once after a delay. It is
    one extra call per restored vehicle and it is the difference between a saved tank and a
    default one.
]]
function Compat.setFuel(vehicle, level)
    if not DoesEntityExist(vehicle) then return false end
    if type(level) ~= 'number' then return false end

    level = Park.clamp(level, 0.0, 100.0)

    local function write()
        if not DoesEntityExist(vehicle) then return end

        SetVehicleFuelLevel(vehicle, level + 0.0)
        DecorSetFloat(vehicle, '_Fuel_Level', level + 0.0)

        -- The replicated statebag is written server-side by the restore path, because a
        -- client cannot set a replicated bag it does not own. This local write keeps the
        -- current frame consistent for anything reading it here.
        local key = fuelStatebagKey()
        if key then
            Entity(vehicle).state:set(key, level, false)
        end

        local provider = resolveFuel()
        if provider.setter then
            Park.try(function() exports[provider.resource][provider.setter](nil, vehicle, level) end)
        end
    end

    write()

    local provider = resolveFuel()
    if provider.setter then
        CreateThread(function()
            Wait(1500)
            write()
        end)
    end

    return true
end

-- ---------------------------------------------------------------------------------------
-- Target
--
-- Entirely optional, and only used by the opt-in "park here" option.
-- ---------------------------------------------------------------------------------------

local function resolveTarget()
    if detected.target ~= nil then return detected.target end

    local force = forced('target')
    if force then
        detected.target = force ~= 'none' and force or false
        return detected.target
    end

    detected.target = firstStarted({ 'ox_target', 'qb-target', 'qtarget' }) or false
    return detected.target
end

function Compat.target()
    return resolveTarget()
end

--[[
    Register the optional vehicle option, if a target system exists and the config asked for
    one. Returns whether it was registered, so the caller can fall back to a key.
]]
function Compat.registerVehicleOption(option)
    local provider = resolveTarget()
    if not provider then return false end

    local label = Locale.text(option.label)

    if provider == 'ox_target' then
        return Park.try(function()
            exports.ox_target:addGlobalVehicle({
                {
                    name = 'vpark:park',
                    icon = option.icon,
                    label = label,
                    distance = option.distance or 2.5,
                    canInteract = option.canInteract,
                    onSelect = option.onSelect,
                },
            })
            return true
        end) == true
    end

    if provider == 'qb-target' or provider == 'qtarget' then
        return Park.try(function()
            exports[provider]:AddGlobalVehicle({
                options = {
                    {
                        icon = option.icon,
                        label = label,
                        action = option.onSelect,
                        canInteract = option.canInteract,
                    },
                },
                distance = option.distance or 2.5,
            })
            return true
        end) == true
    end

    return false
end

-- ---------------------------------------------------------------------------------------
-- What was found
--
-- One table, for `/vparkinfo` and for the boot banner. Resolving everything here means the
-- info command reports what detection ACTUALLY chose rather than re-running it, which is the
-- difference between a diagnostic and a second opinion.
-- ---------------------------------------------------------------------------------------

function Compat.summary()
    resolveFramework()

    return {
        framework = frameworkKind or 'standalone',
        notify = resolveNotify(),
        fuel = resolveFuel().key,
        fuelStatebag = fuelStatebagKey() or 'none',
        target = resolveTarget() or 'none',
        locale = Locale.current(),
    }
end
