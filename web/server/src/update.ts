// AgentOS updates: the state the daily check wrote (update.json), "Check now", and the last run's
// log. Installing stays the existing WebSocket action (/api/system/update) with its lock.
import { open } from 'node:fs/promises';
import type { FastifyInstance } from 'fastify';
import { runAction } from './actions.js';
import type { Deps } from './app.js';
import { HttpError } from './run.js';

export interface UpdateState {
  installed: string | null; available: string | null; notes_url: string | null; notes: string;
  checked_at: string | null; error: string | null; running: boolean; ciActive: string[] | null;
}

const VERSION_RE = /^[0-9][A-Za-z0-9.+~]*$/;   // agentos-update's own check, again
const str = (v: unknown, max: number): string | null => (typeof v === 'string' && v !== '' ? v.slice(0, max) : null);

// The tail of a file (at most max bytes), or '' when it doesn't exist.
async function tail(path: string, max: number): Promise<string> {
  try {
    const f = await open(path, 'r');
    try {
      const { size } = await f.stat();
      const len = Math.min(size, max);
      const offset = size - len;
      const buf = Buffer.alloc(len);
      await f.read(buf, 0, len, offset);
      // A tail cut at this byte boundary can start mid-character: a UTF-8 continuation byte
      // (10xxxxxx) never starts a character, so drop any at the front instead of letting
      // Buffer#toString silently turn the broken lead byte into a stray U+FFFD.
      let start = 0;
      if (offset > 0) while (start < buf.length && (buf[start] & 0xc0) === 0x80) start++;
      return buf.toString('utf8', start);
    } finally { await f.close(); }
  } catch { return ''; }
}

// flock -n exits 1 only when it couldn't get the lock (it's held); any other exit (a bad flock
// invocation, the binary missing) is not "running", just a broken probe.
async function running(deps: Deps): Promise<boolean> {
  return (await runAction(deps.run, { name: 'update-running' })).code === 1;
}

// update.json is untrusted text (the notes come from the repo): only known fields, typed and capped.
// The UI renders the notes as plain text. A corrupt file (wrong types, non-JSON, a mangled
// `available`) must never read as "up to date": `error` is keyed off the validated `checked_at`,
// and a present-but-invalid `available` reports its own error instead of silently becoming null.
export async function updateState(deps: Deps): Promise<UpdateState> {
  let j: Record<string, unknown> = {};
  try { j = JSON.parse(await tail(deps.updateState, 64 * 1024)) ?? {}; } catch { /* not checked yet */ }
  const rawAvailable = j.available;
  const availableStr = str(rawAvailable, 64);
  const available = availableStr && VERSION_RE.test(availableStr) ? availableStr : null;
  // Only poll agentos-ci (a 60 s action) when there's actually an update to warn about restarting
  // for: on an up-to-date box this just adds load and an "agentos-web restarts" warning that never
  // applies.
  const [ver, isRunning, ci] = await Promise.all([
    runAction(deps.run, { name: 'update-version' }),
    running(deps),
    available ? runAction(deps.run, { name: 'ci-list', limit: 200 }, { timeoutMs: 60_000 }) : Promise.resolve(null),
  ]);
  let ciActive: string[] | null = null;
  if (ci) {
    try {
      ciActive = (JSON.parse(ci.stdout) as { id: string; status: string }[])
        .filter((r) => r.status === 'running' || r.status === 'queued').map((r) => String(r.id));
    } catch { ciActive = []; /* agentos-ci unavailable: no warning */ }
  }
  const checkedAt = str(j.checked_at, 64);
  const availablePresent = rawAvailable !== undefined && rawAvailable !== null;
  const errFromFile = str(j.error, 512);
  return {
    installed: ver.code === 0 ? ver.stdout.trim() || null : null,
    available,
    notes_url: str(j.notes_url, 512),
    notes: str(j.notes, 4096) ?? '',
    checked_at: checkedAt,
    error: !checkedAt ? 'not checked yet'
      : errFromFile !== null ? errFromFile
        : availablePresent && !available ? 'invalid version in update.json'
          : null,
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
