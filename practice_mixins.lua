#!/usr/bin/env luajit
-- ============================================================================
-- Practice: Mixins & COmposition in Lua
--
-- Mixin 1: Loggable (Adds logging capabilities)
local Loggable = {}

function Loggable:log(message)
    local id_str = self.id or "Unknown"
    print(string.format("[LOG][%s] %s", id_str, message))
end

-- Mixin 2: Serializable (Adds JSON serialization)
local Serializable = {}

function Serializable:to_json()
    local parts = {}
    for k, v in pairs(self) do
        if type(v) == "string" then
            table.insert(parts, string.format("\"%s\":\"%s\"", k, v))
        elseif type(v) == "number" or type(v) == "boolean" then
            table.insert(parts, string.format("\"%s\":%s", k, tostring(v)))
        end
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

-- Class: Order (Uses both Loggable and Serializable)
local Order = {}
Order.__index = Order

function Order:include(mixin)
    for name, method in pairs(mixin) do
        if type(method) == "function" then
            self[name] = method
        end
    end
    return self
end

-- Mix in both capabilities
Order:include(Loggable):include(Serializable)

function Order:new(id, customer, total)
    local instance = setmetatable({}, self)
    instance.id = id
    instance.customer = customer
    instance.total = total
    instance.status = "PENDING"
    return instance
end

function Order:pay()
    self.status = "PAID"
    self:log("Payment confirmed for $" .. self.total)
end

local order = Order:new("ORD-101", "Alice", 89.99)
order:log("Order created")
order:pay()
print("\nJSON Export:")
print(order:to_json())
