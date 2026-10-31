import { readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import type { FastifyInstance } from 'fastify';
import { buildApp, defaultDeps } from './app.js';
import { PORT } from './auth.js';
import { defaultLanOpts, httpsRedirect, LAN_DIR, LAN_HTTP_PORT, LAN_PORT } from './lan.js';

const deps = defaultDeps();
const apps: FastifyInstance[] = [await buildApp(deps)];
await apps[0].listen({ host: '127.0.0.1', port: PORT });

// The LAN listener, when web-conf turned it on (it restarts this service on a change). A failure
// here leaves the loopback listener, and so Tailscale access, running.
if (deps.webConf().lan) {
  try {
    const https = { key: readFileSync(`${LAN_DIR}/key.pem`), cert: readFileSync(`${LAN_DIR}/cert.pem`) };
    const opts = defaultLanOpts();
    const lan = await buildApp(deps, { opts, https });
    // Dual-stack; IPv4 only on a box with IPv6 turned off.
    await lan.listen({ host: '::', port: LAN_PORT }).catch(() => lan.listen({ host: '0.0.0.0', port: LAN_PORT }));
    apps.push(lan);
    const redirect = createServer((req, res) => {
      const to = httpsRedirect(req.headers.host, opts.hostname(), opts.addresses());
      if (to) res.writeHead(301, { location: to }).end();
      else res.writeHead(400, { 'content-type': 'text/plain; charset=utf-8' }).end('bad host');
    });
    let tries = 0;
    redirect.on('error', (e) => {
      if (tries++ === 0) redirect.listen(LAN_HTTP_PORT, '0.0.0.0');
      else console.error(`LAN HTTP redirect not started: ${e.message}`);
    });
    redirect.listen(LAN_HTTP_PORT, '::');
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
