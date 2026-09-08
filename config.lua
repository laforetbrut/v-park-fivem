--[[
    v-park / config.lua

    Everything this resource does is decided here. There is no second config file and no
    hidden constant: if a number changes behaviour, it is in this file with the sentence that
    explains what it trades away.

    -------------------------------------------------------------------------------------------
    HOW TO READ THIS FILE
    -------------------------------------------------------------------------------------------

    Sections are numbered and independent. Nothing below section 3 needs to be touched to run
    the resource - the defaults are the ones a busy roleplay server wants - and every section
    below it says, in its own header, what it costs to change.

    The five you will actually open:

        Section 4   Persistence     which vehicles are kept at all
        Section 6   Streaming       how many exist in the world at once, and how far away
        Section 7   Placement       the tight-space respawn. THE section. Read its header.
        Section 8   Lifecycle       when a forgotten vehicle stops being kept
        Section 12  Commands        the names, and who may run them

    -------------------------------------------------------------------------------------------
    THE ONE RULE
    -------------------------------------------------------------------------------------------

    Any optional dependency that is missing degrades, it never errors. The framework, the
    database driver, the fuel resource, the key resource, the notification system and the
    target system are all detected at runtime and all optional. `/vparkinfo` prints what was
    actually found on your server, which is a better answer than anything written here.
]]

Config = {}

-- ===========================================================================================
-- 1. GENERAL
-- ===========================================================================================

Config.General = {
    -- Language. 'auto' follows, in order: the `vpark_locale` convar, `qb_locale`,
    -- `esx_locale`, then English. Set a code to pin it.
    --
    -- Shipped: 'en', 'fr'. A new language is one file in locales/ and one line in
    -- fxmanifest.lua; the check script asserts it is key-for-key identical to English.
    locale = 'auto',

    -- Printed once at boot: what was detected, how many vehicles were loaded, and the
    -- author line the licence asks you to keep. Set false and the resource boots silently
    -- apart from warnings and errors.
    banner = true,

    -- The routing bucket vehicles are restored into.
    --
    -- 0 is the default world and what you want unless you run instanced content. Set to
    -- `false` to restore each vehicle into the bucket it was saved from, which is what an
    -- apartment or instanced-heist server wants. See Section 6 for the streaming
    -- consequence: buckets are matched before distance, so a player in bucket 3 never
    -- spawns a bucket 0 vehicle.
    routingBucket = 0,

    -- Refuse to start when the server is not running OneSync.
    --
    -- The whole design assumes server-side entity creation, which needs OneSync. Without it
    -- there is no way to make a vehicle exist for everybody, and the resource would appear
    -- to work while silently keeping a per-client fiction. Booting loudly is the honest
    -- failure. Set false only if you know exactly why.
    requireOneSync = true,
}

-- ===========================================================================================
-- 2. LOGGING
-- ===========================================================================================

Config.Log = {
    -- 'error' | 'warn' | 'info' | 'debug' | 'trace'
    --
    -- 'info' is the shipping level: boot, migration, and anything an operator needs to know.
    -- 'debug' adds every spawn, despawn and placement decision, which is what you want when
    -- tuning Section 7 and is far too much for a live server.
    -- 'trace' adds every save tick and every grid query. Measured in thousands of lines a
    -- minute on a full server.
    level = 'info',

    -- `/vparkdebug` flips the level between `level` and `debugLevel` at runtime, so a
    -- placement problem can be watched without a restart.
    debugLevel = 'debug',

    -- Log every destructive action - a delete, a purge, an ownership transfer, a migration -
    -- to a database table as well as the console. The table is `<prefix>audit`.
    --
    -- This is the record that answers "who deleted forty cars last Tuesday". It is small:
    -- one row per admin action, not one row per save.
    audit = true,

    -- Rows older than this are dropped by the daily sweep. 0 keeps them forever.
    auditRetentionDays = 30,
}

-- ===========================================================================================
-- 2b. DISCORD WEBHOOKS
--
-- What gets posted, and where.
--
-- -------------------------------------------------------------------------------------------
-- READ THIS BEFORE PUTTING A URL IN THIS FILE
-- -------------------------------------------------------------------------------------------
--
-- A webhook URL is a credential. Anybody who has it can post to your channel as you, forever,
-- with no further authentication. Putting one in `config.lua` means it is in your repository,
-- in your backups, and in the zip you send somebody when you ask for help.
--
-- So the default is to read it from a CONVAR instead, set in `server.cfg` - which is already
-- the file you do not share:
--
--     set vpark_webhook_errors  "https://discord.com/api/webhooks/..."
--     set vpark_webhook_admin   "https://discord.com/api/webhooks/..."
--     set vpark_webhook_activity "https://discord.com/api/webhooks/..."
--
-- Better still, use `set` in a `server_secrets.cfg` that is `exec`-ed and gitignored.
--
-- The `url` fields below are the fallback for operators who would rather have it here. Leaving
-- them nil and using the convars is the recommendation, not a formality.
--
-- -------------------------------------------------------------------------------------------
-- WHY THREE CHANNELS AND NOT ONE
-- -------------------------------------------------------------------------------------------
--
-- Errors need to be seen by whoever fixes them. Admin actions need to be seen by whoever
-- supervises staff. Routine activity needs to be seen by nobody most of the time and searched
-- occasionally. In one channel the first drowns in the third, which is how a real error goes
-- unread for a fortnight.
--
-- Point two of them at the same URL if you want fewer channels. Nothing here objects.
-- ===========================================================================================

Config.Webhooks = {
    enabled = true,

    -- The name and avatar on every post. `avatar` may be nil.
    username = 'v-park',
    avatar = nil,

    -- Prefix every message with your server's name, for a Discord that receives from several.
    -- nil reads `sv_projectName` and falls back to nothing.
    serverName = nil,

    -- ---------------------------------------------------------------------------------
    -- Errors and warnings
    -- ---------------------------------------------------------------------------------
    errors = {
        enabled = true,
        convar = 'vpark_webhook_errors',
        url = nil,

        -- 'error' posts only errors. 'warn' posts warnings too, which on a healthy server
        -- is a handful a week and on a misconfigured one is how you find out.
        level = 'warn',

        -- Identical messages inside this many seconds are collapsed into one post with a
        -- count. Without it, an error inside a per-second timer posts 3600 times an hour and
        -- Discord rate-limits the channel into uselessness.
        dedupeSeconds = 300,

        -- Never post more than this many messages per minute, across everything. Excess is
        -- counted and summarised in the next post rather than dropped silently.
        rateLimitPerMinute = 12,

        -- Include the last few console lines from this resource as context. Off by default:
        -- it makes posts long, and the error message is normally the whole story.
        includeContext = false,
    },

    -- ---------------------------------------------------------------------------------
    -- Staff actions
    --
    -- The record that answers "who deleted forty cars last Tuesday". Everything an admin does
    -- through a command or the panel, with who did it and to what.
    -- ---------------------------------------------------------------------------------
    admin = {
        enabled = true,
        convar = 'vpark_webhook_admin',
        url = nil,

        -- Which actions post. Deletes and ownership transfers are the ones that matter;
        -- the rest are here because somebody will want them.
        actions = {
            delete = true,
            purge = true,
            wipe = true,
            restore = true,
            owner = true,
            impound = true,
            toGarage = true,
            bring = true,
            teleport = false,
            repair = false,
            refuel = false,
            migrate = true,
        },

        -- Include the admin's Discord id when the server can resolve one from their
        -- identifiers, so the post pings the right person rather than naming a character.
        mentionActor = true,
    },

    -- ---------------------------------------------------------------------------------
    -- Routine activity
    --
    -- Off by default, and it should stay off unless you have a reason. On a busy server this
    -- is a post every few seconds.
    -- ---------------------------------------------------------------------------------
    activity = {
        enabled = false,
        convar = 'vpark_webhook_activity',
        url = nil,

        events = {
            parked = false,
            expired = true,
            semiExpired = true,
            evicted = true,
            migrationFinished = true,
            bootSummary = true,
        },
    },

    -- Embed colours, as decimal. Discord takes them as integers, not hex strings.
    colours = {
        error = 15158332,   -- red
        warn = 15844367,    -- amber
        info = 3447003,     -- blue
        success = 3066993,  -- green
        admin = 10181046,   -- purple
    },

    -- Seconds to wait for Discord before giving up on one post.
    --
    -- A webhook that hangs must never hold anything up. Every post is fire-and-forget in its
    -- own thread, so this only bounds how long that thread lives.
    timeout = 5,
}

-- ===========================================================================================
-- 3. COMPATIBILITY
--
-- Everything here is DETECTION OVERRIDE. Leave it all on 'auto' unless your server has two
-- of something installed, or unless you renamed a resource folder.
--
-- `/vparkinfo` prints what detection actually chose.
-- ===========================================================================================

Config.Compat = {
    -- 'auto' | 'qb' | 'qbx' | 'esx' | 'ox' | 'standalone'
    --
    -- Detection order is qbx_core, qb-core, ox_core, es_extended, and the first one started
    -- wins. Force it on a server that has two installed, which is more common than it sounds
    -- during a migration between frameworks.
    --
    -- 'standalone' is a supported configuration, not a fallback: vehicles are keyed on the
    -- Rockstar licence, ownership is whoever last drove it, and everything else is identical.
    framework = 'auto',

    -- The resource folder names, if you renamed one. nil means "the standard name".
    resources = {
        qb        = nil, -- default: qb-core
        qbx       = nil, -- default: qbx_core
        esx       = nil, -- default: es_extended
        ox        = nil, -- default: ox_core
        oxLib     = nil, -- default: ox_lib
        oxMySQL   = nil, -- default: oxmysql
    },

    -- 'auto' | 'oxmysql' | 'mysql-async' | 'ghmattimysql' | 'none'
    --
    -- 'none' runs the whole resource in memory: vehicles persist across a resource restart
    -- but not across a server restart. It is announced once, loudly, at boot. Useful on a
    -- development server and nowhere else.
    database = 'auto',

    -- 'auto' | 'v-hud' | 'ox_lib' | 'qb' | 'esx' | 'okok' | 'native' | 'none'
    --
    -- 'v-hud' is checked first when it is installed, so a server running it gets every
    -- v-park message in the player's own chosen HUD theme rather than in a second style
    -- sitting next to it.
    --
    -- 'native' is this resource's own on-screen toast, drawn with game natives. It exists so
    -- that a standalone server is not silent.
    notify = 'auto',

    -- 'auto' | 'rcore_fuel' | 'ox_fuel' | 'LegacyFuel' | 'ps-fuel' | 'cdn-fuel'
    --   | 'qs-fuelstations' | 'lj-fuel' | 'x-fuel' | 'okokGasStation' | 'native' | 'none'
    --
    -- Fuel is the one property that half the ecosystem stores outside the vehicle, in a
    -- statebag or a decor. Detection covers the ten above; `fuelStatebag` below covers
    -- everything else in one line.
    --
    -- rcore_fuel is checked FIRST when several are installed, because it is the one that
    -- actively overwrites a fuel level it did not set: a value written through anything but
    -- its own export is reverted on its next tick, and the vehicle comes back with a full
    -- tank it did not have.
    fuel = 'auto',

    -- The statebag key your fuel resource writes, if it is not one of the detected ones.
    -- Setting this switches fuel handling to "read and write this statebag", which works for
    -- any resource built in the last three years.
    --
    -- Known keys: ox_fuel and most modern forks use 'fuel'. cdn-fuel uses 'fuel'. Some use
    -- 'fuelLevel'.
    fuelStatebag = nil,

    -- 'auto' | 'qs-vehiclekeys' | 'qb-vehiclekeys' | 'wasabi_carlock' | 'mk_vehiclekeys'
    --   | 'cd_garage' | 'jaksam' | 'none'
    --
    -- What this does: after a persisted vehicle is restored, its owner should still have the
    -- keys they had before the restart. Section 15 decides whether that happens at all.
    --
    -- Quasar's key resource is `qs-vehiclekeys` and is handled through both its export and
    -- its client event, because which of the two exists depends on the build.
    keys = 'auto',

    -- 'auto' | 'qs-inventory' | 'ox_inventory' | 'qb-inventory' | 'core' | 'none'
    --
    -- Only used to keep trunk and glovebox contents attached to the right vehicle. See
    -- Section 16 - on every inventory listed this is automatic and needs nothing from us,
    -- because they all key the stash on the plate and we preserve the plate exactly.
    inventory = 'auto',

    -- 'auto' | 'ox_target' | 'qb-target' | 'qtarget' | 'none'
    --
    -- Optional. Only used by the optional "park here" target option in Section 17.
    target = 'auto',

    -- Garage resources whose stored vehicles must never be restored into the world.
    --
    -- 'auto' detects, in order: qs-advancedgarages and qs-smartgarage (Quasar), qb-garages,
    -- qbx_garages, jg-advancedgarages, cd_garage, loaf_garage, okokGarage, RxGarage.
    --
    -- The mechanism is not a hook into their code: it is that a vehicle they delete stops
    -- being tracked, and a vehicle their database marks as stored is skipped on load.
    -- Section 18 has the detail, including the one snippet Quasar's garage wants.
    garages = 'auto',
}

-- ===========================================================================================
-- 4. DATABASE
--
-- Every table this resource creates is prefixed. Nothing outside the prefix is ever read,
-- written or dropped, with one exception that is asked for explicitly: the Advanced Parking
-- table during a migration, which is only ever READ. See Section 19.
-- ===========================================================================================

Config.Database = {
    -- The prefix on every table name.
    --
    -- WHY THE UNDERSCORE. `v-park_vehicles` is a legal MySQL identifier but only inside
    -- backticks, so every hand-typed query against it - in Adminer, in a backup script, in a
    -- support thread - fails with a syntax error until somebody works out why. `v_park_` is
    -- the same namespace with none of that.
    --
    -- If you would rather have the hyphen, set it. Every identifier this resource emits is
    -- backticked, so `v-park_` works correctly; you are only choosing what your own queries
    -- will have to look like.
    prefix = 'v_park_',

    -- Create and upgrade the schema on boot.
    --
    -- Leave true. The migration between our own schema versions is forward-only, additive,
    -- and logged. `sql/v_park.sql` is shipped for operators who would rather import by hand;
    -- with this true, importing it is optional.
    autoSchema = true,

    -- How long to wait, in seconds, for the database driver to answer its first query before
    -- giving up and running in memory.
    --
    -- oxmysql is normally ready in under a second. A server whose MySQL is on another
    -- machine can take longer, and giving up too early means booting into memory mode on a
    -- server that has a perfectly good database.
    connectTimeout = 30,

    -- Rows per batched write. The save pipeline coalesces every dirty vehicle into one
    -- statement of this size.
    --
    -- 200 is comfortable for MySQL's default max_allowed_packet with a full modifications
    -- blob per row. Raise it on a server with thousands of vehicles and a tuned MySQL;
    -- lower it if you see packet errors in the console.
    batchSize = 200,

    -- Wrap each batch in a transaction.
    --
    -- With this on, a crash mid-flush leaves the table exactly as it was before the flush
    -- rather than half-written. Costs one round trip per batch. There is no good reason to
    -- turn it off except a driver that does not support it, which we detect anyway.
    transactions = true,

    -- Keep deleted vehicles in `<prefix>trash` for this many days so `/vparkrestore` can
    -- bring one back. 0 disables the trash entirely and makes every delete final.
    --
    -- This is the single most requested feature that persistence scripts do not have: an
    -- admin deletes the wrong car and there is nothing to do about it.
    trashRetentionDays = 7,
}

-- ===========================================================================================
-- 5. PERSISTENCE
--
-- WHICH VEHICLES ARE KEPT. The most important section for how your server feels, and the one
-- with the biggest performance consequence: every rule here is evaluated once, when a vehicle
-- first becomes a candidate, and never again.
-- ===========================================================================================

Config.Persistence = {
    -- 'all' | 'owned' | 'claimed' | 'none'
    --
    --   'all'      Any vehicle a player drives becomes persistent. Closest to what
    --              Advanced Parking does by default. Expect a few thousand rows on a busy
    --              server, which is fine - see Section 8, they expire.
    --
    --   'owned'    Only vehicles the framework says belong to a character: the qb-core
    --              `player_vehicles` table, ESX `owned_vehicles`, ox_core `vehicles`. A
    --              stolen car vanishes on restart. Quieter world, fewer surprises.
    --
    --   'claimed'  Nothing persists until somebody runs `/vpark` in it. Maximum player
    --              agency, smallest table, and it makes parking a deliberate act, which
    --              some servers want and some hate.
    --
    --   'none'     Persistence off. The commands, the API and the migration still work, so
    --              this is the setting to use while migrating, before you flip the switch.
    --
    -- 'owned' IS THE DEFAULT SINCE 1.0.2. It was 'all', which persists every car anybody
    -- drives, and on a busy server that is a table full of stolen taxis nobody will ever look
    -- for again. 'owned' keeps the cars players actually care about and lets the rest be
    -- traffic - and with `keysGrantOwnership` in Section 10, holding the keys is enough to
    -- count, so an admin-spawned car or one handed over by another player is kept too.
    --
    -- Set it back to 'all' if you were running 1.0.0 or 1.0.1 and want the old behaviour.
    mode = 'owned',

    -- In 'owned' and 'claimed' mode, also keep vehicles that belong to a job or a gang.
    -- Police cruisers left outside Mission Row survive the restart; a stolen Sultan does not.
    jobVehicles = true,

    -- In 'owned' mode, also keep a vehicle a player explicitly parked with `/vpark`.
    --
    -- On by default because `mode = 'owned'` is the default, and without this the park
    -- command would do nothing at all on a stock install: a claim is neither an owned vehicle
    -- nor a job one, so the mode would refuse it. A claim is a deliberate act by a player
    -- about a car they are sitting in, and silently ignoring it is not a defensible reading
    -- of any mode.
    --
    -- Turn it off for a strict "only what the framework says is theirs" server.
    allowClaimInOwnedMode = true,

    -- Seconds a vehicle must have been stationary and empty before it is written for the
    -- first time.
    --
    -- This is not about performance, it is about intent. Without it, every car a player
    -- steps out of for four seconds at a red light becomes a permanent fixture of the map.
    -- 45 seconds says "they left it there".
    --
    -- Set to 0 to persist the moment a player leaves the vehicle.
    --
    -- IT DOES NOT APPLY TO OWNED VEHICLES. See `ownedImmediately` directly below.
    settleSeconds = 45,

    --[[
        A vehicle the framework says somebody OWNS is kept the moment they get into it.

        No settle timer, no command, no waiting for them to walk away. It is theirs; it is
        kept. That is the whole rule.

        WHY THIS IS SEPARATE FROM `settleSeconds`. The settle timer answers "did they leave
        it there or are they coming back", which is a real question for a car nobody owns -
        the alternative is every vehicle a player steps out of at a red light becoming a
        permanent fixture of the map.

        It is not a question at all for a car that is already in the player's garage list.
        That car is theirs whether they walk away or not, and making them wait forty-five
        seconds for it to be kept means a player who takes their car out and disconnects
        thirty seconds later loses it. Which is exactly the case where losing it hurts most.

        The check is one indexed lookup against the framework's owned-vehicles table, on
        entry, once per vehicle. A vehicle that is not owned falls through to the settle
        timer as before.

        Turn it off only if you genuinely want owned vehicles to wait as well.
    ]]
    ownedImmediately = true,

    --[[
        How long before the same vehicle is offered on entry again.

        The offer is what asks the server "is this car theirs, and should it be kept". 1.0.1
        made it once per vehicle per session, which meant a player who got into a car and THEN
        got the keys - `/admincar`, a mate handing them over, a dealership finishing a sale -
        was never asked about again and lost the car on the next restart. Reported as exactly
        that.

        Sixty seconds is one small event a minute for as long as somebody is sitting in a car
        that is not theirs, and nothing at all once they get out or once it is adopted.

        Raise it if you have a very large player count and a very slow key resource. Setting
        it to 0 offers on every entry.
    ]]
    entryOfferRetrySeconds = 60,

    -- Also persist a vehicle the moment its driver disconnects, without waiting for
    -- `settleSeconds`.
    --
    -- Otherwise a crash at 03:00 costs the player their car. The vehicle is written where it
    -- stood, which is occasionally the middle of the motorway - Section 7 handles that far
    -- better than deleting it would.
    saveOnDisconnect = true,

    -- Persist a vehicle nobody has ever driven, if a player has been within `noticeRadius`
    -- of it for `noticeSeconds`.
    --
    -- Off by default and it should stay off unless you know what you are asking for: the
    -- world is full of ambient parked cars, and turning this on writes every one of them a
    -- player walks past. It exists for servers that want a genuinely static world.
    ambient = {
        enabled = false,
        noticeRadius = 8.0,
        noticeSeconds = 120,
        -- Even with it on, cap how many ambient vehicles may be adopted per hour so a single
        -- player walking through downtown cannot add four hundred rows.
        perHourLimit = 20,
    },

    -- Vehicle classes that never persist, by class id.
    --
    --   0 Compacts        1 Sedans          2 SUVs           3 Coupes
    --   4 Muscle          5 Sports Classic  6 Sports         7 Super
    --   8 Motorcycles     9 Off-road       10 Industrial    11 Utility
    --  12 Vans          13 Cycles          14 Boats         15 Helicopters
    --  16 Planes        17 Service         18 Emergency     19 Military
    --  20 Commercial    21 Trains          22 Open Wheel
    --
    -- 13 (bicycles) and 21 (trains) are excluded by default and you almost certainly want to
    -- keep them that way: a bicycle is not parked, it is dropped, and a persisted train is a
    -- support ticket.
    excludedClasses = { 13, 21 },

    -- Classes that persist but are not restored into the world unless a player is very close.
    -- See `Config.Streaming.classRadius` - this list is the one that feeds it.
    --
    -- Aircraft and boats are here because they are large, expensive to stream, and normally
    -- parked somewhere nobody walks past by accident.
    lowPriorityClasses = { 14, 15, 16 },

    -- Model names that never persist. Case-insensitive, matched against the model name and
    -- against the model hash.
    excludedModels = {
        -- Nothing by default. Common additions:
        -- 'taxi', 'trash', 'trash2', 'firetruk', 'ambulance', 'police', 'policeb',
    },

    -- Only these models persist. An empty list means "no whitelist", which is the default.
    -- A non-empty list overrides `excludedModels` entirely: whitelist wins.
    includedModels = {},

    -- Plates that never persist. Useful for a dealership's demo fleet or a job's spawner
    -- fleet, both of which normally use a fixed plate prefix.
    --
    -- A trailing `*` makes it a prefix match: 'PDM*' excludes every plate starting PDM.
    excludedPlates = {
        -- 'PDM*',
    },

    -- Never persist a vehicle whose engine is destroyed or whose body is below this.
    --
    -- 0 disables the check and keeps wrecks. A wreck IS a legitimate thing to persist -
    -- it is evidence, and a burnt-out car outside a bank is good roleplay - but it is also
    -- what a table fills up with if nobody cleans up. Section 8 expires them faster.
    minimumBodyHealth = 0,

    -- Persist trailers, and persist the fact that a trailer was attached to a truck.
    --
    -- On restore, the trailer is placed first, then the truck, then they are re-attached.
    -- If either half fails to place, neither is attached and both stand where they were,
    -- which is a strictly better failure than a truck welded to a trailer inside a wall.
    trailers = true,

    -- Persist vehicles attached to a tow truck or a cargobob the same way.
    -- Experimental, and off by default: the attachment offsets are not always reproducible
    -- across a game build change.
    attached = false,

    -- Never persist a vehicle that is inside a `Config.Zones` blocked zone. See Section 11.
    respectZones = true,

    -- Hard ceiling on rows in the table. When it is reached, the oldest untouched vehicle is
    -- evicted before a new one is written - see `Config.Lifecycle.eviction`.
    --
    -- 0 means no ceiling. 20000 is roughly 40 MB of table on a typical server and is a
    -- number chosen to be far above what any server reaches, so that hitting it is a signal
    -- that something is wrong rather than a routine event.
    maximumVehicles = 20000,

    -- Per-character ceiling. 0 means no ceiling.
    --
    -- This is the knob that stops one player leaving thirty cars scattered across the map.
    -- When they exceed it, their OLDEST persisted vehicle is dropped, and they are told
    -- which one.
    maximumPerCharacter = 0,
}

-- ===========================================================================================
-- 6. SAVING
--
-- WHEN AND WHAT IS WRITTEN. The delta design is the whole performance story: a vehicle is
-- written when something about it changed, and a parked car changes nothing, so a server with
-- three thousand parked cars writes zero rows a minute.
-- ===========================================================================================

Config.Save = {
    -- Seconds between save sweeps. Every tracked vehicle is hashed and the changed ones are
    -- queued.
    --
    -- The sweep is staggered across this interval rather than done all at once, so the cost
    -- is spread over the whole window instead of a spike every N seconds. Lower is not
    -- meaningfully more expensive; it only means smaller, more frequent batches.
    interval = 30,

    -- Seconds between flushes of the write queue to the database.
    --
    -- Separate from `interval` on purpose: hashing is cheap and can be frequent, writing is
    -- not and should be batched. A vehicle that changes three times in a minute is written
    -- once.
    flushInterval = 15,

    -- Fraction of the tracked set hashed per sweep tick, as a divisor.
    --
    -- 1 hashes everything every `interval`. 4 hashes a quarter of the set four times as
    -- often, which produces the same coverage with a quarter of the peak cost. Raise it on a
    -- server with thousands of vehicles.
    sweepSlices = 4,

    -- Also write immediately when any of these happen, without waiting for the sweep.
    triggers = {
        onExit = true,          -- a player left the vehicle
        onDisconnect = true,    -- the driver disconnected
        onShutdown = true,      -- the resource or the server is stopping. Never turn off.
        onDamage = true,        -- the vehicle took meaningful damage. Rate-limited below.
        onOwnerChange = true,   -- ownership was transferred
        onLockChange = true,    -- somebody locked or unlocked it
    },

    -- Minimum seconds between two immediate writes of the SAME vehicle.
    --
    -- Without this, a vehicle being rammed repeatedly writes a row per impact. With it, the
    -- damage trigger collapses into one write and the rest is picked up by the sweep.
    triggerCooldown = 10,

    -- What is stored. Turning one off makes the row smaller and the property application on
    -- respawn faster, at the cost of that thing not surviving a restart.
    --
    -- The defaults store everything. There is no meaningful saving in turning these off on a
    -- normal server; they exist because somebody always has a reason.
    fields = {
        modifications = true,  -- every mod slot, wheels, livery, plate holder
        colours = true,        -- primary, secondary, pearlescent, wheel, interior, dashboard
        customPaint = true,    -- RGB custom paint, which is separate from the colour index
        neons = true,
        extras = true,
        xenon = true,
        windowTint = true,
        tyreSmoke = true,
        damage = true,         -- doors, windows, tyres, and which are broken off
        deformation = true,    -- the bodywork SHAPE. See Section 6b before turning it off
        health = true,         -- body, engine, petrol tank
        dirt = true,
        fuel = true,
        oil = true,
        lockState = true,
        engineState = false,   -- restore the engine running. Off: a parked car is off.
        doorsOpen = false,     -- restore open doors. Off: they close, which looks parked.
        roofState = true,      -- convertible roof up or down
        livery = true,
        plate = true,
        statebags = true,      -- only the keys in `statebagKeys` below
    },

    -- Which entity statebag keys are carried across a restart.
    --
    -- A whitelist, never a blanket copy. Statebags are how half the ecosystem stores vehicle
    -- data, and copying all of them would resurrect stale keys from resources that have
    -- since been removed - including, on some servers, ones that mark a vehicle as owned.
    --
    -- Add your own resource's keys here. They are stored verbatim and re-applied on the
    -- server side after the entity exists.
    statebagKeys = {
        -- Fuel, under the three names the ecosystem uses.
        'fuel',
        'fuelLevel',

        -- Identity keys some garages and key resources hang off the entity.
        'vehicleid',
        'vehicleProps',
        'doorslocked',

        -- v-hud reads these off the vehicle. Carrying them across a restart is what keeps a
        -- car's mileage and its fitted NOS bottle after a reboot instead of resetting the
        -- odometer to zero, which reads as a different car to every mechanic script.
        'odometer',
        'mileage',
        'jimOdo',
        'hasnitro',
        'noslevel',

        -- Ours. `vpark:label` is the optional name an owner can give a vehicle.
        'vpark:label',
    },

    -- Cap on the serialised size of one vehicle's data, in bytes. A vehicle over the cap is
    -- stored without its statebags first, and then without its modifications, and is logged.
    --
    -- This exists because a badly behaved resource can put a hundred kilobytes into a
    -- statebag, and one such vehicle should not be able to blow up a batch insert.
    maximumRowBytes = 65536,
}

-- ===========================================================================================
-- 6b. DEFORMATION
--
-- Bodywork shape: the dents, not the health number.
--
-- -------------------------------------------------------------------------------------------
-- WHY IT IS A SEPARATE SECTION
-- -------------------------------------------------------------------------------------------
--
-- `bodyHealth` is one number and two cars at 600 look nothing alike: one folded at the front,
-- one caved in along the driver's door. Restoring the number without the shape gives a car
-- that comes back with its damage in the wrong place.
--
-- It is also the most common desync in FiveM. The engine hands a vehicle's damage to whoever
-- owns the entity and reconstructs it approximately everywhere else, so two players beside the
-- same wreck routinely see two different wrecks.
--
-- Both have one answer: sample the deformation into data, store it, and have EVERY client
-- apply that same data. Then the dents are identical everywhere by construction instead of by
-- hoping the engine agrees with itself.
--
-- `client/deformation.lua` documents the technique and its one real limitation, which is that
-- applying a shape is approximate. `recaptureDelta` below is the guard that stops the
-- approximation compounding.
-- ===========================================================================================

Config.Deformation = {
    -- Capture, store, restore and synchronise bodywork deformation.
    --
    -- Off means body health is still stored and restored, so a damaged car still drives like
    -- a damaged car. It just comes back with its dents in the engine's idea of the right
    -- place rather than yours.
    enabled = true,

    -- Metres. A sampled point must have moved at least this far inwards to be stored.
    --
    -- 0.05 is five centimetres, which is about the smallest dent that reads on screen at
    -- normal draw distance. Lowering it stores paint scratches as geometry and makes the
    -- delta hash flap on floating point noise; raising it loses light damage.
    threshold = 0.05,

    -- Magnitudes are stored as integers at this scale. 100 means centimetres.
    --
    -- The reason to quantise at all is stability: two reads of the same undamaged panel
    -- differ in the fifth decimal, and an unquantised value would make an untouched parked
    -- car look changed on every save sweep.
    quantiseScale = 100.0,

    -- Most deformation points stored per vehicle.
    --
    -- A car rolled down a hill lights up most of the grid, and this data replicates to every
    -- client in scope. The deepest dents are the ones that read on screen, so the cap keeps
    -- those and drops the rest. 48 is roughly 200 bytes.
    maximumPoints = 48,

    -- Milliseconds the restore may spend deforming one vehicle before giving up on the
    -- points it has not reached yet.
    --
    -- Restoring a shape is a search - hit the panel, measure, hit it harder - so it is
    -- budgeted rather than capped by iterations: what matters is that the frame does not
    -- stall, not how many corrections it took. It runs in its own thread while the vehicle
    -- is still frozen and settling, so a player never sees the difference.
    applyBudgetMs = 120,

    -- Hard ceiling on correction passes, in case a model simply will not deform at a point.
    maximumPasses = 12,

    -- Metres. How close a restored dent has to get to the stored one before it is finished.
    tolerance = 0.03,

    -- The two constants that turn a target dent depth into a first guess at the `damage`
    -- argument `SetVehicleDamage` wants. Fitted against the base game's compacts, sedans,
    -- SUVs and muscle cars.
    --
    -- Only worth touching on a server whose fleet is mostly add-ons with unusual
    -- proportions, and the symptom that would send you here is dents that come back
    -- consistently too shallow or too deep.
    seedBase = 20.0,
    seedGain = 90.0,

    -- Body health must move by more than this before a RESTORED vehicle is re-captured.
    --
    -- THE DRIFT GUARD, and the setting not to set to 0. Applying a shape is approximate, so
    -- capturing from a car we restored and storing that is a copy of a copy. Doing it every
    -- save sweep walks the damage away from what the player actually did. 20 body health is
    -- comfortably more than noise and comfortably less than a real impact.
    recaptureDelta = 20.0,

    -- Stand aside when Kiminaze's VehicleDeformation resource is installed.
    --
    -- It writes the same kind of data to a statebag on the same entities. Two resources
    -- deciding what shape a car is, on different schedules, makes the car visibly pulse.
    -- With this on we read and write through its exports instead, so its damage still
    -- survives a restart and nothing fights.
    deferToVehicleDeformation = true,
}

-- ===========================================================================================
-- 6c. MECHANIC AND TUNING RESOURCES
--
-- Vehicle modifications are read and written through the game's own mod slots, so anything a
-- tuning script fits is captured by Section 6 without knowing that script exists. This section
-- is only for the things a tuning script keeps OUTSIDE the vehicle, which the game cannot tell
-- us about.
-- ===========================================================================================

Config.Mechanic = {
    -- 'auto' | 'jim-mechanic' | 'none'
    resource = 'auto',

    -- jim-mechanic keeps nitrous per PLATE, in two extra columns on the framework's
    -- owned-vehicles table, and holds a live copy in memory that it rebuilds from that table
    -- at boot.
    --
    -- For an owned vehicle that is enough on its own: we preserve the plate exactly, so its
    -- rows still match. For a vehicle that is NOT in the owned table - a stolen car, a job
    -- vehicle, anything persisted by us and unknown to the framework - its in-memory entry
    -- is lost on restart and the bottle disappears.
    --
    -- With this on, the nitrous statebags are carried across the restart and its load event
    -- is re-fired for the restored plate, so the fitted bottle survives on any vehicle.
    restoreNitrous = true,

    -- Purge, tyre smoke trails and exhaust flames are keyed on a network id and are runtime
    -- effects rather than fitted parts: there is nothing on the vehicle to read them back
    -- from once it is gone. They are not restored, and this switch exists only so that
    -- turning it on produces a documented warning rather than silence.
    restoreEffects = false,
}

-- ===========================================================================================
-- 7. PLACEMENT
--
-- THE TIGHT-SPACE RESPAWN. This is the section that exists because every other persistence
-- script gets this wrong, and it is worth reading in full before changing anything.
--
-- -------------------------------------------------------------------------------------------
-- THE PROBLEM, STATED PRECISELY
-- -------------------------------------------------------------------------------------------
--
-- A vehicle restored at the coordinates it was saved at will, on a stock setup, end up
-- somewhere else. Four separate mechanisms move it, and each needs a different answer:
--
--   1. COLLISION IS NOT LOADED YET. The entity is created before the map geometry around it
--      streams in, so for a few hundred milliseconds it is standing on nothing. It falls. By
--      the time the ground arrives it is under it, and the engine pops it out somewhere
--      approximately correct - the middle of the road, usually.
--      ANSWER: create it frozen, wait for `HasCollisionLoadedAroundEntity`, then unfreeze.
--
--   2. SOMETHING IS ALREADY THERE. Ambient traffic spawns while the server is empty, and the
--      game is happy to put a parked NPC car exactly where the player left theirs. Two solid
--      bodies in one place is an explosion, or a launch.
--      ANSWER: probe the target volume before creating anything, and clear ambient vehicles
--      out of it. Never clear another persisted vehicle - resolve that case by claim age.
--
--   3. THE ENGINE GROUND-SNAPS IT. `SetVehicleOnGroundProperly` is what most scripts reach
--      for, and in an underground car park or a narrow alley it probes down, finds the level
--      below, and drops the car through the floor.
--      ANSWER: never call it. Place with `SetEntityCoordsNoOffset` at the exact saved Z, and
--      only probe the ground when the saved Z is provably wrong.
--
--   4. IT IS IN AN INTERIOR. A vehicle inside an MLO garage is, to the engine, in a room. An
--      entity placed at those coordinates without being told which room is outside the
--      interior looking in, and renders through the wall or falls to the world below.
--      ANSWER: store the interior and the room, and force them on restore.
--
-- Everything in this section is one of those four answers with a number attached.
-- ===========================================================================================

Config.Placement = {
    -- Milliseconds to wait for collision to load around a newly created vehicle before
    -- unfreezing it.
    --
    -- The wait ends early the moment `HasCollisionLoadedAroundEntity` answers true, so this
    -- is a ceiling and not a delay. It is only reached when nobody is close enough to stream
    -- the map at all, in which case the vehicle stays frozen, which is correct.
    collisionTimeout = 8000,

    -- Milliseconds the vehicle stays frozen AFTER collision loads, before physics is handed
    -- back to it.
    --
    -- Small but not zero. Handing physics to a car in the same frame the ground arrives
    -- produces a visible settle - a bounce, or a slide down a camber. 250 ms of stillness
    -- costs nothing and looks like a parked car.
    settleDelay = 250,

    -- Keep a restored vehicle frozen until a player interacts with it.
    --
    -- THIS IS THE BIG ONE, for both fidelity and performance.
    --
    -- Fidelity: a frozen car cannot drift, cannot be nudged down a slope by a passing NPC,
    -- and cannot be slowly walked out of a tight parking space by the physics solver over
    -- twenty minutes. It is exactly where it was left, indefinitely.
    --
    -- Performance: a frozen entity is not simulated. Three thousand restored vehicles at
    -- rest cost the client almost nothing.
    --
    -- It unfreezes the instant any of these happen: a player opens a door, enters it, shoots
    -- it, rams it, or comes within `wakeRadius` while looking at it. So it is invisible in
    -- play - a player never touches a car that is still frozen.
    freezeUntilTouched = true,

    -- Metres. A frozen vehicle within this distance of a player wakes up.
    -- Below `Config.Streaming.spawnRadius` by design: waking is a much cheaper event than
    -- spawning, and doing it early means the car is already live by the time anybody
    -- reaches it.
    wakeRadius = 30.0,

    -- Re-freeze a woken vehicle after this many seconds with no player within `wakeRadius`
    -- and no movement. 0 disables re-freezing.
    --
    -- The hysteresis matters: without it, a player walking back and forth at the boundary
    -- freezes and unfreezes the same car repeatedly.
    refreezeAfter = 60,

    -- ---------------------------------------------------------------------------------
    -- The probe: is the target volume free?
    -- ---------------------------------------------------------------------------------
    probe = {
        -- Run the probe at all. Off means "place it and hope", which is what every other
        -- script does. There is no reason to turn this off except measuring the difference.
        enabled = true,

        -- Shrink the model's bounding box by this fraction before testing.
        --
        -- WHY SHRINK. A model's bounding box is bigger than the body: it includes the wing
        -- mirrors, the aerial and a margin. Testing the raw box in a garage bay whose walls
        -- are exactly car-width reports "blocked" every time, and the vehicle gets nudged
        -- out of a space it fits in perfectly.
        --
        -- 0.88 was measured against the tightest legitimate space in the base map: the
        -- single-car garages behind Grove Street, and the middle bays of the Pillbox
        -- underground car park. Raise it towards 1.0 for stricter checking and more false
        -- blocks; lower it for the opposite.
        shrink = 0.88,

        -- Metres of clearance required above the vehicle. Catches the case of a car saved on
        -- a car lift or under a garage door that has since closed.
        headroom = 0.15,

        -- What counts as blocking. These are shape test flags, and each is a different class
        -- of thing you may or may not want to move for.
        blockedBy = {
            world = true,      -- map geometry: walls, pillars, closed shutters
            objects = true,    -- props: bins, barriers, pallets
            vehicles = true,   -- other vehicles, ours and ambient
            peds = false,      -- an NPC standing in the bay. Not worth moving a car for;
                               -- the NPC will walk away, and pushing one is harmless.
        },
    },

    -- ---------------------------------------------------------------------------------
    -- Clearing what is in the way
    -- ---------------------------------------------------------------------------------
    clear = {
        -- Delete ambient (game-spawned, unowned, empty) vehicles inside the target volume.
        --
        -- This is what fixes "my car came back on top of an NPC Asea". It only ever removes
        -- a vehicle that has no driver, no passengers, is not persisted by us, and is not
        -- flagged as a mission entity. Nothing a player owns or is using can be caught by it.
        ambientVehicles = true,

        -- Metres beyond the vehicle's own footprint to sweep for ambient vehicles.
        radius = 1.5,

        -- Delete loose props (rubbish bags, cones, boxes) inside the target volume too.
        -- Off by default: a prop is more likely to be somebody's roleplay than a car is.
        props = false,

        -- Suppress ambient traffic and parked-car generation around a restored vehicle for
        -- this many seconds after it is placed. 0 disables.
        --
        -- Stops the game deciding, four seconds after we restored a car into a bay, that the
        -- bay is empty and putting an NPC car in it.
        suppressTrafficSeconds = 20,
    },

    -- ---------------------------------------------------------------------------------
    -- When the exact spot really is blocked: the search
    -- ---------------------------------------------------------------------------------
    search = {
        -- Look for a free spot near the saved one when the saved one is blocked by something
        -- that could not be cleared - a wall, a player's car, a prop somebody placed.
        --
        -- Off means "place it at the saved spot anyway and let the engine sort it out", which
        -- is occasionally what you want on a server whose map has changed underneath its
        -- saved vehicles.
        enabled = true,

        -- Metres between rings of the search. Half a car width.
        step = 1.25,

        -- How far out to look before giving up, in metres.
        --
        -- Deliberately small. A car that comes back nine metres from where it was parked is
        -- a bug report; one that comes back two metres over, in the next bay, is not. If
        -- nothing within `maximumRadius` is free, the fallback below decides what happens,
        -- and every fallback is better than teleporting a car across the street.
        maximumRadius = 6.0,

        -- Candidate positions per ring. 8 is one every 45 degrees.
        perRing = 8,

        -- Keep the saved heading at every candidate position.
        --
        -- True is what you want: a car parked nose-in stays nose-in, one bay over. False
        -- lets the search rotate it to fit, which finds more spots and looks worse - a car
        -- at 40 degrees to the kerb reads as crashed, not parked.
        keepHeading = true,

        -- Also try the saved position at the level above and below, offset by this many
        -- metres, before searching sideways.
        --
        -- This is the multi-storey car park case: the Z drifted by a floor because the
        -- vehicle was saved mid-fall, and the right answer is one floor up, not two metres
        -- sideways.
        verticalRetry = 3.5,
    },

    -- What happens when the probe fails and the search finds nothing.
    --
    --   'place'   Put it at the saved position regardless, frozen. It may be intersecting
    --             geometry, and it will be exactly where the player left it. With
    --             `freezeUntilTouched` on, this is stable: nothing pushes it, and the first
    --             player to drive it out resolves the intersection.
    --             THE DEFAULT, and the right answer for a tight space.
    --
    --   'defer'   Do not place it now. Try again on the next streaming pass, and keep
    --             trying. The vehicle exists in the database and simply is not in the world
    --             yet. Right for a server whose map is still loading.
    --
    --   'ground'  Place it at the saved X and Y, on the ground, keeping the heading. Gives
    --             up on the exact Z. Right for an outdoor-only server.
    --
    --   'skip'    Do not place it and do not retry until the player moves away and comes
    --             back.
    fallback = 'place',

    -- Restore the interior and room a vehicle was saved in.
    --
    -- Needed for any vehicle parked inside an MLO: a garage, a warehouse, a tunnel with its
    -- own interior. Without it the car is at the right coordinates and in the wrong room,
    -- which the renderer resolves by not drawing it, or by dropping it to the world below.
    restoreInterior = true,

    -- Cross-check the saved Z against the ground beneath it, and correct it when it is
    -- provably wrong.
    --
    -- "Provably wrong" means: more than `groundTolerance` metres BELOW the ground. A vehicle
    -- above the ground is on a ramp, a roof or a car park level and must not be touched. A
    -- vehicle below it was saved mid-fall through the map and has no correct Z to restore.
    groundCheck = true,
    groundTolerance = 1.5,

    -- Milliseconds after unfreezing during which the vehicle is watched for being ejected.
    -- If it moves more than `ejectDistance` in that window, it is put back and left frozen.
    --
    -- The last line of defence. It catches every case the probe did not predict.
    ejectWatchMs = 1500,
    ejectDistance = 2.0,

    -- Metres per second below which a restored vehicle counts as at rest, for the purposes
    -- of re-freezing and of deciding whether it has settled.
    restSpeed = 0.15,
}

-- ===========================================================================================
-- 8. STREAMING
--
-- HOW MANY VEHICLES EXIST AT ONCE. Nothing is spawned until somebody is near it, and
-- everything is despawned when nobody is. A database with five thousand vehicles and one
-- player online has perhaps thirty entities in the world.
--
-- This is the difference between this resource and a script that spawns everything at boot.
-- ===========================================================================================

Config.Streaming = {
    -- Metres. A persisted vehicle within this distance of any player is created.
    --
    -- 250 is comfortably beyond the distance a vehicle becomes visible, so a player never
    -- sees one appear. Raising it costs entities; lowering it risks a pop-in on a fast
    -- vehicle.
    spawnRadius = 250.0,

    -- Metres. A created vehicle further than this from every player is removed.
    --
    -- MUST be larger than `spawnRadius`. The gap is hysteresis: a player standing exactly on
    -- the boundary would otherwise spawn and despawn the same vehicle several times a
    -- second. 100 metres of gap is roughly three seconds in a fast car.
    despawnRadius = 350.0,

    -- Per-class spawn radius override, for the classes in
    -- `Config.Persistence.lowPriorityClasses` and any other class you name here.
    --
    -- An aircraft at an airfield does not need to exist when you are 250 metres away, and
    -- there are usually a lot of them in one place.
    classRadius = {
        [14] = 150.0, -- Boats
        [15] = 150.0, -- Helicopters
        [16] = 200.0, -- Planes
    },

    -- Milliseconds between streaming passes. Each pass compares the persisted set against
    -- the online players and decides what to create and what to remove.
    --
    -- 1000 is four times finer than it needs to be at walking pace and about right at
    -- 200 km/h. The pass itself is a grid lookup per player, not a scan of the table.
    interval = 1000,

    -- Maximum vehicles created per pass, across the whole server.
    --
    -- The cap that stops a player fast-travelling into a dense area and creating two hundred
    -- entities in one frame. They arrive over the next few passes instead, nearest first.
    spawnsPerPass = 6,

    -- Maximum vehicles removed per pass. Removal is cheaper than creation, so this is
    -- higher.
    despawnsPerPass = 20,

    -- Metres. The spatial grid cell size.
    --
    -- Should be a little under `spawnRadius` so that a query looks at a 3x3 block of cells.
    -- Smaller cells mean more cells to visit; larger cells mean more vehicles per cell to
    -- distance-check. 200 is measured to be the flat part of that curve for a map this size.
    cellSize = 200,

    -- Hard ceiling on vehicles this resource has in the world at once, server-wide.
    --
    -- A safety valve, not a tuning knob. If you are hitting it, `spawnRadius` is too large
    -- for your population density. When it is reached, the furthest vehicles are removed to
    -- make room for nearer ones.
    maximumEntities = 400,

    -- Ceiling per player. 0 means no per-player ceiling.
    maximumPerPlayer = 60,

    -- Order candidates by distance before spawning them.
    --
    -- Costs a sort per pass over the candidate list, which is small. Buys the property that
    -- the car you are walking towards appears before the one behind the building.
    nearestFirst = true,

    -- Only stream vehicles whose saved routing bucket matches the player's.
    --
    -- Leave true. False means an instanced apartment full of vehicles streams into the main
    -- world, which is exactly the bug this setting exists to prevent.
    matchRoutingBucket = true,

    -- Seconds between reconciliation sweeps.
    --
    -- The sweep deletes vehicles in the world that carry one of our ids and are not the entity
    -- we have registered for that id: orphans nothing else will ever collect, and duplicate
    -- copies of a vehicle we already have.
    --
    -- It exists because `entity.orphanMode` below tells the engine NOT to collect an entity
    -- nobody is near, which is correct and which means anything we lose track of is ours to
    -- find again. 30 seconds is cheap - one pass over the server's vehicle list - and is the
    -- difference between one stray vehicle and a car park full of them.
    --
    -- 0 disables it. Do not, unless orphanMode is also off.
    --
    -- 15 rather than 30 since 1.0.2: it is the net that catches anything the creation path
    -- still manages to lose, and a stray vehicle is much more visible than the cost of
    -- looking for one.
    reconcileInterval = 15,

    -- Server-side entity settings, applied to every vehicle we create.
    entity = {
        -- Keep the entity alive when no player is near it, rather than letting the engine
        -- collect it.
        --
        -- We decide when a vehicle goes away, not the engine. Without this the engine
        -- deletes it out from under us the moment the last player walks off, and the next
        -- streaming pass creates it again: a spawn-delete loop at the radius boundary.
        --
        -- Degrades silently on a server build without `SetEntityOrphanMode`.
        orphanMode = true,

        -- Metres. The distance at which clients stop being told about the entity.
        --
        -- Matched to `despawnRadius` so the network culling boundary and our own boundary
        -- agree. Set to 0 to leave the server's default culling alone.
        cullingRadius = 350.0,
    },
}

-- ===========================================================================================
-- 9. LIFECYCLE
--
-- WHEN A VEHICLE STOPS BEING KEPT. Every timer here counts real time, including time the
-- server was offline, computed from a stored timestamp rather than from a tick counter.
-- ===========================================================================================

Config.Lifecycle = {
    -- Hours after which an untouched vehicle is removed. 0 disables expiry for that kind.
    --
    -- "Untouched" means nobody entered it, drove it, damaged it or ran a command on it.
    -- Merely being near it does not count, or nothing near a busy street would ever expire.
    expiry = {
        owned = 0,        -- framework-owned vehicles. 0: never expire, they belong to somebody
        job = 168,        -- job and gang vehicles: one week
        rental = 72,      -- rentals: three days. Normally reached long after Section 9b
        claimed = 336,    -- explicitly parked with /vpark: two weeks
        unowned = 48,     -- a car somebody drove and abandoned: two days
        ambient = 12,     -- adopted ambient vehicles, if you enabled them
        wrecked = 6,      -- engine destroyed. Cleared faster than anything else
    },

    -- What happens at expiry.
    --
    --   'delete'   Removed. Recoverable from the trash for `Config.Database
    --              .trashRetentionDays`.
    --   'impound'  Handed to the framework as impounded, so the player can retrieve it from
    --              the impound lot. Only meaningful for owned vehicles; anything else falls
    --              back to 'delete'.
    --   'garage'   Marked as stored in the owner's default garage. Same caveat.
    onExpiry = 'impound',

    -- Minutes between lifecycle sweeps. This is a single indexed query, not a scan.
    sweepInterval = 30,

    -- What to do when `Config.Persistence.maximumVehicles` or `maximumPerCharacter` is hit.
    --
    --   'oldest'   Evict the least recently touched. Predictable, and it is what a player
    --              expects: the car you have not looked at in a fortnight is the one that
    --              goes.
    --   'refuse'   Do not persist the new vehicle. The player is told why.
    eviction = 'oldest',

    -- Never evict or expire a vehicle a player is currently inside, or one within this many
    -- metres of an online player. Belt and braces: it should be impossible for either to be
    -- true of an expired vehicle, and it costs one distance check to be certain.
    protectRadius = 60.0,

    -- Remove a vehicle from persistence when another resource deletes its entity.
    --
    -- This is how garage integration works without a single hook into a garage script: a
    -- garage stores a car by deleting the entity, we notice the entity went away in a way we
    -- did not ask for, and we stop tracking it. See Section 18 for the full mechanism and
    -- its one caveat.
    forgetOnExternalDelete = true,

    -- Seconds to wait after an external deletion before acting on it.
    --
    -- Some resources delete and immediately recreate a vehicle - a repair, a colour change,
    -- a re-spawn into a garage bay. Acting instantly would forget a vehicle that is about to
    -- come back. Five seconds covers every case measured.
    externalDeleteGrace = 5,
}

-- ===========================================================================================
-- 9c. CLEANUP BY USE
--
-- Sending a car that nobody drives any more back to its garage.
--
-- -------------------------------------------------------------------------------------------
-- WHY THIS IS NOT THE SAME AS SECTION 9
-- -------------------------------------------------------------------------------------------
--
-- Section 9's expiry counts from `touched_at`, which moves whenever ANYTHING happens to a
-- vehicle: a save, a repair, a nudge from a passing car, an admin looking at it. That is the
-- right clock for "is this abandoned".
--
-- It is the wrong clock for "does anybody still drive this". A car parked outside its owner's
-- house is touched constantly - it is near players, it gets saved, traffic brushes past it -
-- and has not been driven since March.
--
-- So this section counts from `last_used_at`, which moves ONLY when a person gets into the
-- vehicle. Nothing else touches it. A car that nobody has sat in for a fortnight is a car
-- nobody wants in the street, whatever else has been happening around it.
--
-- -------------------------------------------------------------------------------------------
-- IT SENDS THEM HOME, IT DOES NOT DELETE THEM
-- -------------------------------------------------------------------------------------------
--
-- The whole point is to tidy the map without costing anybody a car. An owned vehicle goes back
-- to a garage - the one it came out of, where we know it, or the one named below. The player
-- opens their garage and it is there.
--
-- A vehicle with no owner has no garage to go to, and `unowned` below decides what happens to
-- those. It is 'delete' by default because an abandoned stolen car is litter, and it is a
-- separate setting precisely so you can disagree.
--
-- -------------------------------------------------------------------------------------------
-- IT WILL NOT CLEAR YOUR MAP IN ONE GO
-- -------------------------------------------------------------------------------------------
--
-- `maximumPerSweep` caps how many go per pass. Switching this on for the first time on a
-- server with two years of accumulated vehicles would otherwise remove several thousand cars
-- in one tick, and every one of their owners would notice at once. It trickles instead.
--
-- Run `/vparkadmin cleanup preview` first. It lists exactly what WOULD go and changes nothing.
-- ===========================================================================================

Config.Cleanup = {
    enabled = true,

    -- Days since anybody last SAT IN the vehicle, per ownership kind. 0 exempts that kind.
    --
    -- These are deliberately long. This is a tidying pass, not a lifetime: a player who goes
    -- on holiday for a fortnight should not come back to an empty driveway.
    idleDays = {
        owned = 15,      -- the number you asked for
        job = 7,
        rental = 3,
        claimed = 30,    -- somebody deliberately parked it there. Give it the longest.
        unowned = 5,
        ambient = 2,
    },

    -- Per-class overrides, in days, for kinds that are otherwise covered above.
    --
    -- An aircraft parked at an airfield is not in anybody's way and can sit for a season; a
    -- van blocking a loading bay is in the way from day one.
    idleDaysByClass = {
        -- [15] = 60,   -- Helicopters
        -- [16] = 60,   -- Planes
        -- [14] = 60,   -- Boats
    },

    -- Where an owned vehicle goes.
    --
    --   'lastGarage'   The garage it was last taken out of, when we know it, falling back to
    --                  `fallbackGarage`. THE DEFAULT, and what a player expects: the car
    --                  goes back where they got it.
    --   'configured'   Always `fallbackGarage`, whatever the vehicle's history.
    --   'nearest'      The garage nearest to where the vehicle is standing. Reads the garage
    --                  list from your garage resource; falls back to `fallbackGarage` when
    --                  that list could not be read.
    destination = 'lastGarage',

    -- The garage id used when the above cannot produce one.
    --
    -- It must be an id YOUR garage resource knows. `/vparkadmin garages` prints the list it
    -- was able to read from whichever garage resource you run, which is the fastest way to
    -- find the right string.
    fallbackGarage = 'motelgarage',

    -- What happens to a vehicle with no owner, which has no garage to go to.
    --   'delete' | 'keep'
    unowned = 'delete',

    -- Most vehicles moved per sweep. The trickle that stops a first run emptying the map.
    maximumPerSweep = 25,

    -- Minutes between cleanup sweeps. Long, because the resolution needed for a 15-day timer
    -- is nothing like the resolution needed for a 45-minute one.
    interval = 60,

    -- Never clean a vehicle that is currently in the world with a player near it, or one
    -- somebody is sitting in. Belt and braces on top of `Config.Lifecycle.protectRadius`.
    protectInUse = true,

    -- Never clean a vehicle inside one of these zones by name, matching `Config.Zones[].name`.
    --
    -- For the case of a server that has a designated long-stay car park, or a player housing
    -- area where cars are meant to sit.
    exemptZones = {
        -- 'Motel car park',
    },

    -- Never clean a vehicle whose label was set with `/vparkname`.
    --
    -- Naming a car is a deliberate act, and treating it as "this one matters, leave it" is
    -- both intuitive and free.
    exemptNamed = true,

    -- Tell the owner, on their next login, which vehicles were sent home and where to.
    notifyOwner = true,

    -- Warn the owner this many days before a vehicle is due, on login. 0 disables.
    warnBeforeDays = 2,

    -- Write a line per moved vehicle to the console and to the audit table.
    --
    -- Leave it on for the first few weeks. The single most useful thing when somebody asks
    -- "where did my car go" is a log line that says exactly which garage it went to.
    verbose = true,
}

-- ===========================================================================================
-- 9b. SEMI-PERSISTENCE
--
-- A vehicle that survives a restart but not its owner going home.
--
-- -------------------------------------------------------------------------------------------
-- WHAT PROBLEM THIS SOLVES
-- -------------------------------------------------------------------------------------------
--
-- A job vehicle and a rental are not the player's property and are not scenery. A police
-- cruiser parked outside Mission Row should still be there after a restart, because the
-- officer is still on shift and the restart is not part of the fiction. The same cruiser
-- should NOT still be there tomorrow morning because somebody logged off in it at 3am.
--
-- Full persistence gets the first half right and the second half wrong. No persistence gets
-- it the other way round. Semi-persistence is the setting that gets both: the vehicle is tied
-- to its owner's PRESENCE rather than to the clock.
--
-- -------------------------------------------------------------------------------------------
-- HOW THE COUNTDOWN WORKS, AND WHY IT IS NOT A WALL CLOCK
-- -------------------------------------------------------------------------------------------
--
-- The obvious implementation is "delete it 45 minutes after the owner's last-seen timestamp".
-- It is wrong, and it is wrong in the exact case this feature exists for: a server that
-- restarts at 06:00 and comes back at 06:03 has, by that measure, had every offline player
-- absent all night. Every job vehicle would be gone at boot, which is precisely the "survives
-- a reboot" half of the requirement broken.
--
-- So the countdown accumulates only while THE SERVER IS RUNNING and THE OWNER IS NOT. Each
-- lifecycle sweep adds its own elapsed time to the vehicle's offline counter, and a
-- three-minute restart costs three minutes of nobody's grace period. The counter resets to
-- zero the moment the owner connects.
--
-- Set `pauseWhileServerOffline = false` to get the wall-clock behaviour instead, which is
-- what you want if your server restarts rarely and you would rather an overnight outage
-- clear the map.
-- ===========================================================================================

Config.SemiPersistence = {
    -- Master switch. Off means every ownership type follows Section 9 only.
    enabled = true,

    -- Per ownership type. Any type not listed here is fully persistent and governed by
    -- Section 9 alone.
    --
    -- The keys are the same ownership types used everywhere else: 'owned', 'job', 'rental',
    -- 'claimed', 'unowned', 'ambient'. Listing 'owned' here is possible and is almost
    -- certainly a mistake: a player's own car disappearing because they logged off is the
    -- one behaviour nobody wants.
    types = {
        job = {
            enabled = true,

            -- Minutes the owner may be offline before the vehicle is removed.
            -- The number you asked for, and the number to change.
            graceMinutes = 45,

            -- Do not count time the server itself was down. See the header.
            pauseWhileServerOffline = true,

            -- Also remove it when the owner is online but no longer holds the job the
            -- vehicle belongs to. An officer who clocks off as a mechanic does not keep the
            -- cruiser.
            --
            --   'ignore'   Leave it. The grace period is the only rule.
            --   'remove'   Remove it as soon as the job no longer matches.
            --   'grace'    Start the grace countdown, as though they had gone offline.
            onJobChange = 'grace',

            -- Also start the countdown when the owner goes off duty, where the framework has
            -- a duty concept. qb-core and qbx_core do; ESX and ox_core do not, and this is
            -- ignored there.
            onOffDuty = false,

            -- What happens at the end of the countdown.
            --   'delete'   Removed, recoverable from the trash.
            --   'garage'   Handed back to the framework's garage, where it applies.
            onExpiry = 'delete',

            -- Keep the vehicle regardless while any player is inside it, or within
            -- `Config.Lifecycle.protectRadius`. A cruiser another officer is driving does
            -- not vanish because the officer who signed it out logged off.
            protectWhenInUse = true,
        },

        rental = {
            enabled = true,
            graceMinutes = 45,
            pauseWhileServerOffline = true,
            onJobChange = 'ignore',
            onOffDuty = false,
            onExpiry = 'delete',
            protectWhenInUse = true,

            -- A rental may also carry a hard end time, set by whichever resource rented it
            -- out through `exports['v-park']:SetRental(id, seconds)`. When it does, the
            -- vehicle goes at that time OR at the end of the grace period, whichever comes
            -- first. Nothing here can extend a rental past what the rental script sold.
            respectHardExpiry = true,
        },
    },

    -- Warn the owner this many minutes before the countdown ends, if they are online.
    --
    -- They will not be, most of the time - that is the point of the feature - but a player
    -- who alt-tabbed and came back deserves to be told the cruiser is about to go rather
    -- than to walk outside and find it gone.
    warnBeforeMinutes = 10,

    -- Seconds between semi-persistence checks. Independent of the main lifecycle sweep,
    -- because 45 minutes of resolution needs a much finer tick than 30 minutes of sweep.
    --
    -- 60 means a vehicle is removed at most a minute after its grace period ends. The check
    -- is a single indexed query against the semi-persistent rows only.
    interval = 60,

    -- Remove semi-persistent vehicles whose owner is offline at BOOT, before the streaming
    -- pass has a chance to put them in the world.
    --
    -- With `pauseWhileServerOffline` on this rarely fires at boot, because no grace has been
    -- spent yet. It is here for the case where a vehicle was already past its grace when the
    -- server went down, which would otherwise be visible for one sweep interval.
    sweepOnBoot = true,
}

-- ===========================================================================================
-- 10. OWNERSHIP
-- ===========================================================================================

Config.Ownership = {
    -- Who may run a command against a vehicle they do not own.
    --
    --   'owner'   Only the owner, and admins.
    --   'keys'    Anybody who holds the keys, per your key resource.
    --   'anyone'  Anybody. Sensible only on a server that trusts its players completely.
    commandScope = 'keys',

    -- Match a restored vehicle to a framework-owned one by plate, and adopt its owner.
    --
    -- This is what makes `mode = 'all'` behave sensibly: a car that is in the framework's
    -- owned-vehicles table is recognised as owned even though it was persisted as a loose
    -- vehicle, and gets the owned expiry rather than the two-day one.
    matchOwnedByPlate = true,

    -- Also try to match on the vehicle id or hash column some frameworks keep, when the
    -- plate has been changed since. Costs one extra indexed lookup per restored vehicle at
    -- boot and nothing afterwards.
    matchOwnedByVehicleId = true,

    -- A Lua pattern that identifies a job vehicle by its plate.
    --
    -- Without it, "is this a job vehicle" is answered by "the framework has no owner row for
    -- it and the driver holds a job", which is right on most servers and costs one indexed
    -- lookup. With it, the answer is exact and free.
    --
    -- Set it if your job spawners use a recognisable plate. `'^LSPD'` and `'^EMS%d'` are the
    -- usual shapes. It is a Lua pattern, not a wildcard: `-` and `%` need escaping.
    jobPlatePattern = nil,

    -- Transfer persistence with the vehicle when the framework's owner changes.
    --
    -- A car sold through a dealership or a player-to-player sale keeps its persisted state
    -- and changes hands, rather than the buyer finding a car that expires in two days.
    followFrameworkOwner = true,

    --[[
        HOLDING THE KEYS COUNTS AS OWNING IT.

        Added in 1.0.2, and it is the other half of making `mode = 'owned'` the default.

        The framework's owned-vehicles table is not the only way a car becomes somebody's.
        `/admincar`, a dealership demo, a job spawner, a player handing a mate the keys, a
        heist vehicle given to the crew - none of those write a row in `player_vehicles`, and
        in a strict reading of 'owned' every one of them is traffic that vanishes on restart.

        That is wrong, and it was reported as exactly that: a car the player had given
        themselves the keys to was not kept, and obviously should have been.

        So the resolution order is now the framework's record first, because it is the
        strongest evidence there is, and the key resource second. A player who holds the keys
        is recorded as the owner with `owner_type = 'owned'` and gets the owned expiry.

        WHAT THIS COSTS. One export call to your key resource per vehicle, at the moment
        somebody gets into one that is not persisted yet. Not per save, not per streaming
        pass. A key resource with no readable server-side answer returns nothing, which is
        treated as "no keys", and the vehicle falls through to the settle timer exactly as it
        did before.

        Turn it off for a strict "only what the framework sold them" reading.
    ]]
    keysGrantOwnership = true,
}

-- ===========================================================================================
-- 11. ZONES
--
-- Places where nothing persists. A vehicle driven into one is dropped from persistence; a
-- vehicle that would be restored into one is not restored.
--
-- Three shapes are supported. Every zone needs a `type` and a `name`; the name is what
-- `/vparkzones` prints and what appears in the audit log.
-- ===========================================================================================

Config.Zones = {
    -- Example: a circle.
    -- {
    --     type = 'circle',
    --     name = 'Pillbox garage',
    --     centre = { x = 215.0, y = -810.0, z = 30.0 },
    --     radius = 40.0,
    --     -- Optional. Without it the zone applies at every height, which is wrong in a
    --     -- multi-storey building and right almost everywhere else.
    --     heightRange = { min = 25.0, max = 40.0 },
    -- },

    -- Example: an axis-aligned box.
    -- {
    --     type = 'box',
    --     name = 'PDM lot',
    --     min = { x = -60.0, y = -1120.0, z = 25.0 },
    --     max = { x = -20.0, y = -1080.0, z = 32.0 },
    -- },

    -- Example: a polygon, for a car park that is not a rectangle. Points are 2D; the
    -- optional heightRange bounds it vertically.
    -- {
    --     type = 'poly',
    --     name = 'Mission Row yard',
    --     points = {
    --         { x = 400.0, y = -1620.0 },
    --         { x = 440.0, y = -1620.0 },
    --         { x = 440.0, y = -1660.0 },
    --         { x = 400.0, y = -1660.0 },
    --     },
    --     heightRange = { min = 24.0, max = 40.0 },
    -- },
}

Config.ZoneOptions = {
    -- Automatically exclude the area around every garage your garage resource knows about.
    --
    -- Reads the garage list from qb-garages, qbx_garages, jg-advancedgarages, cd_garage,
    -- loaf_garage and okokGarage when one of them is installed. It is a read of their config
    -- table, not a hook, and it degrades to doing nothing when the shape is not what we
    -- expect - which is announced at boot rather than assumed.
    --
    -- Turn this off if you WANT cars to persist on the garage forecourt, which some servers
    -- do deliberately.
    autoGarages = true,

    -- Metres around each auto-detected garage point.
    autoGarageRadius = 25.0,

    -- Draw every zone as a marker while `/vparkdebug` is on.
    debugDraw = true,
}

-- ===========================================================================================
-- 12. COMMANDS
--
-- Every command is prefixed `vpark`, so nothing here can collide with another resource's
-- `/park`. Rename any of them; set `false` to remove one entirely.
--
-- `permission` is one of:
--   'everyone'   anybody
--   'owner'      the vehicle's owner, per Section 10
--   'admin'      an ACE permission, or a framework admin group. See Section 13.
-- ===========================================================================================

Config.Commands = {
    -- Player commands
    park       = { name = 'vpark',        permission = 'everyone', enabled = true },
    unpark     = { name = 'vparkforget',  permission = 'owner',    enabled = true },
    list       = { name = 'vparklist',    permission = 'everyone', enabled = true },
    find       = { name = 'vparkfind',    permission = 'owner',    enabled = true },
    info       = { name = 'vparkinfo',    permission = 'everyone', enabled = true },
    lock       = { name = 'vparklock',    permission = 'owner',    enabled = true },
    -- Naming a vehicle also exempts it from the Section 9c idle cleanup, because naming a car
    -- is a deliberate act and "this one matters, leave it" is the obvious reading of it.
    rename     = { name = 'vparkname',    permission = 'owner',    enabled = true },

    -- Staff commands
    admin      = { name = 'vparkadmin',   permission = 'admin',    enabled = true },
    here       = { name = 'vparkhere',    permission = 'admin',    enabled = true },
    -- Quoted because `goto` is a reserved word in Lua 5.4 and a bare key by that name is a
    -- parse error, not a runtime one - the whole file fails to load. Renaming it would have
    -- been the other option; keeping the obvious name and quoting it is the smaller surprise.
    ['goto']   = { name = 'vparkgoto',    permission = 'admin',    enabled = true },
    delete     = { name = 'vparkdelete',  permission = 'admin',    enabled = true },
    restore    = { name = 'vparkrestore', permission = 'admin',    enabled = true },
    owner      = { name = 'vparkowner',   permission = 'admin',    enabled = true },
    purge      = { name = 'vparkpurge',   permission = 'admin',    enabled = true },
    save       = { name = 'vparksave',    permission = 'admin',    enabled = true },
    stats      = { name = 'vparkstats',   permission = 'admin',    enabled = true },
    scan       = { name = 'vparkscan',    permission = 'admin',    enabled = true },
    zones      = { name = 'vparkzones',   permission = 'admin',    enabled = true },
    debug      = { name = 'vparkdebug',   permission = 'admin',    enabled = true },
    probe      = { name = 'vparkprobe',   permission = 'admin',    enabled = true },
    migrate    = { name = 'vparkmigrate', permission = 'admin',    enabled = true },

    -- A console-only command. Never available in game, whatever `permission` says elsewhere.
    -- It is the one that can empty the table.
    wipe       = { name = 'vparkwipe',    permission = 'console',  enabled = true },
}

-- ===========================================================================================
-- 13. PERMISSIONS
-- ===========================================================================================

Config.Permissions = {
    -- The ACE object checked for 'admin' commands. Grant it in server.cfg:
    --
    --     add_ace group.admin vpark.admin allow
    --
    -- ACE is checked FIRST and independently of the framework, so a server owner always has
    -- a way in even when the framework is down.
    ace = 'vpark.admin',

    -- Framework groups that also count as admin, checked when ACE says no.
    -- qb-core and qbx_core permissions, ESX groups, ox_core groups.
    groups = { 'admin', 'god', 'superadmin' },

    -- Also accept a player whose framework job is in this list, at or above the given grade.
    -- Useful for a mechanic faction that needs `/vparkhere` without being server admins.
    jobs = {
        -- mechanic = 3,
    },

    -- Print a line to the console for every refused command.
    -- On by default: a refused admin command is almost always a misconfigured ACE, and
    -- silence makes that take an hour to find.
    logRefusals = true,
}

-- ===========================================================================================
-- 14. NOTIFICATIONS
-- ===========================================================================================

Config.Notify = {
    enabled = true,

    -- Milliseconds. Used by the native fallback and passed to providers that accept it.
    duration = 4000,

    -- Which events notify the player. All of them are informative rather than urgent, so
    -- turning any of them off costs nothing but clarity.
    events = {
        parked = true,          -- "this vehicle will be here after the restart"
        forgotten = true,       -- "this vehicle will not"
        restored = false,       -- "your car was restored". Noisy at peak login.
        expiring = true,        -- "expires in 6 hours"
        expired = true,         -- sent on next login
        impounded = true,
        evicted = true,         -- "your oldest vehicle was dropped to make room"
        refused = true,         -- persistence refused, and why
        adminAction = true,     -- an admin did something to your vehicle
    },

    -- Warn the owner this many hours before a vehicle expires, on their next login.
    -- 0 disables the warning.
    expiryWarningHours = 12,
}

-- ===========================================================================================
-- 15. KEYS
-- ===========================================================================================

Config.Keys = {
    -- Give the owner their keys back when a persisted vehicle is restored.
    --
    -- The single most common complaint about every persistence script: the car came back and
    -- the owner cannot start it. On by default.
    restore = true,

    -- Also give keys to whoever had them when the vehicle was saved, not only to the owner.
    --
    -- Off by default because it means storing a list of identifiers per vehicle, which is
    -- data you may not want to keep, and because a shared key from three restarts ago is
    -- rarely still intended.
    restoreShared = false,

    -- Restore the lock state the vehicle was saved with. Independent of key handling: a
    -- locked car with no keys is a locked car.
    restoreLockState = true,
}

-- ===========================================================================================
-- 16. INVENTORY
-- ===========================================================================================

Config.Inventory = {
    -- Keep trunk and glovebox contents attached across a restart.
    --
    -- On ox_inventory, qb-inventory and qs-inventory this happens by itself, because the
    -- stash is keyed on the plate and we preserve the plate exactly. All this setting does
    -- is REFUSE to change a plate in a way that would orphan a stash, and warn when another
    -- resource does.
    --
    -- Turning it off does not delete anything; it only stops us protecting the link.
    preserveStashes = true,

    -- Refuse a plate change on a persisted vehicle that would orphan its stash, and log it.
    -- The change is refused, not silently applied, so the resource that tried it gets a
    -- truthful answer.
    guardPlateChanges = true,
}

-- ===========================================================================================
-- 17. INTERACTION
--
-- Optional convenience. Everything here is off or minimal by default: the resource's job is
-- persistence, not adding UI to your server.
-- ===========================================================================================

Config.Interaction = {
    -- Add a "park here" option to your target system for the vehicle you are looking at.
    -- Only appears in the modes where parking is a deliberate act: `claimed`, and `owned`
    -- while `Config.Persistence.allowClaimInOwnedMode` is on.
    target = {
        enabled = false,
        label = 'interaction.park',   -- a locale key, or literal text
        icon = 'fa-solid fa-square-parking',
        distance = 2.5,
    },

    -- A key to park the vehicle you are sitting in. `false` disables it.
    -- Control ids: https://docs.fivem.net/docs/game-references/controls/
    key = false,

    -- Blips on your own persisted vehicles.
    blips = {
        enabled = false,
        sprite = 225,
        colour = 3,
        scale = 0.7,
        -- Only blip vehicles within this many metres. 0 blips all of them, which on a
        -- player with twenty cars is twenty blips.
        radius = 0,
    },
}

-- ===========================================================================================
-- 17b. THE ADMIN PANEL
--
-- `/vparkadmin` opens it. Everything it does is also available as a chat command, because a
-- panel that is the only way to do something is a panel you cannot script against - but
-- nobody wants to type an id to teleport to the fourteenth of two hundred vehicles.
--
-- It is the ONLY NUI in this resource, it is only ever open for staff, and it sends nothing
-- and paints nothing while it is closed. A player who never runs the command never loads it.
-- ===========================================================================================

Config.Panel = {
    enabled = true,

    -- Rows per page. The list is paginated server-side: the panel never receives the whole
    -- table, which on a large server is thousands of rows it would have to hold and filter.
    pageSize = 25,

    -- Metres. The default radius for the panel's "near me" filter.
    nearRadius = 150.0,

    -- Which actions the panel offers. Each is still subject to the same permission check the
    -- equivalent command uses, on the server, every time - the panel hiding a button is a
    -- convenience and never the security boundary.
    actions = {
        teleportTo = true,      -- go to the vehicle
        bringHere = true,       -- bring the vehicle to you
        repair = true,          -- full repair: body, engine, tank, tyres, windows, dents
        clean = true,           -- wash it
        refuel = true,
        unlock = true,
        setOwner = true,
        toGarage = true,        -- send it to a garage. See `garages` below
        impound = true,
        delete = true,
        restore = true,         -- bring one back from the trash
        rename = true,          -- set the optional label
    },

    -- The garages `toGarage` offers.
    --
    -- 'auto' reads the list from whichever garage resource is installed - Quasar's
    -- qs-advancedgarages, qb-garages, qbx_garages, jg-advancedgarages, cd_garage, loaf_garage
    -- and okokGarage are all understood - so the dropdown shows YOUR garages with YOUR names
    -- and nothing has to be typed in here.
    --
    -- Replace it with a list to pin the choices, which is what you want if your garage
    -- resource is not one of those or if staff should only be able to use some of them:
    --
    --     garages = {
    --         { id = 'motelgarage', label = 'Motel' },
    --         { id = 'beeker',      label = "Beeker's Garage" },
    --     },
    garages = 'auto',

    -- Refresh the open panel every this many seconds, so a second admin's changes appear
    -- without anybody pressing anything. 0 disables it and the panel only refreshes on
    -- demand.
    --
    -- The refresh is the same paginated query as opening it. Cheap, but it is one query per
    -- open panel per interval, so it is not free on a server with ten staff online.
    refreshSeconds = 15,

    -- The visual theme. 'sandy' is the shipped one: Blaine County signage - sand, rust,
    -- bleached bone and hard edges, no rounded corners anywhere.
    --
    -- A theme is one CSS file in `html/css/`. Adding one is documented in README.md.
    theme = 'sandy',
}

-- ===========================================================================================
-- 18. GARAGE INTEGRATION
--
-- HOW IT WORKS, because it is worth understanding before you trust it.
--
-- A garage stores a vehicle by deleting its entity and writing a row in its own table. We do
-- not hook that. Instead:
--
--   1. Every vehicle we restore carries a `vpark:id` statebag.
--   2. When an entity carrying one is removed and we did not remove it, we treat that as an
--      external deletion and stop tracking the vehicle, after `Config.Lifecycle
--      .externalDeleteGrace` seconds.
--   3. On load, a vehicle whose plate is marked stored in the framework's owned-vehicles
--      table is skipped.
--
-- THE CAVEAT: step 2 cannot distinguish a garage storing a car from a resource deleting one
-- for any other reason. That is what the grace period is for, and what `exports` below are
-- for - a garage that calls `Store` explicitly gets an exact answer rather than an inferred
-- one. The FAQ in README.md has the two-line snippet for the common garages.
-- ===========================================================================================

Config.Garages = {
    -- Read the framework's owned-vehicles table on load and skip anything marked as stored
    -- or impounded.
    --
    -- Column and value per framework are detected; `state = 1` is out for qb-core,
    -- `stored = 0` for ESX, `stored` for ox_core.
    respectStoredFlag = true,

    -- When a persisted vehicle is restored, also mark it as out of the garage in the
    -- framework's table, so the garage UI agrees with the world.
    --
    -- Without this, a player can have a car sitting in the street AND listed as in their
    -- garage, and take it out twice. That is a duplication bug, and this setting is the one
    -- that prevents it. Leave it on.
    markAsOut = true,

    -- The reverse: when a vehicle is removed from persistence for any reason other than a
    -- garage storing it, mark it as stored so it is not lost to the player.
    --
    -- This is what makes expiry safe for owned vehicles: the car is not deleted from the
    -- player's account, it goes back in the garage.
    returnToGarageOnRemoval = true,
}

-- ===========================================================================================
-- 19. MIGRATION FROM ADVANCED PARKING
--
-- Read MIGRATION.md before running this. The short version:
--
--   /vparkmigrate scan     find the table and print what was found. Changes nothing.
--   /vparkmigrate dry      map every row and print what WOULD be written. Changes nothing.
--   /vparkmigrate run      do it. Backs up first.
--   /vparkmigrate rollback undo the last run.
--
-- The source table is only ever READ. Nothing in this resource writes to it, drops it, or
-- renames it - so your old script keeps working, and you can run both while you decide.
-- ===========================================================================================

Config.Migration = {
    -- Table names to look for, in order. The first one that exists is used.
    --
    -- Advanced Parking creates its table itself and does not publish the schema, and it has
    -- changed across its major versions. So the migration does not assume one: it reads
    -- INFORMATION_SCHEMA, maps the columns it recognises, and prints the ones it does not.
    -- `columnMap` below is the escape hatch for a schema we have not seen.
    tables = {
        'advancedparking',
        'AdvancedParking',
        'advanced_parking',
        'advancedparking_vehicles',
        'parked_vehicles',
        'kimi_parking',
    },

    -- Explicit column mapping, when detection gets it wrong or your table is not one of the
    -- above. Left side is ours, right side is the column name in the source table.
    --
    -- Anything left nil is detected. Set only what you need to correct.
    columnMap = {
        -- id          = 'id',
        -- plate       = 'plate',
        -- model       = 'model',
        -- owner       = 'owner',
        -- position    = 'position',    -- a JSON blob, or an "x,y,z" string
        -- rotation    = 'rotation',
        -- properties  = 'properties',  -- the modifications blob
        -- fuel        = 'fuel',
        -- bodyHealth  = 'bodyHealth',
        -- engineHealth= 'engineHealth',
        -- created     = 'created',
        -- updated     = 'updated',
    },

    -- Rows read and written per batch. The migration yields between batches so a large table
    -- does not block the server thread.
    batchSize = 250,

    -- Copy the source table into `<prefix>migration_backup` before writing anything.
    --
    -- Leave true. It is what `rollback` reads, and it is the difference between a mistake
    -- being an inconvenience and being a restore-from-backup evening.
    backup = true,

    -- What to do with a row whose model is not a valid vehicle in this server's game build.
    --
    --   'skip'    Do not migrate it, and list it in the report. The right answer: the model
    --             is from an add-on car that has since been removed, and restoring it would
    --             be a vehicle nobody can see.
    --   'import'  Migrate it anyway. It will fail to spawn until the add-on comes back,
    --             which is a legitimate thing to want during a temporary removal.
    invalidModels = 'skip',

    -- What to do with a row whose owner does not match any character on this server.
    --
    --   'orphan'  Migrate it with no owner. It gets the `unowned` expiry.
    --   'skip'    Do not migrate it.
    --   'keep'    Migrate it and keep the raw owner string, so it re-matches if that
    --             character comes back. The default, and the least destructive.
    unknownOwners = 'keep',

    -- Refuse to run when our own table already has rows, unless `/vparkmigrate run force` is
    -- used.
    --
    -- Stops the common accident of running the migration twice and doubling every vehicle.
    -- The duplicate check is by plate and position regardless, so a forced second run is
    -- idempotent - this is belt and braces.
    refuseWhenPopulated = true,
}

-- ===========================================================================================
-- 20. PERFORMANCE
--
-- The knobs that trade responsiveness for cost. The defaults are measured on a 64-slot
-- server with roughly 3000 persisted vehicles; every number below is the one that was flat
-- on that curve.
--
-- `/vparkstats` prints what the resource is actually costing you right now, which beats
-- every number written here.
-- ===========================================================================================

Config.Performance = {
    -- Milliseconds of server time the streaming pass may take before it yields and finishes
    -- on the next tick. A budget, not a target: the pass normally costs a fraction of it.
    streamBudgetMs = 3,

    -- The same for the save sweep.
    saveBudgetMs = 4,

    -- Client tick intervals, in milliseconds, by how far the nearest tracked vehicle is.
    --
    -- The client has no per-frame loop. It has one timer whose interval is chosen from this
    -- table, so a player in an empty field costs a wakeup every two seconds and a player in
    -- a full car park costs one every 200 ms.
    clientTiers = {
        { distance = 30.0,  interval = 200 },
        { distance = 100.0, interval = 500 },
        { distance = 250.0, interval = 1000 },
        { distance = math.huge, interval = 2000 },
    },

    -- Milliseconds between a client's reports of the vehicle it is currently in.
    --
    -- The client tells the server "I am in vehicle N and it is at X" so the server does not
    -- have to poll entity positions. Server-created entities have server-readable
    -- coordinates, so this is only needed for vehicles the server did not create.
    reportInterval = 5000,

    -- Cache decoded vehicle properties on the client, keyed by vehicle id and a version
    -- counter, so a vehicle that streams in and out repeatedly is decoded once.
    --
    -- Bounded: the cache holds at most this many entries and evicts the least recently used.
    propertyCache = 200,
}

-- ===========================================================================================
-- 21. API
--
-- Exports are always registered. This section only decides who may CHANGE things through
-- them; reading is never gated.
--
-- The full list is in API.md.
-- ===========================================================================================

Config.Api = {
    -- Allow other resources to add, remove and modify persisted vehicles through exports.
    --
    -- Turning this off makes the API read-only, which is a reasonable posture on a server
    -- running scripts it does not fully trust.
    allowWrites = true,

    -- Resources that may call the write exports. An empty list means "any resource".
    --
    -- Named resources only; there is no wildcard. FiveM tells us the calling resource
    -- truthfully, so this is a real boundary and not a courtesy.
    allowedResources = {},

    -- Fire `vpark:server:vehicleRestored`, `vpark:server:vehicleSaved` and the rest as
    -- server events for other resources to listen to.
    events = true,
}
