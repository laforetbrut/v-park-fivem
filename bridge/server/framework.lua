-- Author: vyrriox
--[[
    bridge/server/framework.lua

    The server's half of the compatibility layer. Everything the server needs to know about a
    player - who they are, what character they are on, what job they hold, whether they are an
    admin - and everything it needs to know about a framework-owned vehicle is asked for here.
    No file above this one names a framework.

    -------------------------------------------------------------------------------------------
    HOW A FRAMEWORK IS ADDED
    -------------------------------------------------------------------------------------------

    Each is an ADAPTER: a table of small functions with the same names. `Bridge.boot()` picks
    the first whose resource is started and whose handshake answers, and every `Bridge.*`
    function calls through the chosen adapter. Nothing branches on a framework name outside
    this file.

    Three adapters serve four frameworks:

        qb      qb-core and qbx_core. Same GetCoreObject export, same PlayerData shape.
        esx     es_extended. Different object, no citizenid, identifier is the stable key.
        ox      ox_core. Different object again, groups instead of jobs, numeric charId.

    Anything else degrades to standalone, where the character key is the Rockstar licence.
    That is a supported configuration, not a failure mode: everything works, and a player with
    two characters shares one set of parked vehicles because the server has no way to know
    they are different people.

    -------------------------------------------------------------------------------------------
    THE GATE IS Park.callable, NEVER type(fn) == 'function'
    -------------------------------------------------------------------------------------------

    A framework method that has crossed a resource boundary is a TABLE carrying a `__call`
    metamethod. Stock qb-core does not export GetPlayer, so the fallback through
    `QBCore.Functions.GetPlayer` is the only path, and a type test there rejects an object
    that calls perfectly well. The symptom is a resource that detects the framework, announces
    itself ready, and never resolves a single player.
]]

Bridge = {}

local core
local adapter
local frameworkName     -- the resource name, e.g. 'qbx_core'
local frameworkKind     -- the adapter key, e.g. 'qb'

local function try(fn, ...)
    return Park.try(fn, ...)
end

local field = Park.field

local function resourceName(key, fallback)
    local named = Config and Config.Compat and Config.Compat.resources and Config.Compat.resources[key]
    if type(named) == 'string' and named ~= '' then return named end
    return fallback
end

-- ---------------------------------------------------------------------------------------
-- The adapters
-- ---------------------------------------------------------------------------------------

local ADAPTERS = {}

-- ------------------------------------------------------------------ qb-core / qbx_core ---

ADAPTERS.qb = {
    resources = function()
        return { resourceName('qbx', 'qbx_core'), resourceName('qb', 'qb-core') }
    end,

    handshake = function(resource)
        local object = try(function() return exports[resource]:GetCoreObject() end)
        return type(object) == 'table' and object or nil
    end,

    player = function(object, src)
        -- The export first, because a qb build that dropped the Functions alias still has it.
        local player = try(function() return exports[frameworkName]:GetPlayer(src) end)
        if type(player) == 'table' then return player end

        local functions = field(object, 'Functions')
        if functions and functions.GetPlayer then
            player = try(functions.GetPlayer, src)
            if type(player) == 'table' then return player end
        end

        return nil
    end,

    characterId = function(_, player)
        return player and player.PlayerData and player.PlayerData.citizenid or nil
    end,

    license = function(_, player)
        return player and player.PlayerData and player.PlayerData.license or nil
    end,

    name = function(_, player)
        local charinfo = player and player.PlayerData and player.PlayerData.charinfo
        if type(charinfo) ~= 'table' then return nil end
        return ((charinfo.firstname or '') .. ' ' .. (charinfo.lastname or '')):gsub('^%s+', '')
    end,

    --[[
        The roleplay name of a character who is NOT connected.

        qb-core keeps it as JSON in `players`.`charinfo`, keyed by citizenid. The admin panel
        asks for it so a list of owners reads as names rather than as a column of
        `KLJ61534` - which is exactly what an operator cannot act on.

        `table` is separate from the query so a server that renamed it can be handled, and the
        column list is explicit rather than `*` because charinfo rows are large.
    ]]
    offlineNames = {
        query = 'SELECT `citizenid` AS `id`, `charinfo` FROM `players` WHERE `citizenid` IN (%s)',
        read = function(row)
            local info = Park.decode(row.charinfo)
            if type(info) ~= 'table' then return nil end

            local name = ((info.firstname or '') .. ' ' .. (info.lastname or ''))
            name = name:gsub('^%s+', ''):gsub('%s+$', '')
            return name ~= '' and name or nil
        end,
    },

    job = function(_, player)
        local job = player and player.PlayerData and player.PlayerData.job
        if type(job) ~= 'table' then return nil end
        return {
            name = job.name,
            grade = (type(job.grade) == 'table' and job.grade.level) or job.grade or 0,
            boss = job.isboss == true,
            onDuty = job.onduty ~= false,
        }
    end,

    gang = function(_, player)
        local gang = player and player.PlayerData and player.PlayerData.gang
        if type(gang) ~= 'table' or not gang.name or gang.name == 'none' then return nil end
        return {
            name = gang.name,
            grade = (type(gang.grade) == 'table' and gang.grade.level) or gang.grade or 0,
        }
    end,

    hasGroup = function(object, src, groups)
        for _, group in ipairs(groups) do
            local ok = try(function() return exports[frameworkName]:HasPermission(src, group) end)
            if ok == true then return true end

            local functions = field(object, 'Functions')
            if functions and functions.HasPermission then
                if try(functions.HasPermission, src, group) == true then return true end
            end
        end
        return false
    end,

    -- The owned-vehicles table, for matching a persisted vehicle to a character's property.
    ownedTable = function()
        return {
            table = 'player_vehicles',
            plate = 'plate',
            owner = 'citizenid',
            model = 'hash',
            id = 'id',
            storedColumn = 'state',
            storedValue = 1,      -- 1 = in garage
            outValue = 0,         -- 0 = out in the world
            garageColumn = 'garage',
        }
    end,
}

-- ---------------------------------------------------------------------------- es_extended ---

ADAPTERS.esx = {
    resources = function()
        return { resourceName('esx', 'es_extended') }
    end,

    handshake = function(resource)
        local object = try(function() return exports[resource]:getSharedObject() end)
        if type(object) == 'table' then return object end

        -- The legacy event, still what a large share of servers run.
        local shared
        TriggerEvent('esx:getSharedObject', function(value) shared = value end)
        return type(shared) == 'table' and shared or nil
    end,

    player = function(object, src)
        local getter = field(object, 'GetPlayerFromId')
        local player = try(getter, src)
        if type(player) == 'table' then return player end
        return nil
    end,

    --[[
        ESX has no citizenid. The identifier IS the character key, and on a multi-character
        ESX it already carries the character suffix, so it is stable and correct.
    ]]
    characterId = function(_, player)
        return player and player.identifier or nil
    end,

    license = function(_, player)
        return player and player.identifier or nil
    end,

    name = function(_, player)
        return player and (player.getName and try(player.getName) or player.name) or nil
    end,

    -- ESX keys `users` on the identifier, which IS its character id.
    offlineNames = {
        query = 'SELECT `identifier` AS `id`, `firstname`, `lastname` FROM `users` WHERE `identifier` IN (%s)',
        read = function(row)
            local name = ((row.firstname or '') .. ' ' .. (row.lastname or ''))
            name = name:gsub('^%s+', ''):gsub('%s+$', '')
            return name ~= '' and name or nil
        end,
    },

    job = function(_, player)
        local job = player and player.job
        if type(job) ~= 'table' then return nil end
        return {
            name = job.name,
            grade = job.grade or 0,
            boss = job.grade_name == 'boss',
            onDuty = true,   -- ESX has no duty concept in core
        }
    end,

    gang = function() return nil end,   -- ESX has no gangs

    hasGroup = function(_, src, groups)
        local player = ADAPTERS.esx.player(core, src)
        if not player then return false end

        local group = player.getGroup and try(player.getGroup) or player.group
        if type(group) ~= 'string' then return false end

        for _, wanted in ipairs(groups) do
            if group == wanted then return true end
        end
        return false
    end,

    ownedTable = function()
        return {
            table = 'owned_vehicles',
            plate = 'plate',
            owner = 'owner',
            model = nil,          -- ESX keeps the model inside the `vehicle` JSON blob
            id = 'plate',
            storedColumn = 'stored',
            storedValue = 1,
            outValue = 0,
            garageColumn = 'parking',
        }
    end,
}

-- -------------------------------------------------------------------------------- ox_core ---

ADAPTERS.ox = {
    resources = function()
        return { resourceName('ox', 'ox_core') }
    end,

    handshake = function(resource)
        -- ox_core's core object IS its exports table. Indexing an export that does not exist
        -- raises, so the handshake is a call to one we know exists, through pcall.
        local object = exports[resource]
        local ok = try(function() return object:GetPlayer(0) end) ~= nil
            or Park.callable(field(object, 'GetPlayer'))
        return ok and object or nil
    end,

    player = function(object, src)
        local player = try(function() return object:GetPlayer(src) end)
        return type(player) == 'table' and player or nil
    end,

    characterId = function(_, player)
        local id = player and (player.charId or player.charid)
        return id and tostring(id) or nil
    end,

    license = function(_, player)
        return player and (player.license2 or player.license or player.userId and tostring(player.userId)) or nil
    end,

    name = function(_, player)
        if not player then return nil end
        local first = player.firstName or player.firstname
        local last = player.lastName or player.lastname
        if first or last then
            return ((first or '') .. ' ' .. (last or '')):gsub('^%s+', '')
        end
        return player.name
    end,

    offlineNames = {
        query = 'SELECT `charId` AS `id`, `firstName`, `lastName` FROM `characters` WHERE `charId` IN (%s)',
        read = function(row)
            local name = ((row.firstName or row.firstname or '') .. ' '
                .. (row.lastName or row.lastname or ''))
            name = name:gsub('^%s+', ''):gsub('%s+$', '')
            return name ~= '' and name or nil
        end,
    },

    --[[
        ox_core has groups, not jobs. The active group is the closest equivalent, and
        `getGroup` answers the grade within it.
    ]]
    job = function(_, player)
        if not player then return nil end

        local groups = player.getGroups and try(player.getGroups) or player.groups
        if type(groups) ~= 'table' then return nil end

        -- The highest-graded group, deterministically: sorted by name so two runs agree.
        local best, bestGrade
        for _, name in ipairs(Park.keys(groups)) do
            local grade = tonumber(groups[name]) or 0
            if not bestGrade or grade > bestGrade then
                best, bestGrade = name, grade
            end
        end

        if not best then return nil end
        return { name = best, grade = bestGrade or 0, boss = false, onDuty = true }
    end,

    gang = function() return nil end,

    hasGroup = function(_, src, groups)
        local player = ADAPTERS.ox.player(core, src)
        if not player then return false end

        for _, wanted in ipairs(groups) do
            local grade = player.getGroup and try(player.getGroup, wanted)
            if grade and grade ~= 0 then return true end
        end
        return false
    end,

    ownedTable = function()
        return {
            table = 'vehicles',
            plate = 'plate',
            owner = 'owner',
            model = 'model',
            id = 'id',
            storedColumn = 'stored',
            storedValue = nil,    -- ox_core stores a garage NAME, or NULL when out
            outValue = nil,
            garageColumn = 'stored',
        }
    end,
}

-- ---------------------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------------------

local ORDER = { 'qb', 'esx', 'ox' }

--[[
    Detect the framework. Called once from the server boot sequence, and re-callable so that
    `/vparkreload` can pick up a framework that started after us.

    Returns the adapter key, or 'standalone'.
]]
function Bridge.boot()
    local force = Config and Config.Compat and Config.Compat.framework

    if force == 'standalone' then
        frameworkKind = 'standalone'
        Park.log('running standalone: vehicles are keyed on the Rockstar licence')
        return frameworkKind
    end

    -- qbx and qb share the qb adapter but are different forced values, so map them.
    local wanted = force
    if wanted == 'qbx' then wanted = 'qb' end
    if wanted == 'auto' or wanted == '' then wanted = nil end

    for _, kind in ipairs(ORDER) do
        if not wanted or wanted == kind then
            local candidate = ADAPTERS[kind]

            for _, resource in ipairs(candidate.resources()) do
                if Park.started(resource) then
                    local object = candidate.handshake(resource)
                    if object then
                        core = object
                        adapter = candidate
                        frameworkName = resource
                        frameworkKind = kind
                        Park.log('framework: %s (%s)', kind, resource)
                        return frameworkKind
                    end

                    Park.warn('%s is started but did not answer its handshake', resource)
                end
            end
        end
    end

    if wanted then
        Park.warn("Config.Compat.framework is '%s' but it was not found - running standalone", tostring(force))
    end

    frameworkKind = 'standalone'
    Park.log('no framework detected - running standalone')
    return frameworkKind
end

function Bridge.kind()
    return frameworkKind or 'standalone'
end

function Bridge.resource()
    return frameworkName
end

function Bridge.core()
    return core
end

local function player(src)
    if not adapter then return nil end
    return adapter.player(core, src)
end

Bridge.player = player

-- ---------------------------------------------------------------------------------------
-- Identity
-- ---------------------------------------------------------------------------------------

--[[
    The Rockstar licence for a source, or nil.

    Always available, framework or not, and stable across characters. Used as the standalone
    character key and as the fallback tie-breaker everywhere else.
]]
function Bridge.license(src)
    if type(src) ~= 'number' or src <= 0 then return nil end

    for _, identifier in ipairs(GetPlayerIdentifiers(src) or {}) do
        local licence = identifier:match('^license2:(.+)$') or identifier:match('^license:(.+)$')
        if licence then return licence end
    end

    return nil
end

--[[
    The CHARACTER key: what a persisted vehicle is owned by.

    Returns nil - never a guess - when the framework is present but has not finished loading
    the character. The caller retries on nil. Answering with the licence here is the bug that
    gives every character on an account one shared set of vehicles, and it does not surface
    until somebody makes a second character.
]]
function Bridge.characterId(src)
    if type(src) ~= 'number' or src <= 0 then return nil end

    if frameworkKind == 'standalone' or not adapter then
        return Bridge.license(src)
    end

    local object = player(src)
    if not object then return nil end

    local id = adapter.characterId(core, object)
    if type(id) == 'string' and id ~= '' then return id end
    if type(id) == 'number' then return tostring(id) end

    return nil
end

--[[
    Wait for the character to load, up to `timeoutMs`.

    Every framework loads the character asynchronously after the player connects, and the
    delay ranges from instant to twenty seconds on a slow multicharacter. Everything that
    needs an identity calls this rather than reading once and giving up.
]]
function Bridge.waitForCharacter(src, timeoutMs)
    timeoutMs = timeoutMs or 30000
    local deadline = Park.ticks() + timeoutMs

    repeat
        local id = Bridge.characterId(src)
        if id then return id end
        Wait(500)
    until Park.ticks() > deadline or not Bridge.playerName(src)

    return nil
end

--[[
    `GetPlayerName` without the crash.

    -------------------------------------------------------------------------------------------
    WHY THIS EXISTS
    -------------------------------------------------------------------------------------------

    `GetPlayerName(0)` does not return nil. It RAISES:

        script error in native 00000000406b4b20: Argument at index 0 was null.

    Zero is the console, and the console runs commands. Every audit row written for a console
    command went through `Bridge.name(0)`, raised inside the database thread, was swallowed by
    that thread's pcall, and the row was never written - so `/vparkmigrate run` from the server
    console has never been audited, in any version, and said nothing about it.

    A player id typed by an operator has the same shape: `/vparkowner <vehicle> 0` reached the
    native with a zero as well.

    Returns nil for anything that is not a connected player, which is what every caller was
    already written to expect.
]]
function Bridge.playerName(src)
    if type(src) ~= 'number' or src <= 0 then return nil end

    local ok, name = pcall(GetPlayerName, src)
    if not ok or type(name) ~= 'string' or name == '' then return nil end

    return name
end

function Bridge.name(src)
    -- The console is not a player and has a name worth printing.
    if type(src) ~= 'number' or src <= 0 then return 'console' end

    local object = player(src)
    if object and adapter then
        local name = adapter.name(core, object)
        if type(name) == 'string' and name ~= '' then return name end
    end
    return Bridge.playerName(src) or ('player ' .. tostring(src))
end

function Bridge.job(src)
    local object = player(src)
    if not object or not adapter then return nil end
    return adapter.job(core, object)
end

function Bridge.gang(src)
    local object = player(src)
    if not object or not adapter then return nil end
    return adapter.gang(core, object)
end

-- ---------------------------------------------------------------------------------------
-- Permissions
--
-- ACE FIRST, always, and independently of the framework.
--
-- A server owner must have a way in that does not depend on the framework being up. When
-- qb-core fails to boot, the one thing an admin needs is the command that tells them why, and
-- gating it behind qb-core's permission system means it is not there.
-- ---------------------------------------------------------------------------------------

function Bridge.isAdmin(src)
    -- The console. Not a player, and permitted to do everything.
    if src == 0 then return true end
    if type(src) ~= 'number' or src <= 0 then return false end

    local ace = Config and Config.Permissions and Config.Permissions.ace
    if type(ace) == 'string' and ace ~= '' then
        if IsPlayerAceAllowed(src, ace) then return true end
    end

    local groups = (Config and Config.Permissions and Config.Permissions.groups) or {}
    if adapter and #groups > 0 then
        if adapter.hasGroup(core, src, groups) == true then return true end
    end

    -- A job at or above a configured grade.
    local jobs = (Config and Config.Permissions and Config.Permissions.jobs) or {}
    if next(jobs) then
        local job = Bridge.job(src)
        if job and job.name then
            local required = jobs[job.name]
            if type(required) == 'number' and (job.grade or 0) >= required then
                return true
            end
        end
    end

    return false
end

-- ---------------------------------------------------------------------------------------
-- Owned vehicles
--
-- Read-only, always. This resource never writes a framework's owned-vehicles table except
-- through the two explicit, config-gated calls at the bottom, and both are about a garage
-- state that would otherwise let a player duplicate a car.
-- ---------------------------------------------------------------------------------------

function Bridge.ownedTable()
    if not adapter then return nil end
    return adapter.ownedTable()
end

--[[
    Find the framework-owned vehicle matching a plate.

    Returns { owner, id, stored, garage } or nil. The caller uses it to decide ownership and
    expiry, so a nil here means "not owned as far as the framework knows", which is a
    perfectly ordinary answer for a stolen car.
]]
function Bridge.ownedByPlate(plate)
    local schema = Bridge.ownedTable()
    if not schema or not Database.available() then return nil end

    local normalised = Park.plate(plate)
    if not normalised then return nil end

    local columns = { schema.owner .. ' AS owner', schema.id .. ' AS id' }
    if schema.storedColumn then
        columns[#columns + 1] = ('`%s` AS stored'):format(schema.storedColumn)
    end
    if schema.garageColumn and schema.garageColumn ~= schema.storedColumn then
        columns[#columns + 1] = ('`%s` AS garage'):format(schema.garageColumn)
    end

    local sql = ('SELECT %s FROM `%s` WHERE `%s` = ? LIMIT 1')
        :format(table.concat(columns, ', '), schema.table, schema.plate)

    local rows = Database.query(sql, { normalised })
    if type(rows) ~= 'table' or not rows[1] then return nil end

    return rows[1]
end

--[[
    Is the framework's record saying this vehicle is currently in a garage?

    THE DUPLICATION GUARD. Without it, a car can sit in the street AND be listed in the
    player's garage, and taking it out produces two of them.

    The three frameworks disagree on how they say it, so each answers separately rather than
    through one column comparison that is wrong for two of them.
]]
function Bridge.isStored(row)
    if type(row) ~= 'table' then return false end

    if frameworkKind == 'qb' then
        -- state: 0 out, 1 garaged, 2 impounded. Anything but 0 is not in the world.
        local state = tonumber(row.stored)
        return state ~= nil and state ~= 0
    end

    if frameworkKind == 'esx' then
        local stored = row.stored
        if type(stored) == 'boolean' then return stored end
        return tonumber(stored) == 1
    end

    if frameworkKind == 'ox' then
        -- ox_core keeps a garage name, or NULL when the vehicle is out.
        return row.stored ~= nil and row.stored ~= '' and row.stored ~= 0
    end

    return false
end

--[[
    Mark a vehicle as OUT of the garage, because we have just put it in the world.

    Config-gated on `Config.Garages.markAsOut`, and it is the write that makes persistence
    safe next to a garage script. It writes exactly one column of one row.
]]
function Bridge.markOut(plate)
    if not (Config and Config.Garages and Config.Garages.markAsOut) then return false end

    local schema = Bridge.ownedTable()
    if not schema or not schema.storedColumn or not Database.available() then return false end

    local normalised = Park.plate(plate)
    if not normalised then return false end

    local sql, params
    if frameworkKind == 'ox' then
        sql = ('UPDATE `%s` SET `%s` = NULL WHERE `%s` = ?')
            :format(schema.table, schema.storedColumn, schema.plate)
        params = { normalised }
    elseif frameworkKind == 'qb' or frameworkKind == 'esx' then
        sql = ('UPDATE `%s` SET `%s` = ? WHERE `%s` = ?')
            :format(schema.table, schema.storedColumn, schema.plate)
        params = { 0, normalised }
    else
        return false
    end

    local result = Database.execute(sql, params)
    return result ~= nil and result ~= false
end

--[[
    The reverse: hand a vehicle back to the garage rather than deleting it.

    What makes expiry safe for an owned vehicle. The player does not lose the car; it is in
    the garage, which is where they would have put it.
]]
function Bridge.returnToGarage(plate, garage)
    if not (Config and Config.Garages and Config.Garages.returnToGarageOnRemoval) then return false end

    local schema = Bridge.ownedTable()
    if not schema or not schema.storedColumn or not Database.available() then return false end

    local normalised = Park.plate(plate)
    if not normalised then return false end

    local value
    if frameworkKind == 'qb' then value = 1
    elseif frameworkKind == 'esx' then value = 1
    elseif frameworkKind == 'ox' then value = garage or 'default'
    else return false end

    local assignment = ('`%s` = ?'):format(schema.storedColumn)
    local params = { value }
    if type(garage) == 'string' and garage ~= '' and schema.garageColumn
        and schema.garageColumn ~= schema.storedColumn then
        assignment = assignment .. (', `%s` = ?'):format(schema.garageColumn)
        params[#params + 1] = garage
    end
    params[#params + 1] = normalised
    local sql = ('UPDATE `%s` SET %s WHERE `%s` = ?')
        :format(schema.table, assignment, schema.plate)

    local result = Database.execute(sql, params)
    return result ~= nil and result ~= false
end

--[[
    Mark an owned vehicle as impounded, for `Config.Lifecycle.onExpiry = 'impound'`.

    Only qb-core has a first-class impound state. ESX and ox_core do not, so they fall back to
    the garage, which is the nearest honest equivalent - and the caller is told which happened
    so the notification does not promise an impound lot that does not exist.
]]
function Bridge.impound(plate)
    local schema = Bridge.ownedTable()
    if not schema or not Database.available() then return false, 'none' end

    local normalised = Park.plate(plate)
    if not normalised then return false, 'none' end

    if frameworkKind == 'qb' and schema.storedColumn then
        local result = Database.execute(('UPDATE `%s` SET `%s` = 2 WHERE `%s` = ?')
            :format(schema.table, schema.storedColumn, schema.plate), { normalised })
        if result ~= nil and result ~= false then return true, 'impound' end
        return false, 'none'
    end

    if Bridge.returnToGarage(normalised) then
        return true, 'garage'
    end

    return false, 'none'
end

-- ---------------------------------------------------------------------------------------
-- Keys
--
-- Handled server-side where the resource allows it, and by asking the owning client where it
-- does not. Every path is optional and every one degrades to doing nothing.
-- ---------------------------------------------------------------------------------------

local keyProvider

local KEY_PROVIDERS = {
    { key = 'qb-vehiclekeys',  resource = 'qb-vehiclekeys' },
    { key = 'qs-vehiclekeys',  resource = 'qs-vehiclekeys' },
    { key = 'wasabi_carlock',  resource = 'wasabi_carlock' },
    { key = 'mk_vehiclekeys',  resource = 'mk_vehiclekeys' },
    { key = 'cd_garage',       resource = 'cd_garage' },
    { key = 'jaksam',          resource = 'jaksam-vehicles-keys' },
}

local function resolveKeys()
    if keyProvider ~= nil then return keyProvider end

    local force = Config and Config.Compat and Config.Compat.keys
    if force == 'none' then
        keyProvider = false
        return keyProvider
    end
    if force == 'auto' or force == nil or force == '' then force = nil end

    for _, provider in ipairs(KEY_PROVIDERS) do
        if (not force or force == provider.key) and Park.started(provider.resource) then
            keyProvider = provider
            Park.debug('key provider detected: %s', provider.key)
            return keyProvider
        end
    end

    keyProvider = false
    return keyProvider
end

function Bridge.keyProvider()
    local provider = resolveKeys()
    return provider and provider.key or 'none'
end

--[[
    Give `src` the keys to `plate`.

    Every provider is tried through pcall, and a failure is a debug line rather than an error:
    the vehicle is restored either way, and the owner can still call a locksmith.
]]
function Bridge.giveKeys(src, plate, netId)
    if not (Config and Config.Keys and Config.Keys.restore) then return false end

    local provider = resolveKeys()
    if not provider then return false end

    local normalised = Park.plate(plate)
    if not normalised then return false end

    local key = provider.key

    if key == 'qb-vehiclekeys' then
        -- Two generations of qb-vehiclekeys, and servers run both.
        if try(function() exports['qb-vehiclekeys']:GiveKeys(src, normalised) end) ~= nil then return true end
        TriggerClientEvent('qb-vehiclekeys:client:AddKeys', src, normalised)
        return true
    end

    if key == 'qs-vehiclekeys' then
        if try(function() exports['qs-vehiclekeys']:GiveKeys(src, normalised) end) ~= nil then return true end
        TriggerClientEvent('qs-vehiclekeys:client:AddKeys', src, normalised)
        return true
    end

    if key == 'wasabi_carlock' then
        if try(function() exports.wasabi_carlock:GiveKey(src, normalised) end) ~= nil then return true end
        return true
    end

    if key == 'mk_vehiclekeys' then
        if try(function() exports.mk_vehiclekeys:addKey(src, normalised) end) ~= nil then return true end
        return true
    end

    if key == 'cd_garage' then
        TriggerClientEvent('cd_garage:AddKeys', src, normalised)
        return true
    end

    if key == 'jaksam' then
        if try(function() exports['jaksam-vehicles-keys']:giveVehicleKeysToPlayerId(src, netId, normalised) end) ~= nil then
            return true
        end
        return true
    end

    return false
end

-- ---------------------------------------------------------------------------------------
-- Notifications, from the server
-- ---------------------------------------------------------------------------------------

--[[
    Notify a player. The client owns the provider choice; the server only says what to say.

    `event` names the `Config.Notify.events` toggle. A message whose toggle is off is not
    sent, and the check happens HERE rather than on the client so that a switched-off
    notification costs no network traffic at all.
]]
function Bridge.notify(src, event, message, kind)
    if type(src) ~= 'number' or src <= 0 then return end
    if not (Config and Config.Notify and Config.Notify.enabled) then return end

    if event then
        local events = Config.Notify.events or {}
        if events[event] == false then return end
    end

    TriggerClientEvent('vpark:client:notify', src, message, kind or 'info')
end

-- ---------------------------------------------------------------------------------------
-- Roleplay names
-- ---------------------------------------------------------------------------------------

--[[
    characterId -> the roleplay name, for characters who are not connected.

    -------------------------------------------------------------------------------------------
    WHY THIS EXISTS
    -------------------------------------------------------------------------------------------

    A record stores `owner_name` as it was when the vehicle was persisted, and only when a
    player was online to be asked. Every other row - one whose owner came from the framework's
    owned-vehicles table, one brought in by the migration, one whose owner has since changed -
    has a citizenid and nothing else.

    The admin panel then shows a column of `KLJ61534`, which is not something an operator can
    act on. This resolves those to "Jean Dupont" the way the rest of the server does.

    Bounded, and never invalidated on a timer: a character's name changes at most once in the
    life of a server, and a stale one for the length of a session is a much smaller problem
    than a query per row per refresh.
]]
local nameCache = {}
local nameCacheCount = 0

local NAME_CACHE_LIMIT = 500

function Bridge.cachedName(characterId)
    if type(characterId) ~= 'string' then return nil end
    local name = nameCache[characterId]
    -- `false` is "we asked and the framework does not know", which is a real answer and stops
    -- the same id being queried on every refresh.
    if name == false then return nil end
    return name
end

--[[
    Look up every name we do not already have, in ONE query.

    Called by the panel with the ids on the page it is about to send. A page is at most a
    hundred rows and the second time it is asked for the same page it queries nothing at all.

    Returns quietly and changes nothing when there is no database, no framework, or no adapter
    that knows where names live - all of which are ordinary configurations, not errors.
]]
function Bridge.resolveNames(ids)
    if type(ids) ~= 'table' or #ids == 0 then return end
    if not (adapter and adapter.offlineNames) then return end
    if not (Database and Database.available and Database.available()) then return end

    local wanted, count = {}, 0

    for _, id in ipairs(ids) do
        if type(id) == 'string' and nameCache[id] == nil then
            -- Marked before the query, not after: two panels open at once would otherwise ask
            -- for the same hundred ids twice.
            nameCache[id] = false
            nameCacheCount = nameCacheCount + 1
            count = count + 1
            wanted[count] = id
        end
    end

    if count == 0 then return end

    -- Placeholders rather than interpolation. These ids come from our own table, but a
    -- citizenid is ultimately whatever a framework wrote there.
    local marks = string.rep('?', count, ', ')

    local rows = Database.query(adapter.offlineNames.query:format(marks), wanted)
    if type(rows) ~= 'table' then return end

    local found = 0
    for _, row in ipairs(rows) do
        local id = row.id and tostring(row.id)
        local ok, name = pcall(adapter.offlineNames.read, row)

        if id and ok and type(name) == 'string' and name ~= '' then
            nameCache[id] = name
            found = found + 1
        end
    end

    Park.trace('resolved %d of %d character name(s)', found, count)

    --[[
        Bounded by emptying it rather than by evicting the oldest.

        An LRU here would be several times the code for a table whose entries are two short
        strings, and the cost of being wrong is one extra query. Five hundred characters is
        more than any single panel session looks at.
    ]]
    if nameCacheCount > NAME_CACHE_LIMIT then
        nameCache = {}
        nameCacheCount = 0
        Park.debug('the character name cache reached %d entries and was emptied', NAME_CACHE_LIMIT)
    end
end

--[[
    The best name we have for a character, online or not.

    Online wins: it is current, and it costs nothing.
]]
function Bridge.displayName(characterId, stored)
    if type(characterId) ~= 'string' then return stored end

    local src = Ownership and Ownership.sourceOf and Ownership.sourceOf(characterId)
    if src then
        local live = Bridge.name(src)
        if type(live) == 'string' and live ~= '' and live ~= 'console' then return live end
    end

    return Bridge.cachedName(characterId) or stored
end

-- ---------------------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------------------

function Bridge.summary()
    return {
        framework = frameworkKind or 'unknown',
        resource = frameworkName or 'none',
        keys = Bridge.keyProvider(),
        ownedTable = (Bridge.ownedTable() or {}).table or 'none',
    }
end
