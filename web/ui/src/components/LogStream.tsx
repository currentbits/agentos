import { useEffect, useRef, useState } from 'react';
import { wsUrl } from '../api';

// Streams a WebSocket's text frames into a scrolling <pre>; closes the socket on unmount.
// onEnd fires when the server closes the stream (not on unmount).
export function LogStream({ path, onEnd }: { path: string; onEnd?: () => void }) {
  const [text, setText] = useState('');
  const pre = useRef<HTMLPreElement>(null);
  useEffect(() => {
    setText('');
    const ws = new WebSocket(wsUrl(path));
    ws.onmessage = (e) => setText((t) => (t + (e.data as string)).slice(-200_000));
    ws.onclose = (e) => { if (e.reason) setText((t) => `${t}\n[${e.reason}]`); onEnd?.(); };
    return () => { ws.onclose = null; ws.close(); };
  }, [path]);
  useEffect(() => { pre.current?.scrollTo(0, pre.current.scrollHeight); }, [text]);
  return <pre className="log" ref={pre}>{text}</pre>;
}
