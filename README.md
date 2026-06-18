# Lattice

Lattice is the umbrella repository for the LatticeNet ecosystem: a
security-first server probe, automation, and cluster network control plane.

The code is intentionally split into independent repositories so server,
node-agent, dashboard, SDK, plugins, and mobile companion surfaces can be
released and maintained separately.

## Ecosystem Repositories

- [`lattice-sdk`](https://github.com/LatticeNet/lattice-sdk) - shared Go protocol/domain models.
- [`lattice-server`](https://github.com/LatticeNet/lattice-server) - deployable control plane.
- [`lattice-node-agent`](https://github.com/LatticeNet/lattice-node-agent) - deployable outbound node agent.
- [`lattice-dashboard`](https://github.com/LatticeNet/lattice-dashboard) - static dashboard.
- [`lattice-plugin-template`](https://github.com/LatticeNet/lattice-plugin-template) - starter templates for system, Worker, and future Wasm plugins.
- [`.github`](https://github.com/LatticeNet/.github) - organization profile.
- [`Astra`](https://github.com/LatticeNet/Astra) - iOS companion app for the
  Lattice mobile control surface.

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
- Geo-Routing configure+preview for a self-hosted DNS apex, using
  operator-owned node locations and healthy-node selection.
- Log ingestion/query MVP with a dedicated bounded `logs.db`, agent tailer,
  scoped source management, and dashboard Logs panel.
- Server-controlled node-agent update policies with manual update plans,
  auto-plan pending approvals, SHA-256-pinned HTTPS artifacts, and delayed
  service restart after task result reporting.
- Proxy-core/subscription foundation: shared models, redacted proto views,
  JSON/bbolt persistence, and encrypted Reality/user/subscription credentials
  plus the first fail-closed sing-box `vless`+TCP+REALITY renderer, scoped
  CRUD/read APIs that return secret-free views, a redacted reviewed plan
  endpoint that binds the real rendered config hash, and secret-safe reviewed
  queue/apply with encrypted task scripts, `sing-box check`, atomic config swap,
  task-result status reconciliation, and a public plain/base64 `/sub/{token}`
  MVP with `Subscription-Userinfo`, dedicated rate limiting, hashed-token audit,
  duplicate-token fail-closed handling, sing-box JSON and Clash/Mihomo YAML
  subscription formats for VLESS+REALITY+TCP, plus dashboard
  inbounds/users/profiles management, an explicit audited rotate/copy
  subscription URL workflow, and a baseline usage-reporting path with
  server-side monotonic rollup plus dashboard usage/last-seen display.
- Operator-owned NodeGeo records and a dependency-free dashboard world map.
- Astra iOS companion app v2 for phone-first operations: Overview, Nodes,
  Monitors, Inventory, and More tabs backed by a Swift `LatticeClient` for
  identity/version, nodes, PATs, machine inventory, monitors/results,
  Network & security read views with SHA-256-bound approval, notifications,
  audit, tasks, and logs. Source is published in `LatticeNet/Astra`; signing,
  TestFlight, and live iPhone QA remain separate release steps.
- Static TypeScript source and dependency-free browser assets.
- Local AES-256-GCM encrypted JSON storage plus an append-only hash-chained audit WAL. The storage interface is isolated; the planned durable engine is bbolt to preserve the pure-Go / zero-CGo constraint. The server now has an explicit JSON↔bbolt migration/export CLI plus record-level bbolt APIs for current state buckets; JSON remains the default runtime store.

## Quick Start

Docker server deployment:

```sh
cd Lattice/lattice/compose
cp .env.example .env
$EDITOR .env
docker compose up -d
```

See [Docker server deployment](./docs/tutorials/docker-server.md). The
recommended production shape is containerized `lattice-server` plus a
systemd-managed host `lattice-node-agent`.

Local binary development:

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
- [Operator guide](./docs/tutorials/operator-guide.md)
- [Server install](./docs/tutorials/server-install.md)
- [Agent install](./docs/tutorials/agent-install.md)
- [Agent updates](./docs/tutorials/agent-updates.md)
- [Storage migration drills](./docs/tutorials/storage-migration.md)
- [Plugins](./docs/tutorials/plugins.md)
- [Network guard](./docs/tutorials/network-guard.md)
- [Development report, 2026-06-13](./docs/development-report-2026-06-13.md)

## Contributor Docs

- [Development workflow](./docs/development-workflow.md)

## Repository Creation Order

Publish `lattice-sdk` first, then `lattice-server`, `lattice-node-agent`,
`lattice-dashboard`, `lattice-plugin-template`, `lattice`, and `.github`.
`lattice-dashboard` is the canonical modern Vue dashboard; server images pin a
specific dashboard commit through `lattice-server/dashboard.ref`.

## Shared Contract Releases

`lattice-server` and `lattice-node-agent` intentionally consume shared models
from `lattice-sdk`. When SDK contracts change, cut a new `lattice-sdk` tag first
and then update the dependent `go.mod` files. Local multi-repo development can
use `go.work`, but standalone builds should not depend on an untagged SDK
`main`.

Current dependent SDK version: `v0.2.0`.
