"""Regression checks for Git operations, terminal rendering, and actual key dispatch."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest
import time


ROOT = Path(__file__).resolve().parent
APP = ROOT / "lazygit_lite.lua"
LUAJIT = shutil.which("luajit")
SOURCE = APP.read_text(encoding="utf-8").split(
    "-- Run with protected terminal cleanup;", 1
)[0].split("\n", 1)[1]

MOCK = r'''
local frames, actions = {}, {}
local keys, key_index = {}, 0
local status = " M file.txt\0"
local width, height = 160, 30
local branches, commits = "* main\n", "abc|Author|now|Subject"
local failure
local on_key
local query_count = 0
local saved_print = print
enable_raw_mode = function() return false end
disable_raw_mode = function() end
get_terminal_size = function() return width, height end
read_key = function()
    key_index = key_index + 1
    if on_key then on_key(key_index) end
    return keys[key_index] or "q"
end
io.write = function(text) frames[#frames + 1] = text end
io.flush = function() end
print = function() end
exec_git = function(args)
    if args[1] == "rev-parse" then
        return args[2] == "--is-inside-work-tree" and "true" or "/test/repository\n"
    elseif args[1] == "status" then
        return status
    elseif args[1] == "branch" then
        return args[2] == "--show-current" and "main" or branches
    elseif args[1] == "log" then
        return commits
    elseif args[1] == "diff" or args[1] == "show" then
        query_count = query_count + 1
        return "+preview\n"
    end
    actions[#actions + 1] = args
    if failure then return nil, failure end
    return "ok"
end
local function plain(text)
    return text:gsub("\27%[[%d;?]*[A-Za-z]", "")
end
local function all_output()
    return plain(table.concat(frames))
end
'''


@unittest.skipUnless(LUAJIT, "LuaJIT required")
class LazyGitLiteTests(unittest.TestCase):
    def lua(self, code, cwd=None, mock=False):
        preamble = "arg[0] = " + json.dumps(str(APP), ensure_ascii=False) + "\n"
        result = subprocess.run(
            [LUAJIT, "-"], input=(preamble + SOURCE + (MOCK if mock else "") + code).encode(),
            cwd=cwd or ROOT, capture_output=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        return result.stdout

    def git(self, directory, *args):
        result = subprocess.run(
            ["git", "-c", "core.autocrlf=false", *args], cwd=directory,
            capture_output=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        return result.stdout

    def test_discard_requires_confirmation(self):
        self.lua(r'''
keys = { "d", "n", "q" }
main()
assert(#actions == 0)
assert(all_output():find("[y/N]", 1, true))
assert(all_output():find("Discard cancelled", 1, true))
frames, keys, key_index = {}, { "d", "y", "q" }, 0
main()
assert(#actions == 1 and actions[1][1] == "restore")
assert(actions[1][2] == "--" and actions[1][3] == "file.txt")
''', mock=True)

    def test_git_failures_visible_without_success(self):
        self.lua(r'''
for _, sequence in ipairs({ { "SPACE", "q" }, { "d", "y", "q" }, { "a", "q" } }) do
    frames, keys, key_index = {}, sequence, 0
    failure = "index.lock: File exists; remove stale lock after checking Git processes"
    main()
    local text = all_output()
    assert(text:find("index.lock", 1, true), text)
    assert(not text:find("Staged file", 1, true))
    assert(not text:find("Discarded changes", 1, true))
end
''', mock=True)

    def test_commit_tokens_and_failed_input_preservation(self):
        self.lua(r'''
keys = { "c", "h", "i", "SPACE", "x", "BACKSPACE", "!", "ENTER", "ESC", "q" }
failure = "hook rejected commit"
main()
assert(actions[1][1] == "commit" and actions[1][3] == "hi !")
local text = all_output()
assert(text:find("hook rejected commit", 1, true), text)
assert(not text:find("Committed:", 1, true))
assert(query_count == 1, "typing must not re-query Git")
for index = 3, 8 do
    local _, rows = frames[index]:gsub("\27%[%d+;1H", "")
    assert(rows == 1, "typing should redraw only the prompt row")
end
''', mock=True)

    def test_scrolling_all_lists_and_boundary_navigation(self):
        self.lua(r'''
local files, branch_rows, commit_rows = {}, {}, {}
for i = 1, 25 do
    files[i] = " M file" .. i .. ".txt\0"
    branch_rows[i] = "  branch" .. i
    commit_rows[i] = "hash" .. i .. "|Author|now|subject" .. i
end
status, branches, commits = table.concat(files), table.concat(branch_rows, "\n"), table.concat(commit_rows, "\n")
for pane = 1, 3 do
    frames, keys, key_index = {}, { tostring(pane) }, 0
    for _ = 1, 24 do keys[#keys + 1] = "DOWN" end
    keys[#keys + 1] = "q"
    main()
    local last = plain(frames[#frames])
    local expected = pane == 1 and "file25.txt" or (pane == 2 and "branch25" or "hash25")
    assert(last:find(expected, 1, true), last)
end
''', mock=True)

    def test_renderers_sizes_long_unicode_and_empty_transitions(self):
        self.lua(r'''
local long = C.sel_bg .. string.rep("長name%", 40) .. C.reset
for _, size in ipairs({ 0, 1, 3, 4, 12, 30 }) do
    local value = truncate(long, size)
    assert(visual_len(value) <= size)
    assert(not value:gsub("\27%[[%d;]*m", ""):find("\27", 1, true))
end
for _, dimensions in ipairs({ { 1, 1 }, { 20, 8 }, { 61, 20 }, { 100, 30 }, { 200, 50 } }) do
    width, height = dimensions[1], dimensions[2]
    frames, keys, key_index = {}, { "2", "3", "4", "c", "ESC", "d", "n", "q" }, 0
    main()
    for _, frame in ipairs(frames) do
        if frame:find("\27[?2026h", 1, true) then
            assert(frame:sub(-8) == "\27[?2026l")
            assert(not frame:find("\27[2J", 1, true))
            for line in frame:gmatch("([^\n]*)\n") do
                assert(line:sub(-3) == "\27[K")
            end
        end
    end
end
width, height, frames, keys, key_index = 100, 30, {}, { "r", "q" }, 0
on_key = function(index) if index == 1 then status, branches, commits = "", "", "" end end
main()
assert(all_output():find("Working tree clean", 1, true))
local screen = {}
for _, frame in ipairs(frames) do
    for row, content in frame:gmatch("\27%[(%d+);1H(.-)\27%[K\n") do
        screen[tonumber(row)] = plain(content)
    end
end
assert(not table.concat(screen, "\n"):find("file.txt", 1, true), "stale file rows survived refresh")
''', mock=True)

    def test_key_decoder_preserves_bursts_and_fragmented_sequences(self):
        self.lua(r'''
local pending = "ab \27[B\27[5~\127\r"
local expected = { "a", "b", "SPACE", "DOWN", "PAGE_UP", "BACKSPACE", "ENTER" }
for _, token in ipairs(expected) do
    local actual
    actual, pending = decode_key(pending, false)
    assert(actual == token, tostring(actual) .. " ~= " .. token)
end
assert(pending == "")
local token, rest = decode_key("\27[", false)
assert(token == nil and rest == "\27[")
token, rest = decode_key(rest .. "Aq", false)
assert(token == "UP" and rest == "q")
token = decode_key("\27", true)
assert(token == "ESC")
token, rest = decode_key("\228\184", false)
assert(token == nil)
token, rest = decode_key(rest .. "\173x", false)
assert(token == "中" and rest == "x")
''')

    @unittest.skipIf(os.name == "nt", "POSIX terminal integration")
    def test_pty_burst_input_and_signal_cleanup(self):
        import pty
        import select
        import signal
        import termios

        for shutdown in ("keys", "signal"):
            with self.subTest(shutdown=shutdown), tempfile.TemporaryDirectory() as directory:
                self.git(directory, "init", "-q")
                master, slave = pty.openpty()
                original = termios.tcgetattr(slave)
                child = subprocess.Popen([LUAJIT, str(APP)], cwd=directory,
                                         stdin=slave, stdout=slave, stderr=slave)
                output = b""
                try:
                    deadline = time.monotonic() + 15
                    while b"LAZYGIT-LITE" not in output and time.monotonic() < deadline:
                        if select.select([master], [], [], 0.1)[0]:
                            output += os.read(master, 65536)
                    self.assertIn(b"LAZYGIT-LITE", output)
                    if shutdown == "keys":
                        os.write(master, b"cmessage with spaces\x1bq")
                    else:
                        child.send_signal(signal.SIGTERM)
                    deadline = time.monotonic() + 15
                    while child.poll() is None and time.monotonic() < deadline:
                        if select.select([master], [], [], 0.1)[0]:
                            output += os.read(master, 65536)
                    child.wait(timeout=2)
                    while select.select([master], [], [], 0.1)[0]:
                        output += os.read(master, 65536)
                    self.assertEqual(child.returncode, 0, output)
                    self.assertIn(b"\x1b[?1049l", output)
                    self.assertIn(b"\x1b[?25h", output)
                    self.assertIn(b"\x1b[?7h", output)
                    self.assertEqual(termios.tcgetattr(slave), original)
                    if shutdown == "keys":
                        self.assertIn(b"message with spaces", output)
                finally:
                    if child.poll() is None:
                        child.kill()
                        child.wait()
                    os.close(master)
                    os.close(slave)

    def test_real_git_paths_renames_and_message_arguments(self):
        with tempfile.TemporaryDirectory(prefix="lazygit test ") as directory:
            self.git(directory, "init", "-q")
            self.git(directory, "config", "user.name", "Test")
            self.git(directory, "config", "user.email", "test@example.invalid")
            names = ["space name.txt", "a & echo INJECTED.txt", "-dash.txt", "[ab]*.txt", "中文.txt", "%PATH%!test.txt"]
            if os.name == "nt":
                names.remove("[ab]*.txt")
                names.append("[ab].txt")
            else:
                names.append('quote\'"$.txt')
            for name in names:
                Path(directory, name).write_text("original\n", encoding="utf-8")
            lua_names = "{ " + ", ".join(json.dumps(n, ensure_ascii=False) for n in names) + " }"
            self.lua("local names = " + lua_names + r'''
assert(#get_git_commits() == 0)
local files = get_git_status()
assert(#files == #names)
for _, name in ipairs(names) do
    local found = false
    for _, file in ipairs(files) do if file.path == name then found = true end end
    assert(found, name)
    assert(table.concat(get_git_diff(name, false)):find("original", 1, true))
    assert(exec_git({ "add", "--", name }))
end
local message = 'spaces "quotes" & echo INJECTED %PATH% !bang! $HOME `uname`'
assert(exec_git({ "commit", "-m", message }))
assert(query_git({ "log", "-1", "--pretty=%B" }):gsub("%s+$", "") == message)
local output, err = exec_git({ "add", "--", "missing-file.txt" })
assert(output == nil and err:find("missing-file.txt", 1, true))
output, err = exec_git({ "commit", "-m", "nothing staged" })
assert(output == nil and #err > 0)
''', cwd=directory)
            self.git(directory, "mv", "--", names[0], "renamed space.txt")
            self.lua(r'''
local files = get_git_status()
assert(#files == 1 and files[1].path == "renamed space.txt")
assert(files[1].original_path == "space name.txt")
assert(exec_git({ "restore", "--staged", "--", files[1].path, files[1].original_path }))
''', cwd=directory)
            lock = Path(directory, ".git", "index.lock")
            lock.write_bytes(b"test-owned lock; preserve me")
            self.lua(r'''
local output, err = exec_git({ "add", "--", "renamed space.txt" })
assert(output == nil and err:find("index.lock", 1, true))
''', cwd=directory)
            self.assertEqual(lock.read_bytes(), b"test-owned lock; preserve me")

    def test_process_failure_and_large_output(self):
        self.lua(r'''
local output, err = process.run({ "nonexistent-lazygit-executable-12345" })
assert(output == nil and err:find("nonexistent", 1, true))
output = assert(process.run({ "git", "help", "-a" }))
assert(#output > 8192)
''')

    def test_live_pipeline_and_non_repository(self):
        with tempfile.TemporaryDirectory(prefix="lazygit live ") as directory:
            self.git(directory, "init", "-q")
            result = subprocess.run([LUAJIT, str(APP)], input=b"cmessage with spaces\x1bq",
                                    cwd=directory, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(b"Exited lazygit-lite", result.stdout)
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([LUAJIT, str(APP)], input=b"q", cwd=directory,
                                    capture_output=True, timeout=30)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"not a git repository", result.stderr.lower())

    def test_live_discard_cancel_confirm_and_stage(self):
        with tempfile.TemporaryDirectory(prefix="lazygit actions ") as directory:
            self.git(directory, "init", "-q")
            self.git(directory, "config", "user.name", "Test")
            self.git(directory, "config", "user.email", "test@example.invalid")
            target = Path(directory, "space & name.txt")
            target.write_bytes(b"original\n")
            self.git(directory, "add", "--", target.name)
            self.git(directory, "commit", "-qm", "initial")

            def run(keys):
                result = subprocess.run([LUAJIT, str(APP)], input=keys, cwd=directory,
                                        capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                return result.stdout

            target.write_bytes(b"unsaved edits\n")
            self.assertIn(b"Discard cancelled", run(b"dnq"))
            self.assertEqual(target.read_bytes(), b"unsaved edits\n")
            self.assertIn(b"Discarded changes", run(b"dyq"))
            self.assertEqual(target.read_bytes(), b"original\n")
            target.write_bytes(b"stage these edits\n")
            self.assertIn(b"Staged space & name.txt", run(b" q"))
            self.assertTrue(self.git(directory, "diff", "--cached"))
            self.assertIn(b"Unstaged space & name.txt", run(b" q"))
            self.assertFalse(self.git(directory, "diff", "--cached"))

    def test_bytecode_has_only_known_globals(self):
        allowed = {"arg", "assert", "debug", "dofile", "error", "io", "ipairs", "math", "os",
                   "pairs", "print", "require", "string", "table", "tonumber", "tostring", "xpcall"}
        for name in ("lazygit_lite.lua", "lazygit_process.lua"):
            result = subprocess.run([LUAJIT, "-bl", str(ROOT / name)], capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            globals_found = set(re.findall(rb'GGET[^\n]*; "([^"\r\n]+)"', result.stdout))
            self.assertFalse({n.decode() for n in globals_found} - allowed)


if __name__ == "__main__":
    unittest.main()
