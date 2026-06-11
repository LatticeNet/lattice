# Roadmap

> **2026-06-11 security hardening pass** delivered the items marked *(Delivered)*
> below plus a broad set of fixes (authz bugs, rate limiting, O(1) PAT auth,
> session persistence, nft/storage input validation, TLS/HSTS, real CPU metrics,
> agent timeouts). See [`SECURITY-HARDENING.md`](./SECURITY-HARDENING.md).


## V1 Hardening

- Replace JSON storage with SQLite WAL migrations.
- Add protobuf/ConnectRPC transport and generated TypeScript clients.
- Add TOTP setup and recovery codes.
- Add PAT creation/revocation UI. (API delivered 2026-06-11: `POST/GET /api/tokens`, `/api/tokens/revoke`; UI pending.)
- Add approval re-authentication for `network:apply` and `task:run`.
- Add systemd units and install scripts.
- Add end-to-end browser QA.

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
- Backup hub replication.

