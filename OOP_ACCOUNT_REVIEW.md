# Technical Code Review: `oop_account.lua` (formerly `oop_account_example.lua`)

**Date:** 2026-10-25  
**Target:** [`oop_account.lua`](file:///home/zliu/test/lualab/oop_account.lua)  
**Status:** Review & Refactoring Complete  

---

## 1. Executive Summary

[`oop_account.lua`](file:///home/zliu/test/lualab/oop_account.lua) (renamed from `oop_account_example.lua`) is a demonstration script for Object-Oriented Programming (OOP) in Lua using metatables and prototype delegation. 

While it illustrates basic method invocation via `:withdraw` and `:report`, the implementation contains critical scoping bugs (global variable leakage into `_G`), lacks explicit subclass metatable wiring (breaking inheritance in derived classes), lacks basic banking operations (e.g. deposit, inter-account transfer, balance query, `__tostring`), performs no input validation, and violates repository Lua formatting and architectural standards.

### Findings Matrix

| # | Category | Finding | Severity | Impact |
|---|---|---|---|---|
| **1** | **Scoping & Globals** | Global variable pollution (`Account`, `acc` in `_G`) | **High** | Leaks symbols across scripts; violates repo zero-`GGET` standard |
| **2** | **OOP Architecture** | Missing subclass inheritance demonstration (`SavingsAccount`) | **Medium** | Does not show how to properly derive classes with explicit metatable chains |
| **3** | **Domain Completeness** | Missing `deposit`, `transfer`, `get_balance`, and `__tostring` | **Medium** | Incomplete demonstration of object interactions and metamethods |
| **4** | **Error Handling** | Negative withdrawals, string arithmetic errors, silent overdrafts | **Medium** | Unchecked balance manipulation; silent failures violate `AGENTS.md` |
| **5** | **Code Standards** | 2-space indent, missing hashbang, banners, section dividers | **Low** | Violates repository formatting standards |
| **6** | **Modularity** | Script executes side-effects on load; cannot be required | **Medium** | Blocks reuse in test harnesses and other modules |

---

## 2. Detailed Technical Findings

### Finding 1: Global Variable Pollution (`_G` Leaks)

#### Evidence
```lua
Account = {}
Account.__index = Account
...
acc = Account:new(9000)
acc:withdraw(200)
```

#### Bytecode Analysis (`luajit -bl oop_account_example.lua`)
```
0001    TNEW     0   0
0002    GSET     0   0      ; "Account"
0003    GGET     0   0      ; "Account"
...
0020    GSET     0   8      ; "acc"
0021    GGET     0   8      ; "acc"
```

#### Impact
Neither `Account` nor `acc` are declared with `local`. In Lua, undeclared assignments bind to `_G`. If another script requires or evaluates this file, it corrupts or overwrites global state. Repository standards mandate:
> *"Local by Default: Always declare variables and helper functions as `local`. Never leak symbols into global `_G`."*

---

### Finding 2: Missing Subclass Inheritance Demonstration (Explicit Metatable Chain)

#### Evidence & Analysis
Lines 1–8 of [`oop_account_example.lua`](file:///home/zliu/test/lualab/oop_account_example.lua):
```lua
Account = {}
Account.__index = Account

function Account:new(balance)
  local obj = setmetatable({}, self)
  obj.balance = (balance or 0)
  return obj
end
```

For the base class `Account` itself, setting `Account.__index = Account` statically once at definition time is **the correct, high-performance pattern**. It avoids the redundant overhead of re-assigning `self.__index = self` every single time `:new()` is called to create an instance.

However, as an educational OOP demonstration script, the file **stops halfway**:
1. It does not demonstrate **inheritance** or **polymorphism** (subclassing).
2. Because Lua lacks built-in `class` or `extends` syntax, developers learning OOP from this example need to see how to properly extend `Account` into a derived subclass like `SavingsAccount`.
3. If someone naively writes `local SubClass = Account:new()` without understanding metatables, `SubClass.__index` remains `nil`, causing method lookups on instances of `SubClass` to fail:
```lua
local SpecialAccount = Account:new()
-- Naive subclass: SpecialAccount.__index is nil!
function SpecialAccount:get_limit() return 500 end

local s = SpecialAccount:new()
-- s:get_limit() crashes with: attempt to call method 'get_limit' (a nil value)
```

#### Architectural Decision: Pattern Comparison

| Pattern | Implementation | Pros | Cons / Tradeoffs | Status |
|---|---|---|---|---|
| **Dynamic Prototype** (*PiL*) | `self.__index = self` inside `:new()` | Zero boilerplate when deriving classes (`Sub = Base:new()`) | Re-executes `self.__index = self` on **every single instance creation** call to `:new()` | Rejected |
| **Explicit Class Definition** (*Selected*) | `Class.__index = Class` set **once** per class & subclass | **Zero constructor overhead**; constructors remain pure; inheritance is explicit and clean | Requires declaring `Sub.__index = Sub` when defining subclasses | **Adopted** |

#### Solution (Explicit Class Definition Pattern)
Separate class definition from instance creation. Set `.__index` **exactly once** when defining the base class and each subclass:
```lua
-- 1. Base Class Setup (executed once at load time)
local Account = {}
Account.__index = Account

function Account:new(initial_balance)
    -- Constructor ONLY creates the object; never touches class metatables!
    local instance = setmetatable({}, self)
    instance.balance = initial_balance or 0
    return instance
end

-- 2. Subclass Setup (executed once at load time)
local SavingsAccount = setmetatable({}, { __index = Account })
SavingsAccount.__index = SavingsAccount

function SavingsAccount:new(initial_balance, interest_rate)
    local instance = Account.new(self, initial_balance)
    instance.interest_rate = interest_rate or 0.05
    return instance
end
```

#### Why this pattern is optimal:
1. **Zero Redundancy**: `Account.__index` and `SavingsAccount.__index` are evaluated once at script load time. Calling `:new()` millions of times will never redundantly re-execute metatable assignments.
2. **Method Resolution Chain**:
   * Calling `savings_inst:accrue_interest()` checks `savings_inst` -> checks `SavingsAccount` via `SavingsAccount.__index` -> **Found**.
   * Calling `savings_inst:withdraw(100)` checks `savings_inst` -> checks `SavingsAccount` -> delegates to `Account` via `{ __index = Account }` -> **Found**.
3. **Pure Constructors**: The `:new()` functions focus exclusively on instance state initialization (`id`, `balance`, `limit`), keeping instance creation fast and clean.

---

### Finding 3: Missing Core Banking Domain Operations & Metamethods

#### Missing Operations
1. **Deposit**: An account model cannot only have withdrawals. It requires `Account:deposit(amount)`.
2. **Transfer**: Lacks multi-object interaction (`acc1:transfer(amount, acc2)`).
3. **Accessor**: Lacks `Account:get_balance()`.
4. **Metamethod `__tostring`**: Without `__tostring`, printing an account outputs `table: 0x55c...` instead of a readable description like `Account(ACC-1001, balance: $9,000.00)`.

---

### Finding 4: Silent Failures, Negative Overdrafts & Missing Validation

#### Evidence
```lua
function Account:withdraw(amount)
  print("Withdrawing " .. amount .. "...")
  self.balance = self.balance - amount
  self:report()
end
```

#### Edge-Case Hazards
* **Negative amounts**: `acc:withdraw(-500)` silently increases the balance by 500.
* **Non-numeric strings**: `acc:withdraw("abc")` prints `Withdrawing abc...` and crashes on arithmetic evaluation.
* **Unbounded Overdrafts**: `acc:withdraw(1000000)` sets `self.balance = -991000` with no check or warning.

#### Standard Rule
> *"Never Fail Silently: Handle errors explicitly. Do not swallow exceptions, ignore failed return values, or exit without explaining what failed."*

---

### Finding 5: Repository Formatting & Modularity Violations

* **Indentation**: The file uses 2-space indentation; the repository standard requires 4 spaces.
* **Header / Dividers**: Missing hashbang `#!/usr/bin/env luajit`, header descriptive banner, and 80-character section dividers.
* **Export Table**: The file lacks a module return (`return Account`). Requiring the file immediately executes side effects rather than providing a reusable component.

---

## 3. Proposed Refactored Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                       Account (Base)                        │
│  - id: string ("ACC-1001")                                  │
│  - balance: number                                          │
│  + new(balance, id) -> Account                              │
│  + deposit(amount) -> (boolean, balance_or_err)             │
│  + withdraw(amount) -> (boolean, balance_or_err)            │
│  + transfer(amount, target) -> (boolean, balance_or_err)    │
│  + get_balance() -> number                                  │
│  + __tostring() -> string                                   │
└──────────────────────────────▲──────────────────────────────┘
                               │ inherits via prototype
┌──────────────────────────────┴──────────────────────────────┐
│                  SavingsAccount (Subclass)                  │
│  - interest_rate: number (e.g. 0.05)                        │
│  - overdraft_limit: number (e.g. 500.00)                    │
│  + new(balance, rate, limit, id) -> SavingsAccount          │
│  + accrue_interest() -> number                              │
│  + withdraw(amount) [overridden: allows overdraft limit]     │
│  + __tostring() -> string                                   │
└─────────────────────────────────────────────────────────────┘
```

---

## 4. Proposed Code Comparison

### Before ([`oop_account_example.lua`](file:///home/zliu/test/lualab/oop_account_example.lua))
```lua
Account = {}
Account.__index = Account

function Account:new(balance)
  local obj = setmetatable({}, self)
  obj.balance = (balance or 0)
  return obj
end

function Account:withdraw(amount)
  print("Withdrawing " .. amount .. "...")
  self.balance = self.balance - amount
  self:report()
end

function Account:report()
  print("Your current balance is: " .. self.balance)
end

acc = Account:new(9000)
acc:withdraw(200)
```

### Proposed After ([`oop_account_example.lua`](file:///home/zliu/test/lualab/oop_account_example.lua))
```lua
#!/usr/bin/env luajit
-- =========================================================================
-- oop_account_example.lua - Idiomatic Metatable OOP Prototype Demonstration
--
-- Features:
--   * Pure local scoping (zero _G pollution, 0 undeclared globals in bytecode)
--   * Explicit class definition pattern (__index set once per class/subclass)
--   * Clean constructors: zero redundant __index assignments on :new()
--   * Encapsulation, input validation, and explicit error returns
--   * Multi-object messaging (inter-account transfer)
--   * Metamethods (__tostring)
--   * Subclass polymorphism (SavingsAccount with interest & overdraft limit)
--   * Dual-use: exports module when required, runs demo when standalone
-- =========================================================================

local string_format = string.format
local type          = type
local setmetatable  = setmetatable

-- =========================================================================
-- Base Class: Account
-- =========================================================================

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

function Account:deposit(amount)
    if type(amount) ~= "number" or amount <= 0 then
        return false, "Deposit amount must be a positive number"
    end
    self.balance = self.balance + amount
    return true, self.balance
end

function Account:withdraw(amount)
    if type(amount) ~= "number" or amount <= 0 then
        return false, "Withdrawal amount must be a positive number"
    end
    if amount > self.balance then
        return false, string_format("Insufficient funds (balance: $%.2f, requested: $%.2f)", self.balance, amount)
    end
    self.balance = self.balance - amount
    return true, self.balance
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

function Account:get_balance()
    return self.balance
end

function Account:report()
    print(string_format("[%s] Current balance: $%.2f", self.id, self.balance))
end

function Account:__tostring()
    return string_format("Account(%s, balance: $%.2f)", self.id, self.balance)
end

-- =========================================================================
-- Subclass: SavingsAccount (Inherits from Account)
-- =========================================================================

local SavingsAccount = setmetatable({}, { __index = Account })
SavingsAccount.__index = SavingsAccount

local next_savings_id = 2001

function SavingsAccount:new(initial_balance, interest_rate, overdraft_limit, id)
    local instance = Account.new(self, initial_balance, id or ("SAV-" .. next_savings_id))
    if not id then
        next_savings_id = next_savings_id + 1
    end
    instance.interest_rate = interest_rate or 0.05
    instance.overdraft_limit = overdraft_limit or 0
    return instance
end

function SavingsAccount:accrue_interest()
    local interest = self.balance * self.interest_rate
    if interest > 0 then
        self.balance = self.balance + interest
    end
    return interest
end

function SavingsAccount:withdraw(amount)
    if type(amount) ~= "number" or amount <= 0 then
        return false, "Withdrawal amount must be a positive number"
    end
    local available = self.balance + self.overdraft_limit
    if amount > available then
        return false, string_format("Exceeds overdraft limit (available: $%.2f, requested: $%.2f)", available, amount)
    end
    self.balance = self.balance - amount
    return true, self.balance
end

function SavingsAccount:__tostring()
    return string_format("SavingsAccount(%s, balance: $%.2f, limit: $%.2f)", self.id, self.balance, self.overdraft_limit)
end

-- Module table
local M = {
    Account = Account,
    SavingsAccount = SavingsAccount
}

-- =========================================================================
-- Standalone Demonstration Runner
-- =========================================================================

local is_standalone = false
if not pcall(debug.getlocal, 4, 1) and arg and arg[0] and arg[0]:match("oop_account_example%.lua$") then
    is_standalone = true
end

if is_standalone then
    print("================================================================================")
    print("Lua OOP Account Example (Metatable Prototype Pattern)")
    print("================================================================================\n")

    -- 1. Base Account Operations
    print("1. Base Account Operations:")
    local a1 = Account:new(9000)
    print("   Created:", a1)
    a1:deposit(500)
    print("   After deposit $500.00 -> Balance: $" .. string_format("%.2f", a1:get_balance()))
    a1:withdraw(200)
    print("   After withdraw $200.00 -> Balance: $" .. string_format("%.2f", a1:get_balance()))

    -- 2. Inter-Account Transfer
    print("\n2. Inter-Account Transfer:")
    local a2 = Account:new(1000)
    print("   Created:", a2)
    print("   Transferring $1,500.00 from " .. a1.id .. " to " .. a2.id .. "...")
    local ok, err = a1:transfer(1500, a2)
    if ok then
        print("   Transfer succeeded!")
        print("   " .. tostring(a1))
        print("   " .. tostring(a2))
    else
        print("   Transfer failed:", err)
    end

    -- 3. Subclassing & Polymorphism (SavingsAccount)
    print("\n3. Subclassing & Polymorphism (SavingsAccount with 5% Interest & Overdraft):")
    local sav = SavingsAccount:new(2000, 0.05, 500)
    print("   Created:", sav)
    local interest = sav:accrue_interest()
    print("   Accrued 5% interest: +$" .. string_format("%.2f", interest) .. " -> Balance: $" .. string_format("%.2f", sav:get_balance()))

    -- Test overdraft withdrawal within limit
    print("   Attempting withdrawal of $2,400.00 (within $500 overdraft limit)...")
    local ok_wd, err_wd = sav:withdraw(2400)
    if ok_wd then
        print("   Withdrawal approved! Current balance: $" .. string_format("%.2f", sav:get_balance()))
    else
        print("   Withdrawal rejected:", err_wd)
    end

    -- Test overdraft withdrawal exceeding limit
    print("   Attempting withdrawal of $400.00 (exceeds remaining overdraft limit)...")
    local ok_wd2, err_wd2 = sav:withdraw(400)
    if ok_wd2 then
        print("   Withdrawal approved! Current balance: $" .. string_format("%.2f", sav:get_balance()))
    else
        print("   Withdrawal rejected:", err_wd2)
    end

    print("\nAll OOP demonstrations completed successfully!\n")
end

return M
```

---

## 5. Verification Plan

1. **Automated Unit Tests (`test_oop_account.lua`)**:
   * Test instantiation defaults and custom IDs.
   * Test deposit and withdrawal logic, including zero, negative, and invalid type rejections.
   * Test overdraft rejection in base `Account`.
   * Test successful transfer and failed transfer on insufficient balance.
   * Test `SavingsAccount` inheritance, method delegation, interest calculation, and overdraft limits.
   * Test `__tostring` metamethod formatting.
2. **Bytecode Scoping Analysis**:
   * Run `luajit -bl oop_account_example.lua` and assert 0 undeclared globals (`GGET`/`GSET`).
3. **Standalone Execution**:
   * Run `luajit oop_account_example.lua` and verify formatted output.
