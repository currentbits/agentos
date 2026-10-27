import { useState } from 'react';
import { api } from '../api';
import { LogStream } from '../components/LogStream';
import { Power } from '../components/Power';
import { Services } from '../components/Services';
import { openTerminal } from '../quick';
import type { Me } from '../types';
import { usePoll } from '../usePoll';

export function System({ me }: { me: Me | null }) {
  const [unit, setUnit] = useState<string | null>(null);
  const [updating, setUpdating] = useState(0);
  const [updateOpen, setUpdateOpen] = useState(false);
  const updates = usePoll(() => api<{ lastUnattended: string | null }>('/api/system/updates'));
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
      <div className="panel">
        <h2>Updates</h2>
        <p>Last unattended-upgrades run: {updates.data?.lastUnattended ? new Date(updates.data.lastUnattended).toLocaleString() : 'never'}</p>
        <button disabled={updateOpen} onClick={() => { setUpdateOpen(true); setUpdating((n) => n + 1); }}>Run agentos-update</button>
        {updating > 0 && <LogStream key={updating} path="/api/system/update" onEnd={() => setUpdateOpen(false)} />}
      </div>
      {me && <Power hostname={me.hostname} />}
    </section>
  );
}
