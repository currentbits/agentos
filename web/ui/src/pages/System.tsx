import { useState } from 'react';
import { LogStream } from '../components/LogStream';
import { Power } from '../components/Power';
import { Services } from '../components/Services';
import { UpdateCard } from '../components/UpdateCard';
import { api } from '../api';
import { openTerminal } from '../quick';
import type { LanInfo, Me } from '../types';
import { usePoll } from '../usePoll';

// LAN access (AGENTOS_WEB_LAN): where to point a browser, and the fingerprint to compare with the
// browser's certificate warning.
function LanCard() {
  const { data } = usePoll(() => api<LanInfo>('/api/system/lan'));
  if (!data) return null;
  return (
    <div className="panel">
      <h2>LAN access</h2>
      {data.enabled ? (
        <>
          <p>{data.addresses.map((a) => <code key={a}>https://{a} </code>)}(password of <code>agent</code>)</p>
          <p>Certificate SHA-256: <code className="fingerprint">{data.fingerprint}</code></p>
          <p className="hint">Your browser warns about this self-signed certificate: continue only if it shows this fingerprint.</p>
        </>
      ) : <p>Off. Turn it on in Settings, Web UI.</p>}
    </div>
  );
}

export function System({ me }: { me: Me | null }) {
  const [unit, setUnit] = useState<string | null>(null);
  return (
    <section>
      <h1>System</h1>
      <div className="actions"><button onClick={openTerminal}>Open terminal</button></div>
      <Services onLogs={setUnit} />
      {unit && (
        <div className="panel">
          <h2>Journal: <code>{unit}</code> <button onClick={() => setUnit(null)}>Close</button></h2>
          <LogStream path={`/api/system/journal?unit=${encodeURIComponent(unit)}`} />
        </div>
      )}
      <LanCard />
      <UpdateCard />
      {me && <Power hostname={me.hostname} />}
    </section>
  );
}
