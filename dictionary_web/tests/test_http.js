// End-to-end checks run the real LuaJIT server with a temporary SQLite file.
const assert = require('node:assert/strict');
const { test } = require('node:test');
const { spawn, spawnSync } = require('node:child_process');
const { once } = require('node:events');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const root = path.resolve(__dirname, '..');

async function start(database, host = '127.0.0.1', dictionary = 'none', flags = [], setupExtra = '') {
  // Keep real HTTP/database tests offline by stubbing only the public Youdao
  // network response before running the actual application entry point.
  const publicFixture = '<ul class="basic"><li><span class="trans">A public-page fixture.</span></li></ul>';
  const icibaFixture = '<script id="__NEXT_DATA__">{"props":{"pageProps":{"initialReduxState":{"word":{"wordInfo":{"baesInfo":{"symbols":[{"ph_en":"həˈləʊ","parts":[{"part":"int.","means":["A public-page fixture."]}]}]}}}}}}}</script>';
  const setup = `package.path=${JSON.stringify(path.join(root, '?.lua') + ';')}..package.path; local net=require('net'); local original=net.fetch; net.fetch=function(url,body) if url:find('https://www.youdao.com/result?',1,true)==1 then return ${JSON.stringify(publicFixture)} elseif url:find('https://www.iciba.com/word?',1,true)==1 then return ${JSON.stringify(icibaFixture)} end return original(url,body) end`;
  const child = spawn('luajit', ['-e', setup + ';' + setupExtra, path.join(root, 'app.lua'), '--host', host, '--port', '0', '--db', database, '--dict-db', dictionary, ...flags], {
    env: { ...process.env, YOUDAO_APP_KEY: '', YOUDAO_APP_SECRET: '' }
  });
  let logs = '';
  child.stderr.on('data', data => { logs += data; });
  const url = await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => { child.kill(); reject(new Error('Server startup timed out: ' + logs)); }, 5000);
    child.on('error', error => { clearTimeout(timeout); reject(error); });
    child.on('exit', code => { clearTimeout(timeout); reject(new Error(`Server exited ${code}: ${logs}`)); });
    child.stdout.on('data', data => {
      logs += data;
      const match = logs.match(/Wordbook: (http:\/\/127\.0\.0\.1:\d+)/);
      if (match) { clearTimeout(timeout); resolve(match[1]); }
    });
  });
  return { child, url, logs: () => logs };
}
async function stop(server, signal = 'SIGTERM') {
  const exited = once(server.child, 'exit');
  server.child.kill(signal);
  const [code, receivedSignal] = await exited;
  assert.equal(code, 0, server.logs());
  assert.equal(receivedSignal, null);
}
async function post(url, route, body, headers = {}) {
  const response = await fetch(url + route, { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(body) });
  return { status: response.status, data: await response.json() };
}
async function raw(url, text, fragments = false) {
  const parsed = new URL(url);
  const client = net.connect(Number(parsed.port), parsed.hostname);
  const completed = new Promise((resolve, reject) => {
    let output = '';
    client.on('data', data => { output += data; });
    client.on('end', () => resolve(output)); client.on('error', reject);
    client.setTimeout(5000, () => { client.destroy(); reject(new Error('Raw request timed out')); });
  });
  await once(client, 'connect');
  if (fragments) {
    const split = text.indexOf('\r\n\r\n') + 4;
    client.write(text.slice(0, split));
    await new Promise(resolve => setTimeout(resolve, 40));
    client.write(text.slice(split));
  } else client.write(text);
  return completed;
}

test('real LuaJIT HTTP server, static UI, SQLite round trip and clean signals', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'wordbook-http-'));
  const database = path.join(directory, 'words.db');
  let server;
  try {
    server = await start(database);
    const { url } = server;
    for (const [route, type] of [['/', 'text/html'], ['/style.css', 'text/css'], ['/app.js', 'text/javascript']]) {
      const response = await fetch(url + route);
      assert.equal(response.status, 200); assert.ok(response.headers.get('content-type').startsWith(type));
      assert.ok((await response.text()).length > 100);
      assert.ok(response.headers.get('content-security-policy').includes("script-src 'self'"));
    }
    assert.equal((await fetch(url + '/', { method: 'HEAD' })).status, 200);
    assert.equal((await fetch(url + '/api/daily')).status, 200);
    assert.deepEqual((await (await fetch(url + '/api/words')).json()).words, []);
    let result = await post(url, '/api/search', { word: '  HELLO ', source: 'merriam-webster' });
    assert.equal(result.status, 400); assert.match(result.data.error, /valid dictionary source/);
    assert.equal(result.data.id, undefined);
    assert.deepEqual((await (await fetch(url + '/api/words')).json()).words, []);
    result = await post(url, '/api/search', { word: 'hello', source: 'youdao' });
    const id = result.data.id;
    assert.equal(result.data.saved, true);
    result = await post(url, '/api/search', { word: 'hello', source: 'youdao' });
    assert.equal(result.data.id, id); assert.equal(result.data.lookup_count, 2);
    assert.equal((await post(url, '/api/note', { id, note: '你好 <script>alert(1)</script>' })).status, 200);
    assert.equal((await post(url, '/api/review', { id, remembered: true })).status, 200);
    assert.deepEqual((await (await fetch(url + '/api/words?due=1')).json()).words, []);
    let words = (await (await fetch(url + '/api/words?q=hell')).json()).words;
    assert.equal(words.length, 1); assert.equal(words[0].review_count, 1);
    assert.equal(words[0].note, '你好 <script>alert(1)</script>');
    let suggestions = (await (await fetch(url + '/api/suggest?q=hel')).json()).suggestions;
    assert.equal(suggestions.length, 1);
    assert.equal(suggestions[0].word, 'hello');
    assert.equal((await post(url, '/api/search', { word: '学习', source: 'youdao' })).status, 200);
    assert.equal((await post(url, '/api/search', { word: '', source: 'dict.cn' })).status, 400);
    assert.equal((await post(url, '/api/search', { word: 'hello', source: {} })).status, 400);
    assert.equal((await post(url, '/api/review', { id, remembered: 'yes' })).status, 400);
    assert.equal((await post(url, '/api/review', { id: 99999, remembered: true })).status, 404);
    assert.equal((await post(url, '/api/note', { id, note: 'x'.repeat(4001) })).status, 400);
    assert.equal((await post(url, '/api/search', { word: 'x' }, { 'Content-Type': 'application/jsonfoo' })).status, 415);
    assert.equal((await post(url, '/api/search', { word: 'x' }, { Origin: 'https://evil.example' })).status, 403);
    const host = new URL(url).host;
    assert.match(await raw(url, 'GET / HTTP/1.1\r\nHost: evil.example\r\n\r\n'), /^HTTP\/1.1 403/);
    assert.match(await raw(url, `POST /api/search HTTP/1.1\r\nHost: ${host}\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n{}`), /^HTTP\/1.1 400/);
    assert.match(await raw(url, `POST /api/search HTTP/1.1\r\nHost: ${host}\r\nContent-Type: application/json\r\nContent-Length: 9000\r\n\r\n`), /^HTTP\/1.1 413/);
    assert.match(await raw(url, `GET /../schema.sql HTTP/1.1\r\nHost: ${host}\r\n\r\n`), /^HTTP\/1.1 404/);
    assert.match(await raw(url, `POST /api/search HTTP/1.1\r\nHost: ${host}\r\nContent-Type: application/json\r\nContent-Length: 4\r\n\r\noops`), /^HTTP\/1.1 400/);
    const body = JSON.stringify({ word: 'fragmented', source: 'youdao' });
    assert.match(await raw(url, `POST /api/search HTTP/1.1\r\nHost: ${host}\r\nContent-Type: application/json\r\nContent-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`, true), /^HTTP\/1.1 200/);
    await stop(server); server = await start(database);
    words = (await (await fetch(server.url + '/api/words?q=hello')).json()).words;
    assert.equal(words[0].lookup_count, 2); assert.equal(words[0].review_count, 1);
    assert.equal(words[0].note, '你好 <script>alert(1)</script>');
    await stop(server, 'SIGINT'); server = null;
  } finally {
    if (server && server.child.exitCode === null) await stop(server);
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('all-interface mode accepts remote Host headers and same-origin browser writes', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'wordbook-network-'));
  let server;
  try {
    server = await start(path.join(directory, 'words.db'), '0.0.0.0');
    const port = new URL(server.url).port;
    for (const hostname of ['192.168.1.102', '100.101.69.0', 'wordbook.example']) {
      const host = `${hostname}:${port}`;
      assert.match(await raw(server.url, `GET /api/daily HTTP/1.1\r\nHost: ${host}\r\n\r\n`), /^HTTP\/1.1 200/);
      const body = JSON.stringify({ word: 'remote', source: 'youdao' });
      const response = await raw(server.url, `POST /api/search HTTP/1.1\r\nHost: ${host}\r\nOrigin: http://${host}\r\nContent-Type: application/json\r\nContent-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
      assert.match(response, /^HTTP\/1.1 200/);
    }
    assert.match(await raw(server.url, `GET / HTTP/1.1\r\nHost: wordbook.example:${Number(port) + 1}\r\n\r\n`), /^HTTP\/1.1 403/);
    assert.match(await raw(server.url, `GET / HTTP/1.1\r\nHost: user@wordbook.example:${port}\r\n\r\n`), /^HTTP\/1.1 403/);
    assert.equal((await post(server.url, '/api/search', { word: 'remote' }, { Origin: 'https://evil.example' })).status, 403);
    await stop(server); server = null;
    for (const host of ['invalid', '::', '192.168.1.102']) {
      const result = spawnSync('luajit', [path.join(root, 'app.lua'), '--host', host], { encoding: 'utf8' });
      assert.notEqual(result.status, 0); assert.match(result.stderr, /Invalid --host/);
    }
  } finally {
    if (server && server.child.exitCode === null) await stop(server);
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('HTTP uses imported dictionary and shared TUI notes/reviews without ID collisions', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'wordbook-shared-http-'));
  const dictionaryPath = path.join(directory, 'dictionary.db');
  const env = { ...process.env, WORDBOOK_TEST_DB: dictionaryPath };
  const luaPrefix = `package.path=${JSON.stringify(path.join(root, '..', '?.lua') + ';')}..package.path; local d=require('ffi_dict'); local db=assert(d.Database.open(os.getenv('WORDBOOK_TEST_DB'))); `;
  let server;
  try {
    const seed = spawnSync('luajit', ['-e', luaPrefix + `assert(db:dict_replace_word('hello',{{pos='interjection',definition='A greeting.',example='Hello, friend.'}})==1); assert(db:deck_add({word='hello',mnem='TUI note'},100)); db:close()`], { env, encoding: 'utf8' });
    assert.equal(seed.status, 0, seed.stderr);
    server = await start(path.join(directory, 'words.db'), '127.0.0.1', dictionaryPath);
    let words = (await (await fetch(server.url + '/api/words')).json()).words;
    assert.equal(words.length, 1); assert.equal(words[0].collection, 'tui'); assert.equal(words[0].note, 'TUI note');
    const tuiId = words[0].id;
    const other = await post(server.url, '/api/search', { word: 'other', source: 'youdao' });
    assert.equal(other.data.collection, 'web'); assert.equal(other.data.id, tuiId);
    const local = await post(server.url, '/api/search', { word: 'hello', source: 'local' });
    assert.equal(local.status, 200); assert.equal(local.data.collection, 'tui');
    assert.ok(local.data.entry.definitions[0].includes('A greeting.'));
    // Cache a controlled dict.cn entry so all-source HTTP verification stays offline.
    const cacheEnv = { ...process.env, WORDBOOK_WEB_TEST_DB: path.join(directory, 'words.db') };
    const cacheCode = `package.path=${JSON.stringify(path.join(root, '?.lua') + ';' + path.join(root, '..', '?.lua') + ';')}..package.path; local d=require('db'); local db=d.open(os.getenv('WORDBOOK_WEB_TEST_DB')); db:save('hello','dict.cn',{definitions={'A cached greeting.'},examples={},phonetic=''},os.time()); db:close()`;
    const cache = spawnSync('luajit', ['-e', cacheCode], { env: cacheEnv, encoding: 'utf8' });
    assert.equal(cache.status, 0, cache.stderr);
    const all = await post(server.url, '/api/search', { word: 'hello', source: 'all' });
    assert.equal(all.status, 200); assert.equal(all.data.results.length, 4);
    assert.ok(all.data.results[0].entry); assert.ok(all.data.results[1].cached);
    assert.equal(all.data.results[2].entry.via, 'public-page');
    assert.equal(all.data.results[2].entry.definitions[0], 'A public-page fixture.');
    assert.equal(all.data.results[3].source, 'iciba');
    assert.equal(all.data.results[3].entry.via, 'public-page');
    assert.ok(all.data.results.filter(result => result.saved).every(result => result.collection === 'tui' && result.id === tuiId));
    assert.equal((await post(server.url, '/api/note', { id: tuiId, collection: 'tui', note: 'Shared web note' })).status, 200);
    assert.equal((await post(server.url, '/api/review', { id: tuiId, collection: 'tui', remembered: true, grade: 3 })).status, 200);
    const checked = spawnSync('luajit', ['-e', luaPrefix + `local w=db:deck_get('hello'); assert(w.mnem=='Shared web note'); assert(w.interval_days==2); assert(db:scalar('SELECT count(*) FROM reviews')==1); assert(db:srs_apply(w.id,0,1000)); assert(db:run('UPDATE words SET mnem=? WHERE id=?',{'Note from TUI',w.id})); db:close()`], { env, encoding: 'utf8' });
    assert.equal(checked.status, 0, checked.stderr);
    words = (await (await fetch(server.url + '/api/words?due=1')).json()).words;
    const shared = words.find(word => word.collection === 'tui');
    assert.equal(shared.note, 'Note from TUI'); assert.equal(shared.review_count, 2); assert.equal(shared.due_at, 1600);
    const web = words.find(word => word.collection === 'web'); assert.equal(web.note, '');
    assert.equal((await post(server.url, '/api/review', { id: web.id, collection: 'web', remembered: true })).status, 200);
    assert.equal((await post(server.url, '/api/review', { id: tuiId, collection: 'tui', remembered: true, grade: 99 })).status, 400);
    await stop(server); server = await start(path.join(directory, 'words.db'), '127.0.0.1', dictionaryPath);
    words = (await (await fetch(server.url + '/api/words')).json()).words;
    assert.equal(words.filter(word => word.word === 'hello').length, 1);
    assert.equal(words.find(word => word.collection === 'tui').review_count, 2);
    assert.equal((await post(server.url, '/api/delete', { id: tuiId, collection: 'tui' })).status, 200);
    words = (await (await fetch(server.url + '/api/words')).json()).words;
    assert.equal(words.filter(word => word.word === 'hello').length, 0);
    assert.equal(words.length, 1); assert.equal(words[0].collection, 'web');
    const preserved = spawnSync('luajit', ['-e', luaPrefix + `assert(not db:deck_get('hello')); assert(#db:dict_lookup('hello')==1); assert(db:scalar('SELECT count(*) FROM reviews')==0); db:close()`], { env, encoding: 'utf8' });
    assert.equal(preserved.status, 0, preserved.stderr);
    assert.equal((await post(server.url, '/api/delete', { id: tuiId, collection: 'tui' })).status, 404);
    assert.equal((await post(server.url, '/api/delete', { id: -1, collection: 'web' })).status, 400);
    assert.equal((await post(server.url, '/api/delete', { id: web.id, collection: 'web' })).status, 200);
    assert.deepEqual((await (await fetch(server.url + '/api/words')).json()).words, []);
    await stop(server); server = await start(path.join(directory, 'words.db'), '127.0.0.1', dictionaryPath);
    assert.deepEqual((await (await fetch(server.url + '/api/words')).json()).words, []);
    await stop(server); server = null;
  } finally {
    if (server && server.child.exitCode === null) await stop(server);
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('both launchers automatically invoke setup and expose manual/disabled setup options', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'wordbook-startup-'));
  const marker = path.join(directory, 'setup-called');
  const stub = `package.preload['download_dict']=function() return {ensure=function(options) local f=assert(io.open(${JSON.stringify(marker)},'w')); f:write(options.db..'\\n'..tostring(options.force or false)); f:close(); local d=require('ffi_dict'); local db=assert(d.Database.open(options.db)); assert(db:dict_replace_word('hello',{{definition='Startup fixture definition.'}})==1); db:close(); return {words=1,senses=1} end} end`;
  let server;
  try {
    const tuiPath = path.join(root, '..', 'ffi_dict.lua');
    const tuiDb = path.join(directory, 'tui.db');
    let result = spawnSync('luajit', ['-e', stub, tuiPath, 'lookup', 'hello', '--db', tuiDb], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr); assert.match(result.stdout, /Startup fixture definition/);
    assert.equal(fs.readFileSync(marker, 'utf8'), tuiDb + '\nfalse');
    result = spawnSync('luajit', ['-e', stub, tuiPath, '--import-dict', '--db', tuiDb], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr); assert.equal(fs.readFileSync(marker, 'utf8'), tuiDb + '\ntrue');
    fs.unlinkSync(marker);
    result = spawnSync('luajit', ['-e', stub, tuiPath, 'stats', '--no-auto-import', '--db', path.join(directory, 'no-auto.db')], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr); assert.equal(fs.existsSync(marker), false);
    result = spawnSync('luajit', ['-e', stub, tuiPath, '--help', '--import-dict'], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr); assert.equal(fs.existsSync(marker), false);
    const sharedDb = path.join(directory, 'web-dictionary.db');
    server = await start(path.join(directory, 'web.db'), '127.0.0.1', sharedDb, [], stub);
    assert.equal(fs.readFileSync(marker, 'utf8'), sharedDb + '\nfalse');
    assert.equal((await post(server.url, '/api/search', { word: 'hello', source: 'local' })).data.saved, true);
    await stop(server); server = null;
    server = await start(path.join(directory, 'web.db'), '127.0.0.1', sharedDb, ['--import-dict'], stub);
    assert.equal(fs.readFileSync(marker, 'utf8'), sharedDb + '\ntrue');
    await stop(server); server = null; fs.unlinkSync(marker);
    server = await start(path.join(directory, 'web.db'), '127.0.0.1', sharedDb, ['--no-auto-import'], stub);
    assert.equal(fs.existsSync(marker), false); await stop(server); server = null;
    result = spawnSync('luajit', [path.join(root, 'app.lua'), '--dict-db', 'none', '--import-dict'], { encoding: 'utf8' });
    assert.notEqual(result.status, 0); assert.match(result.stderr, /requires a local dictionary/);
  } finally {
    if (server && server.child.exitCode === null) await stop(server);
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('LuaJIT bytecode contains no undeclared globals in every new Lua module', () => {
  const allowed = new Set(['require', 'assert', 'error', 'setmetatable', 'tonumber', 'tostring', 'type', 'ipairs', 'pairs', 'pcall', 'xpcall', 'print', 'arg', 'package', 'os', 'io', 'string', 'table', 'math', 'debug']);
  const files = fs.readdirSync(root).filter(file => file.endsWith('.lua')).map(file => path.join(root, file));
  files.push(path.join(root, 'tests', 'test_app.lua'), path.join(root, 'tests', 'test_shared.lua'));
  files.push(path.join(root, '..', 'download_dict.lua'), path.join(root, '..', 'test_download_dict.lua'), path.join(root, '..', 'ffi_dict.lua'));
  for (const file of files) {
    const result = spawnSync('luajit', ['-bl', file], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    const undeclared = [...result.stdout.matchAll(/\bGGET\b[^\n]*;\s*"([^"]+)"/g)].map(match => match[1]).filter(name => !allowed.has(name));
    assert.deepEqual(undeclared, [], path.relative(root, file));
    assert.doesNotMatch(result.stdout, /\bGSET\b/, 'Unexpected global assignment: ' + file);
  }
});
