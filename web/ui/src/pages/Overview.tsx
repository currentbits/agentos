import { api } from '../api';
import { ErrorText } from '../components/ErrorText';
import { duration, gib, pct } from '../format';
import { newDesktop, openTerminal } from '../quick';
import { Link, navigate } from '../router';
import type { CiRun, Desktop, Health, Session, Tailscale } from '../types';
import { usePoll } from '../usePoll';

export function Overview() {
  const health = usePoll(() => api<Health>('/api/system/health'), 5000);
  const sessions = usePoll(() => api<Session[]>('/api/sessions'), 5000);
  const desktops = usePoll(() => api<{ desktops: Desktop[] }>('/api/desktops'), 5000);
  const ts = usePoll(() => api<Tailscale>('/api/system/tailscale'), 30000);
  const ci = usePoll(() => api<CiRun[]>('/api/ci/runs?limit=1'), 10000);
  const last = ci.data?.[0];
  const h = health.data;
  return (
    <section>
      <h1>Overview</h1>
      <ErrorText error={health.error} />
      {h && (
        <div className="cards">
          <div className="card"><h3>CPU</h3><p>{h.cpuPercent} %</p><small>load {h.load.map((l) => l.toFixed(2)).join(' ')}</small></div>
          <div className="card"><h3>Memory</h3><p>{pct(h.memory.usedBytes, h.memory.totalBytes)} %</p><small>{gib(h.memory.usedBytes)} of {gib(h.memory.totalBytes)}</small></div>
          <div className="card"><h3>Disk</h3><p>{pct(h.disk.usedBytes, h.disk.totalBytes)} %</p><small>{gib(h.disk.usedBytes)} of {gib(h.disk.totalBytes)}</small></div>
          <div className="card"><h3>Sessions</h3><p>{sessions.data?.filter((s) => s.state === 'running').length ?? '…'}</p></div>
          <div className="card"><h3>Desktops</h3><p>{desktops.data?.desktops.length ?? '…'}</p></div>
          <div className="card"><h3>CI</h3>
            {last ? <><p className={`ci-${last.status}`}><Link to={`/ci/${last.id}`}>{last.status}</Link></p>
              <small>{last.repo.split('/').pop()} {last.ref} · {duration(last.started, last.finished)}</small></>
              : <p>{ci.data ? 'no runs' : '…'}</p>}
          </div>
          <div className="card"><h3>Tailscale</h3><p>{ts.data?.state ?? '…'}</p><small>serve: {ts.data?.serve ?? '…'}</small></div>
        </div>
      )}
      <div className="actions">
        <button onClick={() => navigate('/sessions')}>New session</button>
        <button onClick={newDesktop}>New desktop</button>
        <button onClick={openTerminal}>Open terminal</button>
      </div>
    </section>
  );
}
