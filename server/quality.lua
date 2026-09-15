--[[
    server/quality.lua

    Which players are fit to be handed synchronisation work.

    -------------------------------------------------------------------------------------------
    WHY THIS EXISTS
    -------------------------------------------------------------------------------------------

    v-park names a client to do the work only a client can do: dress and place a restored
    vehicle, answer a capture. It has always picked the NEAREST player, because the nearest
    player is the one most likely to have the vehicle in scope.

    The nearest player is also, often enough, the one with a bad connection or a machine
    struggling at 15 FPS. A placement then waits twenty seconds for an answer that never comes,
    the vehicle is removed and re-nominated, and a capture request goes unanswered until it
    expires. Nothing breaks outright; the server just does the same work twice and the vehicle
    appears late.

    -------------------------------------------------------------------------------------------
    WHAT IT CHANGES, AND WHAT IT DELIBERATELY DOES NOT
    -------------------------------------------------------------------------------------------

    The nearest player is still chosen by default. A player is only passed over when they are
    CLEARLY struggling - high ping, low reported FPS, or several recent unanswered requests - and
    another player is within `slack` metres of them, so the replacement is just as likely to have
    the vehicle in scope. With nobody suitable nearby, the nearest player is kept: a slow answer
    beats no answer.

    Where the network owner of an entity is already the one being asked, nothing here is
    consulted. The owner simulates the entity, and that is worth more than a better connection.

    Packet loss itself is not readable on the server. Ping, unanswered requests and placements
    that never came back are what a lossy connection looks like from here, and those are measured
    directly.
]]

Quality = {}

-- src -> { fps, fpsAt, strikes = { tick, tick, ... } }
local players = {}

local stats = { passedOver = 0 }

local function options()
    return (Config and Config.Performance and Config.Performance.syncQuality) or {}
end

local function entry(src)
    local item = players[src]
    if not item then
        item = { strikes = {} }
        players[src] = item
    end
    return item
end

-- Recent strikes only. A player who lagged ten minutes ago is not a bad choice now.
local function strikeCount(item)
    local window = (tonumber(options().strikeMinutes) or 5) * 60000
    local now = Park.ticks()
    local kept = {}

    for _, at in ipairs(item.strikes) do
        if now - at <= window then kept[#kept + 1] = at end
    end

    item.strikes = kept
    return #kept
end

--[[
    Something this player was asked to do did not happen: a placement with no answer, a restore
    that could not find the entity, a capture request that expired.
]]
function Quality.strike(src)
    src = tonumber(src)
    if not src or src <= 0 then return end

    local item = entry(src)
    item.strikes[#item.strikes + 1] = Park.ticks()
end

function Quality.forget(src)
    players[tonumber(src) or src] = nil
end

--[[
    Is this player clearly struggling?

    Conservative on purpose: every threshold is well past what an ordinary player hits, because
    passing over a player who was fine costs a vehicle placed by somebody slightly further away.
]]
function Quality.poor(src)
    local opts = options()
    if opts.enabled == false then return false end

    src = tonumber(src)
    if not src then return false end

    local ping = GetPlayerPing and GetPlayerPing(src) or 0
    if ping and ping > (tonumber(opts.maxPing) or 250) then return true end

    local item = players[src]
    if not item then return false end

    -- An FPS report only counts while it is fresh. A client that stopped reporting says nothing.
    if item.fps and item.fpsAt and Park.ticks() - item.fpsAt < 30000
        and item.fps < (tonumber(opts.minFps) or 25) then
        return true
    end

    return strikeCount(item) >= (tonumber(opts.maxStrikes) or 2)
end

--[[
    The player to hand work for a position to.

    Returns the same table shape as the `players` list it is given. Nearest first, exactly as
    before; a struggling nearest player is only replaced by one within `slack` metres of them.
]]
function Quality.pick(players_, x, y, bucket)
    local nearest, nearestDistance

    for _, player in ipairs(players_) do
        if player.bucket == bucket then
            local dx, dy = player.x - x, player.y - y
            local distance = dx * dx + dy * dy
            if not nearestDistance or distance < nearestDistance then
                nearest, nearestDistance = player, distance
            end
        end
    end

    if not nearest or not Quality.poor(nearest.src) then return nearest end

    local slack = tonumber(options().slack) or 40.0
    local limit = (math.sqrt(nearestDistance) + slack) ^ 2
    local best, bestDistance

    for _, player in ipairs(players_) do
        if player ~= nearest and player.bucket == bucket then
            local dx, dy = player.x - x, player.y - y
            local distance = dx * dx + dy * dy
            if distance <= limit and not Quality.poor(player.src)
                and (not bestDistance or distance < bestDistance) then
                best, bestDistance = player, distance
            end
        end
    end

    if best then
        stats.passedOver = stats.passedOver + 1
        return best
    end

    return nearest
end

function Quality.stats()
    local poor = 0
    for _, src in ipairs(GetPlayers()) do
        if Quality.poor(src) then poor = poor + 1 end
    end
    return { poor = poor, passedOver = stats.passedOver }
end

--[[
    A client reporting its frame rate. Rate-limited and clamped: the value only ever makes a
    player LESS likely to be chosen, so lying about it can do nothing but take work off the liar.
]]
RegisterNetEvent('vpark:server:quality', function(fps)
    local src = source
    fps = tonumber(fps)
    if not fps or fps ~= fps then return end

    local item = entry(src)
    local now = Park.ticks()
    if item.reportAt and now - item.reportAt < 5000 then return end

    item.reportAt = now
    item.fps = math.max(1, math.min(500, fps))
    item.fpsAt = now
end)

AddEventHandler('playerDropped', function()
    Quality.forget(source)
end)
