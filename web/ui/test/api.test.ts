import { afterEach, expect, it, vi } from 'vitest';
import { api, ApiError } from '../src/api';

afterEach(() => vi.unstubAllGlobals());

function stubFetch(status: number, body: unknown) {
  const fetch = vi.fn(async () => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } }));
  vi.stubGlobal('fetch', fetch);
  return fetch;
}

it('sends X-AgentOS: 1 and JSON on mutating requests, nothing extra on GET', async () => {
  const fetch = stubFetch(200, { ok: true });
  await api('/api/x', 'POST', { a: 1 });
  expect(fetch).toHaveBeenLastCalledWith('/api/x', { method: 'POST', headers: { 'X-AgentOS': '1', 'Content-Type': 'application/json' }, body: '{"a":1}' });
  await api('/api/x', 'DELETE');
  expect(fetch).toHaveBeenLastCalledWith('/api/x', { method: 'DELETE', headers: { 'X-AgentOS': '1' }, body: undefined });
  await api('/api/x');
  expect(fetch).toHaveBeenLastCalledWith('/api/x', { method: 'GET', headers: {}, body: undefined });
});

it('turns an error body into an ApiError with the field', async () => {
  stubFetch(400, { error: 'must be 1-16', field: 'AGENTOS_MAX_DESKTOPS' });
  await expect(api('/api/settings', 'PUT', {})).rejects.toEqual(new ApiError(400, 'must be 1-16', 'AGENTOS_MAX_DESKTOPS'));
});
