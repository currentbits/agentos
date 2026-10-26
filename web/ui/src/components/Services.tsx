import { api } from '../api';
import type { Unit } from '../types';
import { usePoll } from '../usePoll';
import { confirmAction } from './Confirm';
import { ErrorText } from './ErrorText';

export function Services({ onLogs }: { onLogs: (unit: string) => void }) {
  const { data, error, reload } = usePoll(() => api<Unit[]>('/api/system/services'), 10000);
  const restart = (u: string) =>
    confirmAction(`Restart ${u}?`) && api(`/api/system/services/${encodeURIComponent(u)}/restart`, 'POST').then(reload, (e: Error) => alert(e.message));
  return (
    <div className="panel">
      <h2>Services</h2>
      <ErrorText error={error} />
      <table>
        <tbody>
          {data?.map((u) => (
            <tr key={u.unit}>
              <td><code>{u.unit}</code></td>
              <td className={u.active === 'active' ? 'ok' : u.active === 'failed' ? 'bad' : ''}>{u.active} ({u.sub})</td>
              <td>{u.description}</td>
              <td><button onClick={() => onLogs(u.unit)}>Logs</button> <button onClick={() => restart(u.unit)}>Restart</button></td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
