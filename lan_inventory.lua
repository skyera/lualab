-- Persistent inventory; scans and UI consume the same device records.
local json = require("json")
local ffi = require("ffi")
local replace = os.rename
if ffi.os == "Windows" then
    ffi.cdef[[int MoveFileExA(const char *existing, const char *replacement, unsigned long flags);]]
    local kernel = ffi.load("kernel32")
    replace = function(source, destination)
        if kernel.MoveFileExA(source, destination, 9) ~= 0 then return true end
        return nil, "MoveFileExA failed"
    end
end

local function identity(device)
    local mac = (device.mac or ""):lower():gsub("-", ":")
    if mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") and
       mac ~= "00:00:00:00:00:00" and mac ~= "ff:ff:ff:ff:ff:ff" then
        return "mac:" .. mac
    end
    return "ip:" .. device.ip
end

local function new(path)
    local inventory = { path = path, devices = {}, writable = true }

    function inventory:migrate_aliases(entries, aliases, hostname_cache)
        local current_ips, occupants, changed = {}, {}, false
        for _, entry in ipairs(entries) do
            local key = identity(entry)
            current_ips[key], occupants[entry.ip] = entry.ip, key
        end
        for _, old in ipairs(self.devices) do
            local key = identity(old)
            local current_ip = current_ips[key]
            if old.is_custom then
                local reused = occupants[old.ip] and occupants[old.ip] ~= key
                if ((current_ip and current_ip ~= old.ip) or reused) and aliases[old.ip] == old.hostname then
                    aliases[old.ip], hostname_cache[old.ip] = nil, nil
                    changed = true
                end
            end
        end
        for _, old in ipairs(self.devices) do
            local current_ip = current_ips[identity(old)]
            if old.is_custom and current_ip and not aliases[current_ip] then
                aliases[current_ip], hostname_cache[current_ip] = old.hostname, old.hostname
                changed = true
            end
        end
        return changed
    end

    function inventory:load()
        local file, err, code = io.open(self.path, "r")
        if not file then
            if code == 2 then return true end -- New inventory.
            self.writable = false
            return nil, err
        end
        local content = file:read("*a")
        file:close()
        local ok, data = pcall(json.decode, content)
        if ok then
            ok = type(data) == "table" and data.version == 1 and type(data.devices) == "table"
        end
        local records, seen = {}, {}
        if ok then
            for _, device in ipairs(data.devices) do
                if type(device) ~= "table" or type(device.ip) ~= "string" or
                   not device.ip:match("^%d+%.%d+%.%d+%.%d+$") or
                   type(device.first_seen) ~= "number" or type(device.last_seen) ~= "number" or
                   (device.mac ~= nil and type(device.mac) ~= "string") or
                   type(device.hostname) ~= "string" or type(device.vendor) ~= "string" or
                   type(device.category) ~= "string" or type(device.type_name) ~= "string" or
                   type(device.ports) ~= "table" or
                   (device.hardware ~= nil and type(device.hardware) ~= "table") or
                   device.first_seen < 0 or device.last_seen < device.first_seen then
                    ok = false
                    break
                end
                for octet in device.ip:gmatch("%d+") do
                    if tonumber(octet) > 255 then ok = false end
                end
                for _, port in ipairs(device.ports) do
                    if type(port) ~= "table" or type(port.port) ~= "number" or
                       port.port < 1 or port.port > 65535 or port.port ~= math.floor(port.port) or
                       type(port.name) ~= "string" then ok = false; break end
                end
                for port_key in pairs(device.ports) do
                    if type(port_key) ~= "number" or port_key < 1 or port_key > #device.ports then ok = false end
                end
                if not ok then break end
                local key = identity(device)
                if seen[key] then ok = false; break end
                seen[key] = true
                device.status = "unchecked"
                device.is_local_host = false
                device.mac = device.mac or ""
                records[#records + 1] = device
            end
            for key in pairs(data.devices) do
                if type(key) ~= "number" or key < 1 or key > #records then ok = false end
            end
        end
        if not ok then
            self.writable = false
            return nil, "Invalid inventory; original file preserved"
        end
        self.devices = records
        self.writable = true
        return true
    end

    function inventory:merge(scan, timestamp, ports_probed)
        local previous, observed, result = {}, {}, {}
        for _, device in ipairs(self.devices) do previous[identity(device)] = device end
        for _, device in ipairs(scan) do
            local key = identity(device)
            local old = previous[key]
            if not observed[key] then
                observed[key] = true
                device.first_seen = old and old.first_seen or timestamp
                device.last_seen = timestamp
                if old then
                    if old.is_custom and not device.is_custom then
                        device.hostname, device.is_custom = old.hostname, true
                    end
                    if not ports_probed or device.status ~= "online" then
                        device.ports = old.ports
                        device.port_count = #device.ports
                    end
                end
                result[#result + 1] = device
            end
        end
        for _, device in ipairs(self.devices) do
            if not observed[identity(device)] then
                device.status = "not_observed"
                device.is_local_host = false
                result[#result + 1] = device
            end
        end
        self.devices = result
        return result
    end

    function inventory:save()
        if not self.writable then return nil, "Inventory saving disabled: fix the unreadable or invalid file and restart" end
        local ok, content = pcall(json.encode, { version = 1, devices = self.devices })
        if not ok then return nil, content end
        if content == self.saved_content then return true end
        local temporary = self.path .. ".tmp"
        local file, err = io.open(temporary, "w")
        if not file then return nil, err end
        local written, write_err = file:write(content .. "\n")
        local closed, close_err = file:close()
        if not written or not closed then
            os.remove(temporary)
            return nil, write_err or close_err
        end
        local replaced, replace_err = replace(temporary, self.path)
        if not replaced then os.remove(temporary); return nil, replace_err end
        self.saved_content = content
        return true
    end

    return inventory
end

return { new = new, identity = identity }
