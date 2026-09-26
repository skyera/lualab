#!/usr/bin/env luajit
--------------------------------------------------------------------------------
-- test_ffi_dict.lua
-- Comprehensive test suite for ffi_dict.lua (Offline Vocabulary Trainer & Dictionary)
--------------------------------------------------------------------------------

local dict = require("ffi_dict")
local Database = dict.Database
local SM2 = dict.SM2
local JSON = dict.JSON
local Quiz = dict.Quiz
local Importer = dict.Importer
local STUDY_TRACKS = dict.STUDY_TRACKS

local luajit_bin = "luajit"
if arg and arg[-1] and #arg[-1] > 0 then
    luajit_bin = arg[-1]
else
    local f_check = io.open("./LuaJIT/src/luajit", "rb")
    if f_check then
        f_check:close()
        luajit_bin = "./LuaJIT/src/luajit"
    end
end

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

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected '%s', got '%s'", msg or "Assertion failed", tostring(expected), tostring(actual)), 2)
    end
end

local function assert_near(actual, expected, eps, msg)
    if math.abs(actual - expected) > (eps or 1e-9) then
        error(string.format("%s: expected ~%s, got %s", msg or "Assertion failed", tostring(expected), tostring(actual)), 2)
    end
end

print("================================================================================")
print("  Running Integration & Unit Test Suite for ffi_dict.lua")
print("================================================================================")

local test_db_path = "/tmp/_test_ffi_dict_suite_" .. os.time() .. ".db"
os.remove(test_db_path)
os.remove(test_db_path .. "-wal")
os.remove(test_db_path .. "-shm")

local db = assert(Database.open(test_db_path))

TestRunner.describe("1. SQLite Schema and Initialization", function()
    TestRunner.it("should initialize database object and connection handle", function()
        assert_true(db ~= nil and db.db ~= nil, "Database handle should not be nil")
    end)

    TestRunner.it("should create all core tables without error", function()
        local rows = assert(db:query("SELECT name FROM sqlite_master WHERE type = 'table';"))
        local names = {}
        for _, r in ipairs(rows) do names[r.name] = true end
        for _, t in ipairs({ "meta", "dict", "dict_fts", "words", "srs", "reviews" }) do
            assert_true(names[t], "missing table: " .. t)
        end
    end)

    TestRunner.it("should index case-insensitive dictionary replacement lookups", function()
        local plan = assert(db:query(
            "EXPLAIN QUERY PLAN SELECT id FROM dict WHERE lower(word) = lower(?);", { "ephemeral" }))
        local indexed = false
        for _, row in ipairs(plan) do
            if row.detail and row.detail:find("idx_dict_word_lower", 1, true) then
                indexed = true
                break
            end
        end
        assert_true(indexed, "lower(word) lookup should use idx_dict_word_lower")
    end)

    TestRunner.it("should report empty stats on a fresh database", function()
        local s = db:stats(1000)
        assert_eq(s.total, 0, "deck should start empty")
        assert_eq(s.dict_words, 0, "dictionary should start empty")
        assert_eq(#s.day_counts, 14, "sparkline covers 14 days")
    end)
end)

TestRunner.describe("2. JSON Decoder", function()
    TestRunner.it("should decode nested objects, arrays and scalar types", function()
        local obj = JSON.decode('{"a": [1, 2.5, true, "x"], "b": {"c": "d"}, "n": null, "f": false}')
        assert_eq(obj.a[1], 1)
        assert_eq(obj.a[2], 2.5)
        assert_eq(obj.a[3], true)
        assert_eq(obj.a[4], "x")
        assert_eq(obj.b.c, "d")
        assert_true(obj.n == nil, "null decodes to nil")
        assert_eq(obj.f, false)
    end)

    TestRunner.it("should decode string escapes including \\u and surrogate pairs", function()
        local obj = JSON.decode('{"s": "a\\nb\\t\\"q\\" \\u0041 \\ud83d\\ude00"}')
        assert_eq(obj.s, "a\nb\t\"q\" A \240\159\152\128")
    end)

    TestRunner.it("should reject malformed JSON", function()
        assert_true(not pcall(JSON.decode, "{bad"), "malformed object must error")
        assert_true(not pcall(JSON.decode, '{"a": }'), "missing value must error")
        assert_true(not pcall(JSON.decode, "[1, 2"), "unterminated array must error")
    end)
end)

TestRunner.describe("3. Dictionary Import & Lookup", function()
    local wordset = {
        ephemeral = { word = "ephemeral", meanings = {
            { def = "lasting for a very short time", speech_part = "adjective",
              example = "Fame in the world of art is ephemeral.", synonyms = { "transient", "fleeting" } },
            { def = "a short-lived insect", speech_part = "noun" },
        } },
        obstinate = { word = "obstinate", meanings = {
            { def = "stubbornly refusing to change one's opinion", speech_part = "adjective",
              example = "The obstinate child refused to eat.", synonyms = { "stubborn" } },
        } },
    }

    TestRunner.it("should ingest wordset-format entries with all senses", function()
        local w, s = Importer.ingest_wordset(db, wordset)
        assert_eq(w, 2, "two words ingested")
        assert_eq(s, 3, "three senses ingested")
        local senses = db:dict_lookup("ephemeral")
        assert_eq(#senses, 2, "ephemeral has two senses")
        assert_true(senses[1].definition:find("very short time"), "first sense definition")
        assert_true(senses[1].example:find("ephemeral"), "example stored")
        assert_true(senses[1].syn:find("transient"), "synonyms joined")
        assert_eq(senses[2].pos, "noun")
    end)

    TestRunner.it("should replace senses on re-import instead of duplicating", function()
        local w, s = Importer.ingest_wordset(db, wordset)
        assert_eq(w, 2)
        assert_eq(s, 3, "re-import overwrites")
        local senses = db:dict_lookup("ephemeral")
        assert_eq(#senses, 2, "no duplicate senses")
    end)

    TestRunner.it("should find words via FTS5 search over definitions", function()
        local hits = db:dict_search("stubbornly")
        assert_true(#hits >= 1, "FTS hit expected")
        assert_eq(hits[1].word, "obstinate")
    end)

    TestRunner.it("should fall back to prefix search on unknown terms", function()
        local hits = db:dict_search("obsti")
        assert_true(#hits >= 1, "prefix fallback hit expected")
        assert_eq(hits[1].word, "obstinate")
    end)

    TestRunner.it("should ingest Webster 1913 format (word -> list of defs)", function()
        local w, s = Importer.ingest_webster(db, {
            laconic = { "using very few words", "terse" },
        })
        assert_eq(w, 1)
        assert_eq(s, 2)
        local senses = db:dict_lookup("laconic")
        assert_eq(#senses, 2)
        assert_eq(senses[1].definition, "using very few words")
    end)

    TestRunner.it("should parse CSV with quoted fields and escaped quotes", function()
        local f = Importer.parse_csv_line('foo,adj,"a ""quoted"" word, with comma"')
        assert_eq(f[1], "foo")
        assert_eq(f[2], "adj")
        assert_eq(f[3], 'a "quoted" word, with comma')
        local h = Importer.parse_csv_line('word,pos,definition')
        assert_eq(h[3], "definition", "header row parsed")
    end)

    TestRunner.it("should ingest CSV entries and skip the header row", function()
        local w, s = Importer.ingest_csv(db, 'word,pos,definition,example,syn,ant\nebullient,adj,"cheerful and full of energy","Her ebullient personality lit up the room.",energetic,flat\n')
        assert_eq(w, 1, "one word from csv")
        assert_eq(s, 1)
        local senses = db:dict_lookup("ebullient")
        assert_eq(#senses, 1)
        assert_eq(senses[1].definition, "cheerful and full of energy")
    end)
end)

TestRunner.describe("4. Study Plan", function()
    local plan_db_path = "/tmp/_test_ffi_dict_plan_" .. os.time() .. ".db"
    os.remove(plan_db_path); os.remove(plan_db_path .. "-wal"); os.remove(plan_db_path .. "-shm")
    local plan_db = assert(Database.open(plan_db_path))

    TestRunner.it("should expose the four requested tracks", function()
        assert_eq(#STUDY_TRACKS, 3, "three curated tracks plus mixed mode")
        assert_eq(STUDY_TRACKS[1].name, "Common English")
        assert_eq(STUDY_TRACKS[2].name, "Academic")
        assert_eq(STUDY_TRACKS[3].name, "Exam Prep")
        assert_eq(STUDY_TRACKS[1].id, "common")
        assert_eq(STUDY_TRACKS[2].id, "academic")
        assert_eq(STUDY_TRACKS[3].id, "exam")
        local ok, err = plan_db:study_plan_set("mixed", 7, 1000)
        assert_true(ok, err)
        local plan = plan_db:study_plan_get()
        assert_eq(plan.track, "mixed")
        assert_eq(plan.batch_size, 7)

        local path = "/tmp/_test_ffi_dict_plan_persistence_" .. os.time() .. ".db"
        os.remove(path); os.remove(path .. "-wal"); os.remove(path .. "-shm")
        local persistent = assert(Database.open(path))
        assert(persistent:study_plan_set("academic", 5, 1000))
        persistent:close()
        persistent = assert(Database.open(path))
        local saved = persistent:study_plan_get()
        assert_eq(saved.track, "academic", "track survives database reopen")
        assert_eq(saved.batch_size, 5, "batch size survives database reopen")
        persistent:close()
        os.remove(path); os.remove(path .. "-wal"); os.remove(path .. "-shm")
    end)

    TestRunner.it("should enforce valid track and per-session batch bounds", function()
        local ok, err = plan_db:study_plan_set("unknown", 10, 1000)
        assert_true(not ok and err:find("unknown"), "unknown track is rejected")
        ok, err = plan_db:study_plan_set("common", 0, 1000)
        assert_true(not ok and err:find("1 to 50"), "invalid session batch size is rejected")
    end)

    TestRunner.it("should choose only dictionary-backed words and avoid deck duplicates", function()
        Importer.ingest_wordset(plan_db, {
            ability = { meanings = { { def = "the power or skill to do something", speech_part = "noun" } } },
            accept = { meanings = { { def = "to receive or agree to something", speech_part = "verb" } } },
            achieve = { meanings = { { def = "to succeed in doing something", speech_part = "verb" } } },
            active = { meanings = { { def = "doing things or moving around", speech_part = "adjective" } } },
            abstract = { meanings = { { def = "existing as an idea rather than a physical thing", speech_part = "adjective" } } },
            abate = { meanings = { { def = "to become less intense", speech_part = "verb" } } },
        })
        local candidates = assert(plan_db:study_plan_candidates("common", 10))
        assert_true(#candidates > 0, "seed track intersects imported sample dictionary")
        for _, entry in ipairs(candidates) do
            assert_true(#entry.definition > 0, "candidate has a dictionary definition")
            assert_true(plan_db:deck_get(entry.word) == nil, "candidate is not already in deck")
        end
        assert(plan_db:deck_add({ word = candidates[1].word }, 1000))
        local next_candidates = assert(plan_db:study_plan_candidates("common", 10))
        for _, entry in ipairs(next_candidates) do
            assert_true(entry.word:lower() ~= candidates[1].word:lower(), "deck word excluded")
        end
        local mixed = assert(plan_db:study_plan_candidates("mixed", 3))
        assert_eq(#mixed, 3, "mixed track takes one available word per curriculum")
        local mixed_tracks = {}
        for _, entry in ipairs(mixed) do mixed_tracks[entry.source_track] = true end
        assert_true(mixed_tracks.common and mixed_tracks.academic and mixed_tracks.exam,
            "mixed mode draws from all eligible tracks")
    end)

    TestRunner.it("should fall back to unused general dictionary entries", function()
        local fallback_path = "/tmp/_test_ffi_dict_plan_fallback_" .. os.time() .. ".db"
        os.remove(fallback_path); os.remove(fallback_path .. "-wal"); os.remove(fallback_path .. "-shm")
        local fallback_db = assert(Database.open(fallback_path))
        Importer.ingest_wordset(fallback_db, {
            quasar = { meanings = { { def = "a compact astronomical object", speech_part = "noun" } } },
            zephyr = { meanings = { { def = "a gentle breeze", speech_part = "noun" } } },
        })
        assert(fallback_db:deck_add({ word = "quasar" }, 1000))
        local candidates = assert(fallback_db:study_plan_candidates("common", 5))
        assert_eq(#candidates, 1, "deck duplicate is excluded and other general word is offered")
        assert_eq(candidates[1].word, "zephyr")
        assert_eq(candidates[1].source_track, "general")
        assert_true(#candidates[1].definition > 0, "fallback includes imported definition")

        assert(fallback_db:study_plan_set("common", 2, 1000))
        local added = assert(fallback_db:study_plan_start_today(1000))
        assert_eq(#added, 1, "general fallback word can be added to plan")
        assert_eq(fallback_db:scalar("SELECT source_track FROM study_plan_words WHERE word_id = ?;", { added[1].id }),
            "general", "fallback source is persisted for adaptive mode")
        local none, exhaustion_message = fallback_db:study_plan_start_today(1000)
        assert_true(none and #none == 0, "general fallback stops when dictionary is exhausted")
        assert_true(exhaustion_message:find("no unused words remain"), "general dictionary exhaustion is explained")
        fallback_db:close()
        os.remove(fallback_path); os.remove(fallback_path .. "-wal"); os.remove(fallback_path .. "-shm")
    end)

    TestRunner.it("should allow multiple same-day batches without repeating words", function()
        local ok = plan_db:study_plan_set("common", 2, 1000)
        assert_true(ok)
        local today = os.date("%Y-%m-%d", 1000)
        assert_eq(plan_db:study_plan_today_count(today), 0)
        local no_selection, no_selection_message = plan_db:study_plan_start_today(1000, {})
        assert_true(no_selection and #no_selection == 0, "empty selection adds no words")
        assert_true(no_selection_message:find("no words selected"), "empty selection is explained")
        assert_eq(plan_db:study_plan_today_count(today), 0, "empty selection does not consume quota")

        local preview = assert(plan_db:study_plan_candidates("common", 2))
        local selection = { [preview[1].word] = true }
        local first_batch = assert(plan_db:study_plan_start_today(1000, selection))
        assert_eq(#first_batch, 1, "adds only the selected preview word")
        assert_eq(plan_db:study_plan_today_count(today), 1)
        local final_batch = assert(plan_db:study_plan_start_today(1000))
        assert_eq(#final_batch, 2, "second call adds a full batch on the same day")
        assert_eq(plan_db:study_plan_today_count(today), 3)
        assert_true(first_batch[1].word ~= final_batch[1].word, "subsequent batches do not repeat words")
        local seen = { [first_batch[1].word:lower()] = true }
        for _, word in ipairs(final_batch) do
            assert_true(not seen[word.word:lower()], "batch never repeats an earlier word")
            seen[word.word:lower()] = true
        end
        assert_eq(#plan_db:get_due(1000, 10), 4,
            "planned words join ordinary due queue alongside the candidate added earlier")

        local none, exhaustion_message = plan_db:study_plan_start_today(1000)
        assert_true(none and #none == 0, "returns empty only when no unused words remain")
        assert_true(exhaustion_message:find("no unused words remain"), "dictionary exhaustion is explained")
        local plan = plan_db:study_plan_get()
        assert_eq(plan.track, "common", "selected plan persisted")
        assert_eq(plan.batch_size, 2, "per-session batch size persisted")
    end)

    TestRunner.it("should render a readable study-plan preview frame", function()
        local lines = dict.TUI.study_plan_frame({
            screen = "preview", heading = "Choose a track and daily goal", track_name = "Common English",
            preview = { { word = "ability", definition = "the power to do something", selected = true,
                source_track = "general" } },
        }, dict.Term.make_theme(true, true), 80, 24)
        local output = dict.TUI.render_lines(lines)
        assert_true(output:find("study plan", 1, true) ~= nil)
        assert_true(output:find("[x] ability", 1, true) ~= nil)
        assert_true(output:find("[General dictionary]", 1, true) ~= nil)
        assert_true(output:find("Enter add selected", 1, true) ~= nil)

        local choose_lines = dict.TUI.study_plan_frame({
            screen = "choose", track_idx = 1, batch_size = 10, due = 0, plan_today = 20,
        }, dict.Term.make_theme(true, true), 80, 24)
        local choose_output = dict.TUI.render_lines(choose_lines)
        assert_true(choose_output:find("New words per session: 10", 1, true) ~= nil,
            "plan UI identifies a per-session batch size")
        assert_true(choose_output:find("New words added today: 20", 1, true) ~= nil,
            "plan UI shows today's progress")
    end)

    plan_db:close()
    os.remove(plan_db_path); os.remove(plan_db_path .. "-wal"); os.remove(plan_db_path .. "-shm")
end)

TestRunner.describe("5. Deck Add & Auto-fill", function()
    TestRunner.it("should auto-fill missing fields from the imported dictionary", function()
        local id = assert(db:deck_add({ word = "ephemeral" }, 1000))
        assert_true(id ~= nil)
        local card = db:deck_get("ephemeral")
        assert_true(card.definition:find("very short time"), "auto-filled definition")
        assert_eq(card.pos, "adjective", "auto-filled pos")
        assert_true(card.example:find("Fame"), "auto-filled example")
        assert_true(card.syn:find("transient"), "auto-filled synonyms")
    end)

    TestRunner.it("should honor explicitly provided fields", function()
        assert(db:deck_add({ word = "taciturn", pos = "adjective", definition = "reserved speech" }, 1000))
        local card = db:deck_get("taciturn")
        assert_eq(card.definition, "reserved speech")
        assert_eq(card.pos, "adjective")
    end)

    TestRunner.it("should reject duplicate words", function()
        local id, err = db:deck_add({ word = "Ephemeral" }, 1000)
        assert_true(id == nil, "duplicate must fail")
        assert_true(err:find("already"), "duplicate error message")
    end)

    TestRunner.it("should reject unknown words without an explicit definition", function()
        local id, err = db:deck_add({ word = "zzzunknown" }, 1000)
        assert_true(id == nil, "unknown word must fail")
        assert_true(err:find("not found"), "unknown word error message")
    end)

    TestRunner.it("should accept unknown words when --def is provided", function()
        local id = assert(db:deck_add({ word = "zzzneologism", definition = "a made-up word" }, 1000))
        assert_true(id ~= nil)
    end)
end)

TestRunner.describe("5. SM-2 Spaced Repetition Scheduling", function()
    local st = SM2.new_state()

    TestRunner.it("should schedule a new card graded Good after 1 day", function()
        local s = assert(SM2.schedule(st, SM2.GRADE_GOOD, 1000))
        assert_eq(s.interval_days, 1)
        assert_eq(s.reps, 1)
        assert_eq(s.due_at, 1000 + 86400)
    end)

    TestRunner.it("should follow the 1 -> 3 -> ease-multiplied progression", function()
        local s1 = assert(SM2.schedule(st, SM2.GRADE_GOOD, 0))
        local s2 = assert(SM2.schedule(s1, SM2.GRADE_GOOD, 0))
        assert_eq(s2.interval_days, 3)
        assert_eq(s2.reps, 2)
        local s3 = assert(SM2.schedule(s2, SM2.GRADE_GOOD, 0))
        assert_near(s3.interval_days, 7.5, 1e-9, "third interval is interval * ease")
    end)

    TestRunner.it("should bump ease on Easy", function()
        local s = assert(SM2.schedule(st, SM2.GRADE_EASY, 0))
        assert_eq(s.interval_days, 2)
        assert_near(s.ease, 2.65, 1e-9)
    end)

    TestRunner.it("should penalize ease on Hard", function()
        local s = assert(SM2.schedule(st, SM2.GRADE_HARD, 0))
        assert_eq(s.interval_days, 0.5)
        assert_near(s.ease, 2.35, 1e-9)
    end)

    TestRunner.it("should register lapses and relearn after 10 minutes on Again", function()
        local s1 = assert(SM2.schedule(st, SM2.GRADE_GOOD, 0))
        local s2 = assert(SM2.schedule(s1, SM2.GRADE_GOOD, 0))
        local s3 = assert(SM2.schedule(s2, SM2.GRADE_GOOD, 0))
        local a = assert(SM2.schedule(s3, SM2.GRADE_AGAIN, 1000))
        assert_eq(a.reps, 0, "reps reset")
        assert_eq(a.lapses, 1, "lapse recorded")
        assert_eq(a.interval_days, 0)
        assert_eq(a.due_at, 1000 + SM2.AGAIN_DELAY)
        assert_near(a.ease, 2.3, 1e-9)
    end)

    TestRunner.it("should never drop ease below 1.3", function()
        local floor_st = { ease = 1.35, interval_days = 5, due_at = 0, reps = 2, lapses = 0 }
        local s = assert(SM2.schedule(floor_st, SM2.GRADE_AGAIN, 0))
        assert_eq(s.ease, 1.3)
        local s2 = assert(SM2.schedule(floor_st, SM2.GRADE_HARD, 0))
        assert_eq(s2.ease, 1.3)
    end)

    TestRunner.it("should reject invalid grades", function()
        local s, err = SM2.schedule(st, 7, 0)
        assert_true(s == nil and err ~= nil, "invalid grade rejected")
    end)
end)

TestRunner.describe("6. Due Queue & Review Logging", function()
    TestRunner.it("should list newly added cards as due", function()
        local due = db:get_due(1000, 10)
        assert_eq(#due, 3, "all added cards are due at add-time")
    end)

    TestRunner.it("should apply grades, update SRS state and log reviews", function()
        local due = db:get_due(1000, 10)
        local graded = assert(db:srs_apply(due[1].id, SM2.GRADE_GOOD, 1000))
        assert_eq(graded.reps, 1)
        assert_eq(graded.interval_days, 1)
        assert_eq(db:scalar("SELECT COUNT(*) FROM reviews;"), 1, "review logged")
        local st = db:srs_state(due[1].id)
        assert_eq(st.interval_days, 1)
    end)

    TestRunner.it("should exclude future-due cards from the queue", function()
        local due = db:get_due(1000, 10)
        assert_eq(#due, 2, "graded card no longer due")
        local later = db:get_due(1000 + 2 * 86400, 10)
        assert_eq(#later, 3, "card returns once due")
    end)

    TestRunner.it("should respect the limit and ordering", function()
        local due = db:get_due(1000 + 2 * 86400, 1)
        assert_eq(#due, 1, "limit honored")
    end)
end)

TestRunner.describe("7. Statistics & Word of the Day", function()
    TestRunner.it("should classify deck words by learning stage", function()
        local s = db:stats(1000)
        assert_eq(s.total, 3)
        assert_eq(s.reviews, 1)
        assert_eq(s.retention, 100, "one Good review = 100% retention")
        assert_eq(s.learning, 1, "one graded card is learning")
    end)

    TestRunner.it("should return a deterministic word of the day", function()
        local w1, src1 = db:wotd(1000)
        local w2 = db:wotd(1000)
        assert_true(w1 ~= nil, "wotd found")
        assert_eq(src1, "deck")
        assert_eq(w1.word, w2.word, "same word within a day")
        local w3 = db:wotd(1000 + 86400)
        assert_true(w3 ~= nil, "wotd next day")
    end)

    TestRunner.it("should track review day counts over 14 days", function()
        local counts = db:review_day_counts(1000, 14)
        assert_eq(#counts, 14)
    end)
end)

TestRunner.describe("8. Quiz Builder", function()
    local entry = {
        word = "ephemeral", pos = "adjective",
        definition = "lasting for a very short time",
        example = "Fame in the world of art is ephemeral.",
    }
    local pool = { "obstinate", "taciturn", "magnanimous", "laconic", "ebullient" }

    TestRunner.it("should mask the word in the example (case-insensitive, whole-word)", function()
        local masked, n = Quiz.mask_example("The Ephemeral mayfly; ephemeral.", "ephemeral")
        assert_eq(n, 2, "two occurrences masked")
        assert_true(masked:find("____") ~= nil)
        assert_true(masked:find("mayfly") ~= nil, "surrounding text kept")
    end)

    TestRunner.it("should build a cloze question when an example exists", function()
        local q = assert(Quiz.build(entry, pool, Quiz.lcg_rng(42)))
        assert_eq(q.kind, "cloze")
        assert_true(q.prompt:find("____") ~= nil, "blank inserted")
        assert_true(q.prompt:find("Fame") ~= nil)
    end)

    TestRunner.it("should fall back to a meaning question without example", function()
        local e2 = { word = "taciturn", definition = "reserved speech" }
        local q = assert(Quiz.build(e2, pool, Quiz.lcg_rng(1)))
        assert_eq(q.kind, "meaning")
        assert_true(q.prompt:find("reserved speech") ~= nil)
    end)

    TestRunner.it("should produce 4 unique choices including the answer", function()
        local q = assert(Quiz.build(entry, pool, Quiz.lcg_rng(7)))
        assert_eq(#q.choices, 4)
        local seen = {}
        for _, c in ipairs(q.choices) do
            assert_true(not seen[c], "choices must be unique")
            seen[c] = true
        end
        assert_true(seen["ephemeral"], "answer present in choices")
        assert_true(seen[q.choices[q.answer_idx]], "answer_idx points at answer")
    end)

    TestRunner.it("should be deterministic for the same seed", function()
        local q1 = assert(Quiz.build(entry, pool, Quiz.lcg_rng(42)))
        local q2 = assert(Quiz.build(entry, pool, Quiz.lcg_rng(42)))
        assert_eq(table.concat(q1.choices, "|"), table.concat(q2.choices, "|"))
        assert_eq(q1.answer_idx, q2.answer_idx)
    end)

    TestRunner.it("should validate answers via check()", function()
        local q = assert(Quiz.build(entry, pool, Quiz.lcg_rng(3)))
        assert_true(Quiz.check(q, q.answer_idx), "correct index accepted")
        assert_true(not Quiz.check(q, (q.answer_idx % 4) + 1), "wrong index rejected")
    end)

    TestRunner.it("should reject pools with too few distractors", function()
        local q, err = Quiz.build(entry, { "only-one" }, Quiz.lcg_rng(1))
        assert_true(q == nil and err ~= nil, "insufficient distractors rejected")
    end)
end)

TestRunner.describe("9. CLI Integration", function()
    local cli_db = "/tmp/_test_ffi_dict_cli_" .. os.time() .. ".db"
    os.remove(cli_db); os.remove(cli_db .. "-wal"); os.remove(cli_db .. "-shm")

    TestRunner.it("should execute ffi_dict.lua --help and mention study plans", function()
        local out = os.tmpname()
        local ret = os.execute(string.format('"%s" ffi_dict.lua --help > %s 2>&1', luajit_bin, out))
        assert_true(ret == 0 or ret == true, "--help exit code")
        local f = io.open(out, "r"); local text = f:read("*a"); f:close(); os.remove(out)
        assert_true(text:find("plan", 1, true) ~= nil, "help lists study-plan command")
        assert_true(text:find("git clone https://github.com/wordset/wordset-dictionary.git", 1, true) ~= nil,
            "help includes a copyable Wordset download command")
        assert_true(text:find("import --wordset ./wordset-dictionary/data", 1, true) ~= nil,
            "help includes a copyable Wordset import command")
    end)

    TestRunner.it("should pass the built-in --test suite", function()
        local ret = os.execute(string.format('"%s" ffi_dict.lua --test > /dev/null 2>&1', luajit_bin))
        assert_true(ret == 0 or ret == true, "--test exit code")
    end)

    TestRunner.it("should import a wordset JSON file via the CLI", function()
        local f = io.open("/tmp/_test_ffi_dict_wordset.json", "w")
        f:write([[{
            "celerity": {"word": "celerity", "meanings": [{"def": "swiftness of movement", "speech_part": "noun", "example": "He completed the task with celerity."}]},
            "obstinate": {"word": "obstinate", "meanings": [{"def": "stubbornly refusing to change", "speech_part": "adjective"}]},
            "laconic": {"word": "laconic", "meanings": [{"def": "using very few words", "speech_part": "adjective"}]},
            "ebullient": {"word": "ebullient", "meanings": [{"def": "cheerful and full of energy", "speech_part": "adjective"}]},
            "magnanimous": {"word": "magnanimous", "meanings": [{"def": "generous and forgiving", "speech_part": "adjective"}]}
        }]])
        f:close()
        local out = os.tmpname()
        local ret = os.execute(string.format('"%s" ffi_dict.lua import --wordset /tmp/_test_ffi_dict_wordset.json --db %s > %s 2>&1',
            luajit_bin, cli_db, out))
        assert_true(ret == 0 or ret == true, "import exit code")
        local result = io.open(out, "r")
        local text = result:read("*a")
        result:close()
        os.remove(out)
        assert_true(text:find("Scanning /tmp/_test_ffi_dict_wordset.json", 1, true) ~= nil,
            "import reports scan and candidate file count")
        assert_true(text:find("[1/1] Importing /tmp/_test_ffi_dict_wordset.json", 1, true) ~= nil,
            "import reports file start")
        assert_true(text:find("done: 5 words / 5 senses | elapsed ", 1, true) ~= nil,
            "import reports per-file word and elapsed time")
        assert_true(text:find(" | ETA ~", 1, true) ~= nil,
            "import reports estimated time remaining")
        assert_true(text:find("imported 5 words (5 senses) from 1 file(s)", 1, true) ~= nil,
            "import reports final summary")
    end) 

    TestRunner.it("should report invalid JSON files during import", function()
        local bad_path = "/tmp/_test_ffi_dict_bad.json"
        local f = io.open(bad_path, "w")
        f:write("{invalid json")
        f:close()
        local out = os.tmpname()
        local ret = os.execute(string.format('"%s" ffi_dict.lua import --wordset %s --db %s > %s 2>&1',
            luajit_bin, bad_path, cli_db, out))
        assert_true(ret == 0 or ret == true, "import with skipped invalid JSON exits successfully")
        local result = io.open(out, "r")
        local text = result:read("*a")
        result:close()
        os.remove(out)
        os.remove(bad_path)
        assert_true(text:find("skipped: " .. bad_path, 1, true) ~= nil,
            "import explains why invalid JSON was skipped")
    end) 

    TestRunner.it("should add a word with auto-fill via the CLI", function()
        local ret = os.execute(string.format('"%s" ffi_dict.lua add celerity --db %s > /dev/null 2>&1',
            luajit_bin, cli_db))
        assert_true(ret == 0 or ret == true, "add exit code")
    end)

    TestRunner.it("should fail adding an unknown word without --def", function()
        local ret = os.execute(string.format('"%s" ffi_dict.lua add zzznoword --db %s > /dev/null 2>&1',
            luajit_bin, cli_db))
        assert_true(not (ret == 0 or ret == true), "add of unknown word must fail")
    end)

    TestRunner.it("should find the word via CLI lookup", function()
        local out = os.tmpname()
        local ret = os.execute(string.format('"%s" ffi_dict.lua lookup swiftness --db %s > %s 2>&1',
            luajit_bin, cli_db, out))
        assert_true(ret == 0 or ret == true, "lookup exit code")
        local f = io.open(out, "r"); local text = f:read("*a"); f:close(); os.remove(out)
        assert_true(text:find("celerity") ~= nil, "lookup output mentions celerity")
    end)

    TestRunner.it("should print stats via the CLI", function()
        local out = os.tmpname()
        local ret = os.execute(string.format('"%s" ffi_dict.lua stats --db %s > %s 2>&1',
            luajit_bin, cli_db, out))
        assert_true(ret == 0 or ret == true, "stats exit code")
        local f = io.open(out, "r"); local text = f:read("*a"); f:close(); os.remove(out)
        assert_true(text:find("deck") ~= nil, "stats output has deck line")
    end)

    TestRunner.it("should render review --snapshot headlessly", function()
        local out = os.tmpname()
        local ret = os.execute(string.format('"%s" ffi_dict.lua review --snapshot --db %s > %s 2>&1',
            luajit_bin, cli_db, out))
        assert_true(ret == 0 or ret == true, "review --snapshot exit code")
        local f = io.open(out, "r"); local text = f:read("*a"); f:close(); os.remove(out)
        assert_true(text:find("celerity") ~= nil, "snapshot shows the due card")
    end)

    TestRunner.it("should render quiz --snapshot headlessly with deterministic choices", function()
        local out1, out2 = os.tmpname(), os.tmpname()
        local cmd_fmt = '"%s" ffi_dict.lua quiz --snapshot --seed 42 --db %s > %s 2>&1'
        local r1 = os.execute(string.format(cmd_fmt, luajit_bin, cli_db, out1))
        local r2 = os.execute(string.format(cmd_fmt, luajit_bin, cli_db, out2))
        assert_true(r1 == 0 or r1 == true, "quiz --snapshot exit code")
        assert_true(r2 == 0 or r2 == true, "quiz --snapshot exit code (repeat)")
        local f = io.open(out1, "r"); local t1 = f:read("*a"); f:close(); os.remove(out1)
        f = io.open(out2, "r"); local t2 = f:read("*a"); f:close(); os.remove(out2)
        assert_true(t1:find("____") ~= nil, "quiz snapshot has a blank")
        assert_eq(t1, t2, "same seed renders identical output")
    end)

    TestRunner.it("should print word of the day via the CLI", function()
        local out = os.tmpname()
        local ret = os.execute(string.format('"%s" ffi_dict.lua wotd --db %s > %s 2>&1',
            luajit_bin, cli_db, out))
        assert_true(ret == 0 or ret == true, "wotd exit code")
        local f = io.open(out, "r"); local text = f:read("*a"); f:close(); os.remove(out)
        assert_true(text:find("word of the day") ~= nil)
    end)

    TestRunner.it("should run the study plan with text prompts when stdin is not a TTY", function()
        local out = os.tmpname()
        local ret = os.execute(string.format(
            'printf "q\\n" | "%s" ffi_dict.lua plan --db %s > %s 2>&1',
            luajit_bin, cli_db, out))
        assert_true(ret == 0 or ret == true, "text-mode plan exit code")
        local f = io.open(out, "r"); local text = f:read("*a"); f:close(); os.remove(out)
        assert_true(text:find("requires an interactive TTY", 1, true) == nil,
            "plan must not refuse to run without a TTY")
        assert_true(text:find("study plan", 1, true) ~= nil, "text plan shows the track chooser")
    end)

    os.remove(cli_db); os.remove(cli_db .. "-wal"); os.remove(cli_db .. "-shm")
    os.remove("/tmp/_test_ffi_dict_wordset.json")
end)

db:close()
os.remove(test_db_path)
os.remove(test_db_path .. "-wal")
os.remove(test_db_path .. "-shm")

print("\n================================================================================")
print(string.format("  TEST SUMMARY: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
print("================================================================================")

if TestRunner.failed > 0 then
    os.exit(1)
else
    print("\27[1;32mALL TESTS PASSED SUCCESSFULLY!\27[0m\n")
    os.exit(0)
end
