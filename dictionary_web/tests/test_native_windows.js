// =============================================================================
// test_native_windows.js
// Windows Native WinHTTP Client & TLS Validation Test Suite
// =============================================================================

// Windows defaults to WinHTTP without loading curl DLLs; native errors remain visible.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawn, spawnSync } = require('node:child_process');
const { once } = require('node:events');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const https = require('node:https');

const root = path.resolve(__dirname, '..').replaceAll('\\', '/');

test('Windows native startup ignores stale curl pins and performs lookup without curl', {
  skip: process.platform !== 'win32'
}, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dict-native-'));
  const config = path.join(dir, 'config.json');
  fs.writeFileSync(config, JSON.stringify({ curl_dll: 'missing.dll', custom: 42 }));

  const setup = `package.path = ${JSON.stringify(root + '/?.lua;')} .. package.path
      local ffi = require('ffi')
      local original = ffi.load
      ffi.load = function(name, ...)
          assert(not name:lower():find('curl', 1, true), 'Must not load curl')
          return original(name, ...)
      end
      require('net_windows').fetch = function(url)
          return '<ul class="basic"><li><span class="trans">A native fixture.</span></li></ul>'
      end`;

  const child = spawn('luajit', [
    '-e', setup,
    root + '/app.lua',
    '--config', config,
    '--db', path.join(dir, 'words.db'),
    '--dict-db', 'none',
    '--port', '0',
    '--save-config'
  ]);

  let logs = '';
  child.stderr.on('data', b => { logs += b; });

  try {
    const url = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(logs)), 5000);
      child.on('error', e => {
        clearTimeout(timer);
        reject(e);
      });
      child.on('exit', code => {
        clearTimeout(timer);
        reject(new Error('Exited ' + code + ': ' + logs));
      });
      child.stdout.on('data', b => {
        logs += b;
        const match = logs.match(/Wordbook: (http:\/\/127\.0\.0\.1:\d+)/);
        if (match) {
          clearTimeout(timer);
          resolve(match[1]);
        }
      });
    });

    assert.match(logs, /HTTP client: Windows WinHTTP/);
    assert.doesNotMatch(logs, /Curl .*selected|Must not load curl/);

    const response = await fetch(url + '/api/search', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ word: 'hello', source: 'youdao' })
    });
    assert.equal(response.status, 200);
    assert.equal((await response.json()).saved, true);

    const saved = JSON.parse(fs.readFileSync(config));
    assert.equal(saved.curl_dll, 'missing.dll');
    assert.equal(saved.custom, 42);
  } finally {
    if (child.exitCode === null && child.signalCode === null) {
      const exited = once(child, 'exit');
      child.kill();
      await exited;
    }
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('WinHTTP rejects an untrusted real TLS certificate and non-HTTPS URLs', {
  skip: process.platform !== 'win32'
}, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dict-native-tls-'));
  let server;

  try {
    const key = path.join(dir, 'key.pem');
    const cert = path.join(dir, 'cert.pem');
    const opensslConfig = path.join(dir, 'openssl.cnf');
    fs.writeFileSync(opensslConfig, '[req]\ndistinguished_name=req_dn\n[req_dn]\n');

    const created = spawnSync('openssl', [
      'req', '-config', opensslConfig,
      '-x509', '-newkey', 'rsa:2048', '-nodes',
      '-subj', '/CN=localhost',
      '-keyout', key, '-out', cert, '-days', '1'
    ], { encoding: 'utf8' });
    assert.equal(created.status, 0, created.stderr);

    server = https.createServer({
      key: fs.readFileSync(key),
      cert: fs.readFileSync(cert)
    }, (_, res) => res.end('unsafe'));
    server.on('tlsClientError', () => {});
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');

    const url = 'https://127.0.0.1:' + server.address().port + '/';
    const script = `package.path = ${JSON.stringify(root + '/?.lua;')} .. package.path
        local native = require('net_windows')
        local value, err = native.fetch(${JSON.stringify(url)}, nil, 'none')
        assert(not value and err:find('TLS certificate or handshake failed', 1, true), tostring(err))
        value, err = native.fetch('http://example.invalid/', nil, 'none')
        assert(not value and err:find('Only HTTPS', 1, true))
        print('TLS trust rejection and HTTPS restriction verified')`;

    const child = spawn('luajit', ['-e', script]);
    let output = '';
    child.stdout.on('data', b => { output += b; });
    child.stderr.on('data', b => { output += b; });
    const timer = setTimeout(() => child.kill(), 20000);

    try {
      const [code] = await once(child, 'exit');
      assert.equal(code, 0, output);
    } finally {
      clearTimeout(timer);
    }
  } finally {
    if (server) {
      server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
    }
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('Native redirects, response bounds, timeouts and handle cleanup are enforced', {
  skip: process.platform !== 'win32'
}, () => {
  const script = `package.path = ${JSON.stringify(root + '/?.lua;')} .. package.path
      local ffi = require('ffi')
      local original = ffi.load
      local kernel = original('kernel32')
      local scenario, closed, reads, requests, code, tick = 'success', 0, 0, 0, 0, 0

      local api = {
          WinHttpOpen = function() return 1 end,
          WinHttpConnect = function() return 2 end,
          WinHttpOpenRequest = function() requests = requests + 1; return 3 end,
          WinHttpSetTimeouts = function() return 1 end,
          WinHttpSetOption = function(_, option) assert(option == 88 or option == 118); return 1 end,
          WinHttpSendRequest = function()
              if scenario == 'timeout' then code = 12002; return 0 end
              return 1
          end,
          WinHttpReceiveResponse = function() return 1 end,
          WinHttpCloseHandle = function() closed = closed + 1; return 1 end,
          WinHttpQueryHeaders = function(_, kind, _, buffer, size)
              if kind == 19 + 0x20000000 then
                  local status = 200
                  if scenario == 'http_error' then
                      status = 403
                  elseif scenario == 'redirect_http' or scenario == 'loop'
                      or (scenario == 'redirect_https' and requests == 1) then
                      status = 302
                  end
                  ffi.cast('unsigned long *', buffer)[0] = status
                  return 1
              end
              local target = scenario == 'redirect_http' and 'http://unsafe.example/' or '/next'
              if buffer == nil then
                  size[0] = (#target + 1) * 2
                  code = 122
                  return 0
              end
              local text = ffi.cast('uint16_t *', buffer)
              for i = 1, #target do
                  text[i - 1] = target:byte(i)
              end
              text[#target] = 0
              return 1
          end,
          WinHttpReadData = function(_, buffer, _, count)
              reads = reads + 1
              if scenario == 'read_error' then code = 12029; return 0 end
              if scenario == 'deadline' then tick = 20000 end
              local text = scenario == 'large' and string.rep('x', 16384) or reads == 1 and 'fixture' or ''
              ffi.copy(buffer, text, #text)
              count[0] = #text
              return 1
          end
      }

      ffi.load = function(name, ...)
          if name == 'winhttp' then return api end
          if name == 'kernel32' then
              return setmetatable({
                  GetLastError = function() return code end,
                  GetTickCount64 = function() return tick end
              }, { __index = function(_, key) return kernel[key] end })
          end
          return original(name, ...)
      end

      local native = require('net_windows')
      local scenarios = {
          'success', 'http_error', 'redirect_http', 'redirect_https',
          'loop', 'large', 'read_error', 'timeout', 'deadline'
      }

      for _, name in ipairs(scenarios) do
          scenario, closed, reads, requests, code, tick = name, 0, 0, 0, 0, 0
          local value, err = native.fetch('https://example.invalid/', nil, 'none')
          if name == 'success' or name == 'redirect_https' then
              assert(value == 'fixture', tostring(err))
          else
              assert(not value and err:find('Dictionary connection failed', 1, true), name)
          end
          assert(closed == requests * 3, name .. ' leaked handles')
          if name == 'redirect_http' then
              assert(err:find('Blocked non-HTTPS redirect', 1, true))
          end
          if name == 'large' then
              assert(err:find('exceeds 2 MB', 1, true))
          end
          if name == 'timeout' or name == 'deadline' then
              assert(err:find('timed out', 1, true))
          end
      end
      print('Native bounds and cleanup verified')`;

  const result = spawnSync('luajit', ['-e', script], { encoding: 'utf8', timeout: 5000 });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /Native bounds and cleanup verified/);
});
