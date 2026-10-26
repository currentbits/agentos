import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { ApiError } from '../src/api';
import { SettingsForm, type FieldSpec } from '../src/components/SettingsForm';

afterEach(cleanup);

const FIELDS: FieldSpec[] = [
  { key: 'AGENTOS_MAX_DESKTOPS', label: 'Max', type: 'number' },
  { key: 'AGENTOS_LAN_SSH', label: 'LAN SSH', type: 'bool' },
];

it('saves only changed fields', async () => {
  const onSave = vi.fn(async () => {});
  render(<SettingsForm title="T" fields={FIELDS} values={{ AGENTOS_MAX_DESKTOPS: '8', AGENTOS_LAN_SSH: '0' }} onSave={onSave} />);
  fireEvent.click(screen.getByLabelText('LAN SSH'));
  fireEvent.click(screen.getByText('Save'));
  await vi.waitFor(() => expect(onSave).toHaveBeenCalledWith({ AGENTOS_LAN_SSH: '1' }));
});

it('shows a validation error next to its field', async () => {
  const onSave = vi.fn(async () => { throw new ApiError(400, 'must be 1-16', 'AGENTOS_MAX_DESKTOPS'); });
  render(<SettingsForm title="T" fields={FIELDS} values={{ AGENTOS_MAX_DESKTOPS: '8' }} onSave={onSave} />);
  fireEvent.change(screen.getByLabelText('Max'), { target: { value: '99' } });
  fireEvent.click(screen.getByText('Save'));
  const alert = await screen.findByRole('alert');
  expect(alert.textContent).toBe('must be 1-16');
  expect(alert.closest('.field')!.textContent).toContain('Max');
});

it('beforeSave can cancel the save', async () => {
  const onSave = vi.fn(async () => {});
  render(<SettingsForm title="T" fields={FIELDS} values={{ AGENTOS_MAX_DESKTOPS: '8' }} onSave={onSave} beforeSave={() => false} />);
  fireEvent.change(screen.getByLabelText('Max'), { target: { value: '4' } });
  fireEvent.click(screen.getByText('Save'));
  await new Promise((r) => setTimeout(r, 20));
  expect(onSave).not.toHaveBeenCalled();
});
