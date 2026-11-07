#!/usr/bin/env python3
"""Verify that deploy.lua installs shared dependencies (termkit.lua, json.lua), that the
installed apps start from any working directory, and that failures are loud."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
LUAJIT = shutil.which(os.environ.get("LUALAB_LUAJIT", "luajit"))


def run(args, cwd, stdin_text=None, env=None, timeout=60):
    return subprocess.run(
        args, cwd=cwd, input=stdin_text, capture_output=True, text=True,
        encoding="utf-8", timeout=timeout, env=env,
    )


@unittest.skipUnless(LUAJIT, "LuaJIT is required")
class DeployDependencies(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="deploy-deps-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.target = self.root / "install dir 中文"
        self.elsewhere = self.root / "elsewhere"
        self.elsewhere.mkdir()

    def deploy(self, *args, script=None):
        return run([LUAJIT, str(script or ROOT / "deploy.lua"), *args], cwd=self.root)

    def test_luatop_gets_termkit_and_starts_from_any_directory(self):
        result = self.deploy("--app", "luatop", "--dir", str(self.target))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.target / "termkit.lua").is_file(), "termkit.lua not installed")
        self.assertIn("termkit.lua", result.stdout)
        started = run([LUAJIT, str(self.target / "luatop.lua")], cwd=self.elsewhere,
                      stdin_text="q")
        self.assertEqual(started.returncode, 0, started.stderr)
        self.assertNotIn("not found", started.stderr)

    def test_hwtui_is_deployable_and_runs_from_any_directory(self):
        result = self.deploy("--app", "hwtui", "--dir", str(self.target))
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ("hwinfo_tui.lua", "termkit.lua", "hwtui"):
            self.assertTrue((self.target / name).is_file(), name + " missing")
        self.assertTrue(os.access(self.target / "hwtui", os.X_OK), "launcher not executable")
        report = run([LUAJIT, str(self.target / "hwinfo_tui.lua"), "--text"], cwd=self.elsewhere)
        self.assertEqual(report.returncode, 0, report.stderr)
        self.assertIn("== CPU ==", report.stdout)
        launched = run([str(self.target / "hwtui"), "--json"], cwd=self.elsewhere)
        self.assertEqual(launched.returncode, 0, launched.stderr)
        self.assertIn('"tabs"', launched.stdout)

    def test_aliases_still_resolve(self):
        result = self.deploy("--app", "ltop", "--dir", str(self.target))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.target / "luatop.lua").is_file())

    def test_unknown_app_lists_valid_choices(self):
        result = self.deploy("--app", "bogus", "--dir", str(self.target))
        self.assertEqual(result.returncode, 2)
        self.assertIn("unknown --app 'bogus'", result.stderr)
        self.assertIn("hwtui", result.stderr)
        self.assertFalse(self.target.exists(), "nothing may be written for a bad app name")

    def test_check_reports_dependencies_and_writes_nothing(self):
        result = self.deploy("--app", "hwtui", "--check", "--dir", str(self.target))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("would copy", result.stdout)
        self.assertIn("termkit.lua", result.stdout)
        self.assertFalse(self.target.exists(), "--check must not create the target directory")

    def test_missing_dependency_is_a_visible_failure(self):
        isolated = self.root / "isolated source"
        isolated.mkdir()
        shutil.copy(ROOT / "deploy.lua", isolated / "deploy.lua")
        shutil.copy(ROOT / "luatop.lua", isolated / "luatop.lua")
        result = self.deploy("--app", "luatop", "--dir", str(self.target),
                             script=isolated / "deploy.lua")
        self.assertEqual(result.returncode, 1)
        self.assertIn("failed to install dependency termkit.lua", result.stderr)
        self.assertIn("same directory as deploy.lua", result.stderr)

    def test_redeploy_refreshes_a_stale_dependency(self):
        self.assertEqual(self.deploy("--app", "luatop", "--dir", str(self.target)).returncode, 0)
        installed = self.target / "termkit.lua"
        installed.write_text("-- stale copy\n")
        self.assertEqual(self.deploy("--app", "luatop", "--dir", str(self.target)).returncode, 0)
        self.assertEqual(installed.read_bytes(), (ROOT / "termkit.lua").read_bytes())

    def test_all_copies_each_shared_dependency_once(self):
        result = self.deploy("--dir", str(self.target))
        self.assertEqual(result.returncode, 0, result.stderr)
        copied = [line for line in result.stdout.splitlines() if "termkit.lua" in line]
        self.assertEqual(len(copied), 1, copied)
        for name in ("termkit.lua", "json.lua", "codefind.lua", "hwinfo_tui.lua", "luatop.lua"):
            self.assertTrue((self.target / name).is_file(), name + " missing after --app all")

    def test_json_dependency_still_installed_for_landrop(self):
        result = self.deploy("--app", "landrop", "--dir", str(self.target))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.target / "json.lua").is_file())

    def test_windows_layout_includes_the_dependency_and_launcher(self):
        result = self.deploy("--app", "hwtui", "--os", "windows", "--dir", str(self.target))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.target / "termkit.lua").is_file())
        launcher = (self.target / "hwtui.cmd").read_text()
        self.assertIn("hwinfo_tui.lua", launcher)
        self.assertIn("HWTUI_LUAJIT", launcher)


if __name__ == "__main__":
    unittest.main(verbosity=2)
