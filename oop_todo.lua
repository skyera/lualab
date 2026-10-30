#!/usr/bin/env luajit
-- ============================================================================
-- OOP Todo List Manager (Task & Todo Classes)
-- ============================================================================

local string_format = string.format
local table_insert = table.insert
local table_remove = table.remove
local ipairs = ipairs
local tonumber = tonumber
local tostring = tostring
local type = type
local setmetatable = setmetatable

local Task = {}
Task.__index = Task

setmetatable(Task, {
    __call = function(cls, ...)
        return cls:new(...)
    end
})

function Task:new(text, done)
    if type(text) ~= "string" or text:match("^%s*$") then
        return nil, "Task text cannot be empty"
    end

    local instance = setmetatable({}, self)
    instance.text = text:match("^%s*(.-)%s*$")
    instance.done = (done == true)
    return instance
end

function Task:complete()
    self.done = true
    return self
end

function Task:toggle()
    self.done = not self.done
    return self
end

function Task:__tostring()
    local status = self.done and "[x]" or "[ ]"
    return string_format("%s %s", status, self.text)
end

local t = Task("  Learn Lua OOP")
print(t)
t:complete()
print(t)
t:toggle()
print(t)
