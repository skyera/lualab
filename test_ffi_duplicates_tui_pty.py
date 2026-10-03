#!/usr/bin/env python3
"""Linux terminal integration checks using a real PTY and native scanner."""
import errno
import fcntl
import json
import os
import pathlib
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest

SCRIPT = pathlib.Path(__file__).with_name('ffi_duplicates.lua').resolve()
LUAJIT = os.environ.get('LUALAB_LUAJIT', 'luajit')


class Session:
    def __init__(self, root, cols=100, rows=18):
        self.master, self.slave = pty.openpty()
        self.resize(cols, rows)
        self.original = termios.tcgetattr(self.slave)
        self.output = b''
        self.process = subprocess.Popen(
            [LUAJIT, str(SCRIPT), '--tui', str(root)],
            stdin=self.slave, stdout=self.slave, stderr=self.slave,
            start_new_session=True,
        )

    def resize(self, cols, rows):
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))

    def read(self, duration=0.15):
        deadline = time.monotonic() + duration
        while time.monotonic() < deadline:
            if select.select([self.master], [], [], max(0, deadline - time.monotonic()))[0]:
                try:
                    data = os.read(self.master, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not data:
                    break
                self.output += data
        return self.output

    def wait_for(self, text, timeout=5):
        deadline = time.monotonic() + timeout
        while text not in self.output and time.monotonic() < deadline:
            self.read(0.03)
            if self.process.poll() is not None:
                break
        if text not in self.output:
            raise AssertionError(f'TUI did not display {text!r}: {self.output[-1500:]!r}')

    def send(self, keys):
        os.write(self.master, keys)
        self.read()

    def finish(self, expected=0):
        self.process.wait(timeout=5)
        self.read(0.05)
        if self.process.returncode != expected:
            raise AssertionError((self.process.returncode, self.output[-1500:]))
        if termios.tcgetattr(self.slave) != self.original:
            raise AssertionError('Terminal settings were not restored')
        for escape in (b'\x1b[?1049l', b'\x1b[?25h', b'\x1b[?7h'):
            if escape not in self.output:
                raise AssertionError(f'Missing restoration escape: {escape!r}')

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait()
        os.close(self.master)
        os.close(self.slave)


@unittest.skipUnless(sys.platform == 'linux', 'PTY tests require Linux')
class DuplicateTUI(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='duplicates-pty-')
        self.root = pathlib.Path(self.temp.name)
        for i in range(20):
            (self.root / f'{i:02}-a.bin').write_bytes(bytes([i]) * (i + 1))
            (self.root / f'{i:02}-copy.bin').write_bytes(bytes([i]) * (i + 1))
        self.sessions = []

    def tearDown(self):
        for session in self.sessions:
            session.close()
        self.temp.cleanup()

    def session(self, **kwargs):
        session = Session(self.root, **kwargs)
        self.sessions.append(session)
        return session

    def test_navigation_filter_export_resize(self):
        session = self.session()
        session.wait_for(b'Ready')
        baseline = session.output.count(b'\x1b[2J')
        self.assertEqual(baseline, 1)
        session.send(b'?')
        session.wait_for(b'Help - keys')
        session.send(b'\x1b[6~\x1b[F')
        session.wait_for(b'Export writes JSON')
        session.send(b'\x1b')
        session.send(b'\x1b[B\t\x1b[B\r')
        session.wait_for(b'Group details')
        session.send(b'\x1b')
        session.send(b'/19 ')
        session.wait_for(b'Filter: 19 ')
        session.send(b'\x7f\r ')
        session.send(b'e')
        session.wait_for(b'Export JSON:')
        destination = self.root / 'selected groups.json'
        session.send(str(destination).encode() + b'\r')
        session.wait_for(b'Saved:')
        self.assertEqual(len(json.loads(destination.read_text())['groups']), 1)
        session.send(b'!')
        session.wait_for(b'No scan errors.')
        session.send(b'\x1b')
        self.assertEqual(session.output.count(b'\x1b[2J'), baseline)
        session.resize(40, 10)
        session.read()
        self.assertEqual(session.output.count(b'\x1b[2J'), baseline + 1)
        session.send(b'q')
        session.finish()

    def test_ctrl_c(self):
        session = self.session()
        session.wait_for(b'Ready')
        session.send(b'\x03')
        session.finish(130)

    def test_cancel_during_hashing(self):
        payload = b'large duplicate payload\0' * 400000
        (self.root / 'large-a').write_bytes(payload)
        (self.root / 'large-b').write_bytes(payload)
        session = self.session()
        session.wait_for(b'Hashing candidates')
        session.send(b'q')
        session.finish()

    def test_signal_restoration(self):
        for sig in (signal.SIGINT, signal.SIGTERM):
            session = self.session()
            session.wait_for(b'Ready')
            session.process.send_signal(sig)
            session.finish(128 + sig)

    def test_small_terminal_and_empty_results(self):
        for path in self.root.iterdir():
            path.unlink()
        session = self.session(cols=12, rows=4)
        session.wait_for(b'Duplicate')
        session.send(b'!\x1bq')
        session.finish()

    def test_pipeline_rejected_cleanly(self):
        result = subprocess.run(
            [LUAJIT, str(SCRIPT), '--tui', str(self.root)],
            input=b'q\x1b', capture_output=True, timeout=5,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn(b'interactive terminal', result.stderr)
        self.assertNotIn(b'\x1b', result.stdout)
        conflict = subprocess.run(
            [LUAJIT, str(SCRIPT), '--tui', '--json', str(self.root)],
            input=b'', capture_output=True, timeout=5,
        )
        self.assertEqual(conflict.returncode, 2)
        self.assertIn(b'cannot be combined', conflict.stderr)


if __name__ == '__main__':
    unittest.main()
