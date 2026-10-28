# Tailscale ACL for AgentOS

Generate the auth key (`TS_AUTHKEY`) as **single-use**, **pre-approved**, and **tagged** `tag:agentos`:

- **Single-use:** the key outlives its use. Cloud user-data (where `agentos.env` usually comes from) stays readable on the machine (for example `/var/lib/cloud/instance/user-data.txt` and the provider's metadata service), and providers keep it too. AgentOS deletes `TS_AUTHKEY` from `agentos.env` after `tailscale up`, but it cannot scrub those copies. A single-use key is worthless once used. A reusable key would let anyone who reads it join more devices to your tailnet.
- **Pre-approved:** the machine joins without manual device approval.
- **Tagged:** the node is owned by `tag:agentos`, not by you, so the ACL below applies and it gets none of your user's access.

Add to your tailnet policy:

```json
{
  "tagOwners": { "tag:agentos": ["autogroup:admin"] },
  "acls": [
    { "action": "accept", "src": ["autogroup:admin"], "dst": ["tag:agentos:22,443,6080,8765"] }
  ],
  "ssh": [
    { "action": "accept", "src": ["autogroup:admin"], "dst": ["tag:agentos"], "users": ["agent"] }
  ]
}
```

No rule lets `tag:agentos` initiate connections to other tailnet devices, so a hijacked agent can't reach them. Internet egress is unaffected.

Mode B's Mac-side bridge (`ssh -R`) over Tailscale SSH also needs your tailnet's SSH policy to grant `SSHAction.AllowRemotePortForwarding`; without it, the remote forward is refused, and the bridge needs the LAN or OpenSSH instead (see `docs/solenta-and-ci.md`).

Port 443 is the web UI (`tailscale serve`, see below). It needs HTTPS certificates enabled for the tailnet (admin console → DNS → HTTPS Certificates). If they're off, `agentos-firstboot` logs a warning, `/etc/agentos/web.conf` says `SERVE=failed: …`, and the login banner shows the reason. Allow users into the web UI with `sudo agentos-config set AGENTOS_WEB_USERS you@example.com && sudo agentos-config apply`. Requests from tagged devices carry no identity, so they are always refused.
