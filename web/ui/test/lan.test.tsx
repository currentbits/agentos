import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { App } from '../src/App';
import { api, page } from '../src/api';
import { Settings } from '../src/pages/Settings';
import { System } from '../src/pages/System';
import type { Me } from '../src/types';

const realReload = page.reload;
afterEach(() => { cleanup(); vi.unstubAllGlobals(); vi.restoreAllMocks(); page.reload = realReload; });

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
const text = (body: string, status: number) => new Response(body, { status, headers: { 'content-type': 'text/plain; charset=utf-8' } });
const FP = 'B4:A0:73:5F:85:CC:CE:06:76:AE:B3:64:CA:36:6A:F8:BC:6B:EF:B4:BC:FD:7F:9C:0E:CB:D9:6E:DE:D2:A9:B8';
const ME: Me = { login: 'agent@lan(192.168.1.20)', hostname: 'box', tailnetIp: null, tailnetName: null, lan: true };

// Routes by "METHOD path" or path (query ignored): a JSON body, or a function making the Response.
// Anything else gets an empty list.
const OVERVIEW = { '/api/system/health': { cpuPercent: 1, load: [0, 0, 0], memory: { totalBytes: 1, usedBytes: 0 }, disk: { totalBytes: 1, usedBytes: 0 } },
  '/api/desktops': { desktops: [] }, '/api/system/tailscale': { state: 'Running', dnsName: null, ip: null, serve: 'ok' }, '/api/update': { installed: '1.0.2' } };
function stubFetch(routes: Record<string, unknown>) {
  const f = vi.fn(async (url: string, init?: RequestInit) => {
    const path = url.split('?')[0];
    const hit = routes[`${init?.method ?? 'GET'} ${path}`] ?? routes[path];
    return typeof hit === 'function' ? (hit as () => Response)() : json(hit ?? []);
  });
  vi.stubGlobal('fetch', f);
  return f;
}

it('an expired LAN session reloads the page (which then shows the login page); other 401s do not', async () => {
  page.reload = vi.fn();
  stubFetch({ '/api/a': () => text('log in first', 401), '/api/b': () => text('no Tailscale identity', 401) });
  await expect(api('/api/a')).rejects.toThrow('log in first');
  expect(page.reload).toHaveBeenCalledTimes(1);
  await expect(api('/api/b')).rejects.toThrow('no Tailscale identity');
  expect(page.reload).toHaveBeenCalledTimes(1);
});

it('shows Log out on the LAN listener only; it posts with the CSRF header, then reloads', async () => {
  page.reload = vi.fn();
  const f = stubFetch({ ...OVERVIEW, '/api/me': ME, 'POST /api/lan/logout': { ok: true } });
  render(<App />);
  fireEvent.click(await screen.findByText('Log out'));
  await vi.waitFor(() => expect(page.reload).toHaveBeenCalled());
  expect(f.mock.calls.find(([u]) => u === '/api/lan/logout')![1]).toMatchObject({ method: 'POST', headers: { 'X-AgentOS': '1' } });
  cleanup();
  stubFetch({ ...OVERVIEW, '/api/me': { ...ME, login: 'alice@example.com', lan: false } });
  render(<App />);
  await screen.findByText('alice@example.com');
  expect(screen.queryByText('Log out')).toBeNull();
});

it('System shows the LAN addresses and the certificate fingerprint, or that LAN access is off', async () => {
  stubFetch({ '/api/system/lan': { enabled: true, fingerprint: FP, addresses: ['192.168.1.50', '10.0.0.7'] }, '/api/update': { installed: '1.0.2' } });
  render(<System me={null} />);
  expect((await screen.findByText(FP)).tagName).toBe('CODE');
  expect(screen.getByText('https://192.168.1.50', { exact: false })).toBeTruthy();
  expect(screen.getByText('https://10.0.0.7', { exact: false })).toBeTruthy();
  cleanup();
  stubFetch({ '/api/system/lan': { enabled: false, fingerprint: null, addresses: ['192.168.1.50'] }, '/api/update': { installed: '1.0.2' } });
  render(<System me={null} />);
  await screen.findByText(/^Off\. Turn it on in Settings/);
  expect(screen.queryByText(/Certificate SHA-256/)).toBeNull();
});

const SETTINGS = { values: { AGENTOS_WEB_LAN: '' }, secrets: {} };
const settingsRoutes = (put = () => json({ ok: true })) => ({
  '/api/settings': SETTINGS, 'PUT /api/settings': put,
  '/api/system/tailscale': { state: 'Running', dnsName: null, ip: null, serve: 'ok' },
  '/api/dirs': { path: '/home/agent', parent: null, dirs: [] },
  '/api/solenta': { host: 'b', remoteHost: 'agent@b', remotePath: null, tailscaleSsh: true, hostKeys: [], keyscan: '', modeA: { enabled: true, service: 'inactive', version: null, webToken: false }, preflight: [] },
});
const lanBox = async () => (await screen.findByLabelText(/Also on the local network/)) as HTMLInputElement;
const saveWeb = (box: HTMLInputElement) => fireEvent.click(box.closest('form')!.querySelector('button')!);

it('Settings turns LAN access on after a warning, and shows why applying failed', async () => {
  const why = 'saved, but applying failed: LAN access to the web UI is not on: set a password for agent first (sudo agentos-config password), then apply again';
  const f = stubFetch(settingsRoutes(() => json({ error: why }, 502)));
  const confirm = vi.spyOn(window, 'confirm').mockReturnValue(true);
  render(<Settings me={{ ...ME, lan: false }} />);
  const box = await lanBox();
  expect(box.checked).toBe(false);
  fireEvent.click(box);
  saveWeb(box);
  await screen.findByText(why);
  expect(confirm.mock.calls[0][0]).toMatch(/full control of this machine/);
  const put = f.mock.calls.find(([u, i]) => u === '/api/settings' && i?.method === 'PUT')!;
  expect(JSON.parse(String(put[1]!.body))).toEqual({ values: { AGENTOS_WEB_LAN: '1' } });
});

it('Settings asks before a LAN user turns LAN access off, and saves nothing on No', async () => {
  const f = stubFetch({ ...settingsRoutes(), '/api/settings': { values: { AGENTOS_WEB_LAN: '1' }, secrets: {} } });
  const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false);
  render(<Settings me={ME} />);
  const box = await lanBox();
  fireEvent.click(box);
  saveWeb(box);
  expect(confirm.mock.calls[0][0]).toMatch(/You are using LAN access/);
  expect(f.mock.calls.some(([, i]) => i?.method === 'PUT')).toBe(false);
});
