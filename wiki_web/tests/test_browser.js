// Optional real-browser selection and viewport checks; Playwright is test tooling only.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawn, spawnSync } = require('node:child_process');
const { once } = require('node:events');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
let chromium;
try { ({ chromium } = require(process.env.LEAF_WIKI_PLAYWRIGHT || 'playwright')); } catch (_) {}
const root = path.resolve(__dirname, '../..');

test('real browser selects words in editor/preview and keeps dictionary within desktop/mobile viewports',
  { skip: !chromium, timeout: 30000 }, async () => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'leaf-browser-'));
    let child, browser, logs = '';
    try {
      const fixture = spawnSync('luajit', [path.join(__dirname, 'test_dictionary.lua'), directory], { encoding: 'utf8' });
      assert.equal(fixture.status, 0, fixture.stdout + fixture.stderr);
      child = spawn('luajit', [path.join(root, 'wiki_web.lua'), '--port', '0', '--data-dir', path.join(directory, 'notebook'),
        '--cache-dir', path.join(directory, 'cache'), '--config', path.join(directory, 'config.json'),
        '--dict-db', path.join(directory, '词典.db')]);
      child.stderr.on('data', bytes => { logs += bytes; });
      const url = await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('Server startup timed out: ' + logs)), 5000);
        child.on('error', reject);
        child.on('exit', code => { clearTimeout(timer); reject(new Error('Server exited: ' + code + logs)); });
        child.stdout.on('data', bytes => {
          logs += bytes; const match = logs.match(/http:\/\/127\.0\.0\.1:\d+/);
          if (match) { clearTimeout(timer); resolve(match[0]); }
        });
      });
      const response = await fetch(url + '/api/page', { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id: 'Study', content: '# Study\nAn ephemeral bloom.', revision: '' }) });
      assert.equal(response.status, 200);
      const executablePath = process.env.PLAYWRIGHT_EXECUTABLE_PATH || (process.platform === 'win32'
        ? path.join(process.env['ProgramFiles(x86)'], 'Microsoft/Edge/Application/msedge.exe') : undefined);
      browser = await chromium.launch({ headless: true, executablePath });
      const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
      const errors = []; page.on('pageerror', error => errors.push(error.message));
      await page.goto(url); await page.locator('#editor').waitFor({ state: 'visible' });
      await page.locator('#editor').evaluate(editor => {
        editor.focus(); const index = editor.value.indexOf('ephemeral'); editor.setSelectionRange(index, index + 9);
      });
      await page.locator('#dictionary-open').click();
      await page.waitForFunction(() => document.getElementById('dictionary-status').textContent.includes('Local dictionary'));
      assert.match(await page.locator('#dictionary-results').innerText(), /Lasting a short time/);
      const panes = await page.locator('#panes').boundingBox();
      const panel = await page.locator('#dictionary-panel').boundingBox();
      assert.ok(panel.x >= panes.x + panes.width, 'Desktop panel should sit beside the editor');
      const screenshots = process.env.LEAF_WIKI_SCREENSHOTS;
      if (screenshots) { fs.mkdirSync(screenshots, { recursive: true }); await page.screenshot({ path: path.join(screenshots, 'desktop.png') }); }
      await page.locator('#dictionary-close').click();
      await page.locator('#preview').evaluate(preview => {
        const text = preview.querySelector('p').firstChild;
        const index = text.textContent.indexOf('ephemeral');
        const range = document.createRange(); range.setStart(text, index); range.setEnd(text, index + 9);
        const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
      });
      await page.locator('#dictionary-open').click();
      await page.waitForFunction(() => document.getElementById('dictionary-status').textContent.includes('Local dictionary'));
      assert.equal(await page.locator('#dictionary-word').inputValue(), 'ephemeral');
      for (const width of [950, 650, 375, 320]) {
        await page.setViewportSize({ width, height: 850 });
        const bounds = await page.locator('#dictionary-panel').boundingBox();
        assert.ok(bounds.x >= 0 && bounds.x + bounds.width <= width, 'Panel outside viewport: ' + width);
        const find = await page.locator('#dictionary-form button').boundingBox();
        assert.ok(find.height < 50, 'Find button wrapped: ' + width);
        assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'Horizontal overflow: ' + width);
      }
      if (screenshots) await page.screenshot({ path: path.join(screenshots, 'mobile.png'), fullPage: true });
      await page.locator('#dictionary-word').fill('missing');
      await page.locator('#dictionary-form button').click();
      await page.waitForFunction(() => document.getElementById('dictionary-status').textContent.includes('No definition'));
      assert.equal(await page.locator('#editor').inputValue(), '# Study\nAn ephemeral bloom.');
      await page.locator('#dictionary-word').fill('<script>');
      await page.locator('#dictionary-form button').click();
      await page.waitForFunction(() => document.getElementById('dictionary-status').textContent.includes('Local dictionary'));
      assert.match(await page.locator('#dictionary-results').innerText(), /<img src=x onerror=alert\(1\)>/);
      assert.equal(await page.locator('#dictionary-results img').count(), 0);
      assert.deepEqual(errors, []);
    } finally {
      if (browser) await browser.close();
      if (child && child.exitCode === null) { const exit = once(child, 'exit'); child.kill(); await exit; }
      fs.rmSync(directory, { recursive: true, force: true });
    }
  });
