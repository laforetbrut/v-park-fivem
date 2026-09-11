-- Author: vyrriox
-- Track complete neon selections on the current network owner. Reapply only on acquisition
-- or an engine transition, never in a permanent loop that fights a mechanic's edits.
local sessions = {}

local function owns(entity)
    if not DoesEntityExist(entity) then return false end
    local control = NetworkHasControlOfEntity(entity)
    return NetworkGetEntityOwner(entity) == PlayerId()
        and (control == true or control == 1)
end

local function engineState(entity)
    local value = GetIsVehicleEngineRunning(entity)
    return value == true or value == 1
end

function Properties.forgetNeons(id)
    sessions[id] = nil
end

function Properties.rememberNeons(id, entity, properties, ready)
    sessions[id] = {entity=entity, confirmed=Schema.neonState(properties) or Properties.captureNeons(entity),
        published=Schema.neonState(properties), ready=ready == true, engine=engineState(entity)}
end

function Properties.savedNeons(id, entity)
    local session = sessions[id]
    if not session or session.entity ~= entity or not session.ready or session.busy
        or not owns(entity) then return nil end
    return Schema.neonState(session.confirmed)
end

local function restore(id, session, wanted)
    if session.busy or (session.attempts or 0) >= 3 then return end
    session.busy = true
    session.ready = false
    session.attempts = (session.attempts or 0) + 1
    CreateThread(function()
        -- The identity check invalidates an outstanding retry after forget or ownership loss.
        local ok, applied = pcall(Properties.applyNeons, session.entity, wanted, true, function()
            return sessions[id] == session and owns(session.entity)
        end)
        if sessions[id] ~= session then return end
        session.busy = false
        session.retryAt = Park.ticks() + 2000
        if not ok then Park.warn('neon restore for %s raised: %s', id, tostring(applied)) end
        if not ok or not applied or not owns(session.entity) then return end
        session.confirmed = Schema.neonState(wanted)
        session.engine = engineState(session.entity)
        session.pending = nil
        session.ready = true
        TriggerServerEvent('vpark:server:verified', id, 'neons',
            NetworkGetNetworkIdFromEntity(session.entity), session.confirmed)
    end)
end

function Properties.observeNeons(id, entity, changed)
    if not Schema.enabled('neons') or not owns(entity) then
        sessions[id] = nil
        return
    end
    local state = Entity(entity).state
    -- The placing client owns the initial transaction through the restore acknowledgment.
    if state['vpark:hold'] then return end
    local published = state['vpark:neons']
    local wanted = Schema.neonState(published)
    local current = Properties.captureNeons(entity)
    if not current then return end
    local session = sessions[id]
    if not session or session.entity ~= entity then
        -- Entity and statebags can arrive in either order. False explicitly means no saved group;
        -- nil means the authoritative selection has not arrived, so defaults are not publishable.
        if not wanted and published ~= false then return end
        session = {entity=entity, published=wanted, engine=engineState(entity)}
        sessions[id] = session
        if wanted then restore(id, session, wanted); return end
        session.ready, session.confirmed = true, current
    end
    if session.busy then return end
    if not session.ready then
        if wanted and Park.ticks() >= (session.retryAt or 0) then restore(id, session, wanted) end
        return
    end
    if wanted and not Schema.sameNeons(wanted, session.published) then
        session.published = wanted
        if not Schema.sameNeons(wanted, session.confirmed) then
            session.attempts = 0
            restore(id, session, wanted)
            return
        end
    end
    local engine = engineState(entity)
    if engine ~= session.engine then
        session.engine = engine
        session.pending = nil
        if not Schema.sameNeons(current, session.confirmed) then
            session.attempts = 0
            restore(id, session, session.confirmed)
            return
        end
    end
    if Schema.sameNeons(current, session.confirmed) then session.pending = nil; return end
    -- Capture a stable switch/RGB selection, including colour-only edits and all-off states.
    if not Schema.sameNeons(current, session.pending) then
        session.pending, session.pendingAt = current, Park.ticks()
        return
    end
    if Park.ticks() - session.pendingAt < 500 then return end
    session.confirmed = current
    session.pending = nil
    session.attempts = 0
    changed(id)
end
