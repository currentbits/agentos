import { EventEmitter } from 'node:events';
import { hostname } from 'node:os';
import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { cpuPercent, parseCpu, parseMeminfo, parseTailscale, parseUnits, streamToSocket } from '../src/system.js';
import { fakeDeps, HM, LOGIN } from './helpers.js';

// A minimal fake WebSocket: an EventEmitter with the bits streamToSocket touches.
function fakeSocket() {
  const s = new EventEmitter() as EventEmitter & { readyState: number; OPEN: number; sent: string[]; send: (d: string) => void; close: () => void };
  s.OPEN = 1;
  s.readyState = 1;
  s.sent = [];
  s.send = (d: string) => s.sent.push(d);
  s.close = () => { s.readyState = 3; s.emit('close'); };
  return s;
}

const delay = (ms: number) => new Promise((r) => setTimeout(r, ms));
const alive = (pid: number) => { try { process.kill(pid, 0); return true; } catch { return false; } };
// A child that prints its own pid then idles, so the test can check whether it survived a close.
const PID_SCRIPT = ['node', '-e', 'process.stdout.write(String(process.pid));setInterval(()=>{},1000)'];

describe('system parsers', () => {
  it('cpu, memory', () => {
    const a = parseCpu('cpu  100 0 100 800 0 0 0 0 0 0\ncpu0 1');
    const b = parseCpu('cpu  150 0 150 900 0 0 0 0 0 0\n');
    expect(cpuPercent(a, b)).toBe(50);
    expect(parseMeminfo('MemTotal:       4000 kB\nMemFree: 1 kB\nMemAvailable:   1000 kB\n')).toEqual({ totalBytes: 4096000, usedBytes: 3072000 });
  });
  it('units: keeps only allowlisted services', () => {
    const out = 'agentos-web.service loaded active running AgentOS web UI\nssh.service loaded active running OpenBSD\ndocker.service loaded active running Docker\n';
    expect(parseUnits(out)).toEqual([
      { unit: 'agentos-web.service', load: 'loaded', active: 'active', sub: 'running', description: 'AgentOS web UI' },
      { unit: 'docker.service', load: 'loaded', active: 'active', sub: 'running', description: 'Docker' },
    ]);
  });
  it('tailscale', () => {
    expect(parseTailscale('{"BackendState":"Running","Self":{"DNSName":"b.t.ts.net.","TailscaleIPs":["100.1.2.3"]}}'))
      .toEqual({ state: 'Running', dnsName: 'b.t.ts.net', ip: '100.1.2.3' });
    expect(parseTailscale('')).toEqual({ state: 'unavailable', dnsName: null, ip: null });
  });
  it('power needs the hostname typed', async () => {
    const { deps, calls, audits } = fakeDeps();
    const app = await buildApp(deps);
    expect((await app.inject({ method: 'POST', url: '/api/system/power', headers: HM, payload: { action: 'reboot', confirm: 'wrong' } })).statusCode).toBe(400);
    expect((await app.inject({ method: 'POST', url: '/api/system/power', headers: HM, payload: { action: 'halt', confirm: 'x' } })).statusCode).toBe(400);
    expect(calls).toEqual([]);
    expect((await app.inject({ method: 'POST', url: '/api/system/power', headers: HM, payload: { action: 'poweroff', confirm: hostname() } })).statusCode).toBe(200);
    expect(calls.at(-1)!.argv).toEqual(['sudo', '-n', 'systemctl', 'poweroff']);
    expect(audits).toEqual([`${LOGIN} poweroff ${hostname()}`]);
  });
  it('restart only allowlisted units', async () => {
    const { deps, calls } = fakeDeps();
    const app = await buildApp(deps);
    expect((await app.inject({ method: 'POST', url: '/api/system/services/ssh.service/restart', headers: HM })).statusCode).toBe(400);
    expect(calls).toEqual([]);
    expect((await app.inject({ method: 'POST', url: '/api/system/services/docker.service/restart', headers: HM })).statusCode).toBe(200);
    expect(calls.at(-1)!.argv).toEqual(['sudo', '-n', 'systemctl', 'restart', 'docker.service']);
  });
  it('pauses the command while the socket is backed up, resumes once it drains', async () => {
    const cbs: (() => void)[] = [];
    const sent: string[] = [];
    const s = Object.assign(new EventEmitter(), { OPEN: 1, readyState: 1, bufferedAmount: 0,
      send: (d: string, cb: () => void) => { sent.push(d); cbs.push(cb); }, close: () => {} });
    const child = streamToSocket(s as never, ['node', '-e', 'setInterval(()=>process.stdout.write("x".repeat(1000)),5)']);
    while (sent.length === 0) await delay(10);
    s.bufferedAmount = 2 * 1024 * 1024;
    while (!child.stdout!.isPaused()) await delay(10);
    s.bufferedAmount = 0;
    cbs.at(-1)!();
    expect(child.stdout!.isPaused()).toBe(false);
    child.kill();
  });

  it('kills the journal stream on socket close, but leaves the update stream running', async () => {
    const journal = fakeSocket();
    streamToSocket(journal, PID_SCRIPT, true);
    while (journal.sent.join('').length === 0) await delay(10);
    const journalPid = Number(journal.sent.join(''));
    expect(alive(journalPid)).toBe(true);
    journal.close();
    await delay(200);
    expect(alive(journalPid)).toBe(false);

    const update = fakeSocket();
    streamToSocket(update, PID_SCRIPT, false);
    while (update.sent.join('').length === 0) await delay(10);
    const updatePid = Number(update.sent.join(''));
    update.close();
    await delay(200);
    expect(alive(updatePid)).toBe(true);
    process.kill(updatePid, 'SIGKILL');
  });
});
