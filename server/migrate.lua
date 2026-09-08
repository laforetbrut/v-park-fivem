--[[
    server/migrate.lua

    Moving a server from Advanced Parking to v-park without losing anybody's car.

    -------------------------------------------------------------------------------------------
    WHY THIS DOES NOT HARDCODE A SCHEMA
    -------------------------------------------------------------------------------------------

    Advanced Parking creates its own table and does not publish its schema. It has changed
    across its major versions, and the documentation says only that the table "is automatically
    added by the script if it does not exist".

    So a migration written against one remembered column layout would work on one version of
    one server and fail silently everywhere else - and "fail silently" here means importing a
    thousand vehicles with no modifications, or at coordinates read out of the wrong column.

    Instead this reads `INFORMATION_SCHEMA.COLUMNS`, matches what it finds against a table of
    known names and shapes, and PRINTS what it matched and what it could not. An operator can
    read the mapping before running anything, and `Config.Migration.columnMap` overrides any
    part of it.

    -------------------------------------------------------------------------------------------
    THE SOURCE TABLE IS ONLY EVER READ
    -------------------------------------------------------------------------------------------

    Nothing here writes to it, drops it, or renames it. Your old script keeps working, and you
    can run both while you decide - the two do not share a table and do not share a statebag.

    -------------------------------------------------------------------------------------------
    FOUR STEPS, AND THE FIRST THREE CHANGE NOTHING
    -------------------------------------------------------------------------------------------

        scan      find the table, print the mapping and the row count
        dry       map every row and report exactly what WOULD be written
        run       do it, after copying the source table to a backup
        rollback  undo the last run

    `dry` is not a formality. It is where a mismatched column shows up as four thousand
    vehicles at coordinate zero.
]]

Migrate = {}

local running = false

local function migrationConfig()
    return (Config and Config.Migration) or {}
end

-- ---------------------------------------------------------------------------------------
-- Finding the table
-- ---------------------------------------------------------------------------------------

function Migrate.findTable()
    local candidates = migrationConfig().tables

    if type(candidates) ~= 'table' then
        return nil, 'Config.Migration.tables is not a list'
    end

    for _, name in ipairs(candidates) do
        if type(name) == 'string' and Database.tableExists(name) then
            return name
        end
    end

    return nil, 'none of the candidate table names exist in this database'
end

-- ---------------------------------------------------------------------------------------
-- Mapping the columns
-- ---------------------------------------------------------------------------------------

--[[
    Candidate source column names for each of our fields, in order of preference.

    Order matters: `plate` before `numberplate` because a table with both almost certainly uses
    the first as the key and the second as a display value, and `coords` before `position`
    because a table with both usually stores the authoritative one in `coords`.

    A name here is a NAME, not a guess about content. Anything unmatched is reported rather
    than assumed, which is the difference between a migration you can check and one you have to
    trust.
]]
local CANDIDATES = {
    id          = { 'id', 'uuid', 'vehicleid', 'vehicle_id', 'identifier' },
    plate       = { 'plate', 'numberplate', 'number_plate', 'licenseplate', 'license_plate' },
    model       = { 'model', 'hash', 'modelhash', 'model_hash', 'vehicle', 'vehiclemodel' },
    owner       = { 'owner', 'citizenid', 'identifier', 'charid', 'char_id', 'steamid', 'license' },
    position    = { 'position', 'coords', 'location', 'pos', 'vehiclecoords' },
    posX        = { 'x', 'pos_x', 'posx', 'coord_x' },
    posY        = { 'y', 'pos_y', 'posy', 'coord_y' },
    posZ        = { 'z', 'pos_z', 'posz', 'coord_z' },
    rotation    = { 'rotation', 'rot', 'heading_full', 'rotationvector' },
    heading     = { 'heading', 'h', 'rot_z', 'w' },
    properties  = { 'properties', 'props', 'mods', 'modifications', 'vehicleprops',
                    'vehicle_props', 'data', 'vehicle', 'meta' },
    fuel        = { 'fuel', 'fuellevel', 'fuel_level', 'gas' },
    bodyHealth  = { 'bodyhealth', 'body_health', 'body' },
    engineHealth= { 'enginehealth', 'engine_health', 'engine' },
    dirt        = { 'dirt', 'dirtlevel', 'dirt_level' },
    created     = { 'created', 'created_at', 'createdat', 'first_seen', 'time' },
    updated     = { 'updated', 'updated_at', 'updatedat', 'last_seen', 'lastseen', 'timestamp' },
    bucket      = { 'bucket', 'routingbucket', 'routing_bucket', 'dimension' },
    statebags   = { 'statebags', 'state', 'states', 'entitystate', 'statebag' },
}

--[[
    Work out which source column feeds each of our fields.

    Returns `map, unmatched, columns`, where `map` is field -> column name, `unmatched` is the
    list of source columns nothing claimed, and `columns` is the raw introspection result.

    `Config.Migration.columnMap` wins over detection for any field it names, including naming a
    column that detection would not have picked. A field mapped to a column that does not exist
    is reported as an error rather than silently ignored.
]]
function Migrate.mapColumns(tableName)
    local columns = Database.columns(tableName)

    if next(columns) == nil then
        return nil, nil, nil, ('table `%s` has no readable columns'):format(tableName)
    end

    local map = {}
    local claimed = {}

    local overrides = migrationConfig().columnMap or {}

    for field, candidates in pairs(CANDIDATES) do
        local override = overrides[field]

        if type(override) == 'string' and override ~= '' then
            if columns[override:lower()] then
                map[field] = override:lower()
                claimed[override:lower()] = true
            else
                return nil, nil, columns,
                    ('Config.Migration.columnMap.%s names `%s`, which is not a column of `%s`')
                        :format(field, override, tableName)
            end
        else
            for _, candidate in ipairs(candidates) do
                if columns[candidate] and not claimed[candidate] then
                    map[field] = candidate
                    claimed[candidate] = true
                    break
                end
            end
        end
    end

    local unmatched = {}
    for column in pairs(columns) do
        if not claimed[column] then unmatched[#unmatched + 1] = column end
    end
    table.sort(unmatched)

    return map, unmatched, columns
end

--[[
    Is the mapping good enough to run?

    A model and a position are the only two things a vehicle cannot exist without. Everything
    else degrades: no properties means a stock car, no owner means an unowned one, no timestamp
    means "now". Those are all recoverable; a vehicle with no model is not a vehicle and one
    with no position is at the origin.
]]
function Migrate.validate(map)
    local problems = {}

    if not map.model then
        problems[#problems + 1] = 'no model column was found - set Config.Migration.columnMap.model'
    end

    local hasPosition = map.position or (map.posX and map.posY and map.posZ)
    if not hasPosition then
        problems[#problems + 1] = 'no position column was found - set Config.Migration.columnMap.position, or the x/y/z columns'
    end

    return #problems == 0, problems
end

-- ---------------------------------------------------------------------------------------
-- Reading a row
-- ---------------------------------------------------------------------------------------

--[[
    Turn one source row into one of our records, or nil and a reason.

    Every read is defensive. This is somebody else's table, written by somebody else's code,
    across several of its own versions, and a single malformed row must not stop the migration.
]]
function Migrate.convert(row, map, now)
    local model

    local rawModel = row[map.model]
    if type(rawModel) == 'number' then
        model = math.floor(rawModel)
    elseif type(rawModel) == 'string' then
        -- Either a numeric hash written as text, or a model name.
        model = tonumber(rawModel)
        if not model then model = GetHashKey(rawModel) end
    end

    if not model or model == 0 then
        return nil, 'no usable model'
    end

    -- A hash is a signed 32-bit value in some tables and unsigned in others. Normalising means
    -- a table written by a script that stored it signed still matches `IsModelValid`.
    if model < 0 then model = model + 4294967296 end

    local position
    if map.position then
        position = Park.toVec(Park.decode(row[map.position]) or row[map.position])
    end

    if not position and map.posX then
        position = Park.vec(tonumber(row[map.posX]), tonumber(row[map.posY]), tonumber(row[map.posZ]))
    end

    if not position then
        return nil, 'no usable position'
    end

    -- A row at the exact origin is a row whose coordinates were never written, not a vehicle
    -- in the middle of the ocean. Importing it would put a car at 0,0,0 forever.
    if math.abs(position.x) < 0.5 and math.abs(position.y) < 0.5 then
        return nil, 'position is at the origin'
    end

    local rotation = { x = 0.0, y = 0.0, z = 0.0 }

    if map.rotation then
        local decoded = Park.toVec(Park.decode(row[map.rotation]) or row[map.rotation])
        if decoded then
            rotation = { x = decoded.x, y = decoded.y, z = decoded.z }
        end
    end

    if map.heading and (rotation.z == 0.0) then
        local heading = tonumber(row[map.heading])
        if heading then rotation.z = Park.angle(heading) end
    end

    -- Properties. Advanced Parking stores a modifications blob whose key names are the
    -- ecosystem-standard ones - the same names ox_lib and qb-core use - so the table maps
    -- across directly. Anything whose names differ is imported as-is and simply produces a
    -- vehicle with fewer modifications applied, which is visible and fixable rather than
    -- broken.
    local properties = {}
    if map.properties then
        local decoded = Park.decode(row[map.properties])
        if type(decoded) == 'table' then
            properties = decoded
        end
    end

    properties.model = model

    local plate = Park.plate(map.plate and row[map.plate] or properties.plate)
    if plate then properties.plate = plate end

    if map.fuel then
        local fuel = tonumber(row[map.fuel])
        if fuel then properties.fuelLevel = Park.clamp(fuel, 0.0, 100.0) end
    end

    if map.bodyHealth then
        local health = tonumber(row[map.bodyHealth])
        if health then properties.bodyHealth = Park.clamp(health, 0.0, 1000.0) end
    end

    if map.engineHealth then
        local health = tonumber(row[map.engineHealth])
        if health then properties.engineHealth = Park.clamp(health, 0.0, 1000.0) end
    end

    if map.dirt then
        local dirt = tonumber(row[map.dirt])
        if dirt then properties.dirtLevel = Park.clamp(dirt, 0.0, 15.0) end
    end

    local statebags
    if map.statebags then
        local decoded = Park.decode(row[map.statebags])
        if type(decoded) == 'table' and next(decoded) then statebags = decoded end
    end

    local created = tonumber(map.created and row[map.created]) or now
    local updated = tonumber(map.updated and row[map.updated]) or created

    -- Timestamps in milliseconds are common, and importing one as seconds puts the vehicle
    -- fifty thousand years in the future, where no expiry will ever reach it.
    if created > 4102444800 then created = math.floor(created / 1000) end
    if updated > 4102444800 then updated = math.floor(updated / 1000) end

    local owner = map.owner and row[map.owner] or nil
    if type(owner) == 'string' then owner = Park.trim(owner) end
    if owner == '' then owner = nil end

    Schema.filter(properties)

    return {
        id = Park.id(),
        plate = plate,
        model = model,
        model_name = nil,   -- filled in below where the model is valid on this build
        class = 0,
        owner = owner,
        owner_type = owner and 'owned' or 'unowned',
        owner_name = nil,
        job = nil,
        pos_x = position.x,
        pos_y = position.y,
        pos_z = position.z,
        rot_x = rotation.x,
        rot_y = rotation.y,
        rot_z = rotation.z,
        bucket = tonumber(map.bucket and row[map.bucket]) or 0,
        interior = 0,
        room = 0,
        properties = properties,
        statebags = statebags,
        body_health = tonumber(properties.bodyHealth) or 1000.0,
        engine_health = tonumber(properties.engineHealth) or 1000.0,
        fuel = tonumber(properties.fuelLevel),
        wrecked = (tonumber(properties.engineHealth) or 1000) <= 0,
        offline_secs = 0,
        rental_until = 0,
        last_garage = nil,
        source = 'migrated',

        -- `created_at` and `touched_at` carry the SOURCE timestamps, because they are what
        -- the expiry sweep measures against and a migrated vehicle really is as old as the
        -- table says.
        --
        -- `updated_at` carries NOW, because the row was written now - and because it is what
        -- `rollback` finds its own work by. An earlier version stored the source timestamp
        -- here too and filtered the rollback on `created_at >= migrated_at`, which never
        -- matched anything: every migrated row's created_at is older than the migration by
        -- definition. The rollback ran, reported success, and removed nothing.
        created_at = created,
        updated_at = now,
        touched_at = updated,
        -- Migrated rows have no usable "last driven" information: the source table does not
        -- record it. Seeding it to the migration time rather than to zero means the Section 9c
        -- cleanup starts counting from today, so a fresh migration does not send a thousand
        -- cars to the garage on its first sweep.
        last_used_at = now,
    }
end

-- ---------------------------------------------------------------------------------------
-- Scan
-- ---------------------------------------------------------------------------------------

function Migrate.scan()
    local lines = {}

    if not Database.available() then
        return { 'no database driver - a migration needs one' }
    end

    local tableName, err = Migrate.findTable()
    if not tableName then
        lines[#lines + 1] = 'no Advanced Parking table was found.'
        lines[#lines + 1] = ('reason: %s'):format(err)
        lines[#lines + 1] = 'if yours has a different name, add it to Config.Migration.tables.'
        return lines
    end

    lines[#lines + 1] = ('found table `%s`'):format(tableName)

    local count = tonumber(Database.scalar(('SELECT COUNT(*) FROM `%s`'):format(tableName))) or 0
    lines[#lines + 1] = ('it holds %d row(s)'):format(count)

    local map, unmatched, columns, mapError = Migrate.mapColumns(tableName)

    if not map then
        lines[#lines + 1] = ('column mapping failed: %s'):format(tostring(mapError))
        return lines
    end

    lines[#lines + 1] = ('%d column(s) in the source table'):format(Park.count(columns))
    lines[#lines + 1] = 'mapping:'

    for _, field in ipairs(Park.keys(map)) do
        lines[#lines + 1] = ('    %-13s <- %s'):format(field, map[field])
    end

    if #unmatched > 0 then
        lines[#lines + 1] = ('unmatched source columns (ignored): %s'):format(table.concat(unmatched, ', '))
    end

    local ok, problems = Migrate.validate(map)
    if not ok then
        for _, problem in ipairs(problems) do
            lines[#lines + 1] = ('PROBLEM: %s'):format(problem)
        end
    else
        lines[#lines + 1] = 'the mapping is usable. Run the dry run next.'
    end

    return lines
end

-- ---------------------------------------------------------------------------------------
-- Dry run and run
-- ---------------------------------------------------------------------------------------

--[[
    Read every row, convert it, and either report or write.

    `commit` false is the dry run and touches nothing.

    Paged and yielding, because a table with ten thousand rows and a properties blob each is
    both a lot of memory and a lot of JSON decoding, and doing it in one go blocks the server
    thread for long enough to time out every player.
]]
function Migrate.execute(commit, force, report)
    if running then
        report({ 'a migration is already running' })
        return
    end

    running = true

    local lines = {}
    local function say(text, ...)
        if select('#', ...) > 0 then text = text:format(...) end
        lines[#lines + 1] = text
        Park.log('migration: %s', text)
    end

    local ok, err = pcall(function()
        if not Database.available() then
            say('no database driver - a migration needs one')
            return
        end

        local tableName = Migrate.findTable()
        if not tableName then
            say('no Advanced Parking table was found')
            return
        end

        local map, _, _, mapError = Migrate.mapColumns(tableName)
        if not map then
            say('column mapping failed: %s', tostring(mapError))
            return
        end

        local valid, problems = Migrate.validate(map)
        if not valid then
            for _, problem in ipairs(problems) do say('PROBLEM: %s', problem) end
            return
        end

        if commit and migrationConfig().refuseWhenPopulated ~= false and Store.count() > 0 and not force then
            say('v-park already holds %d vehicle(s).', Store.count())
            say('run `run force` if you are sure. Duplicates are skipped by plate and position either way.')
            return
        end

        -- The backup. Read `rollback` before deciding this is optional.
        if commit and migrationConfig().backup ~= false then
            local backupTable = Database.rawTable('migration_backup')

            Database.execute(('DROP TABLE IF EXISTS `%s`'):format(backupTable))
            Database.execute(('CREATE TABLE `%s` AS SELECT * FROM `%s`'):format(backupTable, tableName))

            local backedUp = tonumber(Database.scalar(('SELECT COUNT(*) FROM `%s`'):format(backupTable))) or 0
            say('backed up %d row(s) to `%s`', backedUp, backupTable)
        end

        local batchSize = math.max(50, math.floor(tonumber(migrationConfig().batchSize) or 250))
        local offset = 0
        local now = Park.now()

        local seen, imported, skipped = 0, 0, 0
        local reasons = {}
        local invalidModels = 0
        local duplicates = 0

        local invalidPolicy = migrationConfig().invalidModels or 'skip'
        local ownerPolicy = migrationConfig().unknownOwners or 'keep'

        while true do
            local rows = Database.query(
                ('SELECT * FROM `%s` LIMIT ? OFFSET ?'):format(tableName),
                { batchSize, offset }
            )

            if type(rows) ~= 'table' or #rows == 0 then break end

            local pending = {}

            for _, row in ipairs(rows) do
                seen = seen + 1

                local record, reason = Migrate.convert(row, map, now)

                if not record then
                    skipped = skipped + 1
                    reasons[reason] = (reasons[reason] or 0) + 1
                else
                    -- Duplicate detection: same plate, or same position within half a metre.
                    -- Both, because a plate can be missing and a position can be shared by two
                    -- rows written a second apart.
                    local duplicate = false

                    if record.plate and Store.byPlate(record.plate) then
                        duplicate = true
                    else
                        for _, near in ipairs(Store.near(record.pos_x, record.pos_y, 0.5, record.bucket)) do
                            if near.record.model == record.model then duplicate = true break end
                        end
                    end

                    if duplicate then
                        duplicates = duplicates + 1
                        skipped = skipped + 1
                    elseif IsModelValid and not IsModelValid(record.model) then
                        -- `IsModelValid` is a client native and is nil on most server builds,
                        -- which is why this is guarded rather than assumed. Where it is absent
                        -- the policy cannot be applied and every row is imported; the streaming
                        -- pass then declines to create anything whose model is missing, and
                        -- says so once rather than per vehicle.
                        invalidModels = invalidModels + 1

                        if invalidPolicy == 'import' then
                            pending[#pending + 1] = record
                        else
                            skipped = skipped + 1
                        end
                    else
                        -- Also a client native. Without it the model name is left nil and is
                        -- filled in by the first client that captures the vehicle.
                        if GetDisplayNameFromVehicleModel then
                            record.model_name = GetDisplayNameFromVehicleModel(record.model)
                            if record.model_name == 'CARNOTFOUND' then record.model_name = nil end
                        end

                        if record.owner and ownerPolicy == 'orphan' then
                            record.owner = nil
                            record.owner_type = 'unowned'
                        elseif record.owner and ownerPolicy == 'skip' then
                            -- Only skip when the owner genuinely matches nothing. Checking
                            -- costs one indexed lookup per row, which is why it is only done
                            -- under the policy that needs it.
                            local known = Bridge.ownedByPlate(record.plate)
                            if not known then
                                skipped = skipped + 1
                                reasons['unknown owner'] = (reasons['unknown owner'] or 0) + 1
                                goto nextRow
                            end
                        end

                        pending[#pending + 1] = record
                    end
                end

                ::nextRow::
            end

            if commit then
                for _, record in ipairs(pending) do
                    Store.add(record, true)
                    imported = imported + 1
                end

                -- Flush each batch rather than accumulating twenty thousand dirty records and
                -- writing them all at the end, which is one enormous transaction and a very
                -- long stall.
                Persist.flush(true)
            else
                imported = imported + #pending
            end

            offset = offset + batchSize
            Wait(0)
        end

        say('%d source row(s) read', seen)
        say('%d would be imported', imported)

        if commit then
            say('%d imported and written', imported)
        end

        if duplicates > 0 then
            say('%d skipped as duplicates of vehicles v-park already has', duplicates)
        end

        if invalidModels > 0 then
            say('%d reference a model this game build does not have (policy: %s)',
                invalidModels, invalidPolicy)
        end

        for reason, count in pairs(reasons) do
            say('%d skipped: %s', count, reason)
        end

        if not commit then
            say('nothing was changed. Run `%s run` when the numbers above look right.',
                Config.Commands.migrate and Config.Commands.migrate.name or 'vparkmigrate')
        else
            Database.meta('migrated_at', now)
            Database.meta('migrated_from', tableName)
            Database.meta('migrated_count', imported)

            say('done. `rollback` undoes this.')

            Webhook.activity('migrationFinished', 'Migration finished',
                ('%d vehicle(s) imported from `%s`.'):format(imported, tableName), nil)
        end
    end)

    running = false

    if not ok then
        lines[#lines + 1] = ('the migration raised: %s'):format(tostring(err))
        Park.error('migration failed: %s', tostring(err))
    end

    report(lines)
end

-- ---------------------------------------------------------------------------------------
-- Rollback
-- ---------------------------------------------------------------------------------------

--[[
    Undo the last run.

    Removes every record marked `source = 'migrated'` that was created by the last migration,
    and leaves everything else alone. The backup table is not restored INTO the source table -
    the source table was never written to - it is there so that a source table you have since
    deleted can still be recovered by hand.
]]
function Migrate.rollback(report)
    local lines = {}

    if not Database.available() then
        report({ 'no database driver' })
        return
    end

    local migratedAt = tonumber(Database.meta('migrated_at'))
    if not migratedAt then
        report({ 'there is no record of a migration to roll back' })
        return
    end

    local removed = 0

    --[[
        `updated_at`, not `created_at`.

        A migrated row's `created_at` is the source table's own creation time, which is by
        definition older than the migration that imported it. Filtering on it matched nothing,
        every time, and the rollback reported success having removed zero rows.

        `updated_at` is the moment we wrote it. A vehicle that has been saved since the
        migration has a later one, which still satisfies the comparison - correctly, because it
        is still a migrated row and still ours to remove.
    ]]
    for id, record in pairs(Store.all()) do
        if record.source == 'migrated' and (record.updated_at or 0) >= migratedAt then
            Spawn.despawn(id, 'migration rollback')
            Store.remove(id)
            removed = removed + 1
        end
    end

    Database.execute(
        ('DELETE FROM %s WHERE `source` = ? AND `updated_at` >= ?'):format(Database.table('vehicles')),
        { 'migrated', migratedAt }
    )

    Database.meta('migrated_at', '')

    lines[#lines + 1] = ('rolled back %d migrated vehicle(s)'):format(removed)
    lines[#lines + 1] = ('the source table was never modified and is untouched')
    lines[#lines + 1] = ('the backup in `%s` is still there'):format(Database.rawTable('migration_backup'))

    Park.log('migration rolled back: %d vehicle(s) removed', removed)

    report(lines)
end

-- ---------------------------------------------------------------------------------------
-- The command
-- ---------------------------------------------------------------------------------------

do
    local entry = Config.Commands and Config.Commands.migrate

    if type(entry) == 'table' and entry.enabled ~= false and type(entry.name) == 'string' then
        RegisterCommand(entry.name, function(src, args)
            src = tonumber(src) or 0

            if not Bridge.isAdmin(src) then
                TriggerClientEvent('chat:addMessage', src, {
                    args = { 'v-park', L('error.no_permission') } })
                return
            end

            local function report(lines)
                for _, line in ipairs(lines) do
                    if src == 0 then
                        print('^2[v-park]^7 ' .. line)
                    else
                        TriggerClientEvent('chat:addMessage', src, {
                            color = { 245, 197, 66 }, multiline = true, args = { 'v-park', line } })
                    end
                end
            end

            local sub = (args[1] or 'scan'):lower()

            Database.thread(function()
                if sub == 'scan' then
                    report(Migrate.scan())
                elseif sub == 'dry' or sub == 'dryrun' then
                    Migrate.execute(false, false, report)
                elseif sub == 'run' then
                    local force = (args[2] or ''):lower() == 'force'
                    Migrate.execute(true, force, report)
                    Database.audit('migrate', Bridge.characterId(src), Bridge.name(src), nil, { force = force })
                    Webhook.admin('migrate', src, nil, { step = 'run', force = force })
                elseif sub == 'rollback' then
                    Migrate.rollback(report)
                    Webhook.admin('migrate', src, nil, { step = 'rollback' })
                else
                    report({
                        'usage:',
                        ('  /%s scan      find the table and print the column mapping'):format(entry.name),
                        ('  /%s dry       map every row and report. Changes nothing'):format(entry.name),
                        ('  /%s run       do it. Backs up first'):format(entry.name),
                        ('  /%s rollback  undo the last run'):format(entry.name),
                        'read MIGRATION.md before `run`.',
                    })
                end
            end)
        end, false)   -- unrestricted, gated above. See the note in server/commands.lua.
    end
end
