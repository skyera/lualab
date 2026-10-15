// =============================================================================
// test_curl_windows.js
// Windows libcurl DLL Discovery, Selection & Verification Test Suite
// =============================================================================

// Real curl DLL discovery, selection and verified pins; no external network in fixtures.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawn, spawnSync } = require('node:child_process');
const { once } = require('node:events');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const app = path.join(root, 'app.lua');

test('Windows curl candidates can be selected, pinned and repaired', {
  skip: process.platform !== 'win32'
}, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dict-curl-'));
  const config = path.join(dir, 'settings', 'config.json');
  const run = (flags, input, setup, environment = {}) => spawnSync(
    'luajit',
    [...(setup ? ['-e', setup] : []), app, '--config', config, ...flags],
    {
      encoding: 'utf8',
      input,
      timeout: 10000,
      env: { ...process.env, WORDBOOK_CURL_DLL: '', WORDBOOK_SQLITE3: '', ...environment }
    }
  );

  let child;
  try {
    let result = run(['--curl-list'], undefined, `local ffi = require('ffi')
        local original = ffi.load
        ffi.load = function(name, ...)
            if name:lower():find('curl', 1, true) or name:find('sqlite3', 1, true) then
                error('Listing must not load native database/network libraries')
            end
            return original(name, ...)
        end`);
    assert.equal(result.status, 0, result.stdout + result.stderr);

    const candidates = [...result.stdout.matchAll(/(\d+)\. (.+(?:libcurl(?:-4)?|curl)\.dll) \[/g)];
    assert.ok(candidates.length >= 2, result.stdout);

    // Pick a candidate that matches the active LuaJIT architecture
    const lines = result.stdout.split(/\r?\n/);
    const candidate = candidates.find(m => (
      !lines.some(line => line.includes(m[2]) && line.includes('Architecture does not match'))
      && m[2].endsWith('/libcurl.dll')
    )) || candidates[candidates.length - 1];

    fs.mkdirSync(path.dirname(config));
    const existing = { custom: { value: 42 }, curl_dll: 'missing.dll' };
    fs.writeFileSync(config, JSON.stringify(existing));

    result = run(['--curl-select', '--tls-revoke-best-effort', '--proxy', 'auto'], candidate[1] + '\n');
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.match(result.stdout, /selected \(HTTPS/);
    assert.match(result.stdout, /Configuration saved and verified:/);
    assert.doesNotMatch(result.stdout, /Wordbook: http|SQLite .* selected/);

    const saved = JSON.parse(fs.readFileSync(config));
    assert.deepEqual(saved, {
      ...existing,
      curl_dll: candidate[2],
      tls_revoke_best_effort: true,
      proxy: 'auto',
      http_client: 'curl'
    });

    const invalidAttempts = [
      [['--curl-select'], /Invalid curl selection/],
      [['--curl-select', '--curl-dll', path.join(dir, 'missing.dll')], /missing or unreadable/],
      [['--curl-select', '--curl-dll', path.join(process.env.SystemRoot, 'System32', 'kernel32.dll')], /missing curl_/]
    ];
    for (const [flags, pattern] of invalidAttempts) {
      result = run(flags, '99999\n');
      assert.equal(result.status, 1, result.stdout);
      assert.match(result.stderr, pattern);
      assert.deepEqual(JSON.parse(fs.readFileSync(config)), saved);
    }

    result = run(
      ['--curl-select', '--curl-dll', saved.curl_dll],
      undefined,
      undefined,
      { WORDBOOK_CURL_DLL: path.join(dir, 'missing.dll') }
    );
    assert.equal(result.status, 0, result.stderr);

    result = run(
      ['--http-client', 'curl', '--db', path.join(dir, 'unused.db'), '--dict-db', 'none'],
      undefined,
      undefined,
      { WORDBOOK_CURL_DLL: path.join(dir, 'missing.dll') }
    );
    assert.equal(result.status, 1);
    assert.match(result.stderr, /missing or unreadable/);
    assert.ok(!fs.existsSync(path.join(dir, 'unused.db')));

    const setup = `package.path = ${JSON.stringify(root.replaceAll('\\', '/') + '/?.lua;')} .. package.path
        local ffi = require('ffi')
        local original = ffi.load
        ffi.load = function(name, ...)
            if name == 'libcurl' or name == 'libcurl.dll' or name == 'libcurl-4.dll' then
                error('Unpinned curl loading forbidden')
            end
            return original(name, ...)
        end`;

    child = spawn('luajit', [
      '-e', setup,
      app,
      '--config', config,
      '--db', path.join(dir, 'words.db'),
      '--dict-db', 'none',
      '--port', '0',
      '--http-client', 'curl'
    ], { env: { ...process.env, WORDBOOK_CURL_DLL: '' } });

    let logs = '';
    child.stderr.on('data', b => { logs += b; });
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

    assert.ok(logs.includes(saved.curl_dll));
    assert.match(logs, /TLS revocation: (best effort|best-effort setting inactive)/);
    assert.equal((await fetch(url + '/api/stats')).status, 200);
    assert.doesNotMatch(logs, /Unpinned curl loading forbidden/);

    const exited = once(child, 'exit');
    child.kill();
    await exited;

    result = run(['--curl-select', '--curl-dll', saved.curl_dll, '--tls-revoke-strict', '--proxy', 'none']);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(JSON.parse(fs.readFileSync(config)).tls_revoke_best_effort, false);
    assert.equal(JSON.parse(fs.readFileSync(config)).proxy, 'none');
    assert.match(result.stdout, /HTTP proxy: direct/);
    assert.match(result.stdout, /TLS revocation: backend defaults/);

    fs.unlinkSync(config);
    fs.rmdirSync(path.dirname(config));
    result = run(['--curl-select', '--curl-dll', saved.curl_dll]);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(JSON.parse(fs.readFileSync(config)).curl_dll, saved.curl_dll);
  } finally {
    if (child && child.exitCode === null && child.signalCode === null) {
      const exited = once(child, 'exit');
      child.kill();
      await exited;
    }
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('Curl rejects a DLL without HTTPS and preserves detailed request errors', {
  skip: process.platform !== 'win32'
}, () => {
  const script = `package.path = ${JSON.stringify(root.replaceAll('\\', '/') + '/?.lua;')} .. package.path
      local ffi = require('ffi')
      local loader = require('curl_loader')
      local root_parent = ${JSON.stringify(root.replaceAll('\\', '/') + '/..')}
      local root_dir = ${JSON.stringify(root.replaceAll('\\', '/'))}
      local candidates = loader.discover(root_parent, root_dir)
      local library, info
      for _, c in ipairs(candidates) do
          local ok, lib, inf = pcall(loader.validate, c.path)
          if ok then
              library, info = lib, inf
              break
          end
      end
      assert(library and info, 'No valid candidate found for HTTPS fixture test')

      local original = ffi.load
      local protocols = ffi.new('const char *[2]')
      protocols[0] = 'http'
      local version = ffi.new('wb_curl_version_info[1]')
      ffi.copy(version, library.curl_version_info(0), ffi.sizeof(version))
      version[0].protocols = protocols

      ffi.load = function(name, ...)
          if name == info.path then
              return setmetatable({
                  curl_version_info = function()
                      assert(protocols[0] ~= nil)
                      return ffi.cast('wb_curl_version_info *', version)
                  end
              }, { __index = function(_, key) return library[key] end })
          end
          return original(name, ...)
      end

      local ok, err = pcall(loader.validate, info.path)
      assert(not ok and err:find('lacks HTTPS support', 1, true))
      ffi.load = original

      local buffer
      local fake = setmetatable({
          curl_easy_setopt = function(handle, key, value)
              if key == 10010 then buffer = value end
              return 0
          end,
          curl_easy_perform = function()
              ffi.copy(buffer, 'Blocked redirect protocol')
              return 1
          end
      }, { __index = function(_, key) return library[key] end })

      require('net').set_curl(fake, info)
      local result, message = require('net').fetch('https://example.invalid/')
      assert(not result and message:find('Blocked redirect protocol', 1, true) and message:find(info.path, 1, true))
      assert(message:find('https://example.invalid/', 1, true))
      print('HTTPS validation and detailed errors verified')`;

  const result = spawnSync('luajit', ['-e', script], { encoding: 'utf8', timeout: 10000 });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /HTTPS validation and detailed errors verified/);
});

test('Best-effort revocation keeps TLS verification and fails revoked certificates', () => {
  const script = `package.path = ${JSON.stringify(root.replaceAll('\\', '/') + '/?.lua;')} .. package.path
      local ffi = require('ffi')
      local net = require('net')
      local options
      local closed = 0
      local code = 0

      local fake = {
          curl_easy_init = function() return ffi.cast('WB_CURL *', 1) end,
          curl_easy_cleanup = function() closed = closed + 1 end,
          curl_easy_setopt = function(_, key, value) options[key] = value; return 0 end,
          curl_easy_perform = function()
              if code ~= 0 then ffi.copy(options[10010], 'Certificate is revoked') end
              return code
          end,
          curl_easy_getinfo = function(_, _, value) value[0] = 200; return 0 end,
          curl_easy_strerror = function() return 'Certificate error' end
      }

      local info = { path = 'fixture.dll', version = '8.11.1', version_num = 0x080b01, tls = 'Schannel' }
      net.set_curl(fake, info)
      net.set_proxy('none')

      options = {}
      assert(net.fetch('https://example.invalid/') == '')
      assert(tonumber(options[64]) == 1 and tonumber(options[81]) == 2 and options[216] == nil)

      assert(net.set_tls_revoke_best_effort(true))
      options = {}
      assert(net.fetch('https://example.invalid/') == '')
      assert(tonumber(options[64]) == 1 and tonumber(options[81]) == 2 and tonumber(options[216]) == 8)

      code = 60
      options = {}
      local value, err = net.fetch('https://example.invalid/')
      assert(not value and err:find('Certificate is revoked', 1, true))
      assert(closed == 3)

      net.set_tls_revoke_best_effort(false)
      options = {}
      code = 0
      assert(net.fetch('https://example.invalid/') == '' and options[216] == nil)

      info.tls = 'OpenSSL'
      net.set_tls_revoke_best_effort(true)
      options = {}
      assert(net.fetch('https://example.invalid/') == '' and options[216] == nil)

      info.tls = 'Schannel'
      info.version_num = 0x074500
      local ok, err = pcall(net.set_tls_revoke_best_effort, true)
      assert(not ok and err:find('7.70 or newer', 1, true))
      print('Strict defaults, best effort, certificate errors and backend/version checks verified')`;

  const result = spawnSync('luajit', ['-e', script], { encoding: 'utf8', timeout: 5000 });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /Strict defaults, best effort/);
});
