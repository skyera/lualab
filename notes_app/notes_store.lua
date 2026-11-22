local json = require("json")

local NotesStore = {}
NotesStore.__index = NotesStore

local function trim(text)
    return text:match("^%s*(.-)%s*$")
end

function NotesStore.new(initial_items)
    local items = {}
    local max_id = 0
    for _, note in ipairs(initial_items or {}) do
        items[#items + 1] = {
            id = note.id,
            text = note.text,
            image = note.image
        }
        if note.id > max_id then
            max_id = note.id
        end
    end
    return setmetatable({ items = items, next_id = max_id + 1 }, NotesStore)
end

function NotesStore:list()
    return self.items
end

function NotesStore:add(raw_text, image)
    if type(raw_text) ~= "string" then
        return nil, "Note text is required"
    end
    local text = trim(raw_text)
    if text == "" then
        return nil, "Note text is required"
    end

    local note = { id = self.next_id, text = text }
    if type(image) == "string" and image ~= "" then
        note.image = image
    end
    self.next_id = self.next_id + 1
    self.items[#self.items + 1] = note
    return note
end

function NotesStore:update(id, raw_text)
    if type(raw_text) ~= "string" then
        return nil, "Note text is required"
    end
    local text = trim(raw_text)
    if text == "" then
        return nil, "Note text is required"
    end
    for _, note in ipairs(self.items) do
        if note.id == id then
            note.text = text
            return note
        end
    end
    return nil, "Note not found"
end

function NotesStore:delete(id)
    for i, note in ipairs(self.items) do
        if note.id == id then
            table.remove(self.items, i)
            return true
        end
    end
    return false
end

function NotesStore:save(file_path)
    local file, err = io.open(file_path, "wb")
    if not file then
        return nil, "open " .. file_path .. ": " .. tostring(err)
    end
    local ok, write_err = file:write(json.stringify(self.items) .. "\n")
    file:close()
    if not ok then
        return nil, "write " .. file_path .. ": " .. tostring(write_err)
    end
    return true
end

function NotesStore.load(file_path)
    local file = io.open(file_path, "rb")
    if not file then
        return NotesStore.new()
    end
    local raw = file:read("*a")
    file:close()
    local ok, parsed = pcall(json.parse, raw)
    if not ok or type(parsed) ~= "table" then
        return nil, "invalid JSON in " .. file_path
    end
    return NotesStore.new(parsed)
end

return NotesStore
