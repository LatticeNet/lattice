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
- Outbound agent enrollment, heartbeat, metric/HostFacts reporting, task polling, and task result upload.
- Machine inventory profiles for vendor/region/cost/renewal tracking, encrypted
  console/detail links, and renewal reminders.
- Session login, CSRF checks, TOTP 2FA, OIDC/SSO, PBKDF2 password/token hashing, PAT scopes, server allowlists, and tamper-evident audit WAL.
- Node dashboard, task runner, KV, static bucket, Worker registry, SSO provider admin, plugin lifecycle/runtime health, network guard, saved network policy intent/SVG graph, egress-only NetPolicy apply planning, Fleet Map, approvals, and audit views.
- nftables plan generation with explicit approval before apply, including an
  applied `lattice_guard` Network Guard path and an egress-only NetPolicy path,
  both with agent-side rollback/selfcheck where the server public URL is known.
- Self-host DNS deployment intent, CoreDNS/nft planning, rollback-protected
  apply, Cloudflare hostname publication, separate service/publish status, and
  optional pinned CoreDNS executable install.
- Proxy-core/subscription foundation: shared models, redacted proto views,
  JSON/bbolt persistence, and encrypted Reality/user/subscription credentials
  plus the first fail-closed sing-box `vless`+TCP+REALITY renderer, scoped
  CRUD/read APIs that return secret-free views, a redacted reviewed plan
  endpoint that binds the real rendered config hash, and secret-safe reviewed
  queue/apply with encrypted task scripts, `sing-box check`, atomic config swap,
  and task-result status reconciliation.
- Operator-owned NodeGeo records and a dependency-free dashboard world map.
- Static TypeScript source and dependency-free browser assets.
- Local AES-256-GCM encrypted JSON storage plus an append-only hash-chained audit WAL. The storage interface is isolated; the planned durable engine is bbolt to preserve the pure-Go / zero-CGo constraint. The server now has an explicit JSON↔bbolt migration/export CLI plus record-level bbolt APIs for current state buckets; JSON remains the default runtime store.

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
- Plugins must pass signed-manifest verification before lifecycle registration. Active plugins receive only a capability-scoped broker through the runtime runner contract; artifact execution is still disabled by default.
- Management APIs should live on WireGuard/private addresses or behind a hardened reverse proxy.

## Operator Docs

- [Tutorial index](./docs/tutorials/README.md)
- [Server install](./docs/tutorials/server-install.md)
- [Agent install](./docs/tutorials/agent-install.md)
- [Storage migration drills](./docs/tutorials/storage-migration.md)
- [Plugins](./docs/tutorials/plugins.md)
- [Network guard](./docs/tutorials/network-guard.md)
- [Development report, 2026-06-13](./docs/development-report-2026-06-13.md)

## Contributor Docs

- [Development workflow](./docs/development-workflow.md)

## Repository Creation Order

Publish `lattice-sdk` first, then `lattice-server` and `lattice-node-agent`,
then `lattice-dashboard`, `lattice-plugin-template`, `lattice`, and `.github`.
Tag `lattice-sdk` as `v0.1.0` before building server/agent without the local
workspace.
