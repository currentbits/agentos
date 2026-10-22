# Tailscale ACL for AgentOS

Use a tagged, pre-approved auth key with `tag:agentos`. Add to your tailnet policy:

```json
{
  "tagOwners": { "tag:agentos": ["autogroup:admin"] },
  "acls": [
    { "action": "accept", "src": ["autogroup:admin"], "dst": ["tag:agentos:22,6080,8765"] }
  ],
  "ssh": [
    { "action": "accept", "src": ["autogroup:admin"], "dst": ["tag:agentos"], "users": ["agent"] }
  ]
}
```

No rule lets `tag:agentos` initiate connections to other tailnet devices, so a hijacked agent can't reach them. Internet egress is unaffected.
