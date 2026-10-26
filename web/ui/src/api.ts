// fetch wrapper: JSON in/out, X-AgentOS: 1 on every mutating request (the server's CSRF check).
export class ApiError extends Error {
  constructor(public status: number, message: string, public field?: string) { super(message); }
}

export async function api<T = unknown>(path: string, method = 'GET', body?: unknown): Promise<T> {
  const headers: Record<string, string> = {};
  if (method !== 'GET') headers['X-AgentOS'] = '1';
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  const r = await fetch(path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  const data = r.headers.get('content-type')?.includes('application/json') ? await r.json() : await r.text();
  if (!r.ok) throw new ApiError(r.status, typeof data === 'string' ? data : data.error, typeof data === 'string' ? undefined : data.field);
  return data as T;
}

export const wsUrl = (path: string) => `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}${path}`;
