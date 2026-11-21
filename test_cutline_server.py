#!/usr/bin/env python3
"""Tests for cutline: server options and the UI color theme.

The theme checks are static. The live server tests are skipped when
luvit is not installed.
"""
import http.client
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
SERVER = ROOT / "cutline" / "server.lua"
PUBLIC_DIR = ROOT / "cutline" / "public"
THEMED_FILES = ["index.html", "app.js", "plot.js", "theme.js"]
COLOR_LITERAL = re.compile(r"#[0-9a-fA-F]{3,8}\b|\brgba?\((?!\$\{)")
ROOT_BLOCK = re.compile(r":root\s*\{(.*?)\n    \}", re.S)
STARTUP_TIMEOUT_SECONDS = 5
EXIT_LISTEN_FAILED = 1
EXIT_USAGE = 2
USAGE = "usage: luvit server.lua [--public | --host ADDR] [--port N]"

failures = []


def check(condition, label):
    print(("PASS " if condition else "FAIL ") + label)
    if not condition:
        failures.append(label)


def find_free_port():
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        return reservation.getsockname()[1]


def find_lan_address():
    """Return a non-loopback IPv4 address of this host, or None."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        try:
            # UDP connect sends nothing; it only selects a route.
            probe.connect(("192.0.2.1", 9))
            address = probe.getsockname()[0]
        except OSError:
            return None
    return None if address.startswith("127.") else address


def run_server(args, env_port=None, cwd=ROOT):
    env = dict(os.environ)
    env.pop("PORT", None)
    if env_port is not None:
        env["PORT"] = env_port
    return subprocess.Popen(
        ["luvit", str(SERVER), *args], cwd=cwd, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )


def run_to_exit(args, env_port=None):
    process = run_server(args, env_port)
    try:
        stdout, stderr = process.communicate(timeout=STARTUP_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        process.kill()
        stdout, stderr = process.communicate()
        return None, stdout, stderr
    return process.returncode, stdout, stderr


def get_health_status(host, port):
    connection = http.client.HTTPConnection(host, port, timeout=1)
    try:
        connection.request("GET", "/api/health")
        return connection.getresponse().status
    finally:
        connection.close()


def wait_for_health(host, port):
    deadline = time.monotonic() + STARTUP_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        try:
            return get_health_status(host, port)
        except OSError:
            time.sleep(0.1)
    return None


def stop_server(process):
    process.terminate()
    try:
        stdout, _ = process.communicate(timeout=STARTUP_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        process.kill()
        stdout, _ = process.communicate()
    return stdout


def test_local_default_host():
    port = find_free_port()
    process = run_server(["--port", str(port)], cwd="/")
    status = wait_for_health("127.0.0.1", port)
    lan_address = find_lan_address()
    lan_refused = True
    if lan_address and status == 200:
        try:
            get_health_status(lan_address, port)
            lan_refused = False
        except OSError:
            pass
    stdout = stop_server(process)
    check(status == 200, "default host serves /api/health from cwd /")
    check(lan_refused, "default host is not reachable from LAN address")
    check(f"running at http://127.0.0.1:{port}/" in stdout,
          "default banner shows the local URL")
    check("Use --public" in stdout, "default banner explains --public")


def test_public_host():
    port = find_free_port()
    process = run_server(["--public", "--port", str(port)])
    status = wait_for_health("127.0.0.1", port)
    lan_address = find_lan_address()
    lan_status = None
    if lan_address:
        lan_status = wait_for_health(lan_address, port)
    stdout = stop_server(process)
    check(status == 200, "--public serves on loopback")
    if lan_address:
        check(lan_status == 200, f"--public serves on {lan_address}")
    else:
        print("SKIP --public LAN request (no non-loopback IPv4 address)")
    check(f"listening on 0.0.0.0:{port}" in stdout,
          "--public banner shows 0.0.0.0")
    check(f"http://127.0.0.1:{port}/" in stdout,
          "--public banner lists the loopback URL")
    check("Warning: no authentication" in stdout,
          "--public banner warns about authentication")


def test_port_precedence():
    env_port = find_free_port()
    cli_port = find_free_port()
    process = run_server(["--port", str(cli_port)], env_port=str(env_port))
    cli_status = wait_for_health("127.0.0.1", cli_port)
    stop_server(process)
    check(cli_status == 200, "--port wins over the PORT variable")

    process = run_server([], env_port=str(env_port))
    env_status = wait_for_health("127.0.0.1", env_port)
    stop_server(process)
    check(env_status == 200, "PORT variable sets the port without --port")


def test_usage_errors():
    cases = [
        (["--port", "0"], 'invalid port "0"'),
        (["--port", "70000"], 'invalid port "70000"'),
        (["--port", "abc"], 'invalid port "abc"'),
        (["--port", "1.5"], 'invalid port "1.5"'),
        (["--port"], "missing value for --port"),
        (["--host", "--port", "9000"], "missing value for --host"),
        (["--bogus"], 'unknown option "--bogus"'),
    ]
    for args, message in cases:
        code, _, stderr = run_to_exit(args)
        label = " ".join(args)
        check(code == EXIT_USAGE, f"{label}: exits {EXIT_USAGE}")
        check(f"error: {message}" in stderr and USAGE in stderr,
              f"{label}: stderr names the problem and usage")

    code, _, stderr = run_to_exit([], env_port="x")
    check(code == EXIT_USAGE, "PORT=x: exits 2")
    check("PORT environment variable" in stderr, "PORT=x: names PORT")

    code, stdout, _ = run_to_exit(["--help"])
    check(code == 0 and "--public" in stdout, "--help prints usage, exit 0")


def test_listen_failures():
    with socket.socket() as blocker:
        blocker.bind(("127.0.0.1", 0))
        blocker.listen()
        port = blocker.getsockname()[1]
        code, stdout, stderr = run_to_exit(["--port", str(port)])
    check(code == EXIT_LISTEN_FAILED, "busy port: exits 1")
    check(f"error: listen on 127.0.0.1:{port}: EADDRINUSE" in stderr,
          "busy port: stderr names the address and EADDRINUSE")
    check(f"--port {port + 1}" in stderr, "busy port: suggests next port")
    check("running" not in stdout, "busy port: no running banner")

    code, _, stderr = run_to_exit(["--host", "localhost", "--port", "9"])
    check(code == EXIT_LISTEN_FAILED, "--host localhost: exits 1")
    check("--host takes an IP address" in stderr,
          "--host localhost: explains IP addresses")

    code, _, stderr = run_to_exit(["--host", "192.0.2.1"])
    check(code == EXIT_LISTEN_FAILED, "foreign --host: exits 1")
    check("EADDRNOTAVAIL" in stderr, "foreign --host: EADDRNOTAVAIL")


def read_root_block(html):
    match = ROOT_BLOCK.search(html)
    return match.group(1) if match else ""


def find_color_literals(path, text):
    """Return "file:line: text" for each color literal in `text`."""
    found = []
    for number, line in enumerate(text.splitlines(), 1):
        if COLOR_LITERAL.search(line):
            found.append(f"{path}:{number}: {line.strip()}")
    return found


def test_theme_colors_in_root():
    html = (PUBLIC_DIR / "index.html").read_text()
    root_block = read_root_block(html)
    check(root_block != "", "index.html has a :root block")

    # Blank out :root but keep its newlines so line numbers stay true.
    blanked = html.replace(root_block, "\n" * root_block.count("\n"))
    stray = find_color_literals("index.html", blanked)
    for name in THEMED_FILES[1:]:
        stray += find_color_literals(name, (PUBLIC_DIR / name).read_text())
    for line in stray:
        print(f"  stray color: {line}")
    check(stray == [], "colors are defined only in :root")

    defined = set(re.findall(r"(--[\w-]+)\s*:", root_block))
    used = set(re.findall(r"var\((--[\w-]+)\)", html))
    theme_js = (PUBLIC_DIR / "theme.js").read_text()
    used |= set(re.findall(r'"(--[\w-]+)"', theme_js))
    missing = sorted(used - defined)
    for name in missing:
        print(f"  undefined variable: {name}")
    check(missing == [], "every var(--x) and theme.js variable is defined")


def main():
    test_theme_colors_in_root()
    if shutil.which("luvit") is None:
        print("SKIP live server tests: luvit is not installed")
        return 1 if failures else 0
    test_local_default_host()
    test_public_host()
    test_port_precedence()
    test_usage_errors()
    test_listen_failures()
    if failures:
        print(f"{len(failures)} FAILED")
        return 1
    print("ALL PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
