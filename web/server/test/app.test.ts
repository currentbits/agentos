import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { parseWebConf } from '../src/auth.js';
import { fakeDeps, H, HM, LOGIN } from './helpers.js';

// /api/nope has no route: an authorized request reaches the 404 handler, a rejected one never does.
describe('HTTP auth through the app', () => {
  it('401 without identity, 403 unlisted, through to routing when listed', async () => {
    const app = await buildApp(fakeDeps().deps);
    expect((await app.inject({ url: '/api/nope', headers: { host: H.host } })).statusCode).toBe(401);
    expect((await app.inject({ url: '/api/nope', headers: { ...H, 'tailscale-user-login': 'eve@example.com' } })).statusCode).toBe(403);
    expect((await app.inject({ url: '/api/nope', headers: H })).statusCode).toBe(404);
  });

  it('not-configured mode serves only the static page', async () => {
    const app = await buildApp(fakeDeps(() => ({}), { webConf: () => parseWebConf('') }).deps);
    for (const url of ['/', '/api/settings', '/api/sessions']) {
      const r = await app.inject({ url, headers: H });
      expect(r.statusCode).toBe(403);
      expect(r.headers['content-type']).toMatch(/text\/html/);
      expect(r.body).toContain(`sudo agentos-config set AGENTOS_WEB_USERS ${LOGIN}`);
    }
  });

  it('mutating requests need X-AgentOS and a matching Origin', async () => {
    const app = await buildApp(fakeDeps().deps);
    const post = (headers: Record<string, string>) => app.inject({ method: 'POST', url: '/api/nope', headers, payload: {} });
    expect((await post({ ...H, origin: HM.origin })).statusCode).toBe(403);
    expect((await post({ ...HM, origin: 'https://evil.example' })).statusCode).toBe(403);
    expect((await post(HM)).statusCode).toBe(404);
  });

  it('serves the UI and noVNC behind auth, with an SPA fallback and JSON 404 under /api', async () => {
    const ui = mkdtempSync(join(tmpdir(), 'ui-'));
    mkdirSync(join(ui, 'assets'));
    writeFileSync(join(ui, 'index.html'), '<div id="root"></div>');
    writeFileSync(join(ui, 'assets', 'a.js'), 'x');
    const novnc = mkdtempSync(join(tmpdir(), 'novnc-'));
    mkdirSync(join(novnc, 'core'));
    writeFileSync(join(novnc, 'core', 'rfb.js'), 'export default class RFB {}');
    const app = await buildApp(fakeDeps(() => ({}), { uiRoot: ui, novncRoot: novnc }).deps);
    const rfb = await app.inject({ url: '/novnc/core/rfb.js', headers: H });
    expect(rfb.body).toContain('class RFB');
    expect(rfb.headers['content-type']).toMatch(/javascript/);
    expect((await app.inject({ url: '/novnc/core/rfb.js', headers: { host: H.host } })).statusCode).toBe(401);
    expect((await app.inject({ url: '/', headers: H })).body).toContain('root');
    expect((await app.inject({ url: '/sessions/ag-x', headers: H })).body).toContain('root');
    expect((await app.inject({ url: '/assets/a.js', headers: H })).body).toBe('x');
    const api404 = await app.inject({ url: '/api/nope', headers: H });
    expect(api404.statusCode).toBe(404);
    expect(api404.json()).toEqual({ error: 'not found' });
    expect((await app.inject({ url: '/', headers: { host: H.host } })).statusCode).toBe(401);
  });
});

describe('WebSocket upgrades', () => {
  it('reject a missing identity, an unlisted login and a missing or bad Origin', async () => {
    const app = await buildApp(fakeDeps().deps);
    await app.ready();
    const url = '/api/nope';
    await expect(app.injectWS(url, { headers: { host: H.host, origin: HM.origin } })).rejects.toThrow(/401/);
    await expect(app.injectWS(url, { headers: { ...H, 'tailscale-user-login': 'eve@example.com', origin: HM.origin } })).rejects.toThrow(/403/);
    await expect(app.injectWS(url, { headers: { ...H, origin: 'https://evil.example' } })).rejects.toThrow(/403/);
    await expect(app.injectWS(url, { headers: H })).rejects.toThrow(/403/);
    await expect(app.injectWS(url, { headers: { ...H, origin: HM.origin } })).rejects.toThrow(/404/);
  });
});
