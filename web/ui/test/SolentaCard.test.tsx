import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { SolentaCard } from '../src/components/SolentaCard';

afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
const FP = 'SHA256:' + 'k'.repeat(43);
const status = (path: string | null) => ({
  host: 'box.tail.ts.net', remoteHost: 'agent@box.tail.ts.net', remotePath: path, tailscaleSsh: false,
  hostKeys: [{ type: 'ssh-ed25519', fingerprint: FP }],
  keyscan: 'ssh-keyscan -t ed25519 box.tail.ts.net >> ~/.ssh/known_hosts',
  modeA: { enabled: true, service: 'active', version: '0.27.0', webToken: true },
  preflight: [{ item: 'claude', ok: true, detail: '/home/agent/.local/bin/claude' }, { item: 'grok', ok: false, detail: 'agentos: grok is not installed for user agent' }],
});

it('shows Mode A first, fingerprints and the keyscan line, then clones and re-runs the preflight for the checkout', async () => {
  const fetch = vi.fn(async (url: string, init?: RequestInit) => {
    if (url === '/api/solenta/clone') return json({ path: '/home/agent/work/app' }, 201);
    if (url.startsWith('/api/solenta')) return json(status(url.includes('path=') ? decodeURIComponent(url.split('path=')[1]) : null));
    return json({ path: '/home/agent', parent: null, dirs: [] });
  });
  vi.stubGlobal('fetch', fetch);
  render(<SolentaCard />);
  const modeA = await screen.findByText('Mode A: Solenta on this box (recommended)');
  expect(modeA.compareDocumentPosition(screen.getByText('Mode B: Solenta on the Mac, agents here')) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  expect(screen.getByText(`ssh-ed25519 ${FP}`)).toBeTruthy();
  expect(screen.getByText('ssh-keyscan -t ed25519 box.tail.ts.net >> ~/.ssh/known_hosts')).toBeTruthy();
  expect(screen.getByText('FAIL')).toBeTruthy();
  expect(document.body.textContent).toContain('web token present');
  fireEvent.change(screen.getByLabelText('Git URL'), { target: { value: 'https://example.com/app.git' } });
  fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'app' } });
  fireEvent.click(screen.getByText('Clone into ~/work'));
  expect(await screen.findByText('/home/agent/work/app')).toBeTruthy();
  expect(fetch.mock.calls.some(([u]) => u === `/api/solenta?path=${encodeURIComponent('/home/agent/work/app')}`)).toBe(true);
  expect(JSON.parse(fetch.mock.calls.find(([u]) => u === '/api/solenta/clone')![1]!.body as string)).toEqual({ repo: 'https://example.com/app.git', name: 'app' });
});
