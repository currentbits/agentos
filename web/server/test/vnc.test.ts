import { mkdtempSync, writeFileSync } from 'node:fs';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import fastifyWebsocket from '@fastify/websocket';
import Fastify from 'fastify';
import { expect, it } from 'vitest';
import { WebSocketServer } from 'ws';
import { parseToken, vncRoutes } from '../src/vnc.js';
import { fakeDeps } from './helpers.js';

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
