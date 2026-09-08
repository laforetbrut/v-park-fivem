--[[
    shared/rules.lua

    Whether a vehicle is allowed to persist, and why not.

    Shared because both sides need the answer and they must never disagree. The client asks
    so it can stop reporting a vehicle the server would refuse anyway - which is most of the
    traffic saved on a busy server - and the server asks because the client's opinion is not
    evidence.

    -------------------------------------------------------------------------------------------
    THE RETURN SHAPE
    -------------------------------------------------------------------------------------------

    Every function here returns `allowed, reason`. The reason is a locale key, and it is
    returned even when allowed is true (as nil), because the interesting part of a refusal is
    always which rule refused.

    That shape is why `/vpark` in a blacklisted car says "this class of vehicle is never kept"
    rather than nothing at all.
]]

Rules = {}

-- Built once from the config, because building a set per vehicle per save is the sort of
-- thing that does not show up until a server has three thousand of them.
local cache

local function build()
    local persistence = (Config and Config.Persistence) or {}

    cache = {
        excludedClasses = Classes.setFrom(persistence.excludedClasses, 'Config.Persistence.excludedClasses'),
        lowPriority = Classes.setFrom(persistence.lowPriorityClasses, 'Config.Persistence.lowPriorityClasses'),
        excludedModels = Park.set(persistence.excludedModels),
        includedModels = Park.set(persistence.includedModels),
        platePrefixes = {},
        plateExact = {},
    }

    -- Plates are authored as a list that may contain prefixes: 'PDM*' means every plate
    -- starting PDM. Split once, here, rather than pattern-matching per vehicle.
    for _, raw in ipairs(persistence.excludedPlates or {}) do
        if type(raw) == 'string' then
            local plate = raw:upper()
            local prefix = plate:match('^(.-)%*$')
            if prefix and prefix ~= '' then
                cache.platePrefixes[#cache.platePrefixes + 1] = prefix
            else
                cache.plateExact[plate] = true
            end
        end
    end

    -- A whitelist is stored as hashes too, so that a config naming `adder` matches a vehicle
    -- we only know the hash of. GetHashKey is available on both sides.
    cache.includedHashes = {}
    for name in pairs(cache.includedModels) do
        cache.includedHashes[GetHashKey(name)] = true
    end

    cache.excludedHashes = {}
    for name in pairs(cache.excludedModels) do
        cache.excludedHashes[GetHashKey(name)] = true
    end

    cache.hasWhitelist = next(cache.includedModels) ~= nil
end

--[[
    Drop the cache so the next call rebuilds it. Called by `/vparkreload` and by the boot
    sequence after the config has been read.
]]
function Rules.invalidate()
    cache = nil
end

local function rules()
    if not cache then build() end
    return cache
end

function Rules.isLowPriority(class)
    return rules().lowPriority[class] == true
end

-- ---------------------------------------------------------------------------------------
-- The individual rules
--
-- Each is separately callable so that a command can explain exactly one of them, and so the
-- check script can assert each in isolation.
-- ---------------------------------------------------------------------------------------

function Rules.modelAllowed(model, modelName)
    local set = rules()

    -- A whitelist, when present, is the only rule that applies. An operator who wrote one
    -- meant "these and nothing else", and honouring the blacklist as well would produce the
    -- surprising case of a model on both lists being refused.
    if set.hasWhitelist then
        local name = type(modelName) == 'string' and modelName:lower() or nil
        if (name and set.includedModels[name]) or set.includedHashes[model] then
            return true
        end
        return false, 'refuse.model_not_whitelisted'
    end

    local name = type(modelName) == 'string' and modelName:lower() or nil
    if (name and set.excludedModels[name]) or set.excludedHashes[model] then
        return false, 'refuse.model_excluded'
    end

    return true
end

function Rules.classAllowed(class)
    if rules().excludedClasses[class] then
        return false, 'refuse.class_excluded'
    end
    return true
end

function Rules.plateAllowed(plate)
    local normalised = Park.plate(plate)
    if not normalised then
        -- No plate at all. Every land vehicle has one; a boat or an aircraft may not, and
        -- refusing those would be wrong. The plate is not what identifies a vehicle here -
        -- the id is - so a missing one is allowed and only costs the plate-based matching in
        -- Section 10.
        return true
    end

    local set = rules()

    if set.plateExact[normalised] then
        return false, 'refuse.plate_excluded'
    end

    for _, prefix in ipairs(set.platePrefixes) do
        if normalised:sub(1, #prefix) == prefix then
            return false, 'refuse.plate_excluded'
        end
    end

    return true
end

function Rules.healthAllowed(bodyHealth, engineHealth)
    local minimum = tonumber(Config and Config.Persistence and Config.Persistence.minimumBodyHealth) or 0
    if minimum <= 0 then return true end

    if type(bodyHealth) == 'number' and bodyHealth < minimum then
        return false, 'refuse.wrecked'
    end

    -- An engine at or below zero is a vehicle that will never start again. It is covered by
    -- the body check on most vehicles, and not on the ones that burned without deforming.
    if type(engineHealth) == 'number' and engineHealth <= 0 then
        return false, 'refuse.wrecked'
    end

    return true
end

function Rules.positionAllowed(position)
    local zone = Zones.blocked(position)
    if zone then
        return false, 'refuse.zone', zone.name
    end
    return true
end

--[[
    Does the persistence MODE allow this vehicle, given what is known about who owns it?

    `ownership` is one of 'owned', 'job', 'claimed', 'unowned', 'ambient'. The caller resolves
    it; this function only knows what the mode does with each.
]]
function Rules.modeAllows(ownership)
    local mode = (Config and Config.Persistence and Config.Persistence.mode) or 'all'

    if mode == 'none' then
        return false, 'refuse.disabled'
    end

    if mode == 'all' then
        -- Ambient adoption is separately gated, because 'all' means "everything a player
        -- drove" and an ambient vehicle is by definition one nobody drove.
        if ownership == 'ambient' then
            local ambient = Config.Persistence.ambient
            if not (ambient and ambient.enabled) then
                return false, 'refuse.ambient_disabled'
            end
        end
        return true
    end

    if mode == 'owned' then
        if ownership == 'owned' then return true end
        if ownership == 'job' and Config.Persistence.jobVehicles then return true end
        return false, 'refuse.not_owned'
    end

    if mode == 'claimed' then
        if ownership == 'claimed' then return true end
        if ownership == 'job' and Config.Persistence.jobVehicles then return true end
        return false, 'refuse.not_claimed'
    end

    Park.warn("Config.Persistence.mode is '%s', which is not a mode - treating it as 'none'", tostring(mode))
    return false, 'refuse.disabled'
end

-- ---------------------------------------------------------------------------------------
-- The composite
-- ---------------------------------------------------------------------------------------

--[[
    Everything, in the order that gives the most useful refusal first.

    Order matters for the message and not for the answer: a bicycle inside a garage zone is
    refused for being a bicycle, because that is the fact the player can do nothing about and
    therefore the one worth telling them.

    `candidate` is a table with, at minimum, `model`, `class` and `position`. Everything else
    is optional and skips the rule that needs it - which is how the client can run this
    against what it knows before the server has ever heard of the vehicle.
]]
function Rules.check(candidate)
    if type(candidate) ~= 'table' then
        return false, 'refuse.unknown'
    end

    local allowed, reason, detail

    allowed, reason = Rules.classAllowed(candidate.class or -1)
    if not allowed then return false, reason end

    allowed, reason = Rules.modelAllowed(candidate.model or 0, candidate.modelName)
    if not allowed then return false, reason end

    if candidate.ownership then
        allowed, reason = Rules.modeAllows(candidate.ownership)
        if not allowed then return false, reason end
    end

    if candidate.plate ~= nil then
        allowed, reason = Rules.plateAllowed(candidate.plate)
        if not allowed then return false, reason end
    end

    if candidate.bodyHealth ~= nil or candidate.engineHealth ~= nil then
        allowed, reason = Rules.healthAllowed(candidate.bodyHealth, candidate.engineHealth)
        if not allowed then return false, reason end
    end

    if candidate.position then
        allowed, reason, detail = Rules.positionAllowed(candidate.position)
        if not allowed then return false, reason, detail end
    end

    return true
end

--[[
    Expiry hours for an ownership kind, with the wrecked override.

    Kept here rather than in the lifecycle sweep because the client's `/vparklist` prints the
    remaining time and must compute it the same way, and because a wrecked owned vehicle
    taking the owned expiry - forever - is the exact bug this function exists to not have.
]]
function Rules.expiryHours(ownership, wrecked)
    local expiry = (Config and Config.Lifecycle and Config.Lifecycle.expiry) or {}

    if wrecked then
        local hours = tonumber(expiry.wrecked) or 0
        -- A wrecked vehicle expires at the SHORTER of its own timer and its ownership's,
        -- never the longer. An owned wreck should still be cleared; an unowned wreck should
        -- not outlive the unowned timer just because the wrecked one is bigger.
        local ownHours = tonumber(expiry[ownership]) or 0
        if hours > 0 and ownHours > 0 then return math.min(hours, ownHours) end
        if hours > 0 then return hours end
        return ownHours
    end

    return tonumber(expiry[ownership]) or 0
end
