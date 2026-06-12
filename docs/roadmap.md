# Roadmap

> **2026-06-11 security hardening pass** delivered the items marked *(Delivered)*
> below plus a broad set of fixes (authz bugs, rate limiting, O(1) PAT auth,
> session persistence, nft/storage input validation, TLS/HSTS, real CPU metrics,
> agent timeouts). See [`SECURITY-HARDENING.md`](./SECURITY-HARDENING.md).
>
> **2026-06-12 follow-up:** OIDC/SSO backend + dashboard UI, TOTP 2FA, at-rest
> encryption, tamper-evident audit WAL, signed plugin loader, lifecycle UI, host
> API broker, and runtime runner contract are now landed. The durable storage
> direction is **bbolt**, not SQLite, to preserve the pure-Go / zero-CGo rule;
> bucketized bbolt import/export plus JSON migration/rollback helpers have
> landed, but JSON is still the default server store.


## V1 Hardening

- Replace JSON storage with bbolt migrations, preserving AES-256-GCM secret
  encryption and moving hot/ephemeral records off whole-file rewrites.
  *(Bucketized import/export and JSON rollback helpers delivered; CLI workflow,
  record-level writes, and default store switch pending.)*
- Keep protobuf/ConnectRPC transport and generated TypeScript clients as a later
  API-boundary upgrade; current JSON APIs remain the bootstrap surface.
- TOTP setup and recovery codes. *(Delivered 2026-06-12; enforce-2FA policy,
  TOTP replay protection, and WebAuthn groundwork pending.)*
- Add PAT creation/revocation UI. (API delivered 2026-06-11: `POST/GET /api/tokens`, `/api/tokens/revoke`; UI pending.)
- Add approval re-authentication for `network:apply` and `task:run`.
- Add systemd units and install scripts.
- Add end-to-end browser QA.
- Add node-token last-used telemetry and optional source-IP policy. (Rotation API
  delivered; last-used/source-IP policy pending.)
- Add task-exec OS sandboxing: non-root service profile, cgroup CPU/memory caps,
  kill switch, and optional seccomp/bubblewrap where available.

## Plugin Platform

- Signed plugin loader + fail-closed trust policy. *(Delivered 2026-06-12.)*
- Plugin lifecycle registry/API/UI. *(Delivered 2026-06-12.)*
- Host-API broker + server adapter. *(Delivered 2026-06-12.)*
- Runtime manager + runner contract. *(Delivered 2026-06-12; default runner is
  `noop`, so plugin artifacts do not execute yet.)*
- Concrete system/worker/wasm runners with capability enforcement, per-plugin
  deadlines, rate limits, log/output caps, and runtime health depth.
- Marketplace fetch/install of signed artifacts.

## Network Plugins

- nft apply mode with rollback file and explicit `apply=true`.
- WireGuard peer renderer using `/32` cryptokey routing.
- Cloudflare IP set updater for HTTP origins.
- cloudflared tunnel installation and health monitoring.

## Service Plugins

- sing-box config renderer and reload workflow.
- xray config renderer and reload workflow.
- Sub-Store Node/Docker supervisor and path reverse proxy.
- nginx domain + path static publishing.

## Observability

- Historical metrics retention.
- Fleet latency matrix.
- SSH login alert stream.
- Multi-channel notifications. (Delivered 2026-06-11: `internal/notify` + `POST /api/notify/test`; persistent channel config + event triggers pending.)
- DDNS (dynamic DNS) plugin. (Delivered 2026-06-11: cloudflare + webhook providers, server-side IP-change trigger, `/api/ddns` CRUD + `/api/ddns/run`.)
- Continuous service monitoring (ping/tcping/http). (Delivered 2026-06-11: tcp + http monitors, agent scheduler, capped result history, `/api/monitors` + agent fetch/report; icmp pending.)
- Notification config + event alerts (monitor down/up, SSH login). (Delivered 2026-06-11: persistent channels, server dispatcher, agent `-ssh-alerts` watcher; per-rule routing pending.)
- WireGuard mesh config generation. (Delivered 2026-06-11: per-node config generator + mesh planner, `/api/network/wireguard/plan` with approve→apply; agent reports wg metadata. Auto key-gen pending.)
- Cloudflare Tunnel support. (Delivered 2026-06-11: TunnelProfile + cloudflared config.yml generator, `/api/tunnels` CRUD + plan→approve→apply.)
- Backup hub replication.
