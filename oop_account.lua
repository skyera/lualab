#!/usr/bin/env luajit
local string_format = string.format
local type = type
local setmetatable = setmetatable

local Account = {}
Account.__index = Account

local next_account_id = 1001


function Account:new(initial_balance, id)
    local instance = setmetatable({}, self)

    instance.id = id or ("ACC-" .. next_account_id)
    if not id then
        next_account_id = next_account_id + 1
    end
    instance.balance = (type(initial_balance) == "number" and initial_balance >= 0) and initial_balance or 0
    return instance
end

function Account:get_balance()
    return self.balance
end

function Account:report()
    print(string_format("[%s] Current balance: %.2f", self.id, self.balance))
end

function Account:deposit(amount)
    if type(amount) ~= "number" or amount <= 0 then
        return false, "Deposit amount must be a positive number"
    end
    self.balance = self.balance + amount
    return true, self.balance
end

function Account:withdraw(amount)
    if type(amount) ~= "number" or amount <= 0 then
        return false, "Withdraw amount must be a positive number"
    end

    if amount > self.balance then
        return false, string_format("Insufficient funds (balance: %.2f, requested: %.2f)", self.balance, amount)
    end

    self.balance = self.balance - amount
    return true, self.balance
end

function Account:__tostring()
    return string_format("Account(%s, balance: %.2f)", self.id, self.balance)
end

function Account:transfer(amount, target)
    if not target or type(target.deposit) ~= "function" then
        return false, "Invalid target account for transfer"
    end

    local ok, err = self:withdraw(amount)
    if not ok then
        return false, "Transfer failed: " .. err
    end
    target:deposit(amount)
    return true, self.balance
end

local SavingAccount = setmetatable({}, {__index=Account})
SavingAccount.__index = SavingAccount

local next_saving_id = 2001

local acc = Account:new(9000)
acc:withdraw(200)
acc:report()
print(acc)
