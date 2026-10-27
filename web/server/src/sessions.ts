// Agent sessions: interactive tmux sessions of user agent, plus a JSON sidecar per UI-created
// session in ~/.config/agentos/sessions/<name>.json.
import { mkdir, readdir, readFile, realpath, stat, unlink, writeFile } from 'node:fs/promises';
import { dirname, join, sep } from 'node:path';
import type { FastifyInstance } from 'fastify';
import { HttpError } from './run.js';
import type { Deps } from './app.js';

export const NAME_RE = /^[a-z0-9-]{1,32}$/;
export const CLIS = ['claude', 'codex', 'grok', 'opencode', 'shell'] as const;
export type Cli = (typeof CLIS)[number];
export const REPO_RE = /^(https:\/\/[^\s]+|git@[^\s:]+:[^\s]+|ssh:\/\/[^\s]+)$/;
// ':' separates fields: tmux never allows it in a session name, and it escapes control
// characters such as a tab in format output.
export const TMUX_FORMAT = '#{session_name}:#{session_created}:#{session_attached}';

export interface Sidecar { cli: Cli; dir: string; created: string; createdBy: string; ended?: string }
export interface Session {
  id: string; name: string; cli: string | null; dir: string | null; created: string | null;
  attached: number; state: 'running' | 'ended'; external: boolean;
}
interface TmuxSession { id: string; created: string; attached: number }

export function parseTmuxList(out: string): TmuxSession[] {
  return out.split('\n').filter(Boolean).flatMap((line) => {
    const m = line.match(/^(.+):(\d+):(\d+)$/);
    return m ? [{ id: m[1], created: new Date(Number(m[2]) * 1000).toISOString(), attached: Number(m[3]) }] : [];
  });
}

// realpath, then require the result to be home itself or inside it: catches "..", and symlinks out.
export async function resolveDir(dir: string, home: string): Promise<string> {
  let real: string;
  try {
    real = await realpath(dir);
  } catch {
    throw new HttpError(400, `no such directory: ${dir}`);
  }
  if (real !== home && !real.startsWith(home + sep)) throw new HttpError(400, `directory must be inside ${home}`);
  if (!(await stat(real)).isDirectory()) throw new HttpError(400, `not a directory: ${dir}`);
  return real;
}

export function tmuxNewArgv(name: string, dir: string, cli: Cli): string[] {
  if (!NAME_RE.test(name)) throw new HttpError(400, 'name must match [a-z0-9-]{1,32}');
  const cmd = cli === 'shell' ? ['bash', '-l'] : ['bash', '-lc', cli];
  return ['tmux', 'new-session', '-d', '-s', `ag-${name}`, '-c', dir, ...cmd];
}

export function defaultName(cli: Cli, taken: Set<string>): string {
  for (let n = 1; ; n++) if (!taken.has(`${cli}-${n}`)) return `${cli}-${n}`;
}

export const sidecarDir = (home: string) => join(home, '.config/agentos/sessions');

async function readSidecars(home: string): Promise<Map<string, Sidecar>> {
  const out = new Map<string, Sidecar>();
  let files: string[] = [];
  try { files = await readdir(sidecarDir(home)); } catch { return out; }
  for (const f of files) {
    const name = f.replace(/\.json$/, '');
    if (!f.endsWith('.json') || !NAME_RE.test(name)) continue;
    try {
      const s: unknown = JSON.parse(await readFile(join(sidecarDir(home), f), 'utf8'));
      if (s && typeof s === 'object' && !Array.isArray(s)) out.set(name, s as Sidecar);   // skip null, numbers, arrays
    } catch { /* skip a corrupt sidecar */ }
  }
  return out;
}

export async function tmuxSessions(deps: Deps): Promise<TmuxSession[]> {
  const r = await deps.run(['tmux', 'list-sessions', '-F', TMUX_FORMAT]);
  return r.code === 0 ? parseTmuxList(r.stdout) : [];   // no tmux server = no sessions
}

export async function listSessions(deps: Deps): Promise<Session[]> {
  const live = await tmuxSessions(deps);
  const sidecars = await readSidecars(deps.home);
  const out: Session[] = live.map((t) => {
    const s = t.id.startsWith('ag-') ? sidecars.get(t.id.slice(3)) : undefined;
    return { id: t.id, name: s ? t.id.slice(3) : t.id, cli: s?.cli ?? null, dir: s?.dir ?? null, created: s?.created ?? t.created,
             attached: t.attached, state: 'running', external: !s };
  });
  for (const [name, s] of sidecars) {
    if (live.some((t) => t.id === `ag-${name}`)) continue;
    out.push({ id: `ag-${name}`, name, cli: s.cli, dir: s.dir, created: s.created, attached: 0, state: 'ended', external: false });
  }
  return out.sort((a, b) => a.id.localeCompare(b.id));
}

export interface CreateBody { cli?: string; dir?: string; repo?: string; name?: string }

export async function createSession(deps: Deps, body: CreateBody, login: string): Promise<Session> {
  const cli = body.cli as Cli;
  if (!CLIS.includes(cli)) throw new HttpError(400, `cli must be one of ${CLIS.join(', ')}`);
  const sidecars = await readSidecars(deps.home);
  const live = await tmuxSessions(deps);
  const taken = new Set([...sidecars.keys(), ...live.filter((t) => t.id.startsWith('ag-')).map((t) => t.id.slice(3))]);
  const name = body.name || defaultName(cli, taken);
  if (!NAME_RE.test(name)) throw new HttpError(400, 'name must match [a-z0-9-]{1,32}');
  if (taken.has(name)) throw new HttpError(409, `session ${name} already exists`);

  let dir: string;
  if (body.repo) {
    if (!REPO_RE.test(body.repo)) throw new HttpError(400, 'repo must be an https://, ssh:// or git@ URL');
    const dest = join(deps.home, 'work', name);
    await mkdir(dirname(dest), { recursive: true });
    const r = await deps.run(['git', 'clone', '--', body.repo, dest], {
      timeoutMs: 300_000, env: { ...process.env, GIT_TERMINAL_PROMPT: '0', GIT_SSH_COMMAND: 'ssh -o BatchMode=yes' },
    });
    if (r.code !== 0) throw new HttpError(400, `git clone failed: ${r.stderr.trim()}`);
    deps.audit(login, 'repo-clone', dest);
    dir = await resolveDir(dest, deps.home);
  } else {
    dir = await resolveDir(body.dir || deps.home, deps.home);
  }

  const r = await deps.run(tmuxNewArgv(name, dir, cli), { cwd: dir });
  if (r.code !== 0) throw new HttpError(500, `tmux failed: ${r.stderr.trim()}`);
  const sidecar: Sidecar = { cli, dir, created: new Date().toISOString(), createdBy: login };
  await mkdir(sidecarDir(deps.home), { recursive: true });
  await writeFile(join(sidecarDir(deps.home), `${name}.json`), JSON.stringify(sidecar, null, 2) + '\n');
  deps.audit(login, 'session-create', `ag-${name}`);
  return { id: `ag-${name}`, name, cli, dir, created: sidecar.created, attached: 0, state: 'running', external: false };
}

export async function stopSession(deps: Deps, id: string, login: string): Promise<void> {
  if (!(await tmuxSessions(deps)).some((t) => t.id === id)) throw new HttpError(404, `no running session ${id}`);
  const r = await deps.run(['tmux', 'kill-session', '-t', `=${id}`]);
  if (r.code !== 0) throw new HttpError(500, `tmux failed: ${r.stderr.trim()}`);
  const name = id.slice(3);
  if (id.startsWith('ag-') && NAME_RE.test(name)) {
    const f = join(sidecarDir(deps.home), `${name}.json`);
    try {
      const s: Sidecar = JSON.parse(await readFile(f, 'utf8'));
      await writeFile(f, JSON.stringify({ ...s, ended: new Date().toISOString() }, null, 2) + '\n');
    } catch { /* external session: no sidecar */ }
  }
  deps.audit(login, 'session-stop', id);
}

export async function removeSession(deps: Deps, id: string, login: string): Promise<void> {
  const name = id.slice(3);
  if (!id.startsWith('ag-') || !NAME_RE.test(name)) throw new HttpError(404, `no session ${id}`);
  if ((await tmuxSessions(deps)).some((t) => t.id === id)) throw new HttpError(409, `session ${id} is running; stop it first`);
  try { await unlink(join(sidecarDir(deps.home), `${name}.json`)); } catch { throw new HttpError(404, `no session ${id}`); }
  deps.audit(login, 'session-remove', id);
}

export async function listDirs(path: string, home: string): Promise<{ path: string; parent: string | null; dirs: string[] }> {
  const real = await resolveDir(path || home, home);
  const entries = await readdir(real, { withFileTypes: true });
  const dirs = entries.filter((e) => e.isDirectory() && !e.name.startsWith('.')).map((e) => e.name).sort().slice(0, 500);
  return { path: real, parent: real === home ? null : dirname(real), dirs };
}

export function sessionRoutes(app: FastifyInstance, deps: Deps): void {
  app.get('/api/sessions', async () => listSessions(deps));
  app.post<{ Body: CreateBody }>('/api/sessions', async (req, reply) => reply.code(201).send(await createSession(deps, req.body ?? {}, req.login)));
  app.post<{ Params: { id: string } }>('/api/sessions/:id/stop', async (req) => { await stopSession(deps, req.params.id, req.login); return { ok: true }; });
  app.delete<{ Params: { id: string } }>('/api/sessions/:id', async (req) => { await removeSession(deps, req.params.id, req.login); return { ok: true }; });
  app.get<{ Querystring: { path?: string } }>('/api/dirs', async (req) => listDirs(req.query.path ?? '', deps.home));
}
