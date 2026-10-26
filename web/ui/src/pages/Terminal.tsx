import { FitAddon } from '@xterm/addon-fit';
import { Terminal as Xterm } from '@xterm/xterm';
import '@xterm/xterm/css/xterm.css';
import { useEffect, useRef, useState } from 'react';
import { wsUrl } from '../api';
import { Link } from '../router';

// Full-page terminal attached to a tmux session. Leaving the page detaches; it never kills.
export function Terminal({ id }: { id: string }) {
  const el = useRef<HTMLDivElement>(null);
  const [status, setStatus] = useState('connecting…');
  useEffect(() => {
    const term = new Xterm({ cursorBlink: true, fontSize: 14, theme: { background: '#0d1117' } });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(el.current!);
    fit.fit();
    const ws = new WebSocket(wsUrl(`/api/sessions/${encodeURIComponent(id)}/terminal?cols=${term.cols}&rows=${term.rows}`));
    ws.onopen = () => setStatus('attached');
    ws.onclose = (e) => setStatus(`closed${e.reason ? `: ${e.reason}` : ''}`);
    ws.onmessage = (e) => term.write(e.data as string);
    const input = term.onData((d) => ws.readyState === WebSocket.OPEN && ws.send(JSON.stringify({ t: 'i', d })));
    const resize = term.onResize(({ cols, rows }) => ws.readyState === WebSocket.OPEN && ws.send(JSON.stringify({ t: 'r', c: cols, r: rows })));
    const onWindowResize = () => fit.fit();
    addEventListener('resize', onWindowResize);
    term.focus();
    return () => {
      removeEventListener('resize', onWindowResize);
      input.dispose();
      resize.dispose();
      ws.close();
      term.dispose();
    };
  }, [id]);
  return (
    <section className="terminal-page">
      <div className="toolbar"><Link to="/sessions">← Sessions</Link><strong>{id}</strong><span>{status}</span></div>
      <div className="term-host" ref={el} />
    </section>
  );
}
