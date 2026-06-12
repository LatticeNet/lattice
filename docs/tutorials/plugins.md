# Plugins

Plugins declare type and capabilities. Unknown capabilities are rejected.

Current capability names:

- `audit:read`
- `http:egress`
- `kv:read`
- `kv:write`
- `log:write`
- `monitor:read`
- `monitor:admin`
- `node:read`
- `node:admin`
- `notify:send`
- `static:read`
- `static:write`
- `task:read`
- `task:run`
- `tunnel:admin`
- `worker:route`
- `network:plan`
- `network:apply`
- `ddns:admin`

Host API calls are not direct server handles. They go through the core broker,
which checks the verified manifest's capability list on every call and records
allow/deny host-call events. `http:egress` is only a permission to ask the
server-owned HTTP host to dial; that host must still apply the outbound SSRF and
egress guard.

## System Plugins

System plugins are trusted built-ins. Planned system plugins:

- nft guard
- WireGuard config renderer
- nginx virtual host renderer
- cloudflared tunnel supervisor
- sing-box/xray config renderer
- Sub-Store process supervisor and reverse proxy
- SSH login alert collector
- notification fanout

## Worker Plugins

The bootstrap Worker runtime is intentionally conservative. It supports template
rendering and KV interpolation:

```txt
hello {{path}} {{kv:default/message}}
```

Blocked source primitives include `fetch(`, `require(`, `process.env`, `exec(`,
and `os.`. A future JS runtime should remain capability-based and should not gain
filesystem, process, or arbitrary network access by default.
