import { type FormEvent, useState } from 'react';
import { api } from '../api';
import { navigate } from '../router';
import type { Session } from '../types';
import { DirPicker } from './DirPicker';
import { ErrorText } from './ErrorText';

const CLIS = ['claude', 'codex', 'grok', 'opencode', 'shell'];

export function NewSessionForm() {
  const [cli, setCli] = useState('claude');
  const [mode, setMode] = useState<'dir' | 'repo'>('dir');
  const [dir, setDir] = useState('');   // '' = the agent's home
  const [repo, setRepo] = useState('');
  const [name, setName] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const body = { cli, name: name || undefined, ...(mode === 'dir' ? { dir: dir || undefined } : { repo }) };
      const s = await api<Session>('/api/sessions', 'POST', body);
      navigate(`/sessions/${encodeURIComponent(s.id)}`);
    } catch (err) {
      setError((err as Error).message);
      setBusy(false);
    }
  }

  return (
    <form className="panel" onSubmit={submit}>
      <h2>New session</h2>
      <label>CLI <select value={cli} onChange={(e) => setCli(e.target.value)}>{CLIS.map((c) => <option key={c}>{c}</option>)}</select></label>
      <label>Name <input value={name} onChange={(e) => setName(e.target.value)} placeholder={`${cli}-n`} pattern="[a-z0-9-]{1,32}" /></label>
      <fieldset>
        <label><input type="radio" checked={mode === 'dir'} onChange={() => setMode('dir')} /> Folder</label>
        <label><input type="radio" checked={mode === 'repo'} onChange={() => setMode('repo')} /> Clone repo into ~/work/&lt;name&gt;</label>
      </fieldset>
      {mode === 'dir' ? <DirPicker value={dir} onChange={setDir} />
        : <label>Git URL <input value={repo} onChange={(e) => setRepo(e.target.value)} placeholder="https://github.com/org/repo.git" required /></label>}
      <ErrorText error={error} />
      <button disabled={busy}>{busy ? 'Starting…' : 'Start'}</button>
    </form>
  );
}
