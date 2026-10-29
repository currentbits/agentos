import { writeFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { argv } from '../src/actions.js';
import { buildApp } from '../src/app.js';
import { fakeDeps, H, HM, LOGIN } from './helpers.js';

const UPDATE = '/usr/local/bin/agentos-update';
const LOCK = ['flock', '-n', '/run/lock/agentos-update.lock', 'true'];
const STATE = { installed: '1.0.0', available: '1.1.0', notes_url: 'https://o.github.io/r/apt/notes/1.1.0.md',
  notes: '<b>new</b>', checked_at: '2026-10-29T03:12:00Z', error: null };
const RUNS = JSON.stringify([{ id: '20261029-101500-0001', status: 'running' }, { id: '20261029-101400-0000', status: 'passed' },
  { id: '20261029-101600-0002', status: 'queued' }]);

// A runner for the update calls: version 1.0.0, the lock free unless `locked`, two active CI runs.
const reply = (locked = false) => (a: string[]) =>
  a[0] === UPDATE && a[1] === '--version' ? { stdout: '1.0.0\n' }
    : a[0] === 'flock' ? { code: locked ? 1 : 0 }
      : a[1] === 'list' ? { stdout: RUNS } : {};

describe('updates', () => {
  it('builds exact argv', () => {
    expect(argv({ name: 'update-check' })).toEqual(['sudo', '-n', UPDATE, '--check']);
    expect(argv({ name: 'update-version' })).toEqual([UPDATE, '--version']);
    expect(argv({ name: 'update-running' })).toEqual(LOCK);
  });
  it('GET /api/update: update.json, the live version, the lock and active CI runs', async () => {
    const { deps } = fakeDeps(reply());
    writeFileSync(deps.updateState, JSON.stringify(STATE));
    const app = await buildApp(deps);
    const r = await app.inject({ url: '/api/update', headers: H });
    expect(r.statusCode).toBe(200);
    expect(r.json()).toEqual({ ...STATE, running: false, ciActive: ['20261029-101500-0001', '20261029-101600-0002'] });
  });
  it('not checked yet; running while the lock is held; a hostile version is dropped', async () => {
    const { deps } = fakeDeps(reply(true));
    const app = await buildApp(deps);
    expect((await app.inject({ url: '/api/update', headers: H })).json()).toMatchObject({ installed: '1.0.0', available: null, error: 'not checked yet', running: true });
    writeFileSync(deps.updateState, JSON.stringify({ ...STATE, available: '1.1.0\u001b[2J', error: 'x'.repeat(2000), extra: 'dropped' }));
    const j = (await app.inject({ url: '/api/update', headers: H })).json();
    expect(j.available).toBeNull();
    expect(j.error).toHaveLength(512);
    expect(j).not.toHaveProperty('extra');
  });
  it('an error from the check is passed on, never turned into "up to date"', async () => {
    const { deps } = fakeDeps(reply());
    writeFileSync(deps.updateState, JSON.stringify({ ...STATE, available: null, error: 'Failed to fetch … Missing key 0123ABCD' }));
    const j = (await (await buildApp(deps)).inject({ url: '/api/update', headers: H })).json();
    expect([j.available, j.error]).toEqual([null, 'Failed to fetch … Missing key 0123ABCD']);
  });
  it('POST /api/update/check: CSRF, then agentos-update --check as root, audited', async () => {
    const { deps, calls, audits } = fakeDeps(reply());
    const app = await buildApp(deps);
    expect((await app.inject({ method: 'POST', url: '/api/update/check', headers: H })).statusCode).toBe(403);
    expect(calls).toEqual([]);
    const r = await app.inject({ method: 'POST', url: '/api/update/check', headers: HM });
    expect(r.statusCode).toBe(200);
    expect(calls[0].argv).toEqual(argv({ name: 'update-check' }));
    expect(audits).toEqual([`${LOGIN} update-check -`]);
    expect(r.json().installed).toBe('1.0.0');
  });
  it('GET /api/update/log: the last run, and whether it still runs', async () => {
    const { deps } = fakeDeps(reply(true));
    const app = await buildApp(deps);
    expect((await app.inject({ url: '/api/update/log', headers: H })).json()).toEqual({ running: true, text: '' });
    writeFileSync(deps.updateLog, 'x'.repeat(70 * 1024) + '\nok    agentos\n== done: ok\n');
    const j = (await app.inject({ url: '/api/update/log', headers: H })).json();
    expect(j.text).toHaveLength(64 * 1024);
    expect(j.text.endsWith('ok    agentos\n== done: ok\n')).toBe(true);
  });
});
