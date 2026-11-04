# Lua OOP & Metatable Notes: Mental Model & Reference

A concise guide to understanding Object-Oriented Programming and Metatables in Lua, mapped to familiar C++ concepts.

---

## 1. The Core Mental Model: "Find Method, Operate on Table"

In Lua, there is no native `class` or `method` keyword.
- A **class** is just a **table** holding functions.
- An **instance** is a **table** holding data fields.
- A **method call** (`t:method(...)`) is a two-step operation:
  1. **Find the method**: Look up `"method"` in `t` itself; if not found, follow `getmetatable(t).__index`.
  2. **Operate on the table**: Call the function and pass `t` as the **1st argument (`self`)**.

```lua
-- When you write:
t:complete("now")

-- Lua literally executes:
t["complete"](t, "now")
-- ^^^^^^^^^^  ^
-- Step 1:     Step 2:
-- Find method Pass table as 1st argument (self)
```

---

## 2. Colon (`:`) vs. Dot (`.`): Syntax & Mechanics

The colon `:` is pure syntactic sugar that automatically injects `self`.

### A. When Defining a Function
```lua
-- Colon syntax (sugar):
function Account:deposit(amount)
    self.balance = self.balance + amount
end

-- Dot syntax (exact equivalent):
function Account.deposit(self, amount)
    self.balance = self.balance + amount
end
```

### B. When Calling a Function
```lua
-- Colon call: passes 'acc' as 1st argument automatically
acc:deposit(100)

-- Dot call: requires passing 'acc' manually
Account.deposit(acc, 100)

-- CAUTION: acc.deposit(100) passes ONLY 100 -> self becomes 100, amount becomes nil!
```

---

## 3. Method Lookup Chain: `rawget` and `__index`

When accessing `t[key]` (or `t.key` / `t:key()`):

1. **Check the table itself**: `rawget(t, key)`
   - If the key exists directly on the instance, use it immediately (enables per-instance overrides).
2. **Fallback to Metatable `__index`**:
   - If `rawget(t, key)` is `nil`, Lua looks at `getmetatable(t).__index`.
   - If `__index` is a table, Lua checks `__index[key]`.
   - If `__index` has its own metatable (subclass chain), Lua repeats the lookup up the prototype hierarchy.

```
Lookup Path for t:complete():
t (instance table)
  │
  ├─> Key "complete" found? ──Yes──> Return function
  │
  └─No─> getmetatable(t) (Class table, e.g. Task)
           │
           └─> Task.__index["complete"] ──Yes──> Return function
```

### What is `rawget` / `rawset`?
- `rawget(t, key)`: Reads `t[key]` **without** querying `__index`.
- `rawset(t, key, val)`: Writes `t[key] = val` **without** triggering `__newindex`.

---

## 4. The C++ to Lua Rosetta Stone

If you know C++, you already know Lua OOP under the hood:

| C++ Concept | Lua Equivalent | Notes |
| :--- | :--- | :--- |
| **`this` pointer** | **`self`** (1st argument) | Passed automatically by `:` |
| **`obj.method(x)`** | **`obj:method(x)`** | Resolves function and passes `obj` as `self` |
| **`vptr`** (vtable pointer) | **`setmetatable(obj, Class)`** | Connects instance to class table |
| **`vtable`** (virtual method table) | **`Class.__index = Class`** | Stores shared function pointers |
| **`Base::method(x)`** | **`Base.method(self, x)`** | Explicit supercall using dot syntax |
| **`operator()` (Functor)** | **`__call`** metamethod | Allows `Class(...)` constructor syntax |
| **`operator==` / `operator<`** | **`__eq` / `__lt`** metamethods | Operator overloading |
| **`dynamic_cast<T*>`** | **`instance:is_a(T)`** | Walking the ancestor metatable chain |

---

## 5. `__call`: Making Tables Callable (Constructors)

In Lua, only functions can be called with `()`. To make a class table callable like a constructor (`Task(...)` instead of `Task:new(...)`), assign `__call` to the **class metatable**.

### The 1st Argument of `__call` is ALWAYS the Table Itself
```lua
setmetatable(Task, {
    __call = function(cls, ...)
        return cls:new(...)
    end
})
```

When you write `local t = Task("Buy milk", false)`:
1. Lua sees `()` on the `Task` table $\rightarrow$ looks for `getmetatable(Task).__call`.
2. Lua passes `Task` as the **1st argument (`cls`)**: `__call(Task, "Buy milk", false)`.
3. Inside `__call`, `cls:new(...)` runs $\rightarrow$ calls `Task:new("Buy milk", false)`.
4. `Task:new` allocates a table `{}` via `setmetatable({}, self)`, fills the fields, and returns it.

---

## 6. Two-Phase Initialization (`__call` + `_init`)

Separating memory allocation from field population prevents constructor boilerplate and avoids double-blessing metatables in subclasses:

```lua
local Entity = {}
Entity.__index = Entity

-- Phase 1: Allocation
setmetatable(Entity, {
    __call = function(cls, ...)
        local instance = setmetatable({}, cls) -- Allocates table with correct class
        if instance._init then
            instance:_init(...)                -- Phase 2: Populates fields
        end
        return instance
    end
})

function Entity:_init(name)
    self.name = name
end
```

---

## 7. Operator Overloading: The Dot (`.`) Invariant for Binary Operators

Binary metamethods (`__eq`, `__lt`, `__add`) receive **two operands `(a, b)`**, not an implicit `self`.

> [!WARNING]
> Always define binary metamethods with **dot syntax (`.`)**, NEVER with a colon (`:`).

```lua
-- CORRECT: receives (a, b)
function Rectangle.__eq(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    return a.width == b.width and a.height == b.height
end

-- WRONG: function Rectangle:__eq(a, b) inserts hidden 'self', so 'b' receives nil!
```

---

## 8. The "Shared Table" Prototype Trap (Class vs. Instance Variables)

In C++, putting a table on the class definition in Lua behaves like declaring a **`static` variable**:

```cpp
// What putting a table on the class secretly behaves like:
class Player {
public:
    static std::vector<std::string> inventory; // ⚠️ SHARED across all instances!
};
```

### The Bug: Primitives Shadow, Tables Mutate in Place

```lua
local Player = {
    level = 1,      -- Primitive (number)
    inventory = {}  -- ⚠️ DANGER! Single shared table in memory!
}
Player.__index = Player

function Player:new(name)
    return setmetatable({ name = name }, self)
end

local p1 = Player:new("Alice")
local p2 = Player:new("Bob")

-- 1. Primitives: SAFE (Assignment shadows the prototype)
p1.level = 2
-- Lua writes 'level = 2' directly into p1. Player.level remains 1.

-- 2. Table mutation: DISASTER (Mutates the shared prototype table!)
table.insert(p1.inventory, "Sword")
-- Step A: p1 has no 'inventory' key -> resolves via __index to Player.inventory.
-- Step B: table.insert mutates that single table in memory!
print(#p2.inventory) -- Output: 1! Bob suddenly sees Alice's sword!
```

### The Golden Rule
- **Primitives** (strings, numbers, booleans) can safely sit on the class table as defaults.
- **Tables and Arrays** MUST ALWAYS be instantiated inside the constructor (`:new()` / `_init`) so each instance gets its own independent table in memory:

```lua
-- ✅ THE CORRECT PATTERN:
function Player:new(name)
    local instance = setmetatable({}, self)
    instance.name = name
    instance.inventory = {} -- 💡 Fresh, independent table for this instance!
    return instance
end
```

---

## 9. Typo Protection & Strict Schemas via `__newindex`

While `__index` intercepts **reading** missing keys (`val = t[missing]`), **`__newindex` intercepts WRITING to a key that does NOT exist in the table yet (`t[new_key] = val`)**.

```
                  t[key] = value
                        │
         Does 'key' ALREADY exist in 't'?
                  │             │
                 YES            NO
                  │             │
          Writes directly    Does metatable have __newindex?
          into t[key]               │                │
          (Fast, normal)           YES               NO
                                    │                │
                          Calls __newindex!    Creates new key in 't'
                          (Intercepted!)       (Normal Lua behavior)
```

### The Bug: Silent Typos
```lua
function Account:deposit(amount)
    self.balence = self.balance + amount -- ⚠️ Typo: creates 'balence', leaves 'balance' untouched!
end
```

### The Fix: Lock Instance Fields with `__newindex`
```lua
function GuardedAccount:new(id, balance)
    local instance = {
        id = id,
        balance = balance or 0,
    }

    local mt = {
        __index = GuardedAccount,
        __newindex = function(tbl, key, value)
            error(string.format("Typo Error: Field '%s' does not exist on GuardedAccount!", key), 2)
        end
    }
    return setmetatable(instance, mt)
end
```
- Existing fields (`instance.balance = 200`) update directly without invoking `__newindex`.
- Misspelled fields (`instance.balence = 999`) trigger `__newindex` and raise an immediate error pointing to the caller's line (`error(..., 2)`).

---

## 10. Mixins & Composition (Beats Multiple Inheritance)

In Lua, chaining multiple inheritance metatables is slow and prone to conflicts. The idiomatic approach is **Mixins** (copying reusable method tables into a class).

```lua
-- Reusable mixin:
local Loggable = {}
function Loggable:log(message)
    print(string.format("[LOG][%s] %s", self.id or "Unknown", message))
end

-- Installer function on class:
function Order:include(mixin)
    for name, method in pairs(mixin) do
        if type(method) == "function" then
            self[name] = method
        end
    end
    return self -- Allows chaining: Order:include(M1):include(M2)
end

Order:include(Loggable)
```

---

## 11. Summary Checklist

1. **To declare a method**: Use `function Class:method(...)`.
2. **To call a method**: Use `instance:method(...)`.
3. **To call a super method**: Use `SuperClass.method(self, ...)` with a **dot** and pass `self` explicitly.
4. **To make a class callable**: Set `setmetatable(Class, { __call = function(cls, ...) return cls:new(...) end })`.
5. **To overload binary operators (`==`, `<`)**: Use dot syntax (`Class.__eq = function(a, b) ... end`).
6. **To avoid the shared table bug**: Always initialize nested tables and arrays inside constructors (`:new()` / `_init`), never on the class prototype.
7. **To catch silent typos**: Use `__newindex` on instance metatables to intercept writing to undeclared keys.
8. **To compose multiple behaviors**: Use mixins via `Class:include(mixin)` instead of multiple inheritance.
9. **To check type hierarchy**: Walk `getmetatable(self)` / `.super` chain.
