"""Exercise the real HTTP loop with a deliberately slow, controllable worker."""
import json
import os
import pathlib
import socket
import subprocess
import tempfile
import time
import urllib.request


def main():
    if os.name == "nt":
        print("Live HTTP harness requires POSIX; use the native worker lifecycle tests on Windows")
        return
    repo = pathlib.Path(__file__).resolve().parent
    lua_path = 'package.path = ' + json.dumps(str(repo / "?.lua") + ";") + ' .. package.path\n'
    with tempfile.TemporaryDirectory(prefix="lan scan test ") as directory:
        root = pathlib.Path(directory)
        inventory = root / "inventory.json"
        control = root / "control.txt"
        clock = root / "clock.txt"
        clock.write_text("1000")
        def set_clock(timestamp):
            temporary = clock.with_suffix(".tmp")
            temporary.write_text(str(timestamp))
            temporary.replace(clock)
        control.write_text("complete")
        inventory.write_text(json.dumps({"version": 1, "devices": [{
            "ip": "127.0.0.1", "mac": "aa:bb:cc:dd:ee:01", "hostname": "Saved NAS",
            "vendor": "Test", "category": "linux", "type_name": "Linux", "ports": [],
            "status": "online", "is_custom": True, "first_seen": 100, "last_seen": 200,
        }]}))
        original = inventory.read_text()
        worker = root / "slow worker.lua"
        worker.write_text(lua_path + '''
local jobs = require("lan_scan_job")
local ffi = require("ffi")
ffi.cdef[[int usleep(unsigned int);]]
local path = (...)
local input = assert(jobs.read_update(path))
local control = assert(io.open(CONTROL, "r"))
local mode = control:read("*a"); control:close()
for i = 1, 12 do
    assert(jobs.write_update(path .. ".progress", {phase = "discovery", completed = i * 20, total = 254}))
    ffi.C.usleep(100000)
end
if mode == "fail" then
    io.stderr:write("Expected slow worker error visible in server output\\n")
    assert(jobs.write_update(path .. ".result", {error = "Deliberate worker failure"}))
    os.exit(1)
end
assert(jobs.write_update(path .. ".progress", {phase = "devices", completed = 1, total = 1}))
assert(jobs.write_update(path .. ".result", {devices = {{ip = "127.0.0.1", mac = "aa:bb:cc:dd:ee:01",
    hostname = "Worker stale name", is_custom = true, vendor = "Test", category = "linux",
    type_name = "Linux", status = "online", ports = {}, hardware = {}, latency_ms = 1}},
    subnet = "127.0.0.0/24", finished_at = os.time()}))
'''.replace("CONTROL", json.dumps(str(control))))
        with socket.socket() as port_socket:
            port_socket.bind(("127.0.0.1", 0))
            port = port_socket.getsockname()[1]
        driver = root / "server.lua"
        driver.write_text(lua_path + '''
local real_time = os.time
os.time = function(value)
    if value then return real_time(value) end
    local file = assert(io.open(CLOCK, "r"))
    local timestamp = tonumber(file:read("*a")); file:close()
    return timestamp
end
'''.replace("CLOCK", json.dumps(str(clock))) + 'local lan = require("lan_dashboard")\nlan.run_web_server(PORT, '
                          '{worker_command = {"luajit", WORKER}})\n'
                          .replace("PORT", str(port)).replace("WORKER", json.dumps(str(worker))))
        env = dict(os.environ, LAN_INVENTORY_FILE=str(inventory))
        output = root / "server.log"
        with output.open("w") as log:
            server = subprocess.Popen(["luajit", str(driver)], cwd=root, env=env, stdout=log, stderr=log)
            base = f"http://127.0.0.1:{port}"

            def request(path, method="GET", data=None):
                started = time.monotonic()
                req = urllib.request.Request(base + path, method=method,
                    data=json.dumps(data).encode() if data is not None else None)
                with urllib.request.urlopen(req, timeout=2) as response:
                    body = response.read().decode()
                    status = response.status
                elapsed = time.monotonic() - started
                assert elapsed < 0.5, f"HTTP blocked for {elapsed:.3f}s: {path}"
                return status, json.loads(body) if path.startswith("/api/") else body

            def wait_state(states):
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    status = request("/api/scan")[1]["scan"]
                    if status["state"] in states:
                        return status
                    time.sleep(0.03)
                raise AssertionError(f"Scan did not reach {states}: {status}")

            try:
                for _ in range(50):
                    try:
                        request("/")
                        break
                    except OSError:
                        if server.poll() is not None:
                            raise AssertionError(output.read_text())
                        time.sleep(0.02)
                else:
                    raise AssertionError("Server did not start")
                initial = request("/api/devices")[1]
                assert initial["scan"]["state"] == "running"
                assert initial["devices"][0]["last_seen"] == 200
                code, duplicate = request("/api/scan", "POST")
                assert code == 202 and duplicate["scan"]["id"] == initial["scan"]["id"]
                time.sleep(0.15)
                progress = request("/api/scan")[1]["scan"]
                assert progress["total"] == 254 and progress["completed"] > 0
                request("/api/stats")
                request("/api/ping?ip=127.0.0.1")
                cancel_started = time.monotonic()
                request("/api/scan/cancel", "POST")
                cancelled = wait_state({"cancelled"})
                assert time.monotonic() - cancel_started < 0.8
                assert inventory.read_text() == original
                assert request("/api/devices")[1]["devices"][0]["last_seen"] == 200
                assert request("/api/scan/cancel", "POST")[1]["scan"]["state"] == "cancelled"

                code, restart = request("/api/scan", "POST")
                assert code == 202 and restart["scan"]["id"] > cancelled["id"]
                assert wait_state({"completed", "failed"})["state"] == "completed"
                completed = request("/api/devices")[1]
                assert completed["devices"][0]["first_seen"] == 100
                assert completed["devices"][0]["last_seen"] > 200
                assert json.loads(inventory.read_text())["devices"] == completed["devices"]

                # Rename and probe remain usable, and their updates survive publication.
                request("/api/scan", "POST")
                request("/api/rename", "POST", {"ip": "127.0.0.1", "name": "Renamed during scan"})
                with socket.socket() as service:
                    service.bind(("127.0.0.1", 0))
                    service.listen(2)
                    service_port = service.getsockname()[1]
                    probed = request(f"/api/probe?ip=127.0.0.1&ports={service_port}")[1]
                    assert any(p["port"] == service_port for p in probed["ports"])
                assert wait_state({"completed", "failed"})["state"] == "completed"
                edited = request("/api/devices")[1]["devices"][0]
                assert edited["hostname"] == "Renamed during scan"
                assert any(p["port"] == service_port for p in edited["ports"])

                control.write_text("fail")
                before_failure = inventory.read_text()
                request("/api/scan", "POST")
                failed = wait_state({"failed"})
                assert failed["error"] == "Deliberate worker failure"
                assert inventory.read_text() == before_failure
                request("/")
                assert "Expected slow worker error" in output.read_text()
                control.write_text("complete")
                request("/api/scan", "POST")
                request("/api/scan/cancel", "POST")
                wait_state({"cancelled"})

                # Advance the server clock to exercise automatic scans without a minute-long sleep.
                previous_id = request("/api/scan")[1]["scan"]["id"]
                set_clock(1061)
                automatic = wait_state({"running"})
                assert automatic["id"] > previous_id
                request("/api/stats")
                request("/api/scan/cancel", "POST")
                auto_cancelled = wait_state({"cancelled"})
                set_clock(1062)
                time.sleep(0.1)
                latest = request("/api/scan")[1]["scan"]
                assert latest["id"] == auto_cancelled["id"] and latest["state"] == "cancelled"
            finally:
                server.terminate()
                try:
                    server.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()
        print("Live HTTP scans: responsiveness, progress, cancellation, retry, persistence, and automatic scans PASS")


if __name__ == "__main__":
    main()
