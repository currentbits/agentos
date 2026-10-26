import { useCallback, useEffect, useState } from 'react';

// Calls fn now, then every ms milliseconds (0 = once). Refetches when deps change or on reload().
export function usePoll<T>(fn: () => Promise<T>, ms = 0, deps: unknown[] = []) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const reload = useCallback(() => setTick((t) => t + 1), []);
  useEffect(() => {
    let live = true;
    const load = () => fn().then((d) => { if (live) { setData(d); setError(null); } }, (e: Error) => { if (live) setError(e.message); });
    load();
    const id = ms ? setInterval(load, ms) : undefined;
    return () => { live = false; clearInterval(id); };
  }, [ms, tick, ...deps]);
  return { data, error, reload };
}
