--[[
    shared/zones.lua

    Where nothing persists.

    Shared because the server refuses to save a vehicle inside a zone and refuses to restore
    one into it, while the client draws them for `/vparkdebug` and checks locally before
    bothering the server. Two implementations of point-in-polygon is two answers on the edge,
    and the edge is where every zone bug lives.

    Three shapes, all cheap:

        circle   one squared distance, optionally bounded in Z
        box      six comparisons, axis-aligned
        poly     ray casting, O(points), optionally bounded in Z

    No dependency on PolyZone. It is a good resource, it is not installed everywhere, and
    what we need from it is forty lines.
]]

Zones = {}

local compiled          -- the config list, validated and normalised, built once
local compiledCount = 0

-- ---------------------------------------------------------------------------------------
-- Compilation
--
-- Done once at boot rather than per query. It validates shapes, drops broken ones with a
-- named warning, and precomputes the bounding box of every polygon so that the common case -
-- a point nowhere near it - costs four comparisons instead of a ray cast.
-- ---------------------------------------------------------------------------------------

local function compileCircle(zone, index)
    local centre = Park.toVec(zone.centre or zone.center or zone.coords)
    if not centre then
        Park.warn('zone #%d (%s) is a circle with no usable centre and was dropped',
            index, tostring(zone.name or '?'))
        return nil
    end

    local radius = tonumber(zone.radius) or 0
    if radius <= 0 then
        Park.warn('zone #%d (%s) is a circle with radius %s and was dropped',
            index, tostring(zone.name or '?'), tostring(zone.radius))
        return nil
    end

    return {
        type = 'circle',
        name = zone.name or ('circle #' .. index),
        centre = centre,
        radiusSq = radius * radius,
        radius = radius,
        heightRange = zone.heightRange,
        -- The bounding box lets a query reject the zone before touching the distance maths.
        minX = centre.x - radius, maxX = centre.x + radius,
        minY = centre.y - radius, maxY = centre.y + radius,
    }
end

local function compileBox(zone, index)
    local min = Park.toVec(zone.min)
    local max = Park.toVec(zone.max)

    if not min or not max then
        Park.warn('zone #%d (%s) is a box without both min and max and was dropped',
            index, tostring(zone.name or '?'))
        return nil
    end

    -- An operator who wrote them the wrong way round meant the box between them. Sorting is
    -- kinder than warning, and there is no other thing they could have meant.
    local lowX, highX = math.min(min.x, max.x), math.max(min.x, max.x)
    local lowY, highY = math.min(min.y, max.y), math.max(min.y, max.y)
    local lowZ, highZ = math.min(min.z, max.z), math.max(min.z, max.z)

    return {
        type = 'box',
        name = zone.name or ('box #' .. index),
        min = { x = lowX, y = lowY, z = lowZ },
        max = { x = highX, y = highY, z = highZ },
        minX = lowX, maxX = highX,
        minY = lowY, maxY = highY,
    }
end

local function compilePoly(zone, index)
    local points = {}

    if type(zone.points) == 'table' then
        for _, raw in ipairs(zone.points) do
            local point = Park.toVec(raw)
            if point then points[#points + 1] = point end
        end
    end

    if #points < 3 then
        Park.warn('zone #%d (%s) is a polygon with %d usable points and was dropped',
            index, tostring(zone.name or '?'), #points)
        return nil
    end

    local minX, maxX = math.huge, -math.huge
    local minY, maxY = math.huge, -math.huge

    for _, point in ipairs(points) do
        if point.x < minX then minX = point.x end
        if point.x > maxX then maxX = point.x end
        if point.y < minY then minY = point.y end
        if point.y > maxY then maxY = point.y end
    end

    return {
        type = 'poly',
        name = zone.name or ('poly #' .. index),
        points = points,
        heightRange = zone.heightRange,
        minX = minX, maxX = maxX,
        minY = minY, maxY = maxY,
    }
end

--[[
    Build the compiled list from `Config.Zones` plus anything handed in.

    `extra` is how auto-detected garages arrive: the server reads a garage resource's config,
    turns each point into a circle, and calls this again. So the list is rebuilt, not
    appended to, and calling it twice is safe.
]]
function Zones.compile(extra)
    compiled = {}
    compiledCount = 0

    local sources = {}

    if type(Config) == 'table' and type(Config.Zones) == 'table' then
        for _, zone in ipairs(Config.Zones) do sources[#sources + 1] = zone end
    end

    if type(extra) == 'table' then
        for _, zone in ipairs(extra) do sources[#sources + 1] = zone end
    end

    for index, zone in ipairs(sources) do
        if type(zone) ~= 'table' then
            Park.warn('zone #%d is not a table and was dropped', index)
        else
            local kind = tostring(zone.type or 'circle'):lower()
            local built

            if kind == 'circle' or kind == 'sphere' then
                built = compileCircle(zone, index)
            elseif kind == 'box' or kind == 'aabb' then
                built = compileBox(zone, index)
            elseif kind == 'poly' or kind == 'polygon' then
                built = compilePoly(zone, index)
            else
                Park.warn("zone #%d (%s) has type '%s', which is not circle, box or poly",
                    index, tostring(zone.name or '?'), kind)
            end

            if built then
                built.source = zone.source or 'config'
                compiledCount = compiledCount + 1
                compiled[compiledCount] = built
            end
        end
    end

    return compiledCount
end

function Zones.all()
    if not compiled then Zones.compile() end
    return compiled
end

function Zones.count()
    if not compiled then Zones.compile() end
    return compiledCount
end

-- ---------------------------------------------------------------------------------------
-- Containment
-- ---------------------------------------------------------------------------------------

local function withinHeight(zone, z)
    local range = zone.heightRange
    if type(range) ~= 'table' then return true end

    local low = tonumber(range.min)
    local high = tonumber(range.max)

    if low and z < low then return false end
    if high and z > high then return false end

    return true
end

--[[
    Ray casting, crossing count.

    The `(a.y > y) ~= (b.y > y)` form is the standard one, and it is standard because it
    handles a vertex exactly on the ray consistently: the edge is treated as half-open, so a
    point level with a vertex is counted once rather than twice or not at all. Written any
    other way, a zone drawn from map coordinates - which are full of shared vertex heights -
    leaks at its corners.
]]
local function insidePolygon(points, x, y)
    local inside = false
    local count = #points
    local j = count

    for i = 1, count do
        local a, b = points[i], points[j]

        if (a.y > y) ~= (b.y > y) then
            local t = (y - a.y) / (b.y - a.y)
            if x < a.x + t * (b.x - a.x) then
                inside = not inside
            end
        end

        j = i
    end

    return inside
end

local function contains(zone, x, y, z)
    -- Bounding box first, for every shape. It is four comparisons and it rejects almost
    -- every query, which is what makes checking thirty zones per save affordable.
    if x < zone.minX or x > zone.maxX or y < zone.minY or y > zone.maxY then
        return false
    end

    if zone.type == 'circle' then
        local dx, dy = x - zone.centre.x, y - zone.centre.y
        if dx * dx + dy * dy > zone.radiusSq then return false end
        return withinHeight(zone, z)
    end

    if zone.type == 'box' then
        return z >= zone.min.z and z <= zone.max.z
    end

    if zone.type == 'poly' then
        if not withinHeight(zone, z) then return false end
        return insidePolygon(zone.points, x, y)
    end

    return false
end

--[[
    The zone containing a point, or nil.

    Returns the zone rather than a boolean so that the caller can name it: "not persisted,
    you are inside Pillbox garage" is an answer, "not persisted" is a support ticket.
]]
function Zones.at(position)
    if not compiled then Zones.compile() end
    if compiledCount == 0 then return nil end

    local point = Park.toVec(position)
    if not point then return nil end

    for i = 1, compiledCount do
        local zone = compiled[i]
        if contains(zone, point.x, point.y, point.z) then
            return zone
        end
    end

    return nil
end

function Zones.blocked(position)
    if type(Config) == 'table'
        and type(Config.Persistence) == 'table'
        and Config.Persistence.respectZones == false then
        return nil
    end

    return Zones.at(position)
end

--[[
    Every zone whose bounding box is within `radius` of a point.

    Used by the debug drawer, which wants the handful of zones near the player and not all of
    them. A bounding box test rather than a true distance because a polygon has no centre
    worth measuring to and the answer only needs to be roughly right.
]]
function Zones.near(position, radius)
    if not compiled then Zones.compile() end

    local point = Park.toVec(position)
    local out = {}
    if not point then return out end

    radius = radius or 200.0

    for i = 1, compiledCount do
        local zone = compiled[i]
        local nearestX = Park.clamp(point.x, zone.minX, zone.maxX)
        local nearestY = Park.clamp(point.y, zone.minY, zone.maxY)
        local dx, dy = point.x - nearestX, point.y - nearestY

        if dx * dx + dy * dy <= radius * radius then
            out[#out + 1] = zone
        end
    end

    return out
end
