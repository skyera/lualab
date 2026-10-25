#!/usr/bin/env python3
"""Exercise mdview's real Linux key reader, resize loop and terminal cleanup."""

import sys

if sys.platform != "linux":
    print("SKIPPED: mdview PTY tests require Linux")
    sys.exit(0)

import fcntl
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time
import unittest

SCRIPT = Path(__file__).with_name("mdview.lua").resolve()
LUAJIT = os.environ.get("LUALAB_LUAJIT", "luajit")


class Session:
    def __init__(self, path, cwd=None):
        self.master, self.slave = pty.openpty()
        self.original = termios.tcgetattr(self.slave)
        self.output = b""
        self.resize(81, 12)
        self.process = subprocess.Popen(
            [LUAJIT, str(SCRIPT), "--no-images"] + ([str(path)] if path is not None else []),
            stdin=self.slave, stdout=self.slave, stderr=self.slave,
            start_new_session=True,
            env=dict(os.environ, NO_COLOR="1", TERM="xterm-256color"),
            cwd=cwd,
        )

    def resize(self, columns, rows):
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))

    def read(self, duration=0.3):
        deadline = time.monotonic() + duration
        while time.monotonic() < deadline:
            remaining = max(0, deadline - time.monotonic())
            if select.select([self.master], [], [], remaining)[0]:
                data = os.read(self.master, 65536)
                if not data:
                    break
                self.output += data

    def send(self, keys):
        os.write(self.master, keys)
        self.read()

    def wait_for(self, marker):
        deadline = time.monotonic() + 5
        while marker not in self.output and time.monotonic() < deadline:
            self.read(0.05)
            if self.process.poll() is not None:
                break
        if marker not in self.output:
            raise AssertionError(f"Missing {marker!r}; last output: {self.output[-1500:]!r}")

    def rows(self):
        rows = {}
        # NO_COLOR leaves only application-owned cursor and synchronized-update
        # escapes. Reconstruct rows to catch stale text after modal transitions.
        for match in re.finditer(rb"\x1b\[(\d+);1H([^\x1b]*)\x1b\[K", self.output):
            rows[int(match[1])] = match[2].decode("utf-8")
        return rows

    def finish(self):
        self.process.wait(timeout=5)
        self.read(0.05)
        if self.process.returncode != 0:
            raise AssertionError((self.process.returncode, self.output[-1500:]))
        if termios.tcgetattr(self.slave) != self.original:
            raise AssertionError("Terminal attributes were not restored")
        for escape in (b"\x1b[?1049l", b"\x1b[?25h", b"\x1b[?7h"):
            if escape not in self.output:
                raise AssertionError(f"Missing cleanup escape: {escape!r}")

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait()
        os.close(self.master)
        os.close(self.slave)


class MarkdownPager(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mdview-pty-")
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "doc.md"
        self.path.write_text(
            "# Intro\n\nalpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu\n\n"
            "## Install Linux\n\nbody\n\n## Install Windows\n\n"
            + "tail\n\n" * 80,
            encoding="utf-8",
        )

    def session(self):
        session = Session(self.path)
        self.addCleanup(session.close)
        session.wait_for(b"\x1b[?2026l")
        return session

    def test_resize_help_outline_and_differential_rows(self):
        session = self.session()
        session.resize(25, 12)
        session.read(0.6)
        rows = session.rows()
        body = " ".join(rows[row].strip() for row in range(2, 12))
        self.assertIn("lambda mu", body)
        session.resize(81, 12)
        session.read(0.6)
        baseline = session.output.count(b"\x1b[2J")
        self.assertEqual(baseline, 3)  # Startup and two resizes only.
        session.send(b"G")
        original = session.rows()
        session.send(b"h")
        self.assertIn("mdview keys", session.rows()[2])
        session.send(b"G")
        session.send(b"\x1b")
        self.assertEqual(session.rows()[2], original[2])
        session.send(b"t")
        self.assertIn("Outline", session.rows()[1])
        before = len(session.output)
        session.send(b"j")
        changed = re.findall(rb"\x1b\[(\d+);1H", session.output[before:])
        self.assertEqual(set(changed), {b"1", b"2", b"3"})
        session.send(b"/Install W\x7fL")
        rows = session.rows()
        self.assertIn("Install Linux", rows[2])
        self.assertTrue(all(not rows[row].strip() for row in range(3, 12)))
        session.send(b"\r")
        self.assertIn("Install Linux", session.rows()[2])
        self.assertEqual(session.output.count(b"\x1b[2J"), baseline)
        session.send(b"q")
        session.finish()

    def test_ctrl_c_and_sigterm_restore_terminal(self):
        session = self.session()
        session.send(b"t/\x03")
        session.finish()
        session = self.session()
        session.process.send_signal(signal.SIGTERM)
        session.finish()

    def test_document_cannot_clear_screen(self):
        self.path.write_bytes(b"# Safe\n\nbefore\x1b[2Jafter\x07\n")
        session = self.session()
        self.assertIn(b"before^[[2Jafter^G", session.output)
        self.assertEqual(session.output.count(b"\x1b[2J"), 1)
        session.send(b"q")
        session.finish()

    def browser_session(self, directory_argument=False):
        root = Path(self.temp.name)
        (root / "nested").mkdir()
        (root / "alpha.md").write_text("# Alpha\n\n" + "alpha body\n\n" * 40, encoding="utf-8")
        (root / "beta.md").write_text("# Beta\n\nshort\n", encoding="utf-8")
        (root / "nested" / "中文.md").write_text("# Nested Unicode\n", encoding="utf-8")
        (root / ".hidden.md").write_text("hidden", encoding="utf-8")
        (root / "loop").symlink_to(root, target_is_directory=True)
        session = Session(root if directory_argument else None, cwd=root)
        self.addCleanup(session.close)
        session.wait_for(b"\x1b[?2026l")
        return session

    def test_no_argument_tree_vim_keys_and_file_state(self):
        session = self.browser_session()
        rows = session.rows()
        self.assertIn("Files [active]", rows[1])
        self.assertIn("📂", rows[2])
        self.assertIn("📁 nested", rows[3])
        self.assertIn("📄 alpha.md", rows[4])
        self.assertNotIn(".hidden.md", "".join(rows.values()))
        self.assertNotIn("loop", "".join(rows.values()))
        baseline = session.output.count(b"\x1b[2J")
        session.send(b"jj\r")
        self.assertIn("Alpha", session.rows()[2])
        session.send(b"/body\rG")
        original = session.rows()[2]
        session.send(b"\tj\r")
        self.assertIn("Beta", session.rows()[2])
        session.send(b"\tk\r")
        self.assertEqual(session.rows()[2], original)
        session.send(b"\tggjl")
        self.assertIn("📂 nested", session.rows()[3])
        self.assertIn("中文.md", session.rows()[4])
        session.send(b"j\r")
        self.assertIn("Nested Unicode", session.rows()[2])
        session.send(b"f")
        self.assertNotIn("Files", session.rows()[1])
        session.send(b"f")
        self.assertIn("Files", session.rows()[1])
        self.assertEqual(session.output.count(b"\x1b[2J"), baseline)
        session.send(b"q")
        session.finish()

    def test_directory_startup_narrow_layout_and_disappearing_file(self):
        session = self.browser_session(directory_argument=True)
        session.resize(41, 10)
        session.read(0.6)
        self.assertIn("Files", session.rows()[1])
        self.assertNotIn("│", session.rows()[2])
        session.send(b"jj\r")
        self.assertIn("Alpha", session.rows()[2])
        self.assertNotIn("Files", session.rows()[1])
        session.send(b"\t")
        self.assertIn("Files", session.rows()[1])
        (Path(self.temp.name) / "beta.md").unlink()
        session.send(b"j\r")
        self.assertIn("Cannot open", session.rows()[10])
        session.send(b"\t")
        self.assertIn("Alpha", session.rows()[2])
        session.send(b"\tgglr")
        self.assertIn("Files", session.rows()[1])
        session.send(b"q")
        session.finish()


if __name__ == "__main__":
    unittest.main(verbosity=2)
