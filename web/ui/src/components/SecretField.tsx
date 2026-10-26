import { useState } from 'react';
import { ErrorText } from './ErrorText';

// Write-only: the current value is never shown (the server never sends it). Shows set / not set,
// sends a new value on Save, and "" on Clear.
export function SecretField({ name, label, isSet, onSave }: {
  name: string; label: string; isSet?: boolean; onSave: (key: string, value: string) => Promise<void>;
}) {
  const [value, setValue] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const save = async (v: string) => {
    setBusy(true);
    setError(null);
    try {
      await onSave(name, v);
      setValue('');
    } catch (e) {
      setError((e as Error).message);
    }
    setBusy(false);
  };
  return (
    <div className="field">
      <label>
        {label}{' '}
        {isSet !== undefined && <span className={isSet ? 'badge ok' : 'badge'}>{isSet ? 'set' : 'not set'}</span>}
        <input type="password" autoComplete="off" value={value} placeholder={isSet ? '•••••• (enter to replace)' : ''} onChange={(e) => setValue(e.target.value)} />
      </label>
      <button disabled={busy || !value} onClick={() => save(value)}>Save</button>
      {isSet && <button disabled={busy} onClick={() => save('')}>Clear</button>}
      <ErrorText error={error} />
    </div>
  );
}
