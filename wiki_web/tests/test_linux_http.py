#!/usr/bin/env python3
"""Linux live-server and signal regression checks without a Node installation."""
import json
import re
import selectors
import signal
import socket
import subprocess
import sys
import tempfile
import unittest
import urllib.error
import urllib.request
from pathlib import Path


@unittest.skipUnless(sys.platform.startswith("linux"), "Linux signal regression")
class LinuxHttpTests(unittest.TestCase):
    def test_ipv6_unavailable_reports_failure(self):
        root = Path(__file__).resolve().parents[2]
        script = """
            package.path = '../?.lua;' .. package.path
            local ffi = require('ffi')
            local transport = setmetatable({}, { __index = ffi.C })
            transport.socket = function(family, kind, protocol)
                if family == 10 then return -1 end
                return ffi.C.socket(family, kind, protocol)
            end
            package.loaded.ffi = setmetatable({ C = transport }, { __index = ffi })
            require('http').serve(0, function() end, function()
                error('Unexpected startup success')
            end, '0.0.0.0', nil, { dual_stack = true })
        """
        result = subprocess.run(["luajit", "-e", script], cwd=root / "dictionary_web",
                                capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cannot create IPv4 + IPv6 server socket", result.stderr)
        self.assertIn("--host 127.0.0.1", result.stderr)
        self.assertNotIn("Unexpected startup success", result.stderr)

    def test_requests_concurrency_restart_and_signals(self):
        root = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory(prefix="leaf-linux-") as directory:
            notebook = Path(directory) / "笔记"
            fixture = subprocess.run(["luajit", str(root / "wiki_web/tests/test_dictionary.lua"), directory],
                                     cwd=directory, capture_output=True, text=True, timeout=10)
            self.assertEqual(fixture.returncode, 0, fixture.stdout + fixture.stderr)
            dictionary = Path(directory) / "词典.db"
            original_dictionary = dictionary.read_bytes()
            command = ["luajit", str(root / "wiki_web.lua"), "--port", "0",
                       "--data-dir", str(notebook), "--cache-dir", directory + "/cache",
                       "--config", directory + "/config.json", "--dict-db", str(dictionary), "--save-config"]
            for stop_signal in (signal.SIGTERM, signal.SIGINT):
                host = "127.0.0.1" if stop_signal == signal.SIGTERM else "0.0.0.0"
                launch = command if stop_signal == signal.SIGTERM else command + ["--host", host]
                child = subprocess.Popen(launch, cwd=directory, stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE, text=True)
                try:
                    with selectors.DefaultSelector() as selector:
                        selector.register(child.stdout, selectors.EVENT_READ)
                        self.assertTrue(selector.select(10), "Server startup timed out")
                    lines = []
                    while True:
                        line = child.stdout.readline()
                        lines.append(line)
                        if not line or "Leaf Wiki: http://" in line:
                            break
                    match = re.search(r"http://127\.0\.0\.1:(\d+)", line)
                    self.assertIsNotNone(match, line)
                    self.assertIn("Loading modules", "".join(lines))
                    self.assertIn("listening on " + host, line)
                    address = ("0100007F" if host == "127.0.0.1" else "0" * 32) + ":" + format(int(match.group(1)), "04X")
                    table = "tcp" if host == "127.0.0.1" else "tcp6"
                    sockets = Path("/proc/{}/net/{}".format(child.pid, table)).read_text().splitlines()
                    self.assertTrue(any(row.split()[1] == address and row.split()[3] == "0A"
                                        for row in sockets[1:]), "Actual socket binding differs from " + host)
                    url = match.group(0)
                    if host == "0.0.0.0":
                        self.assertIn("IPv4 + IPv6", line)
                        for destination in ("127.0.0.1", "::1"):
                            with socket.create_connection((destination, int(match.group(1))), timeout=5) as peer:
                                peer.sendall(("GET /api/state HTTP/1.1\r\nHost: nano.local:{}\r\n"
                                              "Connection: close\r\n\r\n".format(match.group(1))).encode())
                                response = peer.recv(4096)
                                self.assertTrue(response.startswith(b"HTTP/1.1 200"), response)

                    def request(route, body=None):
                        data = json.dumps(body).encode() if body is not None else None
                        req = urllib.request.Request(url + route, data=data,
                                                     headers={"Content-Type": "application/json"})
                        try:
                            response = urllib.request.urlopen(req, timeout=5)
                        except urllib.error.HTTPError as error:
                            response = error
                        with response:
                            return response.status, json.loads(response.read())

                    with socket.create_connection(("127.0.0.1", int(match.group(1))), timeout=5) as idle:
                        idle.sendall(b"GET /api/state HTTP/1.1\r\n")
                        status, state = request("/api/state")
                        self.assertEqual(status, 200)
                        self.assertEqual(state["data_dir"], str(notebook))
                        status, entry = request("/api/dictionary?word=EPHEMERAL")
                        self.assertEqual(status, 200)
                        self.assertEqual(len(entry["senses"]), 2)
                        self.assertEqual(entry["senses"][0]["syn"], "temporary")
                        self.assertEqual(request("/api/dictionary?word=")[0], 400)
                        if stop_signal == signal.SIGTERM:
                            status, page = request("/api/page", {
                                "id": "学习/日志", "content": "Hello " * 6000, "revision": ""})
                            self.assertEqual(status, 200)
                            self.assertEqual(request("/api/page", {
                                "id": page["id"], "content": "stale", "revision": "wrong"})[0], 409)
                            status, renamed = request("/api/rename", {
                                "id": page["id"], "destination": "Projects/Log", "revision": page["revision"]})
                            self.assertEqual(status, 200)
                            self.assertEqual(renamed["content"], page["content"])
                            status, changed = request("/api/page", {"id": renamed["id"],
                                "content": "Changed text", "revision": renamed["revision"]})
                            self.assertEqual(status, 200)
                            status, versions = request("/api/history?id=Projects%2FLog")
                            self.assertEqual(status, 200)
                            self.assertTrue(versions["versions"])
                            status, recovered = request("/api/history/restore", {"id": renamed["id"],
                                "selected": renamed["revision"], "revision": changed["revision"]})
                            self.assertEqual(status, 200)
                            self.assertEqual(recovered["content"], renamed["content"])
                        else:
                            self.assertEqual(state["pages"][0]["id"], "Projects/Log")
                    child.send_signal(stop_signal)
                    _, errors = child.communicate(timeout=10)
                    self.assertEqual(child.returncode, 0, errors)
                    self.assertEqual(errors, "")
                    self.assertEqual(dictionary.read_bytes(), original_dictionary)
                finally:
                    if child.poll() is None:
                        child.kill()
                        child.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()
