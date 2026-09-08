--[[
    server/webhook.lua

    Posting to Discord: errors, staff actions and, if you ask for it, routine activity.

    -------------------------------------------------------------------------------------------
    THE THREE RULES THIS FILE EXISTS TO OBEY
    -------------------------------------------------------------------------------------------

    1. A WEBHOOK MUST NEVER HOLD ANYTHING UP. Every post is fire-and-forget, in its own thread,
       and nothing waits for a reply. Discord being slow, down, or rate-limiting must be
       invisible to the resource. A save that blocks on a webhook is a save that does not
       happen.

    2. AN ERROR INSIDE A TIMER MUST NOT POST 3600 TIMES AN HOUR. That is the failure mode that
       makes people turn error webhooks off, and once they are off the next real error is
       unread for a fortnight. Identical messages inside `dedupeSeconds` collapse into one post
       carrying a count, and a per-minute ceiling caps the rest.

    3. A WEBHOOK POST MUST NOT BE ABLE TO CAUSE THE ERROR IT IS REPORTING. Everything here is
       inside pcall, and `Park.observer` - which is how an error gets here at all - is called
       inside its own pcall by the logger. A recursive error would otherwise be a stack
       overflow triggered by the first genuine one.

    -------------------------------------------------------------------------------------------
    WHERE THE URL COMES FROM
    -------------------------------------------------------------------------------------------

    A convar first, `config.lua` second. A webhook URL is a credential: anybody holding it can
    post to the channel as you, forever, with no further authentication. `config.lua` is in the
    repository and in the zip an operator sends when they ask for help; `server.cfg` is not.

    Section 2b of config.lua says this at more length, next to the setting.
]]

Webhook = {}

-- Identical messages seen recently: key -> { at, count, posted }
local recent = {}

-- Rolling per-minute counter, and how many were suppressed since the last post.
local windowStart = 0
local windowCount = 0
local suppressed = 0

local queueDepth = 0

local function config()
    return (Config and Config.Webhooks) or {}
end

local function enabled()
    return config().enabled ~= false
end

-- ---------------------------------------------------------------------------------------
-- Resolving a URL
-- ---------------------------------------------------------------------------------------

local resolved = {}

--[[
    The URL for a channel, from its convar or its config entry.

    Cached, because `GetConvar` is called on a path that can run once a second. A convar
    changed at runtime therefore needs `/vparkreload`, which is documented and is the right
    trade: nobody changes a webhook URL while the server is running, and everybody has errors
    while it is.
]]
local function urlFor(channel)
    if resolved[channel] ~= nil then return resolved[channel] or nil end

    local section = config()[channel]
    if type(section) ~= 'table' or section.enabled == false then
        resolved[channel] = false
        return nil
    end

    local url

    if type(section.convar) == 'string' and section.convar ~= '' then
        local value = GetConvar(section.convar, '')
        if value ~= '' then url = value end
    end

    if not url and type(section.url) == 'string' and section.url ~= '' then
        url = section.url
        Park.warn("the %s webhook URL is in config.lua - consider `set %s` in server.cfg instead",
            channel, tostring(section.convar))
    end

    -- A URL that is not a Discord webhook is almost always a paste error, and posting server
    -- data to whatever it actually is would be worse than not posting at all.
    if url and not url:match('^https://[%w%.]*discord%.?c?o?m?/api/webhooks/') then
        Park.warn('the %s webhook URL does not look like a Discord webhook - it will not be used', channel)
        url = nil
    end

    resolved[channel] = url or false
    return url
end

function Webhook.reload()
    resolved = {}
end

function Webhook.configured(channel)
    return urlFor(channel) ~= nil
end

-- ---------------------------------------------------------------------------------------
-- Rate limiting
-- ---------------------------------------------------------------------------------------

--[[
    Should this message be posted, and with what note attached?

    Returns `post, note`. `note` is a suffix describing what was collapsed into this post, or
    nil, so that a burst is visible as a burst rather than looking like a single event.
]]
local function admit(key, limitPerMinute, dedupeSeconds)
    local now = Park.ticks()

    -- The rolling window.
    if now - windowStart > 60000 then
        local carried = suppressed
        windowStart = now
        windowCount = 0
        suppressed = 0

        if carried > 0 then
            return true, ('%d further message(s) were suppressed in the previous minute'):format(carried)
        end
    end

    if limitPerMinute > 0 and windowCount >= limitPerMinute then
        suppressed = suppressed + 1
        return false
    end

    -- Deduplication.
    if dedupeSeconds > 0 and key then
        local entry = recent[key]

        if entry and (now - entry.at) < dedupeSeconds * 1000 then
            entry.count = entry.count + 1
            return false
        end

        local note
        if entry and entry.count > 1 then
            note = ('this repeated %d time(s) in the last %s'):format(entry.count, Park.duration(dedupeSeconds))
        end

        recent[key] = { at = now, count = 1 }
        windowCount = windowCount + 1
        return true, note
    end

    windowCount = windowCount + 1
    return true
end

--[[
    Drop dedupe entries nobody will ever match again.

    Without it the table grows for the life of the server, keyed on messages that included a
    vehicle id and will therefore never repeat.
]]
CreateThread(function()
    while true do
        Wait(300000)

        local now = Park.ticks()
        local dedupe = (config().errors and tonumber(config().errors.dedupeSeconds) or 300) * 1000

        for key, entry in pairs(recent) do
            if now - entry.at > dedupe * 4 then
                recent[key] = nil
            end
        end
    end
end)

-- ---------------------------------------------------------------------------------------
-- Posting
-- ---------------------------------------------------------------------------------------

local function serverName()
    local configured = config().serverName
    if type(configured) == 'string' and configured ~= '' then return configured end

    local project = GetConvar('sv_projectName', '')
    if project ~= '' then return project end

    return nil
end

--[[
    Send one embed.

    In its own thread and never awaited. `PerformHttpRequest`'s callback is used only to notice
    a rejection worth telling the console about - and even that is rate-limited to once, because
    an invalid webhook would otherwise produce one console line per post forever.
]]
local warnedRejected = {}

local function post(channel, embed)
    if not enabled() then return end

    local url = urlFor(channel)
    if not url then return end

    local payload = {
        username = config().username or 'v-park',
        avatar_url = config().avatar,
        embeds = { embed },
    }

    queueDepth = queueDepth + 1

    CreateThread(function()
        local ok = pcall(function()
            PerformHttpRequest(url, function(status, _, _, response)
                queueDepth = queueDepth - 1

                -- 204 is Discord's success for a webhook. 429 is a rate limit, which is
                -- expected under a burst and not worth a console line.
                if status ~= 200 and status ~= 204 and status ~= 429 then
                    if not warnedRejected[channel] then
                        warnedRejected[channel] = true
                        -- Printed rather than logged, deliberately: routing this through
                        -- Park.error would call the observer, which would try to post it,
                        -- which is the recursion this whole file is careful about.
                        print(('^3[v-park]^7 the %s webhook was rejected with status %s: %s')
                            :format(channel, tostring(status), tostring(response):sub(1, 200)))
                        print('^3[v-park]^7 this is reported once; check the URL and the channel permissions')
                    end
                end
            end, 'POST', json.encode(payload), { ['Content-Type'] = 'application/json' })
        end)

        if not ok then
            queueDepth = queueDepth - 1
        end
    end)
end

Webhook.post = post

local function embed(colour, title, description, fields, note)
    local out = {
        title = title,
        description = description,
        color = colour,
        footer = { text = serverName() and ('v-park - ' .. serverName()) or 'v-park' },
        timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    }

    if type(fields) == 'table' and #fields > 0 then
        out.fields = fields
    end

    if note then
        out.description = (out.description or '') .. '\n\n_' .. note .. '_'
    end

    return out
end

-- ---------------------------------------------------------------------------------------
-- Errors
--
-- Installed as the logger's observer, so no call site anywhere in the resource needs to know
-- Discord exists. `Park.error(...)` reaches Discord because of these fifteen lines and nothing
-- else.
-- ---------------------------------------------------------------------------------------

local LEVEL_RANK = { error = 1, warn = 2, info = 3, debug = 4, trace = 5 }

Park.observer = function(level, message)
    if not enabled() then return end

    local section = config().errors
    if type(section) ~= 'table' or section.enabled == false then return end

    local wanted = LEVEL_RANK[section.level or 'warn'] or 2
    if (LEVEL_RANK[level] or 5) > wanted then return end

    -- The dedupe key is the message with numbers stripped. An error that names a vehicle id
    -- or a millisecond count is the SAME error every time it fires, and keying on the exact
    -- text would defeat deduplication precisely where it is needed most.
    local key = level .. ':' .. message:gsub('%d+', '#'):sub(1, 160)

    local allowed, note = admit(
        key,
        tonumber(section.rateLimitPerMinute) or 12,
        tonumber(section.dedupeSeconds) or 300
    )

    if not allowed then return end

    local colours = config().colours or {}

    post('errors', embed(
        level == 'error' and (colours.error or 15158332) or (colours.warn or 15844367),
        level == 'error' and 'Error' or 'Warning',
        '```\n' .. message:sub(1, 1800) .. '\n```',
        {
            { name = 'Uptime', value = Park.duration(math.floor(Park.ticks() / 1000)), inline = true },
            { name = 'Vehicles', value = tostring(Store and Store.count() or '?'), inline = true },
            { name = 'In world', value = tostring(Store and Store.liveCount() or '?'), inline = true },
        },
        note
    ))
end

-- ---------------------------------------------------------------------------------------
-- Staff actions
-- ---------------------------------------------------------------------------------------

--[[
    A player's Discord id, when their identifiers carry one.

    Used to mention the actor so a post pings the person rather than naming a character who
    may not be recognisable to whoever reads the channel. Absent on a player who has not
    linked Discord, which is fine and common.
]]
local function discordId(src)
    if type(src) ~= 'number' or src <= 0 then return nil end

    for _, identifier in ipairs(GetPlayerIdentifiers(src) or {}) do
        local id = identifier:match('^discord:(%d+)$')
        if id then return id end
    end

    return nil
end

--[[
    Record a staff action.

    `detail` is a table of extra fields; every value is stringified, and nils are skipped, so a
    caller can pass whatever it has without building the field list.
]]
function Webhook.admin(action, src, target, detail)
    if not enabled() then return end

    local section = config().admin
    if type(section) ~= 'table' or section.enabled == false then return end

    local actions = section.actions or {}
    if actions[action] == false then return end

    local actorName = Bridge.name(src) or ('player ' .. tostring(src))
    local mention = ''

    if section.mentionActor ~= false and src ~= 0 then
        local id = discordId(src)
        if id then mention = (' (<@%s>)'):format(id) end
    end

    local fields = {
        { name = 'Staff', value = actorName .. mention, inline = true },
    }

    if target then
        fields[#fields + 1] = { name = 'Vehicle', value = tostring(target), inline = true }
    end

    if type(detail) == 'table' then
        for _, key in ipairs(Park.keys(detail)) do
            local value = detail[key]
            if value ~= nil then
                fields[#fields + 1] = {
                    name = tostring(key),
                    value = tostring(value):sub(1, 240),
                    inline = true,
                }
            end
        end
    end

    -- Admin posts are NOT deduplicated: an admin deleting the same kind of thing twice is two
    -- separate facts, and collapsing them would hide exactly what this channel exists to
    -- record. They are still rate-limited, because a mass purge is one action and not four
    -- hundred.
    local _, note = admit(nil, tonumber((config().errors or {}).rateLimitPerMinute) or 12, 0)

    post('admin', embed(
        (config().colours or {}).admin or 10181046,
        'Staff action: ' .. action,
        nil,
        fields,
        note
    ))
end

-- ---------------------------------------------------------------------------------------
-- Activity
-- ---------------------------------------------------------------------------------------

function Webhook.activity(event, title, description, fields)
    if not enabled() then return end

    local section = config().activity
    if type(section) ~= 'table' or section.enabled == false then return end

    local events = section.events or {}
    if events[event] == false then return end

    post('activity', embed(
        (config().colours or {}).info or 3447003,
        title,
        description,
        fields
    ))
end

function Webhook.stats()
    return {
        enabled = enabled(),
        errors = Webhook.configured('errors'),
        admin = Webhook.configured('admin'),
        activity = Webhook.configured('activity'),
        queued = queueDepth,
        suppressed = suppressed,
        deduped = Park.count(recent),
    }
end

-- ---------------------------------------------------------------------------------------
-- Boot summary
-- ---------------------------------------------------------------------------------------

CreateThread(function()
    while not Runtime.ready() do Wait(500) end
    Wait(2000)

    local store = Store.stats()

    Webhook.activity('bootSummary', 'v-park started', nil, {
        { name = 'Vehicles', value = tostring(store.total), inline = true },
        { name = 'Framework', value = Bridge.kind(), inline = true },
        { name = 'Database', value = Database.driver(), inline = true },
        { name = 'Mode', value = tostring(Config.Persistence and Config.Persistence.mode), inline = true },
    })
end)
