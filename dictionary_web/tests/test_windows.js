// =============================================================================
// test_windows.js
// Windows Service Launch, SQLite Selection & Inline Requests Test Suite
// =============================================================================

// Real Windows launcher and HTTP requests; fixture only external provider traffic.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawn, spawnSync } = require('node:child_process');
const { once } = require('node:events');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.resolve(__dirname, '..');

test('Windows daily content and provider requests avoid POSIX workers', {
  skip: process.platform !== 'win32'
}, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dict-windows-'));
  const setup = `package.path = ${JSON.stringify(root.replaceAll('\\', '/') + '/?.lua;')} .. package.path
      package.preload.workers = function() error('Windows must not load POSIX workers') end
      require('net').fetch = function() return nil, 'Fixture offline' end
      require('providers').lookup = function(source, word)
          if word == 'fail' then error('Fixture failure') end
          return { definitions = { 'Windows fixture definition' }, examples = {} }
      end`;

  const child = spawn('luajit', [
    '-e', setup,
    path.join(root, 'app.lua'),
    '--port', '0',
    '--db', path.join(dir, 'words.db'),
    '--config', path.join(dir, 'config.json'),
    '--dict-db', 'none',
    '--no-auto-import'
  ]);

  let logs = '';
  child.stderr.on('data', b => { logs += b; });

  try {
    const url = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('Startup timed out: ' + logs)), 5000);
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

    assert.match(logs, /Windows: provider requests run inline/);
    assert.match(logs, /Listening: 127\.0\.0\.1:/);

    const daily = await fetch(url + '/api/daily');
    assert.equal(daily.status, 200);
    assert.ok((await daily.json()).word);

    for (const [word, source] of [['hello', 'iciba'], ['fail', 'iciba'], ['hello', 'local']]) {
      const response = await fetch(url + '/api/search', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ word, source })
      });
      assert.equal(response.status, 200);
      const value = await response.json();
      if (word === 'hello' && source === 'iciba') {
        assert.equal(value.saved, true);
      } else {
        assert.ok(value.error);
      }
    }

    const proverb = await fetch(url + '/api/proverb/random?source=all');
    assert.equal(proverb.status, 200);
    assert.ok((await proverb.json()).proverb.text);

    const fortune = await fetch(url + '/api/proverb/random?source=fortune');
    assert.equal(fortune.status, 400);
    assert.match((await fortune.json()).error, /Fortune requires Linux/);

    const stats = await fetch(url + '/api/stats');
    assert.equal(stats.status, 200);
    await stats.json();

    assert.doesNotMatch(
      logs,
      /cannot resolve symbol|Request failed|POSIX workers|The system cannot find the path specified/
    );
  } finally {
    if (child.exitCode === null && child.signalCode === null) {
      const exited = once(child, 'exit');
      child.kill();
      await exited;
    }
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('Windows dictionary SQLite selection saves, repairs pins and reuses both bindings', {
  skip: process.platform !== 'win32'
}, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dict-select-'));
  const config = path.join(dir, 'settings', 'config.json');
  const app = path.join(root, 'app.lua');
  const run = (flags, input) => spawnSync(
    'luajit',
    [app, '--config', config, ...flags],
    { encoding: 'utf8', input, timeout: 10000, env: { ...process.env, WORDBOOK_SQLITE3: '' } }
  );

  let child;
  try {
    let result = run(['--sqlite-list']);
    assert.equal(result.status, 0, result.stderr);
    const found = result.stdout.match(/(\d+)\. (.+sqlite3(?:-3)?\.dll) \[/);
    assert.ok(found, result.stdout);

    fs.mkdirSync(path.dirname(config));
    const existing = { custom: { value: 7 }, sqlite_dll: 'missing.dll' };
    fs.writeFileSync(config, JSON.stringify(existing));

    result = run(['--sqlite-select'], found[1] + '\n');
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.match(result.stdout, /FTS5 verified/);
    assert.match(result.stdout, /Configuration saved and verified:/);
    assert.doesNotMatch(result.stdout, /Wordbook: http/);

    const saved = JSON.parse(fs.readFileSync(config));
    assert.deepEqual(saved, { ...existing, sqlite_dll: found[2] });

    const invalidFlags = [
      ['--sqlite-select'],
      ['--sqlite-select', '--sqlite-dll', path.join(dir, 'missing.dll')],
      ['--sqlite-select', '--sqlite-dll', path.join(process.env.SystemRoot, 'System32', 'kernel32.dll')]
    ];
    for (const flags of invalidFlags) {
      result = run(flags, '99999\n');
      assert.equal(result.status, 1);
      assert.match(result.stderr, /SQLite recovery:/);
      assert.deepEqual(JSON.parse(fs.readFileSync(config)), saved);
    }

    const ftsSetup = `local ffi = require('ffi')
        local original = ffi.load
        ffi.load = function(name, ...)
            local lib = original(name, ...)
            if name == ${JSON.stringify(saved.sqlite_dll)} then
                return setmetatable({
                    sqlite3_exec = function(db, sql, ...)
                        if sql:find('fts5', 1, true) then return 1 end
                        return lib.sqlite3_exec(db, sql, ...)
                    end
                }, { __index = lib })
            end
            return lib
        end`;

    result = spawnSync(
      'luajit',
      ['-e', ftsSetup, app, '--config', config, '--sqlite-select', '--sqlite-dll', saved.sqlite_dll],
      { encoding: 'utf8', timeout: 10000 }
    );
    assert.equal(result.status, 1);
    assert.match(result.stderr, /FTS5/);
    assert.deepEqual(JSON.parse(fs.readFileSync(config)), saved);

    const setup = `package.path = ${JSON.stringify(root.replaceAll('\\', '/') + '/?.lua;')} .. package.path
        local ffi = require('ffi')
        local original = ffi.load
        ffi.load = function(name, ...)
            if name == 'sqlite3' then error('Unpinned loading forbidden') end
            return original(name, ...)
        end`;

    child = spawn('luajit', [
      '-e', setup,
      app,
      '--config', config,
      '--db', path.join(dir, 'words.db'),
      '--dict-db', 'none',
      '--port', '0'
    ]);

    let logs = '';
    child.stderr.on('data', b => { logs += b; });
    const url = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(logs)), 5000);
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

    assert.ok(logs.includes(saved.sqlite_dll));
    assert.equal((await fetch(url + '/api/stats')).status, 200);
    assert.doesNotMatch(logs, /Unpinned loading forbidden/);
  } finally {
    if (child && child.exitCode === null && child.signalCode === null) {
      const exited = once(child, 'exit');
      child.kill();
      await exited;
    }
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('Windows Fortune never starts a Unix shell command and All retains online providers', {
  skip: process.platform !== 'win32'
}, () => {
  const script = `package.path = ${JSON.stringify(root.replaceAll('\\', '/') + '/?.lua;')} .. package.path
      local calls = 0
      io.popen = function()
          calls = calls + 1
          error('Unexpected shell command')
      end
      local content = require('content')
      local value, err = content.fetch_fortune()
      assert(value == nil and err:find('Fortune requires Linux', 1, true))
      assert(not content.fetch_quote(function() return nil, 'Offline' end, 'all'))
      assert(calls == 0)

      local quote = assert(content.fetch_quote(function(url)
          if url == 'https://zenquotes.io/api/random' then
              return '[{"q":"Keep learning.","a":"Teacher"}]'
          end
          return nil, 'Offline'
      end, 'all'))
      assert(quote.text == 'Keep learning.' and calls == 0)

      local injected = assert(content.fetch_fortune(function()
          return 'Injected fixture quote.'
      end))
      assert(injected.text == 'Injected fixture quote.' and calls == 0)
      print('Windows Fortune guard verified')`;

  const result = spawnSync('luajit', ['-e', script], { encoding: 'utf8', timeout: 5000 });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /Windows Fortune guard verified/);
  assert.equal(result.stderr, '');
});
