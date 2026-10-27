import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { System } from '../src/pages/System';

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

it('disables "Run agentos-update" while its stream is open', async () => {
  vi.stubGlobal('fetch', vi.fn(async () => new Response('[]', { headers: { 'content-type': 'application/json' } })));
  vi.stubGlobal('WebSocket', FakeWS);
  render(<System me={null} />);
  const run = screen.getByText('Run agentos-update') as HTMLButtonElement;
  expect(run.disabled).toBe(false);
  fireEvent.click(run);
  expect(run.disabled).toBe(true);
  const ws = FakeWS.all.at(-1)!;
  expect(ws.url).toMatch(/\/api\/system\/update$/);
  ws.onclose!({ reason: '' });
  await vi.waitFor(() => expect(run.disabled).toBe(false));
});
