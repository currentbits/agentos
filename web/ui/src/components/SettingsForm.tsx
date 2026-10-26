import { type FormEvent, useState } from 'react';
import { ApiError } from '../api';
import { ErrorText } from './ErrorText';

export interface FieldSpec { key: string; label: string; type: 'text' | 'number' | 'bool' | 'select'; options?: string[] }

// A form for plain (non-secret) settings. Saves only changed fields; agentos-config's validation
// error is shown next to the field it names.
export function SettingsForm({ title, fields, values, onSave, beforeSave }: {
  title: string; fields: FieldSpec[]; values: Record<string, string>;
  onSave: (changed: Record<string, string>) => Promise<void>;
  beforeSave?: (changed: Record<string, string>) => boolean;
}) {
  const [draft, setDraft] = useState<Record<string, string>>(values);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const set = (k: string, v: string) => setDraft((d) => ({ ...d, [k]: v }));

  async function submit(e: FormEvent) {
    e.preventDefault();
    const changed = Object.fromEntries(fields.filter((f) => (draft[f.key] ?? '') !== (values[f.key] ?? '')).map((f) => [f.key, draft[f.key] ?? '']));
    if (Object.keys(changed).length === 0 || (beforeSave && !beforeSave(changed))) return;
    setBusy(true);
    setErrors({});
    setError(null);
    try {
      await onSave(changed);
    } catch (err) {
      if (err instanceof ApiError && err.field) setErrors({ [err.field]: err.message });
      else setError((err as Error).message);
    }
    setBusy(false);
  }

  return (
    <form className="panel" onSubmit={submit}>
      <h2>{title}</h2>
      {fields.map((f) => (
        <div className="field" key={f.key}>
          <label>
            {f.label}{' '}
            {f.type === 'bool' ? <input type="checkbox" checked={draft[f.key] === '1'} onChange={(e) => set(f.key, e.target.checked ? '1' : '0')} />
              : f.type === 'select' ? <select value={draft[f.key] ?? ''} onChange={(e) => set(f.key, e.target.value)}>{f.options!.map((o) => <option key={o} value={o}>{o || '(default)'}</option>)}</select>
              : <input type={f.type} value={draft[f.key] ?? ''} placeholder="(default)" onChange={(e) => set(f.key, e.target.value)} />}
          </label>
          <ErrorText error={errors[f.key]} />
        </div>
      ))}
      <ErrorText error={error} />
      <button disabled={busy}>{busy ? 'Saving and applying…' : 'Save'}</button>
    </form>
  );
}
