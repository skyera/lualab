#!/usr/bin/env luajit
-- ============================================================================
-- Part 1: The Silent Typo Bug (Vulnerable Class)
--
local VulnerableAccount = {}
VulnerableAccount.__index = VulnerableAccount

function VulnerableAccount:new(id, balance)
    local instance = setmetatable({}, self)
    instance.id = id
    instance.balance = balance or 0
    return instance
end

function VulnerableAccount:deposit(amount)
    self.balence = self.balance + amount
end

local acc1 = VulnerableAccount:new("ACC-001", 100)
print("Initial balance:", acc1.balance)
acc1:deposit(50)
print("Balance after deposit (BUG!):", acc1.balance)
print("Ghost typo field created: ", acc1.balence)

print("\n=====================================================================\n")
print("Part 2: The Guard CLas with __newindex (Catches Typos!)")
local GuardedAccount = {}
GuardedAccount.__index = GuardedAccount

function GuardedAccount:new(id, balance)
    local instance = {
        id = id,
        balance = balance or 0,
    }

    local mt = {
        __index = GuardedAccount,

        __newindex = function(tbl, key, value)
            error(string.format("Type Error: Field '%s' does not exist on GuardedAccount!", key), 2)
        end
    }
    return setmetatable(instance, mt)
end

function GuardedAccount:deposit(amount)
    self.balance = self.balance + amount
end

local acc2 = GuardedAccount:new("ACC-002", 200)
acc2:deposit(50)
print("Valid deposit: balance is now", acc2.balance)

print("\nAttempting to write type field 'acc2.balence = 999' ...")
local ok, err = pcall(function()
    acc2.balence = 999
end)

if not ok then
    print("[CAUGHT TYPO!]")
    print(err)
end
