#!/usr/bin/env python3
"""PTY smoke tests for luatop.lua after moving to the shared termkit module:
startup, mouse reporting, key dispatch, resize, clean quit and signal cleanup."""

import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "luatop.lua")
FAILURES = []


def check(name, cond, detail=""):
    if cond:
        print("  \033[32m✔\033[0m " + name)
    else:
        print("  \033[31m✘\033[0m " + name + (" :: " + detail if detail else ""))
        FAILURES.append(name)


class Session:
    def __init__(self, rows=30, cols=110, argv=None):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ["TERM"] = "xterm"
            os.chdir(HERE)
            os.execvp("luajit", argv or ["luajit", SCRIPT])
        self.resize(rows, cols, notify=False)

    def resize(self, rows, cols, notify=True):
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        if notify:
            os.kill(self.pid, signal.SIGWINCH)

    def read(self, seconds):
        out = b""
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([self.fd], [], [], 0.1)
            if ready:
                try:
                    chunk = os.read(self.fd, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                out += chunk
        return out.decode("utf-8", errors="replace")

    def send(self, data):
        os.write(self.fd, data.encode())

    def finish(self, timeout=4.0):
        end = time.time() + timeout
        while time.time() < end:
            done, status = os.waitpid(self.pid, os.WNOHANG)
            if done:
                return os.waitstatus_to_exitcode(status)
            self.read(0.1)
        os.kill(self.pid, signal.SIGKILL)
        os.waitpid(self.pid, 0)
        return None


def test_startup_and_quit():
    print("\n▶ luatop startup, input and quit")
    s = Session()
    out = s.read(2.5)
    check("enters the alternate screen with wrap off and cursor hidden",
          "\x1b[?1049h" in out and "\x1b[?7l" in out and "\x1b[?25l" in out)
    check("mouse reporting is enabled", "\x1b[?1000h" in out and "\x1b[?1006h" in out)
    check("draws the dashboard", "luatop" in out.lower() or "CPU" in out)
    s.send("\x1b[B\x1b[B\x1b[A")
    out = s.read(0.8)
    check("arrow-key burst is processed without crashing", "error" not in out.lower())
    s.send("\x1b[<64;20;10M")
    out = s.read(0.6)
    check("mouse wheel event is accepted", "error" not in out.lower())
    s.send("q")
    out = s.read(1.0)
    check("quit restores screen, cursor, wrap and mouse",
          "\x1b[?1049l" in out and "\x1b[?25h" in out and "\x1b[?7h" in out
          and "\x1b[?1000l" in out)
    check("exit status 0", s.finish() == 0)


def test_resize_and_signals():
    print("\n▶ luatop resize and signals")
    s = Session()
    s.read(2.0)
    s.resize(40, 130)
    out = s.read(1.5)
    check("resize does not crash", "error" not in out.lower() and "\x1b[?1049l" not in out)
    os.kill(s.pid, signal.SIGTERM)
    out = s.read(1.0)
    check("SIGTERM restores the terminal",
          "\x1b[?1049l" in out and "\x1b[?25h" in out and "\x1b[?1000l" in out)
    check("SIGTERM exits with 143", s.finish() == 143)


def run_with_piped_input(keys, timeout=10):
    """Runs luatop with `keys` on a pipe that then closes; None means it hung."""
    try:
        result = subprocess.run(["luajit", SCRIPT], input=keys, cwd=HERE,
                                capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None
    return result.returncode


def test_end_of_input_quits_from_every_mode():
    print("\n▶ luatop end of piped input")
    cases = [
        ("normal mode", b""),
        ("search mode", b"/"),
        ("search mode with a query", b"/abc"),
        ("diagnostic command editing", b": x"),
        ("help dialog", b"?"),
        ("signal dialog", b"k"),
    ]
    for name, keys in cases:
        code = run_with_piped_input(keys)
        check("EOF in %s exits with status 0" % name, code == 0,
              "hung" if code is None else "status %s" % code)


# Lua run with `luajit -e`: replaces the telemetry gatherer that luatop's main
# loop calls, then starts luatop. %s is the replacement, given the original
# function as `original`; %s is the entry point to run.
DRIVER_TEMPLATE = """
local luatop = require("luatop")
local index = 1
while true do
    local name, original = debug.getupvalue(luatop.main, index)
    if not name then
        error("upvalue gather_snapshot not found")
    end
    if name == "gather_snapshot" then
        debug.setupvalue(luatop.main, index, %s)
        break
    end
    index = index + 1
end
%s
"""

# Makes the first telemetry read inside the main loop raise.
CRASH_DRIVER = DRIVER_TEMPLATE % (
    'function() error("injected telemetry failure") end',
    "os.exit(luatop.run_protected({}))",
)

# Counts telemetry reads and writes the total to $LUATOP_GATHER_COUNT on exit.
COUNT_DRIVER = DRIVER_TEMPLATE % (
    """(function()
        gather_calls = 0
        return function(...)
            gather_calls = gather_calls + 1
            return original(...)
        end
    end)()""",
    """local code = luatop.main({})
local out = assert(io.open(os.getenv("LUATOP_GATHER_COUNT"), "w"))
out:write(tostring(gather_calls))
out:close()
os.exit(code)""",
)


def test_runtime_error_restores_terminal():
    print("\n▶ luatop runtime error inside the main loop")
    s = Session(argv=["luajit", "-e", CRASH_DRIVER])
    out = s.read(2.5)
    check("the dashboard had entered the alternate screen", "\x1b[?1049h" in out)
    check("error restores screen, cursor, wrap and mouse",
          "\x1b[?1049l" in out and "\x1b[?25h" in out and "\x1b[?7h" in out
          and "\x1b[?1000l" in out)
    restored_at = out.rfind("\x1b[?1049l")
    reported_at = out.find("luatop: fatal error:")
    check("the error is reported after the screen is restored",
          0 <= restored_at < reported_at, out[-300:])
    check("the report names the cause and includes a traceback",
          "injected telemetry failure" in out and "stack traceback" in out)
    check("exit status 1", s.finish() == 1)


def test_modals_on_short_terminals():
    print("\n▶ luatop modals on short terminals")
    cases = [
        ("help", "?", 18, 80, "Close Help Dialog"),
        ("help", "?", 10, 80, "Close Help Dialog"),
        ("inspector", "i", 12, 80, "Close Inspector"),
        # From the main view "k" moves the selection up, so go via the inspector.
        ("signal picker", "ik", 9, 80, "[Esc] Cancel"),
        ("renice", "R", 8, 60, "[Esc] Cancel"),
        ("diagnostic runner", ":", 9, 80, "Diagnostic Runner"),
    ]
    for name, key, rows, cols, expected in cases:
        s = Session(rows=rows, cols=cols)
        s.read(1.5)
        s.send(key)
        out = s.read(1.0)
        label = "%s at %dx%d" % (name, rows, cols)
        check(label + " draws without invalid cursor escapes",
              "\x1b[-" not in out and expected in out, repr(out[-200:]))
        s.send("\x1b")
        s.read(0.3)
        s.send("q")
        s.read(0.5)
        check(label + " closes and quits with status 0", s.finish() == 0)


def count_gathers(keys_before, burst, settle=0.5):
    """Runs luatop, sends keys_before, then `burst` one key at a time, and
    returns (telemetry reads, burst output, exit status, seconds running)."""
    count_path = os.path.join(tempfile.mkdtemp(prefix="luatop_pty_"), "count")
    os.environ["LUATOP_GATHER_COUNT"] = count_path
    started = time.time()
    # Wide enough that the header is not cut off before its [PAUSED] marker.
    s = Session(cols=220, argv=["luajit", "-e", COUNT_DRIVER])
    s.read(settle)
    if keys_before:
        s.send(keys_before)
        s.read(0.15)
    out = ""
    for key in burst:
        s.send(key)
        out += s.read(0.03)
    out += s.read(0.3)
    s.send("\x1b")
    s.read(0.2)
    s.send("q")
    s.read(0.5)
    status = s.finish()
    elapsed = time.time() - started
    with open(count_path) as handle:
        return int(handle.read()), out, status, elapsed


def test_keypress_redraws_without_new_telemetry():
    print("\n▶ luatop keypresses redraw from the last snapshot")
    burst = "j" * 30

    gathers, out, status, _ = count_gathers(" ", burst)
    check("paused: 30 keypresses read telemetry once in total",
          gathers == 1, "gathered %d times" % gathers)
    check("paused: the header says so", "[PAUSED]" in out)
    check("paused: each keypress still redraws", out.count("\x1b[?2026h") >= 25,
          "%d frames" % out.count("\x1b[?2026h"))
    check("paused run exits with status 0", status == 0)

    # Only the 1 s refresh timer may read telemetry: one read for the first
    # frame, one per elapsed second, and one of slack for timing.
    gathers, out, status, elapsed = count_gathers("", burst)
    allowed = int(elapsed) + 2
    check("running: 30 keypresses do not add telemetry reads",
          1 <= gathers <= allowed and gathers < len(burst),
          "gathered %d times in %.1f s (allowed %d)" % (gathers, elapsed, allowed))
    check("running run exits with status 0", status == 0)

    gathers, out, status, _ = count_gathers(" ", "/zzqqxxnomatch")
    check("paused: typing a filter still narrows the list immediately",
          "No processes matching filter" in out and gathers == 1,
          "gathered %d times" % gathers)

    gathers, out, status, _ = count_gathers(" ", " ", settle=0.3)
    check("unpausing reads telemetry again", gathers >= 2,
          "gathered %d times" % gathers)


def main():
    test_startup_and_quit()
    test_keypress_redraws_without_new_telemetry()
    test_modals_on_short_terminals()
    test_runtime_error_restores_terminal()
    test_resize_and_signals()
    test_end_of_input_quits_from_every_mode()
    print("\n=== %d failed ===" % len(FAILURES))
    sys.exit(1 if FAILURES else 0)


if __name__ == "__main__":
    main()
