import { mkdirSync, readFileSync, symlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { defaultName, NAME_RE, parseTmuxList, resolveDir, tmuxNewArgv } from '../src/sessions.js';
import { fakeDeps, H, HM, LOGIN } from './helpers.js';

describe('session names', () => {
  it('accepts [a-z0-9-]{1,32} only', () => {
    for (const ok of ['a', 'claude-1', 'x'.repeat(32), '0-0']) expect(NAME_RE.test(ok)).toBe(true);
    for (const bad of ['', 'x'.repeat(33), 'A', 'a_b', 'a.b', 'a b', '../x', 'a;b', '-'.repeat(33)]) expect(NAME_RE.test(bad)).toBe(false);
  });
  it('picks the lowest free default name', () => {
    expect(defaultName('codex', new Set())).toBe('codex-1');
    expect(defaultName('codex', new Set(['codex-1', 'codex-3']))).toBe('codex-2');
  });
  it('builds tmux argv with a login shell and no shell string', () => {
    expect(tmuxNewArgv('w', '/home/agent/p', 'claude')).toEqual(['tmux', 'new-session', '-d', '-s', 'ag-w', '-c', '/home/agent/p', 'bash', '-lc', 'claude']);
    expect(tmuxNewArgv('s', '/home/agent', 'shell')).toEqual(['tmux', 'new-session', '-d', '-s', 'ag-s', '-c', '/home/agent', 'bash', '-l']);
    expect(() => tmuxNewArgv('Bad', '/home/agent', 'shell')).toThrow();
  });
  it('parses tmux list-sessions output', () => {
    expect(parseTmuxList('main:1761480000:1\nag-x:1761480060:0\ngarbage\n')).toEqual([
      { id: 'main', created: '2025-10-26T12:00:00.000Z', attached: 1 },
      { id: 'ag-x', created: '2025-10-26T12:01:00.000Z', attached: 0 },
    ]);
  });
});

describe('directory validation', () => {
  it('allows home and folders inside it', async () => {
    const { deps } = fakeDeps();
    mkdirSync(join(deps.home, 'proj'));
    expect(await resolveDir(deps.home, deps.home)).toBe(deps.home);
    expect(await resolveDir(join(deps.home, 'proj'), deps.home)).toBe(join(deps.home, 'proj'));
  });
  it('rejects traversal, symlinks out of home, siblings with a common prefix, files and missing paths', async () => {
    const { deps } = fakeDeps();
    symlinkSync('/etc', join(deps.home, 'etc-link'));
    mkdirSync(deps.home + '-evil', { recursive: true });
    writeFileSync(join(deps.home, 'file'), '');
    await expect(resolveDir(join(deps.home, '..'), deps.home)).rejects.toThrow(/inside/);
    await expect(resolveDir(join(deps.home, 'etc-link'), deps.home)).rejects.toThrow(/inside/);
    await expect(resolveDir(deps.home + '-evil', deps.home)).rejects.toThrow(/inside/);
    await expect(resolveDir(join(deps.home, 'file'), deps.home)).rejects.toThrow(/not a directory/);
    await expect(resolveDir(join(deps.home, 'nope'), deps.home)).rejects.toThrow(/no such/);
  });
});

describe('sessions API', () => {
  it('creates a session: tmux argv, sidecar, audit', async () => {
    const { deps, calls, audits } = fakeDeps();
    mkdirSync(join(deps.home, 'p'));
    const app = await buildApp(deps);
    const r = await app.inject({ method: 'POST', url: '/api/sessions', headers: HM, payload: { cli: 'codex', dir: join(deps.home, 'p') } });
    expect(r.statusCode).toBe(201);
    expect(r.json()).toMatchObject({ id: 'ag-codex-1', name: 'codex-1', state: 'running' });
    expect(calls.at(-1)!.argv).toEqual(['tmux', 'new-session', '-d', '-s', 'ag-codex-1', '-c', join(deps.home, 'p'), 'bash', '-lc', 'codex']);
    const sidecar = JSON.parse(readFileSync(join(deps.home, '.config/agentos/sessions/codex-1.json'), 'utf8'));
    expect(sidecar).toMatchObject({ cli: 'codex', dir: join(deps.home, 'p'), createdBy: LOGIN });
    expect(audits).toEqual([`${LOGIN} session-create ag-codex-1`]);
  });

  it('rejects a bad cli, a bad name, a directory outside home and a bad repo URL', async () => {
    const { deps, calls } = fakeDeps();
    const app = await buildApp(deps);
    const post = (payload: object) => app.inject({ method: 'POST', url: '/api/sessions', headers: HM, payload });
    expect((await post({ cli: 'rm -rf /' })).statusCode).toBe(400);
    expect((await post({ cli: 'shell', name: 'Bad Name' })).statusCode).toBe(400);
    expect((await post({ cli: 'shell', dir: '/etc' })).statusCode).toBe(400);
    expect((await post({ cli: 'shell', repo: '--upload-pack=touch /tmp/x' })).statusCode).toBe(400);
    expect((await post({ cli: 'shell', repo: 'file:///etc' })).statusCode).toBe(400);
    expect(calls.filter((c) => c.argv[0] !== 'tmux' || c.argv[1] !== 'list-sessions')).toEqual([]);
  });

  it('clones a repo into ~/work/<name> with prompts disabled', async () => {
    const { deps, calls } = fakeDeps((argv) => {
      if (argv[0] === 'git') mkdirSync(argv[4], { recursive: true });
      return {};
    });
    const app = await buildApp(deps);
    const r = await app.inject({ method: 'POST', url: '/api/sessions', headers: HM, payload: { cli: 'claude', name: 'demo', repo: 'https://github.com/o/r.git' } });
    expect(r.statusCode).toBe(201);
    const git = calls.find((c) => c.argv[0] === 'git')!;
    expect(git.argv).toEqual(['git', 'clone', '--', 'https://github.com/o/r.git', join(deps.home, 'work/demo')]);
    expect(git.opts?.env?.GIT_TERMINAL_PROMPT).toBe('0');
  });

  it('lists running, external and ended sessions', async () => {
    const { deps } = fakeDeps((argv) => (argv[1] === 'list-sessions' ? { stdout: 'main:1761480000:1\nag-a:1761480000:0\n' } : {}));
    mkdirSync(join(deps.home, '.config/agentos/sessions'), { recursive: true });
    for (const n of ['a', 'b']) {
      writeFileSync(join(deps.home, `.config/agentos/sessions/${n}.json`), JSON.stringify({ cli: 'shell', dir: deps.home, created: 'c', createdBy: LOGIN }));
    }
    const app = await buildApp(deps);
    const list = (await app.inject({ url: '/api/sessions', headers: H })).json();
    expect(list.map((s: { id: string; state: string; external: boolean }) => [s.id, s.state, s.external])).toEqual([
      ['ag-a', 'running', false], ['ag-b', 'ended', false], ['main', 'running', true],
    ]);
  });

  it('stops only a live session, by exact name, and removes only ended ones', async () => {
    const { deps, calls } = fakeDeps((argv) => (argv[1] === 'list-sessions' ? { stdout: 'ag-a:1761480000:0\n' } : {}));
    mkdirSync(join(deps.home, '.config/agentos/sessions'), { recursive: true });
    writeFileSync(join(deps.home, '.config/agentos/sessions/a.json'), JSON.stringify({ cli: 'shell', dir: deps.home, created: 'c', createdBy: LOGIN }));
    const app = await buildApp(deps);
    expect((await app.inject({ method: 'POST', url: '/api/sessions/ag-zzz/stop', headers: HM })).statusCode).toBe(404);
    expect((await app.inject({ method: 'DELETE', url: '/api/sessions/ag-a', headers: HM })).statusCode).toBe(409);
    expect((await app.inject({ method: 'POST', url: '/api/sessions/ag-a/stop', headers: HM })).statusCode).toBe(200);
    expect(calls.at(-1)!.argv).toEqual(['tmux', 'kill-session', '-t', '=ag-a']);
    expect(JSON.parse(readFileSync(join(deps.home, '.config/agentos/sessions/a.json'), 'utf8')).ended).toBeTruthy();
  });

  it('lists directories inside home only', async () => {
    const { deps } = fakeDeps();
    mkdirSync(join(deps.home, 'b'));
    mkdirSync(join(deps.home, 'a'));
    mkdirSync(join(deps.home, '.hidden'));
    const app = await buildApp(deps);
    expect((await app.inject({ url: '/api/dirs', headers: H })).json()).toEqual({ path: deps.home, parent: null, dirs: ['a', 'b'] });
    expect((await app.inject({ url: '/api/dirs?path=/etc', headers: H })).statusCode).toBe(400);
  });
});
