import { execFileSync } from 'node:child_process';
import { describe, expect, it, vi } from 'vitest';
import { buildApp } from '../src/app.js';
import { execRunner } from '../src/run.js';
import { attachArgv, parseClientMsg, pipePty, termSize } from '../src/terminal.js';
import { fakeDeps, H, LOGIN } from './helpers.js';

describe('terminal protocol', () => {
  it('parses client frames', () => {
    expect(parseClientMsg('{"t":"i","d":"ls\\r"}')).toEqual({ input: 'ls\r' });
    expect(parseClientMsg('{"t":"r","c":120,"r":40}')).toEqual({ cols: 120, rows: 40 });
    expect(parseClientMsg('{"t":"r","c":0,"r":40}')).toBeNull();
    expect(parseClientMsg('{"t":"r","c":1.5,"r":40}')).toBeNull();
    expect(parseClientMsg('ls')).toBeNull();
  });
  it('attaches by exact name', () => {
    expect(attachArgv('ag-x')).toEqual(['attach-session', '-t', '=ag-x']);
  });
  it('validates the initial size like resize frames, falling back to 80x24', () => {
    expect(termSize({ cols: '120', rows: '40' })).toEqual({ cols: 120, rows: 40 });
    expect(termSize({ cols: '1000', rows: '1' })).toEqual({ cols: 1000, rows: 1 });
    for (const q of [{}, { cols: '0', rows: '40' }, { cols: '-5', rows: '40' }, { cols: '1001', rows: '40' },
      { cols: '1.5', rows: '40' }, { cols: 'abc', rows: '40' }, { cols: '120' }]) {
      expect(termSize(q)).toEqual({ cols: 80, rows: 24 });
    }
  });
});

describe('terminal backpressure', () => {
  it('pauses the pty above 1 MiB buffered and resumes below 256 KiB', () => {
    const cbs: (() => void)[] = [];
    const sent: string[] = [];
    const socket = { OPEN: 1, readyState: 1, bufferedAmount: 0, send: (d: string, cb: () => void) => { sent.push(d); cbs.push(cb); } };
    let onData: (d: string) => void = () => {};
    const term = { paused: false, onData: (f: (d: string) => void) => { onData = f; }, pause() { this.paused = true; }, resume() { this.paused = false; } };
    pipePty(socket, term);
    onData('a');
    expect(term.paused).toBe(false);
    socket.bufferedAmount = 2 * 1024 * 1024;
    onData('b');
    expect(term.paused).toBe(true);
    socket.bufferedAmount = 512 * 1024;
    cbs.shift()!();
    expect(term.paused).toBe(true);
    socket.bufferedAmount = 0;
    cbs.shift()!();
    expect(term.paused).toBe(false);
    expect(sent).toEqual(['a', 'b']);
  });
});

describe('terminal route', () => {
  it('audits terminal-attach for a live session', async () => {
    const { deps, audits } = fakeDeps((argv) => (argv[1] === 'list-sessions' ? { stdout: 'ag-x:1761480000:0\n' } : {}));
    const app = await buildApp(deps);
    await app.ready();
    const ws = await app.injectWS('/api/sessions/ag-x/terminal', { headers: { ...H, origin: 'http://127.0.0.1:7070' } });
    await vi.waitFor(() => expect(audits).toEqual([`${LOGIN} terminal-attach ag-x`]));
    ws.terminate();
    await app.close();
  });
  it('closes with 1008 for a session that is not running, and audits nothing', async () => {
    const { deps, audits } = fakeDeps();
    const app = await buildApp(deps);
    await app.ready();
    const ws = await app.injectWS('/api/sessions/ag-gone/terminal', { headers: { ...H, origin: 'http://127.0.0.1:7070' } });
    const [code, reason] = await new Promise<[number, string]>((r) => ws.once('close', (c: number, b: Buffer) => r([c, b.toString()])));
    expect(code).toBe(1008);
    expect(reason).toBe('no running session ag-gone');
    expect(audits).toEqual([]);
    await app.close();
  });
});

// Needs Linux and a real tmux (CI installs it); the in-VM smoke check covers it end to end too.
const hasTmux = process.platform === 'linux' && (() => { try { execFileSync('tmux', ['-V']); return true; } catch { return false; } })();

it.skipIf(!hasTmux)('terminal WebSocket attaches to tmux, echoes typed input, and detaches on close', async () => {
  const { deps } = fakeDeps(() => ({}), { run: execRunner });
  const id = `ag-vitest-${process.pid}`;
  execFileSync('tmux', ['new-session', '-d', '-s', id, '-x', '80', '-y', '24', 'sh']);
  try {
    const app = await buildApp(deps);
    await app.ready();
    const ws = await app.injectWS(`/api/sessions/${id}/terminal?cols=80&rows=24`, { headers: { ...H, origin: 'http://127.0.0.1:7070' } });
    let out = '';
    const seen = new Promise<void>((resolve) => ws.on('message', (d: Buffer) => { out += d.toString(); if (out.includes('hi-42')) resolve(); }));
    ws.send(JSON.stringify({ t: 'i', d: 'echo hi-$((40+2))\r' }));
    await seen;
    ws.terminate();
    await new Promise((r) => setTimeout(r, 300));
    execFileSync('tmux', ['has-session', '-t', `=${id}`]);   // throws if the session was killed
    await app.close();
  } finally {
    execFileSync('tmux', ['kill-session', '-t', `=${id}`]);
  }
}, 15_000);
