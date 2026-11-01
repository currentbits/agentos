import { api } from '../api';
import { ErrorText } from '../components/ErrorText';
import { duration } from '../format';
import { Link } from '../router';
import type { Agent } from '../types';
import { usePoll } from '../usePoll';

// Every agent CLI running on the box, however it was started. "Working" = it or its tools used CPU
// in the last half second (a guess: an agent waiting on the model's reply shows as idle).
export function Agents() {
  const { data, error } = usePoll(() => api<Agent[]>('/api/agents'), 5000);
  return (
    <section>
      <h1>Agents</h1>
      <ErrorText error={error} />
      {data && !data.length && <p>No agents running.</p>}
      {!!data?.length && (
        <table>
          <thead><tr><th>CLI</th><th>Status</th><th>Folder</th><th>Started from</th><th>Running for</th><th>PID</th></tr></thead>
          <tbody>
            {data.map((a) => (
              <tr key={a.pid}>
                <td>{a.cli}</td>
                <td className={a.working ? 'ci-passed' : ''}>{a.working ? 'working' : 'idle'} <small>{a.cpuPercent} %</small></td>
                <td><code>{a.dir ?? '-'}</code></td>
                <td>{a.session ? <Link to={`/sessions/${encodeURIComponent(a.session)}`}>{a.origin}: {a.session.replace(/^ag-/, '')}</Link> : a.origin}</td>
                <td>{duration(a.started, null)}</td>
                <td>{a.pid}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  );
}
