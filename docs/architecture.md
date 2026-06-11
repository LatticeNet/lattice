# Lattice Architecture

Lattice is split into separately deployable projects:

- `lattice-server` - control plane.
- `lattice-node-agent` - node-side daemon.
- `lattice-dashboard` - static frontend.
- `lattice-sdk` - shared protocol/domain model package.
- `lattice-plugin-template` - starter extension templates.

## Control Plane

`lattice-server` owns identity, node enrollment, task scheduling, KV/static data,
Worker registration, network approvals, and audit events.

The server exposes JSON HTTP APIs in this bootstrap build. The API boundary is
kept narrow so it can move to protobuf/ConnectRPC later without changing domain
packages. The dashboard lives in `lattice-dashboard` and can be served by
`lattice-server -web ../lattice-dashboard` or by an independent static host.

## Node Agent

`lattice-agent` only dials out. It never requires inbound ports on leaf nodes.

Agent responsibilities:

- Authenticate with a per-node enrollment token.
- Send heartbeat and host metrics.
- Poll for bounded tasks.
- Execute tasks only when started with `-allow-exec=true`.
- Return stdout/stderr/exit code with output caps.

## Safety Model

Dangerous operations use this flow:

1. Server creates a plan.
2. Operator reviews the diff/plan.
3. Operator approves.
4. Server queues a bounded validation/apply task.
5. Agent returns result.
6. Audit log records each step.

The current nft flow queues `nft -c` validation after approval. A future apply
mode should require a separate explicit `apply=true` request and a rollback note.

## Plugin Types

- `system`: trusted built-ins for nft, WireGuard, nginx, cloudflared, sing-box,
  xray, Sub-Store supervision, SSH login alerts, and notifications.
- `wasm`: future wazero sandboxed plugins. Host APIs must be explicit capabilities.
- `worker`: lightweight route handlers. The bootstrap runtime supports safe
  template rendering and KV interpolation, not arbitrary JavaScript execution.

## Notifications and Alerts

Notification channels are persisted (`NotifyChannel`: kind + config + enabled)
and reused by every alert. Supported kinds are telegram, bark, discord, and a
generic webhook, all delivered by the dependency-free `internal/notify` package.
The list API returns only the configured key names, never the secret values.

Two event sources currently drive alerts, fanned out to every enabled channel:

- **Monitor state changes** — when a monitor's success flips (or on the first
  observed failure) the server emits a down/recovery alert, so a flapping target
  does not spam every probe result.
- **SSH logins** — agents started with `-ssh-alerts` stream sshd accepted-login
  lines from journald (or `auth.log`) and report them to `/api/agent/event`; the
  server records an `ssh.login` audit event and notifies.

Channel management (`/api/notify/channels`, `/api/notify/test`) requires the
`notify:send` scope.

## Service Monitoring

`lattice-server` distributes periodic reachability/latency monitors to agents,
mirroring the continuous ping/tcping pattern of NodeGet/nezha.

- A `Monitor` has a type (`tcp` or `http`; `icmp` is pending because it needs
  elevated privileges), a target (`host:port` or URL), an interval, a timeout,
  and an assignment (every node via `assign_all`, or an explicit `node_ids`
  list). Assigning members a monitor that targets their group leader is how the
  group's intra-region latency matrix is collected.
- Agents poll `/api/agent/monitors` for their assignment and run each monitor on
  its own schedule in a dedicated goroutine (started/stopped/restarted as the
  assignment changes), reporting `MonitorResult`s to
  `/api/agent/monitor-result`.
- The server keeps a capped history (most recent 500 per monitor) for trend
  display. Operator endpoints (`/api/monitors` CRUD, `/api/monitors/results`)
  require `monitor:read` / `monitor:admin`.

## DDNS

`lattice-server` can publish a node's public IP to DNS when it changes. A
`DDNSProfile` is bound to a node and a provider:

- **cloudflare** — Cloudflare API v4 with a scoped API token (Zone:Read +
  DNS:Edit). Zero external dependency (no libdns); the longest matching zone is
  resolved from the token's zone list, then A/AAAA records are created/updated
  (never proxied).
- **webhook** — a templated request (`#ip#`, `#domain#`, `#type#`) to an
  operator URL. Because the URL is operator-supplied it is screened by an SSRF
  guard that rejects loopback/private/link-local/metadata destinations.

IP source: the agent may report `public_ip`/`public_ipv6`, but when it does not,
the server uses the agent's observed source address (it dials out, so its source
IP is its public IP) — giving zero-config DDNS. When a bound node's public IP
changes, the server applies every bound profile asynchronously with retries;
`POST /api/ddns/run` triggers a profile synchronously. Credentials are stored in
the state file and never returned by the list API. All DDNS endpoints require the
`ddns:admin` scope.

## Storage

The bootstrap build uses a JSON state file so the project builds without network
dependency downloads. The server `internal/store` package is intentionally isolated so a
SQLite WAL implementation can replace it without changing handlers or agents.
