--[[
    bridge/shared/park.lua

    The shared core. Everything below this file is written against `Park`, and nothing in it
    knows what a vehicle is: it is maths, time, table and string work, plus the two or three
    FiveM facts that every other file would otherwise re-discover badly.

    Loaded FIRST on both sides. `config.lua`, the locales and every client and server file
    depend on it existing.

    -------------------------------------------------------------------------------------------
    THE FOUR THINGS IN HERE THAT ARE NOT OBVIOUS
    -------------------------------------------------------------------------------------------

    1. `Park.callable(v)` and never `type(v) == 'function'`. A function that has crossed a
       FiveM resource boundary arrives as a TABLE carrying a `__call` metamethod. A type test
       against it rejects an object that calls perfectly well, which is how a resource can
       detect a framework, announce it, and then silently fail to resolve a single player.

    2. `Park.now()` returns 0 for "the clock is not known yet". `os.time` is server-only, and
       the client's `GetCloudTimeAsInt()` answers 0 for the first frames after a join. Every
       caller treats 0 as unknown and refuses to charge time against it, rather than treating
       it as 1970 and expiring everything on the server.

    3. `Park.hash(value)` is FNV-1a over a canonical serialisation. It is the whole of the
       delta-save design: a vehicle is written to the database when its hash changed, and not
       otherwise. It must therefore be STABLE - the same table must hash the same on two
       different runs - which is why keys are sorted and floats are quantised before hashing.

    4. Angles are stored and compared as quaternions nowhere, and as a full rotation vector
       everywhere. A heading alone loses pitch and roll, and a car parked on the Vinewood
       hills or in a multi-storey ramp has both. `Park.rotationsDiffer` compares the three.
]]

Park = {}

Park.resource = GetCurrentResourceName()

-- ---------------------------------------------------------------------------------------
-- Types and truth
-- ---------------------------------------------------------------------------------------

--[[
    Is `value` something we can call?

    NOT `type(value) == 'function'`. See the header. Every call into another resource's code
    is gated on this and on nothing else.
]]
function Park.callable(value)
    local kind = type(value)
    if kind == 'function' then return true end
    if kind ~= 'table' then return false end

    local meta = getmetatable(value)
    if not meta then return false end

    local call = rawget(meta, '__call')
    return type(call) == 'function' or type(call) == 'table'
end

--[[
    Call `fn` with `...` and return its result, or nil if it was not callable or it threw.

    Every call that leaves this resource goes through here or through a local copy of it. A
    framework that changed a signature between two versions must degrade to nil, never take
    the resource down with it.
]]
function Park.try(fn, ...)
    if not Park.callable(fn) then return nil end
    local ok, result = pcall(fn, ...)
    if not ok then return nil end
    return result
end

--[[
    Read `object[name]` without raising.

    ox_core's "core object" IS its exports table, and indexing an export that does not exist
    RAISES in FiveM rather than returning nil. So `core.Functions` - written for qb-core's
    shape - is a hard error on an ox_core server unless it goes through here.
]]
function Park.field(object, name)
    if type(object) ~= 'table' then return nil end
    local ok, value = pcall(function() return object[name] end)
    if not ok then return nil end
    return value
end

--[[
    Is a resource present and running?

    `starting` counts. A resource that is mid-boot when we look will be up by the time the
    first player connects, and treating it as absent means detecting no framework at all on a
    server whose start order happens to put us early.
]]
function Park.started(resource)
    if type(resource) ~= 'string' or resource == '' then return false end
    local state = GetResourceState(resource)
    return state == 'started' or state == 'starting'
end

-- ---------------------------------------------------------------------------------------
-- Numbers
-- ---------------------------------------------------------------------------------------

function Park.clamp(value, low, high)
    if type(value) ~= 'number' then return low end
    if value ~= value then return low end -- NaN, which compares false against everything
    if value < low then return low end
    if value > high then return high end
    return value
end

function Park.round(value, places)
    if type(value) ~= 'number' or value ~= value then return 0 end
    local factor = 10 ^ (places or 0)
    -- math.floor over string.format: format rounds half-to-even on some builds and
    -- half-away-from-zero on others, and a hash that depends on the build is not a hash.
    if value >= 0 then
        return math.floor(value * factor + 0.5) / factor
    end
    return -math.floor(-value * factor + 0.5) / factor
end

--[[
    A number that survives a JSON round trip and a database column without changing.

    Coordinates are stored to 3 decimals (a millimetre) and angles to 2 (a hundredth of a
    degree). Anything finer is below what the engine reproduces on respawn anyway, and it
    makes the delta hash flap on floating point noise: a parked car whose Z oscillates in the
    seventh decimal would otherwise be written to the database every single save tick.
]]
function Park.coord(value) return Park.round(value, 3) end
function Park.angle(value) return Park.round(value, 2) end

function Park.isFinite(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

-- ---------------------------------------------------------------------------------------
-- Vectors
--
-- Stored as plain { x, y, z } tables, never as vector3. A vector3 does not survive
-- json.encode on every runtime, and the database column is JSON.
-- ---------------------------------------------------------------------------------------

function Park.vec(x, y, z)
    return { x = Park.coord(x or 0.0), y = Park.coord(y or 0.0), z = Park.coord(z or 0.0) }
end

function Park.rot(x, y, z)
    return { x = Park.angle(x or 0.0), y = Park.angle(y or 0.0), z = Park.angle(z or 0.0) }
end

--[[
    Read a position out of anything: a vector3, a { x, y, z } table, a { [1], [2], [3] }
    array, or a "x,y,z" string. The migration reads other people's columns, and every one of
    those four shapes is in the wild.
]]
function Park.toVec(value)
    if value == nil then return nil end

    local kind = type(value)

    if kind == 'vector3' or kind == 'vector4' then
        return Park.vec(value.x, value.y, value.z)
    end

    if kind == 'string' then
        local x, y, z = value:match('^%s*%[?%s*(-?[%d%.]+)%s*,%s*(-?[%d%.]+)%s*,%s*(-?[%d%.]+)')
        if x then return Park.vec(tonumber(x), tonumber(y), tonumber(z)) end
        return nil
    end

    if kind ~= 'table' then return nil end

    if value.x ~= nil and value.y ~= nil then
        return Park.vec(tonumber(value.x), tonumber(value.y), tonumber(value.z))
    end

    if value[1] ~= nil and value[2] ~= nil then
        return Park.vec(tonumber(value[1]), tonumber(value[2]), tonumber(value[3]))
    end

    return nil
end

--[[
    Squared distance. Squared because every caller is comparing against a radius, and a square
    root per vehicle per tick over a few thousand vehicles is a measurable cost for a number
    nobody reads.
]]
function Park.distanceSq(a, b)
    if not a or not b then return math.huge end
    local dx, dy, dz = (a.x or 0) - (b.x or 0), (a.y or 0) - (b.y or 0), (a.z or 0) - (b.z or 0)
    return dx * dx + dy * dy + dz * dz
end

function Park.distance(a, b)
    return math.sqrt(Park.distanceSq(a, b))
end

--[[
    Flat distance, ignoring Z.

    The one that matters for a multi-storey car park: two vehicles thirty metres apart
    vertically are not near each other for streaming purposes, but they ARE in the same cell,
    and a cell is a flat thing. Used where the answer must match the grid.
]]
function Park.distanceFlatSq(a, b)
    if not a or not b then return math.huge end
    local dx, dy = (a.x or 0) - (b.x or 0), (a.y or 0) - (b.y or 0)
    return dx * dx + dy * dy
end

--[[
    Shortest signed difference between two angles, in degrees, in [-180, 180].

    Naive subtraction says 359 and 1 are 358 degrees apart. They are 2.
]]
function Park.angleDelta(a, b)
    local delta = ((a or 0) - (b or 0)) % 360.0
    if delta > 180.0 then delta = delta - 360.0 end
    return delta
end

function Park.rotationsDiffer(a, b, tolerance)
    if not a or not b then return true end
    tolerance = tolerance or 0.5
    return math.abs(Park.angleDelta(a.x, b.x)) > tolerance
        or math.abs(Park.angleDelta(a.y, b.y)) > tolerance
        or math.abs(Park.angleDelta(a.z, b.z)) > tolerance
end

-- ---------------------------------------------------------------------------------------
-- Time
-- ---------------------------------------------------------------------------------------

local isServer = IsDuplicityVersion()
Park.isServer = isServer

--[[
    Unix seconds, or 0 when the clock is not known.

    Server: `os.time()`, always available.
    Client: `GetCloudTimeAsInt()`, which returns 0 for the first frames after joining and
    would otherwise read as 1st January 1970 - old enough for every abandonment timer on the
    server to fire at once.

    EVERY caller checks for 0. There is no fallback value that is safe here; a wrong clock is
    worse than a missing one.
]]
function Park.now()
    if isServer then return os.time() end
    local cloud = GetCloudTimeAsInt()
    if type(cloud) ~= 'number' or cloud <= 0 then return 0 end
    return cloud
end

--[[
    A monotonic millisecond counter for measuring durations.

    `GetGameTimer()` on both sides. It does not go backwards when the wall clock is corrected,
    which is the whole point: a save budget measured against os.time can go negative when NTP
    steps the server.
]]
function Park.ticks()
    return GetGameTimer()
end

--[[
    Format a duration in seconds as the shortest thing a human reads at a glance.
]]
function Park.duration(seconds)
    seconds = math.floor(tonumber(seconds) or 0)
    if seconds < 0 then seconds = 0 end

    if seconds < 60 then return ('%ds'):format(seconds) end
    if seconds < 3600 then return ('%dm'):format(math.floor(seconds / 60)) end
    if seconds < 86400 then
        local hours = math.floor(seconds / 3600)
        local minutes = math.floor((seconds % 3600) / 60)
        if minutes == 0 then return ('%dh'):format(hours) end
        return ('%dh%02dm'):format(hours, minutes)
    end

    local days = math.floor(seconds / 86400)
    local hours = math.floor((seconds % 86400) / 3600)
    if hours == 0 then return ('%dd'):format(days) end
    return ('%dd%dh'):format(days, hours)
end

-- ---------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------

function Park.count(t)
    if type(t) ~= 'table' then return 0 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

function Park.isEmpty(t)
    if type(t) ~= 'table' then return true end
    return next(t) == nil
end

--[[
    Deep copy. Used wherever a config table is handed to code that might keep it: the config
    is read by everything and owned by nobody, and one resource mutating a shared subtable is
    a bug that surfaces three restarts later.
]]
function Park.copy(value)
    if type(value) ~= 'table' then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = Park.copy(v) end
    return out
end

--[[
    Merge `override` onto `base`, in place, recursively.

    Arrays are REPLACED, not merged. An operator writing `blacklist = { 'a' }` in an override
    means that list and not that list appended to ours, and every attempt to be clever about
    which tables are arrays gets it wrong on the one table where it matters.
]]
function Park.merge(base, override)
    if type(base) ~= 'table' or type(override) ~= 'table' then return override end

    for k, v in pairs(override) do
        if type(v) == 'table' and type(base[k]) == 'table' and not Park.isArray(v) then
            Park.merge(base[k], v)
        else
            base[k] = Park.copy(v)
        end
    end

    return base
end

function Park.isArray(t)
    if type(t) ~= 'table' then return false end
    if next(t) == nil then return true end
    local n = 0
    for k in pairs(t) do
        if type(k) ~= 'number' then return false end
        n = n + 1
    end
    return n == #t
end

--[[
    Turn a list into a set keyed by its lowercased string values.

    Every blacklist in the config is authored as a list because that is what is pleasant to
    write, and looked up as a set because that is what is fast to read. Case is folded here
    once so that no lookup site has to remember to fold it.
]]
function Park.set(list)
    local out = {}
    if type(list) ~= 'table' then return out end
    for _, value in ipairs(list) do
        if type(value) == 'string' then
            out[value:lower()] = true
        elseif value ~= nil then
            out[value] = true
        end
    end
    return out
end

function Park.keys(t)
    local out = {}
    if type(t) ~= 'table' then return out end
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
    return out
end

-- ---------------------------------------------------------------------------------------
-- Strings
-- ---------------------------------------------------------------------------------------

function Park.trim(value)
    if type(value) ~= 'string' then return '' end
    return (value:gsub('^%s+', ''):gsub('%s+$', ''))
end

--[[
    A plate as the game stores it: uppercase, exactly 8 characters, padded with spaces.

    The game pads. A plate set to "ABC123" comes back out of `GetVehicleNumberPlateText` as
    "ABC123  ", and every resource that compares a trimmed plate to an untrimmed one has a
    bug. We normalise on the way in and compare normalised, always.
]]
function Park.plate(value)
    if type(value) ~= 'string' then return nil end
    local plate = value:upper():gsub('^%s+', ''):gsub('%s+$', '')
    if plate == '' then return nil end
    return plate
end

--[[
    Compare two plates the way the game means them to be compared.
]]
function Park.platesMatch(a, b)
    local left, right = Park.plate(a), Park.plate(b)
    if not left or not right then return false end
    return left == right
end

--[[
    Split a command line into arguments, honouring double quotes.

    FiveM already splits on spaces for us, but the migration and the admin commands take
    free-text arguments and an operator typing a plate with a space in it is not a bug.
]]
function Park.words(value)
    local out = {}
    if type(value) ~= 'string' then return out end
    for word in value:gmatch('[^%s]+') do out[#out + 1] = word end
    return out
end

-- ---------------------------------------------------------------------------------------
-- Hashing
--
-- The delta-save design lives or dies on this being stable. Two runs of the same server, on
-- two different machines, must hash an unchanged vehicle to the same number - otherwise the
-- first save tick after every restart writes every row in the table.
-- ---------------------------------------------------------------------------------------

local FNV_OFFSET = 2166136261
local FNV_PRIME = 16777619

--[[
    Canonical serialisation: sorted keys, quantised floats, no whitespace.

    `json.encode` is NOT used here. Its key order is the hash order of the underlying table,
    which is not stable across runs, and its float formatting differs between the client and
    the server runtimes. Both would produce a hash that changes for no reason.
]]
local function canonical(value, depth)
    depth = (depth or 0) + 1
    if depth > 12 then return '~' end -- a cycle, or a table nobody meant to hash

    local kind = type(value)

    if value == nil then return 'n' end
    if kind == 'boolean' then return value and 't' or 'f' end

    if kind == 'number' then
        -- Integers keep their exact form; floats are quantised to 3 decimals so that
        -- floating point noise below what we store cannot move the hash.
        if value % 1 == 0 and math.abs(value) < 2 ^ 53 then
            return ('i%d'):format(value)
        end
        return ('d%.3f'):format(value)
    end

    if kind == 'string' then return 's' .. value end

    if kind ~= 'table' then return 'u' .. tostring(kind) end

    local parts = {}
    local order = Park.keys(value)
    for i = 1, #order do
        local key = order[i]
        parts[#parts + 1] = tostring(key) .. '=' .. canonical(value[key], depth)
    end

    return '{' .. table.concat(parts, ',') .. '}'
end

Park.canonical = canonical

--[[
    FNV-1a, 32 bit, over the canonical form. Returned as a number.

    Not a cryptographic hash and not trying to be. It answers one question - did this vehicle
    change since we last wrote it - and a collision costs one skipped save of a vehicle that
    will be re-checked on the next tick anyway.
]]
function Park.hash(value)
    local text = canonical(value)
    local hash = FNV_OFFSET

    for i = 1, #text do
        hash = hash ~ text:byte(i)
        -- The multiply is done in 32 bits explicitly. Lua 5.4 integers are 64 bit and would
        -- otherwise carry the overflow that FNV depends on discarding.
        hash = (hash * FNV_PRIME) & 0xFFFFFFFF
    end

    return hash
end

-- ---------------------------------------------------------------------------------------
-- Identifiers
-- ---------------------------------------------------------------------------------------

local idCounter = 0

--[[
    A short, sortable, collision-resistant id for a persisted vehicle.

    Format: `<base36 seconds><base36 counter><4 random base36>`, uppercase, 12-14 characters.
    The time prefix means ids sort chronologically in a database index and in a printed list,
    which is what an operator scanning `/vparklist` actually wants.

    The counter guarantees uniqueness within a second on one server; the random tail makes a
    collision between two servers sharing a database vanishingly unlikely. The column is
    UNIQUE regardless, so a collision is a rejected insert and a retry, never a lost vehicle.
]]
local BASE36 = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'

local function base36(value, width)
    value = math.floor(math.abs(tonumber(value) or 0))
    local out = ''
    repeat
        local digit = value % 36
        out = BASE36:sub(digit + 1, digit + 1) .. out
        value = math.floor(value / 36)
    until value == 0

    if width then
        while #out < width do out = '0' .. out end
    end

    return out
end

Park.base36 = base36

function Park.id()
    idCounter = (idCounter + 1) % 1296 -- two base36 digits

    local seconds = Park.now()
    if seconds <= 0 then seconds = math.floor(Park.ticks() / 1000) end

    local random = ''
    for _ = 1, 4 do
        local n = math.random(1, 36)
        random = random .. BASE36:sub(n, n)
    end

    return base36(seconds, 7) .. base36(idCounter, 2) .. random
end

-- ---------------------------------------------------------------------------------------
-- Logging
--
-- One place, so that a server operator can silence us with one config value and so that
-- every line this resource prints is recognisable as ours in a wall of console output.
-- ---------------------------------------------------------------------------------------

local LEVELS = { error = 1, warn = 2, info = 3, debug = 4, trace = 5 }

local COLOURS = {
    error = '^1',
    warn  = '^3',
    info  = '^2',
    debug = '^5',
    trace = '^8',
}

--[[
    The threshold is read from Config on every call rather than cached.

    `/vparkdebug` changes it at runtime, and a cached level would mean restarting the resource
    to see debug output - which is exactly the moment the thing you wanted to debug goes away.
]]
local function threshold()
    local level = Config and Config.Log and Config.Log.level
    return LEVELS[level] or LEVELS.info
end

--[[
    An optional observer, called for every line that is printed.

    `server/webhook.lua` installs one so that an error reaches Discord without every call site
    having to know Discord exists. It is a single slot rather than a list on purpose: two
    observers would be two things posting, and there is exactly one thing that wants to.

    It is called AFTER the print and inside a pcall, so a broken observer cannot swallow a log
    line or take down whatever was logging.
]]
Park.observer = nil

local function emit(level, message)
    if (LEVELS[level] or 3) > threshold() then return end

    local colour = COLOURS[level] or '^7'

    print(('%s[v-park]^7 %s%s'):format(
        colour,
        level == 'info' and '' or (colour .. level:upper() .. ': ^7'),
        message
    ))

    if Park.observer then
        pcall(Park.observer, level, message)
    end
end

function Park.log(message, ...)
    if select('#', ...) > 0 then message = message:format(...) end
    emit('info', message)
end

function Park.warn(message, ...)
    if select('#', ...) > 0 then message = message:format(...) end
    emit('warn', message)
end

function Park.error(message, ...)
    if select('#', ...) > 0 then message = message:format(...) end
    emit('error', message)
end

function Park.debug(message, ...)
    if (LEVELS.debug) > threshold() then return end -- format nothing we will not print
    if select('#', ...) > 0 then message = message:format(...) end
    emit('debug', message)
end

function Park.trace(message, ...)
    if (LEVELS.trace) > threshold() then return end
    if select('#', ...) > 0 then message = message:format(...) end
    emit('trace', message)
end

-- ---------------------------------------------------------------------------------------
-- The spatial grid
--
-- Shared because the server indexes vehicles into it and the client asks which cells it is
-- standing in. One implementation, or the two disagree about which cell a boundary
-- coordinate belongs to and vehicles on a cell edge flicker.
-- ---------------------------------------------------------------------------------------

--[[
    The cell key for a coordinate.

    Flat, deliberately: a car park with six floors is one cell, and the whole point of the
    grid is to answer "is anybody near enough to care" cheaply. Z is handled by the distance
    check that runs after the grid narrows the candidates.

    `math.floor` and not integer division, because coordinates are negative over half the map
    and integer division in Lua 5.4 truncates towards zero - which would give cell 0 twice the
    width of every other cell, straddling the origin.
]]
function Park.cellKey(x, y, size)
    size = size or 200
    local cx = math.floor((tonumber(x) or 0) / size)
    local cy = math.floor((tonumber(y) or 0) / size)
    return cx * 100000 + cy -- one integer key, no string concatenation per lookup
end

--[[
    Every cell key within `radius` of a point, as a list.

    The caller iterates these and unions their contents. `radius` is in metres and converted
    to a ring count, so a 300 metre radius on 200 metre cells looks at a 3x3 block - 9 cells
    rather than the whole map.
]]
function Park.cellsAround(x, y, radius, size)
    size = size or 200
    local rings = math.ceil((tonumber(radius) or 0) / size)
    local cx = math.floor((tonumber(x) or 0) / size)
    local cy = math.floor((tonumber(y) or 0) / size)

    local out = {}
    for ix = cx - rings, cx + rings do
        for iy = cy - rings, cy + rings do
            out[#out + 1] = ix * 100000 + iy
        end
    end

    return out
end

-- ---------------------------------------------------------------------------------------
-- Encoding
-- ---------------------------------------------------------------------------------------

--[[
    json.encode that never raises and never returns nil.

    A nil here means a NOT NULL column takes a nil and the whole batch insert fails, taking
    every other vehicle in it with it. An empty object is a vehicle with no modifications,
    which is wrong but recoverable; a failed batch is not.
]]
function Park.encode(value)
    if value == nil then return '{}' end
    local ok, encoded = pcall(json.encode, value)
    if not ok or type(encoded) ~= 'string' then
        Park.warn('could not encode a value for storage, wrote an empty object instead')
        return '{}'
    end
    return encoded
end

--[[
    json.decode that never raises, and that accepts a value already decoded.

    The second half matters for the migration: some MySQL drivers hand back a JSON column
    already decoded into a table, and some hand back the string. Both arrive here.
]]
function Park.decode(value)
    if value == nil then return nil end
    if type(value) == 'table' then return value end
    if type(value) ~= 'string' then return nil end
    if value == '' then return nil end

    local ok, decoded = pcall(json.decode, value)
    if not ok or type(decoded) ~= 'table' then return nil end
    return decoded
end
