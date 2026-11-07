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
