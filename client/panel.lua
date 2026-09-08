--[[
    client/panel.lua

    The bridge between the admin panel's browser and the server.

    -------------------------------------------------------------------------------------------
    THE ONLY NUI IN THIS RESOURCE
    -------------------------------------------------------------------------------------------

    It is loaded lazily and it is only ever open for staff. A player who never runs
    `/vparkadmin` never causes a single message to or from it, and the page paints nothing while
    it is closed.

    That matters more than it sounds. A NUI that is always mounted is a browser process on every
    client for the life of the session, and the most common performance complaint about
    admin-facing resources is exactly that.

    -------------------------------------------------------------------------------------------
    NUI FOCUS IS THE THING THAT GOES WRONG
    -------------------------------------------------------------------------------------------

    A stuck cursor with no way to close it is the failure everybody has had. Three defences:

      1. Focus is released in `close()`, and `close()` is called from the NUI callback, from
         ESCAPE, and from a resource stop.
      2. `onResourceStop` releases it. A panel open when an admin restarts the resource would
         otherwise leave the player unable to move with nothing left running to fix it.
      3. A key handler watches for ESCAPE while open, independently of the browser, so a page
         that has crashed can still be dismissed.
]]

Panel = {}

local open = false
local context

local function send(message)
    SendNUIMessage(message)
end

-- ---------------------------------------------------------------------------------------
-- Opening and closing
-- ---------------------------------------------------------------------------------------

function Panel.close()
    if not open then return end

    open = false
    SetNuiFocus(false, false)
    send({ action = 'close' })
end

RegisterNetEvent('vpark:client:panelOpen', function(payload, data)
    if type(payload) ~= 'table' then return end

    context = payload
    open = true

    SetNuiFocus(true, true)

    send({
        action = 'open',
        context = payload,
        data = data,
        locale = Panel.strings(),
    })
end)

RegisterNetEvent('vpark:client:panelData', function(data)
    if not open then return end
    send({ action = 'data', data = data })
end)

RegisterNetEvent('vpark:client:panelResult', function(ok, message)
    if not open then return end
    send({ action = 'result', ok = ok == true, message = message })

    -- Also notify normally, so an action taken from the panel is confirmed the same way as
    -- one taken from a command - and so it is still visible after the panel is closed.
    Compat.notify(message, ok and 'success' or 'error')
end)

RegisterNetEvent('vpark:client:panelTrash', function(data)
    if not open then return end
    send({ action = 'trash', data = data })
end)

RegisterNetEvent('vpark:client:panelCleanup', function(report)
    if not open then return end
    send({ action = 'cleanup', data = report })
end)

-- ---------------------------------------------------------------------------------------
-- Callbacks from the page
-- ---------------------------------------------------------------------------------------

RegisterNUICallback('close', function(_, cb)
    Panel.close()
    cb({ ok = true })
end)

RegisterNUICallback('query', function(data, cb)
    TriggerServerEvent('vpark:server:panelQuery', data)
    cb({ ok = true })
end)

RegisterNUICallback('action', function(data, cb)
    if type(data) ~= 'table' or type(data.action) ~= 'string' or type(data.id) ~= 'string' then
        cb({ ok = false })
        return
    end

    -- Teleporting to a vehicle closes the panel. Leaving it open over a screen the player has
    -- just been moved to means they cannot see where they arrived, which is the one thing they
    -- ran the action to find out.
    if data.action == 'teleportTo' then
        Panel.close()
    end

    TriggerServerEvent('vpark:server:panelAction', data.action, data.id, data.value)
    cb({ ok = true })
end)

RegisterNUICallback('trash', function(data, cb)
    TriggerServerEvent('vpark:server:panelTrash', data and data.page or 1)
    cb({ ok = true })
end)

RegisterNUICallback('cleanupPreview', function(_, cb)
    TriggerServerEvent('vpark:server:panelCleanupPreview')
    cb({ ok = true })
end)

--[[
    Draw a temporary marker on a vehicle's position, from the panel's "show me" button.

    A three-dimensional marker and a blip, both timed out, so an admin can find a vehicle
    without teleporting to it - which is the safer thing to do in the middle of a scene.
]]
RegisterNUICallback('mark', function(data, cb)
    cb({ ok = true })

    local x, y, z = tonumber(data and data.x), tonumber(data and data.y), tonumber(data and data.z)
    if not x or not y or not z then return end

    SetNewWaypoint(x, y)

    local blip = AddBlipForCoord(x, y, z)
    SetBlipSprite(blip, 225)
    SetBlipColour(blip, 5)
    SetBlipScale(blip, 0.9)
    SetBlipAsShortRange(blip, false)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName('v-park')
    EndTextCommandSetBlipName(blip)

    CreateThread(function()
        Wait(60000)
        if DoesBlipExist(blip) then RemoveBlip(blip) end
    end)
end)

-- ---------------------------------------------------------------------------------------
-- Escape, and the safety net
-- ---------------------------------------------------------------------------------------

CreateThread(function()
    while true do
        if open then
            -- 200 is ESCAPE. Read every frame only while the panel is open, which is the one
            -- place in this resource that a per-frame loop is justified: a stuck cursor is
            -- the worst thing a NUI can do to somebody and this is the last way out of it.
            Wait(0)
            if IsControlJustReleased(0, 200) then
                Panel.close()
            end
        else
            Wait(500)
        end
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= Park.resource then return end
    -- Unconditional, not `if open`: the flag is this file's opinion and the focus is the
    -- game's fact, and if they have disagreed then this is the last chance to fix it.
    SetNuiFocus(false, false)
end)

-- ---------------------------------------------------------------------------------------
-- Strings for the page
--
-- The panel is translated by handing it the strings, rather than by shipping a copy of the
-- locale files to the browser. One source of truth, and a server that adds a language does not
-- have to touch any JavaScript.
-- ---------------------------------------------------------------------------------------

function Panel.strings()
    local keys = {
        'panel.title', 'panel.subtitle', 'panel.search', 'panel.close',
        'panel.filter_all', 'panel.filter_near', 'panel.filter_live', 'panel.filter_idle',
        'panel.filter_wrecked', 'panel.filter_semi', 'panel.filter_owned', 'panel.filter_job',
        'panel.filter_unowned', 'panel.filter_broken',
        'panel.sort_recent', 'panel.sort_distance', 'panel.sort_idle', 'panel.sort_plate',
        'panel.sort_model',
        'panel.col_vehicle', 'panel.col_owner', 'panel.col_where', 'panel.col_state',
        'panel.col_actions',
        'panel.act_goto', 'panel.act_bring', 'panel.act_mark', 'panel.act_repair',
        'panel.act_clean', 'panel.act_refuel', 'panel.act_unlock', 'panel.act_garage',
        'panel.act_impound', 'panel.act_delete', 'panel.act_rename', 'panel.act_owner',
        'panel.tab_vehicles', 'panel.tab_trash', 'panel.tab_cleanup',
        'panel.trash_empty', 'panel.trash_restore', 'panel.cleanup_run', 'panel.cleanup_empty',
        'panel.cleanup_note',
        'panel.in_world', 'panel.stored', 'panel.wrecked', 'panel.idle_due',
        'panel.no_results', 'panel.page', 'panel.of', 'panel.total',
        'panel.confirm', 'panel.cancel', 'panel.confirm_delete', 'panel.choose_garage',
        'panel.rename_prompt', 'panel.owner_prompt', 'panel.refuel_prompt',
        'panel.summary_total', 'panel.summary_live', 'panel.summary_pending',
        'panel.grace', 'panel.idle', 'panel.never_used',
    }

    local out = {}
    for _, key in ipairs(keys) do
        out[key] = L(key)
    end

    return out
end
