import { useEffect, useRef, useState } from 'react';
import { wsUrl } from '../api';
import { Link } from '../router';

// The subset of noVNC's RFB class we use. The module is loaded at runtime from the Debian novnc
// package (served at /novnc/), so it is not bundled and gets Debian's security updates.
interface Rfb {
  viewOnly: boolean;
  scaleViewport: boolean;
  disconnect(): void;
  addEventListener(type: 'connect' | 'disconnect', fn: (e: Event) => void): void;
}
type RfbClass = new (target: HTMLElement, url: string, options?: { wsProtocols?: string[] }) => Rfb;
const RFB_URL = '/novnc/core/rfb.js';

export function DesktopView({ n }: { n: number }) {
  const el = useRef<HTMLDivElement>(null);
  const rfb = useRef<Rfb | null>(null);
  const [control, setControl] = useState(false);
  const [status, setStatus] = useState('connecting…');
  useEffect(() => {
    let alive = true;
    import(/* @vite-ignore */ RFB_URL).then((m: { default: RfbClass }) => {
      if (!alive) return;
      const r = new m.default(el.current!, wsUrl(`/api/desktops/${n}/vnc`), { wsProtocols: ['binary'] });
      r.viewOnly = true;
      r.scaleViewport = true;
      r.addEventListener('connect', () => setStatus('connected'));
      r.addEventListener('disconnect', () => setStatus('disconnected'));
      rfb.current = r;
    }, (e: Error) => setStatus(`noVNC failed to load: ${e.message}`));
    return () => { alive = false; rfb.current?.disconnect(); rfb.current = null; };
  }, [n]);
  useEffect(() => { if (rfb.current) rfb.current.viewOnly = !control; }, [control, status]);
  return (
    <section className="desktop-page">
      <div className="toolbar">
        <Link to="/desktops">← Desktops</Link><strong>Desktop {n}</strong><span>{status}</span>
        <label><input type="checkbox" checked={control} onChange={(e) => setControl(e.target.checked)} /> Take control</label>
        <button onClick={() => el.current?.requestFullscreen()}>Full screen</button>
      </div>
      <div className="vnc" ref={el} />
    </section>
  );
}
