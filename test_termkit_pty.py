#!/usr/bin/env python3
"""PTY tests for termkit.lua: raw-mode lifecycle, suspend/resume, burst input,
mouse reporting and signal cleanup, observed through a real pseudo-terminal."""

import os
import pty
import re
import select
import signal
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
FAILURES = []

DRIVER = r"""
package.path = "%s/?.lua;" .. package.path
local termkit = require("termkit")
local function icanon_state(label)
    local f = io.popen("stty -a 2>/dev/null")
    local text = f:read("*a")
    f:close()
    io.write("STATE:", label, ":", text:find("%%-icanon") and "raw" or "cooked", "\n")
    io.flush()
end
local busy = %s
local function sigblk(label)
    for line in io.lines("/proc/self/status") do
        local mask = line:match("^SigBlk:%%s*(%%x+)")
        if mask then
            io.write("SIGBLK:", label, ":", mask, "\n")
        end
    end
    io.flush()
end
local entered = termkit.enter({ mouse = %s })
io.write("ENTERED:", tostring(entered), " RAW:", tostring(termkit.is_raw()), "\n")
icanon_state("entered")
while true do
    local key = termkit.read_key(100)
    if key == "EOF" or key == "q" then
        break
    elseif type(key) == "table" then
        io.write("KEY:mouse-", key.btn, "\n")
    elseif key == "s" then
        termkit.suspend()
        icanon_state("suspended")
        os.execute("grep '^SigBlk' /proc/self/status | sed 's/^/CHILD_/'")
        termkit.resume()
        icanon_state("resumed")
        sigblk("resumed")
    elseif key == "z" then
        local cols, rows = termkit.size()
        io.write("SIZE:", cols, "x", rows, "\n")
    elseif key then
        io.write("KEY:", key, "\n")
    end
    io.flush()
    if busy then
        -- Simulate a dashboard doing real work: string formatting, table churn, GC.
        local deadline = os.clock() + 0.03
        while os.clock() < deadline do
            local rows = {}
            for i = 1, 200 do
                rows[i] = string.format("%%5d %%-12s %%6.2f", i, "process" .. i, i / 7)
            end
            local joined = table.concat(rows, "\n")
            if #joined == 0 then
                io.write("unreachable")
            end
        end
    end
end
termkit.leave()
termkit.leave()
icanon_state("left")
"""


def check(name, cond, detail=""):
    if cond:
        print("  \033[32m✔\033[0m " + name)
    else:
        print("  \033[31m✘\033[0m " + name + (" :: " + detail if detail else ""))
        FAILURES.append(name)


class Session:
    def __init__(self, mouse=False, rows=24, cols=80, busy=False):
        code = DRIVER % (HERE, "true" if busy else "false", "true" if mouse else "false")
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ["TERM"] = "xterm"
            os.execvp("luajit", ["luajit", "-e", code])
        import fcntl
        import struct
        import termios
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

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

    def finish(self, timeout=3.0):
        end = time.time() + timeout
        while time.time() < end:
            done, status = os.waitpid(self.pid, os.WNOHANG)
            if done:
                return os.waitstatus_to_exitcode(status)
            self.read(0.1)
        os.kill(self.pid, signal.SIGKILL)
        os.waitpid(self.pid, 0)
        return None


def test_lifecycle():
    print("\n▶ Raw-mode lifecycle")
    s = Session()
    out = s.read(1.0)
    check("enter() succeeds on a terminal", "ENTERED:true RAW:true" in out)
    check("alternate screen, hidden cursor, wrap off",
          "\x1b[?1049h" in out and "\x1b[?25l" in out and "\x1b[?7l" in out)
    check("no mouse reporting unless requested", "\x1b[?1000h" not in out)
    check("terminal is in non-canonical mode", "STATE:entered:raw" in out)
    s.send("q")
    out = s.read(1.0)
    check("leave() restores screen, cursor and wrap",
          "\x1b[?1049l" in out and "\x1b[?25h" in out and "\x1b[?7h" in out)
    check("leave() restores canonical mode", "STATE:left:cooked" in out)
    check("calling leave() twice emits the restore sequence once",
          out.count("\x1b[?1049l") == 1)
    check("exit status 0", s.finish() == 0)


def test_suspend_resume():
    print("\n▶ suspend()/resume() around a subprocess")
    s = Session()
    s.read(0.8)
    s.send("s")
    out = s.read(1.0)
    check("suspend() gives a cooked terminal", "STATE:suspended:cooked" in out)
    check("suspend() shows the cursor and re-enables wrap", "\x1b[?25h" in out)
    check("resume() returns to raw mode", "STATE:resumed:raw" in out)
    check("resume() hides the cursor again", "\x1b[?25l" in out)
    check("suspend/resume never leaves the alternate screen", "\x1b[?1049l" not in out)
    s.send("q")
    s.finish()


def test_input():
    print("\n▶ Key input and mouse")
    s = Session(mouse=True)
    out = s.read(0.8)
    check("mouse reporting is enabled on request", "\x1b[?1000h" in out and "\x1b[?1006h" in out)
    s.send("abc")
    out = s.read(0.6)
    keys = re.findall(r"KEY:(\S+)", out)
    check("a burst written at once yields every key in order", keys == ["a", "b", "c"], str(keys))
    s.send("\x1b[A\x1b[B \r\x7f")
    out = s.read(0.6)
    keys = re.findall(r"KEY:(\S+)", out)
    check("arrows and control keys are named", keys == ["UP", "DOWN", "SPACE", "ENTER", "BACKSPACE"],
          str(keys))
    s.send("é中")
    out = s.read(0.6)
    check("multi-byte characters arrive whole", re.findall(r"KEY:(\S+)", out) == ["é", "中"], out)
    s.send("\x1b[<0;10;5M\x1b[<64;3;4M")
    out = s.read(0.6)
    check("mouse events are decoded", re.findall(r"KEY:(\S+)", out) == ["mouse-0", "mouse-64"], out)
    s.send("z")
    out = s.read(0.5)
    check("size() reports the pty size", "SIZE:80x24" in out, out)
    s.send("q")
    out = s.read(0.8)
    check("leave() disables mouse reporting", "\x1b[?1006l" in out and "\x1b[?1000l" in out)
    s.finish()


def test_signals():
    print("\n▶ Signal cleanup")
    for sig, name in ((signal.SIGTERM, "SIGTERM"), (signal.SIGINT, "SIGINT"),
                      (signal.SIGHUP, "SIGHUP")):
        s = Session(mouse=True)
        s.read(0.8)
        os.kill(s.pid, sig)
        out = s.read(0.8)
        check(name + " restores screen, cursor and mouse",
              "\x1b[?1049l" in out and "\x1b[?25h" in out and "\x1b[?1000l" in out)
        code = s.finish()
        check(name + " exits with 128+signal", code == 128 + int(sig), str(code))


def test_signals_while_busy():
    print("\n▶ Signals delivered while the program is busy (not waiting in poll)")
    import random
    rng = random.Random(7)
    failures = []
    for attempt in range(12):
        s = Session(mouse=True, busy=True)
        s.read(0.5 + rng.random())
        os.kill(s.pid, signal.SIGTERM)
        out = s.read(0.8)
        code = s.finish()
        restored = "\x1b[?1049l" in out and "\x1b[?25h" in out and "\x1b[?1000l" in out
        if not restored or code != 143:
            failures.append((attempt, restored, code))
    check("12 random-timing SIGTERMs all restore the terminal and exit 143",
          not failures, str(failures))
    s = Session(busy=True)
    s.read(0.6)
    os.kill(s.pid, signal.SIGINT)
    out = s.read(0.8)
    check("SIGINT while busy restores the terminal", "\x1b[?1049l" in out)
    check("SIGINT while busy exits 130", s.finish() == 130)


def test_signal_mask_is_not_leaked_to_subprocesses():
    print("\n▶ Blocked-signal mask and subprocesses")
    s = Session()
    s.read(0.6)
    s.send("s")
    out = s.read(1.2)
    child = re.search(r"CHILD_SigBlk:\s*([0-9a-f]+)", out)
    check("a subprocess started during suspend() inherits no blocked signals",
          child is not None and (int(child.group(1), 16) & 0x4007) == 0,
          child.group(0) if child else out[-200:])
    resumed = re.search(r"SIGBLK:resumed:([0-9a-f]+)", out)
    check("resume() blocks the signals again",
          resumed is not None and (int(resumed.group(1), 16) & 0x4007) == 0x4007,
          resumed.group(0) if resumed else "no SIGBLK line")
    os.kill(s.pid, signal.SIGTERM)
    out = s.read(0.8)
    check("SIGTERM after resume still restores the terminal", "\x1b[?1049l" in out)
    check("and exits 143", s.finish() == 143)


def main():
    test_lifecycle()
    test_suspend_resume()
    test_input()
    test_signals()
    test_signals_while_busy()
    test_signal_mask_is_not_leaked_to_subprocesses()
    print("\n=== %d failed ===" % len(FAILURES))
    sys.exit(1 if FAILURES else 0)


if __name__ == "__main__":
    main()
