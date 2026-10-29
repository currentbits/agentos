// Built-in CI: every call runs `agentos-ci … --json` as agent (this service's user), never sudo.
// agentos-ci validates again; the actions table validates first.
import type { FastifyInstance } from 'fastify';
import { type Action, argv, runAction } from './actions.js';
import { HttpError } from './run.js';
import type { Deps } from './app.js';
import { resolveDir } from './sessions.js';
import { streamToSocket } from './system.js';

// agentos-ci exits 2 for a bad request (unknown run, bad ref, no repository): the user's error.
export async function ciJson<T = unknown>(deps: Deps, a: Action): Promise<T> {
  const r = await runAction(deps.run, a, { timeoutMs: 60_000 });
  if (r.code !== 0) throw new HttpError(r.code === 2 ? 400 : 500, r.stderr.replace(/^agentos-ci: /, '').trim() || 'agentos-ci failed');
  return JSON.parse(r.stdout) as T;
}

interface RunInfo { id: string; repo: string; commit: string }

// A run's log can be tailed from several tabs/users at once; cap the total across all runs so a
// pile of forgotten tabs can't exhaust this server's file descriptors/child processes.
const MAX_LOG_TAILS = 8;
let activeLogTails = 0;

export function ciRoutes(app: FastifyInstance, deps: Deps): void {
  app.get<{ Querystring: { repo?: string; limit?: string } }>('/api/ci/runs', async (req) => {
    const limit = /^\d{1,3}$/.test(req.query.limit ?? '') ? Math.min(Math.max(Number(req.query.limit), 1), 200) : 50;
    const repo = req.query.repo ? await resolveDir(req.query.repo, deps.home) : undefined;
    return ciJson(deps, { name: 'ci-list', repo, limit });
  });
  app.get<{ Params: { id: string } }>('/api/ci/runs/:id', async (req) => ciJson(deps, { name: 'ci-status', id: req.params.id }));
  app.post<{ Body: { path?: string; ref?: string } }>('/api/ci/runs', async (req, reply) => {
    const path = await resolveDir(String(req.body?.path ?? ''), deps.home);
    const out = await ciJson(deps, { name: 'ci-run', path, ref: String(req.body?.ref || 'HEAD') });
    deps.audit(req.login, 'ci-run', path);
    return reply.code(201).send(out);
  });
  app.post<{ Params: { id: string } }>('/api/ci/runs/:id/rerun', async (req, reply) => {
    const run = await ciJson<RunInfo>(deps, { name: 'ci-status', id: req.params.id });
    const out = await ciJson(deps, { name: 'ci-run', path: run.repo, ref: run.commit });
    deps.audit(req.login, 'ci-rerun', req.params.id);
    return reply.code(201).send(out);
  });
  app.post<{ Params: { id: string } }>('/api/ci/runs/:id/cancel', async (req) => {
    const out = await ciJson(deps, { name: 'ci-cancel', id: req.params.id });
    deps.audit(req.login, 'ci-cancel', req.params.id);
    return out;
  });
  app.get('/api/ci/remotes', async () => ciJson(deps, { name: 'ci-remotes' }));
  app.get<{ Params: { id: string }; Querystring: { step?: string } }>('/api/ci/runs/:id/log', { websocket: true }, (socket, req) => {
    if (activeLogTails >= MAX_LOG_TAILS) { socket.close(1013, 'too many concurrent CI log tails; try again shortly'); return; }
    activeLogTails++;
    socket.on('close', () => { activeLogTails--; });
    try {
      streamToSocket(socket, argv({ name: 'ci-log', id: req.params.id, step: req.query.step ?? '' }));
    } catch (e) {
      socket.close(1008, (e as Error).message);
    }
  });
}
