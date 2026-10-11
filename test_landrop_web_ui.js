// Headless regression checks for the embedded LAN Drop UI and untrusted text.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

class Node {
    constructor(tag = 'div') {
        this.tag = tag;
        this.children = [];
        this.handlers = {};
        this.style = {};
        this.classList = { add() {}, remove() {} };
        this.textContent = '';
    }
    set innerHTML(value) {
        assert(!/[<]img|onclick=|onerror=/i.test(value), 'Untrusted executable markup');
        this.children = [];
    }
    append(...nodes) { this.children.push(...nodes); }
    replaceChildren(...nodes) { this.children = nodes; }
    addEventListener(event, handler) { this.handlers[event] = handler; }
}

async function main() {
    const source = fs.readFileSync('landrop_web.lua', 'utf8');
    const script = source.match(/<script>([\s\S]*?)<\/script>/)[1];
    const nodes = new Map();
    const get = id => {
        if (!nodes.has(id)) nodes.set(id, new Node());
        return nodes.get(id);
    };
    const filename = '<img src=x onerror=alert(1)>\'".txt';
    const texts = ["'))-alert(1)-(('", 'https://example.com/" onclick="alert(1)', 'normal text'];
    let files = [{ name: filename, size_fmt: '1 B', mime: 'text/plain', is_text: true }];
    let history = texts.map(text => ({ text, is_url: text.startsWith('http'), date: 'today', time: 'now' }));
    const context = {
        document: { getElementById: get, createElement: tag => new Node(tag) },
        window: { addEventListener() {} },
        console,
        navigator: {},
        setInterval() {},
        setTimeout() {},
        fetch: async path => ({ json: async () => path === '/api/files' ? files
            : path === '/api/clipboard' ? { history } : {} }),
    };
    vm.createContext(context);
    vm.runInContext(script, context);
    await context.loadFiles();
    await context.loadClipboard();
    const row = get('file-list-container').children[0];
    assert.equal(row.children[0].children[1].children[0].textContent, filename);
    const calls = [];
    context.openPreview = name => calls.push(['preview', name]);
    context.deleteFile = name => calls.push(['delete', name]);
    row.children[1].children[0].handlers.click();
    row.children[1].children[2].handlers.click();
    assert.deepEqual(calls, [['preview', encodeURIComponent(filename)], ['delete', encodeURIComponent(filename)]]);
    const copies = [];
    context.copyToClipboard = text => copies.push(text);
    for (const row of get('clipboard-container').children) {
        const actions = row.children[1].children[1].children;
        actions.at(-1).handlers.click();
    }
    assert.deepEqual(copies, texts);
    const link = get('clipboard-container').children[1].children[1].children[1].children[0];
    assert.equal(link.href, texts[1]);
    assert.equal(link.rel, 'noopener noreferrer');
    files = [];
    history = [];
    await context.loadFiles();
    await context.loadClipboard();
    assert.equal(get('file-list-container').children.length, 0);
    assert.equal(get('clipboard-container').children.length, 0);
    console.log('Passed LAN Drop UI injection, handlers, and empty-state checks.');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
