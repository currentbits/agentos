// E2E: headless Chromium against the web UI, identity header injected like tailscale serve would.
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT ?? 'playwright');
const BASE = process.env.BASE ?? 'http://127.0.0.1:7070';
const LOGIN = process.env.LOGIN ?? 'e2e@example.com';
const NAME = `e2e-${process.pid}`;
const fail = (m) => { console.error(`E2E FAIL: ${m}`); process.exit(1); };

const browser = await chromium.launch();
const ctx = await browser.newContext({ extraHTTPHeaders: { 'Tailscale-User-Login': LOGIN } });
const page = await ctx.newPage();
const errors = [];
page.on('pageerror', (e) => errors.push(e.message));
for (const [path, heading] of [['/', 'Overview'], ['/sessions', 'Sessions'], ['/desktops', 'Desktops'], ['/settings', 'Settings'], ['/system', 'System']]) {
  await page.goto(BASE + path);
  await page.getByRole('heading', { level: 1, name: heading }).waitFor({ timeout: 15000 }).catch(() => fail(`${path}: no "${heading}" heading`));
}
await page.goto(BASE + '/sessions');
await page.getByLabel('CLI').selectOption('shell');
await page.getByRole('textbox', { name: 'Name' }).fill(NAME);
await page.getByRole('button', { name: 'Start' }).click();
await page.waitForURL(`**/sessions/ag-${NAME}`, { timeout: 15000 }).catch(async () => fail('no terminal page: ' + await page.locator('.error').allTextContents()));
await page.getByText('attached').waitFor({ timeout: 15000 }).catch(() => fail('terminal never attached'));
await page.locator('.xterm').click();
await page.keyboard.type('echo e2e-$((6*7))');
await page.keyboard.press('Enter');
await page.locator('.xterm-rows', { hasText: 'e2e-42' }).waitFor({ timeout: 15000 }).catch(() => fail('typed command output not seen'));
const mut = { headers: { 'X-AgentOS': '1', Origin: BASE } };
for (const [method, path] of [['post', `/api/sessions/ag-${NAME}/stop`], ['delete', `/api/sessions/ag-${NAME}`]]) {
  const r = await page.request[method](BASE + path, mut);
  if (!r.ok()) fail(`cleanup ${method} ${path}: ${r.status()}`);
}
// Desktop view: noVNC's rfb.js (and the vendor/ modules it imports) load from /novnc/, and the
// same-origin VNC proxy connects.
const created = await page.request.post(BASE + '/api/desktops', mut);
if (!created.ok()) fail(`create desktop: ${created.status()}`);
const { id } = await created.json();
await page.goto(`${BASE}/desktops/${id}`);
await page.getByText('connected', { exact: true }).waitFor({ timeout: 30000 })
  .catch(async () => fail(`desktop ${id} view never connected: ${await page.locator('.toolbar').textContent()}`));
if (!(await page.request.delete(`${BASE}/api/desktops/${id}`, mut)).ok()) fail(`destroy desktop ${id}`);
if (errors.length) fail(`page errors: ${errors.join('; ')}`);
await browser.close();
console.log('E2E OK');
