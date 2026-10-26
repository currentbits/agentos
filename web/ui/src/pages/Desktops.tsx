import { useEffect, useState } from 'react';
import { api } from '../api';
import { confirmAction } from '../components/Confirm';
import { ErrorText } from '../components/ErrorText';
import { minutes } from '../format';
import { newDesktop } from '../quick';
import { Link } from '../router';
import type { Desktop } from '../types';
import { usePoll } from '../usePoll';

function idleText(d: Desktop): string {
  return d.idleLimitMinutes === 0 ? `idle ${minutes(d.idleSeconds)} (reaper off)` : `idle ${minutes(d.idleSeconds)} of ${d.idleLimitMinutes} min`;
}

export function Desktops() {
  const { data, error, reload } = usePoll(() => api<{ max: number; desktops: Desktop[] }>('/api/desktops'), 5000);
  const [tick, setTick] = useState(Date.now());
  useEffect(() => { const t = setInterval(() => setTick(Date.now()), 5000); return () => clearInterval(t); }, []);
  const destroy = (n: number) =>
    confirmAction(`Destroy desktop ${n}? Everything running on it is killed.`) &&
    api(`/api/desktops/${n}`, 'DELETE').then(reload, (e: Error) => alert(e.message));
  return (
    <section>
      <h1>Desktops <small>{data ? `${data.desktops.length} of ${data.max}` : ''}</small></h1>
      <div className="actions"><button onClick={newDesktop}>New desktop</button></div>
      <ErrorText error={error} />
      <div className="grid">
        {data?.desktops.map((d) => (
          <div className="card desktop" key={d.id}>
            <Link to={`/desktops/${d.id}`}><img src={`/api/desktops/${d.id}/thumbnail?t=${tick}`} alt={`desktop ${d.id}`} width={480} height={270} /></Link>
            <div className="row"><strong>Desktop {d.id}</strong><span>{idleText(d)}</span><span>{d.viewers ? `${d.viewers} viewer(s)` : 'no viewer'}</span></div>
            <div className="row"><Link to={`/desktops/${d.id}`}>Open</Link><button onClick={() => destroy(d.id)}>Destroy</button></div>
          </div>
        ))}
      </div>
    </section>
  );
}
