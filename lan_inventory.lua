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

local function normalize_tags(tags)
    if type(tags) ~= "table" then return nil, "Tags must be an array" end
    local result, seen, count = {}, {}, 0
    for key, value in pairs(tags) do
        count = count + 1
        if type(key) ~= "number" or key < 1 or key > #tags or math.floor(key) ~= key or type(value) ~= "string" then
            return nil, "Tags must be an array of strings"
        end
    end
    if count ~= #tags or count > 8 then return nil, "Use at most eight tags" end
    for _, value in ipairs(tags) do
        value = value:match("^%s*(.-)%s*$")
        local characters = 0
        for _ in value:gmatch("[^\128-\191]") do characters = characters + 1 end
        if value == "" or characters < 1 or characters > 64 or value:find("[%z\1-\31\127]") then
            return nil, "Tags must contain 1–64 characters without control characters"
        end
        local key = value:lower()
        if not seen[key] then result[#result + 1], seen[key] = value, true end
    end
    return result
end

local EVENT_TYPES = {new_device = true, ip_changed = true, port_detected = true, port_opened = true, port_closed = true}
local MAX_EVENTS = 1000

local function new(path)
    local inventory = { path = path, devices = {}, events = {}, next_event_id = 1, writable = true }

    function inventory:record_event(kind, device, timestamp, details)
        local event = {id = self.next_event_id, type = kind, device_id = identity(device),
            hostname = device.hostname, ip = device.ip, timestamp = timestamp}
        for key, value in pairs(details or {}) do event[key] = value end
        self.next_event_id = self.next_event_id + 1
        self.events[#self.events + 1] = event
        if #self.events > MAX_EVENTS then table.remove(self.events, 1) end
    end

    function inventory:find(id)
        for _, device in ipairs(self.devices) do
            if identity(device) == id then return device end
        end
    end

    function inventory:update_metadata(id, trusted, tags)
        if type(id) ~= "string" or type(trusted) ~= "boolean" then return nil, "An id and a boolean trusted flag are required", "invalid" end
        local normalized, err = normalize_tags(tags)
        if not normalized then return nil, err, "invalid" end
        local device = self:find(id)
        if not device then return nil, "Device not found", "missing" end
        local old_trusted, old_tags = device.trusted, device.tags
        device.trusted, device.tags = trusted, normalized
        local ok, save_error = self:save()
        if not ok then
            device.trusted, device.tags = old_trusted, old_tags
            return nil, save_error, "storage"
        end
        return device
    end

    -- Only the ports in this probe's scope can change their recorded observation.
    function inventory:update_ports(device, open_ports, checked_ports, timestamp)
        local current, checks, opened, checked = {}, device.port_checks or {}, {}, {}
        for _, port in ipairs(device.ports or {}) do
            current[port.port] = port
            if checks[tostring(port.port)] == nil then checks[tostring(port.port)] = true end
        end
        for _, port in ipairs(open_ports) do opened[port.port] = port end
        for _, port in ipairs(checked_ports) do
            local number = type(port) == "table" and port.port or port
            if not checked[number] then
                checked[number] = true
                local key, available = tostring(number), opened[number] ~= nil
                local before = checks[key]
                if available and before ~= true then
                    self:record_event(before == false and "port_opened" or "port_detected", device, timestamp,
                        {port = number, service = opened[number].name})
                elseif not available and before == true then
                    self:record_event("port_closed", device, timestamp,
                        {port = number, service = current[number] and current[number].name or ("Port " .. number)})
                end
                checks[key] = available
                current[number] = opened[number]
            end
        end
        local ports = {}
        for _, port in pairs(current) do ports[#ports + 1] = port end
        table.sort(ports, function(a, b) return a.port < b.port end)
        device.ports, device.port_count, device.port_checks = ports, #ports, checks
    end

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
        local records, seen, events = {}, {}, {}
        if ok then
            for _, device in ipairs(data.devices) do
                if type(device) ~= "table" or type(device.ip) ~= "string" or
                   not device.ip:match("^%d+%.%d+%.%d+%.%d+$") or
                   type(device.first_seen) ~= "number" or type(device.last_seen) ~= "number" or
                   (device.mac ~= nil and type(device.mac) ~= "string") or
                   type(device.hostname) ~= "string" or type(device.vendor) ~= "string" or
                   type(device.category) ~= "string" or type(device.type_name) ~= "string" or
                   type(device.ports) ~= "table" or
                   (device.trusted ~= nil and type(device.trusted) ~= "boolean") or
                   (device.tags ~= nil and type(device.tags) ~= "table") or
                   (device.port_checks ~= nil and type(device.port_checks) ~= "table") or
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
                local tags = normalize_tags(device.tags or {})
                if not tags then ok = false; break end
                for port, available in pairs(device.port_checks or {}) do
                    local number = tonumber(port)
                    if type(port) ~= "string" or not number or number < 1 or number > 65535 or
                       number ~= math.floor(number) or type(available) ~= "boolean" then ok = false end
                end
                if not ok then break end
                local key = identity(device)
                if seen[key] then ok = false; break end
                seen[key] = true
                device.status = "unchecked"
                device.is_local_host = false
                device.mac = device.mac or ""
                device.id, device.trusted, device.tags = key, device.trusted == true, tags
                records[#records + 1] = device
            end
            for key in pairs(data.devices) do
                if type(key) ~= "number" or key < 1 or key > #records then ok = false end
            end
        end
        local highest = 0
        if ok and data.events ~= nil then
            if type(data.events) ~= "table" or #data.events > MAX_EVENTS then ok = false
            else
                for _, event in ipairs(data.events) do
                    if type(event) ~= "table" or type(event.id) ~= "number" or event.id <= highest or
                       event.id ~= math.floor(event.id) or not EVENT_TYPES[event.type] or
                       type(event.device_id) ~= "string" or type(event.hostname) ~= "string" or
                       type(event.ip) ~= "string" or type(event.timestamp) ~= "number" or event.timestamp < 0 or
                       (event.type == "ip_changed" and (type(event.old_ip) ~= "string" or type(event.new_ip) ~= "string")) or
                       (event.type:match("^port_") and (type(event.port) ~= "number" or event.port < 1 or event.port > 65535 or
                           event.port ~= math.floor(event.port) or type(event.service) ~= "string")) then
                        ok = false; break
                    end
                    highest = event.id
                    events[#events + 1] = event
                end
                for key in pairs(data.events) do
                    if type(key) ~= "number" or key < 1 or key > #events then ok = false end
                end
            end
        end
        if ok and data.next_event_id ~= nil then
            if type(data.next_event_id) ~= "number" or data.next_event_id <= highest or data.next_event_id ~= math.floor(data.next_event_id) then ok = false
            else highest = data.next_event_id - 1 end
        end
        if not ok then
            self.writable = false
            return nil, "Invalid inventory; original file preserved"
        end
        self.devices = records
        self.events, self.next_event_id = events, highest + 1
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
                device.id, device.trusted, device.tags = key, old and old.trusted == true or false, old and old.tags or {}
                local probed = device.ports
                if old then
                    if old.is_custom and not device.is_custom then
                        device.hostname, device.is_custom = old.hostname, true
                    end
                    device.ports, device.port_count, device.port_checks = old.ports, #old.ports, old.port_checks
                    if old.ip ~= device.ip then
                        self:record_event("ip_changed", device, timestamp, {old_ip = old.ip, new_ip = device.ip})
                    end
                else
                    self:record_event("new_device", device, timestamp)
                    device.ports = {}
                end
                if ports_probed and device.status == "online" then
                    local scope = device.probed_ports
                    if not scope then
                        scope = {}
                        for _, port in ipairs(device.ports) do scope[#scope + 1] = port end
                        for _, port in ipairs(probed) do scope[#scope + 1] = port end
                    end
                    self:update_ports(device, probed, scope, timestamp)
                elseif not old then
                    device.ports, device.port_count = probed, #probed
                end
                device.probed_ports = nil
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
        local ok, content = pcall(json.encode, { version = 1, devices = self.devices, events = self.events, next_event_id = self.next_event_id })
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

return { new = new, identity = identity, normalize_tags = normalize_tags, MAX_EVENTS = MAX_EVENTS }
