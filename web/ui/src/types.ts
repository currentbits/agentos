export interface Me { login: string; hostname: string; tailnetIp: string | null; tailnetName: string | null }
export interface Session { id: string; name: string; cli: string | null; dir: string | null; created: string | null; attached: number; state: 'running' | 'ended'; external: boolean }
export interface Desktop { id: number; idleSeconds: number | null; idleLimitMinutes: number; viewers: number }
export interface Health { cpuPercent: number; load: number[]; memory: { totalBytes: number; usedBytes: number }; disk: { totalBytes: number; usedBytes: number } }
export interface Tailscale { state: string; dnsName: string | null; ip: string | null; serve: string }
export interface Settings { values: Record<string, string>; secrets: Record<string, boolean> }
export interface SshKey { bits: string; fingerprint: string; comment: string; type: string }
export interface Unit { unit: string; load: string; active: string; sub: string; description: string }
export type CiStatus = 'queued' | 'running' | 'passed' | 'failed' | 'cancelled' | 'error';
export interface CiStep { name: string; status: string; exit_code: number | null; started: string | null; finished: string | null }
export interface CiRun {
  id: string; repo: string; ref: string; commit: string; source: string; status: CiStatus;
  created: string; started: string | null; finished: string | null; pipeline: string | null; image: string | null;
  secrets: string[]; missing_secrets: string[]; steps: CiStep[]; error: string | null;
}
export interface CiRemote { name: string; path: string; remote_add: string }
export interface PreflightItem { item: string; ok: boolean; detail: string }
export interface SolentaStatus {
  host: string; remoteHost: string; remotePath: string | null; tailscaleSsh: boolean;
  hostKeys: { type: string; fingerprint: string }[]; keyscan: string;
  modeA: { enabled: boolean; service: string; version: string | null; webToken: boolean };
  preflight: PreflightItem[];
}
