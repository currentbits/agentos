import { describe, expect, it } from 'vitest';
import { cliOf, findAgents, originOf, parseStat, type Proc } from '../src/agents.js';

const P = (pid: number, ppid: number, args: string, ticks = 0, start = 1): Proc => ({ pid, ppid, args: args.split(' '), ticks, start });
const map = (...ps: Proc[]) => new Map(ps.map((p) => [p.pid, p]));

describe('agents', () => {
  it('parseStat: comm with spaces and parens', () => {
    const s = '42 (tmux: server (x)) S 7 42 42 0 -1 0 0 0 0 0 10 5 3 2 20 0 1 0 900 0 0';
    expect(parseStat(s)).toEqual({ ppid: 7, ticks: 20, start: 900 });
  });
  it('cliOf: binaries and node/bun scripts, not the bash wrapper', () => {
    expect(cliOf(['/home/agent/.local/bin/claude'])).toBe('claude');
    expect(cliOf(['node', '/usr/lib/node_modules/@openai/codex/bin/codex'])).toBe('codex');
    expect(cliOf(['/bin/bash', '/usr/local/bin/claude'])).toBeNull();
    expect(cliOf(['vim', 'claude'])).toBeNull();
  });
  it('findAgents: outermost CLI only, CPU of its whole tree, working threshold', () => {
    const before = map(P(1, 0, 'tmux'), P(10, 1, 'node /x/codex', 0), P(11, 10, '/v/codex', 100), P(12, 11, 'bash', 0),
      P(20, 1, '/b/claude', 50));
    const after = map(P(1, 0, 'tmux'), P(10, 1, 'node /x/codex', 0), P(11, 10, '/v/codex', 120), P(12, 11, 'bash', 30),
      P(13, 11, 'cargo', 999, 5), P(20, 1, '/b/claude', 50));
    const got = findAgents(before, after, 1).map((a) => [a.proc.pid, a.cli, a.cpuPercent, a.working]);
    expect(got).toEqual([[10, 'codex', 50, true], [20, 'claude', 0, false]]);   // 13 was born mid-sample
  });
  it('originOf: web session, Solenta, SSH, other; the agent\'s own args are ignored', () => {
    const procs = map(P(1, 0, '/sbin/init'), P(5, 1, 'tmux new-session -d -s ag-x'), P(6, 5, '/b/claude'),
      P(7, 1, '/opt/solenta/solenta-nightly --headless'), P(8, 7, '/b/codex'),
      P(9, 1, 'sshd-session: agent'), P(14, 9, 'bash'), P(15, 14, '/b/claude -p solenta'), P(16, 1, '/b/grok'));
    const panes = new Map([[6, 'ag-x']]);
    expect(originOf(6, procs, panes)).toEqual({ origin: 'Web UI', session: 'ag-x' });
    expect(originOf(8, procs, panes)).toEqual({ origin: 'Solenta', session: null });
    expect(originOf(15, procs, panes)).toEqual({ origin: 'SSH', session: null });
    expect(originOf(16, procs, panes)).toEqual({ origin: 'other', session: null });
  });
});
