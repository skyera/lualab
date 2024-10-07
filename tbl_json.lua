
function tableToJson(tbl)
    local function serialize(obj)
        local objType = type(obj)
        
        if objType == "table" then
            local isArray = (#obj > 0)
            local result = {}
            
            if isArray then
                -- Array-like table (JSON array)
                for _, value in ipairs(obj) do
                    table.insert(result, serialize(value))
                end
                return "[" .. table.concat(result, ",") .. "]"
            else
                -- Object-like table (JSON object)
                for key, value in pairs(obj) do
                    local serializedKey = '"' .. tostring(key) .. '"'
                    table.insert(result, serializedKey .. ":" .. serialize(value))
                end
                return "{" .. table.concat(result, ",") .. "}"
            end
            
        elseif objType == "string" then
            return '"' .. obj:gsub('"', '\\"') .. '"'
        elseif objType == "number" or objType == "boolean" then
            return tostring(obj)
        elseif objType == "nil" then
            return "null"
        else
            error("Unsupported data type: " .. objType)
        end
    end
    
    return serialize(tbl)
end
local exampleTable = {
    name = "John",
    age = 30,
    isActive = true,
    hobbies = {"coding", "reading"},
    address = {city = "New York", zip = 10001}
}

local jsonString = tableToJson(exampleTable)
print(jsonString)
