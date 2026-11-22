local NotesStore  = require("./notes_store")

local function test_add_trims_and_increments_id()
    local store = NotesStore.new()
    local first = assert(store:add("  Buy milk  "))
    local second = assert(store:add("Read book"))
    assert(first.id == 1 and first.text == "Buy milk")
    assert(second.id == 2 and second.text == "Read book")
    assert(#store.items == 2)
    print("PASS add trims and increments id")
end

local function test_add_rejects_empty_and_not_string()
    local store = NotesStore.new()
    local note1, err1 = store:add("   \t\n ")
    assert(note1 == nil and err1 == "Note text is required")
    local note2, err2 = store:add(nil)
    assert(note2 == nil and err2 == "Note text is required")
    assert(#store:list() == 0)
    print("PASS add rejects empty and non-string")
end

local function test_delete_removes_without_holes()
    local store = NotesStore.new({
        { id = 1, text = "One" },
        { id = 2, text = "Two" },
        { id = 3, text = "Three" }
    })
    assert(store:delete(2) == true)
    local items = store:list()
    assert(#items == 2 and items[1].id == 1 and items[2].id == 3)
    assert(store:delete(999) == false)
    print("PASS delete removes without holes")
end

local function test_new_starts_after_max_id()
    local store = NotesStore.new({
        { id = 5, text = "Existing" }
    })
    local added = assert(store:add("Next"))
    assert(added.id == 6)
    print("PASS new starts after max id")
end

test_add_trims_and_increments_id()
test_add_rejects_empty_and_not_string()
test_delete_removes_without_holes()
test_new_starts_after_max_id()
print("ALL PASSED")
