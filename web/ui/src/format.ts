export const gib = (b: number) => `${(b / 2 ** 30).toFixed(1)} GiB`;
export const pct = (used: number, total: number) => (total ? Math.round((100 * used) / total) : 0);
export const minutes = (s: number | null) => (s === null ? '?' : `${Math.floor(s / 60)} min`);
// "1m 05s" between two ISO times (end defaults to now), '' before the start.
export function duration(start: string | null, end: string | null, now = Date.now()): string {
  if (!start) return '';
  const s = Math.max(0, Math.round(((end ? Date.parse(end) : now) - Date.parse(start)) / 1000));
  return s >= 60 ? `${Math.floor(s / 60)}m ${String(s % 60).padStart(2, '0')}s` : `${s}s`;
}
export const FINAL_CI = ['passed', 'failed', 'cancelled', 'error'];
