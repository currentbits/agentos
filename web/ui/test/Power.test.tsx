import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { Power } from '../src/components/Power';

afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

it('enables Reboot and Power off only once the hostname is typed, and sends it as confirmation', async () => {
  const fetch = vi.fn(async () => new Response('{"ok":true}', { headers: { 'content-type': 'application/json' } }));
  vi.stubGlobal('fetch', fetch);
  render(<Power hostname="box1" />);
  const reboot = screen.getByText('Reboot') as HTMLButtonElement;
  expect(reboot.disabled).toBe(true);
  expect((screen.getByText('Power off') as HTMLButtonElement).disabled).toBe(true);
  fireEvent.change(screen.getByRole('textbox'), { target: { value: 'box' } });
  expect(reboot.disabled).toBe(true);
  fireEvent.change(screen.getByRole('textbox'), { target: { value: 'box1' } });
  fireEvent.click(reboot);
  await vi.waitFor(() => expect(fetch).toHaveBeenCalled());
  expect(fetch.mock.calls[0]).toEqual(['/api/system/power', expect.objectContaining({ method: 'POST', body: '{"action":"reboot","confirm":"box1"}' })]);
});
