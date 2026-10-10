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
    const classes = new Set();
    return {
        style: {}, value: '', textContent: '',
        classList: {
            add(name) { classes.add(name); },
            remove(name) { classes.delete(name); },
            toggle(name, active) { if (active) classes.add(name); else classes.delete(name); },
            contains(name) { return classes.has(name); }
        },
        querySelector() { return elements.get('scanIcon'); },
        addEventListener() {},
        set innerHTML(value) { this.markup = value; register(value); },
        get innerHTML() { return this.markup || ''; }
    };
}
register(html);
elements.set('scanIcon', element());
let response = {devices: []};
let httpOK = true;
let failNetwork = false;
const requests = [];
const timers = new Map();
let timerId = 0;
const context = vm.createContext({
    document: {
        getElementById(id) { return elements.get(id) || null; },
        querySelectorAll() { return []; }
    },
    console,
    setInterval(callback, interval) { const id = ++timerId; timers.set(id, {callback, interval}); return id; },
    clearInterval(id) { timers.delete(id); }, setTimeout() {},
    fetch: async (url, options) => {
        requests.push({url, options});
        if (failNetwork) throw new Error('Offline');
        return {ok: httpOK, json: async () => response};
    }
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

    // Progress keeps the last inventory and works independently of auto-refresh.
    vm.runInContext('devices = [sample]; renderDevices();', context);
    const inventoryMarkup = elements.get('deviceGrid').innerHTML;
    const job = {id: 1, state: 'running', phase: 'discovery', completed: 128, total: 254, started_at: 100};
    response = {scan: job};
    await vm.runInContext('triggerScan()', context);
    assert.equal(elements.get('deviceGrid').innerHTML, inventoryMarkup);
    assert.equal(elements.get('scanBtn').disabled, true);
    assert(elements.get('scanIcon').classList.contains('spinner'));
    assert.match(elements.get('scanProgressText').textContent, /Scanning addresses… 128 \/ 254/);
    assert.equal(elements.get('scanProgressBar').value, 128);
    assert([...timers.values()].some(timer => timer.interval === 500));
    assert.equal(requests.at(-1).options.method, 'POST');

    response = {scan: {...job, phase: 'devices', completed: 0, total: 0}};
    await vm.runInContext('pollScan()', context);
    assert.match(elements.get('scanProgressText').textContent, /Checking devices… 0 \/ 0/);
    assert.equal(elements.get('scanProgressBar').max, 1);
    failNetwork = true;
    await vm.runInContext('pollScan()', context);
    assert.match(elements.get('scanProgressText').textContent, /retrying/);
    assert.equal(elements.get('scanBtn').disabled, true);
    failNetwork = false;

    response = {scan: {...job, state: 'cancelled'}};
    await vm.runInContext('cancelScan()', context);
    assert.equal(requests.at(-1).url, '/api/scan/cancel');
    assert.equal(elements.get('deviceGrid').innerHTML, inventoryMarkup);
    assert.match(elements.get('scanProgressText').textContent, /Previous inventory kept/);
    assert.equal(elements.get('scanBtn').disabled, false);
    assert(!elements.get('scanIcon').classList.contains('spinner'));
    assert(![...timers.values()].some(timer => timer.interval === 500));
    context.stale = job;
    vm.runInContext('updateScanStatus(stale)', context);
    assert.equal(elements.get('scanBtn').disabled, false); // Late progress cannot undo cancellation.

    const completed = {...job, id: 2, state: 'completed'};
    response = {scan: {...completed, state: 'running'}};
    await vm.runInContext('triggerScan()', context);
    response = {scan: completed, devices: [], scanned_at: '12:00:00'};
    await vm.runInContext('pollScan()', context);
    assert.equal(requests.at(-1).url, '/api/devices');
    assert.match(elements.get('deviceGrid').innerHTML, /No devices match/);
    assert.equal(elements.get('scanProgress').style.display, 'none');

    response = {scan: {...job, id: 3, state: 'failed', error: 'Worker <failed>'}};
    httpOK = false;
    await vm.runInContext('triggerScan()', context);
    assert.equal(elements.get('scanBtn').disabled, false);
    assert.equal(elements.get('scanProgressText').textContent, 'Worker <failed>');
    assert.match(elements.get('toast').textContent, /Worker <failed>/);
    console.log('Dashboard rendering, progress, cancellation, polling recovery, empty completion, and errors PASS');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
