// The LAN listener (AGENTOS_WEB_LAN=1): HTTPS on [::]:7443, which the firewall reaches from 443 on
// every interface but tailscale0. Password login for the agent account, sessions in memory, rate
// limits. The loopback listener (Tailscale identity, auth.ts) never sees any of this.
import { createHash, randomBytes } from 'node:crypto';
import { hostname, networkInterfaces } from 'node:os';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { runAction } from './actions.js';
import type { Deps } from './app.js';
import { one, type Verdict } from './auth.js';

export const LAN_PORT = 7443;
export const LAN_HTTP_PORT = 7480;
export const LAN_DIR = '/etc/agentos/web-lan';
export const COOKIE = '__Host-agentos-session';
export const IDLE_MS = 12 * 3600_000;
export const ABSOLUTE_MS = 7 * 24 * 3600_000;
export const WINDOW_MS = 10 * 60_000;
export const MAX_FAILS_PER_IP = 5;
export const MAX_FAILS_TOTAL = 30;
export const FAIL_DELAY_MS = 1000;
export const LOGIN_PATH = '/api/lan/login';

export interface LanOpts {
  now: () => number;
  sleep: (ms: number) => Promise<void>;
  hostname: () => string;
  addresses: () => string[];       // every address of this box, as os.networkInterfaces() prints it
}

export const defaultLanOpts = (): LanOpts => ({
  now: Date.now,
  sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
  hostname,
  addresses: () => Object.values(networkInterfaces()).flatMap((l) => (l ?? []).map((a) => a.address)),
});

// IPv4 clients reach the dual-stack socket as ::ffff:a.b.c.d. (injectWS requests have no address.)
export const clientIp = (ip: string | undefined) => (ip ?? '-').replace(/^::ffff:(?=\d+\.\d+\.\d+\.\d+$)/, '');
export const lanLogin = (ip: string | undefined) => `agent@lan(${clientIp(ip)})`;

// Host, lowercased and with a trailing :443 stripped (browsers omit :443; some clients don't).
const normalizeHost = (host: string) => host.toLowerCase().replace(/:443$/, '');

// Host must name this box: its hostname, <hostname>.local or one of its addresses (IPv6 in
// brackets), optionally with :443. Anything else is DNS rebinding, or a mistake.
export function lanHostAllowed(host: string | undefined, name: string, addrs: string[]): boolean {
  if (!host) return false;
  const h = normalizeHost(host);
  const n = name.toLowerCase();
  return h === n || h === `${n}.local` || addrs.some((a) => h === (a.includes(':') ? `[${a.toLowerCase()}]` : a));
}

// Plain HTTP (port 80, redirected to LAN_HTTP_PORT): a bare IP typed into a browser goes to http://
// first. Only a Host naming this box gets sent on to https, so this is no open redirect.
export function httpsRedirect(host: string | undefined, name: string, addrs: string[]): string | null {
  const h = host?.toLowerCase().replace(/:80$/, '');
  return h && lanHostAllowed(h, name, addrs) ? `https://${h}/` : null;
}

const digest = (token: string) => createHash('sha256').update(token).digest('hex');

interface Session { created: number; seen: number }
interface Attempt { at: number; key: string }

// The per-IP rate limit's key: a whole /64 for IPv6 (one device can have many addresses in a
// single block, e.g. privacy extensions or a /64 per LAN), the exact address for IPv4.
export function rateKey(ip: string): string {
  if (!ip.includes(':')) return ip;
  const [head, tail = ''] = ip.split('::');
  const headParts = head ? head.split(':') : [];
  const tailParts = tail ? tail.split(':') : [];
  const groups = ip.includes('::')
    ? [...headParts, ...Array(8 - headParts.length - tailParts.length).fill('0'), ...tailParts]
    : ip.split(':');
  return groups.slice(0, 4).join(':');
}

// Sessions are keyed by the token's SHA-256, so the map holds no usable token and a lookup never
// compares the secret itself. A restart forgets them all.
export class LanState {
  private sessions = new Map<string, Session>();
  private fails: Attempt[] = [];
  constructor(private now: () => number) {}

  create(): string {
    const t = this.now();
    for (const [k, s] of this.sessions) if (this.expired(s, t)) this.sessions.delete(k);
    const token = randomBytes(32).toString('base64url');   // 256 bits
    this.sessions.set(digest(token), { created: t, seen: t });
    return token;
  }
  check(token: string | null): boolean {
    if (!token) return false;
    const k = digest(token);
    const s = this.sessions.get(k);
    if (!s) return false;
    const t = this.now();
    if (this.expired(s, t)) { this.sessions.delete(k); return false; }
    s.seen = t;
    return true;
  }
  drop(token: string | null): void { if (token) this.sessions.delete(digest(token)); }
  private expired(s: Session, t: number) { return t - s.seen > IDLE_MS || t - s.created > ABSOLUTE_MS; }

  // An attempt counts as a failure from the start, and is forgiven when it succeeds: parallel
  // guesses from one address can't all pass the limit check before the first one fails.
  // ponytail: one list for every address; it never holds more than MAX_FAILS_TOTAL entries.
  attempt(ip: string): Attempt | null {
    const t = this.now();
    const key = rateKey(ip);
    this.fails = this.fails.filter((f) => t - f.at < WINDOW_MS);
    if (this.fails.length >= MAX_FAILS_TOTAL || this.fails.filter((f) => f.key === key).length >= MAX_FAILS_PER_IP) return null;
    const a = { at: t, key };
    this.fails.push(a);
    return a;
  }
  forgive(a: Attempt): void { this.fails = this.fails.filter((f) => f !== a); }
}

export function sessionToken(cookie: string | undefined): string | null {
  return cookie?.match(/(?:^|;\s*)__Host-agentos-session=([A-Za-z0-9_-]{43})(?:;|$)/)?.[1] ?? null;
}

export const LOGIN_PAGE = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>AgentOS: log in</title>
<body style="font-family:sans-serif;background:#111;color:#eee;padding:2em">
<form id="f"><h1>AgentOS</h1>
<p><label>Password of <code>agent</code><br><input id="p" type="password" autocomplete="current-password" autofocus required></label></p>
<p><button>Log in</button> <span id="e" role="alert"></span></p></form>
<script>
document.getElementById('f').onsubmit = async (ev) => {
  ev.preventDefault();
  const e = document.getElementById('e');
  e.textContent = '';
  const r = await fetch('/api/lan/login', { method: 'POST', headers: { 'X-AgentOS': '1', 'Content-Type': 'application/json' },
    body: JSON.stringify({ password: document.getElementById('p').value }) });
  if (r.ok) location.reload();
  else e.textContent = r.status === 429 ? 'Too many failed logins: try again in 10 minutes.' : r.status === 401 ? 'Wrong password.' : 'Login failed (' + r.status + ').';
};
</script>`;

export interface LanFacts {
  method: string; path: string; host: string | undefined; hostOk: boolean; ip: string | undefined; session: boolean;
  origin: string | undefined; xAgentOS: string | undefined;
  fetchSite?: string; fetchMode?: string; fetchDest?: string; upgrade: boolean;
}

// The same rules as decide() in auth.ts, with a session in place of the Tailscale identity.
export function lanDecide(f: LanFacts): Verdict {
  if (!f.hostOk) return { ok: false, status: 403, body: 'bad host' };
  const navigation = f.method === 'GET' && f.fetchMode === 'navigate' && f.fetchDest === 'document';
  if (f.fetchSite === 'cross-site' && !navigation) return { ok: false, status: 403, body: 'cross-site request' };
  const safe = f.method === 'GET' || f.method === 'HEAD' || f.method === 'OPTIONS';
  if (!f.session && !(f.method === 'POST' && f.path === LOGIN_PATH)) {
    if (safe && !f.upgrade && !f.path.startsWith('/api/')) return { ok: false, status: 401, body: LOGIN_PAGE, html: true };
    return { ok: false, status: 401, body: 'log in first' };
  }
  if (!safe || f.upgrade) {
    // Compared against the normalised Host (:443 stripped), the same form a browser's Origin
    // takes: a request with "Host: box:443" still sends "Origin: https://box".
    if (f.origin !== `https://${normalizeHost(f.host!)}`) return { ok: false, status: 403, body: 'bad origin' };
    if (!safe && f.xAgentOS !== '1') return { ok: false, status: 403, body: 'missing X-AgentOS header' };
  }
  return { ok: true, login: lanLogin(f.ip) };
}

export function lanAuthHook(state: LanState, opts: LanOpts) {
  return async (req: FastifyRequest, reply: FastifyReply) => {
    const host = one(req.headers.host);
    const v = lanDecide({
      method: req.method,
      path: req.url.split('?')[0],
      host,
      hostOk: lanHostAllowed(host, opts.hostname(), opts.addresses()),
      ip: req.ip,
      session: state.check(sessionToken(one(req.headers.cookie))),
      origin: one(req.headers.origin),
      xAgentOS: one(req.headers['x-agentos']),
      fetchSite: one(req.headers['sec-fetch-site']),
      fetchMode: one(req.headers['sec-fetch-mode']),
      fetchDest: one(req.headers['sec-fetch-dest']),
      upgrade: one(req.headers.upgrade)?.toLowerCase() === 'websocket',
    });
    if (v.ok) {
      req.login = v.login;
      req.lan = true;
      return;
    }
    return reply.code(v.status).type(v.html ? 'text/html; charset=utf-8' : 'text/plain; charset=utf-8').send(v.body);
  };
}

const COOKIE_FLAGS = 'Secure; HttpOnly; SameSite=Strict; Path=/';

export function lanRoutes(app: FastifyInstance, deps: Deps, state: LanState, opts: LanOpts): void {
  // The password goes to check-password on stdin only: never argv (sudo logs it), the audit log,
  // a response or an error message.
  app.post<{ Body: { password?: unknown } }>(LOGIN_PATH, async (req, reply) => {
    const who = lanLogin(req.ip);
    const attempt = state.attempt(clientIp(req.ip));
    if (!attempt) return reply.code(429).send({ error: 'too many failed logins: try again in 10 minutes' });
    const started = opts.now();
    const pw = req.body?.password;
    const ok = typeof pw === 'string' && pw !== '' && pw.length <= 1024 && !/[\r\n\0]/.test(pw) &&
      (await runAction(deps.run, { name: 'check-password' }, { input: `${pw}\n`, timeoutMs: 15_000 })).code === 0;
    if (!ok) {
      deps.audit(who, 'login-failed', '-');
      await opts.sleep(Math.max(0, FAIL_DELAY_MS - (opts.now() - started)));   // ~1 s, however long the check took
      return reply.code(401).send({ error: 'wrong password' });
    }
    state.forgive(attempt);
    deps.audit(who, 'login', '-');
    return reply.header('Set-Cookie', `${COOKIE}=${state.create()}; ${COOKIE_FLAGS}`).send({ ok: true });
  });
  app.post('/api/lan/logout', async (req, reply) => {
    state.drop(sessionToken(one(req.headers.cookie)));
    deps.audit(req.login, 'logout', '-');
    return reply.header('Set-Cookie', `${COOKIE}=; ${COOKIE_FLAGS}; Max-Age=0`).send({ ok: true });
  });
}
