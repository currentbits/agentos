// In-VM WebSocket probe for the web UI, using the ws package shipped with the server.
//   node web_ws.mjs term <session-id> <text-to-type> <expected-output>
//   node web_ws.mjs vnc <desktop-number>        (expects the VNC server's "RFB 003.008" banner)
// Prints "WS OK" and exits 0 once the expected text arrives; exits 1 on close, HTTP error or timeout.
import { createRequire } from 'node:module';
const require = createRequire('/usr/local/lib/agentos/web/server/');
const WebSocket = require('ws');
const [mode, target, typed, expected] = process.argv.slice(2);
const path = mode === 'term' ? `/api/sessions/${target}/terminal?cols=80&rows=24` : `/api/desktops/${target}/vnc`;
const want = mode === 'term' ? expected : 'RFB 003.008';
const ws = new WebSocket(`ws://127.0.0.1:7070${path}`, {
  headers: { 'Tailscale-User-Login': process.env.LOGIN ?? 'smoke@example.com', Origin: 'http://127.0.0.1:7070' },
});
let got = '';
const bail = (why) => { console.error(`WS FAIL: ${why}; got ${JSON.stringify(got.slice(-300))}`); process.exit(1); };
setTimeout(() => bail('timeout'), 20000);
ws.on('unexpected-response', (_req, res) => bail(`HTTP ${res.statusCode}`));
ws.on('close', (code, reason) => bail(`closed ${code} ${reason}`));
ws.on('open', () => { if (mode === 'term') setTimeout(() => ws.send(JSON.stringify({ t: 'i', d: `${typed}\r` })), 1000); });
ws.on('message', (d) => {
  got += d.toString('latin1');
  if (got.includes(want)) { console.log('WS OK'); process.exit(0); }
});
