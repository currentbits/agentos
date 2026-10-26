export interface Me { login: string; hostname: string; tailnetIp: string | null; tailnetName: string | null }
export interface Session { id: string; name: string; cli: string | null; dir: string | null; created: string | null; attached: number; state: 'running' | 'ended'; external: boolean }
export interface Desktop { id: number; idleSeconds: number | null; idleLimitMinutes: number; viewers: number }
export interface Health { cpuPercent: number; load: number[]; memory: { totalBytes: number; usedBytes: number }; disk: { totalBytes: number; usedBytes: number } }
export interface Tailscale { state: string; dnsName: string | null; ip: string | null; serve: string }
export interface Settings { values: Record<string, string>; secrets: Record<string, boolean> }
export interface SshKey { bits: string; fingerprint: string; comment: string; type: string }
export interface Unit { unit: string; load: string; active: string; sub: string; description: string }
