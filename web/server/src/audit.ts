// Audit trail: one journal line per mutating action, at notice level. The "<5>" prefix is
// journald's syslog-priority marker for stdout; the unit's SyslogIdentifier=agentos-web supplies
// the tag, so the journal shows "agentos-web[pid]: <login> <action> <target>".
const field = (s: string) => s.replace(/[\s\x00-\x1f\x7f]+/g, '_') || '-';

export function auditLine(login: string, action: string, target: string): string {
  return `<5>${field(login)} ${field(action)} ${field(target)}`;
}

export type Audit = (login: string, action: string, target: string) => void;

export const journalAudit: Audit = (login, action, target) => {
  process.stdout.write(auditLine(login, action, target) + '\n');
};
