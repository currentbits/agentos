import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { Overview } from '../src/pages/Overview';

afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

const json = (body: unknown) => new Response(JSON.stringify(body), { headers: { 'content-type': 'application/json' } });
const stub = (update: object) => vi.stubGlobal('fetch', vi.fn(async (url: string) =>
  url === '/api/update' ? json(update)
    : url === '/api/system/health' ? json({ cpuPercent: 1, load: [0, 0, 0], memory: { totalBytes: 1, usedBytes: 0 }, disk: { totalBytes: 1, usedBytes: 0 } })
      : url === '/api/desktops' ? json({ desktops: [] }) : url === '/api/system/tailscale' ? json({ state: 'Running', serve: 'ok' }) : json([])));

it('shows the "available" banner with the notes, as plain text, on demand', async () => {
  stub({ installed: '1.0.0', available: '1.1.0', notes: '<img src=x onerror=alert(1)> Faster', error: null, ciActive: [] });
  const { container } = render(<Overview />);
  await screen.findByText('AgentOS 1.1.0 is available');
  expect(screen.queryByText(/Faster/)).toBeNull();
  fireEvent.click(screen.getByText("What's new"));
  expect(screen.getByText('<img src=x onerror=alert(1)> Faster')).toBeTruthy();
  expect(container.querySelector('img')).toBeNull();
});

it('no banner when up to date', async () => {
  stub({ installed: '1.1.0', available: null, notes: '', error: null, ciActive: [] });
  render(<Overview />);
  await screen.findByText('CPU');
  expect(screen.queryByText(/is available/)).toBeNull();
});
