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
test('attachment manager lists active images, missing references, metadata, history-only use, and maintenance changes', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'leaf-attachments-'));
  const notebook = path.join(directory, 'notebook'); let server;
  try {
    server = await start(directory, ['--data-dir', notebook, '--dict-db', 'none']);
    const id = 'Notes/学习';
    const created = await post(server, '/api/page', { id, content: '# Images', revision: '' });
    const upload = async page => (await (await fetch(server.url + '/api/image?page=' + encodeURIComponent(page), { method: 'POST', body: png })).json());
    const image = await upload(id); assert.equal((await upload(id)).file, image.file);
    let saved = await post(server, '/api/page', { id, content: image.markdown + '\n![missing](学习.attachments/missing.jpg)\n'
      + '`![code](学习.attachments/code.png)`\n\n```\n![code](学习.attachments/fence.png)\n```', revision: created.data.revision });
    const list = async () => {
      const response = await fetch(server.url + '/api/attachments'); assert.equal(response.status, 200);
      return (await response.json()).attachments;
    };
    let rows = await list(); assert.equal(rows.length, 2);
    const found = rows.find(row => row.file === image.file);
    assert.equal(found.page, id); assert.equal(found.bytes, png.length); assert.equal(found.referenced, true);
    assert.equal(rows.find(row => row.file === 'missing.jpg').missing, true);
    saved = await post(server, '/api/page', { id, content: '# No current image', revision: saved.data.revision });
    rows = await list(); assert.equal(rows.length, 1); assert.equal(rows[0].referenced, false);
    assert.ok((await (await fetch(server.url + '/api/history?id=' + encodeURIComponent(id))).json()).versions.length > 0);
    await post(server, '/api/page', { id: 'Other', content: '# Other', revision: '' }); await upload('Other');
    rows = await list(); assert.equal(rows.length, 2); assert.ok(rows.every(row => row.file === image.file));
    const renamed = await post(server, '/api/rename', { id, destination: 'New Folder/图片', revision: saved.data.revision });
    assert.equal(renamed.status, 200);
    rows = await list(); assert.ok(rows.some(row => row.page === 'New Folder/图片'));
    const trashed = await post(server, '/api/trash', { id: 'New Folder/图片', revision: renamed.data.revision });
    assert.equal(trashed.status, 200); assert.equal((await list()).length, 1);
    const trash = (await (await fetch(server.url + '/api/state')).json()).trash;
    assert.equal((await post(server, '/api/restore', { token: trash[0].token })).status, 200);
    assert.equal((await list()).length, 2);
    const folder = path.join(notebook, 'Other.attachments');
    fs.writeFileSync(path.join(folder, 'large.webp'), Buffer.alloc(5 * 1024 * 1024 + 1));
    fs.writeFileSync(path.join(folder, 'manual.gif'), 'GIF89a');
    fs.writeFileSync(path.join(folder, 'ignored.svg'), '<svg/>');
    rows = await list(); assert.equal(rows.length, 4);
    assert.match(rows.find(row => row.file === 'large.webp').error, /5 MiB/);
    assert.equal(rows.find(row => row.file === 'manual.gif').bytes, 6);
    const bad = await fetch(server.url + '/api/attachment?page=Other&file=..%2Foutside.png');
    assert.equal(bad.status, 400);
    const held = folder + '-held'; fs.renameSync(folder, held); fs.writeFileSync(folder, 'not a directory');
    try {
      const failed = await fetch(server.url + '/api/attachments'); assert.equal(failed.status, 400);
      assert.match((await failed.json()).error, /Other.attachments/);
    } finally { fs.unlinkSync(folder); fs.renameSync(held, folder); }
    assert.equal((await list()).length, 4);
  } finally {
    if (server) await stop(server);
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('capture API creates a journal, appends safely and validates request bodies', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'leaf-capture-'));
  let server;
  try {
    server = await start(directory, ['--data-dir', path.join(directory, 'notebook'), '--dict-db', 'none']);
    const note = await post(server, '/api/capture', { date: '2026-10-13', kind: 'note', text: '学习', revision: '' });
    assert.equal(note.status, 200); assert.match(note.data.content, /Tuesday\n\n学习\n$/);
    const payload = { date: '2026-10-13', kind: 'task', text: 'Review due:2026-10-15', revision: note.data.revision };
    const results = await Promise.all([post(server, '/api/capture', payload), post(server, '/api/capture', payload)]);
    assert.deepEqual(results.map(result => result.status).sort(), [200, 409]);
    const saved = await (await fetch(server.url + '/api/page?id=' + encodeURIComponent(note.data.id))).json();
    assert.equal(saved.content.match(/Review/g).length, 1);
    assert.equal((await post(server, '/api/capture', { ...payload, date: '2026-02-30' })).status, 400);
    assert.equal((await post(server, '/api/capture', { ...payload, kind: 'invalid' })).status, 400);
    assert.equal((await post(server, '/api/capture', { ...payload, text: ' ' })).status, 400);
    const large = await post(server, '/api/capture', { date: '2026-10-14', kind: 'note', text: '中'.repeat(4000), revision: '' });
    assert.equal(large.status, 200);
    assert.equal((await post(server, '/api/capture', { ...payload, text: 'x'.repeat(16001) })).status, 400);
    const tasks = (await (await fetch(server.url + '/api/tasks')).json()).tasks;
    assert.equal(tasks.length, 1); assert.equal(tasks[0].due, '2026-10-15');
  } finally {
    if (server) await stop(server);
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
test('task API lists source lines and rejects stale, missing and malformed updates', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'leaf-tasks-'));
  let server;
  try {
    server = await start(directory, ['--data-dir', path.join(directory, 'notebook'), '--dict-db', 'none']);
    const content = '# 学习 #work\r\n- [ ] Same due:2026-10-15\r\n- [ ] Same\r\n```\r\n- [ ] Hidden\r\n```';
    const created = await post(server, '/api/page', { id: 'Projects/学习', content, revision: '' });
    assert.equal(created.status, 200);
    let tasks = (await (await fetch(server.url + '/api/tasks')).json()).tasks;
    assert.equal(tasks.length, 2); assert.equal(tasks[0].line, 2); assert.equal(tasks[0].due, '2026-10-15');
    const changed = await post(server, '/api/task', { id: tasks[1].id, line: 3, done: true, revision: tasks[1].revision });
    assert.equal(changed.status, 200);
    assert.equal(changed.data.content, content.replace('- [ ] Same\r\n', '- [x] Same\r\n'));
    assert.equal((await post(server, '/api/task', { id: tasks[0].id, line: 2, done: true, revision: tasks[0].revision })).status, 409);
    assert.equal((await post(server, '/api/task', { id: tasks[0].id, line: 5, done: true, revision: changed.data.revision })).status, 404);
    assert.equal((await post(server, '/api/task', { id: tasks[0].id, line: '3', done: true, revision: changed.data.revision })).status, 400);
    assert.equal((await post(server, '/api/task', { id: 'Missing', line: 1, done: true, revision: '' })).status, 404);
    tasks = (await (await fetch(server.url + '/api/tasks')).json()).tasks;
    assert.equal(tasks[0].done, false); assert.equal(tasks[1].done, true);
    const history = await (await fetch(server.url + '/api/history?id=' + encodeURIComponent(tasks[0].id))).json();
    assert.equal(history.versions.length, 1);
  } finally {
    if (server) await stop(server);
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
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

test('both launchers print startup phases and identify configuration, file, and dependency failures', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'leaf-startup-'));
  try {
    const config = path.join(directory, 'config.json'); fs.writeFileSync(config, '{broken');
    for (const entry of [path.join(root, 'wiki_web.lua'), path.join(root, 'wiki_web/app.lua')]) {
      const result = spawnSync('luajit', [entry, '--config', config], { cwd: os.tmpdir(), encoding: 'utf8', timeout: 5000 });
      assert.equal(result.status, 1, result.stderr);
      assert.match(result.stdout, /Leaf Wiki: Loading modules/);
      assert.match(result.stdout, /Reading configuration:/);
      assert.match(result.stderr, /Leaf Wiki failed during: Reading configuration:/);
      assert.match(result.stderr, /Recovery help:/);
      assert.match(result.stderr, /--save-config/);
      assert.match(result.stderr, /Minimal JSON example:/);
      const missing = spawnSync('luajit', ['-e', "package.preload.ffi=function() error('Injected missing native dependency') end",
        entry, '--port', '0'], { cwd: os.tmpdir(), encoding: 'utf8', timeout: 5000 });
      assert.equal(missing.status, 1);
      assert.match(missing.stdout, /Loading modules/);
      assert.match(missing.stderr, /Leaf Wiki failed during: Loading modules/);
      assert.match(missing.stderr, /Injected missing native dependency/);
    }
    fs.writeFileSync(config, '{}');
    const notebook = path.join(directory, 'notebook'); fs.mkdirSync(notebook);
    fs.writeFileSync(path.join(notebook, 'Invalid.md'), Buffer.from([255]));
    const result = spawnSync('luajit', [path.join(root, 'wiki_web.lua'), '--config', config,
      '--data-dir', notebook, '--cache-dir', path.join(directory, 'cache'), '--port', '0'], { encoding: 'utf8', timeout: 5000 });
    assert.equal(result.status, 1, result.stderr);
    assert.match(result.stdout, /Indexing 1\/1: Invalid.md/);
    assert.match(result.stderr, /failed during: Indexing 1\/1: Invalid.md/);
    assert.match(result.stderr, /UTF-8/);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});

test('lock and occupied-port failures identify their phase and print errors', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'leaf-startup-lock-'));
  let server;
  try {
    const notebook = path.join(directory, 'notebook');
    server = await start(directory, ['--data-dir', notebook]);
    assert.match(server.logs(), /Acquiring notebook lock/); assert.match(server.logs(), /Indexing 0 pages/);
    const flags = ['--config', path.join(directory, 'config.json'), '--cache-dir', path.join(directory, 'cache')];
    const locked = spawnSync('luajit', [path.join(root, 'wiki_web.lua'), ...flags, '--data-dir', notebook], { encoding: 'utf8', timeout: 5000 });
    assert.equal(locked.status, 1); assert.match(locked.stderr, /failed during: Acquiring notebook lock/);
    assert.match(locked.stderr, /already open/);
    const port = new URL(server.url).port;
    const occupied = spawnSync('luajit', [path.join(root, 'wiki_web/app.lua'), ...flags,
      '--data-dir', path.join(directory, 'other'), '--port', port], { encoding: 'utf8', timeout: 5000 });
    assert.equal(occupied.status, 1);
    assert.match(occupied.stderr, /failed during: Starting HTTP server on 127\.0\.0\.1:/);
    assert.match(occupied.stderr, /Cannot bind port/);
    assert.ok(occupied.stderr.includes('Cannot bind port ' + port + ' on 127.0.0.1'));
    assert.match(occupied.stderr, /socket error \d+/);
    assert.match(occupied.stderr, /--port 0/);
  } finally {
    if (server) await stop(server);
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('missing configuration and dictionaries are visible; only the search index is automatically created', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'leaf-missing-files-'));
  const config = path.join(directory, 'missing-config', 'config.json');
  const dictionary = path.join(directory, 'missing.db');
  const notebook = path.join(directory, 'notebook'); let server;
  try {
    const flags = ['--data-dir', notebook, '--config', config, '--dict-db', dictionary];
    server = await start(directory, flags);
    assert.match(server.logs(), /warning: Configuration not found; using defaults:/);
    assert.match(server.logs(), /warning: Dictionary unavailable:/);
    assert.match(server.logs(), /create the config and its directory automatically:/);
    assert.match(server.logs(), /download_dict\.lua --db \.dict\.db/);
    assert.match(server.logs(), /Linux or WSL/);
    assert.match(server.logs(), /unable to open database file/);
    assert.match(server.logs(), /Creating SQLite search index:/);
    const state = await (await fetch(server.url + '/api/state')).json();
    assert.equal(fs.existsSync(state.index_path), true);
    assert.equal(fs.existsSync(dictionary), false);
    assert.equal(fs.existsSync(path.dirname(config)), false);
    await stop(server); server = undefined;
    fs.writeFileSync(dictionary, 'not a SQLite database');
    server = await start(directory, flags);
    assert.match(server.logs(), /Opening SQLite index:/);
    assert.match(server.logs(), /warning: Dictionary unavailable:/);
    assert.match(server.logs(), /file is not a database/);
    assert.equal(fs.readFileSync(dictionary, 'utf8'), 'not a SQLite database');
    await stop(server); server = undefined;
    server = await start(directory, [...flags, '--dict-db', 'none', '--save-config']);
    assert.match(server.logs(), /Dictionary lookup disabled/);
    assert.equal(fs.existsSync(config), true);
    assert.ok(server.logs().includes('Configuration saved and verified: ' + normalized(config)));
    assert.ok(server.logs().includes('Verifying saved configuration: ' + normalized(config)));
    await stop(server); server = undefined;
    fs.writeFileSync(state.index_path, 'corrupt SQLite index');
    const corrupt = spawnSync('luajit', [path.join(root, 'wiki_web.lua'), '--config', config,
      '--cache-dir', path.join(directory, 'cache'), '--dict-db', 'none', '--port', '0'], { encoding: 'utf8', timeout: 5000 });
    assert.equal(corrupt.status, 1);
    assert.match(corrupt.stderr, /failed during: Opening SQLite index:/);
    assert.match(corrupt.stderr, /file is not a database/);
    assert.match(corrupt.stderr, /Recovery help:/);
    assert.match(corrupt.stderr, /--cache-dir/);
    assert.match(corrupt.stderr, /search index is created automatically/);
  } finally {
    if (server) await stop(server);
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('config save success is printed only after read-back verification', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'leaf-verify-config-'));
  const config = path.join(directory, 'config.json'); let server;
  try {
    const flags = ['--data-dir', path.join(directory, 'notebook'), '--dict-db', 'none', '--save-config'];
    server = await start(directory, flags);
    assert.ok(server.logs().includes('Configuration saved and verified: ' + normalized(config)));
    await stop(server); server = undefined;
    server = await start(directory, flags);
    assert.ok(server.logs().includes('Configuration saved and verified: ' + normalized(config)));
    await stop(server); server = undefined;
    for (const fault of ['write', 'read']) {
      const setup = 'package.path=' + JSON.stringify(normalized(path.join(root, 'wiki_web/?.lua')) + ';')
        + '..package.path; local fs=require("fs"); local original=fs.' + fault + '; fs.' + fault
        + '=function(self,path,...) if path=="config.json" then '
        + (fault === 'write' ? 'error("Injected configuration write failure")'
          : 'return "{\\\"data_dir\\\":\\\"wrong\\\",\\\"dict_db\\\":\\\"none\\\"}"')
        + ' end return original(self,path,...) end';
      const result = spawnSync('luajit', ['-e', setup, path.join(root, 'wiki_web.lua'), ...flags,
        '--config', config, '--cache-dir', path.join(directory, 'cache'), '--port', '0'], { encoding: 'utf8', timeout: 5000 });
      assert.equal(result.status, 1, result.stdout + result.stderr);
      assert.doesNotMatch(result.stdout, /Configuration saved and verified:/);
      assert.match(result.stderr, fault === 'write' ? /configuration write failure/ : /verification failed/);
    }
  } finally {
    if (server) await stop(server);
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('default binding is loopback; LAN access requires an explicit host each launch', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'leaf-bind-'));
  let server;
  const checkBinding = host => {
    assert.match(server.logs(), new RegExp('listening on ' + host.replaceAll('.', '\\.')));
    if (windows) {
      const result = spawnSync('netstat', ['-ano', '-p', 'tcp'], { encoding: 'utf8' });
      assert.equal(result.status, 0, result.stderr);
      const address = (host === '0.0.0.0' ? '[::]' : host) + ':' + new URL(server.url).port;
      assert.ok(result.stdout.split(/\r?\n/).some(line => {
        const columns = line.trim().split(/\s+/);
        return columns[1] === address && columns.at(-1) === String(server.child.pid);
      }), 'Actual listening address must be ' + address);
    }
  };
  try {
    server = await start(directory, ['--data-dir', path.join(directory, 'notebook'), '--save-config']);
    checkBinding('127.0.0.1');
    await stop(server); server = undefined;
    server = await start(directory, ['--host', '0.0.0.0', '--save-config']);
    checkBinding('0.0.0.0');
    for (const hostname of ['127.0.0.1', '::1']) {
      const status = await new Promise((resolve, reject) => {
        const req = http.get({ hostname, port: new URL(server.url).port, path: '/api/state',
          headers: { Host: `nano.local:${new URL(server.url).port}` } }, response => {
          response.resume(); response.on('end', () => resolve(response.statusCode));
        });
        req.on('error', reject);
      });
      assert.equal(status, 200);
    }
    await stop(server); server = undefined;
    server = await start(directory); checkBinding('127.0.0.1');
    await stop(server); server = undefined;
    const invalid = spawnSync('luajit', [path.join(root, 'wiki_web.lua'), '--host', 'invalid',
      '--data-dir', path.join(directory, 'notebook'), '--config', path.join(directory, 'config.json')], { encoding: 'utf8' });
    assert.notEqual(invalid.status, 0); assert.match(invalid.stderr, /Host must be/);
  } finally {
    if (server) await stop(server);
    fs.rmSync(directory, { recursive: true, force: true });
  }
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
    for (const route of ['/', '/app.js', '/markdown.js', '/export.js', '/style.css']) assert.equal((await fetch(server.url + route)).status, 200);
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
    const searchRes = await (await fetch(server.url + '/api/state?q=' + encodeURIComponent('path:Projects External'))).json();
    assert.equal(searchRes.pages.length, 1);
    assert.match(searchRes.pages[0].snippet, /External change/);
    assert.deepEqual(searchRes.terms, ['External']);
    await stop(server); server = await start(directory);
    assert.equal((await (await fetch(server.url + '/api/page?id=Projects%2FPlan')).json()).content, 'External change');
    assert.equal((await (await fetch(server.url + '/api/state')).json()).data_dir, normalized(notebook));
  } finally { if (server) await stop(server); fs.rmSync(directory, { recursive: true, force: true }); }
});
test('all Leaf Wiki Lua modules compile without undeclared globals', () => {
  const allowed = new Set(['arg', 'require', 'assert', 'error', 'setmetatable', 'tonumber', 'tostring', 'type', 'ipairs', 'pairs', 'pcall', 'print', 'package', 'os', 'io', 'string', 'table', 'math', 'coroutine', 'debug', 'xpcall']);
  const files = ['wiki_web.lua', ...fs.readdirSync(path.join(root, 'wiki_web')).filter(p => p.endsWith('.lua')).map(p => 'wiki_web/' + p), 'wiki_web/tests/test_notebook.lua', 'wiki_web/tests/test_dictionary.lua', 'wiki_web/tests/test_console_windows.lua', 'dictionary_web/db.lua', 'dictionary_web/http.lua', 'dictionary_web/http_windows.lua'];
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

test('dictionary lookup uses a read-only database, validates words and persists configuration', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'leaf-dictionary-'));
  const dictionary = path.join(directory, '词典.db');
  let server;
  try {
    const fixture = spawnSync('luajit', [path.join(root, 'wiki_web/tests/test_dictionary.lua'), directory], { encoding: 'utf8' });
    assert.equal(fixture.status, 0, fixture.stdout + fixture.stderr);
    const original = fs.readFileSync(dictionary);
    server = await start(directory, ['--data-dir', path.join(directory, 'notebook'), '--dict-db', dictionary, '--save-config']);
    let response = await fetch(server.url + '/api/dictionary?word=%20EPHEMERAL%20');
    assert.equal(response.status, 200);
    const result = await response.json();
    assert.equal(result.source, 'local'); assert.equal(result.senses.length, 2);
    assert.equal(result.senses[0].syn, 'temporary'); assert.equal(result.senses[0].ant, 'lasting');
    response = await fetch(server.url + '/api/dictionary?word=' + encodeURIComponent('学习'));
    assert.equal((await response.json()).senses[0].definition, 'Study and learn.');
    response = await fetch(server.url + '/api/dictionary?word=' + encodeURIComponent("' OR 1=1 --"));
    assert.deepEqual((await response.json()).senses, []);
    for (const word of ['', '\0', '\n', 'x'.repeat(241)]) {
      assert.equal((await fetch(server.url + '/api/dictionary?word=' + encodeURIComponent(word))).status, 400);
    }
    assert.equal((await fetch(server.url + '/api/dictionary')).status, 400);
    assert.equal((await post(server, '/api/dictionary', { word: 'ephemeral' })).status, 404);
    assert.equal((await post(server, '/api/page', { id: 'Study', content: 'ephemeral', revision: '' })).status, 200);
    assert.equal(JSON.parse(fs.readFileSync(path.join(directory, 'config.json'))).dict_db, normalized(dictionary));
    await stop(server); server = undefined;
    server = await start(directory);
    assert.equal((await (await fetch(server.url + '/api/dictionary?word=ephemeral')).json()).senses.length, 2);
    assert.deepEqual(fs.readFileSync(dictionary), original);
    await stop(server); server = undefined;
    const missing = path.join(directory, 'missing.db');
    server = await start(directory, ['--dict-db', missing]);
    response = await fetch(server.url + '/api/dictionary?word=ephemeral');
    assert.equal(response.status, 503); assert.match((await response.json()).error, /--dict-db/);
    assert.equal(fs.existsSync(missing), false);
    assert.equal((await fetch(server.url + '/api/state')).status, 200);
    await stop(server); server = undefined;
    server = await start(directory, ['--dict-db', 'none']);
    assert.equal((await fetch(server.url + '/api/dictionary?word=ephemeral')).status, 503);
  } finally {
    if (server) await stop(server);
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('history API previews, restores with revision checks and survives restart with a new cache', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'leaf-history-'));
  const notebook = path.join(directory, 'notebook'); let server;
  try {
    server = await start(directory, ['--data-dir', notebook, '--save-config']);
    const first = (await post(server, '/api/page', { id: '学习/Note', content: '<script>First</script>', revision: '' })).data;
    const second = (await post(server, '/api/page', { id: first.id, content: 'Second', revision: first.revision })).data;
    let history = await (await fetch(server.url + '/api/history?id=' + encodeURIComponent(first.id))).json();
    assert.equal(history.versions.length, 1); assert.equal(history.versions[0].revision, first.revision);
    const version = await (await fetch(server.url + '/api/version?' + new URLSearchParams({ id: first.id, revision: first.revision }))).json();
    assert.equal(version.content, first.content);
    assert.equal((await post(server, '/api/history/restore', { id: first.id, selected: first.revision, revision: 'stale' })).status, 409);
    assert.equal((await fetch(server.url + '/api/version?' + new URLSearchParams({ id: first.id, revision: '../escape' }))).status, 400);
    assert.equal((await fetch(server.url + '/api/version?' + new URLSearchParams({ id: first.id, revision: '0'.repeat(64) }))).status, 404);
    const restored = await post(server, '/api/history/restore', { id: first.id, selected: first.revision, revision: second.revision });
    assert.equal(restored.status, 200); assert.equal(restored.data.content, first.content);
    await stop(server); server = undefined;
    server = await start(directory, ['--cache-dir', path.join(directory, 'fresh-cache')]);
    history = await (await fetch(server.url + '/api/history?id=' + encodeURIComponent(first.id))).json();
    assert.equal(history.versions.length, 2);
    assert.equal((await post(server, '/api/history/restore', { id: first.id, selected: second.revision, revision: first.revision })).data.content, 'Second');
    fs.writeFileSync(path.join(notebook, '学习', 'Note.md'), 'External');
    assert.equal((await post(server, '/api/history/restore', { id: first.id, selected: first.revision, revision: second.revision })).status, 409);
    assert.equal(fs.readFileSync(path.join(notebook, '学习', 'Note.md'), 'utf8'), 'External');
  } finally {
    if (server) await stop(server);
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('Windows path options normalize environment variables, separators and dot segments without creating unused paths',
  { skip: !windows }, async () => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'leaf-normal-path-'));
    let server;
    const env = { LEAF_WIKI_TEST_PATH_ROOT: directory };
    const notebook = normalized(path.join(directory, '笔记')); const config = normalized(path.join(directory, '配置', 'config.json'));
    try {
      server = await start(directory, ['--data-dir', '%LEAF_WIKI_TEST_PATH_ROOT%\\unused\\..\\笔记\\.',
        '--config', '%LEAF_WIKI_TEST_PATH_ROOT%/配置/./config.json',
        '--cache-dir', '%LEAF_WIKI_TEST_PATH_ROOT%\\缓存\\.',
        '--dict-db', '%LEAF_WIKI_TEST_PATH_ROOT%/dictionary/../missing.db', '--save-config'],
        path.join(root, 'wiki_web.lua'), os.tmpdir(), env);
      const saved = JSON.parse(fs.readFileSync(config, 'utf8'));
      assert.equal(saved.data_dir, notebook); assert.equal(saved.dict_db, normalized(path.join(directory, 'missing.db')));
      assert.ok(server.logs().includes('Configuration saved and verified: ' + config));
      assert.equal(fs.existsSync(path.join(directory, 'unused')), false);
      assert.equal(fs.existsSync(path.join(directory, 'dictionary')), false);
      assert.equal(fs.existsSync(path.join(directory, 'missing.db')), false);
      assert.equal((await fetch(server.url + '/api/state')).status, 200);
      await stop(server); server = undefined;
      server = await start(directory, ['--config', config.replaceAll('/', '\\')], path.join(root, 'wiki_web.lua'), os.tmpdir(), env);
      assert.equal((await (await fetch(server.url + '/api/state')).json()).data_dir, notebook);
    } finally {
      if (server) await stop(server);
      fs.rmSync(directory, { recursive: true, force: true });
    }
  });

test('Content-Security-Policy header allows bible-api.com for verse fetching and enforces self origins', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'leaf-csp-'));
  let server;
  try {
    server = await start(directory, ['--data-dir', path.join(directory, 'notebook'), '--dict-db', 'none']);
    const response = await fetch(server.url + '/');
    assert.equal(response.status, 200);
    const csp = response.headers.get('content-security-policy');
    assert.ok(csp, 'Content-Security-Policy header must be present');
    assert.match(csp, /default-src 'self'/);
    assert.match(csp, /connect-src 'self' https:\/\/bible-api\.com/);
  } finally {
    if (server) await stop(server);
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

