import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { CHECK_PASSWORD } from '../src/actions.js';
import { parseWebConf } from '../src/auth.js';
import { ABSOLUTE_MS, httpsRedirect, IDLE_MS, LanState, LOGIN_PAGE, lanHostAllowed, rateKey, sessionToken, WINDOW_MS, type LanOpts } from '../src/lan.js';
import { fakeDeps, H, LOGIN } from './helpers.js';

const PW = 'correct horse battery';
const NAME = 'box';
const ADDRS = ['127.0.0.1', '192.168.1.50', '::1', 'fe80::1', '2001:db8::5'];
const HOST = '192.168.1.50';
const ORIGIN = `https://${HOST}`;
const CSRF = { host: HOST, origin: ORIGIN, 'x-agentos': '1' };
const IP = '::ffff:192.0.2.7';   // how an IPv4 client shows up on the dual-stack socket

// The LAN app with a fake clock and a recording sleep; check-password accepts PW.
async function lanApp(conf = '') {
  let t = 1_000_000;
  const sleeps: number[] = [];
  const opts: LanOpts = { now: () => t, sleep: async (ms) => { sleeps.push(ms); }, hostname: () => NAME, addresses: () => ADDRS };
  const f = fakeDeps((argv, o) => (argv.includes(CHECK_PASSWORD) ? { code: o?.input === `${PW}\n` ? 0 : 1 } : {}),
    { webConf: () => parseWebConf(conf) });
  const app = await buildApp(f.deps, { opts });
  const login = (password: unknown, remoteAddress = IP, headers: Record<string, string> = CSRF) =>
    app.inject({ method: 'POST', url: '/api/lan/login', headers, remoteAddress, payload: { password } });
  const cookieOf = async () => {
    const r = await login(PW);
    expect(r.statusCode).toBe(200);
    return `__Host-agentos-session=${sessionToken(String(r.headers['set-cookie']))}`;
  };
  return { app, ...f, sleeps, login, cookieOf, advance: (ms: number) => { t += ms; } };
}

describe('Host allowlist', () => {
  it('accepts the hostname, hostname.local and this box\'s addresses, optionally with :443', () => {
    for (const h of ['box', 'BOX', 'box.local', 'box:443', '192.168.1.50', '192.168.1.50:443', '[::1]', '[2001:db8::5]:443', '[fe80::1]']) {
      expect(lanHostAllowed(h, NAME, ADDRS)).toBe(true);
    }
  });
  it('rejects a rebinding name, another port, an unknown address and a bare IPv6 literal', () => {
    for (const h of [undefined, '', 'evil.example', 'box.evil.example', 'evil.example:443', '192.168.1.50:8443', '192.168.1.51', '2001:db8::5', '[2001:db8::6]', 'box.local.']) {
      expect(lanHostAllowed(h, NAME, ADDRS)).toBe(false);
    }
  });
  it('http:// on port 80 is sent to https only for a Host naming this box', () => {
    expect(httpsRedirect('192.168.1.50', NAME, ADDRS)).toBe('https://192.168.1.50/');
    expect(httpsRedirect('Box.local:80', NAME, ADDRS)).toBe('https://box.local/');
    expect(httpsRedirect('[fe80::1]:80', NAME, ADDRS)).toBe('https://[fe80::1]/');
    for (const h of [undefined, '', 'evil.example', 'evil.example:80', '192.168.1.50:8080']) {
      expect(httpsRedirect(h, NAME, ADDRS)).toBe(null);
    }
  });
  it('403 for a bad Host, also on the login route', async () => {
    const { app, login } = await lanApp();
    expect((await app.inject({ url: '/', headers: { host: 'evil.example' } })).statusCode).toBe(403);
    expect((await login(PW, IP, { ...CSRF, host: 'evil.example', origin: 'https://evil.example' })).statusCode).toBe(403);
  });
});

describe('without a session', () => {
  it('a page GET gets the login page (static, no third-party resources); the API and WebSockets get 401', async () => {
    const { app } = await lanApp();
    for (const url of ['/', '/sessions/ag-x', '/novnc/core/rfb.js']) {
      const r = await app.inject({ url, headers: { host: HOST } });
      expect(r.statusCode).toBe(401);
      expect(r.headers['content-type']).toMatch(/text\/html/);
      expect(r.body).toBe(LOGIN_PAGE);
    }
    expect(LOGIN_PAGE).not.toMatch(/https?:\/\/|src=|href=/);
    const api = await app.inject({ url: '/api/sessions', headers: { host: HOST } });
    expect([api.statusCode, api.body]).toEqual([401, 'log in first']);
    await app.ready();
    await expect(app.injectWS('/api/nope', { headers: { host: HOST, origin: ORIGIN } })).rejects.toThrow(/401/);
  });
  it('a Tailscale identity header means nothing here', async () => {
    const { app } = await lanApp();
    expect((await app.inject({ url: '/api/nope', headers: { host: HOST, 'tailscale-user-login': LOGIN } })).statusCode).toBe(401);
  });
});

describe('login', () => {
  it('succeeds with the password: a 256-bit token in a __Host- cookie with every flag, audited', async () => {
    const { login, calls, audits, sleeps } = await lanApp();
    const r = await login(PW);
    expect(r.statusCode).toBe(200);
    expect(String(r.headers['set-cookie'])).toMatch(/^__Host-agentos-session=[A-Za-z0-9_-]{43}; Secure; HttpOnly; SameSite=Strict; Path=\/$/);
    expect(Buffer.from(sessionToken(String(r.headers['set-cookie']))!, 'base64url')).toHaveLength(32);
    expect(audits).toEqual(['agent@lan(192.0.2.7) login -']);
    expect(sleeps).toEqual([]);
    expect(calls).toEqual([{ argv: ['sudo', '-n', CHECK_PASSWORD], opts: { input: `${PW}\n`, timeoutMs: 15_000 } }]);
  });
  it('fails with a wrong, empty, missing or multi-line password: 401 after ~1 s, audited, the password nowhere', async () => {
    const { login, calls, audits, sleeps } = await lanApp();
    for (const pw of ['wrong', '', undefined, 42, `${PW}\nx`]) {
      const r = await login(pw);
      expect(r.statusCode).toBe(401);
      expect(r.body).not.toContain('wrong"');
      expect(r.headers['set-cookie']).toBeUndefined();
    }
    expect(sleeps).toEqual([1000, 1000, 1000, 1000, 1000]);
    expect(audits).toEqual(Array(5).fill('agent@lan(192.0.2.7) login-failed -'));
    expect(calls).toHaveLength(1);   // only 'wrong' reaches the helper; the others are refused before it
    expect(calls[0].argv.join(' ')).not.toContain('wrong');
    expect(JSON.stringify(audits)).not.toContain('wrong');
  });
  it('the delay is measured from the start: a slow check sleeps less', async () => {
    let t = 0;
    const sleeps: number[] = [];
    const opts: LanOpts = { now: () => t, sleep: async (ms) => { sleeps.push(ms); }, hostname: () => NAME, addresses: () => ADDRS };
    const { deps } = fakeDeps((argv) => { if (argv.includes(CHECK_PASSWORD)) t += 300; return { code: 1 }; });
    const app = await buildApp(deps, { opts });
    await app.inject({ method: 'POST', url: '/api/lan/login', headers: CSRF, payload: { password: 'x' } });
    expect(sleeps).toEqual([700]);
  });
  it('needs the same CSRF headers as any unsafe request', async () => {
    const { login, calls } = await lanApp();
    expect((await login(PW, IP, { host: HOST, origin: ORIGIN })).statusCode).toBe(403);
    expect((await login(PW, IP, { host: HOST, 'x-agentos': '1' })).statusCode).toBe(403);
    expect((await login(PW, IP, { ...CSRF, origin: `http://${HOST}` })).statusCode).toBe(403);
    expect(calls).toEqual([]);
  });
  it('matches Origin against the normalised Host: "Host: box:443" needs "Origin: https://box"', async () => {
    const { login } = await lanApp();
    expect((await login(PW, IP, { host: `${NAME}:443`, origin: `https://${NAME}`, 'x-agentos': '1' }))
      .statusCode).toBe(200);
    expect((await login(PW, IP, { host: `${NAME}:443`, origin: `https://${NAME}:443`, 'x-agentos': '1' }))
      .statusCode).toBe(403);
  });
  it('a malformed JSON body is never echoed back', async () => {
    const { app } = await lanApp();
    const r = await app.inject({
      method: 'POST', url: '/api/lan/login', headers: { ...CSRF, 'content-type': 'application/json' },
      payload: '{"password":"wrongXYZnotjson',
    });
    expect(r.statusCode).toBe(400);
    expect(r.json()).toEqual({ error: 'bad request' });
    expect(r.body).not.toContain('wrongXYZ');
  });
});

describe('rate limiting', () => {
  it('5 failures per IP in 10 minutes, then 429 (even for the right password) until the window passes', async () => {
    const { login, advance, calls } = await lanApp();
    for (let i = 0; i < 5; i++) expect((await login('wrong')).statusCode).toBe(401);
    expect((await login(PW)).statusCode).toBe(429);
    expect(calls).toHaveLength(5);
    expect((await login(PW, '192.0.2.8')).statusCode).toBe(200);   // another address is not affected
    advance(WINDOW_MS);
    expect((await login(PW)).statusCode).toBe(200);
  });
  it('a success does not count', async () => {
    const { login } = await lanApp();
    for (let i = 0; i < 4; i++) await login('wrong');
    for (let i = 0; i < 3; i++) expect((await login(PW)).statusCode).toBe(200);
    expect((await login('wrong')).statusCode).toBe(401);
    expect((await login(PW)).statusCode).toBe(429);
  });
  it('30 failures in 10 minutes across all addresses, then 429 for everyone', async () => {
    const { login } = await lanApp();
    for (let i = 0; i < 30; i++) expect((await login('wrong', `198.51.100.${Math.floor(i / 5)}`)).statusCode).toBe(401);
    expect((await login(PW, '203.0.113.1')).statusCode).toBe(429);
  });
  it('parallel guesses from one address can\'t pass the limit together', async () => {
    const { login } = await lanApp();
    const codes = (await Promise.all(Array.from({ length: 8 }, () => login('wrong')))).map((r) => r.statusCode).sort();
    expect(codes).toEqual([401, 401, 401, 401, 401, 429, 429, 429]);
  });
  it('IPv6 clients share the per-/64 limit; a different /64 is unaffected', async () => {
    expect(rateKey('2001:db8:1::1')).toBe(rateKey('2001:db8:1::ffff'));
    expect(rateKey('2001:db8:1::1')).not.toBe(rateKey('2001:db8:2::1'));
    const { login } = await lanApp();
    for (let i = 0; i < 5; i++) expect((await login('wrong', `2001:db8:1::${i}`)).statusCode).toBe(401);
    expect((await login(PW, '2001:db8:1::ffff')).statusCode).toBe(429);        // same /64
    expect((await login(PW, '2001:db8:2::1')).statusCode).toBe(200);           // a different /64
  });
});

describe('sessions', () => {
  it('a session cookie authorizes the API as agent@lan(<ip>), with /api/me saying so', async () => {
    const { app, cookieOf } = await lanApp();
    const cookie = await cookieOf();
    expect((await app.inject({ url: '/api/nope', headers: { host: HOST, cookie } })).statusCode).toBe(404);
    const me = await app.inject({ url: '/api/me', headers: { host: HOST, cookie }, remoteAddress: '192.0.2.9' });
    expect(me.json()).toMatchObject({ login: 'agent@lan(192.0.2.9)', lan: true });
    expect((await app.inject({ url: '/api/nope', headers: { host: HOST, cookie: `${cookie.slice(0, -1)}A` } })).statusCode).toBe(401);
  });
  it('expires after 12 hours idle', async () => {
    const { app, cookieOf, advance } = await lanApp();
    const cookie = await cookieOf();
    advance(IDLE_MS - 1000);
    expect((await app.inject({ url: '/api/nope', headers: { host: HOST, cookie } })).statusCode).toBe(404);
    advance(IDLE_MS + 1);
    expect((await app.inject({ url: '/api/nope', headers: { host: HOST, cookie } })).statusCode).toBe(401);
  });
  it('expires after 7 days however active', async () => {
    const st = (() => { let t = 0; const s = new LanState(() => t); return { s, go: (ms: number) => { t += ms; } }; })();
    const token = st.s.create();
    for (let used = 0; used + 11 * 3600_000 <= ABSOLUTE_MS; used += 11 * 3600_000) { expect(st.s.check(token)).toBe(true); st.go(11 * 3600_000); }
    st.go(ABSOLUTE_MS);   // well past 7 days in total
    expect(st.s.check(token)).toBe(false);
  });
  it('logout deletes the session, clears the cookie and is audited', async () => {
    const { app, cookieOf, audits } = await lanApp();
    const cookie = await cookieOf();
    const r = await app.inject({ method: 'POST', url: '/api/lan/logout', headers: { ...CSRF, cookie }, remoteAddress: IP });
    expect(r.statusCode).toBe(200);
    expect(r.headers['set-cookie']).toBe('__Host-agentos-session=; Secure; HttpOnly; SameSite=Strict; Path=/; Max-Age=0');
    expect(audits.at(-1)).toBe('agent@lan(192.0.2.7) logout -');
    expect((await app.inject({ url: '/api/nope', headers: { host: HOST, cookie } })).statusCode).toBe(401);
  });
  it('CSRF: an unsafe request with a session still needs Origin https://<Host> and X-AgentOS', async () => {
    const { app, cookieOf } = await lanApp();
    const cookie = await cookieOf();
    const post = (h: Record<string, string>) => app.inject({ method: 'POST', url: '/api/nope', headers: { cookie, ...h }, payload: {} });
    expect((await post({ host: HOST, origin: ORIGIN })).statusCode).toBe(403);
    expect((await post({ host: HOST, 'x-agentos': '1' })).statusCode).toBe(403);
    expect((await post({ host: HOST, origin: 'https://box.local', 'x-agentos': '1' })).statusCode).toBe(403);
    expect((await post({ host: 'box.local', origin: 'https://box.local', 'x-agentos': '1' })).statusCode).toBe(404);
    expect((await post(CSRF)).statusCode).toBe(404);
    expect((await app.inject({ url: '/api/nope', headers: { host: HOST, cookie, 'sec-fetch-site': 'cross-site' } })).statusCode).toBe(403);
  });
  it('WebSocket upgrades need the session and the Origin', async () => {
    const { app, cookieOf } = await lanApp();
    const cookie = await cookieOf();
    await app.ready();
    await expect(app.injectWS('/api/nope', { headers: { host: HOST, origin: ORIGIN } })).rejects.toThrow(/401/);
    await expect(app.injectWS('/api/nope', { headers: { host: HOST, cookie, origin: 'https://evil.example' } })).rejects.toThrow(/403/);
    await expect(app.injectWS('/api/nope', { headers: { host: HOST, cookie, origin: ORIGIN } })).rejects.toThrow(/404/);
  });
  it('/api/system/lan reports the fingerprint from web.conf', async () => {
    const { app, cookieOf } = await lanApp('LAN=1\nFINGERPRINT=AB:CD\n');
    const r = await app.inject({ url: '/api/system/lan', headers: { host: HOST, cookie: await cookieOf() } });
    expect(r.json()).toMatchObject({ enabled: true, fingerprint: 'AB:CD' });
  });
});

describe('the Tailscale listener is unchanged', () => {
  it('has no LAN routes, ignores session cookies, and reports lan: false', async () => {
    const { deps } = fakeDeps();
    const app = await buildApp(deps);
    expect((await app.inject({ method: 'POST', url: '/api/lan/login', headers: { host: H.host }, payload: { password: PW } })).statusCode).toBe(401);
    expect((await app.inject({ method: 'POST', url: '/api/lan/login', headers: { ...H, origin: 'http://127.0.0.1:7070', 'x-agentos': '1' }, payload: {} })).statusCode).toBe(404);
    expect((await app.inject({ url: '/api/nope', headers: { host: H.host, cookie: `__Host-agentos-session=${'A'.repeat(43)}` } })).statusCode).toBe(401);
    expect((await app.inject({ url: '/api/system/lan', headers: H })).json()).toMatchObject({ enabled: false, fingerprint: null });
    expect((await app.inject({ url: '/', headers: { host: HOST } })).statusCode).toBe(403);   // a LAN Host is a bad host here
  });
});
