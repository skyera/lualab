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

function SavingAccount:new(initial_balance, interest_rate, overdraft_limit, id)
    local instance = Account.new(self, initial_balance, id or ("SAV-" .. next_saving_id))
    if not id then
        next_saving_id = next_saving_id + 1
    end
    instance.interest_rate = interest_rate or 0.05
    instance.overdraft_limit = overdraft_limit or 0
    return instance
end

function SavingAccount:accure_interest()
    local interest = self.balance * self.interest_rate
    if interest > 0 then
        self.balance = self.balance + interest
    end
    return interest
end

function SavingAccount:withdraw(amount)
    if type(amount) ~= "number" or amount <= 0 then
        return false, "Withdraw amount must be a positive number"
    end
    local available = self.balance + self.overdraft_limit
    if amount > available then
        return false, string_format("Exceeds overdraft limit (available: %.2f, request: %.2f)", available, amount)
    end
    self.balance = self.balance - amount
    return true, self.balance
end

function SavingAccount:__tostring()
    return string_format("SavingAccount(%s, balance: %.2f, limit: %.2f)", self.id, self.balance, self.overdraft_limit)
end

local acc = Account:new(9000)
acc:withdraw(200)
acc:report()
print(acc)

local sav = SavingAccount:new(1000, 0.05, 500)
print(sav)
sav:deposit(200)
print("Deposited $200 -> New balance: $" .. string_format("%.2f", sav:get_balance()))

local interest = sav:accure_interest()
print("Accrued 5% interest: +$" .. string_format("%.2f", interest))
print("Balance after interest: $" .. string_format("%.2f", sav:get_balance()))

print("Attempting to withdraw $1,400 (Current balance is $" .. string_format("%.2f", sav:get_balance()) .. ")...")
local ok1, err1 = sav:withdraw(1400)
if ok1 then
    print("[Approved] Balance went negative: $" .. string_format("%.2f", sav:get_balance()))
else
    print("[Rejected] " .. err1)
end

print("Attempting to withdraw $400.00 (Available limit is $" .. string_format("%.2f", sav.balance + sav.overdraft_limit) .. ")...")
local ok2, err2 = sav:withdraw(400)
if ok2 then
    print("[Approved] Balance: $" .. string_format("%.2f", sav:get_balance()))
else
    print("[Rejected] as expected: " .. err2)
end

local checking = Account:new(5000)
print("Before transfer")
print("Source:", checking)
print("Target:", sav)

local ok3, err3 = checking:transfer(800, sav)
if ok3 then
    print("[Success] Transfer complete!")
    print("Source:", checking)
    print("Target:", sav)
else
    print("[Failed] " .. err3)
end

return {
    Account = Account,
    SavingAccount = SavingAccount
}
