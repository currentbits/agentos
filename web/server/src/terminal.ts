// Browser terminal: WebSocket <-> node-pty running `tmux attach`. Closing the socket kills only the
// tmux client (a detach); the session keeps running.
import type { FastifyInstance } from 'fastify';
import * as pty from 'node-pty';
import type { Deps } from './app.js';
import { tmuxSessions } from './sessions.js';

export type ClientMsg = { input: string } | { cols: number; rows: number } | null;

// Client frames are JSON: {"t":"i","d":"<keys>"} or {"t":"r","c":<cols>,"r":<rows>}.
export function parseClientMsg(raw: string): ClientMsg {
  try {
    const m = JSON.parse(raw);
    if (m?.t === 'i' && typeof m.d === 'string') return { input: m.d };
    if (m?.t === 'r' && Number.isInteger(m.c) && Number.isInteger(m.r) && m.c > 0 && m.r > 0 && m.c <= 1000 && m.r <= 1000) {
      return { cols: m.c, rows: m.r };
    }
  } catch { /* not JSON */ }
  return null;
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
        if (!live.some((t) => t.id === id)) return socket.close(1008, `no running session ${id}`);
        const env: NodeJS.ProcessEnv = { ...process.env, TERM: 'xterm-256color', LANG: 'C.UTF-8' };
        delete env.TMUX;   // node-pty would pass an undefined value as the string "undefined"
        try {
          term = pty.spawn('tmux', attachArgv(id), {
            name: 'xterm-256color',
            cols: Math.min(Number(req.query.cols) || 80, 1000),
            rows: Math.min(Number(req.query.rows) || 24, 1000),
            cwd: deps.home,
            env,
          });
        } catch (e) {
          return socket.close(1011, (e as Error).message.slice(0, 120));
        }
        term.onData((d) => socket.readyState === socket.OPEN && socket.send(d));
        term.onExit(() => socket.close());
        for (const d of early.splice(0)) term.write(d);
      }, (e: Error) => socket.close(1011, e.message.slice(0, 120)));
    });
}
