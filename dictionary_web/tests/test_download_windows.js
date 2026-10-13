// Windows downloader uses native directories and real Git without a command shell.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '../..').replaceAll('\\', '/');
const lua = value => JSON.stringify(value.replaceAll('\\', '/'));
test('Windows import handles directory creation and Git paths, output and failures', { skip: process.platform !== 'win32' }, () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dict-download-'));
    const repo = path.join(dir, 'source repo');
    const git = args => {
        const r = spawnSync('git', args, { encoding: 'utf8' });
        assert.equal(r.status, 0, r.stdout + r.stderr);
    };
    try {
        git(['init', '--initial-branch=master', repo]);
        fs.mkdirSync(path.join(repo, 'data'));
        fs.writeFileSync(path.join(repo, 'data', 'a.json'), JSON.stringify({ hello: { meanings: [{ def: 'A greeting.' }] } }));
        git(['-C', repo, 'add', '.']);
        git(['-C', repo, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-m', 'Fixture']);
        const cache = path.join(dir, "download 选择 & ' 100%", 'checkout');
        const db = path.join(dir, 'dictionary.db');
        const echo = path.join(dir, 'echo.lua');
        fs.writeFileSync(echo, `package.path=${lua(root + '/?.lua;' + root + '/wiki_web/?.lua;')}..package.path
            require('windows_args').normalize(); print('ARGS:'..require('json').encode({arg[1],arg[2]}))
            io.stderr:write('Child stderr visible\\n')`);
        const literal = `quotes " ' & ; $(touch injected) \`touch injected\` %PATH% 选择`;
        const argumentScript = path.join(dir, 'arguments.lua');
        fs.writeFileSync(argumentScript, `package.path=${lua(root + '/?.lua;')}..package.path
            require('windows_process').run({'luajit',${lua(echo)},${JSON.stringify(literal)},'ends\\\\'})`);
        const echoed = spawnSync('luajit', [argumentScript], { encoding: 'utf8', timeout: 10000 });
        assert.equal(echoed.status, 0, echoed.stderr);
        const argumentsOut = JSON.parse(echoed.stdout.match(/ARGS:(.+)/)[1]);
        assert.equal(argumentsOut[0], literal); assert.equal(argumentsOut[1], 'ends\\');
        assert.match(echoed.stderr, /Child stderr visible/);
        const script = path.join(dir, 'import.lua');
        fs.writeFileSync(script, `package.path=${lua(root + '/?.lua;')}..package.path
            local setup=require('download_dict')
            local options={db=${lua(db)},cache_dir=${lua(cache)},files={'a.json'},run=function(argv)
                for i,value in ipairs(argv) do if value=='https://github.com/wordset/wordset-dictionary.git' then argv[i]=${lua(repo)} end end
                setup.run(argv)
            end}
            local result=setup.ensure(options); assert(result.words==1 and result.senses==1)
            assert(setup.ensure(options).skipped)
            options.force=true; assert(setup.ensure(options).words==1)
            local dictionary=require('ffi_dict'); local db=assert(dictionary.Database.open(options.db))
            assert(#db:dict_search('greeting')==1); db:close()
            local ok,err=pcall(setup.run,{'missing_dictionary_executable_12345'})
            assert(not ok and err:find('Cannot start',1,true)); print('Verified missing executable error')
            ok,err=pcall(setup.run,{'git','-C',${lua(repo)},'invalid-command'})
            assert(not ok and err:find('failed (status',1,true)); print('Verified failed command status')
        `);
        const result = spawnSync('luajit', [script], { encoding: 'utf8', timeout: 30000 });
        assert.equal(result.status, 0, result.stdout + result.stderr);
        assert.match(result.stdout, /Creating download directory:/);
        assert.match(result.stdout, /Ready: 1 words/);
        assert.match(result.stdout, /Verified missing executable error/);
        assert.match(result.stdout, /Verified failed command status/);
        assert.match(result.stderr, /Cloning into/);
        assert.match(result.stderr, /invalid-command/);
        assert.ok(fs.existsSync(path.join(cache, '.git', 'config')));
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
