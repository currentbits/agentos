// Same-origin VNC: the browser connects to /api/desktops/N/vnc; we open websockify with the
// desktop's token, so the token never reaches the browser.
import { readFile } from 'node:fs/promises';
import type { FastifyInstance } from 'fastify';
import WebSocket from 'ws';
import type { Deps } from './app.js';
import { activeDesktops, desktopNumber } from './desktops.js';
import { HttpError } from './run.js';

export const TOKEN_DIR = '/run/agentos/vnc';
export const WEBSOCKIFY = 'ws://127.0.0.1:6080/websockify';

// Token file format (vnc-token): "<token>: localhost:<port>".
export function parseToken(text: string): string {
  const t = text.split(':', 1)[0].trim();
  if (!/^[0-9a-f]{32}$/.test(t)) throw new Error('bad token file');
  return t;
}

// Client listeners are attached synchronously: frames that arrive while we're still looking up
// the token are queued, not lost.
export function pipeSockets(client: WebSocket, connect: () => Promise<WebSocket>): void {
  const pending: Buffer[] = [];
  let upstream: WebSocket | null = null;
  client.on('message', (d: Buffer) => (upstream?.readyState === WebSocket.OPEN ? upstream.send(d) : pending.push(d)));
  client.on('close', () => upstream?.close());
  connect().then((up) => {
    upstream = up;
    // Attach the error listener before any close() below: closing a still-CONNECTING ws (ws 8.x)
    // emits 'error' asynchronously, and an 'error' event with no listener crashes the process.
    up.on('error', () => client.close(1011, 'upstream error'));
    if (client.readyState !== WebSocket.OPEN) return up.close();
    up.on('open', () => { for (const d of pending.splice(0)) up.send(d); });
    up.on('message', (d: Buffer) => client.readyState === WebSocket.OPEN && client.send(d));
    up.on('close', () => client.close());
  // Never forward e.message verbatim: a readFile failure on the token file names its path, and
  // future errors are not guaranteed to stay harmless. Only a recognized HttpError's message
  // (always written by this codebase, never raw I/O detail) reaches the client.
  }, (e: unknown) => client.close(1011, e instanceof HttpError ? e.message.slice(0, 120) : 'proxy error'));
}

export function vncRoutes(app: FastifyInstance, deps: Deps, upstreamBase = WEBSOCKIFY, tokenDir = TOKEN_DIR): void {
  app.get<{ Params: { n: string } }>('/api/desktops/:n/vnc', { websocket: true }, (socket, req) => {
    pipeSockets(socket, async () => {
      const n = desktopNumber(req.params.n);
      if (!(await activeDesktops(deps)).includes(n)) throw new Error(`desktop ${n} is not running`);
      const token = parseToken(await readFile(`${tokenDir}/${n}`, 'utf8'));
      return new WebSocket(`${upstreamBase}?token=${token}`, ['binary']);
    });
  });
}
