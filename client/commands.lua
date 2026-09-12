-- Author: vyrriox
--[[
    client/commands.lua

    The client half of the commands: the questions only a client can answer.

    Every command is REGISTERED on the server, including the ones that are about the player's
    own screen. That is deliberate: one registration means one permission check, one name in
    `Config.Commands`, and no way for a client-side command to exist that the server does not
    know about.

    So this file has no `RegisterCommand` in it. It answers.
]]

-- ---------------------------------------------------------------------------------------
-- Which vehicle does the player mean?
-- ---------------------------------------------------------------------------------------

--[[
    The vehicle the player is in, or the one they are looking at.

    The raycast is the second half and it matters: `/vpark` while standing beside a car should
    park that car. A command that only works from the driver's seat is one that has to be
    explained.

    `StartShapeTestRay` from the camera, not from the ped, because "looking at" means what is
    on screen and the ped's head does not always agree with the camera on a third-person view.
]]
-- Print the server's authorized property report as one copyable F8 block.
RegisterNetEvent('vpark:client:propsReport', function(lines)
    if type(lines) ~= 'table' then return end
    local out = { '[v-park] BEGIN vparkprops' }
    for index = 1, math.min(#lines, 100) do
        if type(lines[index]) == 'string' then
            local line = lines[index]:sub(1, 2048):gsub('%^%d', ''):gsub('[%c]', ' ')
            out[#out + 1] = line
        end
    end
    out[#out + 1] = '[v-park] END vparkprops'
    print(table.concat(out, '\n'))
end)

local function vehicleInFront()
    local ped = PlayerPedId()

    local inside = GetVehiclePedIsIn(ped, false)
    if inside ~= 0 and DoesEntityExist(inside) then return inside end

    local camera = GetGameplayCamCoord()
    local rotation = GetGameplayCamRot(2)
    local radians = { x = math.rad(rotation.x), z = math.rad(rotation.z) }

    local direction = vector3(
        -math.sin(radians.z) * math.abs(math.cos(radians.x)),
        math.cos(radians.z) * math.abs(math.cos(radians.x)),
        math.sin(radians.x)
    )

    local target = camera + direction * 12.0

    -- Flag 2 is vehicles, and only vehicles: a ray that also hits the world would stop at a
    -- wall behind the car and report nothing, and one that also hits peds would report a
    -- pedestrian standing in front of it.
    local handle = StartShapeTestRay(camera.x, camera.y, camera.z, target.x, target.y, target.z, 2, ped, 0)

    local result, hit, _, _, entity = 0, false, nil, nil, 0
    for _ = 1, 20 do
        result, hit, _, _, entity = GetShapeTestResult(handle)
        if result ~= 1 then break end
        Wait(0)
    end

    if hit and entity and entity ~= 0 and DoesEntityExist(entity) and IsEntityAVehicle(entity) then
        return entity
    end

    -- Nothing under the crosshair. The nearest vehicle within a short reach is the last
    -- fallback, so that `/vpark` works while standing beside a car and looking at the sky.
    local position = GetEntityCoords(ped)
    local nearest, nearestDistance

    for _, vehicle in ipairs(GetGamePool('CVehicle')) do
        local distance = #(GetEntityCoords(vehicle) - position)
        if distance < 6.0 and (not nearestDistance or distance < nearestDistance) then
            nearest, nearestDistance = vehicle, distance
        end
    end

    return nearest
end

RegisterNetEvent('vpark:client:describeCurrent', function(token)
    local vehicle = vehicleInFront()

    if not vehicle or not DoesEntityExist(vehicle) then
        TriggerServerEvent('vpark:server:describedCurrent', nil, token)
        return
    end

    TriggerServerEvent('vpark:server:describedCurrent', Track.describe(vehicle), token)
end)

-- ---------------------------------------------------------------------------------------
-- Waypoints
-- ---------------------------------------------------------------------------------------

RegisterNetEvent('vpark:client:waypoint', function(x, y)
    if type(x) ~= 'number' or type(y) ~= 'number' then return end
    SetNewWaypoint(x, y)
end)

-- ---------------------------------------------------------------------------------------
-- Notifications
-- ---------------------------------------------------------------------------------------

RegisterNetEvent('vpark:client:notify', function(message, kind)
    if type(message) ~= 'string' then return end
    Compat.notify(message, kind)
end)

-- ---------------------------------------------------------------------------------------
-- The probe tester
--
-- `/vparkprobe` runs the placement probe where the player is standing and prints the answer.
-- It is the tool for tuning `Config.Placement.probe.shrink` against a specific parking space,
-- and it exists because that number is the one an operator with an unusual MLO will need to
-- change and has no other way to measure.
-- ---------------------------------------------------------------------------------------

--[[
    How far is every restored vehicle from where the database says it is?

    Five releases of reasoning about "they are not quite in the right place" produced five
    different theories and the same report each time. This turns it into a number per vehicle
    per axis, which is the only thing that can settle it.

    `dz` on its own points at the ground correction or the model's origin height; `dx`/`dy`
    together point at the search having nudged it; a heading that differs points at the
    rotation; and `frozen = no` on a vehicle nobody is driving points at the freeze never
    having taken.
]]
RegisterNetEvent('vpark:client:where', function(wanted)
    local rows = Stream.audit(wanted)

    if #rows == 0 then
        print('^3[v-park]^7 no restored vehicles are being tracked on this client')
        return
    end

    print(('^2[v-park]^7 %d restored vehicle(s), worst first:'):format(#rows))

    for index = 1, math.min(#rows, 15) do
        local row = rows[index]

        print(('^2[v-park]^7   %-14s %-16s off by %6.3f m   dx %+.3f  dy %+.3f  dz %+.3f  heading %+.2f')
            :format(row.id, tostring(row.model), row.delta, row.dx, row.dy, row.dz, row.dHeading))

        print(('^2[v-park]^7                  frozen %s   dressed %s   owned by me %s   placed here %s')
            :format(row.frozen and 'yes' or '^1NO^7',
                    row.dressed and 'yes' or '^1NO^7',
                    row.mine and 'yes' or 'no',
                    row.placedHere and 'yes' or 'no'))
    end

    if #rows > 15 then
        print(('^2[v-park]^7   ... and %d more'):format(#rows - 15))
    end
end)

--[[
    Go there.

    The server asks rather than doing it itself: a ped moved by `SetEntityCoords` from the server
    arrives, but the position the server holds for that player does not follow - and v-park
    nominates a client, measures despawn distances and checks reports against exactly that value.
    See `Actions.teleportTo`.

    The collision wait is what stops the player falling through the map at the far end, which is
    the ordinary hazard of arriving somewhere that has not streamed in yet.
]]
RegisterNetEvent('vpark:client:teleport', function(target)
    if type(target) ~= 'table' then return end

    local x = tonumber(target.x)
    local y = tonumber(target.y)
    local z = tonumber(target.z)
    if not x or not y or not z then return end

    CreateThread(function()
        local ped = PlayerPedId()

        DoScreenFadeOut(200)
        local fading = GetGameTimer() + 2000
        while not IsScreenFadedOut() and GetGameTimer() < fading do Wait(0) end

        SetEntityCoordsNoOffset(ped, x, y, z, false, false, false)

        if tonumber(target.heading) then
            SetEntityHeading(ped, tonumber(target.heading) % 360.0)
        end

        -- Hold the ped still until the ground under it exists, or it falls through the world
        -- while the map streams in.
        local deadline = GetGameTimer() + 8000
        FreezeEntityPosition(ped, true)

        while not HasCollisionLoadedAroundEntity(ped) and GetGameTimer() < deadline do
            Wait(50)
        end

        FreezeEntityPosition(ped, false)
        DoScreenFadeIn(400)
    end)
end)

RegisterNetEvent('vpark:client:probe', function(modelName)
    local ped = PlayerPedId()
    local position = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)

    local model
    local inside = GetVehiclePedIsIn(ped, false)

    if type(modelName) == 'string' and modelName ~= '' then
        model = GetHashKey(modelName)
    elseif inside ~= 0 then
        model = GetEntityModel(inside)
        position = GetEntityCoords(inside)
        heading = GetEntityHeading(inside)
    else
        local vehicle = vehicleInFront()
        if vehicle then
            model = GetEntityModel(vehicle)
            position = GetEntityCoords(vehicle)
            heading = GetEntityHeading(vehicle)
        end
    end

    if not model then
        Compat.notify(L('probe.no_model'), 'error')
        return
    end

    local dims = Placement.dimensions(model)
    if not dims then
        Compat.notify(L('probe.no_dimensions'), 'error')
        return
    end

    local free, reason, blocker = Placement.probe(model, position, heading, inside ~= 0 and inside or nil)

    print(('^2[v-park]^7 probe at %.2f, %.2f, %.2f heading %.1f'):format(
        position.x, position.y, position.z, heading))
    -- Read through the whole chain rather than off `Config.Placement.probe` directly: this
    -- is the command an operator runs when their config is the thing that is wrong, and it
    -- must not be the one that raises on a missing section.
    local shrink = tonumber(Config.Placement and Config.Placement.probe
        and Config.Placement.probe.shrink) or 0.88

    print(('^2[v-park]^7 model %s  box %.2f x %.2f x %.2f  shrink %.2f'):format(
        tostring(modelName or model),
        dims.half.x * 2, dims.half.y * 2, dims.half.z * 2,
        shrink))

    if free then
        print('^2[v-park]^7 result: ^2FREE^7 - a vehicle would be placed exactly here')
        Compat.notify(L('probe.free'), 'success')
    else
        local detail = reason
        if reason == 'vehicle' and blocker then
            detail = ('vehicle %s (%s)'):format(
                tostring(blocker),
                Placement.isAmbient(blocker) and 'ambient, would be cleared' or 'NOT ambient, would not be touched')
        end

        print(('^3[v-park]^7 result: ^3BLOCKED^7 by %s'):format(tostring(detail)))

        local found, foundHeading = Placement.search(model, position, heading, inside ~= 0 and inside or nil)
        if found then
            print(('^2[v-park]^7 the search would place it %.2f m away, heading %.1f'):format(
                #(found - position), foundHeading))
        else
            print(('^3[v-park]^7 the search found nothing; the fallback is `%s`'):format(
                tostring(Config.Placement and Config.Placement.fallback)))
        end

        Compat.notify(L('probe.blocked', tostring(reason)), 'warn')
    end
end)

-- ---------------------------------------------------------------------------------------
-- Debug overlay
-- ---------------------------------------------------------------------------------------

local debugging = false

RegisterNetEvent('vpark:client:debug', function(enabled)
    debugging = enabled == true
    Compat.notify(debugging and L('debug.overlay_on') or L('debug.overlay_off'), 'info')
end)

function IsDebugging() return debugging end

--[[
    The overlay.

    Drawn only while `/vparkdebug` is on, which is why this is the second and last per-frame
    loop in the resource. It draws a marker over every tracked vehicle, its id, whether it is
    frozen, and the blocked zones nearby.
]]
CreateThread(function()
    while true do
        if not debugging then
            Wait(1000)
        else
            Wait(0)

            local ped = PlayerPedId()
            local playerPosition = GetEntityCoords(ped)

            for id, record in pairs(Stream.all()) do
                if record.entity and DoesEntityExist(record.entity) then
                    local position = GetEntityCoords(record.entity)
                    local distance = #(position - playerPosition)

                    if distance < 120.0 then
                        local red, green, blue = 80, 220, 120
                        if record.frozen then red, green, blue = 90, 160, 240 end

                        DrawMarker(0, position.x, position.y, position.z + 2.2, 0.0, 0.0, 0.0,
                            0.0, 0.0, 0.0, 0.5, 0.5, 0.5, red, green, blue, 140,
                            false, true, 2, false, nil, nil, false)

                        if distance < 40.0 then
                            SetTextScale(0.28, 0.28)
                            SetTextFont(4)
                            SetTextColour(255, 255, 255, 200)
                            SetTextCentre(true)
                            SetTextOutline()
                            BeginTextCommandDisplayText('STRING')
                            AddTextComponentSubstringPlayerName(
                                ('%s%s'):format(id, record.frozen and ' [frozen]' or ''))

                            local onScreen, screenX, screenY = World3dToScreen2d(
                                position.x, position.y, position.z + 1.6)

                            if onScreen then
                                EndTextCommandDisplayText(screenX, screenY)
                            else
                                EndTextCommandDisplayText(0.0, 0.0)
                            end
                        end
                    end
                end
            end

            -- Blocked zones, as a circle of markers, when the config asks for it.
            if Config.ZoneOptions and Config.ZoneOptions.debugDraw then
                for _, zone in ipairs(Zones.near(playerPosition, 120.0)) do
                    if zone.type == 'circle' then
                        DrawMarker(1, zone.centre.x, zone.centre.y, zone.centre.z - 1.0,
                            0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                            zone.radius * 2, zone.radius * 2, 1.0,
                            220, 90, 90, 40, false, false, 2, false, nil, nil, false)
                    end
                end
            end
        end
    end
end)
