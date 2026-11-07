#!/usr/bin/env python3
"""PTY end-to-end tests for hwinfo_tui.lua: startup, resize, auto-refresh,
sensor history, export success/failure, and terminal restoration."""

import fcntl
import os
import pty
import select
import shutil
import signal
import struct
import sys
import tempfile
import termios
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "hwinfo_tui.lua")
FAILURES = []


def check(name, cond, detail=""):
    if cond:
        print("  \033[32m✔\033[0m " + name)
    else:
        print("  \033[31m✘\033[0m " + name + (" :: " + detail if detail else ""))
        FAILURES.append(name)


def write(root, path, content):
    full = root + path
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w") as f:
        f.write(content)


def make_fixture():
    root = tempfile.mkdtemp(prefix="hwinfo_pty_")
    write(root, "/proc/cpuinfo", "processor : 0\nmodel name : PTY Test CPU\n")
    write(root, "/proc/meminfo",
          "MemTotal: 16384000 kB\nMemAvailable: 8192000 kB\n")
    write(root, "/sys/class/hwmon/hwmon0/name", "fakehw\n")
    write(root, "/sys/class/hwmon/hwmon0/temp1_input", "40000\n")
    write(root, "/sys/class/hwmon/hwmon0/temp1_label", "Core\n")
    return root


class Session:
    def __init__(self, root, args=(), cwd=None, rows=24, cols=80):
        env = dict(os.environ, TERM="xterm", HWINFO_ROOT=root)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            if cwd:
                os.chdir(cwd)
            os.execvpe("luajit", ["luajit", SCRIPT, *args], env)
        self.resize(rows, cols, signal_child=False)

    def resize(self, rows, cols, signal_child=True):
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ,
                    struct.pack("HHHH", rows, cols, 0, 0))
        if signal_child:
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


def test_startup_and_quit(root):
    print("\n▶ Startup, navigation and clean quit")
    s = Session(root)
    out = s.read(1.5)
    check("enters alternate screen and hides cursor",
          "\x1b[?1049h" in out and "\x1b[?25l" in out)
    check("disables line wrap", "\x1b[?7l" in out)
    check("first frame shows tab bar", "HWINFO" in out)
    s.send("\x1b[C")
    out = s.read(0.8)
    check("RIGHT shows CPU tab", "PTY Test CPU" in out)
    check("tab switch emits no full-screen clear", "\x1b[2J" not in out)
    s.send("q")
    out = s.read(0.8)
    check("restores primary screen, cursor and wrap",
          "\x1b[?1049l" in out and "\x1b[?25h" in out and "\x1b[?7h" in out)
    check("exit status 0", s.finish() == 0)


def test_resize(root):
    print("\n▶ Terminal resize")
    s = Session(root, rows=24, cols=80)
    s.read(1.0)
    s.resize(40, 120)
    out = s.read(1.0)
    check("resize triggers a full clear", "\x1b[2J" in out)
    check("footer redrawn at the new last row", "\x1b[40;1H" in out)
    s.send("1")
    out = s.read(0.6)
    check("no clear on ordinary key after resize", "\x1b[2J" not in out)
    s.resize(5, 20)
    out = s.read(0.8)
    check("tiny terminal shows a message instead of crashing",
          "Terminal too small" in out or "too small" in out)
    s.resize(24, 80)
    out = s.read(0.8)
    check("recovers after growing again", "HWINFO" in out)
    s.send("q")
    check("still exits 0 after resizes", s.finish() == 0)


def test_auto_refresh_and_history(root):
    print("\n▶ Auto-refresh and sensor history")
    s = Session(root, args=("--tab", "sensors"))
    out = s.read(1.0)
    check("sensors tab shows initial temperature", "40.0 °C" in out)
    check("no sparkline with a single sample", "min 40.0" not in out)
    write(root, "/sys/class/hwmon/hwmon0/temp1_input", "55000\n")
    out = s.read(3.5)
    check("auto-refresh picks up the new value", "55.0 °C" in out)
    check("sparkline with min/max appears", "min 40.0 max 55.0" in out, out[-300:])
    s.send("3")
    write(root, "/proc/meminfo",
          "MemTotal: 16384000 kB\nMemAvailable: 4096000 kB\n")
    out = s.read(3.5)
    check("memory tab refreshes live (used 75%)", "75%" in out)
    write(root, "/sys/class/hwmon/hwmon0/temp1_input", "70000\n")
    s.read(2.5)
    s.send("7")
    out = s.read(0.8)
    check("sensors history kept while on another tab", "min 40.0 max 70.0" in out)
    s.send("q")
    s.finish()


def test_export(root):
    print("\n▶ JSON export")
    cwd = tempfile.mkdtemp(prefix="hwinfo_cwd_")
    s = Session(root, cwd=cwd)
    s.read(1.0)
    s.send("e")
    out = s.read(0.8)
    path = os.path.join(cwd, "hwinfo_snapshot.json")
    check("status line reports the saved file", "Saved" in out and "hwinfo_snapshot.json" in out)
    check("file exists with expected content",
          os.path.exists(path) and "PTY Test CPU" in open(path).read())
    s.send("q")
    s.finish()

    ro = tempfile.mkdtemp(prefix="hwinfo_ro_")
    os.chmod(ro, 0o555)
    if os.access(ro, os.W_OK):
        print("  (skipping write-failure check: running with write access to read-only dir)")
    else:
        s = Session(root, cwd=ro)
        s.read(1.0)
        s.send("e")
        out = s.read(0.8)
        check("write failure is shown in the view", "cannot write" in out)
        s.send("q")
        check("app keeps running after failed export and exits 0", s.finish() == 0)
    os.chmod(ro, 0o755)
    shutil.rmtree(ro, ignore_errors=True)
    shutil.rmtree(cwd, ignore_errors=True)


def test_signals(root):
    print("\n▶ Signal cleanup")
    for sig, name in ((signal.SIGTERM, "SIGTERM"), (signal.SIGINT, "SIGINT")):
        s = Session(root)
        s.read(1.0)
        os.kill(s.pid, sig)
        out = s.read(0.8)
        check(name + " restores the terminal",
              "\x1b[?1049l" in out and "\x1b[?25h" in out)
        code = s.finish()
        check(name + " exit status is 128+signal", code == 128 + int(sig), str(code))


def main():
    root = make_fixture()
    try:
        test_startup_and_quit(root)
        test_resize(root)
        test_auto_refresh_and_history(root)
        test_export(root)
        test_signals(root)
    finally:
        shutil.rmtree(root, ignore_errors=True)
    print("\n=== %d failed ===" % len(FAILURES))
    sys.exit(1 if FAILURES else 0)


if __name__ == "__main__":
    main()
