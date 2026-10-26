// Running commands: argv only (execFile, no shell), with an optional stdin. Every exec in the
// server goes through a Runner so tests can substitute a fake one.
import { execFile } from 'node:child_process';

export class HttpError extends Error {
  constructor(public status: number, message: string, public field?: string) { super(message); }
}

export interface RunResult { code: number; stdout: string; stderr: string }
export interface RunOpts { input?: string; timeoutMs?: number; env?: NodeJS.ProcessEnv; cwd?: string }
export type Runner = (argv: readonly string[], opts?: RunOpts) => Promise<RunResult>;

export const execRunner: Runner = (args, opts = {}) =>
  new Promise((resolve) => {
    const child = execFile(args[0], args.slice(1), {
      timeout: opts.timeoutMs ?? 30_000, maxBuffer: 16 * 1024 * 1024,
      env: opts.env ?? process.env, cwd: opts.cwd, encoding: 'utf8',
    }, (err, stdout, stderr) => {
      const code = err ? (typeof err.code === 'number' ? err.code : 1) : 0;
      resolve({ code, stdout, stderr: err && !stderr ? err.message : stderr });
    });
    child.stdin?.on('error', () => {});   // EPIPE when the command exits without reading stdin
    child.stdin?.end(opts.input ?? '');
  });
