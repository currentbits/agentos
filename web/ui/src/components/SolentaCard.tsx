import { type FormEvent, useState } from 'react';
import { api } from '../api';
import type { SolentaStatus } from '../types';
import { usePoll } from '../usePoll';
import { Copy } from './Copy';
import { DirPicker } from './DirPicker';
import { ErrorText } from './ErrorText';

// Solenta pairing: Mode A (Solenta on this box, recommended) first, then Mode B (Solenta on the
// Mac, agents here). Facts come from solenta-pair; nothing here ever shows a Solenta token.
export function SolentaCard() {
  const [path, setPath] = useState('');
  const [repo, setRepo] = useState('');
  const [name, setName] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const st = usePoll(() => api<SolentaStatus>(`/api/solenta${path ? `?path=${encodeURIComponent(path)}` : ''}`), 0, [path]);
  const s = st.data;

  async function clone(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setErr(null);
    try {
      setPath((await api<{ path: string }>('/api/solenta/clone', 'POST', { repo, name })).path);
      setRepo('');
    } catch (e2) {
      setErr((e2 as Error).message);
    }
    setBusy(false);
  }

  return (
    <div className="panel">
      <h2>Solenta</h2>
      <ErrorText error={st.error} />
      {s && (
        <>
          <h3>Mode A: Solenta on this box (recommended)</h3>
          <p className="hint">In Solenta, open Settings, Connections, Remote Connections, and add <code>{s.remoteHost}</code>. Solenta installs itself here over SSH; AgentOS keeps it running.</p>
          <p>agentos-solenta: <span className={s.modeA.service === 'active' ? 'ok' : ''}>{s.modeA.service}</span>
            {s.modeA.enabled ? '' : ' (turned off below)'} · Solenta {s.modeA.version ?? 'not installed yet'} ·
            web token {s.modeA.webToken ? 'present' : 'absent'}</p>

          <h3>SSH from the Mac</h3>
          <p>{s.tailscaleSsh ? 'Tailscale SSH is on: your tailnet policy decides who may connect.'
            : 'Add the Mac’s public key under SSH keys above.'}</p>
          <p className="hint">Solenta refuses hosts that aren't in the Mac's known_hosts. Compare these fingerprints with what <code>ssh {s.remoteHost}</code> shows, then run the line below on the Mac.</p>
          <ul className="keys">{s.hostKeys.map((k) => <li key={k.fingerprint}><code>{k.type} {k.fingerprint}</code></li>)}</ul>
          <Copy text={s.keyscan} />

          <h3>Mode B: Solenta on the Mac, agents here</h3>
          <form className="field" onSubmit={clone}>
            <input value={repo} onChange={(e) => setRepo(e.target.value)} placeholder="https://github.com/org/repo.git" aria-label="Git URL" required />
            <input value={name} onChange={(e) => setName(e.target.value)} placeholder="name" aria-label="Name" pattern="[a-z0-9-]{1,32}" required />
            <button disabled={busy}>{busy ? 'Cloning…' : 'Clone into ~/work'}</button>
          </form>
          <ErrorText error={err} />
          <p className="hint">Or pick an existing checkout:</p>
          <DirPicker value={path} onChange={setPath} />
          <Copy label="remoteHost" text={s.remoteHost} />
          {s.remotePath && <Copy label="remotePath" text={s.remotePath} />}
          <h3>Preflight</h3>
          <table><tbody>
            {s.preflight.map((p) => (
              <tr key={p.item}><td className={p.ok ? 'ok' : 'bad'}>{p.ok ? 'PASS' : 'FAIL'}</td><td>{p.item}</td><td><code>{p.detail}</code></td></tr>
            ))}
          </tbody></table>
          <p>For Solenta's thread and memory tools, run the <a href="/api/solenta/bridge" download>solenta-bridge</a> on the Mac:
            {' '}<code>bash solenta-bridge install {s.remoteHost}</code></p>
          <p className="hint">Security: the bridge exposes Solenta's MCP ports only on this box's loopback, and they still need Solenta's bearer token. Solenta gives that token to the agents it runs here, so they get the same power over Solenta on the Mac that a local Solenta run has.</p>
        </>
      )}
    </div>
  );
}
