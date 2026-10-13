// Native Windows PAC resolution plus libcurl request option regression coverage.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { spawn, spawnSync } = require('node:child_process');
const { once } = require('node:events');
const path = require('node:path');
const root = path.resolve(__dirname, '..').replaceAll('\\', '/');
const setup = `package.path=${JSON.stringify(root + '/?.lua;' + root + '/../wiki_web/?.lua;')}..package.path;`;
test('Windows resolves a real local PAC per URL and handles static bypass/failures', { skip: process.platform !== 'win32' }, async () => {
    const server = http.createServer((request, response) => {
        response.setHeader('Content-Type', 'application/x-ns-proxy-autoconfig');
        response.end('function FindProxyForURL(url, host) { return host == "proxied.example" ? "PROXY 127.0.0.1:18080" : "DIRECT"; }');
    });
    server.listen(0, '127.0.0.1'); await once(server, 'listening');
    const pac = 'http://127.0.0.1:' + server.address().port + '/proxy.pac';
    const script = setup + `local proxy=require('windows_proxy')
        local settings={auto_url=${JSON.stringify(pac)}}
        local route,source=proxy.resolve('https://proxied.example/word',settings)
        assert(route=='127.0.0.1:18080' and source=='Windows PAC',tostring(route))
        assert(proxy.resolve('https://direct.example/word',settings)=='')
        assert(proxy.select_proxy('http=first:80;https=secure:81','https')=='secure:81')
        assert(proxy.resolve('https://example.invalid/',{proxy='http=first:80;https=secure:81'})=='secure:81')
        assert(proxy.resolve('https://intranet/',{proxy='secure:81',bypass='<local>;*.internal'})=='')
        assert(proxy.resolve('https://host.internal/',{proxy='secure:81',bypass='*.internal'})=='')
        local ok,err=pcall(proxy.resolve,'https://example.invalid/',{auto_url='http://127.0.0.1:1/unavailable.pac'})
        assert(not ok and err:find('PAC resolution failed',1,true))
        local route,source,warning=proxy.resolve('https://example.invalid/',{auto_url='http://127.0.0.1:1/unavailable.pac',proxy='secure:81'})
        assert(route=='secure:81' and warning:find('using static settings',1,true))
        print('Native PAC, direct, bypass and failure paths verified')`;
    const child = spawn('luajit', ['-e', script]);
    let output = '';
    child.stdout.on('data', b => { output += b; }); child.stderr.on('data', b => { output += b; });
    const timer = setTimeout(() => child.kill(), 30000);
    try {
        const [code] = await once(child, 'exit'); assert.equal(code, 0, output);
        assert.match(output, /Native PAC, direct, bypass and failure paths verified/);
    } finally { clearTimeout(timer); await new Promise(resolve => server.close(resolve)); }
});

test('Browser headers, proxy precedence and certificate verification stay correct', { skip: process.platform !== 'win32' }, () => {
    const script = setup + `local ffi=require('ffi');local net=require('net');local options;local calls=0
        package.loaded.windows_proxy={resolve=function(url) calls=calls+1;return 'office:8080','Windows PAC' end}
        local fake={curl_easy_init=function() return ffi.cast('WB_CURL *',1) end,
            curl_easy_cleanup=function() end,curl_easy_setopt=function(_,key,value) options[key]=value;return 0 end,
            curl_easy_perform=function() return 0 end,curl_easy_getinfo=function(_,_,value) value[0]=200;return 0 end}
        net.set_curl(fake,{path='fixture',version='8.11.1',version_num=0x080b01,tls='Schannel'})
        options={};assert(net.fetch('https://www.iciba.com/word?w=ruse')=='')
        assert(options[10004]=='office:8080' and calls==1)
        assert(options[10018]:find('Mozilla/5.0',1,true) and options[10102]=='')
        assert(tonumber(options[84])==2 and tonumber(options[64])==1 and tonumber(options[81])==2)
        net.set_proxy('none');options={};assert(net.fetch('https://www.iciba.com/word?w=ruse')=='')
        assert(options[10004]=='' and calls==1)
        net.set_proxy('http://explicit:8888');options={};assert(net.fetch('https://www.iciba.com/word?w=ruse')=='')
        assert(options[10004]=='http://explicit:8888' and calls==1)
        options={};assert(net.fetch('https://open.iciba.com/dsapi/')=='')
        assert(options[84]==nil and options[10018]:find('Wordbook',1,true))
        assert(not pcall(net.set_proxy,'invalid'))
        print('Request settings verified')`;
    const env = { ...process.env };
    for (const name of ['https_proxy', 'HTTPS_PROXY', 'all_proxy', 'ALL_PROXY']) delete env[name];
    const result = spawnSync('luajit', ['-e', script], { encoding: 'utf8', timeout: 5000, env });
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.match(result.stdout, /Request settings verified/);
});
