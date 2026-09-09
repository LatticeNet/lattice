# Archived roadmap backlog (2026-06)

The feature backlog that sat in `docs/roadmap.md` until 2026-09-03. It was
written between 2026-06-11 and 2026-06-15 and never revised after iteration
060, so it describes a six-repository ecosystem, calls plugin artifact
execution disabled, and omits designs 12 through 19 and the four production
plugins. It is kept because the delivered/pending annotations record what was
actually shipped in June 2026 and why some items were dropped.

Current planning lives in `docs/PRODUCT-VISION.md` section 5 (the program in
leverage order), `docs/designs/README.md` (per-capability status), and the
operator's program log at the workspace root.

---

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
- Add PAT creation/revocation UI. *(Delivered: API and dashboard UI support
  one-time credential reveal, revocation, scope containment, and current
  `server_allowlist` context when minting child PATs.)*
- Add approval re-authentication for `network:apply` and `task:run`.
- Require reviewed-plan SHA-256 binding before high-risk apply approvals.
  *(Delivered 2026-06-14 in iter-025; re-authentication still pending.)*
- Add systemd units and install scripts. *(Agent update control landed in
  iter-058; first-class packaging/unit templates remain pending.)*
- Add Docker/Compose server deployment. *(Dockerfile, GHCR workflow, and compose
  guide landed as the server deployment path; node-agent remains systemd-first.)*
- Add end-to-end browser QA.
- Add node-token last-used telemetry and optional source-IP policy. *(Delivered:
  token rotation, write-throttled `token_last_used_at`, and per-node
  `agent_source_allowlist` exact-IP/CIDR enforcement with proxy headers honored
  only under explicit `TrustProxy`.)*
- Add task-exec OS sandboxing: mount namespace filesystem isolation and optional
  seccomp/bubblewrap remain; runtime posture reporting, Linux no-new-privileges,
  private per-task temp/workdir envs, Linux task `umask 077`, optional non-root
  systemd service profile, server kill switch, and configurable cgroup v2
  CPU/memory/pids caps have landed.

## Plugin Platform

- Signed plugin loader + fail-closed trust policy. *(Delivered 2026-06-12.)*
- Plugin lifecycle registry/API/UI. *(Delivered 2026-06-12.)*
- Host-API broker + server adapter. *(Delivered 2026-06-12.)*
- Runtime manager + runner contract. *(Delivered 2026-06-12; default runner is
  `noop`, so plugin artifacts do not execute yet.)*
- Concrete system/worker/wasm runners with capability enforcement, per-plugin
  deadlines, rate limits, log/output caps, and runtime health depth. *(Design 08
  defines the required gates and order; execution remains disabled.)*
- Marketplace fetch/install of signed artifacts. *(Static `lattice-plugin-index`
  foundation is defined; remote install and activation remain pending.)*

## Network Plugins

- nft Network Guard apply mode with rollback file. *(Delivered 2026-06-14 in
  iter-024; `nft` approvals now commit `/etc/lattice/guard.nft` after `nft -c`,
  with a rollback watchdog and optional control-plane selfcheck when
  `public_url` is configured.)*
- WireGuard peer renderer using `/32` cryptokey routing.
- Cloudflare IP set updater for HTTP origins.
- cloudflared tunnel installation and health monitoring.
- **Per-node nft access control + network/geo visualization** — designed in
  [`designs/design-05-network-acl-and-map.md`](../designs/design-05-network-acl-and-map.md)
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
  Iter-030 adds operator-authored IPv6 CIDR/node remotes for egress and ingress
  composition. Iter-031 adds egress domain-valued operator remotes backed by
  node-filled v4/v6 nft named sets and the existing periodic refresh path.
  Iter-032 adds a cron.d fallback when systemd is unavailable. Bulk geo import
  and map overlays remain pending.
  *(Partially built.)*

## Service Plugins / Providers

> Designed in [`designs/design-01-proxy-cores-and-subscriptions.md`](../designs/design-01-proxy-cores-and-subscriptions.md)
> (CORE provider, not a third-party plugin) and [`designs/design-02-self-host-dns.md`](../designs/design-02-self-host-dns.md).

- **Proxy-core orchestration + subscriptions** — sing-box and xray config
  renderers + reload, fleet-wide tokenized subscriptions, node-agnostic users.
  Iter-039 delivered the foundation: `ProxyInbound`, `ProxyUser`,
  `ProxyNodeProfile`, and `ProxyUsageSnapshot` SDK models, redacted proto views,
  JSON-store/bbolt collection parity, and AES-GCM at-rest encryption for Reality
  private keys, UUID/password credentials, and subscription tokens. Iter-040
  delivered the first server-side sing-box `vless`+TCP+REALITY renderer with
  typed JSON generation, canonical config SHA-256, user eligibility filtering,
  and fail-closed validation. Iter-041 delivered scoped inbounds/users/profiles
  CRUD with secret-free JSON views and node-allowlist-filtered profiles.
  Iter-042 delivered a redacted reviewed `/api/proxy/nodes/{id}/plan` endpoint
  that binds the real rendered config hash and rejects stale approvals.
  Iter-043 encrypted persisted task scripts and enabled `proxycore`
  queue/apply with `sing-box check`, atomic config swap, reload/restart
  activation, and task-result status reconciliation. Iter-044 delivered the
  public `/sub/{token}` MVP: plain/base64 VLESS+REALITY links across applied
  sing-box node profiles, `Subscription-Userinfo`, dedicated public rate
  limiting, constant-time token scan, raw-token-free audit metadata, and
  fail-closed duplicate-token handling. Iter-045 delivered dashboard proxy
  inbounds/users/profiles management and explicit audited rotate/copy
  subscription URL workflow. Iter-046 delivered baseline usage reporting:
  `/api/agent/proxy-usage`, `/api/proxy/usage`, server-side monotonic diffing,
  per-node eligibility filtering, an agent `-proxy-usage-file` bridge, and
  dashboard usage/last-seen display. Iter-047 delivered sing-box client JSON
  and Clash/Mihomo YAML subscription bodies through the existing public
  `/sub/{token}` endpoint, while keeping subscription rendering secret-free and
  dependency-free. Iter-048 delivered a focused dashboard proxy apply review
  flow over the existing plan-hash-bound approval API. Iter-049 delivered a
  stdlib-only node-agent loopback HTTP/V2Ray-stats collector foundation behind
  the existing `ProxyUsageSnapshot` contract. Iter-050 delivered persistent,
  server-owned quota/expiry notifications (80%, 100%, 7d, 1d, expired) through
  the existing notification channels. Iter-051 delivered copy-ready dashboard
  import helpers for the already-supported subscription formats without adding
  a token reveal API. Iter-052 delivered agent-reported collector
  health/error state on proxy profiles without letting error reports mutate the
  accounting baseline. Iter-053 delivered xray VLESS+REALITY+TCP config
  rendering, reviewed `xray test -c` apply, dashboard core selection, and xray
  nodes in the same fleet-wide VLESS subscriptions. Iter-054 delivered the
  dependency-free xray stats transport (`xray api statsquery` via the on-node
  binary, ADR-003 — no `grpc-go`; sing-box uses its existing loopback HTTP API).
  Iter-055 delivered config-drift detection: the scheduler flags applied configs
  that still serve now-ineligible users, audits the transition, and the dashboard
  promotes a one-click Review & Apply enforce path (no auto-apply; approval
  preserved). Iter-058 added server-controlled agent updates outside the proxy
  provider. Next proxy slice: opt-in auto-enforce for reduction-only drift.
  *(Partially built.)*
- **Self-hosted DNS** — per-node CoreDNS deploy via plan→approve→apply + CF
  subdomain/DDNS + nft confinement. Shared `NFTInputs` persistence delivered
  2026-06-13 so DNS can compose into the single nft table. Iter-033 delivered
  the `DNSDeployment` intent model, encrypted inline CF token storage, bbolt
  bucket parity, scoped CRUD API, and dashboard panel. Iter-034 delivered the
  dependency-free CoreDNS renderer and `/api/dns/plan`, including the composed
  `lattice_guard` candidate. Iter-035 delivered the selfdns apply script with
  config/firewall rollback and task-result status reconciliation.
  Iter-036 delivered `/api/dns/publish`, Cloudflare publication through the
  existing DDNS provider, automatic publication on node IP changes, and a
  dashboard Publish control. Iter-037 split CoreDNS/nft apply status
  (`last_applied_at` / `last_error`) from Cloudflare publication status
  (`last_published_at` / `last_publish_error`). Iter-038 added optional pinned
  CoreDNS direct-executable install from a reviewed HTTPS URL + SHA-256. A real
  Linux-node E2E is next. *(Partially built.)*
- Sub-Store-style subscription transform/aggregation (folded into design-01 v2+).
- nginx domain + path static publishing.

## Observability

- **System log ingestion + query** — **MVP shipped iter-056**
  ([`designs/design-03-log-ingestion.md`](../designs/design-03-log-ingestion.md)):
  agent tails a path → dedicated bounded bbolt `logs.db` (NOT the JSON store) →
  scoped query/stats API + dashboard Logs panel. Fail-closed path validation
  (`/var/log/` allowlist, `/proc,/sys,/dev` deny), cross-node ingest rejection,
  per-source byte-cap + lines/sec budget (429), optional at-rest chunk
  encryption. v2: encryption-default + age/global sweeper + silent-source notify
  + journald. *(MVP built.)*
- **Machine inventory + cost/renewal** — designed in
  [`designs/design-04-machine-inventory-and-cost.md`](../designs/design-04-machine-inventory-and-cost.md)
  (auto-detect cores/mem/uptime/arch; cloud vendor/cost/renewal + reminder scheduler).
  `HostFacts` auto-detect/report/display delivered 2026-06-13; server-only
  `MachineProfile` cost/vendor/renewal metadata, encrypted console/detail links,
  renewal reminders, and Machines dashboard MVP delivered 2026-06-13. Audited
  link reveal, per-currency totals, and fact-change alerts remain v2.
- **Fleet Map v2** — delivered 2026-06-17 with automatic IP lookup behind an
  explicit GeoIP provider URL, manual override preservation, source-aware
  NodeGeo metadata, and a refined SVG world map in the dashboard.
- Historical metrics retention.
- Server-controlled agent debug diagnostics. *(Delivered 2026-06-17 with
  `lattice-agent v0.2.1`: local node debug output plus optional central
  collection into managed Logs sources.)*
- Fleet latency matrix.
- SSH login alert stream.
- Browser terminal MVP: scoped `terminal:open` API, agent-side opt-in PTY
  session runner, dashboard Terminal page, bounded in-memory transcript
  retention, xterm rendering, node-level entrypoints, and open/close audit
  events.
- Astra iOS companion v2 repository publication: phone-first Overview, Nodes,
  Monitors, Inventory, More, typed API client, analytics layer, Network &
  security read views with plan-hash-bound approval, GitHub Actions CI, and
  simulator build verification. Signing, TestFlight, live-server QA, and final
  mobile operation policy are still pending.
- Multi-channel notifications. (Delivered 2026-06-11: `internal/notify` + `POST /api/notify/test`; persistent channel config + event triggers pending.)
- DDNS (dynamic DNS) plugin. (Delivered 2026-06-11: cloudflare + webhook providers, server-side IP-change trigger, `/api/ddns` CRUD + `/api/ddns/run`.)
- Continuous service monitoring (ping/tcping/http). (Delivered 2026-06-11: tcp + http monitors, agent scheduler, capped result history, `/api/monitors` + agent fetch/report; icmp pending.)
- Notification config + event alerts (monitor down/up, SSH login). (Delivered 2026-06-11: persistent channels, server dispatcher, agent `-ssh-alerts` watcher; per-rule routing pending.)
- WireGuard mesh config generation. (Delivered 2026-06-11: per-node config generator + mesh planner, `/api/network/wireguard/plan` with approve→apply; agent reports wg metadata. Auto key-gen pending.)
- Cloudflare Tunnel support. (Delivered 2026-06-11: TunnelProfile + cloudflared config.yml generator, `/api/tunnels` CRUD + plan→approve→apply.)
- Backup hub replication.
