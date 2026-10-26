import { useState } from 'react';
import { api } from '../api';
import type { SshKey } from '../types';
import { usePoll } from '../usePoll';
import { confirmAction } from './Confirm';
import { ErrorText } from './ErrorText';

export function SshKeys() {
  const { data, error, reload } = usePoll(() => api<SshKey[]>('/api/ssh-keys'));
  const [key, setKey] = useState('');
  const [user, setUser] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const run = (p: Promise<unknown>, clear: () => void) => p.then(() => { clear(); setErr(null); reload(); }, (e: Error) => setErr(e.message));
  return (
    <div className="panel">
      <h2>SSH keys</h2>
      <ErrorText error={error} />
      <ul className="keys">
        {data?.map((k) => (
          <li key={k.fingerprint}>
            <code>{k.fingerprint}</code> {k.type} {k.comment}{' '}
            <button onClick={() => confirmAction(`Remove ${k.comment || k.fingerprint}?`) && run(api('/api/ssh-keys/remove', 'POST', { fingerprint: k.fingerprint }), () => {})}>Remove</button>
          </li>
        ))}
      </ul>
      <div className="field"><input value={key} onChange={(e) => setKey(e.target.value)} placeholder="ssh-ed25519 AAAA… you@laptop" />
        <button disabled={!key} onClick={() => run(api('/api/ssh-keys', 'POST', { key }), () => setKey(''))}>Add</button></div>
      <div className="field"><input value={user} onChange={(e) => setUser(e.target.value)} placeholder="GitHub username" />
        <button disabled={!user} onClick={() => run(api('/api/ssh-keys/github', 'POST', { user }), () => setUser(''))}>Import from GitHub</button></div>
      <ErrorText error={err} />
    </div>
  );
}
