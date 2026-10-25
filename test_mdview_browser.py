#!/usr/bin/env python3
"""Native filesystem and CLI checks for mdview's Linux/Windows file browser."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("mdview.lua").resolve()
LUAJIT = shutil.which(os.environ.get("LUALAB_LUAJIT", "luajit"))


@unittest.skipUnless(LUAJIT, "LuaJIT is required")
class MarkdownBrowser(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mdview-browser-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "docs with spaces 中文"
        self.root.mkdir()
        (self.root / "nested").mkdir()
        (self.root / "README.md").write_text("# Read me\n\nhello\n", encoding="utf-8")
        (self.root / "中文.markdown").write_text("# Unicode document\n", encoding="utf-8")
        (self.root / ".hidden.md").write_text("hidden", encoding="utf-8")
        (self.root / "other.txt").write_text("other", encoding="utf-8")

    def run_viewer(self, *arguments, cwd=None):
        return subprocess.run(
            [LUAJIT, str(SCRIPT), "--no-color", "--no-images", *map(str, arguments)],
            cwd=cwd or self.root, capture_output=True, text=True, encoding="utf-8", timeout=10,
        )

    def test_current_directory_and_explicit_directory_snapshots(self):
        for args in ((), (self.root,)):
            result = self.run_viewer("--snapshot", "100x12", *args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(result.stdout.splitlines()), 12)
            self.assertIn("Files [active]", result.stdout)
            self.assertIn("📂", result.stdout)
            self.assertIn("📁 nested", result.stdout)
            self.assertIn("📄 README.md", result.stdout)
            self.assertIn("📄 中文.markdown", result.stdout)
            self.assertNotIn("other.txt", result.stdout)
            self.assertNotIn(".hidden.md", result.stdout)
            self.assertEqual(result.stderr, "")

    def test_direct_unicode_file_keeps_document_view(self):
        result = self.run_viewer("--snapshot", "80x10", self.root / "中文.markdown")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Unicode document", result.stdout)
        self.assertNotIn("Files [active]", result.stdout)
        result = self.run_viewer("--no-pager", self.root / "中文.markdown")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Unicode document", result.stdout)

    def test_empty_directory_and_redirected_startup(self):
        result = self.run_viewer("--snapshot", "80x10", self.root / "nested")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("No Markdown files", result.stdout)
        result = self.run_viewer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires a terminal", result.stderr)
        self.assertIn("--snapshot", result.stderr)
        self.assertEqual(result.stdout, "")

    @unittest.skipIf(os.name == "nt", "Creating Windows links may require elevated privileges")
    def test_directory_links_and_special_files_are_omitted(self):
        (self.root / "loop").symlink_to(self.root, target_is_directory=True)
        (self.root / "alias.md").symlink_to(self.root / "README.md")
        os.mkfifo(self.root / "pipe.md")
        result = self.run_viewer("--snapshot", "100x16")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("loop", result.stdout)
        self.assertNotIn("alias.md", result.stdout)
        self.assertNotIn("pipe.md", result.stdout)

    def test_invalid_file_reports_failure(self):
        path = self.root / "broken.md"
        path.write_bytes(b"text\x00binary")
        result = self.run_viewer(path)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("contains NUL bytes", result.stderr)
        path.unlink()
        result = self.run_viewer(path)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot open", result.stderr)
        self.assertIn("broken.md", result.stderr)

    @unittest.skipIf(os.name == "nt", "POSIX permission check")
    def test_unreadable_directory_reports_path_and_error(self):
        if os.geteuid() == 0:
            self.skipTest("Root bypasses directory permissions")
        blocked = self.root / "blocked"
        blocked.mkdir()
        blocked.chmod(0)
        self.addCleanup(blocked.chmod, 0o700)
        result = self.run_viewer("--snapshot", "80x10", blocked)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cannot list", result.stderr)
        self.assertIn("blocked", result.stderr)
        self.assertIn("Permission denied", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
