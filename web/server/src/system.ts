// System: health, services, journal tail and updates (streamed over WebSocket), power.
import { spawn } from 'node:child_process';
import { readFile, stat, statfs } from 'node:fs/promises';
import { hostname, loadavg } from 'node:os';
import type { FastifyInstance } from 'fastify';
import type { WebSocket } from 'ws';
import { argv, runAction, UNIT_RE } from './actions.js';
import { HttpError } from './run.js';
import type { Deps } from './app.js';
import { parseTailnetName } from './auth.js';

export interface CpuSample { idle: number; total: number }
export interface Unit { unit: string; load: string; active: string; sub: string; description: string }

export function parseCpu(procStat: string): CpuSample {
  const f = procStat.split('\n')[0].trim().split(/\s+/).slice(1).map(Number);
  return { idle: f[3] + (f[4] || 0), total: f.reduce((a, b) => a + b, 0) };
}

export function cpuPercent(a: CpuSample, b: CpuSample): number {
  const dt = b.total - a.total;
  return dt > 0 ? Math.round((100 * (dt - (b.idle - a.idle))) / dt) : 0;
}

export function parseMeminfo(text: string): { totalBytes: number; usedBytes: number } {
  const kb = (k: string) => Number(text.match(new RegExp(`^${k}:\\s+(\\d+) kB`, 'm'))?.[1] ?? 0) * 1024;
  return { totalBytes: kb('MemTotal'), usedBytes: kb('MemTotal') - kb('MemAvailable') };
}

export function parseUnits(out: string): Unit[] {
  return out.split('\n').filter(Boolean).flatMap((line) => {
    const [unit, load, active, sub, ...desc] = line.trim().split(/\s+/);
    return UNIT_RE.test(unit) ? [{ unit, load, active, sub, description: desc.join(' ') }] : [];
  });
}

export interface TailscaleState { state: string; dnsName: string | null; ip: string | null }

export function parseTailscale(json: string): TailscaleState {
  try {
    const s = JSON.parse(json);
    return { state: String(s.BackendState ?? 'unknown'), dnsName: parseTailnetName(json), ip: s.Self?.TailscaleIPs?.[0] ?? s.TailscaleIPs?.[0] ?? null };
  } catch {
    return { state: 'unavailable', dnsName: null, ip: null };
  }
}

let prevCpu: CpuSample | null = null;

export async function health() {
  const cpu = parseCpu(await readFile('/proc/stat', 'utf8'));
  const percent = prevCpu ? cpuPercent(prevCpu, cpu) : 0;
  prevCpu = cpu;
  const fs = await statfs('/');
  return {
    cpuPercent: percent,
    load: loadavg(),
    memory: parseMeminfo(await readFile('/proc/meminfo', 'utf8')),
    disk: { totalBytes: fs.blocks * fs.bsize, usedBytes: (fs.blocks - fs.bfree) * fs.bsize },
  };
}

export async function tailscale(deps: Deps): Promise<TailscaleState> {
  const r = await deps.run(['tailscale', 'status', '--json']);
  return parseTailscale(r.stdout);
}

async function lastUnattended(): Promise<string | null> {
  try {
    return (await stat('/var/lib/apt/periodic/unattended-upgrades-stamp')).mtime.toISOString();
  } catch {
    return null;
  }
}

// Stream a command's output to a WebSocket. killOnClose=false for agentos-update: closing the
// tab must not kill apt mid-upgrade.
export function streamToSocket(socket: WebSocket, args: string[], killOnClose = true): void {
  const child = spawn(args[0], args.slice(1), { stdio: ['ignore', 'pipe', 'pipe'] });
  const send = (b: Buffer) => socket.readyState === socket.OPEN && socket.send(b.toString('utf8'));
  child.stdout.on('data', send);
  child.stderr.on('data', send);
  child.on('error', (e) => { send(Buffer.from(`\n[${e.message}]\n`)); socket.close(); });
  child.on('close', (code) => { send(Buffer.from(`\n[exit ${code}]\n`)); socket.close(); });
  if (killOnClose) socket.on('close', () => child.kill());
}

export function systemRoutes(app: FastifyInstance, deps: Deps): void {
  app.get('/api/me', async (req) => {
    const ts = await tailscale(deps);
    return { login: req.login, hostname: hostname(), tailnetIp: ts.ip, tailnetName: ts.dnsName };
  });
  app.get('/api/system/health', async () => health());
  app.get('/api/system/tailscale', async () => ({ ...(await tailscale(deps)), serve: deps.webConf().serve || 'unknown' }));
  app.get('/api/system/services', async () => {
    const r = await deps.run(['systemctl', 'list-units', '--all', '--plain', '--no-legend', '--type=service',
      'agentos-*', 'docker.service', 'tailscaled.service']);
    return parseUnits(r.stdout);
  });
  app.post<{ Params: { unit: string } }>('/api/system/services/:unit/restart', async (req) => {
    const r = await runAction(deps.run, { name: 'restart', unit: req.params.unit });
    deps.audit(req.login, 'service-restart', req.params.unit);
    if (r.code !== 0) throw new HttpError(500, r.stderr.trim());
    return { ok: true };
  });
  app.get('/api/system/updates', async () => ({ lastUnattended: await lastUnattended() }));
  app.post<{ Body: { action?: string; confirm?: string } }>('/api/system/power', async (req) => {
    const action = req.body?.action;
    if (action !== 'reboot' && action !== 'poweroff') throw new HttpError(400, 'action must be reboot or poweroff');
    if (req.body?.confirm !== hostname()) throw new HttpError(400, 'type the hostname to confirm');
    deps.audit(req.login, action, hostname());
    const r = await runAction(deps.run, { name: action });
    if (r.code !== 0) throw new HttpError(500, r.stderr.trim());
    return { ok: true };
  });
  app.get<{ Querystring: { unit?: string } }>('/api/system/journal', { websocket: true }, (socket, req) => {
    try {
      streamToSocket(socket, argv({ name: 'journal', unit: req.query.unit ?? '' }));
    } catch (e) {
      socket.close(1008, (e as Error).message);
    }
  });
  app.get('/api/system/update', { websocket: true }, (socket, req) => {
    deps.audit(req.login, 'update', '-');
    streamToSocket(socket, argv({ name: 'update' }), false);
  });
}
