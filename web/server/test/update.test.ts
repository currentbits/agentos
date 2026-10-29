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
  it('GET /api/update/log: a 64 KiB cut does not split a multi-byte UTF-8 character', async () => {
    const { deps } = fakeDeps(reply(true));
    const app = await buildApp(deps);
    // A 2-byte char ('é', 0xC3 0xA9) straddling the cut point: the tail's read starts one byte
    // into it, at the lone continuation byte 0xA9, which must be dropped, not turned into U+FFFD.
    const buf = Buffer.concat([Buffer.from([0xc3, 0xa9]), Buffer.alloc(65531, 'y'), Buffer.from('END\n')]);
    expect(buf.length).toBe(65537);
    writeFileSync(deps.updateLog, buf);
    const j = (await app.inject({ url: '/api/update/log', headers: H })).json();
    expect(j.text).not.toContain('�');
    expect(j.text.endsWith('END\n')).toBe(true);
    expect(j.text.length).toBe(65535);
  });
  it('a flock probe failure that is not "the lock is held" (exit 2, not 1) is not "running"', async () => {
    const { deps } = fakeDeps((a) =>
      a[0] === UPDATE && a[1] === '--version' ? { stdout: '1.0.0\n' }
        : a[0] === 'flock' ? { code: 2 }
          : a[1] === 'list' ? { stdout: RUNS } : {});
    writeFileSync(deps.updateState, JSON.stringify(STATE));
    const app = await buildApp(deps);
    expect((await app.inject({ url: '/api/update', headers: H })).json().running).toBe(false);
  });
  it('skips ci-list and reports ciActive: null when nothing is available (no polling cost, no misleading restart warning)', async () => {
    const { deps, calls } = fakeDeps(reply());
    const app = await buildApp(deps);   // no update.json: available stays null
    const j = (await app.inject({ url: '/api/update', headers: H })).json();
    expect(j.available).toBeNull();
    expect(j.ciActive).toBeNull();
    expect(calls.some((c) => c.argv[1] === 'list')).toBe(false);
  });
  it('a corrupt update.json never reads as "up to date"', async () => {
    const { deps } = fakeDeps(reply());
    const app = await buildApp(deps);
    const get = async () => (await app.inject({ url: '/api/update', headers: H })).json();

    writeFileSync(deps.updateState, 'not json{{{');
    expect(await get()).toMatchObject({ available: null, error: 'not checked yet' });

    writeFileSync(deps.updateState, JSON.stringify({ checked_at: 12345, available: '1.1.0', error: null }));
    expect(await get()).toMatchObject({ error: 'not checked yet' });

    writeFileSync(deps.updateState, JSON.stringify({ checked_at: STATE.checked_at, available: 'bad version', error: null }));
    expect(await get()).toMatchObject({ available: null, error: 'invalid version in update.json' });
  });
});
