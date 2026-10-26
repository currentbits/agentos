import { api } from '../api';
import { confirmAction } from '../components/Confirm';
import { ErrorText } from '../components/ErrorText';
import { NewSessionForm } from '../components/NewSessionForm';
import { Link } from '../router';
import type { Session } from '../types';
import { usePoll } from '../usePoll';

export function Sessions() {
  const { data, error, reload } = usePoll(() => api<Session[]>('/api/sessions'), 5000);
  const act = (path: string, method: string) => api(path, method).then(reload, (e: Error) => alert(e.message));
  return (
    <section>
      <h1>Sessions</h1>
      <NewSessionForm />
      <ErrorText error={error} />
      <table>
        <thead><tr><th>Name</th><th>CLI</th><th>Directory</th><th>Created</th><th>Viewers</th><th>State</th><th /></tr></thead>
        <tbody>
          {data?.map((s) => (
            <tr key={s.id}>
              <td>{s.state === 'running' ? <Link to={`/sessions/${encodeURIComponent(s.id)}`}>{s.name}</Link> : s.name}</td>
              <td>{s.cli ?? '-'}</td>
              <td><code>{s.dir ?? '-'}</code></td>
              <td>{s.created ? new Date(s.created).toLocaleString() : '-'}</td>
              <td>{s.attached}</td>
              <td>{s.external ? 'external' : s.state}</td>
              <td>
                {s.state === 'running'
                  ? <button onClick={() => confirmAction(`Stop ${s.name}? Its processes are killed.`) && act(`/api/sessions/${encodeURIComponent(s.id)}/stop`, 'POST')}>Stop</button>
                  : <button onClick={() => act(`/api/sessions/${encodeURIComponent(s.id)}`, 'DELETE')}>Remove</button>}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
}
