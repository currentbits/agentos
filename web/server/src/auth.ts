// Identity (Tailscale-User-Login vs the allowlist), Host pinning, and CSRF/Origin checks.
// One onRequest hook covers every HTTP request and every WebSocket upgrade.
import { readFileSync } from 'node:fs';
import type { FastifyReply, FastifyRequest } from 'fastify';

export const PORT = 7070;
export const LOOPBACK_HOSTS = [`127.0.0.1:${PORT}`, `localhost:${PORT}`];

export interface WebConf { users: string[]; enabled: boolean; serve: string; lan: boolean; fingerprint: string }

export function parseWebConf(text: string): WebConf {
  const get = (k: string) => text.match(new RegExp(`^${k}=(.*)$`, 'm'))?.[1].trim() ?? '';
  return {
    users: get('USERS').split(',').map((u) => u.trim().toLowerCase()).filter(Boolean),
    enabled: get('ENABLED') !== '0',
    serve: get('SERVE'),
    lan: get('LAN') === '1',            // the LAN listener (lan.ts), written by web-conf
    fingerprint: get('FINGERPRINT'),    // its certificate's SHA-256, AB:CD:...
  };
}

export function readWebConf(path = '/etc/agentos/web.conf'): WebConf {
  try {
    return parseWebConf(readFileSync(path, 'utf8'));
  } catch {
    return parseWebConf('');
  }
}

// Host must be the tailnet name (via tailscale serve) or loopback; this blocks DNS rebinding.
export function hostAllowed(host: string | undefined, tsName: string | null): boolean {
  return !!host && (host === tsName || LOOPBACK_HOSTS.includes(host));
}

export function expectedOrigin(host: string, tsName: string | null): string {
  return host === tsName ? `https://${host}` : `http://${host}`;
}

export type Verdict =
  | { ok: true; login: string }
  | { ok: false; status: number; body: string; html?: boolean };

const escapeHtml = (s: string) =>
  s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

export function notConfiguredPage(login: string): string {
  const l = escapeHtml(login);
  return `<!doctype html><meta charset="utf-8"><title>AgentOS</title>
<body style="font-family:sans-serif;background:#111;color:#eee;padding:2em">
<p>You are <code>${l}</code>.</p>
<p>Add yourself: <code>sudo agentos-config set AGENTOS_WEB_USERS ${l} &amp;&amp; sudo agentos-config apply</code></p>
</body>`;
}

export interface RequestFacts {
  method: string;
  host: string | undefined;
  login: string | undefined;
  origin: string | undefined;
  xAgentOS: string | undefined;
  fetchSite?: string;   // Sec-Fetch-Site, Sec-Fetch-Mode, Sec-Fetch-Dest
  fetchMode?: string;
  fetchDest?: string;
  upgrade: boolean;
}

export function decide(f: RequestFacts, users: string[], tsName: string | null): Verdict {
  if (!hostAllowed(f.host, tsName)) return { ok: false, status: 403, body: 'bad host' };
  // Browsers send Sec-Fetch-Site on every request; curl and tests don't, so absent is allowed.
  // A cross-site request is refused, except a top-level GET navigation: a link to the console
  // from chat or email must still open it.
  const navigation = f.method === 'GET' && f.fetchMode === 'navigate' && f.fetchDest === 'document';
  if (f.fetchSite === 'cross-site' && !navigation) return { ok: false, status: 403, body: 'cross-site request' };
  const login = f.login?.trim().toLowerCase();
  if (!login) return { ok: false, status: 401, body: 'no Tailscale identity' };
  if (users.length === 0) return { ok: false, status: 403, body: notConfiguredPage(login), html: true };
  if (!users.includes(login)) return { ok: false, status: 403, body: `${login} is not allowed` };
  // Fail closed: every method except the safe ones needs CSRF checks, not just a hardcoded list.
  const safe = f.method === 'GET' || f.method === 'HEAD' || f.method === 'OPTIONS';
  if (!safe || f.upgrade) {
    if (f.origin !== expectedOrigin(f.host!, tsName)) return { ok: false, status: 403, body: 'bad origin' };
    if (!safe && f.xAgentOS !== '1') return { ok: false, status: 403, body: 'missing X-AgentOS header' };
  }
  return { ok: true, login };
}

export const one = (v: string | string[] | undefined) => (Array.isArray(v) ? v[0] : v);

declare module 'fastify' {
  interface FastifyRequest { login: string; lan: boolean }   // lan: arrived on the LAN listener
}

export function authHook(conf: () => WebConf, tsName: () => Promise<string | null>) {
  return async (req: FastifyRequest, reply: FastifyReply) => {
    const v = decide({
      method: req.method,
      host: one(req.headers.host),
      login: one(req.headers['tailscale-user-login']),
      origin: one(req.headers.origin),
      xAgentOS: one(req.headers['x-agentos']),
      fetchSite: one(req.headers['sec-fetch-site']),
      fetchMode: one(req.headers['sec-fetch-mode']),
      fetchDest: one(req.headers['sec-fetch-dest']),
      upgrade: one(req.headers.upgrade)?.toLowerCase() === 'websocket',
    }, conf().users, await tsName());
    if (v.ok) {
      req.login = v.login;
      return;
    }
    return reply.code(v.status).type(v.html ? 'text/html; charset=utf-8' : 'text/plain; charset=utf-8').send(v.body);
  };
}

// Tailnet DNS name (Self.DNSName, trailing dot stripped) from `tailscale status --json`.
export function parseTailnetName(statusJson: string): string | null {
  try {
    const name: unknown = JSON.parse(statusJson)?.Self?.DNSName;
    return typeof name === 'string' && name ? name.replace(/\.$/, '') : null;
  } catch {
    return null;
  }
}
