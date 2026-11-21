# LuaJIT Cutline Analyzer (Luvit)

A lightweight web application powered by **Luvit (LuaJIT 2.1 + FFI)** to display images, draw interactive cutlines (`A → B`), plot RGB/Luminance intensity profiles, compute line statistics, and export CSV data.

## Project Structure

- `server.lua` — Luvit HTTP server + LuaJIT FFI `uint8_t[?]` pixel buffer & bilinear cutline sampler
- `public/index.html` — Dark-mode web UI (image canvas, draggable cutline handles, colormaps, live intensity plot)

## Quick Start

1. Install **Luvit** from https://luvit.io/
2. Start the server (from any directory):

```sh
luvit server.lua
```

3. Open your browser to:

```
http://127.0.0.1:8100/
```

## Options

| Option        | Meaning                                                    |
|---------------|------------------------------------------------------------|
| `--public`    | Listen on all interfaces (`0.0.0.0`) so other computers can connect |
| `--host ADDR` | Listen on one IP address of this computer (default `127.0.0.1`) |
| `--port N`    | TCP port, 1-65535 (default `8100`)                         |
| `--help`      | Show usage                                                 |

The `PORT` environment variable sets the default port; `--port` wins.

By default the server is reachable only from this computer. To open it to
your network:

```sh
luvit server.lua --public              # port 8100
luvit server.lua --public --port 9000
```

The startup banner lists one URL per IPv4 address. There is no
authentication, so anyone who can reach the port can use the app; only use
`--public` on a network you trust. If other computers cannot connect, allow
the port through the firewall, e.g. `sudo ufw allow 8100/tcp` on Ubuntu or
an inbound rule for `luvit.exe` on Windows.

If the port is already in use, the server prints the error and a suggested
`--port` and exits with status 1. Invalid options exit with status 2.

## Tests

```sh
python3 test_cutline_server.py    # from the repository root
```
