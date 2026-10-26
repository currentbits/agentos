import { describe, expect, it } from 'vitest';
import { argv } from '../src/actions.js';

const C = '/usr/local/bin/agentos-config';
const FP = 'SHA256:' + 'A'.repeat(43);

describe('actions table', () => {
  it('builds the exact argv for every action', () => {
    expect(argv({ name: 'config-set', key: 'AGENTOS_LAN_SSH' })).toEqual(['sudo', '-n', C, 'set', 'AGENTOS_LAN_SSH', '-']);
    expect(argv({ name: 'config-get', key: 'AGENTOS_WEB' })).toEqual(['sudo', '-n', C, 'get', 'AGENTOS_WEB']);
    expect(argv({ name: 'config-apply' })).toEqual(['sudo', '-n', C, 'apply']);
    expect(argv({ name: 'add-ssh-key' })).toEqual(['sudo', '-n', C, 'add-ssh-key', '-']);
    expect(argv({ name: 'remove-ssh-key', fingerprint: FP })).toEqual(['sudo', '-n', C, 'remove-ssh-key', FP]);
    expect(argv({ name: 'github-keys', user: 'octo-cat' })).toEqual(['sudo', '-n', C, 'github-keys', 'octo-cat']);
    expect(argv({ name: 'restart', unit: 'agentos-novnc.service' })).toEqual(['sudo', '-n', 'systemctl', 'restart', 'agentos-novnc.service']);
    expect(argv({ name: 'journal', unit: 'docker.service' })).toEqual(['sudo', '-n', 'journalctl', '-u', 'docker.service', '-f', '-n', '200', '-o', 'short-iso']);
    expect(argv({ name: 'update' })).toEqual(['/usr/local/bin/agentos-update']);
    expect(argv({ name: 'reboot' })).toEqual(['sudo', '-n', 'systemctl', 'reboot']);
    expect(argv({ name: 'poweroff' })).toEqual(['sudo', '-n', 'systemctl', 'poweroff']);
    expect(argv({ name: 'desktop-start', n: 3 })).toEqual(['systemctl', '--no-ask-password', 'start', 'agentos-desktop@3.service']);
    expect(argv({ name: 'desktop-stop', n: 16 })).toEqual(['systemctl', '--no-ask-password', 'stop', 'agentos-desktop@16.service']);
  });

  it('restricts units to agentos-*, docker and tailscaled', () => {
    for (const unit of ['agentos-web.service', 'agentos-desktop@2.service', 'docker.service', 'tailscaled.service']) {
      expect(() => argv({ name: 'restart', unit })).not.toThrow();
    }
    for (const unit of ['ssh.service', 'docker', 'agentos-x.timer', '-H.service', 'agentos-a;b.service', '../docker.service', 'Docker.service']) {
      expect(() => argv({ name: 'restart', unit })).toThrow(/invalid unit/);
      expect(() => argv({ name: 'journal', unit })).toThrow(/invalid unit/);
    }
  });

  it('rejects bad keys, fingerprints, users and desktop numbers', () => {
    expect(() => argv({ name: 'config-set', key: 'lower' })).toThrow();
    expect(() => argv({ name: 'config-set', key: '-x' })).toThrow();
    expect(() => argv({ name: 'remove-ssh-key', fingerprint: 'MD5:aa' })).toThrow();
    expect(() => argv({ name: 'github-keys', user: '--help' + 'x'.repeat(40) })).toThrow();
    expect(() => argv({ name: 'github-keys', user: 'a b' })).toThrow();
    expect(() => argv({ name: 'desktop-start', n: 0 })).toThrow();
    expect(() => argv({ name: 'desktop-start', n: 17 })).toThrow();
  });

  it('never puts a value in argv: config-set takes it on stdin', () => {
    expect(argv({ name: 'config-set', key: 'ANTHROPIC_API_KEY' }).join(' ')).not.toMatch(/sk-/);
  });
});
