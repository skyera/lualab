#!/usr/bin/env python3
"""Live HTTP regressions for LAN Drop framing, concurrency, and cleanup."""
import http.client
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent


def main():
    with tempfile.TemporaryDirectory(prefix="landrop_http_") as directory:
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        process = subprocess.Popen(
            ["luajit", str(ROOT / "landrop_web.lua"), "--host", "127.0.0.1",
             "--port", str(port), "--dir", directory],
            cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )
        clients = []

        def request(method, path, body=None):
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
            try:
                connection.request(method, path, body)
                response = connection.getresponse()
                return response.status, dict(response.getheaders()), response.read()
            finally:
                connection.close()

        def connect():
            client = socket.create_connection(("127.0.0.1", port), timeout=3)
            clients.append(client)
            return client

        def raw(data):
            client = connect()
            client.sendall(data)
            client.shutdown(socket.SHUT_WR)
            response = http.client.HTTPResponse(client)
            response.begin()
            result = response.status, response.read()
            client.close()
            return result

        try:
            for _ in range(100):
                if process.poll() is not None:
                    raise AssertionError(process.stderr.read().decode())
                try:
                    assert request("GET", "/api/status")[0] == 200
                    break
                except OSError:
                    time.sleep(0.02)
            else:
                raise AssertionError("Server did not start")

            for value in [123, True, {}, [], None]:
                assert request("POST", "/api/clipboard", json.dumps({"text": value}))[0] == 400
                assert request("GET", "/api/status")[0] == 200
            for body in ['{"text":', '[]', '{}', 'plain text']:
                assert request("POST", "/api/clipboard", body)[0] == 400
            assert request("POST", "/api/clipboard", json.dumps({"text": "hello"}))[0] == 200
            print("ok - invalid clipboard requests return 400 and preserve service")

            idle = connect()
            idle.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\n")
            upload = connect()
            upload.sendall(b"POST /api/upload?name=slow.txt HTTP/1.1\r\n"
                           b"Host: localhost\r\nContent-Length: 6\r\n\r\nabc")
            assert request("GET", "/api/status")[0] == 200
            upload.sendall(b"def")
            response = http.client.HTTPResponse(upload)
            response.begin()
            assert response.status == 200
            response.read()
            upload.close()
            assert Path(directory, "slow.txt").read_bytes() == b"abcdef"
            print("ok - unfinished headers and streaming uploads do not block other clients")

            status, _ = raw(b"POST /api/upload?name=extra.txt HTTP/1.1\r\n"
                            b"CONTENT-LENGTH: 1\r\n\r\nABCDE")
            assert status == 200
            assert Path(directory, "extra.txt").read_bytes() == b"A"
            for header in [b"Content-Length: nope", b"Content-Length: -1",
                           b"Content-Length: 1\r\nContent-Length: 2",
                           b"Transfer-Encoding: chunked", b"Content-Length: 1073741825"]:
                assert raw(b"POST /api/upload?name=bad.txt HTTP/1.1\r\n" + header + b"\r\n\r\n")[0] == 400
            assert raw(b"POST /api/clipboard HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n")[0] == 400
            assert raw(b"POST /api/upload?name=bad.txt HTTP/1.1\r\n\r\n")[0] == 400
            assert raw(b"\r\n\r\n")[0] == 400
            assert raw(b"INVALID\r\n\r\n")[0] == 400
            assert raw(b"GET / HTTP/1.1\r\nX-Large: " + b"a" * 17000 + b"\r\n\r\n")[0] == 400
            print("ok - exact body lengths, case-insensitive headers, limits, and unsupported framing")

            original = Path(directory, "original.txt")
            original.write_bytes(b"keep me")
            assert raw(b"POST /api/upload?name=original.txt HTTP/1.1\r\n"
                       b"Content-Length: 10\r\n\r\nabc")[0] == 400
            assert original.read_bytes() == b"keep me"
            failed = Path(directory, "destination")
            failed.mkdir()
            (failed / "child").write_text("preserved")
            assert request("POST", "/api/upload?name=destination", b"replacement")[0] == 500
            assert (failed / "child").read_text() == "preserved"
            assert not list(Path(directory).glob(".tmp_*"))
            print("ok - interrupted uploads and real rename failures preserve destinations")

            active = b"<script>alert(1)</script>"
            assert request("POST", "/api/upload?name=active.html", active)[0] == 200
            status, headers, body = request("GET", "/view/active.html")
            assert status == 200 and body == active
            assert headers["Content-Security-Policy"] == "sandbox"
            assert headers["X-Content-Type-Options"] == "nosniff"
            print("ok - active file previews are sandboxed")

            payload = bytes(range(256)) * 16384
            assert request("POST", "/api/upload?name=large.bin", payload)[0] == 200
            # A slow reader exercises pending/partial sends while status remains available.
            reader = connect()
            reader.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
            reader.sendall(b"GET /download/large.bin HTTP/1.1\r\nHost: localhost\r\n\r\n")
            time.sleep(0.1)
            assert request("GET", "/api/status")[0] == 200
            reader.close()
            assert request("GET", "/download/large.bin")[2] == payload
            print("ok - slow downloads do not block clients and full downloads match byte-for-byte")

            abandoned = connect()
            abandoned.sendall(b"POST /api/upload?name=abandoned.txt HTTP/1.1\r\n"
                              b"Content-Length: 10\r\n\r\na")
            deadline = time.monotonic() + 18
            idle.settimeout(0.2)
            while time.monotonic() < deadline:
                try:
                    if idle.recv(1) == b"":
                        break
                except socket.timeout:
                    pass
            else:
                raise AssertionError("Idle headers were not timed out")
            abandoned.settimeout(3)
            assert abandoned.recv(1) == b""
            assert not Path(directory, "abandoned.txt").exists()
            assert not list(Path(directory).glob(".tmp_*"))
            assert request("GET", "/api/status")[0] == 200
            print("ok - idle deadlines close connections and remove temporary uploads")
        finally:
            for client in clients:
                client.close()
            process.terminate()
            process.communicate(timeout=5)


if __name__ == "__main__":
    main()
