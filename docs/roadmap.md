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
> bucketized bbolt import/export, JSON migration/rollback CLI, and record-level
> bbolt APIs for current state buckets have landed, but JSON is still the
> default server store.
>
> **2026-06-13 closeout:** the current six-repo baseline and next development
> order are captured in [`development-report-2026-06-13.md`](./development-report-2026-06-13.md).
>
> **2026-06-13 audit + designs:** a full-codebase security/stability audit was
> run and remediated ([`iterations/iter-016-audit-remediation.md`](./iterations/iter-016-audit-remediation.md)):
> ~25 fixes incl. state-file fsync durability, WireGuard `/32` host routes,
> per-plugin KV namespacing, TOTP replay protection, session-epoch invalidation,
> trust-proxy CIDR allowlist, constant-time CSRF/recovery-code. The next major
> capabilities are now fully designed in [`designs/`](./designs/README.md)
> (proxy cores + subscriptions, self-host DNS, log ingestion, machine inventory +
> cost, per-node nft ACL + geo-map). Machine-inventory HostFacts landed in
> iter-017, MachineProfile cost/renewal reminder MVP landed in iter-018, and
> shared per-node nft input persistence landed in iter-019. Design 05's
> `NetPolicy` state/API/reachability graph/dashboard foundation landed in
> iter-020; egress-only nft compiler/plan/apply with dead-man rollback and
> agent control-plane selfcheck landed in iter-021; operator `NodeGeo` CRUD and
> the dependency-free dashboard Fleet Map landed in iter-022; dashboard
> policy-graph SVG landed in iter-023; Network Guard now commits
> `lattice_guard` with rollback/selfcheck and composes enabled ingress policy
> into the single input chain in iter-024. Control-plane domain-backed nft sets
> now have IPv4/IPv6 refresh; domain-valued operator remotes, operator policy
> IPv6, bulk geo import, and map overlays remain pending.


## V1 Hardening

- Replace JSON storage with bbolt migrations, preserving AES-256-GCM secret
  encryption and moving hot/ephemeral records off whole-file rewrites.
  *(Bucketized import/export, JSON rollback CLI, and record-level APIs for
  nodes/KV/audit/static/Workers/plugin lifecycle/approvals/tasks/results/
  monitors/monitor results/tunnels/users/tokens/sessions/TOTP/DDNS/notify/OIDC
  delivered; default store switch pending.)*
- Keep protobuf/ConnectRPC transport and generated TypeScript clients as a later
  API-boundary upgrade; current JSON APIs remain the bootstrap surface.
- TOTP setup and recovery codes. *(Delivered 2026-06-12; TOTP replay protection
  delivered 2026-06-13 (per-user last-step compare-and-set). Enforce-2FA policy
  and WebAuthn groundwork pending.)*
- Add PAT creation/revocation UI. (API delivered 2026-06-11: `POST/GET /api/tokens`, `/api/tokens/revoke`; UI pending.)
- Add approval re-authentication for `network:apply` and `task:run`.
- Require reviewed-plan SHA-256 binding before high-risk apply approvals.
  *(Delivered 2026-06-14 in iter-025; re-authentication still pending.)*
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

- nft Network Guard apply mode with rollback file. *(Delivered 2026-06-14 in
  iter-024; `nft` approvals now commit `/etc/lattice/guard.nft` after `nft -c`,
  with a rollback watchdog and optional control-plane selfcheck when
  `public_url` is configured.)*
- WireGuard peer renderer using `/32` cryptokey routing.
- Cloudflare IP set updater for HTTP origins.
- cloudflared tunnel installation and health monitoring.
- **Per-node nft access control + network/geo visualization** — designed in
  [`designs/design-05-network-acl-and-map.md`](./designs/design-05-network-acl-and-map.md)
  (fail-closed compiler with dead-man rollback; zero-dep inline-SVG map).
  Shared `NFTInputs` persistence delivered 2026-06-13, and `NetPolicy`
  validation/store/API/graph/dashboard state delivered in iter-020. Egress-only
  nft compiler, `/api/netpolicy/plan`, agent selfcheck/rollback apply, task
  result status tracking, and dashboard `Plan Apply` entry landed in iter-021.
  Operator `NodeGeo` CRUD and the zero-dependency inline-SVG Fleet Map landed in
  iter-022. Dashboard policy-graph SVG landed in iter-023. Ingress rules now
  compose into the single `lattice_guard` Network Guard render in iter-024,
  so a deny can constrain broad public/WireGuard port allows without creating a
  second input hook. Iter-026 adds the first domain-backed nft set: HTTPS
  hostname `public_url` values for `nftpolicy` apply render a
  node-filled `lattice_control4` control-plane set instead of requiring an IPv4
  literal. Iter-027 moves the apply-time set mutation into
  `lattice-agent --update-nft-domain-set` so DNS answers no longer flow through
  shell parsing. Iter-028 installs a systemd timer to refresh the
  control-plane set periodically and removes stale timer artifacts when a later
  approved apply no longer uses a hostname. Iter-029 adds `lattice_control6`
  plus IPv6 literal `public_url` support for control-plane reachability.
  Domain-valued operator remotes, operator-authored IPv6 policy remotes,
  non-systemd scheduling, bulk geo import, and map overlays remain pending.
  *(Partially built.)*

## Service Plugins / Providers

> Designed in [`designs/design-01-proxy-cores-and-subscriptions.md`](./designs/design-01-proxy-cores-and-subscriptions.md)
> (CORE provider, not a third-party plugin) and [`designs/design-02-self-host-dns.md`](./designs/design-02-self-host-dns.md).

- **Proxy-core orchestration + subscriptions** — sing-box config renderer + reload
  (v1), xray (v2), fleet-wide tokenized subscriptions, node-agnostic users. *(Designed.)*
- **Self-hosted DNS** — per-node CoreDNS deploy via plan→approve→apply + CF
  subdomain/DDNS + nft confinement. Shared `NFTInputs` persistence delivered
  2026-06-13 so DNS can compose into the single nft table; DNS deployment itself
  is still pending. *(Designed; prerequisite landed.)*
- Sub-Store-style subscription transform/aggregation (folded into design-01 v2+).
- nginx domain + path static publishing.

## Observability

- **System log ingestion + query** — designed in
  [`designs/design-03-log-ingestion.md`](./designs/design-03-log-ingestion.md)
  (agent tails a path → bounded per-node store, NOT the JSON store → query API). *(Designed.)*
- **Machine inventory + cost/renewal** — designed in
  [`designs/design-04-machine-inventory-and-cost.md`](./designs/design-04-machine-inventory-and-cost.md)
  (auto-detect cores/mem/uptime/arch; cloud vendor/cost/renewal + reminder scheduler).
  `HostFacts` auto-detect/report/display delivered 2026-06-13; server-only
  `MachineProfile` cost/vendor/renewal metadata, encrypted console/detail links,
  renewal reminders, and Machines dashboard MVP delivered 2026-06-13. Audited
  link reveal, per-currency totals, and fact-change alerts remain v2.
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
