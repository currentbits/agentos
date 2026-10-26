import { useEffect, useRef, useState } from 'react';
import { wsUrl } from '../api';

// Streams a WebSocket's text frames into a scrolling <pre>; closes the socket on unmount.
export function LogStream({ path }: { path: string }) {
  const [text, setText] = useState('');
  const pre = useRef<HTMLPreElement>(null);
  useEffect(() => {
    setText('');
    const ws = new WebSocket(wsUrl(path));
    ws.onmessage = (e) => setText((t) => (t + (e.data as string)).slice(-200_000));
    ws.onclose = (e) => { if (e.reason) setText((t) => `${t}\n[${e.reason}]`); };
    return () => ws.close();
  }, [path]);
  useEffect(() => { pre.current?.scrollTo(0, pre.current.scrollHeight); }, [text]);
  return <pre className="log" ref={pre}>{text}</pre>;
}
