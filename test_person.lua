#!/usr/bin/env luajit
--------------------------------------------------------------------------------
-- test_person.lua
-- Test suite for person.lua
--------------------------------------------------------------------------------

local Person = require("person")

local TestRunner = {
    passed = 0,
    failed = 0
}

function TestRunner.describe(suite_name, fn)
    print(string.format("\n\27[1;36m▶ Suite: %s\27[0m", suite_name))
    fn()
end

function TestRunner.it(test_name, fn)
    local ok, err = pcall(fn)
    if ok then
        TestRunner.passed = TestRunner.passed + 1
        print(string.format("  \27[32m✔\27[0m %s", test_name))
    else
        TestRunner.failed = TestRunner.failed + 1
        print(string.format("  \27[31m✘\27[0m %s", test_name))
        print(string.format("    \27[31mError: %s\27[0m", tostring(err)))
    end
end

local function assert_true(val, msg)
    if not val then error(msg or "Assertion failed: expected true", 2) end
end

local function assert_false(val, msg)
    if val then error(msg or "Assertion failed: expected false", 2) end
end

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected '%s', got '%s'",
              msg or "Assertion failed", tostring(expected), tostring(actual)), 2)
    end
end

local function assert_error(fn, msg)
    local ok = pcall(fn)
    assert_false(ok, msg or "Assertion failed: expected the call to raise an error")
end

print("================================================================================")
print("  Running Test Suite for person.lua")
print("================================================================================")

--------------------------------------------------------------------------------
TestRunner.describe("Construction", function()
    TestRunner.it("new() creates a person with the given fields", function()
        local p = Person.new("Alice", 1990)
        assert_eq(p.name, "Alice", "name")
        assert_eq(p.birth_year, 1990, "birth_year")
        assert_eq(p.email, nil, "email defaults to nil")
    end)

    TestRunner.it("new() accepts an options table", function()
        local p = Person.new("Bob", 1985, { email = "bob@example.com" })
        assert_eq(p.email, "bob@example.com", "email")
    end)

    TestRunner.it("new() assigns an incrementing id", function()
        local before = Person.count()
        local a = Person.new("A", 1990)
        local b = Person.new("B", 1991)
        assert_eq(a._id, before + 1, "first id")
        assert_eq(b._id, before + 2, "second id")
    end)

    TestRunner.it("new() rejects a non-string name", function()
        assert_error(function() Person.new(42, 1990) end, "should reject a number name")
    end)

    TestRunner.it("new() rejects an empty name", function()
        assert_error(function() Person.new("", 1990) end, "should reject an empty name")
    end)

    TestRunner.it("new() rejects a non-number birth_year", function()
        assert_error(function() Person.new("Alice", "1990") end, "should reject a string year")
    end)

    TestRunner.it("new() rejects a fractional birth_year", function()
        assert_error(function() Person.new("Alice", 1990.5) end, "should reject a fractional year")
    end)

    TestRunner.it("new() rejects a future birth_year", function()
        assert_error(function() Person.new("Time", 3000) end, "should reject a future year")
    end)
end)

--------------------------------------------------------------------------------
TestRunner.describe("Behavior", function()
    TestRunner.it("get_age() computes against the current year", function()
        local this_year = tonumber(os.date("%Y"))
        local p = Person.new("Alice", this_year - 30)
        assert_eq(p:get_age(), 30, "age")
    end)

    TestRunner.it("get_age(as_of_year) honors the argument", function()
        local p = Person.new("Alice", 1990)
        assert_eq(p:get_age(2000), 10, "age in 2000")
        assert_eq(p:get_age(2020), 30, "age in 2020")
    end)

    TestRunner.it("is_adult() flips at 18", function()
        local this_year = tonumber(os.date("%Y"))
        assert_false(Person.new("Kid", this_year - 10):is_adult(), "10yo is not an adult")
        assert_true(Person.new("Grown", this_year - 18):is_adult(), "18yo is an adult")
    end)

    TestRunner.it("greet() includes the name and age", function()
        local p = Person.new("Alice", 1990)
        local msg = p:greet()
        assert_true(msg:find("Alice", 1, true) ~= nil, "greeting should contain the name")
        assert_true(msg:find("Hello", 1, true) ~= nil, "greeting should default to Hello")
    end)

    TestRunner.it("greet() accepts a custom salutation", function()
        local msg = Person.new("Alice", 1990):greet("Hi")
        assert_true(msg:find("Hi,", 1, true) ~= nil, "greeting should use the custom salutation")
    end)

    TestRunner.it("set_email() updates and validates", function()
        local p = Person.new("Bob", 1990)
        p:set_email("bob@example.com")
        assert_eq(p.email, "bob@example.com", "email set")
        p:set_email(nil)
        assert_eq(p.email, nil, "email cleared")
        assert_error(function() p:set_email(99) end, "should reject a non-string email")
    end)
end)

--------------------------------------------------------------------------------
TestRunner.describe("OOP dispatch", function()
    TestRunner.it("methods resolve through __index", function()
        local p = Person.new("Alice", 1990)
        assert_eq(type(p.greet), "function", "p.greet should be the class method")
        assert_eq(p.greet, Person.greet, "instance method is the class method")
    end)

    TestRunner.it("Person(...) is sugar for Person.new(...)", function()
        local a = Person("Alice", 1990)
        local b = Person.new("Alice", 1990)
        assert_eq(a.name, b.name, "same name")
        assert_eq(a.birth_year, b.birth_year, "same birth year")
        -- Note: `a ~= b` is false here because __eq compares field-wise.
        -- rawequal is the only way to test object identity once __eq exists.
        assert_false(rawequal(a, b), "should be two distinct objects")
    end)

    TestRunner.it("instances get private state, not shared class state", function()
        local a = Person.new("Alice", 1990)
        local b = Person.new("Bob", 1990)
        a.name = "Changed"
        assert_eq(b.name, "Bob", "mutating a must not affect b")
        assert_eq(Person.name, nil, "the class itself must stay clean")
    end)

    TestRunner.it("the module leaks no globals", function()
        assert_eq(_G.Person, nil, "Person must not be a global")
        assert_eq(_G.ClassMeta, nil, "ClassMeta must not be a global")
    end)
end)

--------------------------------------------------------------------------------
TestRunner.describe("Identity & comparison", function()
    TestRunner.it("Person.is_person() recognizes instances", function()
        assert_true(Person.is_person(Person.new("Alice", 1990)), "instance is a Person")
        assert_false(Person.is_person({ name = "Alice" }), "plain table is not")
        assert_false(Person.is_person("Alice"), "string is not")
    end)

    TestRunner.it("__tostring formats the person", function()
        local s = tostring(Person.new("Alice", 1990))
        assert_true(s:find("Person(Alice, b. 1990, age ", 1, true) == 1,
                    "unexpected tostring output: " .. s)
    end)

    TestRunner.it("__eq compares field-wise", function()
        local a = Person.new("Alice", 1990)
        local b = Person.new("Alice", 1990)
        local c = Person.new("Alice", 1991)
        assert_true(a == b, "same name+year should be equal")
        assert_true(a ~= c, "different year should not be equal")
    end)

    TestRunner.it("__lt sorts by name, then by age descending", function()
        local people = {
            Person.new("Carol", 1992),
            Person.new("Alice", 1990),
            Person.new("Alice", 1980),
            Person.new("Bob", 1995),
        }
        table.sort(people)
        local names = {}
        for i, p in ipairs(people) do names[i] = p.name .. "/" .. p.birth_year end
        assert_eq(table.concat(names, ","), "Alice/1990,Alice/1980,Bob/1995,Carol/1992", "sort order")
    end)

    TestRunner.it("__le works for <= comparisons", function()
        local a = Person.new("Alice", 1990)
        local b = Person.new("Alice", 1990)
        local c = Person.new("Alice", 1991)
        assert_true(a <= b, "equal people are <=")
        -- Within the same name, a later birth year sorts first, so the
        -- 1991 person precedes the 1990 person.
        assert_true(c <= a, "1991 sorts before 1990")
        assert_false(a <= c, "and therefore 1990 is not <= 1991")
    end)
end)

--------------------------------------------------------------------------------
TestRunner.describe("Inheritance", function()
    local Employee = Person:extend("Employee")

    function Employee:_init(name, birth_year, opts)
        opts = opts or {}
        self.name       = name
        self.birth_year = birth_year
        self.email      = opts.email
        self.role       = opts.role or "unknown"
        self.created_at = os.time()
    end

    function Employee:describe()
        return string.format("%s works as a %s", self.name, self.role)
    end

    TestRunner.it("subclass instances inherit parent methods", function()
        local e = Employee("Carol", 1992, { role = "engineer" })
        assert_eq(e.role, "engineer", "subclass field")
        assert_true(e:get_age() >= 0, "inherited get_age must work")
        assert_true(e:greet("Hello"):find("Carol", 1, true) ~= nil, "inherited greet must work")
    end)

    TestRunner.it("subclass constructor is wired up", function()
        local e = Employee("Dave", 1980)
        assert_eq(getmetatable(e), Employee, "instance metatable is the subclass")
        assert_eq(e.role, "unknown", "role defaults")
    end)

    TestRunner.it("subclass does not clobber the parent", function()
        local p = Person.new("Alice", 1990)
        assert_eq(getmetatable(p), Person, "parent instances still use Person")
        assert_eq(p.role, nil, "parent instances have no subclass fields")
        assert_eq(Employee.role, nil, "the class table itself is not an instance")
    end)

    TestRunner.it("subclass overrides work polymorphically", function()
        local function speak(p) return p:describe() end
        local e = Employee("Eve", 1995, { role = "designer" })
        local ok, err = pcall(speak, e)
        assert_true(ok, "subclass method should exist: " .. tostring(err))
    end)

    TestRunner.it("a subclass of a subclass inherits transitively", function()
        local Manager = Employee:extend("Manager")
        function Manager:_init(name, birth_year, opts)
            Employee._init(self, name, birth_year, opts)
            self.reports = opts and opts.reports or 0
        end
        local m = Manager("Frank", 1975, { role = "boss", reports = 4 })
        assert_eq(m.reports, 4, "grandchild field")
        assert_eq(m.role, "boss", "inherited from parent _init")
        assert_true(m:get_age() >= 0, "inherited two levels up")
    end)

    TestRunner.it("class metatable __index exposes statics", function()
        assert_eq(type(Person.extend), "function", "extend is reachable as a static")
        assert_eq(type(Person.count), "function", "count is reachable as a static")
    end)

    TestRunner.it("printing a class shows its name, not a table address", function()
        assert_eq(tostring(Person), "class Person", "base class __tostring")
        assert_eq(tostring(Employee), "class Employee", "subclass __tostring")
    end)
end)

--------------------------------------------------------------------------------
TestRunner.describe("clone()", function()
    TestRunner.it("clone() copies fields but issues a new id", function()
        local a = Person.new("Alice", 1990, { email = "a@x.com" })
        local b = a:clone()
        assert_eq(b.name, a.name, "name copied")
        assert_eq(b.birth_year, a.birth_year, "birth_year copied")
        assert_eq(b.email, a.email, "email copied")
        assert_true(b._id ~= a._id, "clone must get a fresh id")
        b.name = "Changed"
        assert_eq(a.name, "Alice", "clone must be independent")
    end)
end)

print("\n================================================================================")
print(string.format("  TEST SUMMARY: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
print("================================================================================")

if TestRunner.failed > 0 then
    os.exit(1)
else
    print("\27[1;32mALL TESTS PASSED SUCCESSFULLY!\27[0m\n")
    os.exit(0)
end
