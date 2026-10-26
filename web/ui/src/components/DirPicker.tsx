import { api } from '../api';
import { usePoll } from '../usePoll';
import { ErrorText } from './ErrorText';

interface Listing { path: string; parent: string | null; dirs: string[] }

// Browses folders under /home/agent (the server refuses anything outside it).
export function DirPicker({ value, onChange }: { value: string; onChange: (path: string) => void }) {
  const { data, error } = usePoll(() => api<Listing>(`/api/dirs?path=${encodeURIComponent(value)}`), 0, [value]);
  return (
    <div className="dirpicker">
      <code>{data?.path ?? value}</code>
      <ErrorText error={error} />
      <ul>
        {data?.parent && <li><button type="button" onClick={() => onChange(data.parent!)}>..</button></li>}
        {data?.dirs.map((d) => <li key={d}><button type="button" onClick={() => onChange(`${data.path}/${d}`)}>{d}/</button></li>)}
      </ul>
    </div>
  );
}
