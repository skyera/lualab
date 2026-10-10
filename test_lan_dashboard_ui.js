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

    // Trust/tag filtering and escaped labels work for both device views.
    context.organized = {...context.sample, trusted: true, tags: ['Office', '日本 <camera>']};
    context.unknown = {...context.sample, ip: '192.168.1.21', mac: 'aa:bb:cc:dd:ee:02', hostname: 'Unknown', trusted: false, tags: ['Review']};
    vm.runInContext('devices = [organized, unknown]; updateTagOptions(); renderGrid(devices); renderTable(devices);', context);
    assert.match(elements.get('deviceGrid').innerHTML, /Trusted/);
    assert.match(elements.get('deviceGrid').innerHTML, /Unrecognized/);
    assert.match(elements.get('deviceGrid').innerHTML, /日本 &lt;camera&gt;/);
    assert.match(elements.get('deviceTableBody').innerHTML, /日本 &lt;camera&gt;/);
    assert.match(elements.get('tagFilter').innerHTML, /日本 &lt;camera&gt;/);
    elements.get('trustFilter').value = 'unrecognized';
    assert.equal(vm.runInContext('filterList().length', context), 1);
    assert.equal(vm.runInContext('filterList()[0].hostname', context), 'Unknown');
    elements.get('trustFilter').value = 'trusted';
    elements.get('tagFilter').value = 'office';
    assert.equal(vm.runInContext('filterList().length', context), 1);
    elements.get('searchInput').value = '日本';
    assert.equal(vm.runInContext('filterList().length', context), 1);
    elements.get('tagFilter').value = 'review';
    assert.equal(vm.runInContext('filterList().length', context), 0);
    elements.get('trustFilter').value = 'all';
    elements.get('tagFilter').value = '';
    elements.get('searchInput').value = '';

    // Historical devices can be organized by identity, without targeting a reused IP.
    vm.runInContext('openDeviceSettings(deviceId(organized))', context);
    assert.equal(elements.get('deviceSettingsModal').style.display, 'flex');
    assert.equal(elements.get('settingsTrusted').checked, true);
    assert.equal(elements.get('settingsTags').value, 'Office\n日本 <camera>');
    elements.get('settingsTrusted').checked = false;
    elements.get('settingsTags').value = ' Lab \nReview';
    response = {device: {...context.organized, trusted: false, tags: ['Lab', 'Review']}};
    let prevented = false;
    context.submitEvent = {preventDefault() { prevented = true; }};
    await vm.runInContext('saveDeviceSettings(submitEvent)', context);
    assert(prevented);
    assert.equal(requests.at(-1).url, '/api/device/meta');
    assert.deepEqual(JSON.parse(requests.at(-1).options.body).tags, ['Lab', 'Review']);
    assert.equal(JSON.parse(requests.at(-1).options.body).id, 'mac:aa:bb:cc:dd:ee:01');
    assert.equal(elements.get('deviceSettingsModal').style.display, 'none');
    vm.runInContext('openDeviceSettings(deviceId(organized))', context);
    httpOK = false;
    response = {message: 'Invalid <tag>'};
    await vm.runInContext('saveDeviceSettings(submitEvent)', context);
    assert.equal(elements.get('settingsError').textContent, 'Invalid <tag>');
    assert.equal(elements.get('deviceSettingsModal').style.display, 'flex');
    assert.equal(elements.get('settingsSaveBtn').disabled, false);
    vm.runInContext('closeDeviceSettings()', context);
    httpOK = true;

    const device_id = 'mac:aa:bb:cc:dd:ee:01';
    response = {events: [
        {id: 1, type: 'new_device', device_id, hostname: 'NAS <script>', ip: '192.168.1.18', timestamp: 100},
        {id: 2, type: 'ip_changed', device_id, hostname: 'NAS', ip: '192.168.1.20', old_ip: '192.168.1.18', new_ip: '192.168.1.20', timestamp: 200},
        {id: 3, type: 'port_opened', device_id, hostname: 'NAS', ip: '192.168.1.20', port: 443, service: 'HTTPS', timestamp: 300}
    ]};
    await vm.runInContext("showPane('changes')", context);
    assert.equal(elements.get('changesView').style.display, 'block');
    assert.equal(elements.get('deviceGrid').style.display, 'none');
    const timeline = elements.get('changesView').innerHTML;
    assert.match(timeline, /NAS &lt;script&gt;/);
    assert(timeline.indexOf('Port opened') < timeline.indexOf('IP changed'));
    elements.get('searchInput').value = '192.168.1.18';
    vm.runInContext('renderTimeline()', context);
    assert.match(elements.get('changesView').innerHTML, /IP changed/);
    elements.get('searchInput').value = 'Missing';
    vm.runInContext('renderTimeline()', context);
    assert.match(elements.get('changesView').innerHTML, /No changes match/);
    elements.get('searchInput').value = '';
    response = {events: []};
    await vm.runInContext('fetchEvents()', context);
    assert.match(elements.get('changesView').innerHTML, /No recorded changes yet/);
    httpOK = false;
    await vm.runInContext('fetchEvents()', context);
    assert.match(elements.get('changesView').textContent, /Changes unavailable/);
    httpOK = true;
    await vm.runInContext("showPane('devices')", context);
    assert.equal(elements.get('deviceGrid').style.display, 'grid');
    assert.equal(elements.get('changesView').style.display, 'none');

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
    assert(requests.slice(-2).some(request => request.url === '/api/devices'));
    assert.match(elements.get('deviceGrid').innerHTML, /No devices match/);
    assert.equal(elements.get('scanProgress').style.display, 'none');

    response = {scan: {...job, id: 3, state: 'failed', error: 'Worker <failed>'}};
    httpOK = false;
    await vm.runInContext('triggerScan()', context);
    assert.equal(elements.get('scanBtn').disabled, false);
    assert.equal(elements.get('scanProgressText').textContent, 'Worker <failed>');
    assert.match(elements.get('toast').textContent, /Worker <failed>/);

    httpOK = true;
    vm.runInContext("devices = [{...sample, status: 'online'}]; inspectDevice(sample.ip, sample.mac);", context);
    assert.match(elements.get('modalBody').innerHTML, /5000–6000/);
    assert.match(elements.get('modalBody').innerHTML, /8000–9000/);
    const probe = {id: 1, state: 'running', phase: 'ports', completed: 640, total: 2002, target_ip: context.sample.ip, started_at: 100};
    response = {probe};
    await vm.runInContext("scanPortPreset(sample.ip, '5000-6000,8000-9000')", context);
    assert.equal(elements.get('customPortInput').value, '5000-6000,8000-9000');
    assert.match(requests.at(-1).url, /ports=5000-6000%2C8000-9000/);
    assert.match(elements.get('portProbeText').textContent, /640 \/ 2002/);
    assert.equal(elements.get('portRangeBothBtn').disabled, true);
    failNetwork = true;
    await vm.runInContext('fetchProbeStatus()', context);
    assert.match(elements.get('portProbeText').textContent, /retrying/);
    failNetwork = false;
    response = {probe: {...probe, state: 'cancelled'}};
    await vm.runInContext('cancelPortProbe()', context);
    assert.equal(requests.at(-1).url, '/api/probe/cancel');
    assert.match(elements.get('portProbeText').textContent, /Previous results kept/);
    assert.equal(elements.get('customScanBtn').disabled, false);
    assert.equal(elements.get('portRangeBothBtn').disabled, false);
    response = {probe: {...probe, id: 2, completed: 0, total: 1001}};
    await vm.runInContext("scanPortPreset(sample.ip, '5000-6000')", context);
    const scanned = {...context.sample, status: 'online', ports: [{port: 6000, name: 'Port 6000'}]};
    response = {probe: {...probe, id: 2, state: 'completed', completed: 1001, total: 1001, ports: scanned.ports}, devices: [scanned]};
    await vm.runInContext('fetchProbeStatus()', context);
    assert.equal(elements.get('portProbeProgress').style.display, 'none');
    assert.match(elements.get('modalBody').innerHTML, /Port 6000/);
    assert.match(elements.get('toast').textContent, /1 reachable ports/);
    console.log('Dashboard rendering, timeline, tags, range presets, independent progress/cancellation, and errors PASS');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
