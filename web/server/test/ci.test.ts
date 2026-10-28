import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { argv } from '../src/actions.js';
import { buildApp } from '../src/app.js';
import { fakeDeps, H, HM, LOGIN } from './helpers.js';

const CI = '/usr/local/bin/agentos-ci';
const ID = '20261027-101500-0001';
const RUN = { id: ID, repo: '/home/agent/work/app', ref: 'HEAD', commit: 'a'.repeat(40), status: 'failed', steps: [] };

describe('ci actions', () => {
  it('builds exact argv, values after "--" or as --opt=value', () => {
    expect(argv({ name: 'ci-run', path: '/home/agent/x', ref: 'main' })).toEqual([CI, 'run', '--json', '--source', 'web', '--ref', 'main', '--', '/home/agent/x']);
    expect(argv({ name: 'ci-status', id: ID })).toEqual([CI, 'status', '--json', ID]);
    expect(argv({ name: 'ci-list', limit: 5 })).toEqual([CI, 'list', '--json', '--limit', '5']);
    expect(argv({ name: 'ci-list', limit: 5, repo: '/home/agent/x' })).toEqual([CI, 'list', '--json', '--limit', '5', '--repo=/home/agent/x']);
    expect(argv({ name: 'ci-cancel', id: ID })).toEqual([CI, 'cancel', '--json', ID]);
    expect(argv({ name: 'ci-log', id: ID, step: 'test' })).toEqual([CI, 'logs', ID, '--follow', '--step=test']);
    expect(argv({ name: 'ci-log', id: ID, step: '' })).toEqual([CI, 'logs', ID, '--follow']);
    expect(argv({ name: 'ci-remotes' })).toEqual([CI, 'remote', 'list', '--json']);
    expect(argv({ name: 'solenta-status', path: '/home/agent/w' })).toEqual(['/usr/local/lib/agentos/solenta-pair', 'status', '--', '/home/agent/w']);
  });
  it('rejects bad ids, refs, steps, limits and relative paths', () => {
    for (const id of ['', '../x', '20261027-101500-zzzz', `${ID};id`]) expect(() => argv({ name: 'ci-status', id })).toThrow(/run id/);
    for (const ref of ['-x', '--upload-pack=x', 'a b', '']) expect(() => argv({ name: 'ci-run', path: '/home/agent', ref })).toThrow(/ref/);
    for (const step of ['../run.json', '-x', 'a/b']) expect(() => argv({ name: 'ci-log', id: ID, step })).toThrow(/step/);
    expect(() => argv({ name: 'ci-run', path: 'rel', ref: 'HEAD' })).toThrow(/path/);
    expect(() => argv({ name: 'ci-list', limit: 0 })).toThrow(/limit/);
    expect(() => argv({ name: 'ci-list', limit: 1.5 })).toThrow(/limit/);
  });
});

describe('ci routes', () => {
  it('lists, shows and maps agentos-ci errors to 400', async () => {
    const { deps, calls } = fakeDeps((a) => a[1] === 'status' && a[3] === '20261027-000000-0000'
      ? { code: 2, stderr: 'agentos-ci: no run 20261027-000000-0000\n' }
      : { stdout: JSON.stringify(a[1] === 'list' ? [RUN] : RUN) });
    const app = await buildApp(deps);
    const list = await app.inject({ url: '/api/ci/runs?limit=7', headers: H });
    expect(list.json()).toEqual([RUN]);
    expect(calls.at(-1)!.argv).toEqual([CI, 'list', '--json', '--limit', '7']);
    expect((await app.inject({ url: `/api/ci/runs/${ID}`, headers: H })).json()).toEqual(RUN);
    const missing = await app.inject({ url: '/api/ci/runs/20261027-000000-0000', headers: H });
    expect(missing.statusCode).toBe(400);
    expect(missing.json().error).toBe('no run 20261027-000000-0000');
    expect((await app.inject({ url: '/api/ci/runs/..%2Fx', headers: H })).statusCode).toBe(400);
  });

  it('runs a directory inside home only, audited; rerun pins the commit; cancel audited', async () => {
    const { deps, calls, audits } = fakeDeps((a) => ({ stdout: JSON.stringify(a[1] === 'run' ? { run_id: ID } : RUN) }));
    mkdirSync(join(deps.home, 'proj'));
    const app = await buildApp(deps);
    const post = (url: string, payload?: object) => app.inject({ method: 'POST', url, headers: HM, payload });
    expect((await post('/api/ci/runs', { path: '/etc' })).statusCode).toBe(400);
    expect((await post('/api/ci/runs', {})).statusCode).toBe(400);
    expect(calls).toEqual([]);
    const r = await post('/api/ci/runs', { path: join(deps.home, 'proj'), ref: 'main' });
    expect(r.statusCode).toBe(201);
    expect(r.json()).toEqual({ run_id: ID });
    expect(calls.at(-1)!.argv).toEqual([CI, 'run', '--json', '--source', 'web', '--ref', 'main', '--', join(deps.home, 'proj')]);
    expect((await post(`/api/ci/runs/${ID}/rerun`)).statusCode).toBe(201);
    expect(calls.at(-1)!.argv).toEqual([CI, 'run', '--json', '--source', 'web', '--ref', 'a'.repeat(40), '--', RUN.repo]);
    expect((await post(`/api/ci/runs/${ID}/cancel`)).statusCode).toBe(200);
    expect(calls.at(-1)!.argv).toEqual([CI, 'cancel', '--json', ID]);
    expect(audits).toEqual([`${LOGIN} ci-run ${join(deps.home, 'proj')}`, `${LOGIN} ci-rerun ${ID}`, `${LOGIN} ci-cancel ${ID}`]);
  });

  it('mutations need the CSRF headers', async () => {
    const { deps, calls } = fakeDeps();
    const app = await buildApp(deps);
    expect((await app.inject({ method: 'POST', url: `/api/ci/runs/${ID}/cancel`, headers: H })).statusCode).toBe(403);
    expect(calls).toEqual([]);
  });

  it('streams a step log over the WebSocket, and refuses a bad step', async () => {
    const { deps } = fakeDeps();
    const app = await buildApp(deps);
    await app.ready();
    const ws = await app.injectWS(`/api/ci/runs/${ID}/log?step=..%2Frun.json`, { headers: HM });
    const closed = await new Promise<number>((resolve) => ws.on('close', (code) => resolve(code)));
    expect(closed).toBe(1008);
  });
});
