import { expect, it } from 'vitest';
import { execRunner } from '../src/run.js';

it('runs argv without a shell', async () => {
  const r = await execRunner(['/bin/echo', '$(id)', ';', '|'], {});
  expect(r).toEqual({ code: 0, stdout: '$(id) ; |\n', stderr: '' });
  const s = await execRunner(['/bin/cat'], { input: 'secret-on-stdin' });
  expect(s.stdout).toBe('secret-on-stdin');
  const f = await execRunner(['/bin/sh', '-c', 'echo bad >&2; exit 3']);
  expect(f).toEqual({ code: 3, stdout: '', stderr: 'bad\n' });
});

it('survives a command that exits without reading its stdin', async () => {
  expect(await execRunner(['true'], { input: 'x'.repeat(1 << 20) })).toEqual({ code: 0, stdout: '', stderr: '' });
});
