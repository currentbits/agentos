import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { createDesktop, listDesktops, lowestFree, parseActive, parseDesktopConf, thumbnail } from '../src/desktops.js';
import { fakeDeps, HM, LOGIN } from './helpers.js';

describe('desktop helpers', () => {
  it('parses desktop.conf with defaults and clamps', () => {
    expect(parseDesktopConf('MAX_DESKTOPS=4\nSCREENSHOT_WIDTH=1366\nIDLE_MINUTES=30\n')).toEqual({ max: 4, idleMinutes: 30 });
    expect(parseDesktopConf('MAX_DESKTOPS=99\n')).toEqual({ max: 8, idleMinutes: 120 });
  });
  it('parses active units and picks the lowest free number', () => {
    expect(parseActive('agentos-desktop@3.service loaded active running x\nagentos-desktop@1.service loaded active running x\n')).toEqual([1, 3]);
    expect(lowestFree([1, 3], 8)).toBe(2);
    expect(lowestFree([1, 2], 2)).toBeNull();
  });
  it('validates desktop numbers in routes', async () => {
    const { deps, calls } = fakeDeps();
    const app = await buildApp(deps);
    expect((await app.inject({ method: 'DELETE', url: '/api/desktops/0', headers: HM })).statusCode).toBe(400);
    expect((await app.inject({ method: 'DELETE', url: '/api/desktops/1;reboot', headers: HM })).statusCode).toBe(400);
    expect((await app.inject({ method: 'DELETE', url: '/api/desktops/2', headers: HM })).statusCode).toBe(404);
    expect(calls.every((c) => c.argv[1] === 'list-units')).toBe(true);
  });
});

describe('createDesktop', () => {
  it('starts the lowest free number, waits for it to come up, and audits it without a token', async () => {
    const { deps, calls, audits } = fakeDeps((argv) => {
      if (argv[1] === 'list-units') return { stdout: 'agentos-desktop@1.service loaded active running x\n' };
      if (argv[0] === 'xdotool') return { code: 0 };
      return {};
    });
    const r = await createDesktop(deps, LOGIN);
    expect(r).toEqual({ id: 2 });
    expect(audits).toEqual([`${LOGIN} desktop-create 2`]);
    expect(calls.some((c) => c.argv.includes('start') && c.argv.includes('agentos-desktop@2.service'))).toBe(true);
  });

  it('409s when every desktop is already in use', async () => {
    const active = Array.from({ length: 8 }, (_, i) => `agentos-desktop@${i + 1}.service loaded active running x\n`).join('');
    const { deps } = fakeDeps((argv) => (argv[1] === 'list-units' ? { stdout: active } : {}));
    await expect(createDesktop(deps, LOGIN)).rejects.toMatchObject({ status: 409 });
  });
});

describe('listDesktops', () => {
  it('reports viewer counts from ss, and null idle time with no .last file', async () => {
    const { deps } = fakeDeps((argv) => {
      if (argv[1] === 'list-units') return { stdout: 'agentos-desktop@1.service loaded active running x\n' };
      if (argv[0] === 'ss') return { stdout: 'line-one\nline-two\n' };
      return {};
    });
    expect(await listDesktops(deps)).toEqual([{ id: 1, idleSeconds: null, idleLimitMinutes: 120, viewers: 2 }]);
  });
});

describe('thumbnail', () => {
  it('shares one scrot call across concurrent requests for the same desktop', async () => {
    let scrotCalls = 0;
    const { deps } = fakeDeps((argv) => {
      if (argv[1] === 'list-units') return { stdout: 'agentos-desktop@1.service loaded active running x\n' };
      if (argv[0] === 'scrot') {
        scrotCalls++;
        const target = argv[argv.length - 1];
        writeFileSync(target.replace(/\.png$/, '-thumb.png'), 'fake-png');
        return { code: 0 };
      }
      return {};
    });
    const [a, b, c] = await Promise.all([thumbnail(deps, 1), thumbnail(deps, 1), thumbnail(deps, 1)]);
    expect(scrotCalls).toBe(1);
    expect(a.toString()).toBe('fake-png');
    expect(b).toBe(a);
    expect(c).toBe(a);
  });

  it('runs a fresh scrot for a later, non-concurrent request', async () => {
    let scrotCalls = 0;
    const { deps } = fakeDeps((argv) => {
      if (argv[1] === 'list-units') return { stdout: 'agentos-desktop@1.service loaded active running x\n' };
      if (argv[0] === 'scrot') {
        scrotCalls++;
        const target = argv[argv.length - 1];
        writeFileSync(target.replace(/\.png$/, '-thumb.png'), 'fake-png');
        return { code: 0 };
      }
      return {};
    });
    await thumbnail(deps, 1);
    await thumbnail(deps, 1);
    expect(scrotCalls).toBe(2);
  });

  it('clears the in-flight entry after a failed scrot, so the next call retries instead of reusing the rejection', async () => {
    let scrotCalls = 0;
    const { deps } = fakeDeps((argv) => {
      if (argv[1] === 'list-units') return { stdout: 'agentos-desktop@1.service loaded active running x\n' };
      if (argv[0] === 'scrot') { scrotCalls++; return { code: 1, stderr: 'boom' }; }
      return {};
    });
    await expect(thumbnail(deps, 1)).rejects.toMatchObject({ status: 500 });
    await expect(thumbnail(deps, 1)).rejects.toMatchObject({ status: 500 });
    expect(scrotCalls).toBe(2);   // a stuck in-flight entry would have reused the first rejection without re-running scrot
  });
});

describe('desktop routes never expose the VNC token', () => {
  it('puts the token in no response body or header, across GET/POST/DELETE/thumbnail', async () => {
    const token = 'de'.repeat(16);
    const { deps } = fakeDeps((argv) => {
      if (argv[1] === 'list-units') return { stdout: 'agentos-desktop@1.service loaded active running x\n' };
      if (argv[0] === 'ss') return { stdout: '' };
      if (argv[0] === 'scrot') {
        const target = argv[argv.length - 1];
        writeFileSync(target.replace(/\.png$/, '-thumb.png'), 'fake-png-bytes');
        return { code: 0 };
      }
      return {};
    });
    // A real token file, wired through Deps exactly as the running service would see it; none of
    // the desktop routes below ever read it, but this guards against that ever changing silently.
    writeFileSync(join(deps.vncTokenDir, '1'), `${token}: localhost:5901\n`);
    const app = await buildApp(deps);

    const list = await app.inject({ url: '/api/desktops', headers: HM });
    const created = await app.inject({ method: 'POST', url: '/api/desktops', headers: HM });
    const destroyed = await app.inject({ method: 'DELETE', url: '/api/desktops/1', headers: HM });
    const thumb = await app.inject({ url: '/api/desktops/1/thumbnail', headers: HM });

    for (const r of [list, created, destroyed, thumb]) {
      expect(r.body).not.toContain(token);
      expect(JSON.stringify(r.headers)).not.toContain(token);
    }
  });
});
