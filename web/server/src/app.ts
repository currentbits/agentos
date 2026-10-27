// Fastify app: the auth hook first, then the API, then the static UI with an SPA fallback.
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import fastifyStatic from '@fastify/static';
import fastifyWebsocket from '@fastify/websocket';
import Fastify, { type FastifyInstance } from 'fastify';
import { type Audit, journalAudit } from './audit.js';
import { authHook, parseTailnetName, readWebConf, type WebConf } from './auth.js';
import { execRunner, HttpError, type Runner } from './run.js';
// Route modules (one import per task):
import { settingsRoutes } from './settings.js';
import { sessionRoutes } from './sessions.js';
import { terminalRoutes } from './terminal.js';
import { desktopRoutes } from './desktops.js';
import { TOKEN_DIR, vncRoutes } from './vnc.js';
import { systemRoutes } from './system.js';

export interface Deps {
  run: Runner;
  webConf: () => WebConf;
  tsName: () => Promise<string | null>;
  audit: Audit;
  home: string;
  uiRoot: string | null;
  novncRoot: string | null;
  vncTokenDir: string;
}

export function cachedTailnetName(run: Runner, ttlMs = 60_000): () => Promise<string | null> {
  let value: string | null = null;
  let at = 0;
  let inflight: Promise<string | null> | null = null;   // single-flight: share one call on expiry
  return async () => {
    if (Date.now() - at <= ttlMs) return value;
    inflight ??= run(['tailscale', 'status', '--json'], { timeoutMs: 5000 })
      .then((r) => parseTailnetName(r.stdout))
      .finally(() => { inflight = null; });
    const v = await inflight;
    // Cache only a real name: a failed lookup (tailscaled starting, logged out) is retried next time.
    if (v !== null) { value = v; at = Date.now(); }
    return v;
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
    vncTokenDir: TOKEN_DIR,
  };
}

export async function buildApp(deps: Deps): Promise<FastifyInstance> {
  const app = Fastify({ logger: { level: 'warn' }, bodyLimit: 1024 * 1024 });
  // A bodyless mutating action (stop, create-with-no-fields) still gets `Content-Type:
  // application/json` from some clients (the smoke checks' CSRF-header helper, among others).
  // Fastify's default parser treats that as an error; treat an empty body as {} instead.
  app.addContentTypeParser('application/json', { parseAs: 'string' }, (_req, body, done) => {
    if (body === '') return done(null, {});
    try {
      done(null, JSON.parse(body as string));
    } catch (err) {
      (err as Error & { statusCode?: number }).statusCode = 400;
      done(err as Error, undefined);
    }
  });
  app.decorateRequest('login', '');
  // Anti-clickjacking headers on every response, including 401/403 and static files.
  app.addHook('onSend', async (_req, reply, payload) => {
    reply.header('X-Frame-Options', 'DENY');
    reply.header('Content-Security-Policy', "frame-ancestors 'none'");
    reply.header('X-Content-Type-Options', 'nosniff');
    reply.header('Referrer-Policy', 'no-referrer');
    return payload;
  });
  app.addHook('onRequest', authHook(deps.webConf, deps.tsName));
  app.setErrorHandler((err, _req, reply) => {
    if (err instanceof HttpError) return reply.code(err.status).send({ error: err.message, field: err.field });
    const status = (err as { statusCode?: number }).statusCode ?? 500;
    if (status >= 500) app.log.error(err);
    return reply.code(status).send({ error: status >= 500 ? 'internal error' : (err as Error).message });
  });
  await app.register(fastifyWebsocket, { options: { maxPayload: 4 * 1024 * 1024 } });

  // API routes (one line per task):
  settingsRoutes(app, deps);
  sessionRoutes(app, deps);
  terminalRoutes(app, deps);
  desktopRoutes(app, deps);
  vncRoutes(app, deps, undefined, deps.vncTokenDir);
  systemRoutes(app, deps);

  // Only what DesktopView imports (core/rfb.js and the vendor/ modules it loads), not noVNC's own
  // app (vnc.html and friends). Separate roots, so "core/../vnc.html" can't climb out.
  for (const dir of ['core', 'vendor']) {
    const root = deps.novncRoot && join(deps.novncRoot, dir);
    if (root && existsSync(root)) await app.register(fastifyStatic, { root, prefix: `/novnc/${dir}/`, decorateReply: false });
  }
  if (deps.uiRoot && existsSync(deps.uiRoot)) {
    await app.register(fastifyStatic, { root: deps.uiRoot, prefix: '/' });
    app.setNotFoundHandler((req, reply) =>
      req.url.startsWith('/api/') ? reply.code(404).send({ error: 'not found' }) : reply.sendFile('index.html'));
  }
  return app;
}
