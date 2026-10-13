// Real Windows launcher and HTTP requests; fixture only external provider traffic.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawn, spawnSync } = require('node:child_process');
const { once } = require('node:events');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
test('Windows daily content and provider requests avoid POSIX workers', { skip: process.platform !== 'win32' }, async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dict-windows-'));
    const setup = `package.path=${JSON.stringify(root.replaceAll('\\', '/') + '/?.lua;')}..package.path;
        package.preload.workers=function() error('Windows must not load POSIX workers') end;
        require('net').fetch=function() return nil,'Fixture offline' end;
        require('providers').lookup=function(source,word)
            if word=='fail' then error('Fixture failure') end
            return {definitions={'Windows fixture definition'},examples={}}
        end`;
    const child = spawn('luajit', ['-e', setup, path.join(root, 'app.lua'), '--port', '0', '--db',
        path.join(dir, 'words.db'), '--dict-db', 'none', '--no-auto-import']);
    let logs = '';
    child.stderr.on('data', b => { logs += b; });
    try {
        const url = await new Promise((resolve, reject) => {
            const timer = setTimeout(() => reject(new Error('Startup timed out: ' + logs)), 5000);
            child.on('error', e => { clearTimeout(timer); reject(e); });
            child.on('exit', code => { clearTimeout(timer); reject(new Error('Exited ' + code + ': ' + logs)); });
            child.stdout.on('data', b => {
                logs += b;
                const match = logs.match(/Wordbook: (http:\/\/127\.0\.0\.1:\d+)/);
                if (match) { clearTimeout(timer); resolve(match[1]); }
            });
        });
        assert.match(logs, /Windows: provider requests run inline/);
        assert.match(logs, /Listening: 127\.0\.0\.1:/);
        const daily = await fetch(url + '/api/daily');
        assert.equal(daily.status, 200); assert.ok((await daily.json()).word);
        for (const [word, source] of [['hello', 'iciba'], ['fail', 'iciba'], ['hello', 'local']]) {
            const response = await fetch(url + '/api/search', { method: 'POST',
                headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ word, source }) });
            assert.equal(response.status, 200);
            const value = await response.json();
            if (word === 'hello' && source === 'iciba') assert.equal(value.saved, true);
            else assert.ok(value.error);
        }
        const stats = await fetch(url + '/api/stats');
        assert.equal(stats.status, 200); await stats.json();
        assert.doesNotMatch(logs, /cannot resolve symbol|Request failed|POSIX workers/);
    } finally {
        if (child.exitCode === null && child.signalCode === null) {
            const exited = once(child, 'exit'); child.kill(); await exited;
        }
        fs.rmSync(dir, { recursive: true, force: true });
    }
});
