--[[
    server/lifecycle.lua

    When a vehicle stops being kept, and what happens to it instead of simply vanishing.

    Three separate mechanisms live here and they are easy to confuse, so:

        EXPIRY              Section 9. Wall-clock: a vehicle nobody has touched for N hours.
                            Applies to every ownership kind, with a different N for each.

        SEMI-PERSISTENCE    Section 9b. Presence-based: a job or rental vehicle whose OWNER
                            has been offline for N minutes of server uptime. This is the one
                            that survives a reboot and does not survive its owner going home.

        EVICTION            Section 9 again. Pressure-based: the table or the player is at a
                            ceiling and the least recently touched thing goes to make room.

    -------------------------------------------------------------------------------------------
    NOTHING HERE DELETES A PLAYER'S CAR
    -------------------------------------------------------------------------------------------

    An owned vehicle removed by any of the three is handed back to the framework's garage, not
    destroyed. The player opens their garage and it is there. `Config.Garages
    .returnToGarageOnRemoval` is the switch and it defaults to on, and every path through this
    file honours it.

    Anything that IS removed goes to `<prefix>trash` first, for
    `Config.Database.trashRetentionDays` days, so `/vparkrestore` can bring it back. An admin
    deleting the wrong car is a mistake, not a catastrophe.
]]

Lifecycle = {}

local stats = {
    expired = 0,
    evicted = 0,
    semiExpired = 0,
    impounded = 0,
    returned = 0,
    deleted = 0,
    externalDeletes = 0,
    cleaned = 0,
}

-- Vehicles seen to have lost their entity, awaiting the grace period before we act.
-- id -> tick first noticed.
local vanishing = {}

-- The last tick the semi-persistence sweep ran, so it can add its own elapsed time to the
-- offline counters rather than assuming its interval was honoured exactly.
local lastSemiTick

local function lifecycleConfig()
    return (Config and Config.Lifecycle) or {}
end

local function semiConfig()
    return (Config and Config.SemiPersistence) or {}
end

-- ---------------------------------------------------------------------------------------
-- Removal
-- ---------------------------------------------------------------------------------------

--[[
    Copy a record into the trash before it goes.

    The whole record, encoded, so `/vparkrestore` can rebuild it exactly - including its
    modifications and its deformation. A trash row that only kept the plate and the position
    would restore a stock car, which is not the car that was deleted.
]]
local function toTrash(record, actor, reason)
    local days = tonumber(Config.Database and Config.Database.trashRetentionDays) or 0
    if days <= 0 then return end
    if not Database.available() then return end

    Database.execute(
        ('INSERT INTO %s (`id`, `deleted_at`, `deleted_by`, `reason`, `payload`) VALUES (?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE `deleted_at` = VALUES(`deleted_at`), `payload` = VALUES(`payload`)')
            :format(Database.table('trash')),
        { record.id, Park.now(), actor, reason, Park.encode(record) }
    )
end

--[[
    Remove a vehicle from persistence.

    `disposition` says what the vehicle should become:

        'delete'   gone, recoverable from the trash
        'garage'   handed back to the framework's garage
        'impound'  handed to the framework as impounded, falling back to the garage where
                   the framework has no impound concept

    Returns what actually happened, which is not always what was asked for: an unowned vehicle
    cannot go to a garage, because there is no account to put it in.
]]
function Lifecycle.remove(id, disposition, actor, reason)
    local record = Store.get(id)
    if not record then return false, 'unknown' end

    disposition = disposition or 'delete'

    -- Owned vehicles are handed back rather than destroyed, wherever that is possible. This
    -- is the line that makes expiry safe to switch on.
    local outcome = 'deleted'

    if record.owner_type == 'owned' and record.plate then
        if disposition == 'impound' then
            local ok, how = Bridge.impound(record.plate)
            if ok then
                outcome = how == 'impound' and 'impounded' or 'returned'
            end
        elseif disposition == 'garage'
            or (Config.Garages and Config.Garages.returnToGarageOnRemoval ~= false) then
            if Bridge.returnToGarage(record.plate) then
                outcome = 'returned'
            end
        end
    end

    toTrash(record, actor, reason or disposition)

    Spawn.despawn(id, reason or 'removed')
    Store.remove(id)

    if Database.available() then
        Database.execute(('DELETE FROM %s WHERE `id` = ?'):format(Database.table('vehicles')), { id })
    end

    if outcome == 'impounded' then stats.impounded = stats.impounded + 1
    elseif outcome == 'returned' then stats.returned = stats.returned + 1
    else stats.deleted = stats.deleted + 1 end

    Database.audit('remove', actor, nil, id, { reason = reason, outcome = outcome, plate = record.plate })

    -- Tell the owner, if they are here to be told.
    if record.owner then
        local src = Ownership.sourceOf(record.owner)
        if src then
            local event = outcome == 'impounded' and 'impounded' or 'expired'
            Bridge.notify(src, event, L('notify.' .. (outcome == 'impounded' and 'impounded' or
                outcome == 'returned' and 'returned' or 'removed'),
                record.model_name or L('vehicle.unknown'), record.plate or '?'), 'warn')
        end
    end

    if Config.Api and Config.Api.events then
        TriggerEvent('vpark:server:vehicleRemoved', id, {
            plate = record.plate,
            owner = record.owner,
            reason = reason,
            outcome = outcome,
        })
    end

    Park.debug('removed %s (%s): %s -> %s', id, tostring(record.plate), tostring(reason), outcome)

    return true, outcome
end

--[[
    Bring a vehicle back out of the trash.

    The record is rebuilt from the stored payload, given a fresh `touched_at` so it does not
    immediately expire again, and re-indexed. The id is preserved, which means anything that
    referenced it - an audit row, a screenshot of the panel - still resolves.
]]
function Lifecycle.restore(id, actor)
    if not Database.available() then return false, 'no_database' end

    local row = Database.single(
        ('SELECT `payload` FROM %s WHERE `id` = ?'):format(Database.table('trash')), { id })

    if not row or not row.payload then return false, 'not_in_trash' end

    local record = Park.decode(row.payload)
    if type(record) ~= 'table' or not record.id then return false, 'corrupt' end

    if Store.get(record.id) then return false, 'already_present' end

    local now = Park.now()
    record.touched_at = now
    record.updated_at = now
    record.offline_secs = 0

    Store.add(record, true)

    Database.execute(('DELETE FROM %s WHERE `id` = ?'):format(Database.table('trash')), { id })
    Database.audit('restore', actor, nil, id, { plate = record.plate })

    Park.log('restored %s (%s) from the trash', id, tostring(record.plate))

    return true
end

-- ---------------------------------------------------------------------------------------
-- Expiry
-- ---------------------------------------------------------------------------------------

--[[
    Is this vehicle protected from being removed right now?

    Two protections, both cheap and both belt-and-braces: it should be impossible for an
    expired vehicle to have somebody in it, and being certain costs one distance check.
]]
local function protected(record)
    local entry = Store.live(record.id)
    if entry and entry.entity and DoesEntityExist(entry.entity) then
        -- Somebody driving it.
        local driver = GetPedInVehicleSeat(entry.entity, -1)
        if driver and driver ~= 0 then return true end
    end

    local radius = tonumber(lifecycleConfig().protectRadius) or 0
    if radius <= 0 then return false end

    for _, player in ipairs(Spawn.onlinePlayers()) do
        local dx, dy = player.x - record.pos_x, player.y - record.pos_y
        if dx * dx + dy * dy < radius * radius then return true end
    end

    return false
end

Lifecycle.protected = protected

--[[
    The wall-clock expiry sweep.

    Walks the store, not the database: the store IS the working set and a query would answer
    the same question more slowly. Yields periodically so a large table does not block the
    server thread.
]]
function Lifecycle.sweepExpiry()
    local now = Park.now()
    if now <= 0 then return 0 end

    local disposition = lifecycleConfig().onExpiry or 'impound'
    local removed = 0
    local seen = 0

    for id, record in pairs(Store.all()) do
        seen = seen + 1

        local hours = Rules.expiryHours(record.owner_type, record.wrecked)

        if hours > 0 then
            local age = now - (record.touched_at or now)

            if age > hours * 3600 and not protected(record) then
                Lifecycle.remove(id, disposition, 'system', 'expired')
                removed = removed + 1
                stats.expired = stats.expired + 1
            end
        end

        -- Yield every few hundred so a twenty-thousand-row store does not stall the frame.
        if seen % 500 == 0 then Wait(0) end
    end

    if removed > 0 then
        Park.log('expiry removed %d vehicle(s)', removed)
    end

    return removed
end

-- ---------------------------------------------------------------------------------------
-- Semi-persistence
--
-- Section 9b of config.lua argues the design; this implements it.
--
-- THE COUNTER, NOT A TIMESTAMP. Each sweep adds ITS OWN elapsed time to the offline counter
-- of every semi-persistent vehicle whose owner is not online. A three-minute restart costs
-- three minutes of nobody's grace, because the sweep did not run during it - which is exactly
-- the "survives a reboot" half of the requirement.
--
-- With `pauseWhileServerOffline = false` the wall clock is used instead, and an overnight
-- outage does clear the map. Both are legitimate; the counter is the default because it is
-- the one that matches what a job vehicle is for.
-- ---------------------------------------------------------------------------------------

--[[
    The semi-persistence rules for an ownership kind, or nil when it is fully persistent.
]]
function Lifecycle.semiRules(ownerType)
    local config = semiConfig()
    if config.enabled == false then return nil end

    local types = config.types
    if type(types) ~= 'table' then return nil end

    local rules = types[ownerType]
    if type(rules) ~= 'table' or rules.enabled == false then return nil end

    return rules
end

--[[
    How much grace a vehicle has left, in seconds. Negative means it is due.

    Exposed because `/vparklist` and the panel both print it, and computing it in three places
    is how three places come to disagree.
]]
function Lifecycle.graceRemaining(record)
    local rules = Lifecycle.semiRules(record.owner_type)
    if not rules then return nil end

    local graceSeconds = (tonumber(rules.graceMinutes) or 45) * 60

    if rules.pauseWhileServerOffline ~= false then
        return graceSeconds - (record.offline_secs or 0)
    end

    local now = Park.now()
    if now <= 0 then return graceSeconds end

    return graceSeconds - (now - (record.touched_at or now))
end

--[[
    A vehicle's owner has come back. Reset the countdown.

    Called on connect and on a character load, for every vehicle that owner has. It is a loop
    over one player's vehicles, which is a handful, not over the store.
]]
function Lifecycle.onOwnerOnline(characterId)
    for _, record in ipairs(Store.ownedBy(characterId)) do
        if record.offline_secs and record.offline_secs > 0 then
            Store.update(record.id, { offline_secs = 0 })
        end
    end
end

--[[
    A vehicle's owner has gone. Nothing happens yet; the sweep starts counting.

    Deliberately empty of action. Removing on disconnect would be a different feature - and a
    worse one, because a player who crashes and reconnects in ninety seconds should find their
    cruiser where they left it.
]]
function Lifecycle.onOwnerOffline(characterId)
    Park.trace('%s went offline; their semi-persistent vehicles start counting', tostring(characterId))
end

--[[
    The semi-persistence sweep.

    Runs on its own interval, much finer than the expiry sweep, because 45 minutes of grace
    needs better than 30 minutes of resolution.
]]
function Lifecycle.sweepSemi()
    local config = semiConfig()
    if config.enabled == false then return 0 end

    local now = Park.ticks()
    local elapsed = lastSemiTick and math.floor((now - lastSemiTick) / 1000) or 0
    lastSemiTick = now

    -- A wildly large elapsed - the server was frozen, or the game timer wrapped - is not
    -- grace anybody spent. Clamping it to a sane maximum means a hitch cannot clear the map.
    local interval = tonumber(config.interval) or 60
    if elapsed > interval * 4 then elapsed = interval end
    if elapsed < 0 then elapsed = 0 end

    local warnBefore = (tonumber(config.warnBeforeMinutes) or 0) * 60
    local removed = 0
    local seen = 0

    --[[
        Only the semi-persistent kinds, from the ownership index.

        Before 1.0.1 this walked the entire store once a minute to find the handful of rows it
        cares about. On a server with twenty thousand vehicles and forty cruisers, that was
        twenty thousand iterations a minute for forty answers.
    ]]
    local kinds = {}
    for kind, rules in pairs(config.types or {}) do
        if type(rules) == 'table' and rules.enabled ~= false then
            kinds[#kinds + 1] = kind
        end
    end

    if #kinds == 0 then return 0 end

    local candidates = Store.ofTypes(kinds)

    for _, record in ipairs(candidates) do
        local id = record.id
        local rules = Lifecycle.semiRules(record.owner_type)

        if rules then
            seen = seen + 1

            local ownerOnline = record.owner and Ownership.isOnline(record.owner) or false
            local counting = not ownerOnline

            -- The job-change rule. An officer who clocks off as a mechanic does not keep the
            -- cruiser, and 'grace' means they have the same countdown as if they had gone home.
            if ownerOnline and record.owner_type == 'job' and record.job then
                local behaviour = rules.onJobChange or 'ignore'

                if behaviour ~= 'ignore' then
                    local src = Ownership.sourceOf(record.owner)
                    local job = src and Bridge.job(src)
                    local gang = src and Bridge.gang(src)

                    local matches = (job and job.name == record.job)
                        or (gang and gang.name and ('gang:' .. gang.name) == record.job)

                    if not matches then
                        if behaviour == 'remove' then
                            Lifecycle.remove(id, rules.onExpiry or 'delete', 'system', 'job_changed')
                            removed = removed + 1
                            stats.semiExpired = stats.semiExpired + 1
                            goto continue
                        end
                        counting = true
                    elseif rules.onOffDuty and job and job.onDuty == false then
                        counting = true
                    end
                end
            end

            -- A rental with a hard end time from whichever resource sold it. Nothing here can
            -- extend a rental past what was sold, so this is checked before the grace period.
            if rules.respectHardExpiry ~= false
                and record.rental_until and record.rental_until > 0
                and Park.now() >= record.rental_until then

                if not (rules.protectWhenInUse ~= false and protected(record)) then
                    Lifecycle.remove(id, rules.onExpiry or 'delete', 'system', 'rental_ended')
                    removed = removed + 1
                    stats.semiExpired = stats.semiExpired + 1
                    goto continue
                end
            end

            if counting then
                if rules.pauseWhileServerOffline ~= false then
                    record.offline_secs = (record.offline_secs or 0) + elapsed
                end

                local remaining = Lifecycle.graceRemaining(record)

                if remaining ~= nil and remaining <= 0 then
                    if rules.protectWhenInUse ~= false and protected(record) then
                        -- Somebody else is using it. A cruiser another officer is driving does
                        -- not vanish because the officer who signed it out logged off.
                        record.offline_secs = 0
                    else
                        Lifecycle.remove(id, rules.onExpiry or 'delete', 'system', 'owner_absent')
                        removed = removed + 1
                        stats.semiExpired = stats.semiExpired + 1
                        goto continue
                    end
                elseif remaining and warnBefore > 0 and remaining <= warnBefore and not record.warned then
                    -- They will usually not be online to hear it, which is the point of the
                    -- feature. A player who alt-tabbed and came back deserves the warning.
                    local src = record.owner and Ownership.sourceOf(record.owner)
                    if src then
                        record.warned = true
                        Bridge.notify(src, 'expiring',
                            L('notify.semi_expiring', record.model_name or L('vehicle.unknown'),
                                Park.duration(remaining)), 'warn')
                    end
                end
            elseif record.offline_secs and record.offline_secs > 0 then
                record.offline_secs = 0
                record.warned = nil
            end
        end

        ::continue::

        if seen % 500 == 0 then Wait(0) end
    end

    -- The counters are written on the ordinary flush cadence, not one statement per vehicle.
    -- (see below)
    -- One indexed bulk update is cheaper than a thousand row writes, and losing a minute of
    -- counter to an unclean shutdown costs a minute of grace nobody will notice.
    if seen > 0 and Database.available() then
        Lifecycle.persistCounters()
    end

    if removed > 0 then
        Park.log('semi-persistence removed %d vehicle(s)', removed)
    end

    return removed
end

--[[
    Write the offline counters.

    One statement per ownership kind rather than per vehicle: every semi-persistent vehicle
    whose owner is offline advanced by the same amount, so the update is arithmetic on the
    column rather than a value per row.

    The exceptions - vehicles whose owner IS online, and which therefore reset - are handled
    by a second statement listing them, which is normally a short list.
]]
function Lifecycle.persistCounters()
    local types = semiConfig().types
    if type(types) ~= 'table' then return end

    local kinds = {}
    for kind, rules in pairs(types) do
        if type(rules) == 'table' and rules.enabled ~= false then
            kinds[#kinds + 1] = kind
        end
    end

    if #kinds == 0 then return end

    local resetIds = {}
    local advanced = {}

    -- The ownership index again, for the same reason as the sweep above.
    for _, record in ipairs(Store.ofTypes(kinds)) do
        if record.offline_secs == 0 then
            resetIds[#resetIds + 1] = record.id
        else
            advanced[#advanced + 1] = { record.id, record.offline_secs }
        end
    end

    Database.thread(function()
        if #resetIds > 0 then
            -- Chunked, because an IN list of ten thousand ids exceeds max_allowed_packet.
            for start = 1, #resetIds, 500 do
                local chunk = {}
                for i = start, math.min(start + 499, #resetIds) do
                    chunk[#chunk + 1] = resetIds[i]
                end

                Database.execute(
                    ('UPDATE %s SET `offline_secs` = 0 WHERE `id` IN (%s)')
                        :format(Database.table('vehicles'), string.rep('?', #chunk, ', ')),
                    chunk
                )
            end
        end

        for start = 1, #advanced, 200 do
            local queries = {}
            for i = start, math.min(start + 199, #advanced) do
                queries[#queries + 1] = {
                    ('UPDATE %s SET `offline_secs` = ? WHERE `id` = ?'):format(Database.table('vehicles')),
                    { advanced[i][2], advanced[i][1] },
                }
            end
            if #queries > 0 then
                Database.transaction(queries)
                Wait(0)
            end
        end
    end)
end

-- ---------------------------------------------------------------------------------------
-- Eviction
-- ---------------------------------------------------------------------------------------

--[[
    Drop the least recently touched vehicle to make room.

    `owner` scopes it to one character's vehicles, for the per-character ceiling. nil scopes it
    to the whole server.

    Never evicts a vehicle somebody is near or in, which means a server that is genuinely full
    of vehicles all in use will refuse rather than evict. That is the correct order of
    preference: refusing to persist a new car is recoverable, deleting one somebody is standing
    next to is not.
]]
function Lifecycle.evictOldest(owner)
    if (lifecycleConfig().eviction or 'oldest') ~= 'oldest' then return false end

    local candidates = owner and Store.ownedBy(owner) or nil

    local oldest, oldestAt

    if candidates then
        for _, record in ipairs(candidates) do
            if not protected(record) and (not oldestAt or (record.touched_at or 0) < oldestAt) then
                oldest, oldestAt = record, record.touched_at or 0
            end
        end
    else
        for _, record in pairs(Store.all()) do
            if not protected(record) and (not oldestAt or (record.touched_at or 0) < oldestAt) then
                oldest, oldestAt = record, record.touched_at or 0
            end
        end
    end

    if not oldest then return false end

    Lifecycle.remove(oldest.id, 'garage', 'system', 'evicted')
    stats.evicted = stats.evicted + 1

    if oldest.owner then
        local src = Ownership.sourceOf(oldest.owner)
        if src then
            Bridge.notify(src, 'evicted',
                L('notify.evicted', oldest.model_name or L('vehicle.unknown')), 'warn')
        end
    end

    return true
end

-- ---------------------------------------------------------------------------------------
-- External deletion
--
-- HOW GARAGE INTEGRATION ACTUALLY WORKS, with no hook into any garage script.
--
-- A garage stores a vehicle by deleting its entity. We notice that an entity carrying our
-- statebag has gone away without us removing it, wait out the grace period, and stop tracking
-- the vehicle.
--
-- THE GRACE PERIOD IS LOAD-BEARING. Several resources delete and immediately recreate a
-- vehicle - a repair, a colour change, a re-spawn into a garage bay - and acting instantly
-- would forget a vehicle that is about to come straight back.
-- ---------------------------------------------------------------------------------------

local function sweepVanishing()
    if lifecycleConfig().forgetOnExternalDelete == false then return end

    local grace = (tonumber(lifecycleConfig().externalDeleteGrace) or 5) * 1000

    for id, entry in pairs(Store.allLive()) do
        local exists = entry.entity ~= nil and DoesEntityExist(entry.entity)

        --[[
            AN ENTITY THAT HAS NEVER EXISTED HAS NOT BEEN DELETED.

            Since 1.0.4 vehicles are created with `CREATE_VEHICLE_SERVER_SETTER`, which
            registers the entity immediately and leaves it ORPHANED - not simulated, and not
            present in the game world - until a client comes into scope. `DoesEntityExist`
            answers false for the whole of that window, by design.

            Without this flag, a vehicle that took longer than `externalDeleteGrace` to reach a
            client would be read as "something else deleted it" and its ROW WOULD BE DELETED.
            That is not a flicker, it is losing somebody's car, and it is the failure this
            check exists to avoid rather than to cause.

            `seen` is set the first time the entity is genuinely observed - by a client
            answering the restore, by an adoption, or right here.
        ]]
        if exists then entry.seen = true end

        if entry.seen and not exists then
            if not vanishing[id] then
                vanishing[id] = Park.ticks()
            elseif Park.ticks() - vanishing[id] > grace then
                vanishing[id] = nil

                -- It came back. Some resources recreate with a new handle, in which case the
                -- statebag is gone and this is a genuine deletion after all.
                local record = Store.get(id)
                if record then
                    Park.debug('%s was deleted by something else - forgetting it', id)
                    stats.externalDeletes = stats.externalDeletes + 1

                    Store.setLive(id, nil)

                    -- Removed from persistence, NOT put in the trash and not handed to a
                    -- garage: whatever deleted it has already decided what happens to it, and
                    -- second-guessing that is how a vehicle ends up in a garage and in the
                    -- street.
                    Store.remove(id)

                    if Database.available() then
                        Database.thread(function()
                            Database.execute(
                                ('DELETE FROM %s WHERE `id` = ?'):format(Database.table('vehicles')),
                                { id })
                        end)
                    end
                end
            end
        else
            vanishing[id] = nil
        end
    end
end

-- ---------------------------------------------------------------------------------------
-- Cleanup by use
--
-- Section 9c of config.lua argues the design. The short version: `touched_at` answers "is
-- this abandoned" and `last_used_at` answers "does anybody still drive this", and a car parked
-- outside its owner's house is touched constantly and has not been driven since March.
--
-- This sweep sends the second kind home. It does not delete them.
-- ---------------------------------------------------------------------------------------

local function cleanupConfig()
    return (Config and Config.Cleanup) or {}
end

--[[
    How many idle days this vehicle is allowed, or 0 for exempt.

    The class override wins over the ownership one, because it is the more specific statement:
    an operator who wrote `idleDaysByClass[16] = 60` meant aircraft, whoever owns them.
]]
function Lifecycle.idleDaysFor(record)
    local config = cleanupConfig()

    local byClass = config.idleDaysByClass
    if type(byClass) == 'table' then
        local specific = tonumber(byClass[record.class])
        if specific then return specific end
    end

    local byType = config.idleDays
    if type(byType) ~= 'table' then return 0 end

    return tonumber(byType[record.owner_type]) or 0
end

--[[
    Is this vehicle exempt from the cleanup sweep?

    Four exemptions, and each exists because of a specific way an automatic tidy-up goes wrong:

      - In use, or with somebody near it. Obvious, and checked anyway.
      - Inside a named exempt zone: a long-stay car park, a housing area where cars are meant
        to sit.
      - Named by its owner with `/vparkname`. Naming a car is a deliberate act and treating it
        as "leave this one" is both intuitive and free.
      - Never used at all, with `last_used_at` at zero. That is a row from before this feature
        existed, or a migrated one, and treating "we have no idea" as "fifty-six years idle"
        would clear the map on the first sweep after an upgrade.
]]
function Lifecycle.cleanupExempt(record)
    local config = cleanupConfig()

    if (record.last_used_at or 0) <= 0 then return true, 'never_recorded' end

    if config.protectInUse ~= false and protected(record) then
        return true, 'in_use'
    end

    if config.exemptNamed ~= false then
        local label = record.statebags and record.statebags['vpark:label']
        if label and label ~= '' then return true, 'named' end
    end

    local exemptZones = config.exemptZones
    if type(exemptZones) == 'table' and #exemptZones > 0 then
        local zone = Zones.at({ x = record.pos_x, y = record.pos_y, z = record.pos_z })
        if zone then
            for _, name in ipairs(exemptZones) do
                if zone.name == name then return true, 'exempt_zone' end
            end
        end
    end

    return false
end

--[[
    Where an idle vehicle should be sent.

    Returns a garage id, or nil when there is nowhere to send it - which for an unowned vehicle
    is always, because a garage is a place on an account and an unowned car has no account.
]]
function Lifecycle.cleanupDestination(record)
    if record.owner_type ~= 'owned' or not record.plate then return nil end

    local config = cleanupConfig()
    local mode = config.destination or 'lastGarage'
    local fallback = config.fallbackGarage

    if mode == 'configured' then
        return fallback
    end

    if mode == 'lastGarage' then
        if record.last_garage and record.last_garage ~= '' then
            return record.last_garage
        end
        return fallback
    end

    if mode == 'nearest' then
        local best, bestDistance

        for _, garage in ipairs(Runtime.garages()) do
            local dx = garage.point.x - record.pos_x
            local dy = garage.point.y - record.pos_y
            local distance = dx * dx + dy * dy

            if not bestDistance or distance < bestDistance then
                best, bestDistance = garage.id, distance
            end
        end

        return best or fallback
    end

    return fallback
end

--[[
    The cleanup sweep.

    `preview` runs every decision and changes nothing, returning the list. That is what
    `/vparkadmin cleanup preview` calls, and running it before switching this on for the first
    time is the difference between a tidy map and a support queue.
]]
function Lifecycle.sweepCleanup(preview)
    local config = cleanupConfig()
    if config.enabled == false and not preview then return 0, {} end

    local now = Park.now()
    if now <= 0 then return 0, {} end

    local maximum = tonumber(config.maximumPerSweep) or 25
    local unownedAction = config.unowned or 'delete'
    local verbose = config.verbose ~= false

    local moved = 0
    local seen = 0
    local report = {}

    for id, record in pairs(Store.all()) do
        seen = seen + 1

        if not preview and maximum > 0 and moved >= maximum then break end

        local days = Lifecycle.idleDaysFor(record)

        if days > 0 then
            local idleSeconds = now - (record.last_used_at or now)

            if idleSeconds > days * 86400 then
                local exempt, why = Lifecycle.cleanupExempt(record)

                if not exempt then
                    local garage = Lifecycle.cleanupDestination(record)

                    report[#report + 1] = {
                        id = id,
                        plate = record.plate,
                        model = record.model_name,
                        owner = record.owner_name or record.owner,
                        ownerType = record.owner_type,
                        idle = Park.duration(idleSeconds),
                        destination = garage or (record.owner_type == 'owned' and '?' or unownedAction),
                    }

                    if not preview then
                        if garage then
                            local ok = Actions.toGarage(0, id, garage)

                            if ok then
                                moved = moved + 1

                                if verbose then
                                    Park.log('cleanup: %s (%s) idle %s -> garage %s',
                                        tostring(record.plate), tostring(record.model_name),
                                        Park.duration(idleSeconds), garage)
                                end

                                Lifecycle.rememberCleanup(record, garage)
                            end
                        elseif record.owner_type ~= 'owned' and unownedAction == 'delete' then
                            Lifecycle.remove(id, 'delete', 'system', 'idle_cleanup')
                            moved = moved + 1

                            if verbose then
                                Park.log('cleanup: %s (%s) idle %s -> deleted (no owner)',
                                    tostring(record.plate), tostring(record.model_name),
                                    Park.duration(idleSeconds))
                            end
                        end
                    end
                elseif preview then
                    report[#report + 1] = {
                        id = id,
                        plate = record.plate,
                        model = record.model_name,
                        idle = Park.duration(idleSeconds),
                        destination = 'exempt: ' .. tostring(why),
                    }
                end
            end
        end

        if seen % 500 == 0 then Wait(0) end
    end

    if moved > 0 then
        stats.cleaned = (stats.cleaned or 0) + moved
        Park.log('cleanup moved %d idle vehicle(s)', moved)

        Webhook.activity('expired', 'Idle vehicles cleaned up',
            ('%d vehicle(s) were sent back to a garage.'):format(moved), nil)
    end

    return moved, report
end

-- Vehicles moved by cleanup whose owner was offline, to be mentioned on their next login.
-- character id -> list of { model, garage }
local cleanupNotices = {}

function Lifecycle.rememberCleanup(record, garage)
    if cleanupConfig().notifyOwner == false then return end
    if not record.owner then return end

    local src = Ownership.sourceOf(record.owner)

    if src then
        Bridge.notify(src, 'adminAction',
            L('notify.cleanup_moved', record.model_name or L('vehicle.unknown'), garage), 'info')
        return
    end

    local list = cleanupNotices[record.owner]
    if not list then
        list = {}
        cleanupNotices[record.owner] = list
    end

    -- Bounded. A player who has been away for a year should get a summary, not two hundred
    -- notifications the moment they log in.
    if #list < 10 then
        list[#list + 1] = { model = record.model_name, garage = garage }
    end
end

function Lifecycle.deliverCleanupNotices(src, characterId)
    local list = cleanupNotices[characterId]
    if not list or #list == 0 then return end

    cleanupNotices[characterId] = nil

    for _, entry in ipairs(list) do
        Bridge.notify(src, 'adminAction',
            L('notify.cleanup_moved', entry.model or L('vehicle.unknown'), entry.garage), 'info')
    end
end

-- ---------------------------------------------------------------------------------------
-- Warnings on login
-- ---------------------------------------------------------------------------------------

--[[
    Tell a player which of their vehicles is about to expire.

    Sent once, on connect, and only for vehicles inside the warning window. A player with
    twenty cars and none of them expiring hears nothing.
]]
function Lifecycle.warnExpiring(src, characterId)
    -- Anything the cleanup sweep moved while they were away, first: it already happened, and
    -- "where is my car" is a more urgent question than "when will it go".
    Lifecycle.deliverCleanupNotices(src, characterId)

    local now = Park.now()
    if now <= 0 then return end

    -- Vehicles approaching the idle cleanup. A different warning from the expiry one below,
    -- because the outcome is different: this one says the car is going back to a garage, not
    -- that it is going away.
    local cleanupWarnDays = tonumber(cleanupConfig().warnBeforeDays) or 0
    if cleanupWarnDays > 0 and cleanupConfig().enabled ~= false then
        for _, record in ipairs(Store.ownedBy(characterId)) do
            local days = Lifecycle.idleDaysFor(record)

            if days > 0 and (record.last_used_at or 0) > 0 then
                local remaining = days * 86400 - (now - record.last_used_at)
                if remaining > 0 and remaining <= cleanupWarnDays * 86400 then
                    Bridge.notify(src, 'expiring',
                        L('notify.cleanup_due', record.model_name or L('vehicle.unknown'),
                            Park.duration(remaining)), 'warn')
                end
            end
        end
    end

    local hours = tonumber(Config.Notify and Config.Notify.expiryWarningHours) or 0
    if hours <= 0 then return end

    for _, record in ipairs(Store.ownedBy(characterId)) do
        local expiryHours = Rules.expiryHours(record.owner_type, record.wrecked)

        if expiryHours > 0 then
            local remaining = expiryHours * 3600 - (now - (record.touched_at or now))
            if remaining > 0 and remaining <= hours * 3600 then
                Bridge.notify(src, 'expiring',
                    L('notify.expiring', record.model_name or L('vehicle.unknown'),
                        Park.duration(remaining)), 'warn')
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------
-- Timers
-- ---------------------------------------------------------------------------------------

CreateThread(function()
    while not Runtime.ready() do Wait(500) end

    if semiConfig().sweepOnBoot ~= false then
        -- One pass immediately, for vehicles that were already past their grace when the
        -- server went down. Without it they are visible for one sweep interval after boot.
        lastSemiTick = Park.ticks()
        pcall(Lifecycle.sweepSemi)
    end

    while true do
        Wait((tonumber(semiConfig().interval) or 60) * 1000)

        local ok, err = pcall(Lifecycle.sweepSemi)
        if not ok then
            Park.error('the semi-persistence sweep raised: %s', tostring(err))
            Wait(10000)
        end
    end
end)

CreateThread(function()
    while not Runtime.ready() do Wait(500) end

    while true do
        Wait((tonumber(lifecycleConfig().sweepInterval) or 30) * 60000)

        local ok, err = pcall(function()
            Lifecycle.sweepExpiry()
            Database.prune()
        end)

        if not ok then
            Park.error('the lifecycle sweep raised: %s', tostring(err))
        end
    end
end)

CreateThread(function()
    while not Runtime.ready() do Wait(500) end

    while true do
        Wait(2000)
        pcall(sweepVanishing)
    end
end)

--[[
    The cleanup sweep, on its own long interval.

    A first pass is NOT run at boot, unlike the semi-persistence one. A 15-day timer has no
    urgency, and running it during boot - before every player who might be about to log in and
    drive their car has connected - is the one moment it is most likely to move something
    somebody was about to use.
]]
CreateThread(function()
    while not Runtime.ready() do Wait(500) end

    while true do
        Wait((tonumber(cleanupConfig().interval) or 60) * 60000)

        local ok, err = pcall(Lifecycle.sweepCleanup)
        if not ok then
            Park.error('the cleanup sweep raised: %s', tostring(err))
        end
    end
end)

function Lifecycle.stats()
    return stats
end
