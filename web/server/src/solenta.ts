// The Solenta card: pairing facts and preflight (solenta-pair, as agent) and a repo clone through
// the sessions code. Nothing here reads a Solenta token.
import type { FastifyInstance } from 'fastify';
import { runAction } from './actions.js';
import { HttpError } from './run.js';
import type { Deps } from './app.js';
import { cloneRepo, resolveDir } from './sessions.js';

export function solentaRoutes(app: FastifyInstance, deps: Deps): void {
  app.get<{ Querystring: { path?: string } }>('/api/solenta', async (req) => {
    const path = req.query.path ? await resolveDir(req.query.path, deps.home) : undefined;
    const r = await runAction(deps.run, { name: 'solenta-status', path }, { timeoutMs: 30_000 });
    if (r.code !== 0) throw new HttpError(500, r.stderr.trim() || 'solenta-pair failed');
    return JSON.parse(r.stdout);
  });
  app.post<{ Body: { repo?: string; name?: string } }>('/api/solenta/clone', async (req, reply) =>
    reply.code(201).send({ path: await cloneRepo(deps, String(req.body?.repo ?? ''), String(req.body?.name ?? ''), req.login) }));
}
