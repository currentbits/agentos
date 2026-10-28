import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { duration } from '../src/format';
import { CI } from '../src/pages/CI';

afterEach(() => { cleanup(); vi.unstubAllGlobals(); });
HTMLElement.prototype.scrollTo = () => {};   // jsdom has no layout

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
const ID = '20261027-101500-0001';
const RUN = { id: ID, repo: '/home/agent/work/app', ref: 'refs/heads/main', commit: 'abcdef0123456789', source: 'push', status: 'failed',
  created: '2026-10-27T10:15:00Z', started: '2026-10-27T10:15:00Z', finished: '2026-10-27T10:16:05Z', pipeline: 'ci.yml', image: null,
  secrets: ['NPM_TOKEN'], missing_secrets: [], error: null,
  steps: [{ name: 'install', status: 'passed', exit_code: 0, started: null, finished: null },
          { name: 'test', status: 'failed', exit_code: 1, started: null, finished: null }] };

class FakeWS {
  static all: FakeWS[] = [];
  onmessage: ((e: { data: string }) => void) | null = null;
  onclose: ((e: { reason: string }) => void) | null = null;
  constructor(public url: string) { FakeWS.all.push(this); }
  close() {}
}

it('formats durations', () => {
  expect(duration('2026-10-27T10:15:00Z', '2026-10-27T10:16:05Z')).toBe('1m 05s');
  expect(duration('2026-10-27T10:15:00Z', '2026-10-27T10:15:09Z')).toBe('9s');
  expect(duration(null, null)).toBe('');
});

it('lists runs and push remotes, and starts a run for a picked directory', async () => {
  const fetch = vi.fn(async (url: string, init?: RequestInit) => {
    if (init?.method === 'POST') return json({ run_id: ID }, 201);
    if (url.startsWith('/api/ci/runs')) return json([RUN]);
    if (url === '/api/ci/remotes') return json([{ name: 'app', path: '/home/agent/git/app.git', remote_add: 'git remote add agentos agent@box:git/app.git' }]);
    return json({ path: '/home/agent', parent: null, dirs: ['work'] });
  });
  vi.stubGlobal('fetch', fetch);
  render(<CI />);
  expect(await screen.findByText(ID)).toBeTruthy();
  expect(screen.getByText('~/work/app')).toBeTruthy();
  expect(screen.getByText('1m 05s')).toBeTruthy();
  expect(await screen.findByText('git remote add agentos agent@box:git/app.git')).toBeTruthy();
  const run = screen.getByText('Run CI', { selector: 'button' }) as HTMLButtonElement;
  expect(run.disabled).toBe(true);
  fireEvent.click(await screen.findByText('work/'));
  fireEvent.click(run);
  await vi.waitFor(() => expect(location.pathname).toBe(`/ci/${ID}`));
  const post = fetch.mock.calls.find(([, i]) => i?.method === 'POST')!;
  expect(post[0]).toBe('/api/ci/runs');
  expect(JSON.parse(post[1]!.body as string)).toEqual({ path: '/home/agent/work', ref: 'HEAD' });
});

it('shows a run, streams the failing step log by default, switches steps, re-runs and cancels', async () => {
  const fetch = vi.fn(async (url: string, init?: RequestInit) =>
    init?.method === 'POST' ? json(url.endsWith('/rerun') ? { run_id: '20261027-101600-0000' } : RUN) : json({ ...RUN, status: 'running' }));
  vi.stubGlobal('fetch', fetch);
  vi.stubGlobal('WebSocket', FakeWS);
  vi.stubGlobal('confirm', () => true);
  render(<CI id={ID} />);
  expect(await screen.findByText('Secrets exposed: NPM_TOKEN')).toBeTruthy();
  await vi.waitFor(() => expect(FakeWS.all.at(-1)!.url).toMatch(new RegExp(`/api/ci/runs/${ID}/log\\?step=test$`)));
  FakeWS.all.at(-1)!.onmessage!({ data: 'npm ERR! 1 failing\n' });
  expect(await screen.findByText(/1 failing/)).toBeTruthy();
  fireEvent.click(screen.getByText('install'));
  await vi.waitFor(() => expect(FakeWS.all.at(-1)!.url).toMatch(/step=install$/));
  fireEvent.click(screen.getByText('Cancel'));
  await vi.waitFor(() => expect(fetch.mock.calls.some(([u, i]) => u === `/api/ci/runs/${ID}/cancel` && i?.method === 'POST')).toBe(true));
  fireEvent.click(screen.getByText('Re-run'));
  await vi.waitFor(() => expect(location.pathname).toBe('/ci/20261027-101600-0000'));
});
