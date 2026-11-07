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


def ansi_safe(path):
    """Return a path luajit.exe can open: it uses the ANSI API, so on Windows a path with
    characters outside the code page (e.g. CJK) must be given in its 8.3 short form."""
    if os.name != "nt":
        return str(path)
    import ctypes
    buf = ctypes.create_unicode_buffer(32768)
    if ctypes.windll.kernel32.GetShortPathNameW(str(path), buf, len(buf)) == 0:
        return str(path)
    return buf.value


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
        started = run([LUAJIT, ansi_safe(self.target / "luatop.lua")], cwd=self.elsewhere,
                      stdin_text="q")
        self.assertEqual(started.returncode, 0, started.stderr)
        self.assertNotIn("not found", started.stderr)

    def test_hwtui_is_deployable_and_runs_from_any_directory(self):
        result = self.deploy("--app", "hwtui", "--dir", str(self.target))
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ("hwinfo_tui.lua", "termkit.lua", "hwtui"):
            self.assertTrue((self.target / name).is_file(), name + " missing")
        self.assertTrue(os.access(self.target / "hwtui", os.X_OK), "launcher not executable")
        if os.name == "nt":
            self.skipTest("deploy verified; hwinfo_tui itself supports only Linux")
        report = run([LUAJIT, ansi_safe(self.target / "hwinfo_tui.lua"), "--text"], cwd=self.elsewhere)
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
        self.assertIn("termkit (required by luatop.lua)", result.stderr)
        self.assertIn("next to deploy.lua", result.stderr)
        self.assertFalse(self.target.exists(), "nothing may be written for a broken source tree")

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


@unittest.skipUnless(LUAJIT, "LuaJIT is required")
class DeployDiscovery(unittest.TestCase):
    """Dependencies are found by scanning the app source, so new requires need no registry edit."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="deploy-discovery-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.target = self.root / "target"
        for name in ("deploy.lua", "hwinfo_tui.lua", "termkit.lua"):
            shutil.copy(ROOT / name, self.source / name)

    def append_to_app(self, text):
        with open(self.source / "hwinfo_tui.lua", "a", encoding="utf-8") as handle:
            handle.write("\n" + text + "\n")

    def module(self, name, body="return {}"):
        (self.source / (name + ".lua")).write_text(body + "\n", encoding="utf-8")

    def deploy(self):
        return run([LUAJIT, str(self.source / "deploy.lua"), "--app", "hwtui", "--dir",
                    str(self.target)], cwd=self.root)

    def installed(self):
        return sorted(path.name for path in self.target.iterdir() if path.suffix == ".lua")

    def test_new_require_is_installed_without_touching_the_registry(self):
        self.module("extra_mod", 'require("deep_mod")')
        self.module("deep_mod", 'require("extra_mod")')  # circular on purpose
        self.append_to_app('local extra = require("extra_mod")')
        result = self.deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.installed(),
                         ["deep_mod.lua", "extra_mod.lua", "hwinfo_tui.lua", "termkit.lua"])
        copied = [line for line in result.stdout.splitlines() if "extra_mod.lua" in line]
        self.assertEqual(len(copied), 1, "copied once: %s" % copied)

    def test_optional_pcall_require_is_installed_when_present(self):
        self.module("optional_mod")
        self.append_to_app('local ok, mod = pcall(require, "optional_mod")')
        self.assertEqual(self.deploy().returncode, 0)
        self.assertIn("optional_mod.lua", self.installed())

    def test_missing_optional_module_is_not_an_error(self):
        self.append_to_app('local ok, mod = pcall(require, "not_installed_anywhere")')
        result = self.deploy()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_comments_strings_and_test_modules_are_not_dependencies(self):
        for name in ("ghost_line", "ghost_block", "ghost_string", "test_helper"):
            self.module(name)
        self.append_to_app('-- require("ghost_line")')
        self.append_to_app('--[[ require("ghost_block") ]]')
        self.append_to_app('local helper = [[ local m = require("ghost_string") ]]')
        self.append_to_app('local ok = pcall(require, "test_helper")')
        result = self.deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.installed(), ["hwinfo_tui.lua", "termkit.lua"])

    def test_unresolvable_required_module_fails_before_writing(self):
        self.append_to_app('local lost = require("no_such_module")')
        result = self.deploy()
        self.assertEqual(result.returncode, 1)
        self.assertIn("no_such_module (required by hwinfo_tui.lua)", result.stderr)
        self.assertFalse(self.target.exists(), "nothing may be written")

    def test_missing_module_inside_a_dependency_names_the_dependency(self):
        self.module("extra_mod", 'require("lost_in_extra")')
        self.append_to_app('local extra = require("extra_mod")')
        result = self.deploy()
        self.assertEqual(result.returncode, 1)
        self.assertIn("lost_in_extra (required by extra_mod.lua)", result.stderr)

    def test_builtin_modules_need_no_file(self):
        self.append_to_app('local a, b, c = require("ffi"), require("bit"), require("jit")')
        result = self.deploy()
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
