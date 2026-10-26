import { mkdtempSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:net';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import fastifyWebsocket from '@fastify/websocket';
import Fastify from 'fastify';
import { expect, it } from 'vitest';
import { WebSocketServer } from 'ws';
import { buildApp } from '../src/app.js';
import { parseToken, vncRoutes } from '../src/vnc.js';
import { fakeDeps, H, HM } from './helpers.js';

it('parses vnc-token files', () => {
  expect(parseToken('0123456789abcdef0123456789abcdef: localhost:5901\n')).toBe('0123456789abcdef0123456789abcdef');
  expect(() => parseToken('garbage')).toThrow();
});

it('proxies to websockify with the token added server-side', async () => {
  const token = 'ab'.repeat(16);
  const upstream = new WebSocketServer({ port: 0, host: '127.0.0.1' });
  const seen: string[] = [];
  upstream.on('connection', (ws, req) => {
    seen.push(req.url ?? '');
    ws.on('message', (d: Buffer) => ws.send(Buffer.concat([Buffer.from('echo:'), d])));
  });
  await new Promise((r) => upstream.once('listening', r));
  const tokens = mkdtempSync(join(tmpdir(), 'vnc-'));
  writeFileSync(join(tokens, '1'), `${token}: localhost:5901\n`);

  const { deps } = fakeDeps((argv) => (argv[1] === 'list-units' ? { stdout: 'agentos-desktop@1.service loaded active running x\n' } : {}));
  const app = Fastify();
  app.decorateRequest('login', '');
  await app.register(fastifyWebsocket);
  vncRoutes(app, deps, `ws://127.0.0.1:${(upstream.address() as AddressInfo).port}/websockify`, tokens);
  await app.ready();

  const ws = await app.injectWS('/api/desktops/1/vnc');
  const reply = new Promise<string>((r) => ws.once('message', (d: Buffer) => r(d.toString())));
  ws.send(Buffer.from('RFB 003.008\n'));
  expect(await reply).toBe('echo:RFB 003.008\n');
  expect(seen).toEqual([`/websockify?token=${token}`]);
  ws.terminate();

  const closed = await app.injectWS('/api/desktops/2/vnc');
  const code = await new Promise<number>((r) => closed.once('close', (c: number) => r(c)));
  expect(code).toBe(1011);
  upstream.close();
  await app.close();
});

// Regression for the crash found in review: closing the client while the upstream is still
// CONNECTING used to call up.close() with no 'error' listener attached yet, and ws (8.x) emits
// 'error' asynchronously for a close()/terminate() during the handshake. An unlistened 'error'
// event is an uncaught exception that would kill the whole process, not just this request.
it('survives the client closing before the upstream connects, and keeps serving after', async () => {
  // A raw TCP server that accepts the connection but never completes the WebSocket handshake:
  // the upstream ws stays in readyState CONNECTING for as long as we need it to.
  const blackhole = createServer((socket) => socket.on('data', () => {}));
  await new Promise<void>((r) => blackhole.listen(0, '127.0.0.1', r));
  const port = (blackhole.address() as AddressInfo).port;
  const tokens = mkdtempSync(join(tmpdir(), 'vnc-'));
  writeFileSync(join(tokens, '1'), `${'cd'.repeat(16)}: localhost:5901\n`);
  const { deps } = fakeDeps((argv) => (argv[1] === 'list-units' ? { stdout: 'agentos-desktop@1.service loaded active running x\n' } : {}));

  const app = Fastify();
  app.decorateRequest('login', '');
  await app.register(fastifyWebsocket);
  vncRoutes(app, deps, `ws://127.0.0.1:${port}/websockify`, tokens);
  await app.ready();

  let crashed: unknown = null;
  const onUncaught = (e: unknown) => { crashed = e; };
  process.on('uncaughtException', onUncaught);
  try {
    const ws = await app.injectWS('/api/desktops/1/vnc');
    ws.terminate();   // the client is gone while the upstream handshake (to the blackhole) is pending
    await new Promise((r) => setTimeout(r, 100));   // give the deferred abort/'error' path time to run
  } finally {
    process.off('uncaughtException', onUncaught);
  }
  expect(crashed).toBeNull();

  // The server is still alive: a fresh connection against the same (still-pending) blackhole works.
  const again = await app.injectWS('/api/desktops/1/vnc');
  again.terminate();
  await app.close();
  blackhole.close();
});

it('never leaks the token to the client, even when the upstream connection is refused', async () => {
  const token = 'ef'.repeat(16);
  const tokens = mkdtempSync(join(tmpdir(), 'vnc-'));
  writeFileSync(join(tokens, '1'), `${token}: localhost:5901\n`);
  const { deps } = fakeDeps((argv) => (argv[1] === 'list-units' ? { stdout: 'agentos-desktop@1.service loaded active running x\n' } : {}));

  const app = Fastify();
  app.decorateRequest('login', '');
  await app.register(fastifyWebsocket);
  // Nothing listens here: the upstream connect fails immediately with ECONNREFUSED.
  vncRoutes(app, deps, 'ws://127.0.0.1:1/websockify', tokens);
  await app.ready();

  const ws = await app.injectWS('/api/desktops/1/vnc');
  const [code, reason] = await new Promise<[number, string]>((r) =>
    ws.once('close', (c: number, b: Buffer) => r([c, b.toString()])));
  expect(code).toBe(1011);
  expect(reason).not.toContain(token);
  await app.close();
});

it('is rejected by the app auth hook before reaching the token or upstream', async () => {
  const { deps } = fakeDeps();
  const app = await buildApp(deps);
  await app.ready();
  await expect(app.injectWS('/api/desktops/1/vnc', { headers: { host: H.host, origin: HM.origin } })).rejects.toThrow(/401/);
  await expect(app.injectWS('/api/desktops/1/vnc', { headers: { ...H, origin: 'https://evil.example' } })).rejects.toThrow(/403/);
  await app.close();
});
