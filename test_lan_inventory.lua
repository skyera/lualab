local module = require("lan_inventory")
local json = require("json")
local path = os.tmpname()
os.remove(path)

local function device(ip, mac, name)
    return { ip = ip, mac = mac, hostname = name or "NAS", vendor = "Vendor",
        category = "linux", type_name = "Linux", status = "online", ports = {}, latency_ms = 1 }
end

local function read_file(file_path)
    local f = assert(io.open(file_path, "r"))
    local content = f:read("*a")
    f:close()
    return content
end

local inventory = module.new(path)
assert(inventory:load())
local original = device("192.168.1.18", "AA:BB:CC:DD:EE:01", 'NAS "office" \\ 日本\n')
original.is_custom = true
original.ports = {{port = 443, name = "HTTPS"}}
inventory:merge({original}, 100, true)
assert(original.first_seen == 100 and original.last_seen == 100)
assert(inventory:save())
assert(not io.open(path .. ".tmp", "r"))
local saved = json.decode(read_file(path))
assert(saved.version == 1 and saved.devices[1].hostname == original.hostname)

local restarted = module.new(path)
assert(restarted:load())
assert(restarted.devices[1].status == "unchecked")
assert(restarted.devices[1].first_seen == 100)
local moved = device("192.168.1.20", "aa-bb-cc-dd-ee-01", "host-new")
local aliases, cache = {[original.ip] = original.hostname}, {[original.ip] = original.hostname}
assert(restarted:migrate_aliases({moved}, aliases, cache))
assert(aliases[moved.ip] == original.hostname and aliases[original.ip] == nil)
assert(cache[moved.ip] == original.hostname and cache[original.ip] == nil)
restarted:merge({moved}, 200, false)
assert(#restarted.devices == 1 and moved.first_seen == 100 and moved.last_seen == 200)
assert(moved.hostname == original.hostname and moved.is_custom)
assert(moved.ports[1].port == 443 and moved.port_count == 1)

restarted:merge({}, 300, false)
assert(#restarted.devices == 1 and moved.status == "not_observed" and moved.last_seen == 200)
local replacement = device(moved.ip, "aa:bb:cc:dd:ee:02", "Replacement")
aliases, cache = {[moved.ip] = moved.hostname}, {[moved.ip] = moved.hostname}
assert(restarted:migrate_aliases({replacement}, aliases, cache))
assert(aliases[moved.ip] == nil and cache[moved.ip] == nil)
restarted:merge({replacement}, 400, false)
assert(#restarted.devices == 2 and replacement.first_seen == 400)
assert(replacement.hostname == "Replacement" and not replacement.is_custom)
local returning = device("192.168.1.21", original.mac)
restarted:merge({returning, replacement}, 500, true)
assert(#restarted.devices == 2 and returning.first_seen == 100 and returning.last_seen == 500)
assert(#returning.ports == 0) -- A completed probe can remove stale services.
assert(restarted:save())

local swap = module.new(path)
local a, b = device("192.168.1.10", "aa:bb:cc:dd:ee:10", "A"), device("192.168.1.11", "aa:bb:cc:dd:ee:11", "B")
a.is_custom, b.is_custom = true, true
swap:merge({a, b}, 100, false)
aliases, cache = {[a.ip] = "A", [b.ip] = "B"}, {}
assert(swap:migrate_aliases({device(b.ip, a.mac), device(a.ip, b.mac)}, aliases, cache))
assert(aliases[a.ip] == "B" and aliases[b.ip] == "A")

local fallback = module.new(path .. ".fallback")
fallback:merge({device("192.168.1.30", "00:00:00:00:00:00")}, 100, false)
fallback:merge({device("192.168.1.30", nil)}, 200, false)
assert(#fallback.devices == 1 and fallback.devices[1].first_seen == 100)
local randomized = device("192.168.1.30", "02:00:00:00:00:01")
fallback:merge({randomized}, 300, false)
assert(#fallback.devices == 2) -- Different identities are not guessed to be the same device.

local before = read_file(path)
restarted.devices[1].bad = function() end
assert(not restarted:save())
assert(read_file(path) == before)
restarted.devices[1].bad = nil
local impossible = module.new(path .. "/missing/inventory.json")
assert(not impossible:save())

for _, content in ipairs({'{broken', '{"version":2,"devices":[]}',
    '{"version":1,"devices":[{"ip":"bad"}]}', '{"version":1,"devices":{"bad":{}}}'}) do
    local f = assert(io.open(path, "w"))
    assert(f:write(content)); assert(f:close())
    local corrupt = module.new(path)
    assert(not corrupt:load())
    corrupt:merge({device("192.168.1.10", original.mac)}, 600, false)
    assert(not corrupt:save())
    assert(read_file(path) == content)
end
for _, mutation in ipairs({
    function(d) d.ip = "192.168.999.1" end,
    function(d) d.ports = {"invalid"} end,
    function(d) d.ports = {{port = 65536, name = "Invalid"}} end,
    function(d) d.last_seen = -1 end,
    function(d) d.hardware = false end
}) do
    local invalid = device("192.168.1.20", original.mac)
    invalid.first_seen, invalid.last_seen = 100, 200
    mutation(invalid)
    local content = json.encode({version = 1, devices = {invalid}})
    local f = assert(io.open(path, "w")); assert(f:write(content)); assert(f:close())
    local corrupt = module.new(path)
    assert(not corrupt:load())
    assert(not corrupt:save() and read_file(path) == content)
end
local empty = module.new(path)
assert(empty:save())
assert(module.new(path):load())
os.remove(path)
print("Persistent inventory: merge, restart, aliases, IP reuse, ports, corruption, and write failures PASS")
