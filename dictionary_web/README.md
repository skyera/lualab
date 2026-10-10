# Wordbook

A local vocabulary web app built with **LuaJIT and FFI**: Linux sockets serve
the browser UI, libcurl handles HTTPS, and SQLite stores your word journal.
No Python backend or npm installation is needed.

## Run

Install LuaJIT, SQLite, libcurl, and OpenSSL shared libraries. On Debian/Ubuntu:

```sh
sudo apt install luajit libsqlite3-0 libcurl4 libssl3
luajit dictionary_web/app.lua
```

Open **http://127.0.0.1:8765**. From any directory, use an absolute script path.
The server currently supports Linux and defaults to loopback for personal use.

Set up the offline dictionary with one command from the repository root:

```sh
luajit download_dict.lua
```

The script needs Git, LuaJIT, and SQLite. It downloads Wordset into the ignored
`downloads/wordset-dictionary/` directory, validates all 27 JSON files, imports
definitions into `.dict.db` in one transaction, and rebuilds the full-text
index. Saved vocabulary, notes, study plans, and reviews are preserved. If the
dictionary is already populated, it skips downloading/importing. Use `--force`
to refresh, or `--db PATH --cache-dir PATH` for custom locations.

Both applications automatically run setup when their selected dictionary is
missing or empty. Normal launches are sufficient:

```sh
luajit dictionary_web/app.lua --host 0.0.0.0
```

The TUI/CLI checks before running its normal commands:

```sh
luajit ffi_dict.lua review
luajit ffi_dict.lua lookup hello
```

To refresh manually, even when dictionary data is already present:

```sh
luajit ffi_dict.lua --import-dict
luajit dictionary_web/app.lua --host 0.0.0.0 --import-dict
```

The TUI option can be combined with a command; without one it refreshes and
exits. The web option refreshes, then starts serving. `--no-auto-import`
disables automatic setup. `--auto-import` is still accepted for compatibility.

This uses the database selected by `--dict-db` (default: the repo's `.dict.db`).
It downloads only if that dictionary is empty or missing; startup reports and
stops on download/import failure. `--dict-db none` skips setup and disables
local integration, and cannot be combined with `--import-dict`. Help, built-in
TUI tests and explicit file-import commands do not trigger automatic setup.

```sh
luajit dictionary_web/app.lua --port 8080 --db /path/to/words.db
luajit dictionary_web/app.lua --help
```

To allow other computers to access the app, listen on all IPv4 interfaces:

```sh
luajit dictionary_web/app.lua --host 0.0.0.0 --port 8765
```

Open `http://<server-IP>:8765` from another computer. Allow TCP port 8765 in
the server firewall. All visitors share the same journal and can edit notes
and review progress; the app has no login. Internet access also depends on
your router's port forwarding and network configuration. This option does
not enable IPv6 listening.

The default database is `dictionary_web/wordbook.db`, ignored by Git. Back up
that file with the app stopped. Ctrl-C and SIGTERM close the server and database.
The server processes one request at a time. Each outbound HTTPS request has a
12-second timeout; trying a configured Youdao API and then its public-page
fallback can take up to two timeouts and delay other requests.

## Dictionary sources

**All dictionaries** is the default search option. It checks Local dictionary,
dict.cn, and Youdao and displays separately labeled results as each finishes.
Unknown words and connection failures appear
on the affected source's card; successful results remain available. You can
still select a single source. The API also accepts `source: "all"` and returns
a `results` array. The local server handles requests sequentially, so slow
online sources may delay later results; local requests are issued first.

- **Local dictionary** reads imported definitions and
  saved vocabulary from the repository's `.dict.db`, used by `ffi_dict.lua`.
  It works offline. Looking up an imported word adds it to the shared TUI deck.
  Missing local entries can still be looked up with an online source.
- **dict.cn / 海词** works without API credentials by reading its public word
  page. Definitions, pronunciation text, and bilingual examples are extracted.
  Page layout changes or provider blocking may prevent extraction; the app
  shows the failure and provides a link to the original entry.
- **Youdao / 有道** works without API credentials by reading its public result
  page. The parser extracts visible definitions, pronunciation text, and
  bilingual examples for English, Chinese, and phrase queries. It does not
  execute page JavaScript or bypass challenges; blocked or changed pages show
  a clear failure with an original-source link.
  With credentials configured, it first uses the official dictionary API with
  v3 SHA256 signing and falls back to the public page if the API fails.
  Set `YOUDAO_APP_KEY` and `YOUDAO_APP_SECRET` in the server environment.
  Dictionary-service access must also be enabled for your Youdao application;
  ordinary translation credentials alone may not be enough. See
  <https://ai.youdao.com/DOCSIRMA/html/dictionary/api/ydcd/index.html>.

Youdao API keys stay in the server environment. Without them, Youdao uses its
public page. Only lookups with a usable definition are saved. Merriam-Webster
is no longer a supported search source; any older saved entries are retained
as archived entries, and their lookup buttons search the remaining sources.
Requests do not execute a shell or put credentials in command arguments.

## Learning features

- The web app automatically opens `.dict.db` beside `ffi_dict.lua` when it
  exists. Use `--dict-db /path/to/dictionary.db` for another TUI database, or
  `--dict-db none` to disable integration. Missing files are not created by the
  web app; use the existing TUI import commands to create/populate one.
- Existing TUI vocabulary appears in My words and Review with a **Shared with
  TUI** label. Imported dictionary entries are searchable through Local
  dictionary; the entire dictionary is not added to your review queue.
- Notes on shared words update the TUI's mnemonic field. Shared review cards
  offer **Again / Hard / Good / Easy**, using the existing SM-2 scheduler and
  writing the same `srs` and `reviews` tables. Changes made in either interface
  appear when you reopen the relevant view or look up the word again.
- Online history remains in `wordbook.db`. If an online query matches a shared
  deck word, its note and review controls use that shared word; My words avoids
  duplicate entries. Online-only words retain the original web review schedule.

- Failed, missing, or empty-definition results do not create history or
  increment lookup counts. In All dictionaries, only successful sources are
  saved. A failed refresh leaves any existing word, notes, and history unchanged.
  Existing history from earlier app versions is retained.
- Queries are trimmed and ASCII-case normalized, with one SQLite row per
  word/source. Repeated lookups update the count and last-seen timestamp.
- dict.cn definitions are saved and reused for 24 hours.
  After expiry, a lookup refreshes the definition. If refresh fails, an older
  saved definition is explicitly labeled.
- **Youdao forbids caching returned dictionary data**, so only the queried
  word, history, review state, and your own study notes are persisted for that
  source. Its definitions appear only during the current lookup.
- My words filters your journal. Add your own study notes from a lookup result.
- My words also has a **Delete** button with confirmation. For online-only
  entries it removes the selected saved entry and its notes/review state. For
  shared TUI vocabulary it removes the deck word, mnemonic, scheduling, review
  history, study-plan membership, and matching web history together. Imported
  dictionary entries remain searchable, and another lookup can save the word
  again. Cancelling the confirmation makes no changes.
- Review reveals saved definitions and notes. **Again** schedules a review in
  10 minutes. **Remembered** schedules 1, 2, 4, 8, 16, then up to 30 days, with
  the interval reset after an Again grade.
- With local integration, the daily word matches the TUI's daily selection:
  saved vocabulary first, imported dictionary otherwise. A curated selection
  is the fallback when no local words are available. Proverbs rotate from a
  collection of traditional sayings. Selections change at **UTC midnight**
  and are independent of provider “word of the day” feeds.
- Pronunciation playback uses browser speech synthesis when available; voice
  availability depends on the browser and operating system.

## Verify

Run from the repository root. Node.js is needed only for the HTTP/scoping tests:

```sh
luajit dictionary_web/tests/test_app.lua
luajit dictionary_web/tests/test_shared.lua
luajit test_ffi_dict.lua
luajit test_download_dict.lua
node --test dictionary_web/tests/test_http.js
node --check dictionary_web/static/app.js
```

The Lua suite checks SQLite persistence, duplicate handling, cache expiry,
UTF-8 queries, parsing, signing, failure paths, study notes, scheduling, and
daily rotation. The Node suite launches the actual LuaJIT server with temporary
SQLite storage, exercises HTTP requests, restarts it to check persistence,
checks clean signal exits, and analyzes LuaJIT bytecode for undeclared globals.
Provider tests use controlled responses and do not require API keys. Shared-data
tests use temporary TUI databases to verify two-way notes/reviews, all four
SM-2 grades, duplicate handling, overlapping IDs, and persistence. HTTP tests
disable the real `.dict.db` unless a temporary fixture is explicitly supplied.

For a real dict.cn smoke test while the app is running:

```sh
curl -sS http://127.0.0.1:8765/api/search \
  -H 'Content-Type: application/json' \
  -d '{"word":"serendipity","source":"dict.cn"}'
```

Manually verify Discover → My words → Review → Discover, saving a note,
revealing/grading a card, empty/filter states, and narrow/mobile layouts.
Youdao public-page verification does not require credentials. Live official
Youdao API verification requires valid credentials and
enabled provider accounts.
