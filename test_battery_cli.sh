#!/usr/bin/env bash
# =============================================================================
# End-to-end CLI tests for battery_monitor.lua (exit codes, diagnostics, pty).
# Usage: ./test_battery_cli.sh
# All tests use a private temporary database; the user's real DB is never touched.
# =============================================================================

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/battery_monitor.lua"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export BATTERY_DB="$TMP/test.db"
PASS=0
FAIL=0

# check <name> <expected_exit> <stderr_pattern or ""> -- <command...>
check() {
    local name="$1"
    local want_rc="$2"
    local pattern="$3"
    shift 4
    local out
    out="$("$@" 2>"$TMP/stderr" </dev/null)"
    local rc=$?
    local err
    err="$(cat "$TMP/stderr")"
    if [ "$rc" -ne "$want_rc" ]; then
        echo "  [FAIL] $name: exit $rc, expected $want_rc"
        echo "         stderr: $err"
        FAIL=$((FAIL + 1))
        return
    fi
    if [ -n "$pattern" ] && ! grep -qE -e "$pattern" <<<"$err"; then
        echo "  [FAIL] $name: stderr does not match /$pattern/"
        echo "         stderr: $err"
        FAIL=$((FAIL + 1))
        return
    fi
    echo "  [PASS] $name"
    PASS=$((PASS + 1))
}

echo "=== battery_monitor.lua CLI tests ==="

# -- Static checks: no undeclared globals (a typo'd variable silently becomes nil) -
globals_found="$(luajit -bl "$SCRIPT" | grep -E 'G(GET|SET)' \
    | grep -vE '"(require|ipairs|pairs|print|tostring|tonumber|type|pcall|xpcall|assert|io|os|string|math|table|debug|setmetatable|arg|ffi|bit)"')"
if [ -z "$globals_found" ]; then
    echo "  [PASS] bytecode shows 0 undeclared globals"
    PASS=$((PASS + 1))
else
    echo "  [FAIL] undeclared globals:"
    echo "$globals_found"
    FAIL=$((FAIL + 1))
fi

# -- Argument validation -------------------------------------------------------
check "unknown flag rejected" 2 "Unknown option '--tuii'" -- luajit "$SCRIPT" --tuii
check "--db without value rejected" 2 "--db requires" -- luajit "$SCRIPT" --db
check "--db followed by flag rejected" 2 "--db requires" -- luajit "$SCRIPT" --db --seed
check "--plot non-numeric rejected" 2 "expects a positive number" -- luajit "$SCRIPT" --plot abc
check "--history zero rejected" 2 "expects a positive number" -- luajit "$SCRIPT" --history 0
rm -f "$BATTERY_DB"
check "unknown flag exits before touching DB" 2 "" -- luajit "$SCRIPT" --bogus
if [ -e "$BATTERY_DB" ]; then
    echo "  [FAIL] unknown flag created a database file"
    FAIL=$((FAIL + 1))
else
    echo "  [PASS] no database file created for rejected arguments"
    PASS=$((PASS + 1))
fi
check "--help succeeds" 0 "" -- luajit "$SCRIPT" --help

# -- TUI without a terminal ----------------------------------------------------
check "--tui on non-tty exits non-zero" 1 "Could not start the interactive UI" -- \
    luajit "$SCRIPT" --tui

# -- Database creation, corruption and permission failures -----------------------
echo "--- database behaviour"
rm -f "$BATTERY_DB" "$BATTERY_DB-wal" "$BATTERY_DB-shm"
check "first run announces DB creation" 0 "does not exist; creating a new one" -- \
    luajit "$SCRIPT" --seed
second_err="$(luajit "$SCRIPT" --history 3 2>&1 >/dev/null </dev/null)"
if grep -q "creating a new one" <<<"$second_err"; then
    echo "  [FAIL] existing DB must not trigger the creation notice"
    FAIL=$((FAIL + 1))
else
    echo "  [PASS] existing DB reopens without a creation notice"
    PASS=$((PASS + 1))
fi

count_after_seed="$(luajit "$SCRIPT" --history 500 2>/dev/null | grep -cE '^ [0-9]{4}-')"
if [ "$count_after_seed" -eq 144 ]; then
    echo "  [PASS] --seed stored 144 rows"
    PASS=$((PASS + 1))
else
    echo "  [FAIL] --seed stored $count_after_seed rows, expected 144"
    FAIL=$((FAIL + 1))
fi

printf 'this is definitely not an sqlite database, just some text padding padding padding' \
    >"$TMP/corrupt.db"
cp "$TMP/corrupt.db" "$TMP/corrupt.orig"
check "corrupt DB fails with a clear message" 1 "corrupt.db.*(not a database|code 26)" -- \
    luajit "$SCRIPT" --db "$TMP/corrupt.db" --history
if cmp -s "$TMP/corrupt.db" "$TMP/corrupt.orig"; then
    echo "  [PASS] corrupt DB left untouched (no silent replacement)"
    PASS=$((PASS + 1))
else
    echo "  [FAIL] corrupt DB was modified"
    FAIL=$((FAIL + 1))
fi

check "unopenable DB path fails and names the path" 1 "/proc/no_such_dir/x.db" -- \
    luajit "$SCRIPT" --db /proc/no_such_dir/x.db --history
check "directory as DB path fails" 1 "DB ERROR" -- luajit "$SCRIPT" --db "$TMP" --history

if [ "$(id -u)" -ne 0 ]; then
    # A rollback-journal (non-WAL) database, as produced by older versions or other tools
    python3 - "$TMP/readonly.db" <<'PYEOF'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("""CREATE TABLE battery_snapshots (
    id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp INTEGER NOT NULL, capacity INTEGER NOT NULL,
    status TEXT NOT NULL, voltage_v REAL NOT NULL, power_w REAL NOT NULL, energy_wh REAL NOT NULL,
    health_pct REAL NOT NULL, cycle_count INTEGER NOT NULL)""")
con.execute("CREATE INDEX idx_battery_timestamp ON battery_snapshots(timestamp)")
con.execute("INSERT INTO battery_snapshots VALUES (NULL, 1700000000, 77, 'Full', 12.1, 0, 40, 88, 5)")
con.commit()
con.close()
PYEOF
    chmod 444 "$TMP/readonly.db"
    check "read-only DB still readable with visible WAL warning" 0 "WARN.*default journal mode" -- \
        luajit "$SCRIPT" --db "$TMP/readonly.db" --history 3
    check "read-only DB write fails explicitly" 1 "readonly|read-only|locked|ERROR" -- \
        luajit "$SCRIPT" --db "$TMP/readonly.db" --seed
else
    echo "  [SKIP] read-only DB tests (running as root)"
fi

start_ns="$(date +%s%N)"
luajit "$SCRIPT" --db "$TMP/speed.db" --seed >/dev/null 2>&1
elapsed_ms=$(( ($(date +%s%N) - start_ns) / 1000000 ))
echo "  [INFO] --seed into a fresh DB took ${elapsed_ms} ms"

# -- Live pseudo-terminal tests (Ctrl+C, SIGTERM, resize, help) -------------------
if command -v python3 >/dev/null 2>&1; then
    if python3 "$HERE/test_battery_pty.py"; then
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] pty test suite"
        FAIL=$((FAIL + 1))
    fi
else
    echo "  [SKIP] pty tests: python3 not found"
fi

echo "=== Passed: $PASS  Failed: $FAIL ==="
[ "$FAIL" -eq 0 ]
