-- Author: vyrriox
-- Canonical neon values shared by the capture, replication and persistence paths.
function Schema.neonState(properties)
    if type(properties) ~= 'table' or type(properties.neonEnabled) ~= 'table' then return nil end
    local state = { neonEnabled = {} }
    for index = 1, 4 do
        local value = properties.neonEnabled[index]
        if value == true or value == 1 then state.neonEnabled[index] = true
        elseif value == false or value == 0 then state.neonEnabled[index] = false
        else return nil end
    end
    if properties.neonColor ~= nil then
        if type(properties.neonColor) ~= 'table' then return nil end
        state.neonColor = {}
        for index = 1, 3 do
            local value = properties.neonColor[index]
            if type(value) ~= 'number' or value ~= value or value < 0 or value > 255
                or value % 1 ~= 0 then return nil end
            state.neonColor[index] = value
        end
    end
    return state
end

function Schema.sameNeons(left, right)
    left, right = Schema.neonState(left), Schema.neonState(right)
    if not left or not right then return false end
    for index = 1, 4 do
        if left.neonEnabled[index] ~= right.neonEnabled[index] then return false end
    end
    if (left.neonColor == nil) ~= (right.neonColor == nil) then return false end
    if left.neonColor then
        for index = 1, 3 do
            if left.neonColor[index] ~= right.neonColor[index] then return false end
        end
    end
    return true
end
