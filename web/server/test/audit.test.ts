import { expect, it } from 'vitest';
import { auditLine } from '../src/audit.js';

it('formats one notice-level line, with fields that cannot break the line', () => {
  expect(auditLine('alice@example.com', 'config-set', 'AGENTOS_LAN_SSH')).toBe('<5>alice@example.com config-set AGENTOS_LAN_SSH');
  expect(auditLine('a@b', 'session-create', 'x\ny z')).toBe('<5>a@b session-create x_y_z');
  expect(auditLine('a@b', 'reboot', '')).toBe('<5>a@b reboot -');
});
