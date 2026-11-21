#!/usr/bin/env python3
"""PTY end-to-end tests for `luadbg.lua --tui`: layout, stepping, typing
without full redraws, history repeat, source scrolling, resize, program
input/output, script errors, quitting, signals and the non-TTY error."""

import fcntl
import os
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

HERE = os.path.dirname(os.path.abspath(__file__))
LUADBG = os.path.join(HERE, "luadbg.lua")
FAILURES = []

SAMPLE = """#!/usr/bin/env luajit
local function add(a, b)
    local sum = a + b
    return sum
end

local total = add(1, 2)
print("total", total)
io.write("name? ")
local name = io.read()
print("hello " .. tostring(name))
""" + "".join("local filler_%d = %d\n" % (i, i) for i in range(1, 60))

BOOM = "local t = nil\nprint(t.x)\n"
ESCAPE = re.compile(r"\x1b\[([?\d;]*)([A-Za-z@~])")


def check(name, cond, detail=""):
    if cond:
        print("  \033[32m✔\033[0m " + name)
    else:
        suffix = " :: " + detail if detail else ""
        print("  \033[31m✘\033[0m " + name + suffix)
        FAILURES.append(name)


class Screen:
    """Minimal terminal model: cursor moves, \\x1b[K, \\x1b[2J and text."""

    def __init__(self, rows, cols):
        self.resize(rows, cols)

    def resize(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.cells = [[" "] * cols for _ in range(rows)]
        self.row = self.col = 0

    def feed(self, text):
        i = 0
        while i < len(text):
            match = ESCAPE.match(text, i)
            if match:
                self.apply_escape(match.group(1), match.group(2))
                i = match.end()
                continue
            self.put(text[i])
            i += 1

    def apply_escape(self, args, command):
        if command == "H" and not args.startswith("?"):
            parts = (args or "1;1").split(";")
            self.row = int(parts[0]) - 1
            self.col = int(parts[1] if len(parts) > 1 else 1) - 1
        elif command == "K" and 0 <= self.row < self.rows:
            for col in range(self.col, self.cols):
                self.cells[self.row][col] = " "
        elif command == "J" and args == "2":
            self.cells = [[" "] * self.cols for _ in range(self.rows)]

    def put(self, char):
        if char == "\r":
            self.col = 0
        elif char == "\n":
            self.row = min(self.row + 1, self.rows - 1)
        elif char == "\x1b":
            return
        elif 0 <= self.row < self.rows and 0 <= self.col < self.cols:
            self.cells[self.row][self.col] = char
            self.col += 1

    def line(self, number):
        return "".join(self.cells[number - 1]).rstrip()

    def text(self):
        return "\n".join(self.line(n) for n in range(1, self.rows + 1))


class Session:
    def __init__(self, args, rows=24, cols=80, extra_env=None,
                 interpreter="luajit"):
        env = dict(os.environ, TERM="xterm")
        # Colors are on unless a test asks otherwise.
        env.pop("NO_COLOR", None)
        env.pop("DBG_NOCOLOR", None)
        env.pop("LUADBG_THEME", None)
        env.update(extra_env or {})
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(HERE)
            os.execvpe(interpreter,
                       [interpreter, LUADBG, "--tui", *args], env)
        self.screen = Screen(rows, cols)
        self.resize(rows, cols, signal_child=False)

    def resize(self, rows, cols, signal_child=True):
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ,
                    struct.pack("HHHH", rows, cols, 0, 0))
        self.screen.resize(rows, cols)
        if signal_child:
            os.kill(self.pid, signal.SIGWINCH)

    def read(self, seconds):
        out = b""
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([self.fd], [], [], 0.05)
            if ready:
                try:
                    chunk = os.read(self.fd, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                out += chunk
        text = out.decode("utf-8", errors="replace")
        self.screen.feed(text)
        return text

    def send(self, data, seconds=0.6):
        os.write(self.fd, data.encode())
        return self.read(seconds)

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


def restores_terminal(out):
    return "\x1b[?1049l" in out and "\x1b[?25h" in out and "\x1b[?7h" in out


def test_layout_and_stepping(sample):
    print("\n▶ Layout, stepping and typing")
    s = Session([sample])
    out = s.read(1.5)
    check("enters alternate screen without line wrap",
          "\x1b[?1049h" in out and "\x1b[?7l" in out)
    # The first stop is line 5: the end of the `local function add` statement.
    check("header shows location and status",
          "sample.lua:5  in main chunk" in s.screen.line(1)
          and "[stopped · dark]" in s.screen.line(1), s.screen.line(1))
    check("current line is marked", "   5 ▶ end" in s.screen.text())
    s.send("s\r")
    check("output rule and help row are drawn",
          "─ output" in s.screen.text() and "PgUp/PgDn" in s.screen.line(24))
    out = s.send("s\r")
    check("s steps into add()", "sample.lua:3  in local 'add'"
          in s.screen.line(1), s.screen.line(1))
    check("stepping does not clear the screen", "\x1b[2J" not in out)
    out = s.send("p", 0.4)
    check("typing redraws only the input row",
          "\x1b[23;1H" in out and "\x1b[2;1H" not in out, repr(out[:120]))
    out = s.send(" a + b\r")
    check("p prints into the log", "a + b => 3" in s.screen.text())
    s.send("n\r")
    check("n moves to the next line", "sample.lua:4  in local 'add'"
          in s.screen.line(1), s.screen.line(1))
    s.send("\r")
    check("empty Enter repeats the last command",
          "sample.lua:4" not in s.screen.line(1)
          and s.screen.text().count("dbg> n") == 2, s.screen.text())
    out = s.send("q\r")
    check("q restores the terminal", restores_terminal(out))
    check("q exits 0", s.finish() == 0)


def test_scroll_and_resize(sample):
    print("\n▶ Source scrolling and resize")
    s = Session([sample])
    s.read(1.5)
    s.send("\x1b[6~")
    check("PgDn scrolls the source", "  18   local filler_7" in s.screen.text()
          and "   5 ▶" not in s.screen.text(), s.screen.text())
    s.send("\x1b[5~")
    check("PgUp scrolls back", "   5 ▶ end" in s.screen.text())
    out = s.send("x", 0.3)
    s.resize(15, 60)
    out = s.read(0.8)
    check("resize clears once and redraws the last row",
          "\x1b[2J" in out and "\x1b[15;1H" in out)
    check("input survives resize", "dbg> x" in s.screen.line(14),
          s.screen.line(14))
    s.resize(8, 30)
    s.read(0.8)
    check("tiny terminal shows a message",
          "too small" in s.screen.line(1), s.screen.line(1))
    s.resize(24, 80)
    s.read(0.8)
    check("growing again leaves no stale message",
          "too small" not in s.screen.text()
          and "PgUp/PgDn" in s.screen.line(24))
    s.send("\x7fq\r")
    check("exits 0 after resizes", s.finish() == 0)


def test_program_io(sample):
    print("\n▶ Program output, input and exit")
    s = Session([sample])
    s.read(1.5)
    s.send("c\r", 1.0)
    check("program output appears in the log",
          "total\t3" in s.screen.text() or "total   3" in s.screen.text(),
          s.screen.text())
    check("io.read() switches to the input prompt",
          "input>" in s.screen.line(23)
          and "waiting for program input" in s.screen.line(1),
          s.screen.line(23) + " | " + s.screen.line(1))
    s.send("Ada\r", 1.0)
    check("program receives the typed line", "hello Ada" in s.screen.text())
    check("finished program waits for a key",
          "Press any key" in s.screen.line(23)
          and "exited normally" in s.screen.line(1))
    out = s.send(" ", 1.0)
    check("leaving restores the terminal", restores_terminal(out))
    after = out.split("\x1b[?1049l", 1)[-1]
    check("program output is replayed after leaving",
          "hello Ada" in after and "total" in after, repr(after))
    check("finished program exits 0", s.finish() == 0)


def test_script_error(boom):
    print("\n▶ Script error stops in the debugger")
    s = Session([boom])
    s.read(1.5)
    s.send("c\r", 1.0)
    check("error stops at the failing line",
          "boom.lua:2" in s.screen.line(1)
          and "attempt to index local 't'" in s.screen.text(), s.screen.text())
    s.send("p t\r")
    check("locals are inspectable at the error", "t => nil" in s.screen.text())
    s.send("c\r", 1.0)
    out = s.send(" ", 1.0)
    check("error exit restores the terminal", restores_terminal(out))
    check("reports the error after leaving",
          "program raised an error" in out, repr(out[-200:]))
    check("script error exits 1", s.finish() == 1)


def test_signal_and_oop_todo(tmp):
    print("\n▶ SIGTERM and a real CLI script")
    tasks = os.path.join(tmp, "tasks.txt")
    s = Session(["oop_todo.lua", tasks])
    s.read(1.5)
    s.send("c\r", 1.0)
    check("oop_todo.lua runs its CLI under --tui",
          "Loaded 0 task(s)" in s.screen.text(), s.screen.text())
    s.send("add hi\r", 0.8)
    check("CLI input works", "Added:" in s.screen.text())
    os.kill(s.pid, signal.SIGTERM)
    out = s.read(1.0)
    check("SIGTERM restores the terminal", restores_terminal(out))
    check("SIGTERM ends the process", s.finish() is not None)


def test_not_a_tty(sample):
    print("\n▶ Non-TTY refusal")
    result = subprocess.run(
        ["luajit", LUADBG, "--tui", sample], cwd=HERE,
        stdin=subprocess.PIPE, capture_output=True, text=True, timeout=10)
    check("piped stdin is refused with a message",
          "--tui needs an interactive terminal" in result.stderr,
          result.stderr)
    check("non-TTY exits 2", result.returncode == 2)


def test_highlighting(sample):
    print("\n▶ Syntax highlighting")
    s = Session([sample])
    out = s.read(1.5)
    check("dark theme by default: bright magenta keywords",
          "\x1b[95mlocal" in out)
    check("current line has the grey background", "\x1b[48;5;237m" in out)
    out = s.send("\x14", 0.6)
    check("Ctrl-T switches to the light theme",
          "· light]" in s.screen.line(1) and "\x1b[48;5;254m" in out
          and "\x1b[2J" not in out, s.screen.line(1))
    s.send("\x14\x14", 0.6)
    check("Ctrl-T cycles through plain back to dark",
          "· dark]" in s.screen.line(1), s.screen.line(1))
    s.send("q\r")
    s.finish()

    s = Session(["--theme", "light", sample])
    out = s.read(1.5)
    check("--theme light uses the light background",
          "\x1b[48;5;254m" in out and "· light]" in s.screen.line(1))
    s.send("q\r")
    s.finish()

    s = Session([sample], extra_env={"LUADBG_THEME": "neon"})
    s.read(1.5)
    check("unknown LUADBG_THEME warns in the log and starts with dark",
          "LUADBG_THEME='neon' is not a theme" in s.screen.text()
          and "· dark]" in s.screen.line(1), s.screen.text())
    s.send("q\r")
    check("session with a theme warning exits 0", s.finish() == 0)

    s = Session([sample], extra_env={"NO_COLOR": "1"})
    out = s.read(1.5)
    check("NO_COLOR=1 turns colors off",
          "\x1b[35m" not in out and "48;5;237" not in out
          and "\x1b[7m" in out)
    s.send("q\r")
    s.finish()

    started = time.time()
    s = Session([os.path.join(HERE, "codefind.lua")])
    out = ""
    while "codefind.lua:" not in s.screen.line(1) \
            and time.time() - started < 5:
        out += s.read(0.1)
    seconds = time.time() - started
    check("large file (codefind.lua) shows its first frame in < 2s",
          "codefind.lua:" in s.screen.line(1) and seconds < 2,
          "%.2fs" % seconds)
    s.send("q\r")
    check("large file session exits 0", s.finish() == 0)


def test_luvit_tui(tmp):
    print("\n▶ Luvit --tui with relative require and uv timer")
    if shutil.which("luvit") is None:
        print("  SKIP luvit is not installed")
        return
    helper_path = os.path.join(tmp, "luvit_helper.lua")
    script_path = os.path.join(tmp, "luvit_async.lua")
    with open(helper_path, "w") as f:
        f.write('return { tag = "luvit-ok" }\n')
    with open(script_path, "w") as f:
        f.write(
            'local uv = require("uv")\n'
            'local helper = require("./luvit_helper")\n'
            'local timer = uv.new_timer()\n'
            'timer:start(5, 0, function()\n'
            '    print("async", helper.tag)\n'
            '    timer:close()\n'
            'end)\n'
        )
    s = Session([script_path], interpreter="luvit")
    s.read(0.6)
    check("luvit --tui shows script in header",
          "luvit_async.lua:" in s.screen.line(1), s.screen.line(1))
    s.send("c\r")
    s.read(0.6)
    check("luvit --tui runs uv timer callback before finishing",
          "async" in s.screen.text() and "luvit-ok" in s.screen.text(),
          s.screen.text())
    s.send("q")
    check("luvit --tui exits 0", s.finish() == 0)

    # Also verify interactive CLI mode (no --tui) waits on a TTY under Luvit
    # instead of exiting on EAGAIN from Luvit's O_NONBLOCK stdin.
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(HERE)
        os.execvp("luvit", ["luvit", LUADBG, script_path])
    out = b""
    deadline = time.time() + 2
    while time.time() < deadline and b"debugger.lua> " not in out:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            out += os.read(fd, 4096)
    _, early_status = os.waitpid(pid, os.WNOHANG)
    check("luvit CLI pauses at debugger.lua> on a TTY",
          b"debugger.lua> " in out and early_status == 0,
          f"status={early_status} out={out!r}")
    os.write(fd, b"n\n")
    deadline = time.time() + 2
    while time.time() < deadline and b"luvit_async.lua:2" not in out:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            out += os.read(fd, 4096)
    check("luvit CLI accepts n on a TTY and steps to line 2",
          b"luvit_async.lua:2" in out, repr(out))
    os.write(fd, b"c\n")
    deadline = time.time() + 2
    while time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
    _, cli_status = os.waitpid(pid, 0)
    os.close(fd)
    check("luvit CLI finishes uv timer and exits 0",
          b"luvit-ok" in out and os.WEXITSTATUS(cli_status) == 0,
          f"status={cli_status} out={out!r}")


def main():
    tmp = tempfile.mkdtemp(prefix="luadbg_tui_pty_")
    try:
        sample = os.path.join(tmp, "sample.lua")
        boom = os.path.join(tmp, "boom.lua")
        with open(sample, "w") as f:
            f.write(SAMPLE)
        with open(boom, "w") as f:
            f.write(BOOM)
        test_layout_and_stepping(sample)
        test_scroll_and_resize(sample)
        test_program_io(sample)
        test_script_error(boom)
        test_signal_and_oop_todo(tmp)
        test_not_a_tty(sample)
        test_highlighting(sample)
        test_luvit_tui(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if FAILURES:
        print("\n%d failure(s): %s" % (len(FAILURES), ", ".join(FAILURES)))
        sys.exit(1)
    print("\nAll luadbg --tui PTY tests passed")


if __name__ == "__main__":
    main()
