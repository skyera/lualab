#!/usr/bin/env luajit

local oop = require("oop_account")
local Account = oop.Account
local SavingAccount = oop.SavingAccount

local tests_run = 0
local tests_passed = 0

local function check(condition, desc)
    tests_run = tests_run + 1
    if condition then
        tests_passed = tests_passed + 1
        print(string.format("  [PASS] %s", desc))
    else
        print(string.format("  [FAIL] %s", desc))
        error("Assertion failed: " .. desc)
    end
end

-- Test 1: Account instantiation & ID Generation
print("\nTest 1: Acccount Instantiation & ID Generation")
do
    local a1 = Account:new(1000)
    check(a1:get_balance() == 1000, "Initial balance initialized to 1000")
end

-- Test 2: Deposit & Input Validation
print("\nTest 2: Deposit & Input Validation")
do
    local a = Account:new(500)
    local ok1, bal1 = a:deposit(250)
    check(ok1 == true and bal1 == 750 and a:get_balance() == 750, "Deposit $250 increases balance to $750")

    local ok_neg, err_neg = a:deposit(-50)
    check(ok_neg == false and a:get_balance() == 750, "Negative deposit rejected without modifying balance")

    local ok_zero, _ = a:deposit(0)
    check(ok_zero == false, "Zero deposit rejected")

    local ok_str, _ = a:deposit("invalid")
    check(ok_str == false, "Non-number deposit rejected safely")
end

-- Test 3: Withdrawl & Overdraft Protection (Base Account)
print("\nTest 3: Withdrawl & Overdraft Protection (Base Account)")
do
    local a = Account:new(500)
    local ok1, bal1 = a:withdraw(200)
    check(ok1 == true and bal1 == 300, "Withdrawal of $200 leaves $300 balance")

    local ok_over, err_over = a:withdraw(400)
    check(ok_over == false, "Overdraft rejected on base Account")
    check(a:get_balance() == 300, "Balance remains $300 after rejected withdrawal")
    check(type(err_over) == "string", "Returns informative error message on failure")
end

-- Test 4: Inter-Account Transfer (Atomic Messaging)
print("\nTest 4: Inter-Account Transfer")
do
    local src = Account:new(1000)
    local dst = Account:new(200)

    local ok_tx, _ = src:transfer(400, dst)
    check(ok_tx == true, "Transfer succeeds")
    check(src:get_balance() == 600, "Source debited by $400")
    check(dst:get_balance() == 600, "Destination credited by $400")

    local ok_fail, _ = src:transfer(9000, dst)
    check(ok_fail == false, "Transfer fails on insufficient funds")
    check(src:get_balance() == 600 and dst:get_balance() == 600, "Neither account modified on failed transfer")

    local ok_bad, _ = src:transfer(100, {})
    check(ok_bad == false, "Transfer rejected when target lacks deposit method")
end

-- Test 5: Metamethod __tostring
print("\nTest 5: Metamethod __tostring")
do
    local a = Account:new(1234.50, "ACC-TEST")
    local str = tostring(a)
    check(str:find("Account%(ACC%-TEST") ~= nil, "__tostring outputs account ID")
    check(str:find("1234%.50") ~= nil, "__tostring outputs formatted balance")
end

-- Test 6: SavingAccount Subclassing, Inheritance & Interest
print("\nTest 6: SavingAccount Subclassing, Inheritance & Interest")
do
    local s = SavingAccount:new(1000, 0.10, 500)
    check(s.interest_rate == 0.10, "Interest rate set to 10%")
    check(s.overdraft_limit == 500, "Overdraft limit set to $500")

    -- Verify inherited deposit method works on SavingAccount
    s:deposit(500)
    check(s:get_balance() == 1500, "Inherited deposit method works on SavingAccount")

    local accrued = s:accure_interest()
    check(accrued == 150, "Accrued 10% interest equals $150")
    check(s:get_balance() == 1650, "Balance updated to $1650 after interest")
end

-- Test 7: SavingAccount Polymorphic Overdraft Withdrawl
print("\nTest 7: SavingAccount Overdraft Withdrawal")
do
    local s = SavingAccount:new(1000, 0.05, 500)

    local ok_wd, bal_wd = s:withdraw(1200)
    check(ok_wd == true, "Overdraft withdrawal approved within limit")
    check(s:get_balance() == -200, "Balance is now negative (-$200)")

    local ok_exceed, err_exceed = s:withdraw(400)
    check(ok_exceed == false, "Withdrawal exceeding overdraft limit rejected")
    check(s:get_balance() == -200, "Balance unchanged after rejected overdraft")

    local s_str = tostring(s)
    check(s_str:find("SavingAccount") ~= nil and s_str:find("limit:") ~= nil, "SavingAccount __tostring includes overdraft limit")
end

-- Test 8: Bytecode Scoping & Undeclared Global Check (GGET/GSET)
print("\nTest 8: Bytecode Scoping & Undeclared Global Analysis")
do
    local luajit = arg[-1] or "luajit"
    local p_bc = io.popen(luajit .. " -bl oop_account.lua", "r")
    assert(p_bc, "Failed to run luajit -bl oop_account.lua")

    local std_globals = {
        require = true, io = true, os = true, pcall = true, xpcall = true,
        string = true, math = true, table = true, print = true, ipairs = true,
        pairs = true, tonumber = true, tostring = true, type = true,
        assert = true, error = true, setmetatable = true, getmetatable = true,
        select = true, next = true, rawget = true, rawset = true,
        coroutine = true, bit = true, ffi = true, jit = true, arg = true,
        _G = true, debug = true
    }

    local bad_globals = {}
    for line in p_bc:lines() do
        local g = line:match('GGET%s+%d+%s+%d+%s+;%s+"([^"]+)"') or line:match('GSET%s+%d+%s+%d+%s+;%s+"([^"]+)"')
        if g and not std_globals[g] then
            bad_globals[g] = (bad_globals[g] or 0) + 1
        end
    end
    p_bc:close()

    local bad_list = {}
    for k, v in pairs(bad_globals) do
        bad_list[#bad_list + 1] = string.format("%s (%d)", k, v)
    end
    check(#bad_list == 0, "Zero undeclared global access in oop_account.lua: " .. table.concat(bad_list, ","))
end

-- Summary
print(string.format("All tests completed: %d / %d passed", tests_passed, tests_run))

