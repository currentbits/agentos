// In-VM WebSocket probe for the web UI, using the ws package shipped with the server.
//   node web_ws.mjs term <session-id> <text-to-type> <expected-output>
//   node web_ws.mjs vnc <desktop-number>        (expects the VNC server's "RFB 003.008" banner)
//   node web_ws.mjs cilog <run-id> <step> <expected-output>
//   node web_ws.mjs update                      (starts agentos-update and prints the stream; exits 0
//                                               when it ends: the run finished, or agentos-web restarted)
// Prints "WS OK" and exits 0 once the expected text arrives; exits 1 on close, HTTP error or timeout.
import { createRequire } from 'node:module';
const require = createRequire('/usr/local/lib/agentos/web/server/');
const WebSocket = require('ws');
const [mode, target, typed, expected] = process.argv.slice(2);
const path = mode === 'term' ? `/api/sessions/${target}/terminal?cols=80&rows=24`
  : mode === 'cilog' ? `/api/ci/runs/${target}/log?step=${encodeURIComponent(typed)}`
    : mode === 'update' ? '/api/system/update' : `/api/desktops/${target}/vnc`;
const want = mode === 'vnc' ? 'RFB 003.008' : expected;
const ws = new WebSocket(`ws://127.0.0.1:7070${path}`, {
  headers: { 'Tailscale-User-Login': process.env.LOGIN ?? 'smoke@example.com', Origin: 'http://127.0.0.1:7070' },
});
let got = '';
const bail = (why) => { console.error(`WS FAIL: ${why}; got ${JSON.stringify(got.slice(-300))}`); process.exit(1); };
setTimeout(() => bail('timeout'), mode === 'update' ? 30 * 60_000 : 20000);
ws.on('unexpected-response', (_req, res) => bail(`HTTP ${res.statusCode}`));
ws.on('close', (code, reason) => {
  if (mode === 'update') { console.log(got); process.exit(0); }
  bail(`closed ${code} ${reason}`);
});
ws.on('open', () => { if (mode === 'term') setTimeout(() => ws.send(JSON.stringify({ t: 'i', d: `${typed}\r` })), 1000); });
ws.on('message', (d) => {
  got += d.toString('latin1');
  if (mode !== 'update' && got.includes(want)) { console.log('WS OK'); process.exit(0); }
});
