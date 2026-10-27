// Browser terminal: WebSocket <-> node-pty running `tmux attach`. Closing the socket kills only the
// tmux client (a detach); the session keeps running.
import type { FastifyInstance } from 'fastify';
import * as pty from 'node-pty';
import type { Deps } from './app.js';
import { tmuxSessions } from './sessions.js';

export type ClientMsg = { input: string } | { cols: number; rows: number } | null;

const validSize = (c: unknown, r: unknown) =>
  Number.isInteger(c) && Number.isInteger(r) && (c as number) >= 1 && (r as number) >= 1 && (c as number) <= 1000 && (r as number) <= 1000;

// Client frames are JSON: {"t":"i","d":"<keys>"} or {"t":"r","c":<cols>,"r":<rows>}.
export function parseClientMsg(raw: string): ClientMsg {
  try {
    const m = JSON.parse(raw);
    if (m?.t === 'i' && typeof m.d === 'string') return { input: m.d };
    if (m?.t === 'r' && validSize(m.c, m.r)) return { cols: m.c, rows: m.r };
  } catch { /* not JSON */ }
  return null;
}

// The initial size from the query string: the same 1..1000 rule as a resize frame, else 80x24.
export function termSize(q: { cols?: string; rows?: string }): { cols: number; rows: number } {
  const cols = /^\d+$/.test(q.cols ?? '') ? Number(q.cols) : NaN;
  const rows = /^\d+$/.test(q.rows ?? '') ? Number(q.rows) : NaN;
  return validSize(cols, rows) ? { cols, rows } : { cols: 80, rows: 24 };
}

const HIGH_WATER = 1024 * 1024;
const LOW_WATER = 256 * 1024;

type PtyOut = Pick<pty.IPty, 'pause' | 'resume'> & { onData: (f: (d: string) => void) => unknown };
type SockOut = { readyState: number; OPEN: number; bufferedAmount: number; send: (d: string, cb: (err?: Error) => void) => void };

// pty -> socket with backpressure: a slow browser pauses the pty (and so tmux) instead of letting
// the socket buffer grow without bound. Each send's callback fires once that frame is flushed.
export function pipePty(socket: SockOut, term: PtyOut): void {
  let paused = false;
  term.onData((d) => {
    if (socket.readyState !== socket.OPEN) return;
    socket.send(d, () => {
      if (paused && socket.bufferedAmount < LOW_WATER) { paused = false; term.resume(); }
    });
    if (!paused && socket.bufferedAmount > HIGH_WATER) { paused = true; term.pause(); }
  });
}

export function attachArgv(id: string): string[] {
  return ['attach-session', '-t', `=${id}`];   // "=": exact session name, no prefix matching
}

export function terminalRoutes(app: FastifyInstance, deps: Deps): void {
  app.get<{ Params: { id: string }; Querystring: { cols?: string; rows?: string } }>(
    '/api/sessions/:id/terminal', { websocket: true }, (socket, req) => {
      const id = req.params.id;
      let term: pty.IPty | null = null;
      const early: string[] = [];   // keys typed before the pty exists
      socket.on('message', (raw: Buffer) => {
        const m = parseClientMsg(raw.toString('utf8'));
        if (!m) return;
        if (!term) { if ('input' in m) early.push(m.input); }
        else if ('input' in m) term.write(m.input);
        else term.resize(m.cols, m.rows);
      });
      socket.on('close', () => term?.kill());
      tmuxSessions(deps).then((live) => {
        if (socket.readyState !== socket.OPEN) return;
        if (!live.some((t) => t.id === id)) return socket.close(1008, `no running session ${id}`.slice(0, 100));
        deps.audit(req.login, 'terminal-attach', id);
        const env: NodeJS.ProcessEnv = { ...process.env, TERM: 'xterm-256color', LANG: 'C.UTF-8' };
        delete env.TMUX;   // node-pty would pass an undefined value as the string "undefined"
        try {
          term = pty.spawn('tmux', attachArgv(id), {
            name: 'xterm-256color',
            ...termSize(req.query),
            cwd: deps.home,
            env,
          });
        } catch (e) {
          return socket.close(1011, (e as Error).message.slice(0, 100));
        }
        pipePty(socket, term);
        term.onExit(() => socket.close());
        for (const d of early.splice(0)) term.write(d);
      }).catch((e: Error) => socket.close(1011, String(e?.message).slice(0, 100)));
    });
}
