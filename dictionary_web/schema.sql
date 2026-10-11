CREATE TABLE IF NOT EXISTS words (
	id INTEGER PRIMARY KEY,
	word TEXT NOT NULL,
	source TEXT NOT NULL,
	entry TEXT,
	lookup_count INTEGER NOT NULL DEFAULT 1,
	first_seen INTEGER NOT NULL,
	last_seen INTEGER NOT NULL,
	fetched_at INTEGER,
	note TEXT NOT NULL DEFAULT '',
	review_count INTEGER NOT NULL DEFAULT 0,
	streak INTEGER NOT NULL DEFAULT 0,
	due_at INTEGER NOT NULL,
	UNIQUE(word, source)
);

CREATE TABLE IF NOT EXISTS proverbs (
	id INTEGER PRIMARY KEY,
	date TEXT UNIQUE NOT NULL,
	text TEXT NOT NULL,
	chinese TEXT NOT NULL,
	explanation TEXT NOT NULL DEFAULT '',
	audio_url TEXT,
	created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS word_organization (
    word TEXT PRIMARY KEY,
    folder TEXT NOT NULL DEFAULT '',
    tags TEXT NOT NULL DEFAULT '[]'
);

CREATE TABLE IF NOT EXISTS study_meanings (
    word TEXT PRIMARY KEY,
    meaning TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS study_examples (
    word TEXT PRIMARY KEY,
    example TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS review_log (
    id INTEGER PRIMARY KEY,
    word_id INTEGER NOT NULL,
    rated_at INTEGER NOT NULL,
    grade INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS review_log_time ON review_log(rated_at);
