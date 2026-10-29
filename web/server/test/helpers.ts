import { mkdtempSync, realpathSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { RunOpts, RunResult } from '../src/run.js';
import type { Deps } from '../src/app.js';
import { parseWebConf } from '../src/auth.js';

export const LOGIN = 'alice@example.com';
export const HOST = '127.0.0.1:7070';
export const ORIGIN = 'http://127.0.0.1:7070';
export const H = { host: HOST, 'tailscale-user-login': LOGIN };
export const HM = { ...H, origin: ORIGIN, 'x-agentos': '1' };   // headers for mutating requests

export interface Call { argv: string[]; opts?: RunOpts }

// A fake runner: records every call; `reply` maps argv to a result (default: success, no output).
export function fakeDeps(reply: (argv: string[], opts?: RunOpts) => Partial<RunResult> = () => ({}), over: Partial<Deps> = {}) {
  const calls: Call[] = [];
  const audits: string[] = [];
  const deps: Deps = {
    run: async (argv, opts) => {
      calls.push({ argv: [...argv], opts });
      return { code: 0, stdout: '', stderr: '', ...reply([...argv], opts) };
    },
    webConf: () => parseWebConf(`USERS=${LOGIN}\n`),
    tsName: async () => null,
    audit: (login, action, target) => audits.push(`${login} ${action} ${target}`),
    home: realpathSync(mkdtempSync(join(tmpdir(), 'agentos-web-home-'))),
    uiRoot: null,
    novncRoot: null,
    vncTokenDir: realpathSync(mkdtempSync(join(tmpdir(), 'agentos-web-vnc-'))),
    bridgePath: fileURLToPath(new URL('../../../tools/solenta-bridge', import.meta.url)),
    updateState: join(realpathSync(mkdtempSync(join(tmpdir(), 'agentos-web-update-'))), 'update.json'),
    updateLog: join(realpathSync(mkdtempSync(join(tmpdir(), 'agentos-web-update-'))), 'agentos-update.log'),
    ...over,
  };
  return { deps, calls, audits };
}
