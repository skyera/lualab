#!/usr/bin/env python3
"""Tests for cutline: server options and the UI color theme.

The theme checks are static. The live server tests are skipped when
luvit is not installed.
"""
import http.client
import json
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
ROOT_BLOCK = re.compile(
    r':root(?:\[data-theme="([\w-]+)"\])?\s*\{(.*?)\n    \}', re.S)
CSS_VARIABLE = re.compile(r"(--[\w-]+)\s*:")
IMAGE_OVERLAY_VARIABLES = {
    "--cutline", "--cutline-glow", "--handle-fill", "--handle-label",
    "--hover-marker", "--hover-ring",
}
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


def read_root_blocks(html):
    """Return [(theme name or "", body)] for every :root block."""
    return [(name, body) for name, body in ROOT_BLOCK.findall(html)]


def find_color_literals(path, text):
    """Return "file:line: text" for each color literal in `text`."""
    found = []
    for number, line in enumerate(text.splitlines(), 1):
        if COLOR_LITERAL.search(line):
            found.append(f"{path}:{number}: {line.strip()}")
    return found


def test_theme_colors_in_root():
    html = (PUBLIC_DIR / "index.html").read_text()
    blocks = read_root_blocks(html)
    check(blocks and blocks[0][0] == "", "index.html starts with :root")
    root_block = blocks[0][1] if blocks else ""

    # Blank out :root blocks but keep newlines so line numbers stay true.
    blanked = html
    for _, body in blocks:
        blanked = blanked.replace(body, "\n" * body.count("\n"))
    stray = find_color_literals("index.html", blanked)
    for name in THEMED_FILES[1:]:
        stray += find_color_literals(name, (PUBLIC_DIR / name).read_text())
    for line in stray:
        print(f"  stray color: {line}")
    check(stray == [], "colors are defined only in :root")

    defined = set(CSS_VARIABLE.findall(root_block))
    used = set(re.findall(r"var\((--[\w-]+)\)", html))
    theme_js = (PUBLIC_DIR / "theme.js").read_text()
    used |= set(re.findall(r'"(--[\w-]+)"', theme_js))
    missing = sorted(used - defined)
    for name in missing:
        print(f"  undefined variable: {name}")
    check(missing == [], "every var(--x) and theme.js variable is defined")
    check_theme_blocks(html, blocks[1:], defined)


def check_theme_blocks(html, theme_blocks, defined):
    """Theme blocks may only override base variables, never the image
    overlay ones, and must match the select options and theme.js."""
    for name, body in theme_blocks:
        overridden = set(CSS_VARIABLE.findall(body))
        unknown = sorted(overridden - defined)
        for variable in unknown:
            print(f"  theme {name}: {variable} is not in base :root")
        check(unknown == [], f"theme {name}: overrides base variables only")
        fixed = sorted(overridden & IMAGE_OVERLAY_VARIABLES)
        for variable in fixed:
            print(f"  theme {name}: overrides image overlay {variable}")
        check(fixed == [], f"theme {name}: keeps image overlay colors")

    select = re.search(r'<select id="themeSelect".*?</select>', html, re.S)
    options = re.findall(r'<option value="([\w-]+)"',
                         select.group(0) if select else "")
    theme_js = (PUBLIC_DIR / "theme.js").read_text()
    names_match = re.search(r"THEME_NAMES = \[(.*?)\]", theme_js)
    js_names = re.findall(r'"([\w-]+)"',
                          names_match.group(1) if names_match else "")
    block_names = ["slate"] + [name for name, _ in theme_blocks]
    print(f"  themes: select={options} theme.js={js_names} "
          f"css={block_names}")
    check(options == js_names == block_names,
          "theme select, THEME_NAMES and CSS theme blocks agree")


def http_request(host, port, method, path, body=None, headers=None):
    connection = http.client.HTTPConnection(host, port, timeout=2)
    try:
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        return response.status, response.headers, response.read()
    finally:
        connection.close()


def test_api_endpoints():
    port = find_free_port()
    process = run_server(["--port", str(port)])
    try:
        status = wait_for_health("127.0.0.1", port)
        check(status == 200, "api test server started")
        if status != 200:
            return

        # 2x2 RGBA: (0,0)=red(200,0,0), (1,0)=green(0,200,0),
        #           (0,1)=blue(0,0,200), (1,1)=white(200,200,200)
        pixels = bytes([
            200, 0, 0, 255, 0, 200, 0, 255,
            0, 0, 200, 255, 200, 200, 200, 255,
        ])
        code, _, body = http_request(
            "127.0.0.1", port, "POST", "/api/image", body=pixels,
            headers={"X-Image-Width": "2", "X-Image-Height": "2"},
        )
        uploaded = json.loads(body)
        image_id = uploaded.get("image_id")
        check(code == 200 and image_id == "1",
              "POST /api/image stores 2x2 RGBA buffer")

        # Sample top row (0,0) -> (1,0) with 3 samples: midpoint is (100,100,0)
        cut_body = json.dumps({
            "image_id": image_id, "x1": 0, "y1": 0,
            "x2": 1, "y2": 0, "samples": 3,
        })
        code, _, body = http_request(
            "127.0.0.1", port, "POST", "/api/cutline", body=cut_body,
            headers={"Content-Type": "application/json"},
        )
        profile = json.loads(body)
        check(code == 200 and profile["r"] == [200, 100, 0]
              and profile["g"] == [0, 100, 200]
              and profile["b"] == [0, 0, 0],
              "POST /api/cutline computes bilinear RGB profile")
        check(profile["luma"] == [42.52, 92.78, 143.04]
              and profile["stats"]["samples"] == 3
              and profile["stats"]["length"] == 1,
              "POST /api/cutline computes luma and stats")

        # CSV export
        code, headers, body = http_request(
            "127.0.0.1", port, "GET",
            f"/api/export?image_id={image_id}&x1=0&y1=0&x2=1&y2=0&samples=2",
        )
        csv_lines = body.decode().strip().splitlines()
        check(code == 200
              and "text/csv" in headers.get("Content-Type", "")
              and csv_lines[0] == "index,distance_px,r,g,b,luminance"
              and len(csv_lines) == 3,
              "GET /api/export returns CSV profile")

        # Validation & safety errors
        bad_uploads = [
            ("non-integer width", "0.5", "2", pixels[:4]),
            ("NaN width", "nan", "2", pixels),
            ("byte mismatch", "2", "2", pixels[:8]),
        ]
        for label, w, h, data in bad_uploads:
            code, _, _ = http_request(
                "127.0.0.1", port, "POST", "/api/image", body=data,
                headers={"X-Image-Width": w, "X-Image-Height": h},
            )
            check(code == 400, f"POST /api/image rejects {label} with 400")

        code, _, _ = http_request(
            "127.0.0.1", port, "POST", "/api/image", body=b"",
            headers={"X-Image-Width": "8192", "X-Image-Height": "8192"},
        )
        check(code == 413, "POST /api/image rejects oversized image with 413")

        code, _, _ = http_request(
            "127.0.0.1", port, "POST", "/api/cutline",
            body=json.dumps({"image_id": image_id, "x1": "nan"}),
        )
        check(code == 400, "POST /api/cutline rejects NaN coord with 400")

        code, _, _ = http_request(
            "127.0.0.1", port, "GET",
            f"/api/export?image_id={image_id}&x1=nan",
        )
        check(code == 400, "GET /api/export rejects NaN coord with 400")

        code, _, _ = http_request(
            "127.0.0.1", port, "POST", "/api/cutline",
            body="x" * (65 * 1024),
        )
        check(code == 413, "POST /api/cutline rejects oversized JSON with 413")

        code, _, _ = http_request(
            "127.0.0.1", port, "POST", "/api/cutline",
            body=json.dumps({"image_id": "9999"}),
        )
        check(code == 404, "POST /api/cutline returns 404 for unknown image")

        # Eviction: upload 16 more images so image #1 is evicted
        last_id = None
        for _ in range(16):
            code, _, body = http_request(
                "127.0.0.1", port, "POST", "/api/image", body=pixels,
                headers={"X-Image-Width": "2", "X-Image-Height": "2"},
            )
            last_id = json.loads(body).get("image_id")
        old_code, _, _ = http_request(
            "127.0.0.1", port, "GET", f"/api/export?image_id={image_id}",
        )
        new_code, _, _ = http_request(
            "127.0.0.1", port, "GET", f"/api/export?image_id={last_id}",
        )
        check(old_code == 404 and new_code == 200,
              "image cache evicts oldest image after 16 uploads")

        # Static index + unknown route
        idx_code, idx_hdrs, _ = http_request("127.0.0.1", port, "GET", "/")
        miss_code, _, _ = http_request("127.0.0.1", port, "GET", "/nope")
        check(idx_code == 200
              and "text/html" in idx_hdrs.get("Content-Type", "")
              and miss_code == 404,
              "static / returns HTML and unknown route returns 404")
    finally:
        stop_server(process)


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
    test_api_endpoints()
    if failures:
        print(f"{len(failures)} FAILED")
        return 1
    print("ALL PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
