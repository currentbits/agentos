// Fastify app: the auth hook first, then the API, then the static UI with an SPA fallback.
import { existsSync } from 'node:fs';
import fastifyStatic from '@fastify/static';
import fastifyWebsocket from '@fastify/websocket';
import Fastify, { type FastifyInstance } from 'fastify';
import { type Audit, journalAudit } from './audit.js';
import { authHook, parseTailnetName, readWebConf, type WebConf } from './auth.js';
import { execRunner, HttpError, type Runner } from './run.js';
// Route modules (one import per task):

export interface Deps {
  run: Runner;
  webConf: () => WebConf;
  tsName: () => Promise<string | null>;
  audit: Audit;
  home: string;
  uiRoot: string | null;
  novncRoot: string | null;
}

export function cachedTailnetName(run: Runner, ttlMs = 60_000): () => Promise<string | null> {
  let value: string | null = null;
  let at = 0;
  return async () => {
    if (Date.now() - at > ttlMs) {
      value = parseTailnetName((await run(['tailscale', 'status', '--json'], { timeoutMs: 5000 })).stdout);
      at = Date.now();
    }
    return value;
  };
}

export function defaultDeps(): Deps {
  return {
    run: execRunner,
    webConf: () => readWebConf(),
    tsName: cachedTailnetName(execRunner),
    audit: journalAudit,
    home: '/home/agent',
    uiRoot: '/usr/local/lib/agentos/web/ui',
    novncRoot: '/usr/share/novnc',
  };
}

export async function buildApp(deps: Deps): Promise<FastifyInstance> {
  const app = Fastify({ logger: { level: 'warn' }, bodyLimit: 1024 * 1024 });
  app.decorateRequest('login', '');
  app.addHook('onRequest', authHook(deps.webConf, deps.tsName));
  app.setErrorHandler((err, _req, reply) => {
    if (err instanceof HttpError) return reply.code(err.status).send({ error: err.message, field: err.field });
    const status = (err as { statusCode?: number }).statusCode ?? 500;
    if (status >= 500) app.log.error(err);
    return reply.code(status).send({ error: status >= 500 ? 'internal error' : (err as Error).message });
  });
  await app.register(fastifyWebsocket, { options: { maxPayload: 4 * 1024 * 1024 } });

  // API routes (one line per task):

  if (deps.novncRoot && existsSync(deps.novncRoot)) {
    await app.register(fastifyStatic, { root: deps.novncRoot, prefix: '/novnc/', decorateReply: false });
  }
  if (deps.uiRoot && existsSync(deps.uiRoot)) {
    await app.register(fastifyStatic, { root: deps.uiRoot, prefix: '/' });
    app.setNotFoundHandler((req, reply) =>
      req.url.startsWith('/api/') ? reply.code(404).send({ error: 'not found' }) : reply.sendFile('index.html'));
  }
  return app;
}
