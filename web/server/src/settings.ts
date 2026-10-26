// Settings via agentos-config. Secret values are write-only: responses carry only "set / not set",
// derived from the key names in secrets.env; values go to agentos-config on stdin, never in argv.
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import type { FastifyInstance } from 'fastify';
import { runAction } from './actions.js';
import { HttpError } from './run.js';
import type { Deps } from './app.js';

export const SECRET_KEYS = ['ANTHROPIC_API_KEY', 'OPENAI_API_KEY', 'GROK_CODE_XAI_API_KEY', 'CLAUDE_CODE_OAUTH_TOKEN'];
// TS_AUTHKEY is write-only too, and its state can't be read (agentos.env is root-only and
// firstboot deletes it once used): the UI shows Tailscale's own status instead.
export const WRITE_ONLY_KEYS = [...SECRET_KEYS, 'TS_AUTHKEY'];
export const PLAIN_KEYS = ['AGENTOS_LAN_SSH', 'AGENTOS_CONSOLE', 'AGENTOS_AUTO_REBOOT', 'AGENTOS_MAX_DESKTOPS',
  'AGENTOS_SCREENSHOT_WIDTH', 'AGENTOS_DESKTOP_IDLE_MINUTES', 'AGENTOS_WEB_USERS', 'AGENTOS_WEB'];

export interface SettingsView { values: Record<string, string>; secrets: Record<string, boolean> }

// Names only: the regex captures the key and never looks past "=".
export function secretNames(secretsEnv: string): Set<string> {
  return new Set([...secretsEnv.matchAll(/^([A-Z0-9_]+)=./gm)].map((m) => m[1]));
}

export async function getSettings(deps: Deps): Promise<SettingsView> {
  const values: Record<string, string> = {};
  for (const key of PLAIN_KEYS) {
    const r = await runAction(deps.run, { name: 'config-get', key });
    values[key] = r.code === 0 ? r.stdout.trim() : '';
  }
  let text = '';
  try { text = await readFile(join(deps.home, '.config/agentos/secrets.env'), 'utf8'); } catch { /* none yet */ }
  const names = secretNames(text);
  return { values, secrets: Object.fromEntries(SECRET_KEYS.map((k) => [k, names.has(k)])) };
}

export async function saveSettings(deps: Deps, values: Record<string, unknown>, login: string): Promise<void> {
  const entries = Object.entries(values ?? {});
  if (entries.length === 0) throw new HttpError(400, 'nothing to save');
  for (const [key, value] of entries) {
    if (![...PLAIN_KEYS, ...WRITE_ONLY_KEYS].includes(key)) throw new HttpError(400, `unknown setting ${key}`, key);
    if (typeof value !== 'string' || /[\r\n]/.test(value)) throw new HttpError(400, 'value must be a single line', key);
  }
  for (const [key, value] of entries) {
    const r = await runAction(deps.run, { name: 'config-set', key }, { input: value as string });
    if (r.code !== 0) throw new HttpError(400, r.stderr.trim() || 'rejected', key);
    deps.audit(login, 'config-set', key);
  }
  const r = await runAction(deps.run, { name: 'config-apply' }, { timeoutMs: 300_000 });
  deps.audit(login, 'config-apply', '-');
  if (r.code !== 0) throw new HttpError(502, 'saved, but applying failed: see journalctl -u agentos-firstboot');
}

export interface SshKey { bits: string; fingerprint: string; comment: string; type: string }

export function parseFingerprints(out: string): SshKey[] {
  return out.split('\n').flatMap((line) => {
    const m = line.match(/^(\d+) (SHA256:[A-Za-z0-9+/]{43}) (.*) \(([A-Z0-9-]+)\)$/);
    return m ? [{ bits: m[1], fingerprint: m[2], comment: m[3], type: m[4] }] : [];
  });
}

export function settingsRoutes(app: FastifyInstance, deps: Deps): void {
  app.get('/api/settings', async () => getSettings(deps));
  app.put<{ Body: { values?: Record<string, unknown> } }>('/api/settings', async (req) => {
    await saveSettings(deps, req.body?.values ?? {}, req.login);
    return { ok: true };
  });
  app.get('/api/ssh-keys', async () => {
    const r = await deps.run(['ssh-keygen', '-l', '-f', join(deps.home, '.ssh/authorized_keys')]);
    return r.code === 0 ? parseFingerprints(r.stdout) : [];
  });
  app.post<{ Body: { key?: string } }>('/api/ssh-keys', async (req) => {
    const r = await runAction(deps.run, { name: 'add-ssh-key' }, { input: String(req.body?.key ?? '').trim() });
    if (r.code !== 0) throw new HttpError(400, r.stderr.trim());
    deps.audit(req.login, 'ssh-key-add', '-');
    return { ok: true };
  });
  app.post<{ Body: { user?: string } }>('/api/ssh-keys/github', async (req) => {
    const user = String(req.body?.user ?? '');
    const r = await runAction(deps.run, { name: 'github-keys', user });
    if (r.code !== 0) throw new HttpError(400, r.stderr.trim());
    deps.audit(req.login, 'ssh-key-github', user);
    return { ok: true };
  });
  app.post<{ Body: { fingerprint?: string } }>('/api/ssh-keys/remove', async (req) => {
    const fingerprint = String(req.body?.fingerprint ?? '');
    const r = await runAction(deps.run, { name: 'remove-ssh-key', fingerprint });
    if (r.code !== 0) throw new HttpError(400, r.stderr.trim());
    deps.audit(req.login, 'ssh-key-remove', fingerprint);
    return { ok: true };
  });
}
