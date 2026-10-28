import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { Settings } from '../src/pages/Settings';

afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

it('reloads settings after a failed save too (keys before the failure may have been written)', async () => {
  const fetch = vi.fn(async (url: string, init?: RequestInit) => {
    if (url === '/api/settings' && init?.method === 'PUT') return json({ error: 'bad key', field: 'ANTHROPIC_API_KEY' }, 400);
    if (url === '/api/settings') return json({ values: {}, secrets: { ANTHROPIC_API_KEY: false } });
    if (url.startsWith('/api/solenta')) return json({ host: 'b', remoteHost: 'agent@b', remotePath: null, tailscaleSsh: true, hostKeys: [], keyscan: '',
      modeA: { enabled: true, service: 'inactive', version: null, webToken: false }, preflight: [] });
    if (url.startsWith('/api/dirs')) return json({ path: '/home/agent', parent: null, dirs: [] });
    return json(url === '/api/system/tailscale' ? { state: 'Running', dnsName: null, ip: null, serve: 'ok' } : []);
  });
  vi.stubGlobal('fetch', fetch);
  render(<Settings me={null} />);
  const gets = () => fetch.mock.calls.filter(([u, i]) => u === '/api/settings' && i?.method === 'GET').length;
  const input = await screen.findByLabelText(/Anthropic API key/);
  expect(gets()).toBe(1);
  fireEvent.change(input, { target: { value: 'sk-x' } });
  fireEvent.click(input.closest('.field')!.querySelector('button')!);
  await screen.findByText('bad key');
  await vi.waitFor(() => expect(gets()).toBe(2));
});
