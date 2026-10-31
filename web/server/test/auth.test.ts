import { describe, expect, it } from 'vitest';
import { decide, notConfiguredPage, parseTailnetName, parseWebConf, readWebConf, type RequestFacts } from '../src/auth.js';

const TS = 'box.tail1234.ts.net';
const base: RequestFacts = { method: 'GET', host: TS, login: 'alice@example.com', origin: undefined, xAgentOS: undefined, upgrade: false };
const users = ['alice@example.com', 'bob@example.com'];
const post = { ...base, method: 'POST', origin: `https://${TS}`, xAgentOS: '1' };

describe('identity', () => {
  it('401 without the identity header', () => {
    expect(decide({ ...base, login: undefined }, users, TS)).toMatchObject({ ok: false, status: 401 });
    expect(decide({ ...base, login: '  ' }, users, TS)).toMatchObject({ ok: false, status: 401 });
  });
  it('403 for a login not on the list', () => {
    expect(decide({ ...base, login: 'mallory@example.com' }, users, TS)).toMatchObject({ ok: false, status: 403 });
  });
  it('accepts a listed login, case-insensitively', () => {
    expect(decide({ ...base, login: 'Alice@Example.COM' }, users, TS)).toEqual({ ok: true, login: 'alice@example.com' });
    expect(decide(base, parseWebConf('USERS=Alice@Example.com\n').users, TS)).toEqual({ ok: true, login: 'alice@example.com' });
  });
  it('not-configured mode: every request gets the static page, no API', () => {
    const v = decide({ ...base, login: 'carol@example.com' }, [], TS);
    expect(v).toMatchObject({ ok: false, status: 403, html: true });
    expect(v.ok === false && v.body).toContain('sudo agentos-config set AGENTOS_WEB_USERS carol@example.com');
  });
  it('escapes the login in the not-configured page', () => {
    expect(notConfiguredPage('<script>@x')).not.toContain('<script>');
  });
});

describe('host pinning', () => {
  it('accepts the tailnet name and loopback, rejects anything else', () => {
    expect(decide({ ...base, host: '127.0.0.1:7070' }, users, null).ok).toBe(true);
    expect(decide({ ...base, host: 'localhost:7070' }, users, null).ok).toBe(true);
    expect(decide({ ...base, host: 'evil.example:7070' }, users, TS)).toMatchObject({ ok: false, status: 403 });
    expect(decide({ ...base, host: undefined }, users, TS)).toMatchObject({ ok: false, status: 403 });
    expect(decide(base, users, null)).toMatchObject({ ok: false, status: 403 });
  });
});

describe('CSRF', () => {
  it('accepts a same-origin mutating request with X-AgentOS: 1', () => {
    for (const method of ['POST', 'PUT', 'DELETE']) expect(decide({ ...post, method }, users, TS).ok).toBe(true);
    expect(decide({ ...post, host: '127.0.0.1:7070', origin: 'http://127.0.0.1:7070' }, users, TS).ok).toBe(true);
  });
  it('rejects a missing X-AgentOS header', () => {
    expect(decide({ ...post, xAgentOS: undefined }, users, TS)).toMatchObject({ ok: false, status: 403, body: 'missing X-AgentOS header' });
    expect(decide({ ...post, xAgentOS: 'true' }, users, TS)).toMatchObject({ ok: false, status: 403 });
  });
  it('rejects a wrong or missing Origin', () => {
    expect(decide({ ...post, origin: 'https://evil.example' }, users, TS)).toMatchObject({ ok: false, body: 'bad origin' });
    expect(decide({ ...post, origin: `http://${TS}` }, users, TS)).toMatchObject({ ok: false, body: 'bad origin' });
    expect(decide({ ...post, origin: undefined }, users, TS)).toMatchObject({ ok: false, body: 'bad origin' });
  });
  it('checks Origin on WebSocket upgrades, without needing X-AgentOS', () => {
    const ws = { ...base, upgrade: true };
    expect(decide({ ...ws, origin: `https://${TS}` }, users, TS).ok).toBe(true);
    expect(decide({ ...ws, origin: 'https://evil.example' }, users, TS)).toMatchObject({ ok: false, status: 403 });
    expect(decide({ ...ws, origin: undefined }, users, TS)).toMatchObject({ ok: false, status: 403 });
    expect(decide({ ...ws, login: undefined, origin: `https://${TS}` }, users, TS)).toMatchObject({ ok: false, status: 401 });
  });
  it('GET needs no Origin', () => {
    expect(decide(base, users, TS).ok).toBe(true);
  });
  it('fails closed: PATCH without X-AgentOS is rejected, HEAD passes untouched', () => {
    expect(decide({ ...post, method: 'PATCH', xAgentOS: undefined }, users, TS)).toMatchObject({ ok: false, status: 403, body: 'missing X-AgentOS header' });
    expect(decide({ ...base, method: 'HEAD' }, users, TS)).toEqual({ ok: true, login: 'alice@example.com' });
  });
});

describe('config parsing', () => {
  it('parses web.conf', () => {
    expect(parseWebConf('USERS=a@x.com, B@y.org\nENABLED=1\nSERVE=ok\nLAN=1\nFINGERPRINT=AB:CD\n'))
      .toEqual({ users: ['a@x.com', 'b@y.org'], enabled: true, serve: 'ok', lan: true, fingerprint: 'AB:CD' });
    expect(parseWebConf('')).toEqual({ users: [], enabled: true, serve: '', lan: false, fingerprint: '' });
    expect(parseWebConf('LAN=0\nFINGERPRINT=\n').lan).toBe(false);
    expect(parseWebConf('ENABLED=0\n').enabled).toBe(false);
  });
  it('parses the tailnet name', () => {
    expect(parseTailnetName('{"Self":{"DNSName":"box.tail1234.ts.net."}}')).toBe('box.tail1234.ts.net');
    expect(parseTailnetName('{"Self":{"DNSName":""}}')).toBeNull();
    expect(parseTailnetName('not json')).toBeNull();
  });
  it('readWebConf on a missing file falls back to not-configured', () => {
    expect(readWebConf('/nonexistent/path/web.conf')).toEqual({ users: [], enabled: true, serve: '', lan: false, fingerprint: '' });
  });
});
