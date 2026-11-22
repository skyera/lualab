local NotesStore = {}
NotesStore.__index = NotesStore

local function trim(text)
    return text:match("^%s*(.-)%s*$")
end

function NotesStore.new(initial_items)
    local items = {}
    local max_id = 0
    for _, note in ipairs(initial_items or {}) do
        items[#items + 1] = { id = note.id, text = note.text }
        if note.id > max_id then
            max_id = note.id
        end
    end
    return setmetatable({ items = items, next_id = max_id + 1 }, NotesStore)
end

function NotesStore:list()
    return self.items
end

function NotesStore:add(raw_text)
    if type(raw_text) ~= "string" then
        return nil, "Note text is required"
    end
    local text = trim(raw_text)
    if text == "" then
        return nil, "Note text is required"
    end

    local note = { id = self.next_id, text = text }
    self.next_id = self.next_id + 1
    self.items[#self.items + 1] = note
    return note
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

return NotesStore
