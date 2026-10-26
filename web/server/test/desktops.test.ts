import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { lowestFree, parseActive, parseDesktopConf } from '../src/desktops.js';
import { fakeDeps, HM } from './helpers.js';

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
