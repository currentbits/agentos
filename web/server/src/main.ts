import { readFileSync } from 'node:fs';
import type { FastifyInstance } from 'fastify';
import { buildApp, defaultDeps } from './app.js';
import { PORT } from './auth.js';
import { defaultLanOpts, LAN_DIR, LAN_PORT } from './lan.js';

const deps = defaultDeps();
const apps: FastifyInstance[] = [await buildApp(deps)];
await apps[0].listen({ host: '127.0.0.1', port: PORT });

// The LAN listener, when web-conf turned it on (it restarts this service on a change). A failure
// here leaves the loopback listener, and so Tailscale access, running.
if (deps.webConf().lan) {
  try {
    const https = { key: readFileSync(`${LAN_DIR}/key.pem`), cert: readFileSync(`${LAN_DIR}/cert.pem`) };
    const lan = await buildApp(deps, { opts: defaultLanOpts(), https });
    // Dual-stack; IPv4 only on a box with IPv6 turned off.
    await lan.listen({ host: '::', port: LAN_PORT }).catch(() => lan.listen({ host: '0.0.0.0', port: LAN_PORT }));
    apps.push(lan);
  } catch (e) {
    console.error(`LAN listener not started: ${(e as Error).message}`);
  }
}

// A restart (web-conf after a LAN change, an update) lets requests in flight finish, such as the
// Settings save that caused it. Open WebSockets are closed; at most 5 s.
process.on('SIGTERM', () => {
  setTimeout(() => process.exit(0), 5000).unref();
  void Promise.allSettled(apps.map((a) => a.close())).then(() => process.exit(0));
});
