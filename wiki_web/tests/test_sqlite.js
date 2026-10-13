const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
test('SQLite DLL selection validates and preserves configuration', { skip: process.platform !== 'win32' }, () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'leaf-sqlite-选择-'));
    const config = path.join(dir, 'settings', 'config.json');
    const run = (flags, input) => spawnSync('luajit', [path.join(root, 'wiki_web.lua'), '--config', config, ...flags],
        { cwd: dir, encoding: 'utf8', input, timeout: 10000, env: { ...process.env, LEAF_WIKI_SQLITE3: '', PATH: dir + ';' + process.env.PATH } });
    try {
        let result = run(['--sqlite-list']);
        assert.equal(result.status, 0, result.stderr);
        const found = result.stdout.match(/\d+\. (.+sqlite3(?:-3)?\.dll) \[/);
        assert.ok(found, result.stdout);
        const dll = path.join(dir, 'sqlite3.dll'); fs.copyFileSync(found[1], dll);
        fs.mkdirSync(path.dirname(config));
        const existing = { data_dir: 'C:/Notes', dict_db: 'none', custom: { value: 42 }, sqlite_dll: 'missing.dll' };
        fs.writeFileSync(config, JSON.stringify(existing));
        result = run(['--sqlite-list']);
        const line = result.stdout.split('\n').find(line => line.includes(dir.replaceAll('\\', '/') + '/sqlite3.dll ['));
        assert.ok(line, result.stdout);
        result = run(['--sqlite-select'], line.match(/^(\d+)\./)[1] + '\n');
        assert.equal(result.status, 0, result.stdout + result.stderr);
        assert.match(result.stdout, /Configuration saved and verified:/);
        assert.doesNotMatch(result.stdout, /Leaf Wiki: http/);
        const saved = JSON.parse(fs.readFileSync(config));
        assert.deepEqual(saved, { ...existing, sqlite_dll: dll.replaceAll('\\', '/') });
        result = run(['--sqlite-select'], '99999\n');
        assert.equal(result.status, 1); assert.match(result.stderr, /Invalid SQLite selection/);
        assert.deepEqual(JSON.parse(fs.readFileSync(config)), saved);
        for (const [file, pattern] of [[path.join(dir, 'missing.dll'), /missing or unreadable/],
            [path.join(process.env.SystemRoot, 'System32', 'kernel32.dll'), /missing sqlite3_open/]]) {
            result = run(['--sqlite-select', '--sqlite-dll', file]);
            assert.equal(result.status, 1); assert.match(result.stderr, pattern);
            assert.deepEqual(JSON.parse(fs.readFileSync(config)), saved);
        }
        const invalid = Buffer.alloc(256); invalid.write('MZ'); invalid.writeUInt32LE(128, 60);
        invalid.write('PE\0\0', 128); invalid.writeUInt16LE(0x14c, 132);
        const bad = path.join(dir, 'wrong.dll'); fs.writeFileSync(bad, invalid);
        result = run(['--sqlite-select', '--sqlite-dll', bad]);
        assert.equal(result.status, 1); assert.match(result.stderr, /Architecture does not match/);
        fs.unlinkSync(config); fs.rmdirSync(path.dirname(config));
        result = run(['--sqlite-select', '--sqlite-dll', dll]);
        assert.equal(result.status, 0, result.stderr);
        assert.equal(JSON.parse(fs.readFileSync(config)).sqlite_dll, dll.replaceAll('\\', '/'));
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
