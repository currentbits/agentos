import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { NewSessionForm } from '../src/components/NewSessionForm';

afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

function stubApi(created: unknown, status = 201) {
  const fetch = vi.fn(async (url: string, init?: RequestInit) =>
    url.startsWith('/api/dirs') ? json({ path: '/home/agent', parent: null, dirs: ['proj'] })
      : init?.method === 'POST' ? json(created, status) : json({}));
  vi.stubGlobal('fetch', fetch);
  return fetch;
}
const posted = (fetch: ReturnType<typeof stubApi>) => JSON.parse(fetch.mock.calls.find(([, i]) => i?.method === 'POST')![1]!.body as string);

it('starts a session in a folder picked from the tree, then opens its terminal', async () => {
  const fetch = stubApi({ id: 'ag-x' });
  render(<NewSessionForm />);
  fireEvent.change(screen.getByLabelText('CLI'), { target: { value: 'codex' } });
  fireEvent.change(screen.getByRole('textbox', { name: 'Name' }), { target: { value: 'x' } });
  fireEvent.click(await screen.findByText('proj/'));
  fireEvent.click(screen.getByText('Start'));
  await vi.waitFor(() => expect(location.pathname).toBe('/sessions/ag-x'));
  expect(posted(fetch)).toEqual({ cli: 'codex', name: 'x', dir: '/home/agent/proj' });
});

it('clones a repo instead of picking a folder, and shows server errors', async () => {
  const fetch = stubApi({ error: 'git clone failed: not found' }, 400);
  render(<NewSessionForm />);
  fireEvent.click(screen.getByLabelText(/Clone repo/));
  fireEvent.change(screen.getByLabelText('Git URL'), { target: { value: 'https://github.com/o/r.git' } });
  fireEvent.click(screen.getByText('Start'));
  expect((await screen.findByRole('alert')).textContent).toBe('git clone failed: not found');
  expect(posted(fetch)).toEqual({ cli: 'claude', repo: 'https://github.com/o/r.git' });
});
