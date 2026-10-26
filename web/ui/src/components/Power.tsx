import { useState } from 'react';
import { api } from '../api';
import { ErrorText } from './ErrorText';

// Reboot / power off: enabled only once the hostname is typed (the server checks it again).
export function Power({ hostname }: { hostname: string }) {
  const [typed, setTyped] = useState('');
  const [error, setError] = useState<string | null>(null);
  const go = (action: string) => api('/api/system/power', 'POST', { action, confirm: typed }).then(
    () => setError(`${action} requested`), (e: Error) => setError(e.message));
  const ok = typed === hostname;
  return (
    <div className="panel">
      <h2>Power</h2>
      <label>Type <code>{hostname}</code> to confirm <input value={typed} onChange={(e) => setTyped(e.target.value)} /></label>
      <button disabled={!ok} onClick={() => go('reboot')}>Reboot</button>
      <button disabled={!ok} onClick={() => go('poweroff')}>Power off</button>
      <ErrorText error={error} />
    </div>
  );
}
