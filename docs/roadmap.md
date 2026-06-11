# Roadmap

## V1 Hardening

- Replace JSON storage with SQLite WAL migrations.
- Add protobuf/ConnectRPC transport and generated TypeScript clients.
- Add TOTP setup and recovery codes.
- Add PAT creation/revocation UI.
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
- Multi-channel notifications.
- Backup hub replication.

