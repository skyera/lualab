#!/usr/bin/env python3
"""PTY smoke tests for luatop.lua after moving to the shared termkit module:
startup, mouse reporting, key dispatch, resize, clean quit and signal cleanup."""

import fcntl
import os
import pty
import select
import signal
import struct
import sys
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
    def __init__(self, rows=30, cols=110):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ["TERM"] = "xterm"
            os.chdir(HERE)
            os.execvp("luajit", ["luajit", SCRIPT])
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


def main():
    test_startup_and_quit()
    test_resize_and_signals()
    print("\n=== %d failed ===" % len(FAILURES))
    sys.exit(1 if FAILURES else 0)


if __name__ == "__main__":
    main()
