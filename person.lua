--------------------------------------------------------------------------------
-- person.lua
-- An idiomatic Lua "class" built on metatables: private state, validation,
-- operator metamethods, __call construction sugar, and single inheritance.
--
-- Usage:
--   local Person = require("person")
--   local alice = Person("Alice", 1990)
--   local bob   = Person.new("Bob", 1985, { email = "bob@example.com" })
--   print(alice)                 --> Person(Alice, b. 1990, age 36)
--
-- Subclassing:
--   local Employee = Person:extend("Employee")
--   local e = Employee("Carol", 1992, { role = "engineer" })
--------------------------------------------------------------------------------

local Person = {}

--- The table every Person instance is metatagged with, so `instance.field`
--- falls through to the class's methods and static members.
Person.__index = Person

--------------------------------------------------------------------------------
-- Private state
--------------------------------------------------------------------------------
-- A closure-local counter: the auto-incrementing id lives in an upvalue and is
-- NOT reachable from any instance or from the outside world. This is Lua's
-- idiom for private data -- there is no `private` keyword.
local next_id = 0

--------------------------------------------------------------------------------
-- Class metatable
--------------------------------------------------------------------------------
-- `Person` itself has a metatable, which gives us three things:
--   __call  --> Person("Alice", 1990) is sugar for Person.new("Alice", 1990)
--   __index --> static lookup: Person:extend, Person.count, etc.
--   __tostring --> so a stray `print(Person)` is readable
local ClassMeta = {}
ClassMeta.__index = ClassMeta

function ClassMeta.__call(cls, ...)
    return cls.new(...)
end

function ClassMeta:extend(class_name, super)
    super = super or self

    local sub = {}
    sub.__index    = sub
    sub.super      = super
    sub.class_name = class_name

    -- The metatable gives us two different things:
    --
    -- 1. __index = super -- because `sub` is itself a table, an instance lookup
    --    `obj.someMethod` (-> sub.someMethod) falls through into `super`.
    --    That is what makes instance-level inheritance work with no extra code.
    --
    -- 2. __call / __tostring -- these MUST be raw fields here. Lua fetches
    --    metamethods with a raw get on the metatable, so a bare
    --    {__index = super} would NOT inherit __call and `Sub(...)` would raise
    --    "attempt to call a table value".
    setmetatable(sub, {
        __index    = super,
        __call     = function(cls, ...) return cls.new(...) end,
        __tostring = function(cls) return "class " .. (cls.class_name or "?") end,
    })

    -- Constructor: sets up storage, then delegates to _init for user logic.
    sub.new = function(...)
        local obj = setmetatable({}, sub)
        obj:_init(...)
        return obj
    end

    -- No-op default _init, but only when neither the subclass nor the base
    -- class defines one. (A plain `sub._init == nil` check would resolve
    -- through __index and see the parent's.)
    if rawget(sub, "_init") == nil and rawget(super, "_init") == nil then
        sub._init = function() end
    end

    return sub
end

-- Note the double underscore: this must be a metamethod name, not a plain
-- method, or `print(Person)` falls back to "table: 0x...".
function ClassMeta:__tostring()
    return "class " .. (self.class_name or "Person")
end

setmetatable(Person, ClassMeta)
Person.class_name = "Person"

--------------------------------------------------------------------------------
-- Construction & validation
--------------------------------------------------------------------------------

local CURRENT_YEAR = tonumber(os.date("%Y"))

local function check(condition, message)
    if not condition then
        error("person.lua: " .. message, 3)
    end
end

--- Create a new Person.
-- @param name        string, non-empty
-- @param birth_year  integer, 1850 .. current year
-- @param opts        optional table { email = string }
function Person.new(name, birth_year, opts)
    opts = opts or {}

    check(type(name) == "string", "name must be a string, got " .. type(name))
    check(#name > 0, "name must not be empty")
    check(type(birth_year) == "number", "birth_year must be a number, got " .. type(birth_year))
    check(birth_year % 1 == 0, "birth_year must be a whole number, got " .. tostring(birth_year))
    check(birth_year >= 1850, "birth_year " .. birth_year .. " is implausibly early")
    check(birth_year <= CURRENT_YEAR, "birth_year " .. birth_year .. " is in the future")

    local self = setmetatable({}, Person)
    self.name       = name
    self.birth_year = birth_year
    self.email      = opts.email
    self.created_at = os.time()

    next_id = next_id + 1
    self._id = next_id   -- readable, but never validated against tampering

    return self
end

--- Number of Person objects created in this process.
function Person.count()
    return next_id
end

--------------------------------------------------------------------------------
-- Behavior
--------------------------------------------------------------------------------

--- Age in whole years. Pass `as_of_year` to compute against another year.
function Person:get_age(as_of_year)
    as_of_year = as_of_year or CURRENT_YEAR
    return as_of_year - self.birth_year
end

function Person:is_adult()
    return self:get_age() >= 18
end

function Person:greet(greeting)
    greeting = greeting or "Hello"
    return string.format("%s, my name is %s and I am %d years old.",
                         greeting, self.name, self:get_age())
end

--- True if this value is a Person created by this module.
function Person.is_person(value)
    return type(value) == "table"
       and getmetatable(value) == Person
       and rawget(value, "_id") ~= nil
end

--------------------------------------------------------------------------------
-- Metamethods
--------------------------------------------------------------------------------

function Person:__tostring()
    local email = self.email and (" <" .. self.email .. ">") or ""
    return string.format("Person(%s, b. %d, age %d)%s",
                         self.name, self.birth_year, self:get_age(), email)
end

-- __eq is only consulted when both operands are tables.
function Person:__eq(other)
    return type(other) == "table"
       and self.name       == other.name
       and self.birth_year == other.birth_year
end

-- Ordering: by name ascending, then by birth year descending (youngest first),
-- so table.sort produces a stable, meaningful order.
function Person:__lt(other)
    if self.name ~= other.name then
        return self.name < other.name
    end
    return self.birth_year > other.birth_year
end

function Person:__le(other)
    return self:__lt(other) or self:__eq(other)
end

--------------------------------------------------------------------------------
-- Composition
--------------------------------------------------------------------------------

--- A new Person with the same data but a fresh id (deep-ish copy of fields).
function Person:clone()
    return Person.new(self.name, self.birth_year, { email = self.email })
end

function Person:set_email(email)
    if email ~= nil then
        check(type(email) == "string", "email must be a string or nil")
    end
    self.email = email
    return self
end

return Person
