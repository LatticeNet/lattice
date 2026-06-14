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
3. Operator approves with the dashboard-computed `sha256(plan)`.
4. Server queues a bounded validation/apply task.
5. Agent returns result.
6. Audit log records each step.

Pending host-mutating approvals require `plan_sha256`; the server rejects a
missing hash with `400` and a mismatched hash with `409`. Already-decided
approvals remain idempotent and do not queue duplicate tasks.

The current nft flow has two committed apply paths:

- Network Guard (`Approval.Plugin == "nft"`) owns the single
  `table inet lattice_guard` input ruleset. It validates with `nft -c`, snapshots
  rollback state, arms a 60s watchdog, commits with `nft -f`, and performs a
  control-plane selfcheck when `public_url` is configured.
- NetPolicy egress (`Approval.Plugin == "nftpolicy"`) owns
  `table inet lattice_policy` output filtering. It always injects the
  control-plane/DNS egress allows before operator rules, then applies with the
  same validate -> rollback snapshot -> watchdog -> commit -> selfcheck pattern.
  HTTPS-domain control-plane URLs and operator-authored egress domain remotes
  compile to empty v4/v6 nft named sets; the node apply script fills and
  periodically refreshes those sets through `lattice-agent
  --update-nft-domain-set` before the selfcheck. Periodic refresh is installed
  through systemd when available, with `/etc/cron.d` as the non-systemd Linux
  fallback.

Ingress NetPolicy rules are not emitted as a second input hook. They are folded
into Network Guard's `lattice_guard` render so input filtering has one coherent
default-drop chain.

## Plugin Types

- `system`: trusted built-ins for nft, WireGuard, nginx, cloudflared, sing-box,
  xray, Sub-Store supervision, SSH login alerts, and notifications.
- `wasm`: future wazero sandboxed plugins. Host APIs must be explicit capabilities.
- `worker`: lightweight route handlers. The bootstrap runtime supports safe
  template rendering and KV interpolation, not arbitrary JavaScript execution.

## Host-API Broker

`lattice-server/internal/plugin.Broker` is the core-owned facade between verified
plugins and server-owned handles. It is constructed from a `plugin.Loaded`
registry entry, checks the manifest's declared capabilities on every call, and
records a capability authorization event through an injected audit sink.

Current broker surfaces:

- `kv:read` / `kv:write` for key-value reads and writes.
- `notify:send` for notification fanout through configured channels.
- `http:egress` for guarded outbound HTTP. The injected HTTP host must enforce
  the server's SSRF/egress policy before dialing.
- `log:write` for plugin-authored structured logs; the broker stamps the
  verified plugin id.

The broker is a contract and enforcement point, not a runtime by itself. The
server runtime manager binds active plugins to this broker and reports runtime
health, but subprocess/wasm execution, per-plugin runtime limits, and process
isolation remain separate Phase B work.

`lattice-server/internal/server/plugin_host.go` provides the first server-owned
adapter for this contract:

- KV calls use `bucket/key` references and validate both halves with the same
  storage-name rules as the public API.
- Notification calls synchronously fan out to enabled channels through the same
  channel builders used by the console.
- HTTP calls use `internal/outbound.NewClient`, so DNS rebinding, redirects, and
  private/link-local/metadata targets stay blocked. Request and response bodies
  are capped at 256 KiB.
- Broker capability allow/deny events are persisted as `plugin.host.*` audit
  events with plugin id, capability, decision, and correlation id.

## Plugin Lifecycle

Verified plugin bundles are persisted as `PluginInstallation` records in the
store. This lifecycle registry is metadata-only: it records manifest identity,
capabilities, artifact digest, local bundle path, status timestamps, and audit
history, but it does **not** execute plugin code.

Status transitions are intentionally narrow:

```txt
verified -> installed -> active -> disabled -> active
                      \-> disabled
```

Skipping install (`verified -> active`) and downgrading trust
(`active/disabled -> verified`) are rejected. Server startup registers only
bundles that passed the signed manifest/digest loader; rejected bundles are
audited and are not added to the lifecycle store. Existing lifecycle state is
preserved across restart, so a disabled plugin is not re-enabled just because its
bundle is still present on disk.

Operator API:

- `GET /api/plugins/lifecycle` (scope `plugin:admin`) returns a public view of
  installation metadata and timestamps. It includes `available` to show whether
  the bundle is present in the current verified loader set. It deliberately
  omits `bundle_path` so local filesystem layout is not leaked to the dashboard
  or API clients.
- `POST /api/plugins/lifecycle` (scope `plugin:admin`) accepts `{id, status}`
  and performs a validated state transition. Moving to `installed` or `active`
  requires `available:true`; stale records for missing bundles can be disabled
  but not activated. The endpoint records `plugin.status` audit events, but does
  not fork, load, or run plugin code.

## Plugin Runtime Manager

`lattice-server/internal/plugin.RuntimeManager` is the first runtime control
surface. It is intentionally an execution-safe skeleton:

- `active` lifecycle state arms a capability-scoped `plugin.Broker` for the
  verified plugin through a `plugin.Runner` and records runtime health as
  `armed`.
- `disabled` stops the in-memory runtime handle and records health as `stopped`.
- Existing `active` plugins are armed again on server startup only when their
  bundle is still in the verified loader set.
- Runtime health is returned in the lifecycle API as `runtime` with
  `plugin_id`, `state`, `runner`, timestamps, and message. It omits
  `bundle_path` and raw broker handles.
- If arming fails after a lifecycle activation request, the server moves the
  plugin back to `disabled`, records a denied `plugin.runtime` audit event, and
  returns an error.
- Runner start receives a context with a bounded deadline. The default runner is
  `noop`, which only arms the broker and does not execute artifact code.

This manager does **not** execute plugin artifacts. Future system/wasm/worker
runners must use this manager as the only path to a `plugin.Broker`, then add
explicit process/wasm isolation, cancellation, rate limits, log/output caps, and
health reporting before any artifact code runs.

## Cloudflare Tunnel

A `TunnelProfile` maps public hostnames to node-local services
(`http://localhost:8088`, `ssh://localhost:22`, ...). The server renders a
cloudflared `config.yml` from it (validated hostnames/services, mandatory
catch-all `http_status:404`). Because cloudflared dials out to Cloudflare's
edge, a NAT-bound node can expose services with no inbound ports.

Deployment uses the shared `plan -> approve -> apply` flow:
`/api/tunnels` CRUD and `/api/tunnels/plan` (scope `tunnel:admin`) produce an
approval; approving with `queue_apply` writes `/etc/cloudflared/config.yml`,
runs `cloudflared ingress validate`, and reloads the service. Tunnel credentials
stay node-local (referenced by path); the server stores only the topology.

## WireGuard Mesh

The server is the mesh's topology brain. From each node's reported public key,
mesh IP, and optional public endpoint it generates a per-node `wg0.conf`:

- one `[Peer]` per other keyed node, `AllowedIPs` pinned to the peer's `/32` (a
  node can only claim its own mesh IP), `PersistentKeepalive = 25` so NAT-bound
  nodes hold the tunnel open, and `Endpoint` only for directly-reachable peers.
- the node's **private key never reaches the server** — the config carries a
  placeholder the agent substitutes from its local key file at apply time.

Deployment follows the same `plan -> approve -> apply` flow as nft:
`POST /api/network/wireguard/plan` records a pending approval with the full
config (safe to diff — no secret), and approving with `queue_apply` dispatches a
bounded task that substitutes the private key and runs `wg-quick`. Keys/ports are
reported by the agent via `-wg-pubkey` / `-wg-endpoint` / `-wg-port`.

## Notifications and Alerts

Notification channels are persisted (`NotifyChannel`: kind + config + enabled)
and reused by every alert. Supported kinds are telegram, bark, discord, and a
generic webhook, all delivered by the dependency-free `internal/notify` package.
The list API returns only the configured key names, never the secret values.

Two event sources currently drive alerts, fanned out to every enabled channel:

- **Monitor state changes** — when a monitor's success flips (or on the first
  observed failure) the server emits a down/recovery alert, so a flapping target
  does not spam every probe result.
- **SSH logins** — agents started with `-ssh-alerts` stream sshd accepted-login
  lines from journald (or `auth.log`) and report them to `/api/agent/event`; the
  server records an `ssh.login` audit event and notifies.

Channel management (`/api/notify/channels`, `/api/notify/test`) requires the
`notify:send` scope.

## Service Monitoring

`lattice-server` distributes periodic reachability/latency monitors to agents,
mirroring the continuous ping/tcping pattern of NodeGet/nezha.

- A `Monitor` has a type (`tcp` or `http`; `icmp` is pending because it needs
  elevated privileges), a target (`host:port` or URL), an interval, a timeout,
  and an assignment (every node via `assign_all`, or an explicit `node_ids`
  list). Assigning members a monitor that targets their group leader is how the
  group's intra-region latency matrix is collected.
- Agents poll `/api/agent/monitors` for their assignment and run each monitor on
  its own schedule in a dedicated goroutine (started/stopped/restarted as the
  assignment changes), reporting `MonitorResult`s to
  `/api/agent/monitor-result`.
- The server keeps a capped history (most recent 500 per monitor) for trend
  display. Operator endpoints (`/api/monitors` CRUD, `/api/monitors/results`)
  require `monitor:read` / `monitor:admin`.

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

## Self-host DNS

`DNSDeployment` is server-owned intent for running CoreDNS on a chosen node. It
is a built-in provider, not a third-party plugin, because it mutates host
firewall state, owns Cloudflare publication credentials, and uses the high-risk
approval path.

Deployment follows the shared `plan -> approve -> apply` flow:

- `POST /api/dns/plan` renders a secret-free CoreDNS Corefile, optional static
  zone files, and a composed `lattice_guard` nft candidate. The DNS listener
  ports are folded into the single Network Guard input table rather than a
  second input hook.
- Approving the reviewed plan with `queue_apply` writes exactly those reviewed
  artifacts, validates with `nft -c`, snapshots rollback state, commits the
  guard ruleset, installs/restarts `lattice-selfdns.service`, and verifies the
  service is active.
- Cloudflare publication is server-side. `POST /api/dns/publish` and the node
  IP-change trigger reuse `internal/ddns` to publish the deployment hostname as
  A/AAAA records. The Cloudflare token is encrypted at rest and never sent to
  the node.

CoreDNS itself is fail-closed. If the server is not configured with a pinned
binary source, the node must already have `coredns` in `PATH`. If
`LATTICE_COREDNS_BINARY_VERSION`, `LATTICE_COREDNS_BINARY_URL`, and
`LATTICE_COREDNS_BINARY_SHA256` are set, the version, HTTPS URL, digest, and
fixed install path (`/usr/local/bin/coredns`) are copied into the reviewed
approval plan. The apply script verifies an existing binary by SHA-256 or
downloads the reviewed URL and installs only after digest verification.

Service apply status (`last_applied_at` / `last_error`) is separate from
hostname publication status (`last_published_at` / `last_publish_error`) so
operators can tell whether CoreDNS/nft failed or Cloudflare publication failed.

## Proxy Cores and Subscriptions

Proxy-core orchestration is a built-in core provider, not a third-party plugin.
It owns bearer credentials, subscription tokens, and reviewed host mutations, so
it uses the same server-owned trust boundary as DNS, DDNS, nft, WireGuard, and
Cloudflare Tunnel.

The current implementation includes the iter-039 persistence foundation, the
iter-040 first renderer slice, the iter-041 CRUD/read-view slice, the iter-042
reviewed-plan slice, the iter-043 secret-safe apply slice, and the iter-044
public subscription slice, plus the iter-045 dashboard/token-workflow slice, the
iter-046 usage-reporting baseline, the iter-047 subscription-format slice, and
the iter-048 focused dashboard apply-review slice:

- `ProxyInbound` models a central sing-box/xray inbound template. REALITY
  private keys are encrypted at rest and redacted from proto/read views.
- `ProxyUser` models a subscriber identity, quota/expiry state, and
  subscription bearer token. UUID, password, and subscription token are
  encrypted at rest; list/read views expose only `has_*` booleans.
- `ProxyNodeProfile` binds inbounds to a node for later render/apply.
- `ProxyUsageSnapshot` stores the last per-node accounting snapshot for later
  monotonic rollup.
- `lattice-server/internal/proxycore` can render a canonical, SHA-256-addressed
  sing-box config for the narrow MVP path: `vless` over TCP with REALITY. The
  renderer is fail-closed, typed-JSON only, filters ineligible users, and treats
  the output as a node-scoped secret-bearing artifact.
- `lattice-server/internal/server/server_proxy.go` exposes JSON CRUD for
  inbounds, users, and profiles. Inbound/user reads require unrestricted
  `proxy:read` because they are global policy/credential objects; profile reads
  are node-allowlist filtered. Views expose `has_reality_private_key`,
  `has_uuid`, `has_password`, and `has_sub_token` booleans instead of secret
  fields.
- `POST /api/proxy/nodes/{node_id}/plan` creates a pending `proxycore`
  approval whose plan text is a redacted sing-box config. The stored action
  binds the SHA-256 of the real rendered config, and approval re-renders the
  current config to reject stale plans.
- `queue_apply:true` for `proxycore` creates a normal agent task after
  plan-hash and current-config checks. The task script carries the real
  node-scoped sing-box config, so `model.Task.Script` is encrypted at rest in
  both JSON and bbolt stores. The agent script runs `sing-box check -c`, swaps
  the config atomically, reloads/restarts `sing-box`, and task results reconcile
  `ProxyNodeProfile.AppliedSHA256`, `LastApplyAt`, and `LastError`.
- `GET /sub/{token}` is the public subscription endpoint. It supports
  `format=base64` by default, `format=plain`, `format=sing-box`, `format=clash`,
  and `format=clash-meta` (`clash.meta` / `clashmeta` aliases). Plain/base64
  emit VLESS URIs, sing-box emits `application/json` client `outbounds`, and
  Clash/Mihomo emits `text/yaml` `proxies:` output. The route emits
  `Subscription-Userinfo`, rate-limits before credential lookup, scans
  subscription tokens in constant time, rejects duplicate stored tokens
  fail-closed, and records `proxy.subscription.fetch` audit events using a
  token SHA-256 hash rather than raw token material.
- `POST /api/proxy/users/rotate-sub-token` explicitly rotates a user's
  subscription token, invalidates the old public URL, audits old/new token
  SHA-256 hashes only, and returns the new subscription URL/path once for
  operator delivery. It uses `LATTICE_PUBLIC_URL` when configured and otherwise
  returns a relative `/sub/{token}` path instead of reflecting request `Host`.
- `lattice-dashboard` now has a `Proxy Core` panel for inbounds, users, node
  profiles, and pending proxy apply reviews. It can create/edit/delete those
  records, request proxy plan approvals, queue pending `proxycore/apply-config`
  approvals through the existing plan-hash-bound approve API, and rotate/copy a
  user's subscription URL without receiving raw token material during ordinary
  refresh.
- `POST /api/agent/proxy-usage` lets an authenticated node report a
  `ProxyUsageSnapshot`. The server forces the node id from the authenticated
  request, filters counters to users eligible for that node profile, rejects
  malformed/negative input, applies deltas under a dedicated mutex, and audits
  aggregate counts only.
- `GET /api/proxy/usage` returns secret-free per-node snapshots and per-user
  usage views for the dashboard. The first report is baseline-only; later
  reports advance `ProxyUser.UsedBytes` monotonically, treat `core_uptime_sec`
  decreases as resets, and never subtract usage on counter rollback.
- `lattice-node-agent` currently supports `-proxy-usage-file` /
  `LATTICE_PROXY_USAGE_FILE` as a bounded JSON snapshot bridge. This is the
  stable collector contract for sidecars and future direct sing-box/xray
  collectors; direct core API polling remains a later slice.

Direct sing-box/xray stats collectors, usage notifications, subscription import
helpers, and xray rendering remain pending.
The subscription route deliberately does not persist raw subscription tokens as
map keys; keep that property if a future SHA-256 token index replaces the MVP
full scan.

## Storage

The bootstrap build uses a JSON state file plus an append-only hash-chained
audit WAL. Reversible secrets are envelope-encrypted at the store persistence
boundary with AES-256-GCM; one-way password/token/recovery-code hashes remain
hashes. The server `internal/store` package is intentionally isolated so a
bbolt implementation can replace whole-file JSON rewrites without changing
handlers or agents while preserving the pure-Go / zero-CGo constraint.

The bbolt path currently supports full import/export, JSON migration, JSON
rollback export, and record-level APIs for nodes, KV, audit, static objects,
Worker scripts, plugin lifecycle records, approvals, tasks, task results,
monitors, monitor results, tunnels, users, tokens, sessions, TOTP challenges,
DDNS profiles, notification channels, OIDC providers, OIDC identities, and OIDC
auth states, plus proxy inbounds/users/node profiles/usage snapshots. Session
IDs, TOTP challenge IDs, and OIDC auth-state keys use
opaque SHA-256 storage keys when encryption is enabled. Server startup still
uses the JSON store by default. Runtime cutover is blocked on backup/restore
drills, audit WAL anchoring, and an explicit operator opt-in.
