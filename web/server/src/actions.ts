// The fixed table of every privileged or mutating command the web UI can run. Argv only, never a
// shell string; parameters are validated here before they reach an argv.
import { HttpError, type RunOpts, type Runner, type RunResult } from './run.js';

export const CONFIG = '/usr/local/bin/agentos-config';
export const KEY_RE = /^[A-Z][A-Z0-9_]{0,63}$/;
export const UNIT_RE = /^(agentos-[a-z0-9@-]+|docker|tailscaled)\.service$/;
export const FINGERPRINT_RE = /^SHA256:[A-Za-z0-9+/]{43}$/;
export const GITHUB_USER_RE = /^[A-Za-z0-9-]{1,39}$/;
export const DESKTOP_RE = /^([1-9]|1[0-6])$/;
export const SOLENTA_PAIR = '/usr/local/lib/agentos/solenta-pair';
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
  | { name: 'reboot' }
  | { name: 'poweroff' }
  | { name: 'desktop-start'; n: number }
  | { name: 'desktop-stop'; n: number }
  | { name: 'solenta-status'; path?: string };          // runs as agent (this service's user): no sudo

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
    case 'update': return ['/usr/local/bin/agentos-update'];
    case 'reboot': return [...sudo, 'systemctl', 'reboot'];
    case 'poweroff': return [...sudo, 'systemctl', 'poweroff'];
    case 'desktop-start': need(DESKTOP_RE.test(String(a.n)), 'desktop'); return ['systemctl', '--no-ask-password', 'start', `agentos-desktop@${a.n}.service`];
    case 'desktop-stop': need(DESKTOP_RE.test(String(a.n)), 'desktop'); return ['systemctl', '--no-ask-password', 'stop', `agentos-desktop@${a.n}.service`];
    case 'solenta-status': if (a.path !== undefined) need(ABS_PATH_RE.test(a.path), 'path');
      return [SOLENTA_PAIR, 'status', ...(a.path ? ['--', a.path] : [])];
  }
}

export async function runAction(run: Runner, a: Action, opts?: RunOpts): Promise<RunResult> {
  return run(argv(a), opts);
}
