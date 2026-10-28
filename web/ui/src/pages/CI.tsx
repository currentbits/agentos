import { type FormEvent, useState } from 'react';
import { api } from '../api';
import { confirmAction } from '../components/Confirm';
import { Copy } from '../components/Copy';
import { DirPicker } from '../components/DirPicker';
import { ErrorText } from '../components/ErrorText';
import { LogStream } from '../components/LogStream';
import { duration, FINAL_CI } from '../format';
import { Link, navigate } from '../router';
import type { CiRemote, CiRun } from '../types';
import { usePoll } from '../usePoll';

export function CI({ id }: { id?: string }) {
  return id ? <RunView id={id} /> : <Runs />;
}

function Runs() {
  const runs = usePoll(() => api<CiRun[]>('/api/ci/runs?limit=50'), 5000);
  const remotes = usePoll(() => api<CiRemote[]>('/api/ci/remotes'));
  const [path, setPath] = useState('');
  const [ref, setRef] = useState('HEAD');
  const [err, setErr] = useState<string | null>(null);

  async function run(e: FormEvent) {
    e.preventDefault();
    setErr(null);
    try {
      navigate(`/ci/${(await api<{ run_id: string }>('/api/ci/runs', 'POST', { path, ref })).run_id}`);
    } catch (e2) {
      setErr((e2 as Error).message);
    }
  }

  return (
    <section>
      <h1>CI</h1>
      <ErrorText error={runs.error} />
      <table>
        <thead><tr><th>Run</th><th>Repo</th><th>Ref</th><th>Commit</th><th>Status</th><th>Duration</th></tr></thead>
        <tbody>
          {runs.data?.map((r) => (
            <tr key={r.id}>
              <td><Link to={`/ci/${r.id}`}>{r.id}</Link></td>
              <td>{r.repo.replace(/^\/home\/agent\//, '~/')}</td>
              <td>{r.ref}</td>
              <td><code>{r.commit.slice(0, 10)}</code></td>
              <td className={`ci-${r.status}`}>{r.status}</td>
              <td>{duration(r.started, r.finished)}</td>
            </tr>
          ))}
        </tbody>
      </table>
      {runs.data?.length === 0 && <p className="hint">No runs yet.</p>}
      <form className="panel" onSubmit={run}>
        <h2>Run CI</h2>
        <DirPicker value={path} onChange={setPath} />
        <label>Ref <input value={ref} onChange={(e) => setRef(e.target.value)} aria-label="Ref" /></label>
        <ErrorText error={err} />
        <button disabled={!path}>Run CI</button>
      </form>
      <div className="panel">
        <h2>Push remotes</h2>
        <p className="hint">Each push to one of these runs CI for every pushed branch. Create one with <code>agentos-ci remote create NAME</code>.</p>
        {remotes.data?.map((r) => <Copy key={r.name} label={r.name} text={r.remote_add} />)}
        {remotes.data?.length === 0 && <p className="hint">None yet.</p>}
      </div>
    </section>
  );
}

function RunView({ id }: { id: string }) {
  const { data: run, error, reload } = usePoll(() => api<CiRun>(`/api/ci/runs/${encodeURIComponent(id)}`), 2000, [id]);
  const [picked, setPicked] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const final = !!run && FINAL_CI.includes(run.status);
  const step = picked ?? run?.steps.find((s) => s.status === 'failed' || s.status === 'cancelled')?.name
    ?? run?.steps.filter((s) => s.status !== 'pending' && s.status !== 'skipped').at(-1)?.name ?? null;
  const act = (p: Promise<unknown>) => p.then(reload, (e: Error) => setErr(e.message));
  return (
    <section>
      <h1><Link to="/ci">CI</Link> / {id}</h1>
      <ErrorText error={error ?? err} />
      {run && (
        <>
          <p><span className={`ci-${run.status}`}>{run.status}</span> · {run.repo} · {run.ref} · <code>{run.commit.slice(0, 12)}</code> · {run.pipeline ?? '…'}
            {run.image && <> · image <code>{run.image}</code></>} · {duration(run.started, run.finished)}</p>
          {run.secrets.length > 0 && <p className="hint">Secrets exposed: {run.secrets.join(', ')}{run.missing_secrets.length > 0 && ` (not set: ${run.missing_secrets.join(', ')})`}</p>}
          {run.error && <p className="error">{run.error}</p>}
          <div className="actions">
            <button onClick={() => act(api<{ run_id: string }>(`/api/ci/runs/${id}/rerun`, 'POST').then((r) => navigate(`/ci/${r.run_id}`)))}>Re-run</button>
            <button disabled={final} onClick={() => confirmAction(`Cancel run ${id}?`) && act(api(`/api/ci/runs/${id}/cancel`, 'POST'))}>Cancel</button>
          </div>
          <table><tbody>
            {run.steps.map((s) => (
              <tr key={s.name}>
                <td><button className={s.name === step ? 'active' : ''} onClick={() => setPicked(s.name)}>{s.name}</button></td>
                <td className={`ci-${s.status}`}>{s.status}{s.exit_code ? ` (exit ${s.exit_code})` : ''}</td>
                <td>{duration(s.started, s.finished)}</td>
              </tr>
            ))}
          </tbody></table>
          {step && <LogStream key={`${step}:${final}`} path={`/api/ci/runs/${encodeURIComponent(id)}/log?step=${encodeURIComponent(step)}`} />}
        </>
      )}
    </section>
  );
}
