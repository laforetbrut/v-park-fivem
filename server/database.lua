--[[
    server/database.lua
    Author: vyrriox

    The only file that talks to MySQL.

    -------------------------------------------------------------------------------------------
    NO HARD DEPENDENCY, ON PURPOSE
    -------------------------------------------------------------------------------------------

    `fxmanifest.lua` does not list oxmysql and this file does not `@oxmysql/lib/MySQL.lua`.
    Both would make the resource fail to start on a server without it, and running in memory is
    a legitimate configuration for a development server. Every driver is reached through its
    exports, wrapped in a promise here, which also means one code path works across every
    oxmysql version rather than depending on which of `query`, `query_async` and `.await` that
    build happens to publish.

    Three drivers are supported and detected in order of how likely they are to be correct:

        oxmysql        the modern default
        mysql-async    still on a lot of long-lived servers
        ghmattimysql   rare, and its `execute` returns rows rather than a count

    None of them present is not an error. `Database.available()` answers false, everything
    above this file keeps working in memory, and it is announced once at boot.

    -------------------------------------------------------------------------------------------
    IDENTIFIER SAFETY
    -------------------------------------------------------------------------------------------

    The table prefix is operator-supplied and ends up in SQL text, which is the one place in
    this resource where a config value is concatenated into a statement. `quote()` below
    validates it against a character class and backticks it, and `Database.table()` is the
    only way a table name is ever produced. Values are ALWAYS parameters, never concatenated.
]]

Database = {}

local driver            -- 'oxmysql' | 'mysql-async' | 'ghmattimysql' | nil
local ready = false
local memoryMode = false

local stats = {
    queries = 0,
    writes = 0,
    errors = 0,
    totalMs = 0,
    slowest = 0,
}

-- ---------------------------------------------------------------------------------------
-- Identifiers
-- ---------------------------------------------------------------------------------------

--[[
    Backtick-quote an identifier, refusing anything that is not one.

    MySQL allows almost any character inside backticks, including a backtick itself when
    doubled. We do not: a table prefix containing a backtick is a mistake or an attack, and
    there is no legitimate use for one. Refusing is the safe direction.
]]
local function quote(identifier)
    if type(identifier) ~= 'string' or identifier == '' then
        error('v-park: an SQL identifier was empty', 2)
    end

    if not identifier:match('^[%w_%-%$]+$') then
        error(("v-park: '%s' is not a usable SQL identifier - the table prefix may contain letters, digits, underscore, hyphen and $ only"):format(identifier), 2)
    end

    return '`' .. identifier .. '`'
end

local prefixCache

local function prefix()
    if prefixCache then return prefixCache end

    local configured = Config and Config.Database and Config.Database.prefix
    if type(configured) ~= 'string' or configured == '' then
        configured = 'v_park_'
    end

    -- Validated once, here, so that a bad prefix fails at boot with a clear message rather
    -- than on the first query with a MySQL syntax error.
    if not configured:match('^[%w_%-%$]+$') then
        Park.error("Config.Database.prefix is '%s', which is not a usable identifier - falling back to 'v_park_'", configured)
        configured = 'v_park_'
    end

    prefixCache = configured
    return prefixCache
end

--[[
    The quoted, prefixed name of one of our tables.

    `Database.table('vehicles')` -> `` `v_park_vehicles` ``

    Every statement in this resource builds its table names through here. Grep for a
    backtick-quoted literal table name and you should find none.
]]
function Database.table(name)
    return quote(prefix() .. name)
end

function Database.rawTable(name)
    return prefix() .. name
end

function Database.prefix()
    return prefix()
end

-- ---------------------------------------------------------------------------------------
-- Driver detection
-- ---------------------------------------------------------------------------------------

local function resourceName(key, fallback)
    local named = Config and Config.Compat and Config.Compat.resources and Config.Compat.resources[key]
    if type(named) == 'string' and named ~= '' then return named end
    return fallback
end

local function detectDriver()
    local forced = Config and Config.Compat and Config.Compat.database

    if forced == 'none' then return nil end
    if forced == 'auto' or forced == nil or forced == '' then forced = nil end

    local candidates = {
        { key = 'oxmysql',      resource = resourceName('oxMySQL', 'oxmysql') },
        { key = 'mysql-async',  resource = 'mysql-async' },
        { key = 'ghmattimysql', resource = 'ghmattimysql' },
    }

    for _, candidate in ipairs(candidates) do
        if (not forced or forced == candidate.key) and Park.started(candidate.resource) then
            return candidate.key, candidate.resource
        end
    end

    return nil
end

-- ---------------------------------------------------------------------------------------
-- The wrapped calls
--
-- One promise wrapper per driver, so that everything above this section is a plain
-- synchronous-looking call. `Citizen.Await` needs a coroutine, so every caller must be inside
-- a thread - which every caller is, and which `Database.thread` exists to guarantee for the
-- ones that are not.
-- ---------------------------------------------------------------------------------------

local function callDriver(kind, sql, params)
    local p = promise.new()

    local function resolve(result)
        p:resolve(result)
    end

    local ok, err = pcall(function()
        if driver == 'oxmysql' then
            local resource = resourceName('oxMySQL', 'oxmysql')
            if kind == 'query' then
                exports[resource]:query(sql, params, resolve)
            elseif kind == 'insert' then
                exports[resource]:insert(sql, params, resolve)
            elseif kind == 'scalar' then
                exports[resource]:scalar(sql, params, resolve)
            else
                exports[resource]:execute(sql, params, resolve)
            end

        elseif driver == 'mysql-async' then
            if kind == 'query' then
                exports['mysql-async']:mysql_fetch_all(sql, params, resolve)
            elseif kind == 'insert' then
                exports['mysql-async']:mysql_insert(sql, params, resolve)
            elseif kind == 'scalar' then
                exports['mysql-async']:mysql_fetch_scalar(sql, params, resolve)
            else
                exports['mysql-async']:mysql_execute(sql, params, resolve)
            end

        elseif driver == 'ghmattimysql' then
            -- ghmattimysql has one entry point and returns rows for everything.
            exports.ghmattimysql:execute(sql, params, resolve)

        else
            resolve(nil)
        end
    end)

    if not ok then
        stats.errors = stats.errors + 1
        Park.error('database call failed to dispatch: %s', tostring(err))
        return nil
    end

    return Citizen.Await(p)
end

--[[
    Run a statement and return its result, timing it.

    A failing statement is logged with its SQL and returns nil. Nothing above this file treats
    a nil result as anything but "no rows", which is the correct interpretation of a failed
    read and a safe one of a failed write: the vehicle stays dirty and is retried next flush.
]]
local function run(kind, sql, params)
    if not ready or not driver then return nil end

    local started = Park.ticks()
    local result = callDriver(kind, sql, params)
    local elapsed = Park.ticks() - started

    stats.queries = stats.queries + 1
    stats.totalMs = stats.totalMs + elapsed
    if elapsed > stats.slowest then stats.slowest = elapsed end
    if kind ~= 'query' and kind ~= 'scalar' then stats.writes = stats.writes + 1 end

    if elapsed > 500 then
        Park.warn('a query took %d ms: %s', elapsed, sql:sub(1, 120))
    end

    return result
end

function Database.query(sql, params)
    local rows = run('query', sql, params)
    if type(rows) ~= 'table' then return {} end
    return rows
end

function Database.single(sql, params)
    local rows = Database.query(sql, params)
    return rows[1]
end

function Database.scalar(sql, params)
    -- ghmattimysql has no scalar. Read the first column of the first row instead, which is
    -- what every other driver's scalar does anyway.
    if driver == 'ghmattimysql' then
        local row = Database.single(sql, params)
        if type(row) ~= 'table' then return nil end
        for _, value in pairs(row) do return value end
        return nil
    end

    return run('scalar', sql, params)
end

function Database.execute(sql, params)
    return run('execute', sql, params)
end

function Database.insert(sql, params)
    return run('insert', sql, params)
end

--[[
    Run a list of statements atomically.

    `queries` is a list of { sql, params }. Returns true when the whole batch committed.

    Only oxmysql publishes a transaction API. On the other two the batch is run statement by
    statement, in order, and the caller is told which happened through the second return
    value - because "committed atomically" and "ran one at a time and the fourth failed" are
    different facts and a save pipeline that cannot tell them apart cannot recover correctly.
]]
function Database.transaction(queries)
    if not ready or not driver then return false, 'none' end
    if type(queries) ~= 'table' or #queries == 0 then return true, 'empty' end

    local useTransaction = Config and Config.Database and Config.Database.transactions ~= false

    if useTransaction and driver == 'oxmysql' then
        local payload = {}
        for i = 1, #queries do
            payload[i] = { query = queries[i][1], values = queries[i][2] }
        end

        local p = promise.new()
        local ok = pcall(function()
            exports[resourceName('oxMySQL', 'oxmysql')]:transaction(payload, function(success)
                p:resolve(success)
            end)
        end)

        if ok then
            local success = Citizen.Await(p)
            stats.queries = stats.queries + 1
            stats.writes = stats.writes + #queries
            if not success then stats.errors = stats.errors + 1 end
            return success == true, 'atomic'
        end
    end

    local failures = 0
    for i = 1, #queries do
        if Database.execute(queries[i][1], queries[i][2]) == nil then
            failures = failures + 1
        end
    end

    return failures == 0, 'sequential'
end

--[[
    Run `fn` inside a thread, so it can await.

    Exists because a statebag handler, an export and an event handler are not always
    coroutines, and `Citizen.Await` outside one raises with a message that says nothing about
    what actually went wrong.
]]
--[[
    Send a statement and DO NOT wait for it.

    The shutdown path, and nothing else.

    `Citizen.Await` needs the scheduler to run again to deliver its callback, and during
    `onResourceStop` there is no guarantee it will: the resource is being torn down. An awaited
    write at that moment can hang until the runtime is destroyed, and the write is lost anyway.

    Firing without awaiting hands the statement to the driver, which has its own queue and its
    own shutdown, and that queue does get drained. It is the difference between a clean stop
    that saves everything and one that saves whatever happened to flush a moment earlier.
]]
function Database.fire(sql, params)
    if not ready or not driver then return false end

    local ok = pcall(function()
        if driver == 'oxmysql' then
            exports[resourceName('oxMySQL', 'oxmysql')]:execute(sql, params)
        elseif driver == 'mysql-async' then
            exports['mysql-async']:mysql_execute(sql, params)
        elseif driver == 'ghmattimysql' then
            exports.ghmattimysql:execute(sql, params)
        end
    end)

    if ok then
        stats.queries = stats.queries + 1
        stats.writes = stats.writes + 1
    else
        stats.errors = stats.errors + 1
    end

    return ok
end

function Database.thread(fn)
    CreateThread(function()
        local ok, err = pcall(fn)
        if not ok then
            Park.error('a database thread raised: %s', tostring(err))
        end
    end)
end

-- ---------------------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------------------

function Database.available()
    return ready and driver ~= nil
end

function Database.memory()
    return memoryMode
end

function Database.driver()
    return driver or 'none'
end

function Database.stats()
    return {
        driver = driver or 'none',
        queries = stats.queries,
        writes = stats.writes,
        errors = stats.errors,
        averageMs = stats.queries > 0 and Park.round(stats.totalMs / stats.queries, 2) or 0,
        slowestMs = stats.slowest,
    }
end

-- ---------------------------------------------------------------------------------------
-- Schema
--
-- Forward-only and additive. Every version adds tables or columns; none drops or renames one.
-- A server that downgrades the resource keeps a column it no longer writes, which is inert,
-- and is a far better outcome than a downgrade that loses data.
-- ---------------------------------------------------------------------------------------

local SCHEMA_VERSION = 2

--[[
    The vehicles table.

    Notes on the column choices, because several are deliberate and non-obvious:

    `id` is CHAR(16), not an auto-increment integer. It is generated by `Park.id()` before the
    row exists, which is what lets a vehicle carry its own identity in a statebag from the
    moment it is created, before any write has happened. An auto-increment would mean a
    round trip to the database in the middle of spawning a car.

    `owner` is VARCHAR(64) and holds a citizenid, an ESX identifier, an ox charId or a
    Rockstar licence depending on the framework. Indexed, because every per-player query goes
    through it.

    `cell` is the spatial grid key, computed on write. It is an INT and it is indexed, and it
    is the reason the streaming pass is a lookup rather than a scan: `WHERE cell IN (...)`
    with nine values, instead of a distance computation over every row.

    `properties` is LONGTEXT rather than JSON. The JSON type would be nicer, and it is not
    available on MariaDB 10.1 or MySQL 5.6, both of which are still under FiveM servers. The
    column stores JSON either way and nothing queries into it.

    `hash` is the delta-detection hash. It is stored so that a restart does not have to
    re-write every row to learn what it already knew.

    `updated_at` and `touched_at` are different on purpose: `updated_at` is when the row last
    changed, `touched_at` is when a player last interacted with the vehicle. Expiry uses
    `touched_at`, so a vehicle that is merely re-saved does not have its expiry reset.
]]
local function vehiclesSchema()
    return ([[
CREATE TABLE IF NOT EXISTS %s (
    `id`             CHAR(16)     NOT NULL,
    `plate`          VARCHAR(12)  DEFAULT NULL,
    `model`          BIGINT       NOT NULL,
    `model_name`     VARCHAR(64)  DEFAULT NULL,
    `class`          TINYINT      NOT NULL DEFAULT 0,
    `vehicle_type`   VARCHAR(24)  DEFAULT NULL,
    `owner`          VARCHAR(64)  DEFAULT NULL,
    `owner_type`     VARCHAR(16)  NOT NULL DEFAULT 'unowned',
    `owner_name`     VARCHAR(64)  DEFAULT NULL,
    `job`            VARCHAR(48)  DEFAULT NULL,
    `pos_x`          DOUBLE       NOT NULL,
    `pos_y`          DOUBLE       NOT NULL,
    `pos_z`          DOUBLE       NOT NULL,
    `rot_x`          FLOAT        NOT NULL DEFAULT 0,
    `rot_y`          FLOAT        NOT NULL DEFAULT 0,
    `rot_z`          FLOAT        NOT NULL DEFAULT 0,
    `cell`           INT          NOT NULL DEFAULT 0,
    `bucket`         INT          NOT NULL DEFAULT 0,
    `interior`       INT          NOT NULL DEFAULT 0,
    `room`           BIGINT       NOT NULL DEFAULT 0,
    `properties`     LONGTEXT     DEFAULT NULL,
    `statebags`      TEXT         DEFAULT NULL,
    `trailer_id`     CHAR(16)     DEFAULT NULL,
    `body_health`    FLOAT        NOT NULL DEFAULT 1000,
    `engine_health`  FLOAT        NOT NULL DEFAULT 1000,
    `fuel`           FLOAT        DEFAULT NULL,
    `wrecked`        TINYINT(1)   NOT NULL DEFAULT 0,
    -- Seconds this vehicle's owner has been offline WHILE THE SERVER WAS UP. The
    -- semi-persistence countdown, and the reason it is a counter rather than a timestamp:
    -- a timestamp would count a nightly restart as absence and clear every job vehicle at
    -- boot. Section 9b of config.lua has the whole argument.
    `offline_secs`   INT          NOT NULL DEFAULT 0,
    -- A hard end time set by a rental resource, or 0. Whichever comes first between this
    -- and the grace period wins; nothing here can extend a rental past what was sold.
    `rental_until`   INT          NOT NULL DEFAULT 0,
    `hash`           BIGINT       NOT NULL DEFAULT 0,
    `source`         VARCHAR(24)  NOT NULL DEFAULT 'auto',
    `created_at`     INT          NOT NULL DEFAULT 0,
    `updated_at`     INT          NOT NULL DEFAULT 0,
    -- `touched_at` moves whenever ANYTHING happens to the vehicle: a save, a repair, a
    -- passing car nudging it. It answers "is this abandoned".
    `touched_at`     INT          NOT NULL DEFAULT 0,
    -- `last_used_at` moves ONLY when a person gets into it. It answers "does anybody still
    -- drive this", which is a different question, and Section 9c of config.lua is the whole
    -- argument for why one column cannot answer both.
    `last_used_at`   INT          NOT NULL DEFAULT 0,
    -- The garage this vehicle was last taken out of, learned from the framework's own column
    -- when we restore it. Where the cleanup sweep sends it back to.
    `last_garage`    VARCHAR(64)  DEFAULT NULL,
    PRIMARY KEY (`id`),
    KEY `idx_cell`    (`cell`, `bucket`),
    KEY `idx_owner`   (`owner`, `owner_type`),
    KEY `idx_plate`   (`plate`),
    KEY `idx_touched` (`touched_at`),
    KEY `idx_model`   (`model`),
    -- The semi-persistence sweep queries by ownership type and offline counter together.
    KEY `idx_semi`    (`owner_type`, `offline_secs`),
    -- The cleanup sweep queries by ownership type and last use together.
    KEY `idx_used`    (`owner_type`, `last_used_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
]]):format(Database.table('vehicles'))
end

local function trashSchema()
    return ([[
CREATE TABLE IF NOT EXISTS %s (
    `id`          CHAR(16)    NOT NULL,
    `deleted_at`  INT         NOT NULL DEFAULT 0,
    `deleted_by`  VARCHAR(64) DEFAULT NULL,
    `reason`      VARCHAR(48) DEFAULT NULL,
    `payload`     LONGTEXT    NOT NULL,
    PRIMARY KEY (`id`),
    KEY `idx_deleted` (`deleted_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
]]):format(Database.table('trash'))
end

local function auditSchema()
    return ([[
CREATE TABLE IF NOT EXISTS %s (
    `id`         INT AUTO_INCREMENT,
    `at`         INT         NOT NULL DEFAULT 0,
    `actor`      VARCHAR(64) DEFAULT NULL,
    `actor_name` VARCHAR(64) DEFAULT NULL,
    `action`     VARCHAR(32) NOT NULL,
    `vehicle_id` CHAR(16)    DEFAULT NULL,
    `detail`     TEXT        DEFAULT NULL,
    PRIMARY KEY (`id`),
    KEY `idx_at` (`at`),
    KEY `idx_vehicle` (`vehicle_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
]]):format(Database.table('audit'))
end

local function metaSchema()
    return ([[
CREATE TABLE IF NOT EXISTS %s (
    `key`   VARCHAR(48) NOT NULL,
    `value` TEXT        DEFAULT NULL,
    PRIMARY KEY (`key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
]]):format(Database.table('meta'))
end

function Database.meta(key, value)
    if not Database.available() then return nil end

    if value == nil then
        return Database.scalar(('SELECT `value` FROM %s WHERE `key` = ?'):format(Database.table('meta')), { key })
    end

    Database.execute(
        ('INSERT INTO %s (`key`, `value`) VALUES (?, ?) ON DUPLICATE KEY UPDATE `value` = VALUES(`value`)')
            :format(Database.table('meta')),
        { key, tostring(value) }
    )
    return value
end

--[[
    Does a table exist in the current schema?

    Used by the schema builder and by the migration, which must not assume the Advanced
    Parking table is there. `DATABASE()` rather than a configured name, because the driver
    already connected to the right one and asking the operator to name it again is one more
    thing to get wrong.
]]
function Database.tableExists(name)
    if not Database.available() then return false end

    local count = Database.scalar(
        'SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?',
        { name }
    )

    return (tonumber(count) or 0) > 0
end

--[[
    The columns of a table, as a set of lowercase names mapped to their data type.

    The whole basis of the schema-agnostic migration: we do not know what Advanced Parking's
    table looks like, so we ask.
]]
function Database.columns(name)
    local out = {}
    if not Database.available() then return out end

    local rows = Database.query(
        'SELECT COLUMN_NAME, DATA_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?',
        { name }
    )

    for _, row in ipairs(rows) do
        local column = row.COLUMN_NAME or row.column_name
        local kind = row.DATA_TYPE or row.data_type
        if column then
            out[tostring(column):lower()] = tostring(kind or 'unknown'):lower()
        end
    end

    return out
end

--[[
    Add a column if it is missing.

    `ADD COLUMN IF NOT EXISTS` is MariaDB-only, so every upgrade checks first. Slower and it
    works on MySQL 5.7, which is what matters.
]]
local function ensureColumn(table_, column, definition)
    local existing = Database.columns(Database.rawTable(table_))
    if existing[column:lower()] then return false end

    Park.log('adding column `%s` to %s', column, Database.rawTable(table_))
    Database.execute(('ALTER TABLE %s ADD COLUMN %s %s')
        :format(Database.table(table_), quote(column), definition))
    if not Database.columns(Database.rawTable(table_))[column:lower()] then
        error(('required column %s.%s could not be added'):format(Database.rawTable(table_), column))
    end
    return true
end

Database.ensureColumn = ensureColumn

--[[
    Create or upgrade the schema. Returns the version now in place.
]]
local function buildSchema()
    if not (Config and Config.Database and Config.Database.autoSchema ~= false) then
        Park.log('Config.Database.autoSchema is off - assuming the schema is already in place')
        return
    end

    Database.execute(metaSchema())
    Database.execute(vehiclesSchema())

    if (tonumber(Config.Database.trashRetentionDays) or 0) > 0 then
        Database.execute(trashSchema())
    end

    if Config.Log and Config.Log.audit then
        Database.execute(auditSchema())
    end

    local current = tonumber(Database.meta('schema_version')) or 0

    -- Older fresh installs were marked current without this column. Check the actual
    -- schema even when its version already agrees, and before recording a successful boot.
    ensureColumn('vehicles', 'vehicle_type', 'VARCHAR(24) DEFAULT NULL AFTER `class`')

    if current == 0 then
        Database.meta('schema_version', SCHEMA_VERSION)
        Database.meta('created_at', Park.now())
        Park.log('schema created at version %d', SCHEMA_VERSION)
        return SCHEMA_VERSION
    end

    if current < SCHEMA_VERSION then
        -- Upgrades go here, one `if current < N` block each, additive only.

        --[[
            Version 2, 1.0.4. `vehicle_type` carries the string
            `CREATE_VEHICLE_SERVER_SETTER` needs, which is not the class and is not derivable
            from it for every model.

            NULL on every existing row, and that is correct: `Classes.setterType` guesses from
            the class until a client next reports the real type, at which point the row is
            corrected for good. Nothing has to be backfilled and nothing breaks in the
            meantime.
        ]]
        -- This column is checked unconditionally above, including incorrectly stamped installs.

        Database.meta('schema_version', SCHEMA_VERSION)
        Park.log('schema upgraded from version %d to %d', current, SCHEMA_VERSION)
    end

    return SCHEMA_VERSION
end

-- ---------------------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------------------

--[[
    Find a driver, wait for it to answer, and build the schema.

    The wait is a real query rather than a resource-state check: oxmysql reports itself
    started well before its connection pool is up, and a schema statement sent into that
    window fails silently on some builds.

    Returns true when the database is usable.
]]
function Database.boot()
    local kind, resource = detectDriver()

    if not kind then
        memoryMode = true
        Park.warn('no MySQL driver found - v-park is running IN MEMORY')
        Park.warn('vehicles will survive a resource restart and NOT a server restart')
        Park.warn("install oxmysql, or set Config.Compat.database = 'none' to silence this")
        return false
    end

    driver = kind
    ready = true

    local timeout = (tonumber(Config.Database and Config.Database.connectTimeout) or 30) * 1000

    --[[
        THE HANDSHAKE RUNS IN ITS OWN THREAD, AND THE TIMEOUT WATCHES A FLAG.

        `Citizen.Await` cannot be cancelled and cannot time out. If the database server is not
        listening at all, oxmysql never calls the callback the promise is waiting on, so the
        await never returns - and an earlier version of this loop blocked inside its FIRST
        `Database.scalar` forever.

        The visible symptom was v-park printing `framework: qb` and then nothing. No error, no
        memory-mode warning, no boot banner, and every timer in the resource waiting on
        `Runtime.ready()` which never became true. Measured with MariaDB stopped.

        So the query goes in its own thread and sets a flag, and the deadline is enforced out
        here where it can actually be enforced. The orphaned thread stays parked on its await
        for the life of the resource, which costs nothing: it holds one coroutine and no timer.
    ]]
    local answered, connected = false, false

    CreateThread(function()
        local answer = Database.scalar('SELECT 1')
        connected = tonumber(answer) == 1
        answered = true
    end)

    local deadline = Park.ticks() + timeout
    while not answered and Park.ticks() < deadline do
        Wait(250)
    end

    if not connected then
        ready = false
        driver = nil
        memoryMode = true

        if answered then
            Park.error('%s answered but not with a working connection - v-park is running IN MEMORY', kind)
        else
            Park.error('%s did not answer within %d seconds - v-park is running IN MEMORY',
                kind, timeout / 1000)
            Park.error('the database server is most likely not running, or not reachable from here')
        end

        Park.error('vehicles will survive a resource restart and NOT a server restart')
        return false
    end

    Park.log('database: %s (%s), tables prefixed `%s`', kind, resource, prefix())

    local ok, err = pcall(buildSchema)
    if not ok then
        ready = false
        driver = nil
        memoryMode = true
        Park.error('the schema could not be created: %s', tostring(err))
        Park.error('v-park is running IN MEMORY. Import sql/v_park.sql by hand and restart.')
        return false
    end

    return true
end

--[[
    Write an audit row.

    Fire and forget, in its own thread, and never awaited by the caller: an admin command must
    not be slowed by its own logging, and a failed audit write must not fail the action it was
    recording.
]]
function Database.audit(action, actor, actorName, vehicleId, detail)
    if not (Config and Config.Log and Config.Log.audit) then return end
    if not Database.available() then return end

    Database.thread(function()
        Database.execute(
            ('INSERT INTO %s (`at`, `actor`, `actor_name`, `action`, `vehicle_id`, `detail`) VALUES (?, ?, ?, ?, ?, ?)')
                :format(Database.table('audit')),
            { Park.now(), actor, actorName, action, vehicleId,
              type(detail) == 'table' and Park.encode(detail) or detail }
        )
    end)
end

--[[
    Drop audit and trash rows past their retention. Called by the daily sweep.
]]
function Database.prune()
    if not Database.available() then return end

    local auditDays = tonumber(Config.Log and Config.Log.auditRetentionDays) or 0
    if auditDays > 0 then
        Database.execute(('DELETE FROM %s WHERE `at` < ?'):format(Database.table('audit')),
            { Park.now() - auditDays * 86400 })
    end

    local trashDays = tonumber(Config.Database and Config.Database.trashRetentionDays) or 0
    if trashDays > 0 then
        Database.execute(('DELETE FROM %s WHERE `deleted_at` < ?'):format(Database.table('trash')),
            { Park.now() - trashDays * 86400 })
    end
end
