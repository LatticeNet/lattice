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
