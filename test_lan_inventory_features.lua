local module = require("lan_inventory")
local json = require("json")
local path = os.tmpname()
os.remove(path)
local function device(ip, mac)
    return {ip = ip, mac = mac, hostname = 'NAS "日本"', vendor = "Test", category = "linux",
        type_name = "Linux", status = "online", ports = {}, latency_ms = 1}
end
local function contents()
    local file = assert(io.open(path, "r"))
    local value = file:read("*a"); file:close(); return value
end

local inventory = module.new(path)
local original = device("192.168.1.18", "aa:bb:cc:dd:ee:01")
inventory:merge({original}, 100, false)
assert(#inventory.events == 1 and inventory.events[1].type == "new_device")
assert(original.trusted == false and #original.tags == 0 and original.id == module.identity(original))
local updated = assert(inventory:update_metadata(original.id, true, {" Office ", "Storage", "office", "日本 <camera>"}))
assert(updated.trusted and #updated.tags == 3 and updated.tags[1] == "Office")
local saved = contents()
for _, tags in ipairs({false, {""}, {"bad\nline"}, {string.rep("x", 65)}, {42}, {bad = "label"},
    {"1", "2", "3", "4", "5", "6", "7", "8", "9"}}) do
    local value, _, reason = inventory:update_metadata(original.id, false, tags)
    assert(not value and reason == "invalid")
    assert(original.trusted and contents() == saved)
end
assert(not inventory:update_metadata(original.id, "true", {}))
local value, _, reason = inventory:update_metadata("mac:00:11:22:33:44:55", true, {})
assert(not value and reason == "missing")
inventory.writable = false
local _, _, failure = inventory:update_metadata(original.id, false, {"Changed"})
assert(failure == "storage" and original.trusted and original.tags[1] == "Office")
inventory.writable = true

local restarted = module.new(path)
assert(restarted:load())
assert(restarted.devices[1].trusted and #restarted.devices[1].tags == 3)
assert(#restarted.events == 1 and restarted.next_event_id == 2)
local moved = device("192.168.1.20", "AA-BB-CC-DD-EE-01")
moved.trusted, moved.tags = false, {"Worker stale label"}
restarted:merge({moved}, 200, false)
assert(moved.trusted and moved.tags[1] == "Office")
assert(#restarted.events == 2 and restarted.events[2].type == "ip_changed")
assert(restarted.events[2].old_ip == original.ip and restarted.events[2].new_ip == moved.ip)
restarted:merge({device(moved.ip, moved.mac)}, 201, false)
assert(#restarted.events == 2) -- Repeated scans and restarts do not invent new discoveries.
restarted:merge({}, 202, false)
assert(#restarted.events == 2 and restarted.devices[1].trusted)
local replacement = device(moved.ip, "aa:bb:cc:dd:ee:02")
restarted:merge({replacement}, 203, false)
assert(not replacement.trusted and #replacement.tags == 0 and #restarted.events == 3)
assert(restarted:find(original.id).trusted) -- Trust is not transferred with a reused IP.

local port_device = restarted:find(original.id)
restarted:update_ports(port_device, {{port = 443, name = "HTTPS"}}, {443, 22}, 210)
assert(restarted.events[#restarted.events].type == "port_detected")
local count = #restarted.events
restarted:update_ports(port_device, {{port = 443, name = "HTTPS"}}, {443, 22}, 211)
assert(#restarted.events == count)
restarted:update_ports(port_device, {{port = 22, name = "SSH"}}, {22}, 212)
assert(restarted.events[#restarted.events].type == "port_opened")
assert(#port_device.ports == 2) -- Partial probes preserve unrelated services.
restarted:update_ports(port_device, {}, {443}, 213)
assert(restarted.events[#restarted.events].type == "port_closed" and #port_device.ports == 1)
restarted:update_ports(port_device, {{port = 443, name = "HTTPS"}}, {443}, 214)
assert(restarted.events[#restarted.events].type == "port_opened")
count = #restarted.events
restarted:merge({device(port_device.ip, port_device.mac)}, 215, false)
assert(#restarted.events == count and #restarted:find(original.id).ports == 2)
assert(restarted:save())
local reloaded = module.new(path)
assert(reloaded:load())
assert(reloaded:find(original.id).port_checks["443"] == true and #reloaded.events == count)

for i = 1, module.MAX_EVENTS + 10 do reloaded:record_event("new_device", original, 300 + i) end
assert(#reloaded.events == module.MAX_EVENTS)
local latest_id = reloaded.events[#reloaded.events].id
assert(reloaded:save())
local bounded = module.new(path)
assert(bounded:load())
assert(#bounded.events == module.MAX_EVENTS and bounded.next_event_id == latest_id + 1)

-- Legacy files load without generating retrospective events.
original.trusted, original.tags, original.port_checks, original.id = nil, nil, nil, nil
local file = assert(io.open(path, "w"))
assert(file:write(json.encode({version = 1, devices = {original}}))); file:close()
local legacy = module.new(path)
assert(legacy:load() and #legacy.events == 0 and not legacy.devices[1].trusted)
assert(#legacy.devices[1].tags == 0)
legacy:merge({device(original.ip, original.mac)}, 400, false)
assert(#legacy.events == 0)
local invalid_documents = {
    {version = 1, devices = {}, events = {{id = 1, type = "unknown"}}},
    {version = 1, devices = {}, events = {bad = true}},
    {version = 1, devices = {}, next_event_id = 0},
}
for _, document in ipairs(invalid_documents) do
    local content = json.encode(document)
    file = assert(io.open(path, "w")); file:write(content); file:close()
    local invalid = module.new(path)
    assert(not invalid:load() and not invalid:save() and contents() == content)
end
os.remove(path)
print("Inventory timeline and metadata: persistence, validation, DHCP/IP reuse, scoped ports, deduplication, and bounded history PASS")
