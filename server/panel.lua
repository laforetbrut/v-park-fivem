--[[
    server/panel.lua

    The data behind the admin panel.

    -------------------------------------------------------------------------------------------
    THE PANEL IS A VIEW. THE SERVER IS THE AUTHORITY.
    -------------------------------------------------------------------------------------------

    Every action the panel offers is `server/actions.lua` doing exactly what the equivalent chat
    command does, with the same permission check, in the same place. The panel hiding a button
    is a convenience for whoever is looking at it and is never the security boundary - a hidden
    button can be un-hidden, and an NUI callback can be sent by anything.

    So `Panel.action` re-checks admin on every single call. It looks redundant next to the
    `/vparkadmin` permission that opened the panel in the first place, and it is not: the panel
    stays open across a change of permissions, and nothing stops a client sending the event
    without ever opening it.

    -------------------------------------------------------------------------------------------
    PAGINATION IS SERVER-SIDE, ALWAYS
    -------------------------------------------------------------------------------------------

    The panel never receives the whole table. On a server with twenty thousand vehicles that is
    tens of megabytes over the network, held in a browser, filtered in JavaScript - which is
    both slow and pointless, because the sort and the filter are cheap here and free to send.
]]

Panel = {}

-- src -> the last query they ran, so a refresh repeats it rather than resetting to page one.
local sessions = {}

local function panelConfig()
    return (Config and Config.Panel) or {}
end

-- ---------------------------------------------------------------------------------------
-- Rows
-- ---------------------------------------------------------------------------------------

--[[
    One vehicle, as the panel needs to see it.

    Deliberately not the whole record: the property blob is several hundred bytes of mod slots
    that no view renders, and sending it for twenty-five rows on every refresh is most of the
    payload for none of the value.
]]
local function toRow(record, from)
    local now = Park.now()
    local live = Store.isLive(record.id)

    local distance
    if from then
        local dx, dy = record.pos_x - from.x, record.pos_y - from.y
        distance = math.floor(math.sqrt(dx * dx + dy * dy))
    end

    local grace = Lifecycle.graceRemaining(record)
    local idleDays = Lifecycle.idleDaysFor(record)

    local idleFor
    if now > 0 and (record.last_used_at or 0) > 0 then
        idleFor = now - record.last_used_at
    end

    return {
        id = record.id,
        plate = record.plate,
        model = record.model_name,
        class = record.class,
        className = Classes.key(record.class),
        owner = record.owner_name or record.owner,
        ownerType = record.owner_type,
        ownerOnline = record.owner ~= nil and Ownership.isOnline(record.owner) or false,
        job = record.job,
        label = record.statebags and record.statebags['vpark:label'] or nil,

        x = record.pos_x,
        y = record.pos_y,
        z = record.pos_z,
        distance = distance,
        bucket = record.bucket,
        interior = record.interior ~= 0,

        bodyHealth = math.floor(record.body_health or 0),
        engineHealth = math.floor(record.engine_health or 0),
        fuel = record.fuel and math.floor(record.fuel) or nil,
        wrecked = record.wrecked == true,

        live = live,
        invalidModel = record.invalidModel == true,

        idleSeconds = idleFor,
        idleText = idleFor and Park.duration(idleFor) or nil,
        idleDue = (idleDays > 0 and idleFor) and (idleFor > idleDays * 86400) or false,

        graceSeconds = grace,
        graceText = grace and Park.duration(math.max(0, grace)) or nil,

        lastGarage = record.last_garage,
        touchedText = now > 0 and Park.duration(now - (record.touched_at or now)) or nil,
    }
end

-- ---------------------------------------------------------------------------------------
-- Querying
-- ---------------------------------------------------------------------------------------

--[[
    Filter, sort and page the store.

    `query` is what the panel sent, and every field of it is optional and every one is
    validated: it arrives from a browser, and a `limit` of ten million would be an easy way to
    make the server build a very large table.
]]
function Panel.query(src, query)
    query = type(query) == 'table' and query or {}

    local pageSize = math.floor(Park.clamp(tonumber(query.pageSize) or tonumber(panelConfig().pageSize) or 25, 5, 100))
    local page = math.max(1, math.floor(tonumber(query.page) or 1))

    local search = type(query.search) == 'string' and Park.trim(query.search):lower() or ''
    local filter = type(query.filter) == 'string' and query.filter or 'all'
    local sort = type(query.sort) == 'string' and query.sort or 'recent'

    local ped = GetPlayerPed(src)
    local from
    if ped and ped ~= 0 and DoesEntityExist(ped) then
        local position = GetEntityCoords(ped)
        from = { x = position.x, y = position.y, z = position.z }
    end

    local nearRadius = tonumber(query.radius) or tonumber(panelConfig().nearRadius) or 150.0

    local matched = {}

    for _, record in pairs(Store.all()) do
        local keep = true

        if filter == 'near' then
            if not from then
                keep = false
            else
                local dx, dy = record.pos_x - from.x, record.pos_y - from.y
                keep = (dx * dx + dy * dy) <= nearRadius * nearRadius
            end
        elseif filter == 'live' then
            keep = Store.isLive(record.id)
        elseif filter == 'wrecked' then
            keep = record.wrecked == true
        elseif filter == 'idle' then
            local days = Lifecycle.idleDaysFor(record)
            local now = Park.now()
            keep = days > 0
                and (record.last_used_at or 0) > 0
                and (now - record.last_used_at) > days * 86400
        elseif filter == 'semi' then
            keep = Lifecycle.semiRules(record.owner_type) ~= nil
        elseif filter == 'unowned' then
            keep = record.owner_type == 'unowned'
        elseif filter == 'owned' then
            keep = record.owner_type == 'owned'
        elseif filter == 'job' then
            keep = record.owner_type == 'job'
        elseif filter == 'broken' then
            keep = record.invalidModel == true
        elseif filter == 'online' then
            -- Whose owner is connected right now. The most useful filter there is for a staff
            -- member dealing with a live situation: it is the set of vehicles somebody could
            -- walk out and drive in the next minute.
            keep = record.owner ~= nil and Ownership.isOnline(record.owner)
        elseif filter == 'offline' then
            keep = record.owner ~= nil and not Ownership.isOnline(record.owner)
        end

        if keep and search ~= '' then
            keep = (record.plate or ''):lower():find(search, 1, true) ~= nil
                or (record.model_name or ''):lower():find(search, 1, true) ~= nil
                or (record.owner_name or ''):lower():find(search, 1, true) ~= nil
                or (record.owner or ''):lower():find(search, 1, true) ~= nil
                or record.id:lower():find(search, 1, true) ~= nil
        end

        if keep then
            matched[#matched + 1] = record
        end
    end

    -- Sorting. `distance` is only meaningful when we know where the requester is, and falls
    -- back to `recent` rather than producing an arbitrary order that looks sorted.
    if sort == 'distance' and from then
        table.sort(matched, function(a, b)
            local da = (a.pos_x - from.x) ^ 2 + (a.pos_y - from.y) ^ 2
            local db = (b.pos_x - from.x) ^ 2 + (b.pos_y - from.y) ^ 2
            return da < db
        end)
    elseif sort == 'idle' then
        table.sort(matched, function(a, b)
            return (a.last_used_at or 0) < (b.last_used_at or 0)
        end)
    elseif sort == 'plate' then
        table.sort(matched, function(a, b) return (a.plate or '') < (b.plate or '') end)
    elseif sort == 'model' then
        table.sort(matched, function(a, b) return (a.model_name or '') < (b.model_name or '') end)
    else
        table.sort(matched, function(a, b) return (a.touched_at or 0) > (b.touched_at or 0) end)
    end

    local total = #matched
    local pages = math.max(1, math.ceil(total / pageSize))
    if page > pages then page = pages end

    local rows = {}
    local first = (page - 1) * pageSize + 1
    local last = math.min(first + pageSize - 1, total)

    for i = first, last do
        rows[#rows + 1] = toRow(matched[i], from)
    end

    sessions[src] = { page = page, filter = filter, sort = sort, search = search, radius = nearRadius }

    local store = Store.stats()

    return {
        rows = rows,
        page = page,
        pages = pages,
        total = total,
        pageSize = pageSize,
        filter = filter,
        sort = sort,
        search = query.search or '',
        summary = {
            total = store.total,
            live = store.live,
            dirty = store.dirty,
            wrecked = store.wrecked,
            byType = store.byType,
            matched = total,
        },
    }
end

--[[
    Everything about one vehicle, for the detail view.

    A separate call rather than more fields on every row: the property table is several hundred
    bytes of mod slots that no list renders, and sending it for twenty-five rows on every
    refresh would be most of the payload for none of the value.
]]
function Panel.detail(src, id)
    local record = Store.get(id)
    if not record then return nil end

    local properties = record.properties or {}

    -- The mod slots that are actually fitted, named, so the view is a list of parts rather
    -- than fifty rows of -1.
    local fitted = {}
    for key, value in pairs(properties) do
        if key:sub(1, 3) == 'mod' and type(value) == 'number' and value >= 0 then
            fitted[#fitted + 1] = { name = key:sub(4), value = value }
        elseif key:sub(1, 3) == 'mod' and value == true then
            fitted[#fitted + 1] = { name = key:sub(4), value = 'on' }
        end
    end
    table.sort(fitted, function(a, b) return a.name < b.name end)

    local damage = {}
    if type(properties.windows) == 'table' and #properties.windows > 0 then
        damage[#damage + 1] = { name = 'windows broken', value = #properties.windows }
    end
    if type(properties.doors) == 'table' and #properties.doors > 0 then
        damage[#damage + 1] = { name = 'doors damaged', value = #properties.doors }
    end
    if type(properties.tyres) == 'table' and next(properties.tyres) then
        damage[#damage + 1] = { name = 'tyres burst', value = Park.count(properties.tyres) }
    end
    if type(properties.deformation) == 'table' then
        local points = properties.deformation.d
        damage[#damage + 1] = {
            name = 'deformation points',
            value = type(points) == 'table' and math.floor(#points / 2) or 'external',
        }
    end

    local live = Store.live(id)
    local now = Park.now()

    return {
        row = toRow(record, nil),

        colours = {
            primary = properties.color1,
            secondary = properties.color2,
            pearlescent = properties.pearlescentColor,
            wheel = properties.wheelColor,
            custom = properties.customPrimary ~= nil,
        },

        fitted = fitted,
        damage = damage,

        extras = properties.extras and Park.count(properties.extras) or 0,
        windowTint = properties.windowTint,
        plateIndex = properties.plateIndex,
        lockState = properties.lockState,

        source = record.source,
        bucket = record.bucket,
        interior = record.interior,
        netId = live and live.netId or nil,
        placer = live and live.placer or nil,

        createdAgo = now > 0 and Park.duration(now - (record.created_at or now)) or nil,
        updatedAgo = now > 0 and Park.duration(now - (record.updated_at or now)) or nil,
        touchedAgo = now > 0 and Park.duration(now - (record.touched_at or now)) or nil,
        usedAgo = (now > 0 and (record.last_used_at or 0) > 0)
            and Park.duration(now - record.last_used_at) or nil,

        offlineSecs = record.offline_secs,
        statebags = record.statebags,
    }
end

-- ---------------------------------------------------------------------------------------
-- Opening
-- ---------------------------------------------------------------------------------------

--[[
    The payload the panel needs once, when it opens: what it may do, and what the garages are
    called on this server.
]]
function Panel.context(src)
    local config = panelConfig()

    local garages = {}
    local configured = config.garages

    if type(configured) == 'table' then
        for _, entry in ipairs(configured) do
            if type(entry) == 'table' and entry.id then
                garages[#garages + 1] = { id = tostring(entry.id), label = tostring(entry.label or entry.id) }
            end
        end
    else
        for _, garage in ipairs(Runtime.garages()) do
            garages[#garages + 1] = { id = tostring(garage.id), label = tostring(garage.label or garage.id) }
        end
    end

    -- A fallback that is not in the list would be a dropdown that cannot select the very
    -- garage the cleanup sweep uses, which is confusing in exactly the moment somebody is
    -- trying to work out where a car went.
    local fallback = Config.Cleanup and Config.Cleanup.fallbackGarage
    if fallback and fallback ~= '' then
        local present = false
        for _, garage in ipairs(garages) do
            if garage.id == fallback then present = true break end
        end
        if not present then
            garages[#garages + 1] = { id = fallback, label = fallback .. ' (config)' }
        end
    end

    return {
        theme = config.theme or 'sandy',
        actions = config.actions or {},
        garages = garages,
        garageResource = Runtime.garageResource(),
        refreshSeconds = tonumber(config.refreshSeconds) or 15,
        pageSize = tonumber(config.pageSize) or 25,
        version = Runtime.state().version,
        framework = Bridge.kind(),
        canRestore = (tonumber(Config.Database.trashRetentionDays) or 0) > 0,
        bulkLimit = 100,
    }
end

function Panel.open(src)
    if not Actions.requireAdmin(src) then
        Bridge.notify(src, 'refused', L('error.no_permission'), 'error')
        return false
    end

    TriggerClientEvent('vpark:client:panelOpen', src, Panel.context(src), Panel.query(src, {}))
    return true
end

-- ---------------------------------------------------------------------------------------
-- Events from the panel
-- ---------------------------------------------------------------------------------------

RegisterNetEvent('vpark:server:panelQuery', function(query)
    local src = source
    if not Actions.requireAdmin(src) then return end
    if not Runtime.ready() then return end

    TriggerClientEvent('vpark:client:panelData', src, Panel.query(src, query))
end)

--[[
    Run an action from the panel.

    One dispatch table, every entry calling straight into `server/actions.lua`. A panel action
    that is switched off in `Config.Panel.actions` is refused HERE and not merely hidden, which
    is the point made in the file header.
]]
local DISPATCH = {
    teleportTo = function(src, id) return Actions.teleportTo(src, id) end,
    bringHere = function(src, id) return Actions.bringHere(src, id) end,
    repair = function(src, id) return Actions.repair(src, id) end,
    clean = function(src, id) return Actions.clean(src, id) end,
    refuel = function(src, id, value) return Actions.refuel(src, id, value) end,
    unlock = function(src, id) return Actions.setLock(src, id, false) end,
    lock = function(src, id) return Actions.setLock(src, id, true) end,
    setOwner = function(src, id, value) return Actions.setOwner(src, id, value) end,
    toGarage = function(src, id, value) return Actions.toGarage(src, id, value) end,
    impound = function(src, id) return Actions.impound(src, id) end,
    delete = function(src, id) return Actions.delete(src, id) end,
    restore = function(src, id) return Actions.restore(src, id) end,
    rename = function(src, id, value) return Actions.rename(src, id, value) end,
}

RegisterNetEvent('vpark:server:panelAction', function(action, id, value)
    local src = source

    if not Actions.requireAdmin(src) then
        TriggerClientEvent('vpark:client:panelResult', src, false, L('error.no_permission'))
        return
    end

    if not Runtime.ready() then
        TriggerClientEvent('vpark:client:panelResult', src, false, L('error.not_ready'))
        return
    end

    if type(action) ~= 'string' or type(id) ~= 'string' then return end

    local handler = DISPATCH[action]
    if not handler then
        TriggerClientEvent('vpark:client:panelResult', src, false, L('error.unknown_action'))
        return
    end

    -- The config gate. `unlock` and `lock` share one switch, because a panel that can lock and
    -- not unlock is not a thing anybody wants.
    local gate = action == 'lock' and 'unlock' or action
    local actions = panelConfig().actions or {}
    if actions[gate] == false then
        TriggerClientEvent('vpark:client:panelResult', src, false, L('error.action_disabled'))
        return
    end

    -- In its own thread: several of these await the database, and an event handler that awaits
    -- blocks the handler queue behind it.
    Database.thread(function()
        local ok, message = handler(src, id, value)

        TriggerClientEvent('vpark:client:panelResult', src, ok == true, L(message or 'error.unknown'))

        -- Refresh whatever they were looking at, so the row they just acted on updates without
        -- them pressing anything.
        local session = sessions[src] or {}
        TriggerClientEvent('vpark:client:panelData', src, Panel.query(src, session))
    end)
end)

--[[
    The trash listing, for the restore view.

    A separate query because it reads a different table and is only ever looked at
    deliberately - paying for it on every panel refresh would be a query nobody asked for.
]]
--[[
    Run one action across a selection.

    -------------------------------------------------------------------------------------------
    WHY THIS IS NOT JUST A LOOP IN THE BROWSER
    -------------------------------------------------------------------------------------------

    It could be, and it would be worse in three ways. Fifty separate events is fifty permission
    checks, fifty audit rows written one at a time, and fifty refreshes racing each other. More
    importantly, a bulk delete is the single most destructive thing this panel can do and it
    deserves one place that counts what it did and says so.

    The cap is real. A selection larger than it is refused rather than truncated, because a
    truncated bulk action is the worst possible outcome: the operator believes it all happened.
]]
local BULK_LIMIT = 100

local BULK_ALLOWED = {
    repair = true,
    clean = true,
    refuel = true,
    unlock = true,
    lock = true,
    toGarage = true,
    impound = true,
    delete = true,
}

RegisterNetEvent('vpark:server:panelBulk', function(action, ids, value)
    local src = source

    if not Actions.requireAdmin(src) then
        TriggerClientEvent('vpark:client:panelResult', src, false, L('error.no_permission'))
        return
    end

    if not Runtime.ready() then
        TriggerClientEvent('vpark:client:panelResult', src, false, L('error.not_ready'))
        return
    end

    if type(action) ~= 'string' or type(ids) ~= 'table' then return end
    if not BULK_ALLOWED[action] then
        TriggerClientEvent('vpark:client:panelResult', src, false, L('error.unknown_action'))
        return
    end

    local gate = action == 'lock' and 'unlock' or action
    local actions = panelConfig().actions or {}
    if actions[gate] == false then
        TriggerClientEvent('vpark:client:panelResult', src, false, L('error.action_disabled'))
        return
    end

    if #ids > BULK_LIMIT then
        TriggerClientEvent('vpark:client:panelResult', src, false, L('panel.bulk_too_many', BULK_LIMIT))
        return
    end

    local handler = DISPATCH[action]
    if not handler then return end

    Database.thread(function()
        local done, failed = 0, 0

        for index = 1, #ids do
            local id = ids[index]

            if type(id) == 'string' then
                local ok = handler(src, id, value)
                if ok then done = done + 1 else failed = failed + 1 end
            end

            -- Yield every few, so a hundred repairs do not hold the server thread. Each one
            -- awaits the database anyway; this makes the yielding explicit and bounded.
            if index % 5 == 0 then Wait(0) end
        end

        Database.audit('bulk_' .. action, Bridge.characterId(src), Bridge.name(src), nil,
            { count = done, failed = failed })
        Webhook.admin(action, src, ('%d vehicle(s)'):format(done),
            { bulk = true, failed = failed })

        TriggerClientEvent('vpark:client:panelResult', src, failed == 0,
            L('panel.bulk_done', done, failed))

        local session = sessions[src] or {}
        TriggerClientEvent('vpark:client:panelData', src, Panel.query(src, session))
    end)
end)

RegisterNetEvent('vpark:server:panelDetail', function(id)
    local src = source
    if not Actions.requireAdmin(src) then return end
    if type(id) ~= 'string' then return end

    TriggerClientEvent('vpark:client:panelDetail', src, Panel.detail(src, id))
end)

RegisterNetEvent('vpark:server:panelTrash', function(page)
    local src = source
    if not Actions.requireAdmin(src) then return end
    if not Database.available() then
        TriggerClientEvent('vpark:client:panelTrash', src, { rows = {}, total = 0, page = 1, pages = 1 })
        return
    end

    Database.thread(function()
        local pageSize = tonumber(panelConfig().pageSize) or 25
        page = math.max(1, math.floor(tonumber(page) or 1))

        local total = tonumber(Database.scalar(
            ('SELECT COUNT(*) FROM %s'):format(Database.table('trash')))) or 0

        local rows = Database.query(
            ('SELECT `id`, `deleted_at`, `deleted_by`, `reason`, `payload` FROM %s ORDER BY `deleted_at` DESC LIMIT ? OFFSET ?')
                :format(Database.table('trash')),
            { pageSize, (page - 1) * pageSize }
        )

        local out = {}
        local now = Park.now()

        for _, row in ipairs(rows) do
            local payload = Park.decode(row.payload) or {}
            out[#out + 1] = {
                id = row.id,
                plate = payload.plate,
                model = payload.model_name,
                owner = payload.owner_name or payload.owner,
                reason = row.reason,
                deletedBy = row.deleted_by,
                deletedAgo = now > 0 and Park.duration(now - (tonumber(row.deleted_at) or now)) or '?',
            }
        end

        TriggerClientEvent('vpark:client:panelTrash', src, {
            rows = out,
            total = total,
            page = page,
            pages = math.max(1, math.ceil(total / pageSize)),
        })
    end)
end)

--[[
    The cleanup preview, from inside the panel.

    The same function `/vparkadmin cleanup preview` calls. It changes nothing.
]]
RegisterNetEvent('vpark:server:panelCleanupPreview', function()
    local src = source
    if not Actions.requireAdmin(src) then return end

    Database.thread(function()
        local _, report = Lifecycle.sweepCleanup(true)
        TriggerClientEvent('vpark:client:panelCleanup', src, report)
    end)
end)

AddEventHandler('playerDropped', function()
    sessions[source] = nil
end)
