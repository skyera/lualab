// Real launcher and filesystem checks; notebooks and caches are temporary.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawn, spawnSync } = require('node:child_process');
const http = require('node:http');
const { once } = require('node:events');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const root = path.resolve(__dirname, '../..');
const windows = process.platform === 'win32';
const normalized = value => value.replace(/\\/g, '/');
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1ioAAAAASUVORK5CYII=', 'base64');
async function start(directory, flags = [], entry = path.join(root, 'wiki_web.lua'), cwd = os.tmpdir(), env = {}, explicitLocations = true) {
  const locations = explicitLocations ? ['--cache-dir', path.join(directory, 'cache'),
    '--config', path.join(directory, 'config.json')] : [];
  const environment = { ...process.env, ...env };
  if (!Object.hasOwn(env, 'LEAF_WIKI_DATA_DIR')) delete environment.LEAF_WIKI_DATA_DIR;
  const child = spawn('luajit', [entry, '--port', '0', ...locations, ...flags],
    { cwd, env: environment });
  let output = '';
  child.stderr.on('data', data => { output += data; });
  const url = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => { child.kill(); reject(new Error('Startup timed out: ' + output)); }, 5000);
    child.on('exit', code => { clearTimeout(timer); reject(new Error('Server exited ' + code + ': ' + output)); });
    child.on('error', reject);
    child.stdout.on('data', data => {
      output += data; const match = output.match(/Leaf Wiki: (http:\/\/127\.0\.0\.1:\d+)/);
      if (match) { clearTimeout(timer); resolve(match[1]); }
    });
  });
  return { child, url, logs: () => output };
}
async function stop(server) {
  const exit = once(server.child, 'exit'); server.child.kill('SIGTERM');
  // Node terminates Windows processes forcibly; console Ctrl-C has a separate test.
  assert.deepEqual(await exit, windows ? [null, 'SIGTERM'] : [0, null], server.logs());
}
async function post(server, route, data) {
  const response = await fetch(server.url + route, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) });
  return { status: response.status, data: await response.json() };
}
function getWithHeaders(url, headers) {
  const target = new URL(url);
  return new Promise((resolve, reject) => {
    const request = http.request({ hostname: '127.0.0.1', port: target.port, path: '/api/state', headers }, response => {
      response.resume(); response.on('end', () => resolve(response.statusCode));
    });
    request.on('error', reject); request.end();
  });
}
test('app.lua can launch directly from the wiki_web directory', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'leaf-direct-'));
  let server;
  try {
    server = await start(directory, ['--data-dir', path.join(directory, 'notebook')],
      path.join(root, 'wiki_web', 'app.lua'), path.join(root, 'wiki_web'));
    const response = await fetch(server.url + '/');
    assert.equal(response.status, 200);
    assert.match(await response.text(), /Leaf Wiki/);
    assert.match(await (await fetch(server.url + '/')).text(), /Journal calendar/);
  } finally {
    if (server) await stop(server);
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
test('app.lua -h prints usage and exits successfully', () => {
  const result = spawnSync('luajit', ['app.lua', '-h'], {
    cwd: path.join(root, 'wiki_web'), encoding: 'utf8'
  });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /^Usage: luajit wiki_web\.lua /);
  assert.equal(result.stderr, '');
});
test('default notebook folder has no spaces in its name', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'leaf-default-'));
  let server;
  try {
    server = await start(directory, [], path.join(root, 'wiki_web.lua'), os.tmpdir(),
      { HOME: directory, USERPROFILE: directory });
    const state = await (await fetch(server.url + '/api/state')).json();
    assert.equal(state.data_dir, normalized(path.join(directory, 'LeafWiki')));
    assert.ok(!path.basename(state.data_dir).includes(' '));
  } finally {
    if (server) await stop(server);
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
test('configured folder, autosave conflicts, images, links, maintenance and clean restart', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'leaf-http-'));
  const notebook = path.join(directory, 'Google Drive', 'My notebook');
  let server;
  try {
    server = await start(directory, ['--data-dir', notebook, '--save-config']);
    assert.equal(JSON.parse(fs.readFileSync(path.join(directory, 'config.json'))).data_dir, normalized(notebook));
    for (const route of ['/', '/app.js', '/markdown.js', '/style.css']) assert.equal((await fetch(server.url + route)).status, 200);
    const state = await (await fetch(server.url + '/api/state')).json();
    assert.deepEqual(state.pages, []); assert.equal(state.data_dir, normalized(notebook));
    assert.ok(!state.index_path.startsWith(normalized(notebook)));
    let page = (await post(server, '/api/page', { id: 'Projects/Design', content: '# Design\n[[Home]]', revision: '' })).data;
    const long = 'Long page. '.repeat(3000);
    page = (await post(server, '/api/page', { id: page.id, content: page.content + '\n' + long, revision: page.revision })).data;
    assert.ok(page.content.length > 8192);
    assert.equal((await post(server, '/api/page', { id: page.id, content: 'Stale', revision: 'wrong' })).status, 409);
    await post(server, '/api/page', { id: 'Home', content: '[[Projects:Design|Design]]', revision: '' });
    const loaded = await (await fetch(server.url + '/api/page?id=' + encodeURIComponent(page.id))).json();
    assert.equal(loaded.backlinks[0].id, 'Home');
    const upload = await fetch(server.url + '/api/image?page=' + encodeURIComponent(page.id), { method: 'POST', headers: { 'Content-Type': 'image/png' }, body: png });
    assert.equal(upload.status, 200); const image = await upload.json();
    const attachment = await fetch(server.url + '/api/attachment?' + new URLSearchParams({ page: page.id, file: image.file }));
    assert.equal(attachment.headers.get('content-type'), 'image/png');
    assert.deepEqual(Buffer.from(await attachment.arrayBuffer()), png);
    page = (await post(server, '/api/page', { id: page.id, content: page.content + '\n' + image.markdown, revision: page.revision })).data;
    const renamed = await post(server, '/api/rename', { id: page.id, destination: 'Projects/Plan', revision: page.revision });
    assert.equal(renamed.status, 200); page = renamed.data;
    assert.ok(fs.existsSync(path.join(notebook, 'Projects', 'Plan.attachments', image.file)));
    assert.match(fs.readFileSync(path.join(notebook, 'Home.md'), 'utf8'), /Projects:Plan/);
    assert.equal((await post(server, '/api/trash', { id: page.id, revision: page.revision })).status, 200);
    const trashed = await (await fetch(server.url + '/api/state')).json();
    assert.equal(trashed.trash.length, 1);
    assert.equal((await post(server, '/api/restore', { token: trashed.trash[0].token })).status, 200);
    const response = await fetch(server.url + '/api/state', { headers: { Host: 'evil.invalid', Origin: 'https://evil.invalid' } });
    assert.equal(response.status, 403);
    const lanHost = `192.168.1.50:${new URL(server.url).port}`;
    assert.equal(await getWithHeaders(server.url, { Host: lanHost, Origin: `http://${lanHost}` }), 200);
    const namedHost = `wiki-pc.local:${new URL(server.url).port}`;
    assert.equal(await getWithHeaders(server.url, { Host: namedHost, Origin: `http://${namedHost}` }), 200);
    assert.equal(await getWithHeaders(server.url, { Host: namedHost, Origin: 'https://attacker.example' }), 403);
    assert.equal(await getWithHeaders(server.url, { Host: lanHost, Origin: 'https://attacker.example' }), 403);
    assert.equal(await getWithHeaders(server.url, { Host: `999.1.1.1:${new URL(server.url).port}` }), 403);
    assert.equal((await post(server, '/api/page', { id: '../Escape', content: 'unsafe', revision: '' })).status, 400);
    assert.equal((await fetch(server.url + '/api/page', { method: 'POST', headers: { 'Content-Type': 'application/json-invalid' }, body: '{}' })).status, 415);
    assert.equal((await fetch(server.url + '/api/page', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{broken' })).status, 400);
    assert.equal((await fetch(server.url + '/api/image?page=Home', { method: 'POST', body: '<svg/>' })).status, 400);
    fs.writeFileSync(path.join(notebook, 'Projects', 'Plan.md'), 'External change');
    assert.equal((await post(server, '/api/page', { id: page.id, content: 'Overwrite', revision: page.revision })).status, 409);
    assert.equal((await (await fetch(server.url + '/api/state?q=External')).json()).pages.length, 1);
    await stop(server); server = await start(directory);
    assert.equal((await (await fetch(server.url + '/api/page?id=Projects%2FPlan')).json()).content, 'External change');
    assert.equal((await (await fetch(server.url + '/api/state')).json()).data_dir, normalized(notebook));
  } finally { if (server) await stop(server); fs.rmSync(directory, { recursive: true, force: true }); }
});
test('all Leaf Wiki Lua modules compile without undeclared globals', () => {
  const allowed = new Set(['arg', 'require', 'assert', 'error', 'setmetatable', 'tonumber', 'tostring', 'type', 'ipairs', 'pairs', 'pcall', 'print', 'package', 'os', 'io', 'string', 'table', 'math', 'coroutine', 'debug', 'xpcall']);
  const files = ['wiki_web.lua', ...fs.readdirSync(path.join(root, 'wiki_web')).filter(p => p.endsWith('.lua')).map(p => 'wiki_web/' + p), 'wiki_web/tests/test_notebook.lua', 'wiki_web/tests/test_console_windows.lua', 'dictionary_web/db.lua', 'dictionary_web/http.lua', 'dictionary_web/http_windows.lua'];
  for (const file of files) {
    const result = spawnSync('luajit', ['-bl', path.join(root, file)], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    const undeclared = [...result.stdout.matchAll(/\bGGET\b[^\n]*;\s*"([^"]+)"/g)].map(m => m[1]).filter(p => !allowed.has(p));
    assert.deepEqual(undeclared, [], file); assert.doesNotMatch(result.stdout, /\bGSET\b/, file);
  }
});

test('notebook unit tests run with managed temporary folders', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'leaf-units-'));
  try {
    const result = spawnSync('luajit', [path.join(root, 'wiki_web/tests/test_notebook.lua'), directory],
      { cwd: os.tmpdir(), encoding: 'utf8' });
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.match(result.stdout, /Passed \d+ notebook tests/);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});

test('Windows console Ctrl-C closes the server and restores console mode', { skip: !windows }, () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'leaf-console-'));
  try {
    const result = spawnSync('luajit', [path.join(root, 'wiki_web/tests/test_console_windows.lua'), directory],
      { encoding: 'utf8', windowsHide: true, timeout: 10000 });
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.match(result.stdout, /Console Ctrl-C restored input mode and released notebook lock/);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});

test('Unicode folders/configuration, lock contention and junction confinement', { skip: !windows }, async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'leaf-windows-'));
  const notebook = path.join(directory, '笔记');
  const config = path.join(directory, '配置', 'config.json');
  const outside = path.join(directory, 'outside');
  let server;
  try {
    fs.mkdirSync(path.dirname(config)); fs.mkdirSync(outside);
    fs.writeFileSync(path.join(outside, 'Secret.md'), 'outside');
    server = await start(directory, ['--data-dir', notebook, '--config', config, '--save-config']);
    let page = await post(server, '/api/page', { id: '学习/日志', content: '你好', revision: '' });
    assert.equal(page.status, 200); assert.equal(page.data.content, '你好');
    const locked = spawnSync('luajit', [path.join(root, 'wiki_web.lua'), '--data-dir', notebook,
      '--cache-dir', path.join(directory, 'cache'), '--config', config], { encoding: 'utf8' });
    assert.notEqual(locked.status, 0); assert.match(locked.stderr, /already open/);
    fs.symlinkSync(outside, path.join(notebook, 'Linked'), 'junction');
    assert.equal((await post(server, '/api/page', { id: 'Linked/Secret', content: 'overwrite', revision: '' })).status, 400);
    assert.equal((await fetch(server.url + '/api/page?id=Linked%2FSecret')).status, 400);
    assert.equal(fs.readFileSync(path.join(outside, 'Secret.md'), 'utf8'), 'outside');
    const state = await (await fetch(server.url + '/api/state')).json();
    assert.deepEqual(state.pages.map(p => p.id), ['学习/日志']);
    await stop(server); server = undefined;
    server = await start(directory, ['--config', config]);
    assert.equal((await (await fetch(server.url + '/api/state')).json()).data_dir, normalized(notebook));
  } finally {
    if (server) await stop(server);
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('idle clients do not block requests; malformed and oversized requests are rejected', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'leaf-sockets-'));
  let server, idle;
  const sockets = [];
  try {
    server = await start(directory, ['--data-dir', path.join(directory, 'notebook')]);
    const port = Number(new URL(server.url).port);
    idle = net.connect(port, '127.0.0.1'); await once(idle, 'connect');
    idle.write('GET /api/state HTTP/1.1\r\n');
    assert.equal((await fetch(server.url + '/api/state')).status, 200);
    const raw = async frame => {
      const socket = net.connect(port, '127.0.0.1'); sockets.push(socket);
      let data = ''; socket.on('data', bytes => { data += bytes; });
      const closed = once(socket, 'close');
      await once(socket, 'connect'); socket.write(frame); await closed; return data;
    };
    const host = 'Host: 127.0.0.1:' + port + '\r\n';
    assert.match(await raw('POST /api/image HTTP/1.1\r\n' + host + 'Content-Length: 5242881\r\n\r\n'), /^HTTP\/1.1 413/);
    assert.match(await raw('GET /api/state HTTP/1.1\r\n' + host + host + '\r\n'), /^HTTP\/1.1 400/);
    assert.match(await raw('POST /api/page HTTP/1.1\r\n' + host + 'Transfer-Encoding: chunked\r\n\r\n'), /^HTTP\/1.1 400/);
  } finally {
    if (idle) idle.destroy(); sockets.forEach(socket => socket.destroy());
    if (server) await stop(server);
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('Windows defaults and environment overrides use Unicode user folders', { skip: !windows }, async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'leaf-defaults-'));
  const home = path.join(directory, '用户');
  const roaming = path.join(directory, '配置');
  const local = path.join(directory, '缓存');
  const env = { USERPROFILE: home, APPDATA: roaming, LOCALAPPDATA: local };
  let server;
  try {
    server = await start(directory, ['--save-config'], path.join(root, 'wiki_web.lua'), os.tmpdir(), env, false);
    let state = await (await fetch(server.url + '/api/state')).json();
    assert.equal(state.data_dir, normalized(path.join(home, 'LeafWiki')));
    assert.ok(state.index_path.startsWith(normalized(path.join(local, 'leaf-wiki')) + '/'));
    const config = path.join(roaming, 'leaf-wiki', 'config.json');
    assert.equal(JSON.parse(fs.readFileSync(config, 'utf8')).data_dir, state.data_dir);
    await stop(server); server = undefined;
    const override = path.join(directory, '环境笔记');
    server = await start(directory, [], path.join(root, 'wiki_web.lua'), os.tmpdir(),
      { ...env, LEAF_WIKI_DATA_DIR: override }, false);
    state = await (await fetch(server.url + '/api/state')).json();
    assert.equal(state.data_dir, normalized(override));
  } finally {
    if (server) await stop(server);
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
