-- Parse complete, bounded TCP port scopes without silently truncating ranges.
local MAX_PORTS = 4096
local function parse(specification)
    if type(specification) ~= "string" or #specification > 4096 then return nil, "Invalid port specification" end
    local ports, seen = {}, {}
    for token in (specification .. ","):gmatch("(.-),") do
        token = token:match("^%s*(.-)%s*$")
        local first, last = token:match("^(%d+)%s*%-%s*(%d+)$")
        if not first and token:match("^%d+$") then first, last = token, token end
        first, last = tonumber(first), tonumber(last)
        if not first or not last or first < 1 or last > 65535 or first > last then
            return nil, "Use ports 1–65535 and ascending ranges (for example 5000-6000,8000-9000)"
        end
        for port = first, last do
            if not seen[port] then
                if #ports == MAX_PORTS then return nil, "A probe can check at most " .. MAX_PORTS .. " distinct ports" end
                seen[port] = true
                ports[#ports + 1] = {port = port, name = "Port " .. port}
            end
        end
    end
    return ports
end
return {parse = parse, MAX_PORTS = MAX_PORTS, PRESETS = {"5000-6000", "8000-9000", "5000-6000,8000-9000"}}
