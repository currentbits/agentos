import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { parseFingerprints, secretNames } from '../src/settings.js';
import { fakeDeps, H, HM, LOGIN } from './helpers.js';

const SECRET = 'sk-ant-SUPERSECRET-123==';

function withSecrets() {
  const f = fakeDeps((argv) => (argv[3] === 'get' ? { stdout: argv[4] === 'AGENTOS_MAX_DESKTOPS' ? '4\n' : '' } : {}));
  mkdirSync(join(f.deps.home, '.config/agentos'), { recursive: true });
  writeFileSync(join(f.deps.home, '.config/agentos/secrets.env'), `ANTHROPIC_API_KEY=${SECRET}\nOPENAI_API_KEY=\nPAD_TOKEN=abc==\n`);
  return f;
}

describe('settings', () => {
  it('reads key names only', () => {
    expect([...secretNames(`A_API_KEY=${SECRET}\nB_TOKEN=\nC_TOKEN=x`)]).toEqual(['A_API_KEY', 'C_TOKEN']);
  });

  it('GET returns plain values and set/not-set for secrets, never a secret value', async () => {
    const { deps } = withSecrets();
    const app = await buildApp(deps);
    const r = await app.inject({ url: '/api/settings', headers: H });
    expect(r.statusCode).toBe(200);
    expect(r.body).not.toContain(SECRET);
    expect(r.body).not.toContain('SUPERSECRET');
    expect(r.json().values.AGENTOS_MAX_DESKTOPS).toBe('4');
    expect(r.json().secrets).toEqual({ ANTHROPIC_API_KEY: true, OPENAI_API_KEY: false, GROK_CODE_XAI_API_KEY: false, CLAUDE_CODE_OAUTH_TOKEN: false });
  });

  it('PUT sends values on stdin (never argv), applies, audits key names only, and echoes nothing', async () => {
    const { deps, calls, audits } = withSecrets();
    const app = await buildApp(deps);
    const r = await app.inject({ method: 'PUT', url: '/api/settings', headers: HM, payload: { values: { ANTHROPIC_API_KEY: SECRET, AGENTOS_LAN_SSH: '1' } } });
    expect(r.statusCode).toBe(200);
    expect(r.body).not.toContain(SECRET);
    expect(calls.map((c) => c.argv.join(' ')).join('\n')).not.toContain(SECRET);
    expect(calls.find((c) => c.argv[4] === 'ANTHROPIC_API_KEY')!.opts?.input).toBe(SECRET);
    expect(calls.at(-1)!.argv).toEqual(['sudo', '-n', '/usr/local/bin/agentos-config', 'apply']);
    expect(audits).toEqual([`${LOGIN} config-set ANTHROPIC_API_KEY`, `${LOGIN} config-set AGENTOS_LAN_SSH`, `${LOGIN} config-apply -`]);
    expect(audits.join('\n')).not.toContain(SECRET);
  });

  it('maps an agentos-config validation error to the field, and skips apply', async () => {
    const { deps, calls } = fakeDeps((argv) => (argv[4] === 'AGENTOS_MAX_DESKTOPS' ? { code: 2, stderr: 'AGENTOS_MAX_DESKTOPS must be 1-16\n' } : {}));
    const app = await buildApp(deps);
    const r = await app.inject({ method: 'PUT', url: '/api/settings', headers: HM, payload: { values: { AGENTOS_MAX_DESKTOPS: '99' } } });
    expect(r.statusCode).toBe(400);
    expect(r.json()).toEqual({ error: 'AGENTOS_MAX_DESKTOPS must be 1-16', field: 'AGENTOS_MAX_DESKTOPS' });
    expect(calls.some((c) => c.argv.includes('apply'))).toBe(false);
  });

  it('rejects unknown keys and multi-line values before running anything', async () => {
    const { deps, calls } = fakeDeps();
    const app = await buildApp(deps);
    const put = (values: object) => app.inject({ method: 'PUT', url: '/api/settings', headers: HM, payload: { values } });
    expect((await put({ PATH: '/x' })).json()).toMatchObject({ field: 'PATH' });
    expect((await put({ AGENTOS_WEB: '1\nX=2' })).statusCode).toBe(400);
    expect(calls).toEqual([]);
  });
});

describe('ssh keys', () => {
  it('parses ssh-keygen -l output', () => {
    const fp = 'SHA256:' + 'b'.repeat(43);
    expect(parseFingerprints(`256 ${fp} me@laptop (ED25519)\n3072 ${fp} no comment (RSA)\n`)).toEqual([
      { bits: '256', fingerprint: fp, comment: 'me@laptop', type: 'ED25519' },
      { bits: '3072', fingerprint: fp, comment: 'no comment', type: 'RSA' },
    ]);
  });
  it('adds a key via stdin and removes by fingerprint', async () => {
    const { deps, calls, audits } = fakeDeps();
    const app = await buildApp(deps);
    const key = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFake me@x';
    expect((await app.inject({ method: 'POST', url: '/api/ssh-keys', headers: HM, payload: { key } })).statusCode).toBe(200);
    expect(calls.at(-1)).toMatchObject({ argv: ['sudo', '-n', '/usr/local/bin/agentos-config', 'add-ssh-key', '-'], opts: { input: key } });
    const fp = 'SHA256:' + 'c'.repeat(43);
    expect((await app.inject({ method: 'POST', url: '/api/ssh-keys/remove', headers: HM, payload: { fingerprint: fp } })).statusCode).toBe(200);
    expect(calls.at(-1)!.argv).toEqual(['sudo', '-n', '/usr/local/bin/agentos-config', 'remove-ssh-key', fp]);
    expect((await app.inject({ method: 'POST', url: '/api/ssh-keys/remove', headers: HM, payload: { fingerprint: '; rm -rf /' } })).statusCode).toBe(400);
    expect(audits).toEqual([`${LOGIN} ssh-key-add -`, `${LOGIN} ssh-key-remove ${fp}`]);
  });
});
