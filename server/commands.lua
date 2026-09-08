--[[
    server/commands.lua

    Every chat and console command.

    -------------------------------------------------------------------------------------------
    EVERY COMMAND IS THIN
    -------------------------------------------------------------------------------------------

    A command parses its arguments, resolves a vehicle, calls one function in
    `server/actions.lua`, and prints the answer. It contains no logic of its own, because the
    admin panel calls the same functions and two implementations of "delete a vehicle" is one
    implementation that forgets to write an audit row.

    -------------------------------------------------------------------------------------------
    REGISTRATION
    -------------------------------------------------------------------------------------------

    Names come from `Config.Commands`, so every one of them is renameable and every one can be
    switched off. A command that is off is not registered at all rather than registered and
    refusing, so it does not appear in a chat suggestion list and does not collide with another
    resource that wants the name.
]]

-- Small pieces of state a command needs to remember between two invocations. Declared at the
-- top rather than at the bottom, because a handler that reads it must not depend on the file
-- having finished loading - which is true here but is not a property worth relying on.
Commands = { wipeToken = nil }

local function commandConfig(key)
    local entry = Config.Commands and Config.Commands[key]
    if type(entry) ~= 'table' then return nil end
    if entry.enabled == false then return nil end
    if type(entry.name) ~= 'string' or entry.name == '' then return nil end
    return entry
end

--[[
    Answer a command, to chat or to the console depending on where it came from.

    One function so that every command works identically from both, which matters more than it
    sounds: a server owner debugging a broken framework needs `/vparkinfo` to work from the
    console, which is the one place the framework cannot be consulted.
]]
local function reply(src, message, colour)
    if src == 0 then
        print(('^%s[v-park]^7 %s'):format(colour or '2', message:gsub('%^%d', '')))
        return
    end

    TriggerClientEvent('chat:addMessage', src, {
        color = { 245, 197, 66 },
        multiline = true,
        args = { 'v-park', message },
    })
end

local function replyMany(src, lines)
    for _, line in ipairs(lines) do reply(src, line) end
end

--[[
    Register a command, with its help text, and gate it on its configured permission.

    The ACE registration matters for the chat suggestion list: FiveM hides a command a player
    cannot use only when it knows about the restriction, and `RegisterCommand`'s third argument
    is how it is told.
]]
local function register(key, help, handler)
    local entry = commandConfig(key)
    if not entry then return end

    --[[
        REGISTERED UNRESTRICTED, AND GATED IN THE HANDLER. Both halves matter.

        `RegisterCommand`'s third argument creates an ACE object called `command.<name>` and
        refuses the command to any principal that has not been granted it. That sounds like
        exactly what an admin command wants, and it has one consequence that makes it wrong
        here: THE SERVER CONSOLE IS ALSO A PRINCIPAL, and it does not hold
        `command.vparkstats` either.

        Measured on a stock qb-core server: `vparkinfo` (unrestricted) ran from the console,
        and `vparkstats`, `vparkzones` and `vparkadmin` all answered `Access denied for
        command`. Which is precisely backwards - the console is where an operator needs the
        diagnostic commands most, and it is the one place they could not run them.

        So the flag is off and `Bridge.isAdmin` does the work. It returns true for source 0,
        which is the console, and checks ACE first for everybody else. Nothing is loosened:
        the handler below refuses before it reaches `handler`, on every call.

        The one thing the flag also did was hide the command from the chat suggestion list for
        players who cannot use it - and it did not really do that either, because
        `chat:addSuggestion` below is sent to -1 and every client gets the list regardless.
    ]]
    RegisterCommand(entry.name, function(src, args, raw)
        src = tonumber(src) or 0

        if entry.permission == 'console' and src ~= 0 then
            reply(src, L('error.console_only'))
            return
        end

        if entry.permission == 'admin' and not Bridge.isAdmin(src) then
            reply(src, L('error.no_permission'))

            if Config.Permissions and Config.Permissions.logRefusals and src ~= 0 then
                Park.warn("%s tried /%s without permission - grant `add_ace group.admin %s allow`",
                    Bridge.playerName(src) or tostring(src), entry.name,
                    tostring(Config.Permissions.ace))
            end
            return
        end

        if not Runtime.ready() and key ~= 'info' then
            reply(src, L('error.not_ready'))
            return
        end

        local ok, err = pcall(handler, src, args, raw)
        if not ok then
            Park.error('/%s raised: %s', entry.name, tostring(err))
            reply(src, L('error.command_failed'))
        end
    end, false)

    -- Chat suggestions, so a player typing `/vpark` sees what the arguments are.
    if help then
        TriggerClientEvent('chat:addSuggestion', -1, '/' .. entry.name, help.description or '', help.params)
    end
end

-- ---------------------------------------------------------------------------------------
-- Player commands
-- ---------------------------------------------------------------------------------------

--[[
    Resolve the vehicle a player means when they name none: the one they are in, or the one
    they are looking at.

    Asked of the client, because the server cannot raycast. Returns via callback, which is why
    every caller of this is written in continuation style rather than as a plain return.
]]
local pendingLookups = {}
local lookupToken = 0

local function askForVehicle(src, callback)
    lookupToken = lookupToken + 1
    local token = lookupToken

    pendingLookups[token] = { src = src, callback = callback, at = Park.ticks() }

    TriggerClientEvent('vpark:client:describeCurrent', src, token)

    -- Never leave a caller waiting forever on a client that will not answer.
    SetTimeout(6000, function()
        local pending = pendingLookups[token]
        if pending then
            pendingLookups[token] = nil
            pending.callback(nil)
        end
    end)
end

RegisterNetEvent('vpark:server:describedCurrent', function(payload, token)
    local src = source
    local pending = pendingLookups[token]

    if not pending or pending.src ~= src then return end
    pendingLookups[token] = nil

    pending.callback(payload)
end)

register('park', {
    description = 'Keep the vehicle you are in across restarts',
    params = {},
}, function(src)
    if src == 0 then
        reply(src, L('error.in_game_only'))
        return
    end

    askForVehicle(src, function(payload)
        if not payload then
            reply(src, L('error.no_vehicle'))
            return
        end

        -- In a thread, because adoption reaches the database through Bridge.ownedByPlate and
        -- that awaits. A net event handler is a coroutine on every current build, so this
        -- would work either way; the two commands players run most often should not depend on
        -- that staying true.
        Database.thread(function()
            local ok, message, detail = Actions.park(src, payload)

            if ok then
                reply(src, L('notify.parked_detail', payload.modelName or '?', payload.plate or '?'))
                Bridge.notify(src, 'parked', L('notify.parked'), 'success')
            else
                local text = detail and L(message, detail) or L(message)
                reply(src, text)
                Bridge.notify(src, 'refused', text, 'error')
            end
        end)
    end)
end)

register('unpark', {
    description = 'Stop keeping a vehicle across restarts',
    params = { { name = 'id|plate', help = 'optional; defaults to the vehicle you are in' } },
}, function(src, args)
    local reference = args[1]

    local function finish(ref)
        Database.thread(function()
            local ok, message = Actions.forget(src, ref)
            reply(src, L(message))
            if ok then Bridge.notify(src, 'forgotten', L('notify.forgotten'), 'info') end
        end)
    end

    if reference then
        finish(reference)
        return
    end

    askForVehicle(src, function(payload)
        if not payload then
            reply(src, L('error.no_vehicle'))
            return
        end
        finish(payload.plate or '')
    end)
end)

register('list', {
    description = 'List the vehicles you have parked',
    params = {},
}, function(src)
    local characterId = Bridge.characterId(src)
    if not characterId then
        reply(src, L('error.character_not_loaded'))
        return
    end

    local records = Store.ownedBy(characterId)

    if #records == 0 then
        reply(src, L('list.empty'))
        return
    end

    table.sort(records, function(a, b) return (a.touched_at or 0) > (b.touched_at or 0) end)

    local lines = { L('list.header', #records) }
    local now = Park.now()

    for index, record in ipairs(records) do
        if index > 20 then
            lines[#lines + 1] = L('list.truncated', #records - 20)
            break
        end

        local age = now > 0 and Park.duration(now - (record.touched_at or now)) or '?'
        local grace = Lifecycle.graceRemaining(record)

        local suffix = ''
        if grace then
            suffix = L('list.grace', Park.duration(math.max(0, grace)))
        end

        lines[#lines + 1] = L('list.row',
            record.id, record.model_name or '?', record.plate or '?', age, suffix)
    end

    replyMany(src, lines)
end)

register('find', {
    description = 'Set a waypoint to one of your vehicles',
    params = { { name = 'id|plate', help = 'the vehicle' } },
}, function(src, args)
    if src == 0 then
        reply(src, L('error.in_game_only'))
        return
    end

    local record = Store.resolve(args[1] or '')
    if not record then
        reply(src, L('error.unknown_vehicle'))
        return
    end

    local allowed = Ownership.mayAct(src, record)
    if not allowed then
        reply(src, L('error.not_yours'))
        return
    end

    TriggerClientEvent('vpark:client:waypoint', src, record.pos_x, record.pos_y)
    reply(src, L('notify.waypoint_set', record.model_name or '?', record.plate or '?'))
end)

register('rename', {
    description = 'Name one of your kept vehicles. A named vehicle is never cleaned up',
    params = {
        { name = 'id|plate', help = 'the vehicle' },
        { name = 'name', help = 'up to 32 characters; leave empty to clear it' },
    },
}, function(src, args)
    local reference = args[1] or ''

    -- Everything after the first argument is the name, so a name with spaces in it works
    -- without the player having to quote it.
    local label = table.concat(args, ' ', 2)

    Database.thread(function()
        local ok, message = Actions.rename(src, reference, label)
        reply(src, L(message))
    end)
end)

register('lock', {
    description = 'Lock or unlock one of your parked vehicles',
    params = { { name = 'id|plate', help = 'the vehicle' }, { name = 'on|off', help = 'lock state' } },
}, function(src, args)
    local locked = (args[2] or 'on'):lower() ~= 'off'

    Database.thread(function()
        local ok, message = Actions.setLock(src, args[1] or '', locked)
        reply(src, L(message))
    end)
end)

-- ---------------------------------------------------------------------------------------
-- Information
-- ---------------------------------------------------------------------------------------

register('info', {
    description = 'What v-park detected on this server',
    params = {},
}, function(src)
    local compat = Bridge.summary()
    local store = Store.stats()
    local state = Runtime.state()

    local lines = {
        L('info.header', state.version),
        L('info.framework', compat.framework, compat.resource),
        L('info.database', Database.driver(), Database.prefix()),
        L('info.keys', compat.keys),
        L('info.mode', tostring(Config.Persistence and Config.Persistence.mode)),
        L('info.counts', store.total, store.live, store.dirty, store.cells),
        L('info.zones', Zones.count()),
    }

    if Database.memory() then
        lines[#lines + 1] = L('info.memory_mode')
    end

    if state.garageResource then
        lines[#lines + 1] = L('info.garages', state.garageResource, #Runtime.garages())
    end

    local webhooks = Webhook.stats()
    lines[#lines + 1] = L('info.webhooks',
        webhooks.errors and 'yes' or 'no',
        webhooks.admin and 'yes' or 'no',
        webhooks.activity and 'yes' or 'no')

    replyMany(src, lines)
end)

register('stats', {
    description = 'What v-park is costing this server right now',
    params = {},
}, function(src)
    local store = Store.stats()
    local spawn = Spawn.stats()
    local persist = Persist.stats()
    local life = Lifecycle.stats()
    local db = Database.stats()

    replyMany(src, {
        L('stats.header'),
        L('stats.store', store.total, store.live, store.dirty, store.cells),
        L('stats.spawn', spawn.spawned, spawn.despawned, spawn.failed, spawn.lastPassMs),
        L('stats.placement', spawn.exact or 0, spawn.nudged or 0, spawn.forced or 0, spawn.grounded or 0),
        L('stats.persist', persist.written, persist.batches, persist.captures, persist.lastFlushMs),
        L('stats.database', db.queries, db.writes, db.errors, db.averageMs, db.slowestMs),
        L('stats.lifecycle', life.expired, life.semiExpired, life.cleaned or 0, life.evicted, life.externalDeletes),
    })
end)

register('zones', {
    description = 'List the zones where nothing persists',
    params = {},
}, function(src)
    local zones = Zones.all()

    if #zones == 0 then
        reply(src, L('zones.empty'))
        return
    end

    local lines = { L('zones.header', #zones) }
    for index, zone in ipairs(zones) do
        if index > 30 then
            lines[#lines + 1] = L('list.truncated', #zones - 30)
            break
        end
        lines[#lines + 1] = L('zones.row', zone.name, zone.type, zone.source or 'config')
    end

    replyMany(src, lines)
end)

register('scan', {
    description = 'List the persisted vehicles near you',
    params = { { name = 'radius', help = 'metres, default 100' } },
}, function(src, args)
    if src == 0 then
        reply(src, L('error.in_game_only'))
        return
    end

    local ped = GetPlayerPed(src)
    local position = GetEntityCoords(ped)
    local radius = tonumber(args[1]) or 100.0

    local found = Store.near(position.x, position.y, radius, GetPlayerRoutingBucket(src))

    if #found == 0 then
        reply(src, L('scan.empty', radius))
        return
    end

    table.sort(found, function(a, b) return a.distanceSq < b.distanceSq end)

    local lines = { L('scan.header', #found, radius) }
    for index, entry in ipairs(found) do
        if index > 25 then
            lines[#lines + 1] = L('list.truncated', #found - 25)
            break
        end

        local record = entry.record
        lines[#lines + 1] = L('scan.row',
            record.id,
            record.model_name or '?',
            record.plate or '?',
            math.floor(math.sqrt(entry.distanceSq)),
            record.owner_type,
            Store.isLive(record.id) and L('scan.in_world') or L('scan.stored'))
    end

    replyMany(src, lines)
end)

-- ---------------------------------------------------------------------------------------
-- Staff commands
-- ---------------------------------------------------------------------------------------

register('here', {
    description = 'Bring a persisted vehicle to you',
    params = { { name = 'id|plate', help = 'the vehicle' } },
}, function(src, args)
    Database.thread(function()
        local ok, message = Actions.bringHere(src, args[1] or '')
        reply(src, L(message))
    end)
end)

register('goto', {
    description = 'Teleport to a persisted vehicle',
    params = { { name = 'id|plate', help = 'the vehicle' } },
}, function(src, args)
    Database.thread(function()
        local ok, message = Actions.teleportTo(src, args[1] or '')
        reply(src, L(message))
    end)
end)

register('delete', {
    description = 'Remove a vehicle from persistence and from the world',
    params = { { name = 'id|plate', help = 'the vehicle' } },
}, function(src, args)
    Database.thread(function()
        local ok, message = Actions.delete(src, args[1] or '')
        reply(src, L(message))
    end)
end)

register('restore', {
    description = 'Bring a deleted vehicle back from the trash',
    params = { { name = 'id', help = 'the vehicle id, from the audit log' } },
}, function(src, args)
    Database.thread(function()
        local ok, message = Actions.restore(src, args[1] or '')
        reply(src, L(message))
    end)
end)

register('owner', {
    description = "Transfer a vehicle to another player",
    params = {
        { name = 'id|plate', help = 'the vehicle' },
        { name = 'player id', help = 'the new owner, online' },
    },
}, function(src, args)
    Database.thread(function()
        local ok, message = Actions.setOwner(src, args[1] or '', args[2])
        reply(src, L(message))
    end)
end)

register('save', {
    description = 'Write every pending change to the database now',
    params = {},
}, function(src)
    Database.thread(function()
        local written = Persist.flush(true)
        reply(src, L('notify.flushed', written))
    end)
end)

register('purge', {
    description = 'Remove vehicles matching a filter. Always previews first',
    params = {
        { name = 'filter', help = 'idle:<days> | type:<ownership> | model:<name> | wrecked' },
        { name = 'confirm', help = "type 'confirm' to actually do it" },
    },
}, function(src, args)
    local filter = (args[1] or ''):lower()
    local confirmed = (args[2] or ''):lower() == 'confirm'

    if filter == '' then
        reply(src, L('purge.usage'))
        return
    end

    local now = Park.now()
    local matched = {}

    local idleDays = filter:match('^idle:(%d+)$')
    local ownerType = filter:match('^type:(%w+)$')
    local modelName = filter:match('^model:(.+)$')

    for id, record in pairs(Store.all()) do
        local hit = false

        if idleDays then
            hit = (now - (record.last_used_at or record.touched_at or now)) > tonumber(idleDays) * 86400
        elseif ownerType then
            hit = record.owner_type == ownerType
        elseif modelName then
            hit = (record.model_name or ''):lower() == modelName
        elseif filter == 'wrecked' then
            hit = record.wrecked == true
        end

        if hit and not Lifecycle.protected(record) then
            matched[#matched + 1] = id
        end
    end

    if #matched == 0 then
        reply(src, L('purge.none', filter))
        return
    end

    if not confirmed then
        reply(src, L('purge.preview', #matched, filter))
        reply(src, L('purge.confirm_hint', filter))
        return
    end

    -- In a thread: removal awaits per vehicle, and a purge of four hundred would otherwise
    -- do four hundred awaits inside one command handler.
    Database.thread(function()
    local removed = 0
    for _, id in ipairs(matched) do
        if Lifecycle.remove(id, 'garage', Bridge.characterId(src) or 'console', 'purge') then
            removed = removed + 1
        end
        if removed % 50 == 0 then Wait(0) end
    end

    reply(src, L('purge.done', removed, filter))
    Database.audit('purge', Bridge.characterId(src), Bridge.name(src), nil,
        { filter = filter, removed = removed })
    Webhook.admin('purge', src, nil, { filter = filter, removed = removed })
    end)
end)

register('debug', {
    description = 'Toggle debug logging and the on-screen overlay',
    params = {},
}, function(src)
    local normal = 'info'
    local debugLevel = (Config.Log and Config.Log.debugLevel) or 'debug'

    if Config.Log.level == debugLevel then
        Config.Log.level = normal
        reply(src, L('debug.off'))
    else
        Config.Log.level = debugLevel
        reply(src, L('debug.on', debugLevel))
    end

    if src ~= 0 then
        TriggerClientEvent('vpark:client:debug', src, Config.Log.level == debugLevel)
    end
end)

register('where', {
    description = 'Report how far each restored vehicle near you is from where it should be',
}, function(src)
    if src == 0 then
        reply(src, L('error.in_game_only'))
        return
    end

    TriggerClientEvent('vpark:client:where', src)
end)

register('probe', {
    description = 'Test the placement probe where you are standing',
    params = { { name = 'model', help = 'optional; defaults to the vehicle you are in' } },
}, function(src, args)
    if src == 0 then
        reply(src, L('error.in_game_only'))
        return
    end

    TriggerClientEvent('vpark:client:probe', src, args[1])
end)

-- ---------------------------------------------------------------------------------------
-- The panel
-- ---------------------------------------------------------------------------------------

register('admin', {
    description = 'Open the v-park admin panel',
    params = { { name = 'subcommand', help = 'cleanup | garages | reconcile - or nothing for the panel' } },
}, function(src, args)
    local sub = (args[1] or ''):lower()

    if sub == '' then
        if src == 0 then
            reply(src, L('error.in_game_only'))
            return
        end

        if not (Config.Panel and Config.Panel.enabled ~= false) then
            reply(src, L('error.panel_disabled'))
            return
        end

        Panel.open(src)
        return
    end

    if sub == 'reconcile' then
        -- Deletes vehicles in the world that carry one of our ids and are not the entity we
        -- have registered for that id: orphans, and duplicate copies. Runs on a timer anyway;
        -- this is for when you want to watch it happen.
        Database.thread(function()
            local removed = Spawn.reconcile()
            reply(src, L('reconcile.done', removed))
        end)
        return
    end

    if sub == 'garages' then
        local garages = Runtime.garages()

        if #garages == 0 then
            reply(src, L('garages.none'))
            reply(src, L('garages.none_hint'))
            return
        end

        local lines = { L('garages.header', Runtime.garageResource() or '?', #garages) }
        for _, garage in ipairs(garages) do
            lines[#lines + 1] = L('garages.row', garage.id, garage.label or garage.id)
        end
        replyMany(src, lines)
        return
    end

    if sub == 'cleanup' then
        local mode = (args[2] or 'preview'):lower()

        if mode == 'preview' then
            local _, report = Lifecycle.sweepCleanup(true)

            if #report == 0 then
                reply(src, L('cleanup.none'))
                return
            end

            local lines = { L('cleanup.preview_header', #report) }
            for index, entry in ipairs(report) do
                if index > 30 then
                    lines[#lines + 1] = L('list.truncated', #report - 30)
                    break
                end
                lines[#lines + 1] = L('cleanup.row',
                    entry.plate or '?', entry.model or '?', entry.idle, entry.destination)
            end
            replyMany(src, lines)
            return
        end

        if mode == 'run' then
            Database.thread(function()
                local moved = Lifecycle.sweepCleanup(false)
                reply(src, L('cleanup.done', moved))
            end)
            return
        end

        reply(src, L('cleanup.usage'))
        return
    end

    reply(src, L('admin.usage'))
end)

-- ---------------------------------------------------------------------------------------
-- Console only
-- ---------------------------------------------------------------------------------------

register('wipe', {
    description = 'Delete every persisted vehicle. Console only, and asks twice',
    params = { { name = 'confirm', help = 'the token printed by the first run' } },
}, function(src, args)
    local token = args[1]

    -- A two-step confirmation with a generated token, so that a copy-and-pasted command from
    -- a support thread cannot empty somebody's table. The token is only ever printed to the
    -- console this command was run from.
    if not Commands.wipeToken or token ~= Commands.wipeToken then
        Commands.wipeToken = Park.base36(math.random(100000, 999999), 4)

        reply(src, L('wipe.warning', Store.count()))
        reply(src, L('wipe.confirm', Config.Commands.wipe.name, Commands.wipeToken))

        SetTimeout(60000, function() Commands.wipeToken = nil end)
        return
    end

    Commands.wipeToken = nil

    local total = Store.count()

    Database.thread(function()
        for id in pairs(Store.all()) do
            Spawn.despawn(id, 'wipe')
            Store.remove(id)
        end

        if Database.available() then
            Database.execute(('DELETE FROM %s'):format(Database.table('vehicles')))
        end
    end)

    reply(src, L('wipe.done', total))
    Park.warn('every persisted vehicle was wiped from the console (%d rows)', total)
    Webhook.admin('wipe', 0, nil, { removed = total })
end)
