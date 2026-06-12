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

## Lifecycle

The server now keeps a metadata-only lifecycle record for each bundle that
passes manifest signature and artifact digest verification:

```txt
verified -> installed -> active -> disabled -> active
                      \-> disabled
```

The lifecycle API is deliberately conservative:

- `GET /api/plugins/lifecycle` requires `plugin:admin` and returns plugin
  identity, capabilities, artifact digest, availability, status, and timestamps.
- The response does not include the local `bundle_path`; filesystem layout stays
  server-private.
- `POST /api/plugins/lifecycle` requires `plugin:admin` and accepts
  `{ "id": "...", "status": "installed|active|disabled" }`.
- Installing or activating requires the bundle to be present in the current
  verified loader set (`available:true`); stale records can be disabled, not
  activated.
- Invalid transitions are rejected and status changes are audited as
  `plugin.status`.
- Activating a plugin arms the server runtime manager and exposes
  `runtime.state` (currently `armed`, `stopped`, or `failed`) and
  `runtime.runner` in the lifecycle response. Disabling stops that in-memory
  runtime handle.
- The current default runner is `noop`: it receives a capability-scoped broker
  and a deadline-bearing context, then reports health without executing artifact
  code.
- Lifecycle/runtime transitions do not execute plugin artifact code yet.
  Subprocess/wasm isolation, rate limits, and concrete runner implementations
  remain Phase B work.

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
