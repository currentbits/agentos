import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { System } from '../src/pages/System';
import type { UpdateLog, UpdateState } from '../src/types';

afterEach(() => { cleanup(); vi.unstubAllGlobals(); });
HTMLElement.prototype.scrollTo = () => {};   // jsdom has no layout

// A fake WebSocket: the test ends the stream by calling onclose itself.
class FakeWS {
  static all: FakeWS[] = [];
  onmessage: ((e: { data: string }) => void) | null = null;
  onclose: ((e: { reason: string }) => void) | null = null;
  constructor(public url: string) { FakeWS.all.push(this); }
  close() {}
}

const json = (body: unknown) => new Response(JSON.stringify(body), { headers: { 'content-type': 'application/json' } });
const STATE: UpdateState = { installed: '1.0.0', available: '1.1.0', notes_url: 'https://o.github.io/r/apt/notes/1.1.0.md',
  notes: '<b>Faster</b> updates', checked_at: '2026-10-29T03:12:00Z', error: null, running: false, ciActive: [] };
// Routes the page's GETs; after a POST to /api/update/check, /api/update returns `after` (the
// server's check rewrote update.json).
function stubFetch(state: UpdateState, log: UpdateLog = { running: false, text: '' }, after = state) {
  const f = vi.fn(async (url: string, _init?: RequestInit) => {
    if (url === '/api/update/check') { state = after; return json(after); }
    if (url === '/api/update') return json(state);
    if (url === '/api/update/log') return json(log);
    if (url === '/api/system/updates') return json({ lastUnattended: null });
    return json([]);
  });
  vi.stubGlobal('fetch', f);
  return f;
}

it('disables "Run agentos-update" while its stream is open', async () => {
  stubFetch({ ...STATE, available: null });
  vi.stubGlobal('WebSocket', FakeWS);
  render(<System me={null} />);
  const run = screen.getByText('Run agentos-update') as HTMLButtonElement;
  await screen.findByText(/up to date/);
  expect(run.disabled).toBe(false);
  fireEvent.click(run);
  expect(run.disabled).toBe(true);
  const ws = FakeWS.all.at(-1)!;
  expect(ws.url).toMatch(/\/api\/system\/update$/);
  ws.onclose!({ reason: '' });
  await vi.waitFor(() => expect(run.disabled).toBe(false));
});

it('shows the versions, the notes as plain text and the CI warning; "Check now" posts and re-reads', async () => {
  const f = stubFetch({ ...STATE, ciActive: ['20261029-101500-0001'] }, undefined, { ...STATE, available: null, checked_at: '2026-10-29T09:00:00Z' });
  const { container } = render(<System me={null} />);
  await screen.findByText(/1\.1\.0 available/);
  expect(screen.getByText('AgentOS 1.0.0', { exact: false })).toBeTruthy();
  expect(screen.getByText('<b>Faster</b> updates')).toBeTruthy();
  expect(container.querySelector('.notes b')).toBeNull();
  expect(screen.getByText(/CI runs in progress: 20261029-101500-0001/)).toBeTruthy();
  fireEvent.click(screen.getByText('Check now'));
  await screen.findByText(/up to date/);
  const post = f.mock.calls.find(([u]) => u === '/api/update/check')!;
  expect(post[1]).toMatchObject({ method: 'POST', headers: { 'X-AgentOS': '1' } });
});

it('shows a failed check as a warning, never as "up to date"', async () => {
  stubFetch({ ...STATE, available: null, error: 'Failed to fetch https://o.github.io/r/apt/dists/stable/InRelease  Missing key 0123ABCD' });
  render(<System me={null} />);
  await screen.findByText(/update check failed: Failed to fetch .* Missing key 0123ABCD/);
  expect(screen.queryByText(/up to date/)).toBeNull();
});

it('after agentos-web restarted mid-update: shows the running update\'s log and keeps the buttons off', async () => {
  stubFetch({ ...STATE, running: true }, { running: true, text: 'ok    agentos\n' });
  render(<System me={null} />);
  await screen.findByText('agentos-update is running:');
  expect(screen.getByText(/ok\s+agentos/)).toBeTruthy();
  expect((screen.getByText('Run agentos-update') as HTMLButtonElement).disabled).toBe(true);
  expect((screen.getByText('Check now') as HTMLButtonElement).disabled).toBe(true);
});
