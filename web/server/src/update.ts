// AgentOS updates: the state the daily check wrote (update.json), "Check now", and the last run's
// log. Installing stays the existing WebSocket action (/api/system/update) with its lock.
import { open } from 'node:fs/promises';
import type { FastifyInstance } from 'fastify';
import { runAction } from './actions.js';
import type { Deps } from './app.js';
import { HttpError } from './run.js';

export interface UpdateState {
  installed: string | null; available: string | null; notes_url: string | null; notes: string;
  checked_at: string | null; error: string | null; running: boolean; ciActive: string[];
}

const VERSION_RE = /^[0-9][A-Za-z0-9.+~]*$/;   // agentos-update's own check, again
const str = (v: unknown, max: number): string | null => (typeof v === 'string' && v !== '' ? v.slice(0, max) : null);

// The tail of a file (at most max bytes), or '' when it doesn't exist.
async function tail(path: string, max: number): Promise<string> {
  try {
    const f = await open(path, 'r');
    try {
      const { size } = await f.stat();
      const buf = Buffer.alloc(Math.min(size, max));
      await f.read(buf, 0, buf.length, size - buf.length);
      return buf.toString('utf8');
    } finally { await f.close(); }
  } catch { return ''; }
}

async function running(deps: Deps): Promise<boolean> {
  return (await runAction(deps.run, { name: 'update-running' })).code !== 0;
}

// update.json is untrusted text (the notes come from the repo): only known fields, typed and capped.
// The UI renders the notes as plain text.
export async function updateState(deps: Deps): Promise<UpdateState> {
  let j: Record<string, unknown> = {};
  try { j = JSON.parse(await tail(deps.updateState, 64 * 1024)) ?? {}; } catch { /* not checked yet */ }
  const [ver, isRunning, ci] = await Promise.all([
    runAction(deps.run, { name: 'update-version' }),
    running(deps),
    runAction(deps.run, { name: 'ci-list', limit: 200 }, { timeoutMs: 60_000 }),
  ]);
  let ciActive: string[] = [];
  try {
    ciActive = (JSON.parse(ci.stdout) as { id: string; status: string }[])
      .filter((r) => r.status === 'running' || r.status === 'queued').map((r) => String(r.id));
  } catch { /* agentos-ci unavailable: no warning */ }
  const available = str(j.available, 64);
  return {
    installed: ver.code === 0 ? ver.stdout.trim() || null : null,
    available: available && VERSION_RE.test(available) ? available : null,
    notes_url: str(j.notes_url, 512),
    notes: str(j.notes, 4096) ?? '',
    checked_at: str(j.checked_at, 64),
    error: j.checked_at ? str(j.error, 512) : 'not checked yet',
    running: isRunning,
    ciActive,
  };
}

export function updateRoutes(app: FastifyInstance, deps: Deps): void {
  app.get('/api/update', async () => updateState(deps));
  app.post('/api/update/check', async (req) => {
    deps.audit(req.login, 'update-check', '-');
    const r = await runAction(deps.run, { name: 'update-check' }, { timeoutMs: 120_000 });
    if (r.code !== 0) throw new HttpError(500, r.stderr.trim() || 'agentos-update --check failed');
    return updateState(deps);
  });
  // After agentos-web restarted mid-update, the page reconnects here: the run keeps writing this log.
  app.get('/api/update/log', async () => ({ running: await running(deps), text: await tail(deps.updateLog, 64 * 1024) }));
}
