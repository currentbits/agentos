import { useState } from 'react';
import { api } from '../api';
import type { UpdateLog, UpdateState } from '../types';
import { usePoll } from '../usePoll';
import { ErrorText } from './ErrorText';
import { LogStream } from './LogStream';

// System > Updates: the installed and available AgentOS versions, "Check now", and the existing
// agentos-update action (WebSocket, one run at a time). The release notes are untrusted text from
// the repo: rendered as text, never as HTML. When agentos-web restarts mid-update the stream ends;
// the run goes on, and its log (/api/update/log) is shown until it finishes.
export function UpdateCard() {
  const u = usePoll(() => api<UpdateState>('/api/update'), 30000);
  const log = usePoll(() => api<UpdateLog>('/api/update/log'), 3000);
  const unattended = usePoll(() => api<{ lastUnattended: string | null }>('/api/system/updates'));
  const [streaming, setStreaming] = useState(0);
  const [open, setOpen] = useState(false);
  const [checking, setChecking] = useState(false);
  const [checkError, setCheckError] = useState<string | null>(null);
  const s = u.data;
  const running = open || !!log.data?.running;
  const check = () => {
    setChecking(true);
    setCheckError(null);
    api('/api/update/check', 'POST').then(u.reload, (e: Error) => setCheckError(e.message)).finally(() => setChecking(false));
  };
  return (
    <div className="panel">
      <h2>Updates</h2>
      <ErrorText error={u.error} />
      {s && (
        <>
          <p>
            AgentOS {s.installed ?? 'not installed'}
            {s.available ? <strong> · {s.available} available</strong>
              : s.error ? <span className="bad"> · update check failed: {s.error}</span>
                : <span className="ok"> · up to date</span>}
          </p>
          {s.checked_at && <p className="hint">Last check: {new Date(s.checked_at).toLocaleString()}</p>}
          {s.available && s.notes && <pre className="notes">{s.notes}</pre>}
          {s.available && s.ciActive && s.ciActive.length > 0 && (
            <p className="bad">CI runs in progress: {s.ciActive.join(', ')}. They keep running, but agentos-web restarts during the update.</p>
          )}
        </>
      )}
      <p>Last unattended-upgrades run: {unattended.data?.lastUnattended ? new Date(unattended.data.lastUnattended).toLocaleString() : 'never'}</p>
      <div className="actions">
        <button disabled={checking || running} onClick={check}>Check now</button>
        <button disabled={running} onClick={() => { setOpen(true); setStreaming((n) => n + 1); }}>Run agentos-update</button>
      </div>
      <ErrorText error={checkError} />
      {open ? <LogStream key={streaming} path="/api/system/update" onEnd={() => { setOpen(false); log.reload(); u.reload(); }} />
        : log.data?.text ? (
          <>
            <p className="hint">{log.data.running ? 'agentos-update is running:' : 'Last agentos-update run:'}</p>
            <pre className="log">{log.data.text}</pre>
          </>
        ) : null}
    </div>
  );
}
