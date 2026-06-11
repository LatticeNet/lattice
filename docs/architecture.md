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

## Storage

The bootstrap build uses a JSON state file so the project builds without network
dependency downloads. The server `internal/store` package is intentionally isolated so a
SQLite WAL implementation can replace it without changing handlers or agents.
