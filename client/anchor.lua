--[[
    client/anchor.lua

    The anchor: dropping it, raising it, and putting it back after a restart.

    -------------------------------------------------------------------------------------------
    WHY THIS EXISTS
    -------------------------------------------------------------------------------------------

    A boat is restored to the exact coordinates it was left at, and then it drifts, because a
    boat on water is meant to. No amount of placement accuracy fixes that: the vehicle is where
    the database says it is, and the water moves it afterwards. Sitting on top of the problem
    with a hard freeze would work and would look wrong - a boat that does not ride the swell
    reads as a bug, not as a moored boat.

    The game already has the answer. `SET_BOAT_ANCHOR` is what the world's own moored boats use:
    the boat holds its position, still rides the water, and behaves normally again when it comes
    up. `CAN_ANCHOR_BOAT_HERE` has to be granted first, because the game otherwise refuses in
    open water - which is exactly where somebody wants to anchor.

    -------------------------------------------------------------------------------------------
    WHAT THE SERVER OWNS AND WHAT THIS FILE OWNS
    -------------------------------------------------------------------------------------------

    The server owns whether a vehicle is anchored. It is a persisted property - `anchored`, in
    the `anchor` schema group - so it survives a restart, and it is replicated as a statebag so
    that every client holds the same boat in the same place. This file applies it.

    The distinction matters for the same reason it mattered for the deformation: a value that
    every client decides for itself is a value two players see differently.

    -------------------------------------------------------------------------------------------
    WHY IT IS NEVER REPORTED AS RAISED
    -------------------------------------------------------------------------------------------

    `Properties.capture` reports `anchored = true` or nothing at all, never `false`. An anchor
    comes up because a person decides it should, and that path tells the server directly. Every
    other way the state can appear to be off - ownership migrating, the boat not streamed in yet,
    `IsBoatAnchoredAndFrozen` answering for the frozen variant only - is the game losing the
    value rather than somebody choosing it.

    That is the neon lesson applied before it costs anything: a capture that can report `false`
    is a capture that can unmoor a boat overnight.
]]

Anchor = {}

-- entity -> true, for the vehicles this client currently has moored. The anchor is applied
-- locally on every client, so this is per-client bookkeeping and not a source of truth.
local anchored = {}

-- entity -> true, set by `Properties.apply` and consumed by `Placement.place`. An anchor
-- dropped before the placement would moor the boat to wherever the server created it.
local wanted = {}

local function options()
    return (Config and Config.Anchor) or {}
end

local function enabled()
    return options().enabled ~= false
end

--[[
    May this vehicle be anchored at all?

    By class, from `Config.Anchor.classes`. Boats only by default: every other class is held by
    freezing the entity outright, and a frozen entity IGNORES POSITION WRITES - so an admin
    teleport or a tow script silently fails on it until the anchor comes up.
]]
function Anchor.allowed(vehicle)
    if not enabled() then return false end
    if not DoesEntityExist(vehicle) then return false end

    local classes = options().classes
    if type(classes) ~= 'table' then return false end

    return classes[GetVehicleClass(vehicle)] == true
end

local function isBoat(vehicle)
    -- The class rather than `GetVehicleType`, because the class is what the config is written
    -- in and the two disagree on a handful of models.
    return GetVehicleClass(vehicle) == 14
end

--[[
    Put the anchor down on a vehicle that is where it belongs.

    Best effort about network control: dropping an anchor is a write to the entity, so a client
    without control writes it locally and the owner overwrites it on its next sync. Every client
    applies the statebag, though, so the owner's own copy of this runs too - which is what makes
    the result stable without this call having to win a race.
]]
local function hold(vehicle)
    if not DoesEntityExist(vehicle) then return false end

    if isBoat(vehicle) then
        -- Granted first. Without it the game refuses to anchor in open water, which is most of
        -- the water somebody wants to anchor in.
        if CanAnchorBoatHere then CanAnchorBoatHere(vehicle, true) end
        if CanAnchorBoatHereIgnorePlayers then CanAnchorBoatHereIgnorePlayers(vehicle, true) end

        if SetBoatFrozenWhenAnchored then
            SetBoatFrozenWhenAnchored(vehicle, options().frozenWhenAnchored == true)
        end

        -- The boat stays put while somebody is at the wheel, which is the whole point: an
        -- anchor that comes up the moment you sit down is not an anchor.
        if SetBoatRemainsAnchoredWhilePlayerIsDriver then
            SetBoatRemainsAnchoredWhilePlayerIsDriver(vehicle, true)
        end

        if SetBoatAnchor then SetBoatAnchor(vehicle, true) end
    else
        -- No anchor of its own. A freeze is visibly not the same thing, which is why the config
        -- ships with this path switched off.
        FreezeEntityPosition(vehicle, true)
    end

    anchored[vehicle] = true
    return true
end

local function release(vehicle)
    anchored[vehicle] = nil
    wanted[vehicle] = nil

    if not DoesEntityExist(vehicle) then return false end

    if isBoat(vehicle) then
        if SetBoatAnchor then SetBoatAnchor(vehicle, false) end
        if SetBoatRemainsAnchoredWhilePlayerIsDriver then
            SetBoatRemainsAnchoredWhilePlayerIsDriver(vehicle, false)
        end
        if CanAnchorBoatHere then CanAnchorBoatHere(vehicle, false) end
    else
        FreezeEntityPosition(vehicle, false)
    end

    return true
end

function Anchor.isAnchored(vehicle)
    if anchored[vehicle] then return true end
    if wanted[vehicle] then return true end
    return false
end

--[[
    What a capture should report.

    `true` or nil, never false. See the note at the top of the file.
]]
function Anchor.stored(vehicle)
    if not enabled() then return nil end
    if Anchor.isAnchored(vehicle) then return true end

    -- The frozen variant is the only one the game will answer for, so it is worth asking: a
    -- boat this client did not moor itself but which the game reports as moored is moored.
    if IsBoatAnchoredAndFrozen and isBoat(vehicle) and IsBoatAnchoredAndFrozen(vehicle) then
        return true
    end

    return nil
end

--[[
    Remember what the restore wants, without acting on it. Called by `Properties.apply`.
]]
function Anchor.want(vehicle, on)
    if on then
        wanted[vehicle] = true
    else
        wanted[vehicle] = nil
    end
end

--[[
    Act on it. Called by `Placement.place` once the vehicle is standing where it belongs.
]]
function Anchor.settle(vehicle)
    if not wanted[vehicle] then return false end
    if not enabled() then return false end

    wanted[vehicle] = nil
    return hold(vehicle)
end

--[[
    ================================================================================================
    THE REPLICATED FACT, APPLIED ON EVERY CLIENT.
    ================================================================================================

    Same shape and same reason as `vpark:deform`: a value every client decides for itself is a
    value two players standing beside the same boat see differently. The server sets this bag
    when the anchor is dropped or raised, and every client in scope acts on it.
]]
AddStateBagChangeHandler('vpark:anchored', '', function(bagName, _, value)
    if not enabled() then return end

    CreateThread(function()
        local entity
        local deadline = Park.ticks() + 10000

        repeat
            entity = GetEntityFromStateBagName(bagName)
            if entity and entity > 0 and DoesEntityExist(entity) then break end
            Wait(100)
        until Park.ticks() > deadline

        if not entity or entity == 0 or not DoesEntityExist(entity) then return end

        -- A freshly created entity reports its class as 0 for a frame or two, and the class is
        -- what decides whether this vehicle may be anchored at all.
        local ready = Park.ticks() + 5000
        while GetEntityModel(entity) == 0 and Park.ticks() < ready do Wait(50) end

        if value == true then
            if Anchor.allowed(entity) then hold(entity) end
        else
            release(entity)
        end
    end)
end)

-- ---------------------------------------------------------------------------------------
-- Asking for it
-- ---------------------------------------------------------------------------------------

--[[
    The vehicle this player is asking about: the one they are in, or the nearest one they are
    not. Sitting in it is the common case and the one the permission check is written for.
]]
local function subject()
    local ped = PlayerPedId()

    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle and vehicle ~= 0 and DoesEntityExist(vehicle) then return vehicle end

    vehicle = GetVehiclePedIsIn(ped, true)
    if vehicle and vehicle ~= 0 and DoesEntityExist(vehicle) then return vehicle end

    return 0
end

--[[
    Toggle the anchor on the vehicle the player is in.

    THE CLIENT ASKS AND THE SERVER DECIDES. Nothing here writes to the vehicle: the server
    checks who is asking, stores the answer and replicates it, and the statebag handler above
    is what actually moves anything. A client that could anchor a boat by itself would be a
    client that could moor somebody else's boat in the middle of a race.

    Exported so a radial menu, an F1 menu or any other interaction resource can offer it:

        exports['v-park']:ToggleAnchor()
]]
function Anchor.toggle()
    local vehicle = subject()

    if vehicle == 0 then
        Compat.notify(L('anchor.no_vehicle'), 'error')
        return false
    end

    if not Anchor.allowed(vehicle) then
        Compat.notify(L('anchor.wrong_class'), 'error')
        return false
    end

    local netId = NetworkGetNetworkIdFromEntity(vehicle)
    if not netId or netId == 0 then
        Compat.notify(L('anchor.no_vehicle'), 'error')
        return false
    end

    TriggerServerEvent('vpark:server:anchor', netId, not Anchor.isAnchored(vehicle))
    return true
end

exports('ToggleAnchor', Anchor.toggle)

--[[
    And the same thing as an event, for a menu that would rather not depend on an export.

        TriggerEvent('vpark:anchor')            -- toggle
        TriggerEvent('vpark:anchor', true)      -- drop it
        TriggerEvent('vpark:anchor', false)     -- raise it
]]
AddEventHandler('vpark:anchor', function(on)
    if on == nil then
        Anchor.toggle()
        return
    end

    local vehicle = subject()
    if vehicle == 0 or not Anchor.allowed(vehicle) then return end

    local netId = NetworkGetNetworkIdFromEntity(vehicle)
    if not netId or netId == 0 then return end

    TriggerServerEvent('vpark:server:anchor', netId, on == true)
end)

--[[
    `/vparkanchor` with no argument. The command cannot know which vehicle is meant - the player
    might be looking at one rather than sitting in it - so the server bounces it back here, where
    the question is answerable.
]]
RegisterNetEvent('vpark:client:anchorToggle', function()
    Anchor.toggle()
end)

-- The server answering: applied by the statebag, so all this does is say something.
RegisterNetEvent('vpark:client:anchored', function(on)
    Compat.notify(L(on and 'anchor.dropped' or 'anchor.raised'), 'success')
end)

--[[
    Handles are reused. An entry left against a freed one is an anchor the game can hand to a
    completely different vehicle, which is the same trap `Deformation.clear` exists for.
]]
function Anchor.forget(vehicle)
    anchored[vehicle] = nil
    wanted[vehicle] = nil
end
