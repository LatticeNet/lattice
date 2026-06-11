# Lattice

Lattice is the umbrella repository for the LatticeNet ecosystem: a
security-first server probe, automation, and cluster network control plane.

The code is intentionally split into independent repositories so server,
node-agent, dashboard, SDK, and plugins can be released and maintained
separately.

## Ecosystem Repositories

- [`lattice-sdk`](https://github.com/LatticeNet/lattice-sdk) - shared Go protocol/domain models.
- [`lattice-server`](https://github.com/LatticeNet/lattice-server) - deployable control plane.
- [`lattice-node-agent`](https://github.com/LatticeNet/lattice-node-agent) - deployable outbound node agent.
- [`lattice-dashboard`](https://github.com/LatticeNet/lattice-dashboard) - static dashboard.
- [`lattice-plugin-template`](https://github.com/LatticeNet/lattice-plugin-template) - starter templates for system, Worker, and future Wasm plugins.
- [`.github`](https://github.com/LatticeNet/.github) - organization profile.

## Current MVP

- Go server and Go node-agent.
- Outbound agent enrollment, heartbeat, metric reporting, task polling, and task result upload.
- Session login, CSRF checks, PBKDF2 password/token hashing, PAT-like scopes, server allowlists, and audit logging.
- Node dashboard, task runner, KV, static bucket, Worker registry, network guard, approvals, and audit views.
- nftables plan generation with explicit approval before apply.
- Static TypeScript source and dependency-free browser assets.
- Local JSON storage to keep this bootstrap build dependency-free; the storage interface is isolated so SQLite/Postgres can replace it later.

## Quick Start

```sh
cd Lattice/lattice
make test
make build
LATTICE_ADMIN_PASSWORD='change-this-passphrase' make run-server
```

Open <http://127.0.0.1:8088>. The default username is `admin`. If
`LATTICE_ADMIN_PASSWORD` is not set on the first run, the server prints a random
bootstrap password to stdout.

Enroll a node from the dashboard, then run:

```sh
cd Lattice/lattice-node-agent
go run ./cmd/lattice-agent \
  -server http://127.0.0.1:8088 \
  -node-id demo-node \
  -token '<enrollment-token>' \
  -allow-exec=false
```

Task execution is disabled by default on the agent. Start with
`-allow-exec=true` only on machines where you accept the risk.

## Design Defaults

- Agents dial out; inbound node ports are not required.
- Dangerous operations follow `plan -> diff -> approve -> apply`.
- Plugins cannot bypass core scopes and audit.
- Management APIs should live on WireGuard/private addresses or behind a hardened reverse proxy.

## Repository Creation Order

Publish `lattice-sdk` first, then `lattice-server` and `lattice-node-agent`,
then `lattice-dashboard`, `lattice-plugin-template`, `lattice`, and `.github`.
Tag `lattice-sdk` as `v0.1.0` before building server/agent without the local
workspace.
