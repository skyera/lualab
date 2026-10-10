// Execute the embedded dashboard renderers without a browser or network.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('lan_dashboard.lua', 'utf8');
const html = source.match(/local DASHBOARD_HTML = \[\[([\s\S]*?)\]\]/)[1];
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const elements = new Map();
function register(markup) {
    for (const match of markup.matchAll(/\bid="([^"]+)"/g)) {
        if (!elements.has(match[1])) elements.set(match[1], element());
    }
}
function element() {
    return {
        style: {}, value: '', textContent: '',
        classList: { add() {}, remove() {}, toggle() {} },
        addEventListener() {},
        set innerHTML(value) { this.markup = value; register(value); },
        get innerHTML() { return this.markup || ''; }
    };
}
register(html);
const context = vm.createContext({
    document: {
        getElementById(id) { return elements.get(id) || null; },
        querySelectorAll() { return []; }
    },
    console,
    setInterval() { return 1; }, clearInterval() {}, setTimeout() {},
    fetch: async () => ({ json: async () => ({ devices: [] }) })
});
async function main() {
    vm.runInContext(script, context);
    await new Promise(resolve => setImmediate(resolve));
    for (const status of ['online', 'offline', 'not_observed', 'unchecked']) {
        for (const name of ['', 'NAS <office> & "日本"', 'X'.repeat(1000)]) {
            context.sample = {
                ip: '192.168.1.20', mac: 'aa:bb:cc:dd:ee:01', hostname: name,
                vendor: 'Vendor & Co', type_name: 'Linux', category: 'linux',
                ports: [{port: 443, name: 'HTTPS'}], status, latency_ms: 2,
                first_seen: 100, last_seen: 200, hardware: {}
            };
            await vm.runInContext(`devices = [sample]; renderGrid(devices); renderTable(devices);
                inspectDevice(sample.ip, sample.mac);`, context);
            assert.match(elements.get('deviceGrid').innerHTML, /First seen:.*Last seen:/s);
            assert.match(elements.get('deviceTableBody').innerHTML, /Last seen:/);
            assert.match(elements.get('modalBody').innerHTML, /First seen:.*Last seen:/s);
            assert.equal(elements.get('inspectModal').style.display, 'flex');
            if (name.includes('<office>')) assert.match(elements.get('deviceGrid').innerHTML, /&lt;office&gt;/);
            if (status === 'not_observed' || status === 'unchecked') {
                assert.match(elements.get('deviceGrid').innerHTML, /disabled onclick="probeDevicePorts/);
                assert.doesNotMatch(elements.get('modalBody').innerHTML, /scanCustomPorts|togglePingMonitor/);
            }
            vm.runInContext('closeModal();', context);
            assert.equal(elements.get('inspectModal').style.display, 'none');
        }
    }
    // IP reuse: details must select the historical MAC rather than the current occupant.
    await vm.runInContext(`devices = [{...sample, hostname: 'New occupant', status: 'online', mac: 'aa:bb:cc:dd:ee:02'},
        {...sample, hostname: 'Old NAS', status: 'not_observed'}];
        inspectDevice(sample.ip, sample.mac);`, context);
    assert.match(elements.get('modalTitle').textContent, /Old NAS/);
    vm.runInContext('devices = []; renderGrid(devices); renderTable(devices);', context);
    assert.match(elements.get('deviceGrid').innerHTML, /No devices match/);
    assert.equal(elements.get('deviceTableBody').innerHTML, '');
    console.log('Dashboard cards, table, details, empty transitions, escaping, and IP reuse PASS');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
