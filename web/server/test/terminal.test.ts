import { execFileSync } from 'node:child_process';
import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { execRunner } from '../src/run.js';
import { attachArgv, parseClientMsg } from '../src/terminal.js';
import { fakeDeps, H } from './helpers.js';

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
