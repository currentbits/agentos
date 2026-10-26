export const gib = (b: number) => `${(b / 2 ** 30).toFixed(1)} GiB`;
export const pct = (used: number, total: number) => (total ? Math.round((100 * used) / total) : 0);
export const minutes = (s: number | null) => (s === null ? '?' : `${Math.floor(s / 60)} min`);
