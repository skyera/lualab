# LAN Dashboard & Port Probing Plan & Status

## 1. Overview & Goal
`lan_dashboard.lua` is a zero-dependency, pure LuaJIT FFI local network scanner and web dashboard for Windows (and POSIX). It discovers network devices via ARP cache inspection, ICMP ping, MAC OUI vendor resolution, NetBIOS queries, and Windows mDNS PTR resolution (`dnsapi.dll`), presenting an interactive UI on `http://localhost:8888/`.

---

## 2. Completed Architecture & Features

### 1. Interactive Standard & Custom Port Probing (Feature #4):
- **On-Demand Standard Probing**: Added **"⚡ Probe Ports"** buttons to device cards, table rows, and the **"🔍 Details"** inspection modal.
- **Service Detection**: Probes 12 standard services (SSH 22, DNS 53, HTTP 80, RPC 135, NetBIOS 139, HTTPS 443, SMB 445, RTSP 554, RDP 3389, UPnP 5000, Web-Alt 8080, Apple-Sync 62078).
- **Custom Port & Range Scanner**: In the Details inspection modal, users can specify arbitrary ports or ranges (e.g. `3000, 8000-8010, 11434`). The backend parses, clamps, and probes each with non-blocking sockets, dynamically merging discovered open ports into the device profile.
- **Non-Blocking Winsock 64-bit Core**: Fixed 64-bit `FIONBIO` command coercion (`0x8004667e` / `-2147195266`), probing 12 ports in ~300ms without blocking.
- **Categorized Color Badges**: Green for SSH, Red for RTSP, Blue for Web/HTTP, Amber for SMB/NetBIOS, Purple for RDP, Yellow for DNS.

### 2. Live Ping Latency & Jitter Monitor (Feature #3):
- **Continuous Ping**: Added a live latency monitor in the device inspection modal (`GET /api/ping?ip=<IP>`).
- **Neon Sparkline Canvas**: 2D HTML5 canvas renders an animated glowing blue line with gradient area fill showing the last 35 ping readings.
- **Real-Time Quality Metrics**: Computes and displays `Cur RTT`, `Min`, `Avg`, `Max`, `Jitter` (mean deviation), and `Packet Loss %` in real time.
- **Lifecycle Management**: Auto-starts/stops via toggle and cleanly disposes intervals on modal close (`closeModal`).

### 3. Scan Latency & mDNS Candidate Gating:
- **Candidate Gating**: In `resolve_system_hostname`, mDNS PTR queries (`dnsapi.DnsQuery_A`) are strictly gated to alive devices from known mDNS families (Apple, Raspberry Pi, NVIDIA, Linux, phone/tablet).
- **Instant Non-Candidate Resolution**: Routers, IoT smart plugs, Dahua/Hikvision cameras, and network switches bypass mDNS lookups instantly with 0ms delay.
- **Offline Banner Guard**: Guarded SSH banner grabbing (`grab_ssh_banner`) to only execute when `is_alive == true`.
- **Result**: Cold subnet scan dropped from ~34s down to ~13s (initial ARP priming + ICMP echo for 41 devices), and warm/cached scan runs in ~4.9s.

### 4. Web Server HTTP Resilience:
- **Client Read Select**: Added non-blocking `select` check (500ms timeout) before calling `ws2.recv(client_sock)` to prevent premature connection resets (`curl (56) Connection aborted`) caused by non-blocking socket inheritance.
- **Graceful TCP Shutdown**: Added `ws2.shutdown(client_sock, 1)` (SD_SEND) before closing client sockets.
- **Auto-Rescan Interval**: Tuned background auto-rescan interval to 60s.
- **Terminal Access & Activity Logging**: Logs every incoming HTTP request with client IP, method, URI, status, and payload size, plus auto-rescan completion logs. Displays both Local and Network URLs on startup.
- **Windows Port Safety**: Avoids `SO_REUSEADDR` on Windows to prevent port stealing / ghost listeners, and resets `addrlen[0]` before each `accept()` call.

### 5. Privacy & Security Hardening (GitHub Readiness):
- **`.gitignore`**: Added `lan_names.json`, `.dict.db`, and `*.db`.
- **Zero Privacy Leakage**: Dynamic `get_local_ip()` via socket query; test fixtures use generic dummy MAC suffixes (`:00:11:22`). Zero personal names, room labels, or camera locations in git tracked files or diffs.

---

## 3. Verification & Test Results

1. **Test Suite**:
   - `luajit test_lan_dashboard.lua` -> **22 Passed, 0 Failed**.
   - Bytecode Scoping Analysis (`luajit -bl`) -> **0 Undeclared Globals (`GGET`)**.
2. **REST API Endpoints**:
   - `GET /api/stats` -> 200 OK, returns live breakdown across categories.
   - `GET /api/devices` -> 200 OK, returns 41 live devices with hardware specs.
   - `GET /api/ping?ip=192.168.1.1` -> 200 OK (`{"rtt": 5, "alive": true, "status": "ok"}`).
   - `GET /api/probe?ip=192.168.1.1` -> 200 OK (`DNS:53, HTTP:80, HTTPS:443`).
   - `GET /api/probe?ip=192.168.1.1&ports=53,80,443,8080-8082` -> 200 OK (`{"custom": true, ...}`).
   - `GET /api/probe?ip=192.168.1.10` -> 200 OK (`SSH:22, HTTP:80, UPnP:5000`).
   - `GET /api/probe?ip=192.168.1.44` -> 200 OK (`SSH:22, DNS:53, HTTP:80, NetBIOS:139, SMB:445, HTTP-Alt:8080`).
3. **Git Working Tree Audit**:
   - `git diff` audit -> Passed (0 private keywords).
   - `lan_names.json` untracked and safely ignored.
