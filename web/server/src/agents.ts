// Agents: every claude/codex/opencode/grok process the agent user runs, however it was started
// (web UI session, Solenta, SSH, CI), with a working/idle guess from the CPU its process tree used.
import { readdir, readFile, readlink, stat } from 'node:fs/promises';
import type { FastifyInstance } from 'fastify';
import type { Deps } from './app.js';

export const AGENT_CLIS = ['claude', 'codex', 'opencode', 'grok'];
const HZ = 100;              // ponytail: USER_HZ is 100 on every Linux AgentOS ships for
const SAMPLE_MS = 500;
export const WORKING_PCT = 5;  // of one core, agent plus its tools; an idle CLI sits near 0-1 %

export interface Proc { pid: number; ppid: number; args: string[]; ticks: number; start: number }
export interface Agent {
  pid: number; cli: string; dir: string | null; started: string; cpuPercent: number; working: boolean;
  origin: 'Web UI' | 'tmux' | 'Solenta' | 'SSH' | 'CI' | 'other'; session: string | null;
}

// /proc/<pid>/stat: comm (field 2) may hold spaces and ')', so split after the last ')'. Ticks count
// reaped children too (cutime/cstime), so a tool that ran and exited between samples still counts.
export function parseStat(s: string): { ppid: number; ticks: number; start: number } {
  const f = s.slice(s.lastIndexOf(')') + 2).split(' ').map(Number);
  return { ppid: f[1], ticks: f[11] + f[12] + f[13] + f[14], start: f[19] };
}

const base = (p = '') => p.slice(p.lastIndexOf('/') + 1);
// The CLI's own binary (claude, codex's native binary, opencode), or node/bun running its script.
export function cliOf(args: string[]): string | null {
  const b = base(args[0]);
  if (AGENT_CLIS.includes(b)) return b;
  return ['node', 'bun'].includes(b) && AGENT_CLIS.includes(base(args[1])) ? base(args[1]) : null;
}

function ancestors(pid: number, procs: Map<number, Proc>): Proc[] {
  const out: Proc[] = [];
  for (let p = procs.get(procs.get(pid)?.ppid ?? 0); p && out.length < 64; p = procs.get(p.ppid)) out.push(p);
  return out;
}

// Nearest recognisable launcher above the agent. panes: tmux pane pid -> session (default socket).
export function originOf(pid: number, procs: Map<number, Proc>, panes: Map<number, string>): Pick<Agent, 'origin' | 'session'> {
  for (const p of [procs.get(pid)!, ...ancestors(pid, procs)]) {
    const session = panes.get(p.pid);
    if (session) return { origin: session.startsWith('ag-') ? 'Web UI' : 'tmux', session };
    if (p.pid === pid) continue;   // the agent's own args can mention anything (a -p prompt)
    const cmd = p.args.join(' ');
    if (/solenta/i.test(cmd)) return { origin: 'Solenta', session: null };
    if (/^tmux/.test(base(p.args[0]))) return { origin: 'tmux', session: null };   // another tmux socket
    if (/agentos\/ci\/|(^|\/)act /.test(cmd)) return { origin: 'CI', session: null };
    if (/^sshd|tailscaled be-child ssh/.test(base(p.args[0]) + ' ' + p.args.slice(1).join(' '))) return { origin: 'SSH', session: null };
  }
  return { origin: 'other', session: null };
}

// Agent processes, outermost only (codex's node launcher, not also its native child), with the
// CPU their whole tree used between two snapshots.
export function findAgents(before: Map<number, Proc>, after: Map<number, Proc>, seconds: number) {
  const kids = new Map<number, number[]>();
  for (const p of after.values()) kids.set(p.ppid, [...(kids.get(p.ppid) ?? []), p.pid]);
  const tree = (pid: number): number[] => [pid, ...(kids.get(pid) ?? []).flatMap(tree)];
  const ticks = (m: Map<number, Proc>, pids: number[]) => pids.reduce((t, q) => t + (m.get(q)?.ticks ?? 0), 0);
  return [...after.values()]
    .filter((p) => cliOf(p.args) && !ancestors(p.pid, after).some((a) => cliOf(a.args)))
    .map((p) => {
      const pids = tree(p.pid).filter((q) => before.get(q)?.start === after.get(q)?.start);   // skip pids born mid-sample
      const cpuPercent = Math.round((100 * (ticks(after, pids) - ticks(before, pids))) / HZ / seconds);
      return { proc: p, cli: cliOf(p.args)!, cpuPercent, working: cpuPercent >= WORKING_PCT };
    });
}

async function snapshot(uid: number): Promise<Map<number, Proc>> {
  const out = new Map<number, Proc>();
  await Promise.all((await readdir('/proc')).filter((d) => /^\d+$/.test(d)).map(async (d) => {
    try {
      if ((await stat(`/proc/${d}`)).uid !== uid) return;
      const [s, cmd] = await Promise.all([readFile(`/proc/${d}/stat`, 'utf8'), readFile(`/proc/${d}/cmdline`, 'utf8')]);
      out.set(Number(d), { pid: Number(d), args: cmd.split('\0').filter(Boolean), ...parseStat(s) });
    } catch { /* exited while we looked */ }
  }));
  return out;
}

export async function listAgents(deps: Deps): Promise<Agent[]> {
  const uid = process.getuid!();
  const before = await snapshot(uid);
  const t0 = Date.now();
  await new Promise((r) => setTimeout(r, SAMPLE_MS));
  const after = await snapshot(uid);
  const seconds = (Date.now() - t0) / 1000;
  const r = await deps.run(['tmux', 'list-panes', '-a', '-F', '#{pane_pid} #{session_name}']);
  const panes = new Map(r.code === 0 ? r.stdout.split('\n').filter(Boolean).map((l) => {
    const [pid, ...name] = l.split(' ');
    return [Number(pid), name.join(' ')] as [number, string];
  }) : []);
  const btime = Number((await readFile('/proc/stat', 'utf8')).match(/^btime (\d+)/m)?.[1] ?? 0);
  return Promise.all(findAgents(before, after, seconds).map(async ({ proc, ...a }) => ({
    pid: proc.pid,
    ...a,
    dir: await readlink(`/proc/${proc.pid}/cwd`).then((d) => (d === deps.home || d.startsWith(`${deps.home}/`) ? `~${d.slice(deps.home.length)}` : d), () => null),
    started: new Date((btime + proc.start / HZ) * 1000).toISOString(),
    ...originOf(proc.pid, after, panes),
  }))).then((l) => l.sort((x, y) => Number(y.working) - Number(x.working) || x.started.localeCompare(y.started)));
}

export function agentRoutes(app: FastifyInstance, deps: Deps): void {
  app.get('/api/agents', async () => listAgents(deps));
}
