// Desktops: systemd agentos-desktop@N (agent may start/stop them via polkit), thumbnails via scrot.
import { mkdtemp, readdir, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { FastifyInstance } from 'fastify';
import { DESKTOP_RE, runAction } from './actions.js';
import { HttpError } from './run.js';
import type { Deps } from './app.js';

export const DESKTOP_CONF = '/etc/agentos/desktop.conf';
export const LAST_DIR = '/run/agentos/desktops';

export interface DesktopConf { max: number; idleMinutes: number }
export interface Desktop { id: number; idleSeconds: number | null; idleLimitMinutes: number; viewers: number }

export function parseDesktopConf(text: string): DesktopConf {
  const num = (k: string, def: number, lo: number, hi: number) => {
    const v = Number(text.match(new RegExp(`^${k}=(\\d+)$`, 'm'))?.[1]);
    return Number.isInteger(v) && v >= lo && v <= hi ? v : def;
  };
  return { max: num('MAX_DESKTOPS', 8, 1, 16), idleMinutes: num('IDLE_MINUTES', 120, 0, 999999) };
}

export function parseActive(out: string): number[] {
  return [...new Set([...out.matchAll(/^agentos-desktop@(\d+)\.service\b/gm)].map((m) => Number(m[1])))].sort((a, b) => a - b);
}

export function lowestFree(active: number[], max: number): number | null {
  for (let n = 1; n <= max; n++) if (!active.includes(n)) return n;
  return null;
}

export function desktopNumber(s: string): number {
  if (!DESKTOP_RE.test(s)) throw new HttpError(400, 'invalid desktop');
  return Number(s);
}

async function conf(): Promise<DesktopConf> {
  try { return parseDesktopConf(await readFile(DESKTOP_CONF, 'utf8')); } catch { return parseDesktopConf(''); }
}

export async function activeDesktops(deps: Deps): Promise<number[]> {
  const r = await deps.run(['systemctl', 'list-units', 'agentos-desktop@*', '--state=active', '--plain', '--no-legend']);
  return parseActive(r.stdout);
}

async function needActive(deps: Deps, n: number): Promise<void> {
  if (!(await activeDesktops(deps)).includes(n)) throw new HttpError(404, `desktop ${n} is not running`);
}

export async function listDesktops(deps: Deps): Promise<Desktop[]> {
  const c = await conf();
  return Promise.all((await activeDesktops(deps)).map(async (id) => {
    let idleSeconds: number | null = null;
    try { idleSeconds = Math.max(0, Math.round((Date.now() - (await stat(join(LAST_DIR, `${id}.last`))).mtimeMs) / 1000)); } catch { /* no .last yet */ }
    const ss = await deps.run(['ss', '-Htn', 'state', 'established', `( sport = :${5900 + id} )`]);
    return { id, idleSeconds, idleLimitMinutes: c.idleMinutes, viewers: ss.stdout.split('\n').filter(Boolean).length };
  }));
}

// ponytail: no lock shared with agentos-computer's create_desktop; a simultaneous MCP create can
// pick the same N. Wrap pick+start in flock(1) on /tmp/agentos-desktop.lock if that ever bites.
export async function createDesktop(deps: Deps, login: string): Promise<{ id: number }> {
  const { max } = await conf();
  const n = lowestFree(await activeDesktops(deps), max);
  if (n === null) throw new HttpError(409, `all ${max} desktops are in use; destroy one first`);
  const r = await runAction(deps.run, { name: 'desktop-start', n });
  if (r.code !== 0) throw new HttpError(500, `could not start desktop ${n}: ${r.stderr.trim()}`);
  deps.audit(login, 'desktop-create', String(n));
  for (let i = 0; i < 150; i++) {
    const x = await deps.run(['xdotool', 'getdisplaygeometry'], { env: { ...process.env, DISPLAY: `:${n}` } });
    if (x.code === 0) return { id: n };
    await new Promise((res) => setTimeout(res, 200));
  }
  throw new HttpError(500, `desktop ${n} did not come up`);
}

export async function destroyDesktop(deps: Deps, n: number, login: string): Promise<void> {
  await needActive(deps, n);
  const r = await runAction(deps.run, { name: 'desktop-stop', n });
  if (r.code !== 0) throw new HttpError(500, `could not stop desktop ${n}: ${r.stderr.trim()}`);
  deps.audit(login, 'desktop-destroy', String(n));
}

// scrot --thumb 25 also writes a 25 % copy (1920 px -> 480 px wide) named <file>-thumb.png.
export async function thumbnail(deps: Deps, n: number): Promise<Buffer> {
  await needActive(deps, n);
  const d = await mkdtemp(join(tmpdir(), 'agentos-web-thumb-'));
  try {
    const r = await deps.run(['scrot', '--overwrite', '--thumb', '25', join(d, 's.png')], { env: { ...process.env, DISPLAY: `:${n}` } });
    if (r.code !== 0) throw new HttpError(500, `scrot failed: ${r.stderr.trim()}`);
    const thumb = (await readdir(d)).find((f) => f.includes('-thumb'));
    if (!thumb) throw new HttpError(500, 'scrot wrote no thumbnail');
    return await readFile(join(d, thumb));
  } finally {
    await rm(d, { recursive: true, force: true });
  }
}

export function desktopRoutes(app: FastifyInstance, deps: Deps): void {
  app.get('/api/desktops', async () => ({ max: (await conf()).max, desktops: await listDesktops(deps) }));
  app.post('/api/desktops', async (req, reply) => reply.code(201).send(await createDesktop(deps, req.login)));
  app.delete<{ Params: { n: string } }>('/api/desktops/:n', async (req) => {
    await destroyDesktop(deps, desktopNumber(req.params.n), req.login);
    return { ok: true };
  });
  app.get<{ Params: { n: string } }>('/api/desktops/:n/thumbnail', async (req, reply) =>
    reply.type('image/png').header('cache-control', 'no-store').send(await thumbnail(deps, desktopNumber(req.params.n))));
}
