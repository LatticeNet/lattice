# Plugins

Plugins declare type and capabilities. Unknown capabilities are rejected.

Current capability names:

- `kv:read`
- `kv:write`
- `static:read`
- `static:write`
- `worker:route`
- `network:plan`
- `network:apply`
- `task:run`
- `notify:send`

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

