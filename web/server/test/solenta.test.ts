import { mkdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { fakeDeps, H, HM, LOGIN } from './helpers.js';

const PAIR = '/usr/local/lib/agentos/solenta-pair';
const STATUS = { host: 'box.ts.net', remoteHost: 'agent@box.ts.net', remotePath: null, tailscaleSsh: true, hostKeys: [],
  keyscan: 'ssh-keyscan -t ed25519 box.ts.net >> ~/.ssh/known_hosts', modeA: { enabled: true, service: 'inactive', version: null, webToken: false }, preflight: [] };

describe('solenta', () => {
  it('returns solenta-pair status, with a path confined to home', async () => {
    const { deps, calls } = fakeDeps(() => ({ stdout: JSON.stringify(STATUS) }));
    mkdirSync(join(deps.home, 'work'));
    const app = await buildApp(deps);
    expect((await app.inject({ url: '/api/solenta', headers: H })).json()).toEqual(STATUS);
    expect(calls.at(-1)!.argv).toEqual([PAIR, 'status']);
    await app.inject({ url: `/api/solenta?path=${encodeURIComponent(join(deps.home, 'work'))}`, headers: H });
    expect(calls.at(-1)!.argv).toEqual([PAIR, 'status', '--', join(deps.home, 'work')]);
    expect((await app.inject({ url: '/api/solenta?path=/etc', headers: H })).statusCode).toBe(400);
  });

  it('clones through the sessions code: allowlisted URL, "--", ~/work/<name>, audited', async () => {
    const { deps, calls, audits } = fakeDeps((a) => {
      if (a[0] === 'git') mkdirSync(a[4], { recursive: true });
      return {};
    });
    const app = await buildApp(deps);
    const post = (payload: object) => app.inject({ method: 'POST', url: '/api/solenta/clone', headers: HM, payload });
    for (const repo of ['file:///etc', '--upload-pack=x', 'ext::sh -c id']) expect((await post({ repo, name: 'x' })).json().field).toBe('repo');
    expect((await post({ repo: 'https://example.com/a.git', name: '../x' })).json().field).toBe('name');
    expect(calls).toEqual([]);
    const r = await post({ repo: 'https://example.com/a.git', name: 'app' });
    expect(r.statusCode).toBe(201);
    expect(r.json()).toEqual({ path: join(deps.home, 'work/app') });
    expect(calls[0].argv).toEqual(['git', 'clone', '--', 'https://example.com/a.git', join(deps.home, 'work/app')]);
    expect(audits).toEqual([`${LOGIN} repo-clone ${join(deps.home, 'work/app')}`]);
  });

  it('serves the bridge script as a download', async () => {
    const { deps } = fakeDeps();
    const app = await buildApp(deps);
    const r = await app.inject({ url: '/api/solenta/bridge', headers: H });
    expect(r.statusCode).toBe(200);
    expect(r.headers['content-disposition']).toBe('attachment; filename="solenta-bridge"');
    expect(r.body).toBe(readFileSync(deps.bridgePath, 'utf8'));
  });
});
