import { useState } from 'react';
import { LogStream } from '../components/LogStream';
import { Power } from '../components/Power';
import { Services } from '../components/Services';
import { UpdateCard } from '../components/UpdateCard';
import { openTerminal } from '../quick';
import type { Me } from '../types';

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
      <UpdateCard />
      {me && <Power hostname={me.hostname} />}
    </section>
  );
}
