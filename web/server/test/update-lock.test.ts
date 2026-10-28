import { EventEmitter } from 'node:events';
import { expect, it, vi } from 'vitest';
import { buildApp } from '../src/app.js';
import { fakeDeps, H, HM, LOGIN } from './helpers.js';

// spawn is mocked: each agentos-update "run" is a fake child the test finishes by emitting 'close'.
const children: (EventEmitter & { stdout: EventEmitter; stderr: EventEmitter; kill: () => void })[] = [];
vi.mock('node:child_process', async (orig) => ({
  ...(await orig<typeof import('node:child_process')>()),
  spawn: vi.fn(() => {
    const pipe = () => Object.assign(new EventEmitter(), { pause: () => {}, resume: () => {} });
    const c = Object.assign(new EventEmitter(), { stdout: pipe(), stderr: pipe(), kill: () => {} });
    children.push(c);
    return c;
  }),
}));

const closed = (ws: { once: (e: string, f: (c: number, r: Buffer) => void) => void }) =>
  new Promise<[number, string]>((r) => ws.once('close', (c, b) => r([c, b.toString()])));

it('runs one agentos-update at a time: a second socket is refused until the child exits', async () => {
  const { deps, audits } = fakeDeps();
  const app = await buildApp(deps);
  await app.ready();
  const headers = { ...H, origin: HM.origin };

  const first = await app.injectWS('/api/system/update', { headers });
  expect(children).toHaveLength(1);
  const second = await app.injectWS('/api/system/update', { headers });
  expect(await closed(second)).toEqual([1013, 'agentos-update is already running']);
  expect(children).toHaveLength(1);

  const firstClosed = closed(first);
  children[0].emit('close', 0);
  await firstClosed;
  const third = await app.injectWS('/api/system/update', { headers });
  expect(children).toHaveLength(2);
  expect(audits).toEqual([`${LOGIN} update -`, `${LOGIN} update -`]);

  // A spawn error clears the lock too.
  const thirdClosed = closed(third);
  children[1].emit('error', new Error('ENOENT'));
  await thirdClosed;
  (await app.injectWS('/api/system/update', { headers })).terminate();
  expect(children).toHaveLength(3);
  await app.close();
});
