import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { SecretField } from '../src/components/SecretField';

afterEach(cleanup);

it('shows set / not set, never a value, and starts empty', () => {
  const { container, rerender } = render(<SecretField name="K" label="Key" isSet onSave={vi.fn()} />);
  expect(screen.getByText('set')).toBeTruthy();
  const input = container.querySelector('input')!;
  expect(input.type).toBe('password');
  expect(input.value).toBe('');
  rerender(<SecretField name="K" label="Key" isSet={false} onSave={vi.fn()} />);
  expect(screen.getByText('not set')).toBeTruthy();
  expect(screen.queryByText('Clear')).toBeNull();
});

it('saves the typed value, then clears the input', async () => {
  const onSave = vi.fn(async () => {});
  const { container } = render(<SecretField name="K" label="Key" isSet={false} onSave={onSave} />);
  const input = container.querySelector('input')!;
  fireEvent.change(input, { target: { value: 'sk-new' } });
  fireEvent.click(screen.getByText('Save'));
  await vi.waitFor(() => expect(input.value).toBe(''));
  expect(onSave).toHaveBeenCalledWith('K', 'sk-new');
});

it('Clear sends an empty value', async () => {
  const onSave = vi.fn(async () => {});
  render(<SecretField name="K" label="Key" isSet onSave={onSave} />);
  fireEvent.click(screen.getByText('Clear'));
  await vi.waitFor(() => expect(onSave).toHaveBeenCalledWith('K', ''));
});

it('shows a save error', async () => {
  const onSave = vi.fn(async () => { throw new Error('rejected'); });
  const { container } = render(<SecretField name="K" label="Key" onSave={onSave} />);
  fireEvent.change(container.querySelector('input')!, { target: { value: 'x' } });
  fireEvent.click(screen.getByText('Save'));
  expect((await screen.findByRole('alert')).textContent).toBe('rejected');
});
