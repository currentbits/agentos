// The fixed table of every privileged or mutating command the web UI can run. Argv only, never a
// shell string; parameters are validated here before they reach an argv.
import { HttpError, type RunOpts, type Runner, type RunResult } from './run.js';

export const CONFIG = '/usr/local/bin/agentos-config';
export const KEY_RE = /^[A-Z][A-Z0-9_]{0,63}$/;
export const UNIT_RE = /^(agentos-[a-z0-9@-]+|docker|tailscaled)\.service$/;
export const FINGERPRINT_RE = /^SHA256:[A-Za-z0-9+/]{43}$/;
export const GITHUB_USER_RE = /^[A-Za-z0-9-]{1,39}$/;
export const DESKTOP_RE = /^([1-9]|1[0-6])$/;
export const CI = '/usr/local/bin/agentos-ci';
export const SOLENTA_PAIR = '/usr/local/lib/agentos/solenta-pair';
export const CI_ID_RE = /^\d{8}-\d{6}-[0-9a-f]{4}$/;
export const UPDATE = '/usr/local/bin/agentos-update';
export const CHECK_PASSWORD = '/usr/local/lib/agentos/check-password';
export const UPDATE_LOCK = '/run/lock/agentos-update.lock';
export const STEP_RE = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/;
export const GIT_REF_RE = /^[A-Za-z0-9_][A-Za-z0-9_./@^~{}-]{0,254}$/;   // agentos-ci's REF_RE
const ABS_PATH_RE = /^\/[^\0\n]*$/;

export type Action =
  | { name: 'config-set'; key: string }            // value goes on stdin, never in argv (sudo logs argv)
  | { name: 'config-get'; key: string }
  | { name: 'config-apply' }
  | { name: 'add-ssh-key' }                          // key on stdin
  | { name: 'remove-ssh-key'; fingerprint: string }
  | { name: 'github-keys'; user: string }
  | { name: 'restart'; unit: string }
  | { name: 'journal'; unit: string }
  | { name: 'update' }
  | { name: 'update-check' }                         // as root: refreshes only the AgentOS source
  | { name: 'update-version' }
  | { name: 'update-running' }                       // exits non-zero while agentos-update holds its lock
  | { name: 'check-password' }                      // the password on stdin, never argv
  | { name: 'reboot' }
  | { name: 'poweroff' }
  | { name: 'desktop-start'; n: number }
  | { name: 'desktop-stop'; n: number }
  // agentos-ci and solenta-pair run as agent (this service's user): no sudo.
  | { name: 'ci-run'; path: string; ref: string }
  | { name: 'ci-status'; id: string }
  | { name: 'ci-list'; repo?: string; limit: number }
  | { name: 'ci-cancel'; id: string }
  | { name: 'ci-log'; id: string; step: string }       // streamed: logs --follow
  | { name: 'ci-remotes' }
  | { name: 'solenta-status'; path?: string };

function need(ok: boolean, what: string): void {
  if (!ok) throw new HttpError(400, `invalid ${what}`);
}

export function argv(a: Action): string[] {
  const sudo = ['sudo', '-n'];
  switch (a.name) {
    case 'config-set': need(KEY_RE.test(a.key), 'key'); return [...sudo, CONFIG, 'set', a.key, '-'];
    case 'config-get': need(KEY_RE.test(a.key), 'key'); return [...sudo, CONFIG, 'get', a.key];
    case 'config-apply': return [...sudo, CONFIG, 'apply'];
    case 'add-ssh-key': return [...sudo, CONFIG, 'add-ssh-key', '-'];
    case 'remove-ssh-key': need(FINGERPRINT_RE.test(a.fingerprint), 'fingerprint'); return [...sudo, CONFIG, 'remove-ssh-key', a.fingerprint];
    case 'github-keys': need(GITHUB_USER_RE.test(a.user), 'GitHub user'); return [...sudo, CONFIG, 'github-keys', a.user];
    case 'restart': need(UNIT_RE.test(a.unit), 'unit'); return [...sudo, 'systemctl', 'restart', a.unit];
    case 'journal': need(UNIT_RE.test(a.unit), 'unit'); return [...sudo, 'journalctl', '-u', a.unit, '-f', '-n', '200', '-o', 'short-iso'];
    case 'update': return [UPDATE];
    case 'update-check': return [...sudo, UPDATE, '--check'];
    case 'update-version': return [UPDATE, '--version'];
    case 'update-running': return ['flock', '-n', UPDATE_LOCK, 'true'];
    case 'check-password': return [...sudo, CHECK_PASSWORD];
    case 'reboot': return [...sudo, 'systemctl', 'reboot'];
    case 'poweroff': return [...sudo, 'systemctl', 'poweroff'];
    case 'desktop-start': need(DESKTOP_RE.test(String(a.n)), 'desktop'); return ['systemctl', '--no-ask-password', 'start', `agentos-desktop@${a.n}.service`];
    case 'desktop-stop': need(DESKTOP_RE.test(String(a.n)), 'desktop'); return ['systemctl', '--no-ask-password', 'stop', `agentos-desktop@${a.n}.service`];
    case 'ci-run': need(ABS_PATH_RE.test(a.path), 'path'); need(GIT_REF_RE.test(a.ref), 'ref');
      return [CI, 'run', '--json', '--source', 'web', '--ref', a.ref, '--', a.path];
    case 'ci-status': need(CI_ID_RE.test(a.id), 'run id'); return [CI, 'status', '--json', a.id];
    case 'ci-list': need(Number.isInteger(a.limit) && a.limit >= 1 && a.limit <= 200, 'limit');
      if (a.repo !== undefined) need(ABS_PATH_RE.test(a.repo), 'repo');
      return [CI, 'list', '--json', '--limit', String(a.limit), ...(a.repo ? [`--repo=${a.repo}`] : [])];
    case 'ci-cancel': need(CI_ID_RE.test(a.id), 'run id'); return [CI, 'cancel', '--json', a.id];
    case 'ci-log': need(CI_ID_RE.test(a.id), 'run id'); need(a.step === '' || STEP_RE.test(a.step), 'step');
      return [CI, 'logs', a.id, '--follow', ...(a.step ? [`--step=${a.step}`] : [])];
    case 'ci-remotes': return [CI, 'remote', 'list', '--json'];
    case 'solenta-status': if (a.path !== undefined) need(ABS_PATH_RE.test(a.path), 'path');
      return [SOLENTA_PAIR, 'status', ...(a.path ? ['--', a.path] : [])];
  }
}

export async function runAction(run: Runner, a: Action, opts?: RunOpts): Promise<RunResult> {
  return run(argv(a), opts);
}
