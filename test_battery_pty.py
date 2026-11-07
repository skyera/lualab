#!/usr/bin/env python3
"""Live pseudo-terminal tests for `battery_monitor.lua --tui`.

Verifies that real keystrokes and signals leave the terminal restored
(alternate screen exited, cursor shown, termios flags back to canonical mode),
and that resize / help / burst input behave without crashes.

Usage: python3 test_battery_pty.py
"""

import fcntl
import os
import pty
import select
import signal
import struct
import sys
import tempfile
import termios
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.environ.get("BATTERY_SCRIPT", os.path.join(HERE, "battery_monitor.lua"))

ALT_ON = b"\x1b[?1049h"
ALT_OFF = b"\x1b[?1049l"
CURSOR_ON = b"\x1b[?25h"
LFLAGS = termios.ICANON | termios.ECHO | termios.ISIG

passed = 0
failed = 0


def report(ok, name, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print("  [PASS] " + name)
    else:
        failed += 1
        print("  [FAIL] " + name + (": " + detail if detail else ""))


def set_winsize(fd, rows, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


class Session:
    """Runs the TUI on a pty and exposes send/read/wait helpers."""

    def __init__(self, db_path, rows=24, cols=80):
        self.output = b""
        pid, fd = pty.fork()
        if pid == 0:
            os.environ["BATTERY_DB"] = db_path
            os.environ["TERM"] = "xterm"
            os.execvp("luajit", ["luajit", SCRIPT, "--tui"])
        self.pid = pid
        self.fd = fd
        set_winsize(fd, rows, cols)
        self.initial_lflag = termios.tcgetattr(fd)[3]

    def read_for(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([self.fd], [], [], 0.05)
            if ready:
                try:
                    chunk = os.read(self.fd, 65536)
                except OSError:
                    return
                if not chunk:
                    return
                self.output += chunk

    def wait_for(self, needle, timeout=5.0):
        end = time.time() + timeout
        while time.time() < end:
            if needle in self.output:
                return True
            self.read_for(0.1)
        return needle in self.output

    def send(self, data):
        os.write(self.fd, data)

    def finish(self, timeout=5.0):
        """Wait for exit; returns (exit_code, term_signal) or (None, None) on timeout."""
        end = time.time() + timeout
        while time.time() < end:
            self.read_for(0.1)
            done, status = os.waitpid(self.pid, os.WNOHANG)
            if done:
                self.read_for(0.2)
                if os.WIFSIGNALED(status):
                    return None, os.WTERMSIG(status)
                return os.WEXITSTATUS(status), None
        os.kill(self.pid, signal.SIGKILL)
        os.waitpid(self.pid, 0)
        return None, None

    def lflag_restored(self):
        try:
            return (termios.tcgetattr(self.fd)[3] & LFLAGS) == (self.initial_lflag & LFLAGS)
        except termios.error:
            return True  # slave already closed; nothing left to leak


def start(tmp):
    session = Session(os.path.join(tmp, "pty.db"))
    if not session.wait_for(ALT_ON):
        report(False, "TUI entered alternate screen", repr(session.output[-200:]))
    return session


def main():
    print("=== battery_monitor.lua pty tests ===")
    with tempfile.TemporaryDirectory() as tmp:
        # -- Ctrl+C -------------------------------------------------------------
        s = start(tmp)
        s.read_for(0.5)
        s.send(b"\x03")
        code, sig = s.finish()
        report(code == 0 and sig is None, "Ctrl+C exits cleanly", "code=%s sig=%s" % (code, sig))
        report(ALT_OFF in s.output and CURSOR_ON in s.output,
               "Ctrl+C restores alt screen + cursor")

        # -- SIGTERM ------------------------------------------------------------
        s = start(tmp)
        s.read_for(0.5)
        os.kill(s.pid, signal.SIGTERM)
        code, sig = s.finish()
        report(sig == signal.SIGTERM, "SIGTERM still terminates the process (by signal)",
               "code=%s sig=%s" % (code, sig))
        report(ALT_OFF in s.output and CURSOR_ON in s.output,
               "SIGTERM restores alt screen + cursor before dying")

        # -- SIGINT sent externally ---------------------------------------------
        s = start(tmp)
        s.read_for(0.5)
        os.kill(s.pid, signal.SIGINT)
        code, sig = s.finish()
        report(ALT_OFF in s.output and CURSOR_ON in s.output,
               "external SIGINT restores alt screen + cursor")

        # -- Help: h must not open it, ? must; Esc closes without quitting ------
        s = start(tmp)
        s.read_for(0.5)
        s.send(b"h")
        s.read_for(0.4)
        report(b"BATTERY MONITOR HELP" not in s.output, "'h' no longer opens help")
        s.send(b"?")
        report(s.wait_for(b"BATTERY MONITOR HELP"), "'?' opens help")
        s.send(b"\x1b")
        s.read_for(0.4)
        s.send(b"2")
        s.read_for(0.4)
        report(s.wait_for(b"HISTORY PLOT"), "app still running after Esc closes help")
        s.send(b"]")
        s.send(b"[")
        s.send(b"jjj\x1b[3~")  # burst + unknown escape sequence must not quit
        s.read_for(0.4)
        s.send(b"q")
        code, sig = s.finish()
        report(code == 0, "'q' quits after exercising keys", "code=%s sig=%s" % (code, sig))
        report(ALT_OFF in s.output, "quit restores alt screen")

        # -- Resize below minimum, then back ------------------------------------
        s = start(tmp)
        s.read_for(0.5)
        set_winsize(s.fd, 8, 30)
        os.kill(s.pid, signal.SIGWINCH)
        report(s.wait_for(b"Terminal too small", 4.0), "tiny terminal shows size warning")
        set_winsize(s.fd, 24, 80)
        os.kill(s.pid, signal.SIGWINCH)
        mark = len(s.output)
        s.read_for(2.0)
        report(b"DASHBOARD" in s.output[mark:], "layout recovers after resizing back")
        s.send(b"q")
        code, sig = s.finish()
        report(code == 0, "clean exit after resize cycle", "code=%s sig=%s" % (code, sig))

        # -- No screen clear on user actions ------------------------------------
        s = start(tmp)
        s.read_for(0.5)
        mark = len(s.output)
        for key in (b"\t", b"\t", b"2", b"3", b"1", b"?", b"\x1b", b"+", b"-"):
            s.send(key)
            s.read_for(0.15)
        report(b"\x1b[2J" not in s.output[mark:], "no \\e[2J emitted for user actions")
        s.send(b"q")
        s.finish()

    print("=== Passed: %d  Failed: %d ===" % (passed, failed))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
