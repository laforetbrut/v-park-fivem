fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'v-park'
author 'vyrriox'
description 'Vehicle persistence for FiveM on qb-core, qbx_core, ESX and ox_core: vehicles stay where they were left across restarts, are restored to the exact spot even in tight spaces, and are streamed in only when somebody is near. Bodywork deformation is stored and synchronised, job and rental vehicles can be semi-persistent, and there is a migration from Advanced Parking.'
version '1.0.6'

-- No hard dependency, on purpose. oxmysql, every framework, every fuel resource, every key
-- resource, every garage and every notification system are detected at runtime and all
-- optional. See config.lua -> Config.Compat, bridge/client/compat.lua and
-- bridge/server/framework.lua.
--
-- OneSync IS required, and that is checked at boot rather than assumed: server-created
-- entities do not exist without it, and a persistence resource that quietly keeps a
-- per-client fiction is worse than one that refuses to start. Config.General.requireOneSync.
--
-- Without a database the resource still runs: vehicles live in memory for the session and
-- that is announced, loudly, once, at boot. It is a development configuration, not a
-- supported production one.

shared_scripts {
    -- The shared core FIRST: it defines `Park` (maths, time, hashing, logging, the grid) and
    -- the locale helper that every file below is written against.
    'bridge/shared/park.lua',
    'bridge/shared/locale.lua',

    -- English first: it is the fallback for any key missing from another locale, so it is the
    -- base table the others are read against.
    'locales/en.lua',
    'locales/fr.lua',

    'config.lua',

    -- The vehicle class table. Before zones and rules, both of which resolve class names.
    'shared/classes.lua',

    -- Where nothing persists. Shared because the server refuses to save inside one and the
    -- client draws them for the debug overlay - and two implementations of point-in-polygon
    -- is two answers on the edge, which is where every zone bug lives.
    'shared/zones.lua',

    -- What a stored vehicle IS: the property groups, their config gates, and the order they
    -- are applied in. Read its header before changing that order.
    'shared/schema.lua',

    -- Whether a vehicle may persist at all. After classes and zones, which it asks.
    'shared/rules.lua',
}

client_scripts {
    -- Runtime detection of everything optional. FIRST, because every client file below asks
    -- it what is installed.
    'bridge/client/compat.lua',

    -- Bodywork deformation. Before properties.lua, which captures and applies through it.
    'client/deformation.lua',

    -- Reading everything off a vehicle and putting it all back.
    'client/properties.lua',

    -- The tight-space placement engine. The headline file; read its header.
    'client/placement.lua',

    -- What the client does with a vehicle the server created, and the one timer that wakes
    -- and re-freezes them. After properties and placement, both of which it drives.
    'client/stream.lua',

    -- Noticing which vehicles matter. After stream.lua, whose index it consults before
    -- reporting anything.
    'client/track.lua',

    -- The admin panel's browser bridge. Independent of everything above it.
    'client/panel.lua',

    -- The client half of the commands. LAST: it answers questions on behalf of every file
    -- above it.
    'client/commands.lua',
}

server_scripts {
    -- The framework adapter. First, because ownership resolution needs it and because its
    -- boot sequence is the second step in runtime.lua.
    'bridge/server/framework.lua',

    -- The only file that talks to MySQL.
    'server/database.lua',

    -- Discord. EARLY, so that an error raised by anything below it is reported. It installs
    -- itself as the logger's observer, which is why no other file mentions Discord.
    'server/webhook.lua',

    -- The in-memory index and the spatial grid.
    'server/store.lua',

    -- Boot order, and the flag every timer below waits on.
    'server/runtime.lua',

    -- Who a vehicle belongs to. Before spawn.lua, which asks it on every restore.
    'server/ownership.lua',

    -- What exists in the world right now.
    'server/spawn.lua',

    -- Turning a vehicle into a row, as rarely as possible.
    'server/persist.lua',

    -- Expiry, semi-persistence, cleanup by use, eviction.
    'server/lifecycle.lua',

    -- Everything that can be DONE to a vehicle. After lifecycle.lua, whose removal it calls.
    'server/actions.lua',

    -- The panel's data. After actions.lua, which it dispatches into.
    'server/panel.lua',

    -- The commands. After everything they call.
    'server/commands.lua',

    -- The Advanced Parking migration. Registers its own command.
    'server/migrate.lua',

    -- The exports. LAST, so that everything they reach exists by the time another resource
    -- can call one.
    'server/api.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/css/reset.css',
    'html/css/panel.css',
    'html/css/sandy.css',
    'html/js/app.js',

    -- Shipped for operators who prefer to import a schema by hand. The tables are created on
    -- first start when they are missing, so importing it is optional.
    'sql/v_park.sql',
}
