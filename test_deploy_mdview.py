#!/usr/bin/env python3
"""Verify mdview installation, launcher output and deployment failure paths."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
LUAJIT = shutil.which(os.environ.get("LUALAB_LUAJIT", "luajit"))


@unittest.skipUnless(LUAJIT, "LuaJIT is required")
class DeployMarkdownViewer(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mdview-deploy-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.target = self.root / "tools with spaces 中文"

    def deploy(self, *args, script=None):
        return subprocess.run(
            [LUAJIT, str(script or ROOT / "deploy.lua"), *args],
            cwd=self.root, capture_output=True, text=True, encoding="utf-8", timeout=30,
        )

    def install(self, layout):
        result = self.deploy("--app", "mdview", "--os", layout, "--dir", str(self.target))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.target / "mdview.lua").read_bytes(), (ROOT / "mdview.lua").read_bytes())
        self.assertIn("Deploy complete", result.stdout)

    def test_dry_run_and_all_include_mdview_without_writes(self):
        for app in ("mdview", "all"):
            for layout in ("linux", "windows"):
                result = self.deploy("--app", app, "--os", layout,
                                     "--dir", str(self.target), "--check")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("[mdview] Terminal Markdown Viewer", result.stdout)
                self.assertIn("mdview.lua", result.stdout)
                self.assertIn("Nothing written", result.stdout)
                if layout == "windows":
                    self.assertIn("mdview.cmd", result.stdout)
                self.assertFalse(self.target.exists())

    @unittest.skipIf(os.name == "nt", "POSIX launcher execution requires a POSIX host")
    def test_linux_launcher_arguments_override_failures_and_reinstall(self):
        self.install("linux")
        launcher = self.target / "mdview"
        self.assertTrue(os.access(launcher, os.X_OK))
        document = self.root / "document with spaces 中文.md"
        document.write_text("# Deployed viewer\n\nHello world\n", encoding="utf-8")
        command = [str(launcher), "--no-pager", "--no-color", str(document)]
        result = subprocess.run(command, cwd=self.root, capture_output=True, text=True,
                                env=dict(os.environ, MDVIEW_LUAJIT=LUAJIT), timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Hello world", result.stdout)
        self.assertNotIn("\x1b", result.stdout)
        result = subprocess.run(command, capture_output=True, text=True, timeout=10,
                                env=dict(os.environ, MDVIEW_LUAJIT=str(self.root / "missing runtime")))
        self.assertEqual(result.returncode, 127)
        self.assertIn("MDVIEW_LUAJIT", result.stderr)
        document.unlink()
        result = subprocess.run(command, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot open", result.stderr)
        (self.target / "keep.txt").write_text("preserved", encoding="utf-8")
        self.install("linux")
        self.assertEqual((self.target / "keep.txt").read_text(), "preserved")

    def test_windows_layout_and_native_launcher_when_available(self):
        self.install("windows")
        cmd = (self.target / "mdview.cmd").read_bytes()
        self.assertIn(b'"%LUAJIT%" "%~dp0mdview.lua" %*', cmd)
        self.assertIn(b"%MDVIEW_LUAJIT%", cmd)
        self.assertNotIn(b"\n", cmd.replace(b"\r\n", b""))
        self.assertIn("MDVIEW_LUAJIT", (self.target / "mdview").read_text(encoding="utf-8"))
        if os.name == "nt":
            result = subprocess.run(
                [os.environ.get("COMSPEC", "cmd.exe"), "/d", "/c",
                 str(self.target / "mdview.cmd"), "--help"],
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("terminal Markdown viewer", result.stdout)

    def test_missing_source_and_unwritable_destination_fail_visibly(self):
        isolated = self.root / "deploy.lua"
        shutil.copyfile(ROOT / "deploy.lua", isolated)
        result = self.deploy("--app", "mdview", "--dir", str(self.target), script=isolated)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mdview.lua not found", result.stderr)
        self.assertFalse(self.target.exists())
        self.target.write_text("existing data", encoding="utf-8")
        result = self.deploy("--app", "mdview", "--dir", str(self.target))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("failed to install mdview.lua", result.stderr)
        self.assertNotIn("Deploy complete", result.stdout)
        self.assertEqual(self.target.read_text(encoding="utf-8"), "existing data")


if __name__ == "__main__":
    unittest.main(verbosity=2)
