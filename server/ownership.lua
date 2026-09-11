-- Author: vyrriox
--[[
    server/ownership.lua

    Who a vehicle belongs to, and what that means for how long it is kept.

    -------------------------------------------------------------------------------------------
    THE SIX KINDS
    -------------------------------------------------------------------------------------------

        owned     the framework says a character owns it. A player's car.
        job       it belongs to a job or a gang rather than a person.
        rental    somebody is renting it. Semi-persistent by default.
        claimed   a player explicitly parked it with /vpark.
        unowned   somebody drove it and left it. A stolen car, a spawned test vehicle.
        ambient   adopted from the world's own traffic, if that is switched on.

    The kind decides three things: the expiry timer, whether the semi-persistence countdown
    applies, and who may run a command against it. Nothing else in the resource branches on it.

    -------------------------------------------------------------------------------------------
    WHY IT IS RESOLVED AT SAVE TIME AND RE-RESOLVED LATER
    -------------------------------------------------------------------------------------------

    A car can change hands. It is sold through a dealership, taken off a player by an admin, or
    the framework's owned-vehicles table gains a row for a plate that was unowned yesterday
    because somebody bought the car they had been driving.

    So ownership is resolved when a vehicle is first persisted, AND re-checked when it is
    restored. The re-check is one indexed lookup per restored vehicle and it is what stops a
    bought car keeping the two-day abandoned-vehicle timer it was given when it was stolen.
]]

Ownership = {}

-- ---------------------------------------------------------------------------------------
-- Resolution
-- ---------------------------------------------------------------------------------------

--[[
    Work out who owns a vehicle, from a plate and from whoever is standing in it.

    `src` is the player who was last in it, or nil. `explicit` forces a kind, and is how
    `/vpark` produces a 'claimed' vehicle and how a rental resource produces a 'rental' one.

    Returns owner, ownerType, ownerName, job.
]]
function Ownership.resolve(plate, src, explicit)
    -- An explicit kind that carries its own owner is taken at face value. It comes from an
    -- export, and the export is only callable by a resource the config allows.
    if type(explicit) == 'table' and explicit.type then
        return explicit.owner, explicit.type, explicit.name, explicit.job
    end

    -- The framework's own record is the strongest evidence there is.
    if Config.Ownership and Config.Ownership.matchOwnedByPlate ~= false then
        local row = Bridge.ownedByPlate(plate)
        if row and row.owner then
            return row.owner, 'owned', nil, nil
        end
    end

    if not src then
        return nil, 'unowned', nil, nil
    end

    local characterId = Bridge.characterId(src)
    local name = Bridge.name(src)

    if explicit == 'claimed' then
        return characterId, 'claimed', name, nil
    end

    --[[
        The keys are the second-strongest evidence, and on a lot of servers the only one.

        `/admincar`, a dealership demo, a job spawner, a heist car handed to the crew: none of
        those write a row in the framework's owned-vehicles table, and every one of them is a
        car the player would be astonished to lose on a restart. This was reported as exactly
        that.

        Deliberately AFTER the framework row. A car whose owner the framework knows has an
        owner, even while somebody else is driving it on a borrowed set of keys - handing a
        mate your keys must not hand them the car.

        See `Config.Ownership.keysGrantOwnership`.
    ]]
    if Config.Ownership and Config.Ownership.keysGrantOwnership ~= false then
        if Ownership.hasKeys(src, plate) then
            return characterId, 'owned', name, nil
        end
    end

    -- A job or gang vehicle: the player is on a job whose vehicles the config keeps, and the
    -- vehicle is not personally owned by anybody.
    if Config.Persistence and Config.Persistence.jobVehicles then
        local job = Bridge.job(src)
        local gang = Bridge.gang(src)

        local group = nil
        if job and job.name and job.name ~= 'unemployed' and job.name ~= 'civ' and job.name ~= 'citizen' then
            group = job.name
        elseif gang and gang.name then
            group = 'gang:' .. gang.name
        end

        if group and Ownership.isJobVehicle(plate, group) then
            return characterId, 'job', name, group
        end
    end

    if type(explicit) == 'string' then
        return characterId, explicit, name, nil
    end

    return characterId, 'unowned', name, nil
end

--[[
    Is this plate a job vehicle rather than a personal one?

    There is no framework-wide answer to this, so the test is: it is NOT in the owned-vehicles
    table, and the player who was in it holds a job. A police cruiser spawned from a job
    garage has no owner row; a personal car does.

    `Config.Ownership.jobPlatePattern` is the override for a server whose job vehicles use a
    recognisable plate, which is both faster and exact.
]]
function Ownership.isJobVehicle(plate, group)
    local pattern = Config.Ownership and Config.Ownership.jobPlatePattern
    if type(pattern) == 'string' and pattern ~= '' then
        local normalised = Park.plate(plate)
        return normalised ~= nil and normalised:match(pattern) ~= nil
    end

    --[[
        WITHOUT A PATTERN, THIS QUESTION CANNOT BE ANSWERED, SO IT ANSWERS NO.

        The rule used to be "there is no owner row and the driver holds a job", and the comment
        above it listed what that catches: a job spawner, a dealership demo, AND AN ADMIN
        COMMAND. It caught all three and treated all three as job vehicles.

        So on a server where staff hold a job - which is most of them - every car spawned with
        `/car` became a permanent row the moment somebody sat in it. Reported as exactly that:
        "/car makes it persistent, that is not normal; it should be /admincar".

        There is no way to tell a police cruiser taken from the Mission Row spawner apart from
        a Premier an admin conjured, by looking at the vehicle. Both are unregistered, both are
        being driven by somebody with a job. The only thing that CAN tell them apart is a
        recognisable plate, which is what `jobPlatePattern` is for and why the config calls it
        exact and free.

        No pattern, no answer. Job vehicles are kept on a server that configures one, and
        nothing else is swept up on a server that does not.
    ]]
    return false
end

--[[
    Re-check a restored vehicle's ownership against the framework, once.

    Called from the spawn path. One indexed lookup also detects a sale between restores.
]]
function Ownership.onRestored(record, entity, netId)
    if not record then return end

    if Config.Ownership and Config.Ownership.matchOwnedByPlate ~= false and record.plate then
        local row = Bridge.ownedByPlate(record.plate)

        if row then
            if row.owner and (record.owner_type ~= 'owned' or record.owner ~= row.owner) then
                Park.debug('%s is now owned by %s in the framework - upgrading its ownership',
                    record.id, tostring(row.owner))

                Store.update(record.id, {
                    owner = row.owner,
                    owner_type = 'owned',
                })
            end

            --[[
                Learn which garage this vehicle came out of, BEFORE we mark it as out.

                This is the only moment the information exists: the framework's garage column
                still names the garage the player took it from, and the very next statement
                overwrites that. Read after `markOut` and the answer is always "nowhere".

                It is what `Config.Cleanup.destination = 'lastGarage'` sends an idle vehicle
                back to, and it is why that setting can be the default rather than needing
                every operator to name a garage.
            ]]
            local garage = row.garage
            if type(garage) == 'string' and garage ~= '' and garage ~= record.last_garage then
                Store.update(record.id, { last_garage = garage })
                Park.trace('%s remembers garage `%s`', record.id, garage)
            end
        end
    end

    -- Tell the framework the vehicle is OUT of the garage. Without this a player can have a
    -- car in the street and the same car listed in their garage, and take it out twice.
    -- That is a duplication bug, and this line is what prevents it.
    if record.owner_type == 'owned' and record.plate then
        Database.thread(function()
            Bridge.markOut(record.plate)
        end)
    end

    -- Keys, for whoever is online and owns it.
    if Config.Keys and Config.Keys.restore and record.owner then
        local src = Ownership.sourceOf(record.owner)
        if src then
            Bridge.giveKeys(src, record.plate, netId)
        end
    end

    -- jim-mechanic keeps nitrous per plate in its own in-memory table, rebuilt at boot from
    -- the framework's owned-vehicles rows. A vehicle that is NOT in those rows - a job car, a
    -- stolen one, anything we persist and the framework does not know - loses its bottle on
    -- every restart. Re-firing its load event for the restored plate puts it back.
    if Config.Mechanic and Config.Mechanic.restoreNitrous
        and record.statebags and record.statebags.hasnitro then
        Ownership.restoreNitrous(record)
    end
end

--[[
    Put a jim-mechanic nitrous bottle back on a restored vehicle.

    Its own server event is used rather than writing its table, so that whatever bookkeeping
    it does around the change still happens. It broadcasts the result to every client itself,
    which is why nothing here talks to clients.
]]
function Ownership.restoreNitrous(record)
    local resource = Config.Mechanic and Config.Mechanic.resource
    if resource == 'none' then return end

    if not Park.started('jim-mechanic') then return end
    if not record.plate then return end

    local level = tonumber(record.statebags.noslevel) or 100

    TriggerEvent('jim-mechanic:server:LoadNitrous', record.plate)

    if level < 100 then
        TriggerEvent('jim-mechanic:server:UpdateNitroLevel', record.plate, level)
    end

    Park.trace('restored a nitrous bottle on %s at %d%%', record.plate, level)
end

-- ---------------------------------------------------------------------------------------
-- Who is online
-- ---------------------------------------------------------------------------------------

-- character id -> source, maintained by the connect and disconnect handlers rather than
-- rebuilt per query. The semi-persistence sweep asks this once per semi-persistent vehicle
-- per minute, and a rebuild per question would be a loop over every player each time.
local online = {}
local registrations = {}

local function unregister(src)
    registrations[src] = nil
    for characterId, mapped in pairs(online) do
        if mapped == src then
            online[characterId] = nil
            Lifecycle.onOwnerOffline(characterId)
        end
    end
end

--[[
    The source for a character id, or nil when they are not online.
]]
function Ownership.sourceOf(characterId)
    if not characterId then return nil end

    local src = online[characterId]
    if not src then return nil end

    -- A slot can remain connected while its character changes. Verify both identities before
    -- giving keys or sending notices intended for the saved owner.
    if not Bridge.playerName(src) then
        online[characterId] = nil
        Lifecycle.onOwnerOffline(characterId)
        return nil
    end
    local currentId = Bridge.characterId(src)
    if currentId ~= characterId then
        -- A restarting framework can temporarily have no player object. Keep the mapping
        -- for recovery, but never treat an unresolved character as online.
        if currentId ~= nil then
            online[characterId] = nil
            Lifecycle.onOwnerOffline(characterId)
        end
        return nil
    end

    return src
end

function Ownership.isOnline(characterId)
    return Ownership.sourceOf(characterId) ~= nil
end

function Ownership.onlineMap()
    return online
end

--[[
    Register a player as online, once their character has actually loaded.

    Waiting matters: `playerJoining` fires long before any framework has decided who the
    character is, and registering the licence there would key the whole semi-persistence system
    on the wrong identifier.
]]
local function register(src)
    src = tonumber(src)
    if not src or src <= 0 then return end
    local registration = {}
    registrations[src] = registration
    CreateThread(function()
        local characterId = Bridge.waitForCharacter(src, 60000)
        if registrations[src] ~= registration then return end
        if not characterId or not Bridge.playerName(src) then
            registrations[src] = nil
            Park.debug('could not resolve a character for %s within 60s', Bridge.playerName(src) or src)
            return
        end

        if online[characterId] == src then
            registrations[src] = nil
            return
        end
        unregister(src)
        online[characterId] = src

        -- Coming back resets every countdown against them. Done here rather than in the sweep
        -- so that a player who reconnects with thirty seconds to spare keeps their vehicle
        -- even if the sweep would have run first.
        Lifecycle.onOwnerOnline(characterId)

        Lifecycle.warnExpiring(src, characterId)
    end)
end

AddEventHandler('playerJoining', function()
    register(source)
end)

--[[
    ================================================================================================
    AND EVERYBODY WHO WAS ALREADY HERE WHEN WE STARTED.
    ================================================================================================

    Every entry in `online` came from an event that fires when a player ARRIVES: `playerJoining`,
    or the framework's own loaded event. A player who was already connected fires none of them, so
    a `restart v-park` - or v-park starting after the framework on a server with players on it -
    left the map empty while the server was full.

    Two things read it, and both were wrong in a way that looked like something else:

      the admin panel   showed every owner as offline. That is the tester's "oui par contre le
                        joueur apparait offline alors qu'il est connecte", and it is the harmless
                        half.

      the semi-persistence sweep   counts a vehicle towards expiry only while its owner is away.
                        With the map empty, every owner was away, so job and semi-persistent
                        vehicles began counting down towards deletion with their owners standing
                        next to them.

    `GetPlayers` is the answer to "who is here", it does not need an event, and `register` already
    waits for the framework to decide who each of them is - which is exactly the wait that makes
    this safe to run before the framework has finished loading.
]]
AddEventHandler('onResourceStart', function(resource)
    if resource ~= Park.resource then return end

    CreateThread(function()
        -- One frame, so that `GetPlayers` is answered by a server that has finished starting us.
        Wait(0)

        local players = GetPlayers()
        if #players == 0 then return end

        Park.log('%d player(s) were already connected - resolving their characters', #players)

        for _, src in ipairs(players) do
            register(tonumber(src) or src)
        end
    end)
end)

--[[
    Every framework announces a character change differently, and a player switching characters
    without disconnecting is a real thing on every one of them. Missing it means the previous
    character stays registered as online and their job vehicle never expires.
]]
-- A network caller can only register itself. Local framework events may supply the source.
local function loaded(src)
    local caller = tonumber(source)
    register(caller and caller > 0 and caller or src)
end

RegisterNetEvent('QBCore:Server:OnPlayerLoaded', loaded)
RegisterNetEvent('esx:playerLoaded', loaded)
RegisterNetEvent('ox:playerLoaded', loaded)

-- QBCore unloads a character before freeing its player object; cancel pending registrations.
AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
    local caller = tonumber(source)
    src = caller and caller > 0 and caller or tonumber(src)
    if src and src > 0 then unregister(src) end
end)

AddEventHandler('playerDropped', function()
    local src = source
    unregister(src)
    Persist.onPlayerDropped(src)
end)

-- ---------------------------------------------------------------------------------------
-- Permission
-- ---------------------------------------------------------------------------------------

--[[
    May `src` act on this vehicle?

    Admins always may. Beyond that, `Config.Ownership.commandScope` decides:

        'owner'   only the owner
        'keys'    the owner, or anybody the key resource says holds keys
        'anyone'  anybody

    The key check is asked of the key resource rather than inferred, because "holds the keys"
    is that resource's fact and not ours, and guessing it wrong either locks a player out of
    their own car or lets them take somebody else's.
]]
function Ownership.mayAct(src, record)
    if Bridge.isAdmin(src) then return true, 'admin' end
    if not record then return false, 'unknown' end

    local scope = (Config.Ownership and Config.Ownership.commandScope) or 'keys'

    if scope == 'anyone' then return true, 'open' end

    local characterId = Bridge.characterId(src)
    if characterId and record.owner == characterId then return true, 'owner' end

    -- A job vehicle is actionable by anybody currently holding that job.
    if record.owner_type == 'job' and record.job then
        local job = Bridge.job(src)
        local gang = Bridge.gang(src)

        if job and job.name == record.job then return true, 'job' end
        if gang and gang.name and ('gang:' .. gang.name) == record.job then return true, 'gang' end
    end

    if scope == 'keys' and record.plate then
        if Ownership.hasKeys(src, record.plate) then return true, 'keys' end
    end

    return false, 'not_yours'
end

--[[
    Does this player hold the keys to a plate?

    Asked of whichever key resource is installed. A resource with no readable answer returns
    nil, and nil is treated as NO - the fail-closed direction, chosen on purpose: letting
    somebody move a car because we could not tell whether they had the keys is worse than
    making the owner use their own command.
]]
function Ownership.hasKeys(src, plate)
    local provider = Bridge.keyProvider()
    if provider == 'none' then return false end

    local normalised = Park.plate(plate)
    if not normalised then return false end

    --[[
        Asked with BOTH spellings of the plate.

        `Park.plate` trims and upper-cases; a key resource stores whatever it was handed. Most
        trim, some do not, and `GetVehicleNumberPlateText` pads a short plate with trailing
        spaces - so "ADMIN" and "ADMIN   " are the same car and two different table keys. Two
        lookups against an in-memory table is not a cost worth reasoning about; a keyholder we
        failed to recognise over three spaces is a bug worth avoiding.
    ]]
    local spellings = { normalised }
    if type(plate) == 'string' and plate ~= normalised then
        spellings[2] = plate
    end

    local function ask(fn)
        for _, spelling in ipairs(spellings) do
            if Park.try(function() return fn(spelling) end) == true then return true end
        end
        return false
    end

    if provider == 'qs-vehiclekeys' then
        return ask(function(text) return exports['qs-vehiclekeys']:HasKeys(src, text) end)
    end

    if provider == 'qb-vehiclekeys' then
        return ask(function(text) return exports['qb-vehiclekeys']:HasKeys(src, text) end)
    end

    if provider == 'wasabi_carlock' then
        return ask(function(text) return exports.wasabi_carlock:HasKey(src, text) end)
    end

    if provider == 'mk_vehiclekeys' then
        return ask(function(text) return exports.mk_vehiclekeys:hasKey(src, text) end)
    end

    return false
end

-- ---------------------------------------------------------------------------------------
-- Transfer
-- ---------------------------------------------------------------------------------------

--[[
    Hand a persisted vehicle to somebody else.

    Used by `/vparkowner`, by the panel, and by the API so that a dealership can transfer
    persistence along with the sale.
]]
function Ownership.transfer(id, characterId, ownerType, name)
    local record = Store.get(id)
    if not record then return false, 'unknown' end

    local previous = record.owner

    Store.update(id, {
        owner = characterId,
        owner_type = ownerType or record.owner_type,
        owner_name = name,
        touched_at = Park.now(),
        -- A change of hands resets the semi-persistence countdown. The new owner has not been
        -- offline; the previous one's absence is not theirs to inherit.
        offline_secs = 0,
    })

    Park.log('%s transferred from %s to %s', id, tostring(previous), tostring(characterId))

    return true
end
