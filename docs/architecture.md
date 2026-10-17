# Lattice Architecture

Lattice is split into separately deployable projects:

- `lattice-server` - control plane.
- `lattice-node-agent` - node-side daemon.
- `lattice-dashboard` - Vue static frontend.
- `lattice-sdk` - shared protocol/domain model package.
- `lattice-plugin-template` - starter extension templates.
- `Astra` - iOS companion app for mobile-first fleet operations.

## Control Plane

`lattice-server` owns identity, node enrollment, task scheduling, KV/static data,
Worker registration, network approvals, and audit events.

The server exposes JSON HTTP APIs in this bootstrap build. The API boundary is
kept narrow so it can move to protobuf/ConnectRPC later without changing domain
packages. The dashboard lives in `lattice-dashboard`; build it with `pnpm build`
and serve `dist/` through `lattice-server -web ../lattice-dashboard/dist` or an
independent static host.

## Mobile Companion

`Astra` is the Lattice iOS companion app. The Xcode project and scheme keep the
historical `Astra` name, while the installed app presents as `Lattice`.

The v2 app turns the old read-only node monitor into a phone-first operator
surface:

- Overview, Nodes, Monitors, Inventory, and More tabs.
- `Sources/AstraCore/LatticeModels.swift` mirrors server and SDK response
  shapes for mobile-safe operations.
- `Sources/AstraCore/LatticeAPI.swift` provides a typed `LatticeClient` for
  identity/version, nodes, PATs, machine inventory, monitors/results,
  notifications, audit, tasks, and logs.
- `Sources/AstraCore/LatticeAnalytics.swift` derives fleet health, metric
  history, inventory cost/renewal summaries, monitor uptime, and formatting.

Astra is intentionally not a full dashboard replacement. Heavy mutation planes
such as NetPolicy, proxy core apply, DNS, storage, plugins, OIDC provider
admin, and 2FA enrollment remain in the Web dashboard until their mobile
review and rollback flows are designed.

## Node Agent

`lattice-agent`'s control channel only dials out, and the agent needs no
inbound port on leaf nodes. The one inbound socket it may open is the
measurement beacon (see [Monitoring](#monitoring)): off by default, opened on a
node only while an approved `node.beacon` plan enables it, and refused by an
agent started with `-no-beacon`.

Agent responsibilities:

- Authenticate with a per-node enrollment token.
- Send heartbeat and host metrics.
- Poll for bounded tasks.
- Execute tasks only when started with `-allow-exec=true`.
- Return stdout/stderr/exit code with output caps.
- Print its build version with `-version`, used by server-controlled update
  smoke checks.

## Agent Lifecycle Updates

The server owns `AgentUpdatePolicy` records for node-agent updates. A policy
pins the exact target version, HTTPS artifact URL, SHA-256 digest, install path,
and service name. Manual updates and auto-plan updates both create a pending
`agentupdate` approval; neither mode mutates a node without operator approval
and `plan_sha256` binding.

When approved with `queue_apply`, the node runs a bounded update script through
the existing task executor. The script downloads over HTTPS, verifies the digest,
runs the candidate with `-version`, backs up the current binary, atomically
replaces it, then schedules a delayed service restart so the current agent can
post the task result before being stopped.

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

`agentupdate` approvals are treated as high-risk host mutations and require the
same plan hash binding as nft, self-host DNS, and proxy-core apply.

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

Two of the event sources that drive alerts, fanned out to every enabled channel:

- **Monitoring paths.** Unless its alert policy is `off` (the path set's
  default), a path that fails its check's `alert_after` runs in a row opens a
  `monitor.down` incident, and its next success sends `monitor.recovered` if
  the open went out; a path judged degraded opens `path.degraded` under the
  `down_and_degraded` policy. Incidents, not single results, send messages, so a
  flapping target does not page on every run. The rules are in
  [Monitoring](#monitoring).
- **SSH logins.** Agents started with `-ssh-alerts` stream sshd accepted-login
  lines from journald (or `auth.log`) and report them to `/api/agent/event`; the
  server records an `ssh.login` audit event and notifies.

Channel management (`/api/notify/channels` and its delete, test and
deliveries routes) requires `notify:admin`; sending a test notification
(`/api/notify/test`) requires `notify:send`.

## Monitoring

Monitoring measures paths. A check (`model.Monitor`) has one method, one
target, one or more sources, its expectations, an interval and an alert
policy. Each (check, source) pair is a path, and the hot store keys every
row, rollup, latest record and degraded record by that pair. Operators create
checks one by one, and the path set (`model.LatencyProbeConfig`) is one rule,
sources times targets, that the control plane expands into generated checks.
Design 29 (`designs/design-29-monitoring-paths.md`) holds the reasoning and
the wire contracts; the operator's guide to the console is
[`tutorials/monitoring.md`](./tutorials/monitoring.md). This section
describes the code.

### Methods

| Kind | Runs on | Measures |
|---|---|---|
| `tcp` | agent | time to connect to `host:port` |
| `http` | agent | a GET judged against a status set (default `200-399`); redirects are never followed, so a 3xx is the answer, and the body is closed unread |
| `icmp` | agent | unprivileged datagram echo (`udp4` ICMP sockets, no `CAP_NET_RAW`): 1 to 10 echoes 200 ms apart, default 5, each with a 32-byte payload carrying 16 random bytes; a reply counts only when its payload and source address match |
| `beacon` | agent | signed UDP requests to a node's measurement beacon (below), 1 to 10 per run, default 5 |
| `tls` | control plane | certificate expiry; its path's source is the control plane, an empty node id |

A multi-packet run (icmp, beacon) reports `sent`, `lost` and the RTT of each
reply, and its latency is the median RTT. Every check runs at most every
10 s (operator checks default to 30 s, the path set to 60 s); the timeout is
1 to 60 s (1 to 30 s for the path set) and shorter than the interval; a
multi-packet run, (packets minus 1) times 200 ms plus the timeout, must end
before the next one starts; and a save is refused when, per source and
resolved target, the enabled checks of one kind, generated ones included,
would send more than 2 packets a second. The target is an address for icmp
and the endpoint `address:port` for beacon, so the two budgets to one node
are counted apart, and the planner's re-plans are not judged again.

Each agent reports the kinds it runs (`probe_methods`) and the kinds its host
refuses (`probe_refusals`, for example `icmp_not_permitted` when
`net.ipv4.ping_group_range` excludes the agent's group) on every hello and
heartbeat. An agent that reports neither predates them and runs exactly tcp
and http. The control plane hands a source only the kinds it runs, and an
http check with headers or a non-default status set only to an agent that
reports `probe_methods` at all. A path whose source cannot run its kind reads
unknown with `agent_too_old` or the refusal's code, never down.

**Targets.** icmp, tcp and beacon checks may name a node in `target_node`
(beacon must). The control plane resolves it each time it hands the check to
an agent: icmp to the node's public IPv4, tcp to a public TCP line port the
node already serves (never port 22, an sshd port, the SSH Guard port or a
knock-gated port), beacon to the endpoint the node's applied beacon plan
advertises. A moved address or a new line therefore follows without an edit,
and a check that no longer resolves is left out of the agent's list while its
paths read `not_probeable` (`beacon_not_enabled` for an operator beacon
check). A literal target must be public: a save refuses
loopback, link-local, metadata, multicast, private, carrier-grade NAT,
unspecified and broadcast ranges, `localhost`, and host names whose last
label is a number. Each agent resolves a target once, judges every address by
the same SDK rule (`model.MonitorDestinationRefused`), dials only addresses it
judged and uses no proxy from the environment; a refused run reports
`destination_refused`. It skips that judgment only for tcp and icmp targets
the control plane resolved from a node; a beacon endpoint is judged by the
beacon's own endpoint rule instead (an IPv4 literal and port, never
0.0.0.0/8, loopback, link-local, multicast or 240.0.0.0/4).

**HTTP headers.** An http check carries up to 8 request headers. A secret
header requires https; its value is encrypted at rest with the store's other
reversible secrets when the store's encryption key is configured, is returned
by no read (reads carry the name with `secret` and `set`), is never written to
an audit record, and goes only to the check's assigned agents. Secrets are
bound to the origin they were saved for (`secrets_origin`), and an agent
sends them only on a request to exactly that origin over https. A check's
target cannot change on edit, so a new URL is a new check that starts without
secrets. An edit names each header as `keep`, `set` or `delete`, so an editor
that echoes a read neither wipes nor leaks a value. Error text is stored
without URL user info, query or fragment.

**Agents and results.** Each cycle (the agent's `-interval`, 10 s by default)
an agent pulls `/api/agent/monitors`, runs one goroutine per check, holds
results in an in-memory queue of 2000 and posts them in batches to
`/api/agent/monitor-results`. The server decodes a batch entry by entry,
stores what passes and lists the rest in `dropped` with a reason
(`invalid`, `wrong_node`, `not_assigned`, `out_of_window` and others) instead
of refusing the batch. It refuses a result for a check not assigned to the
posting node or from a paused source, and one stamped more than 24 hours ago
or more than a minute ahead. A result with a `reason` (the run could not
measure the path, for example `agent_too_old`) is stored and becomes the
path's latest, but counts as neither success nor failure.

### The path set and generated checks

The path set names its sources, its targets (by default every node whose
country is set and is not `CN`, adjusted by include and exclude lists), its
disabled pairs, a method with per-source pins, an interval, a timeout, an
alert policy and degraded thresholds. Until the first save the source is the
node whose id or name is `cd-hs-sh`; a saved path set names sources by id. It
is read at `GET /api/monitors/latency` and saved whole at
`PUT /api/monitors/latency` (`monitor:admin` with no node allowlist, the
`version` it was read at, audited as `monitor.latency.config`).

A planner runs every two minutes and after each save. It keeps one generated
check per target and kind, `mon_lat_<target>` (tcp), `mon_lati_<target>`
(icmp) and `mon_latb_<target>` (beacon), each assigned the sources that use
that kind for that target. The `auto` method picks, per source and target,
the beacon when the target's applied plan approved this source, the target's
agent reports listening on the planned address and the source runs the
beacon client; else icmp when the source runs it, the target has a public
IPv4, and the pair's newest icmp result is not an `icmp_filtered` verdict
younger than a day; else tcp to a line port; else icmp even where it reads
filtered, when the target has no TCP line. A pinned method never falls back.
A generated check that no source uses stays, paused, with its history.
Generated checks are deleted only with their target node, answer edits and
deletes with 409, and are paused per pair through the disabled pairs. The
series of a path addressed by (source, target node) joins the three ids by
time and marks each switch in `method_changes`, so a method switch does not
break the chart.

### The measurement beacon

The beacon is the one inbound socket an agent may open (doctrine in
`PRODUCT-VISION.md`): a UDP responder that answers only requests signed for
it. The wire format lives in the SDK's `beacon` package, which the server,
the agents and their tests import.

**Responder.** A request is exactly 96 bytes and a reply exactly 64, so a
reply is never larger than its request. The responder drops, before any HMAC
is computed, a datagram of any other length, with the wrong magic, version or
padding, from an unknown source id or for an epoch it does not hold; it then
drops a request whose truncated HMAC-SHA256 tag does not verify (compared in
constant time) and a replayed nonce. A request whose tag verified but that it
refuses gets a signed status, at most one a second per source: `stale` when
the timestamp is more than 60 s from the responder's clock or older than its
start, `unknown_epoch` for a retired key, `rate_limited` above 20 requests a
second from that source or with that source's nonce cache full. Nothing
unsigned ever draws a reply, so an open beacon port reads open-or-filtered to
a scanner. Around that handler the agent binds exactly the planned IPv4
address and port (never the wildcard), reads into a 128-byte buffer, counts
datagrams before authentication in a fixed-size array rather than a map keyed
by sender, recovers from a panic per datagram, and opens a circuit breaker
(state `circuit_open`, five minutes closed) when a flood has filled nearly
every second of the last minute.

**Keys.** The server mints a 32-byte key per target node when a plan first
enables its beacon, keeps it with the store's reversible secrets (encrypted at
rest when the store's encryption key is configured), deletes it when a plan
disables the beacon, and sends it to no node. For each approved source and
epoch it derives a path key with HMAC-SHA256 from the target key, the
source's server-assigned id and the epoch (`beacon.DerivePathKey`). Through
`GET /api/agent/config` (`beacon`) a target receives the table of path keys
it accepts and a source receives only its own path key per target it probes
by beacon. Nodes hold them in memory only. A rotation moves a target to a
new epoch: on `POST /api/nodes/beacon/rotate` (`monitor:admin` and
`node:admin`, audited as `beacon.rotate`), at the decision of a change plan
that drops a previously approved source, and at the target's next
configuration pull
after any other source leaves its table. Sources switch 20 s after the target
first pulls the new table; the old epoch is accepted for two minutes after
that pull and then answers only `unknown_epoch` for ten more.

**Plans.** Enabling, changing and disabling a beacon are `node.beacon` plans,
filed with `POST /api/nodes/beacon/plan` and decided in Approvals like other
plans. The approval's plan document covers the resulting and previous
settings (port, bind address, advertised endpoint, limits), the source set
with each source's id and, under NetGuard, the /32s it may come from, the
exposure (`netguard` or `internet`), the NetGuard companion with the node's
whole ruleset and its SHA-256, and the base version. At the decision the
server renders the document again from live state and refuses it as stale
when the bytes differ or another beacon plan applied since; the lint runs
again too. The port defaults to a random one in 40000 to 59999 assigned once
per node, and an operator may choose 1024 to 65535. The bind address defaults
to the node's primary interface address (its private address on a NAT node),
else its public IPv4. The advertised endpoint is an IPv4 literal and port,
by default the public IPv4 and the listen port, and may be a NAT mapping; it
must be one of the node's own addresses (public, interface, or a public line
endpoint the latency port rule accepted), and the server judges that again at
every render and every time it hands out a key or a check. Findings block a
port that a sing-box inbound, sshd (port 22 and the SSH Guard port
included), a knock sequence or WireGuard uses, and a bind on the WireGuard
address; they warn on a bind address that is not the node's, a mapped
endpoint, no sources yet, and a node NetGuard does not manage. Planning needs
`monitor:admin`, `node:admin` and `network:plan` on the node, `netguard:admin`
as well when NetGuard manages it, and `monitor:read` on every source;
deciding needs `network:apply` with the same scopes.

**NetGuard companion.** When NetGuard manages the target, the plan carries a
companion: an accept rule for UDP to the beacon port from exactly the
approved sources (each source's public and WireGuard /32, plus the global
IPv4 the server saw it connect from when that differs), and `notrack` chains
at raw priority for the bind address and port in both directions, so
datagrams to the beacon never fill the connection-tracking table that other
traffic on the node needs. Such a plan must be approved with `queue_apply`,
and until its apply task succeeds the beacon stays closed: the target
receives no responder, sources receive no keys and its paths read
`firewall_pending`. A failed apply leaves it closed. The companion stays in
the node's NetGuard compile input, so later NetGuard plans keep it. Without
NetGuard the port is open to the internet and protected only by the
responder's properties, which the node page says. Adding a source later opens
nothing by itself: the source reads `firewall_pending` (`beacon_source_pending`
without NetGuard) until a change plan that admits it is applied.

**Reachability and the veto.** After a plan that enables or changes a beacon
applies and the target reports `listening` on the planned address and port,
the server hands one approved, online source the generated check
`mon_beaconr_<target>` (three requests a minute) until a telling result,
stores the verdict (`reachable`, `not_listening`, `filtered` or `no_source`)
and retires the check. It is not a path and never pages. An agent started
with `-no-beacon`, or with `LATTICE_NO_BEACON` in its environment set to any
value but empty, `0`, `false`, `no` or `off` (the installer writes `0`),
fixes the veto at start, checks it before any bind, reports
`refused_by_node` and never listens, whatever the server configures; its own
beacon checks against other nodes still run, since the client only sends.
`GET /api/nodes/beacon?node_id=` returns the beacon's state, applied
settings, epoch, last authenticated request, the agent's report, the
reachability verdict, the exposure and each source. No read and no audit
record carries a key.

### History and retention

With the hot store (`state-hot.db`, bbolt) results live in four buckets:
raw rows (`monitor_result_rows`), one latest record per pair
(`monitor_result_latest`), five-minute rollups (`monitor_rollup_fine`) and
hourly rollups (`monitor_rollup_coarse`); degraded records have a fifth
(`monitor_path_degraded`).

| Tier | Resolution | Kept |
|---|---|---|
| Raw rows | every run | 1440 per path, none older than the hourly tier |
| Fine rollups | 5 minutes | `fine_retention_days`: 3 to 14, default 7 |
| Coarse rollups | 1 hour | 35 days |

A rollup bucket holds runs, failures, min, max, a latency histogram (eight
bins per doubling) from which p50 and p95 are read, the sum and count of the
differences between consecutive successful runs (jitter), and probes sent and
lost. Loss is lost over sent, counting every echo or request of a
multi-packet run and one probe per tcp or http run, and failures over runs in
buckets written before probes were counted. A multi-packet run counts once
in runs and enters the histogram with its median RTT.

The pruning sweep runs at start, every hour, and at once when retention is
lowered. For every pair, paused ones included, it deletes the buckets and
rows behind each tier's line (each tier keeps an hour of slack) in write
transactions of at most 2000 deletes, outside the store lock. bbolt reuses
freed pages but never shrinks its file. `GET /api/monitors/settings`
(`monitor:read` with no node allowlist, since its figures cover the fleet)
returns the setting with its bounds, the fixed tiers, the
paths recording history, the bytes the monitor buckets use now (bbolt page
statistics) and the bytes they would use at the current setting;
`POST /api/monitors/settings/update` (`monitor:admin` with no node allowlist,
the `version` it was read at, audited as `monitor.settings.update`) saves it.
Without the hot store (the JSON fallback, which is not production) a pair
keeps 120 raw rows, reads fold them instead of stored rollups, and degraded
records live in memory.

### Reads

- `GET /api/monitors/paths?window=` is the matrix. Windows are `1h`, `6h`,
  `24h`, `3d`, `7d` and `14d`; `1h` reads raw rows, `6h` and `24h` fine
  rollups, `3d` and longer hourly rollups. Each window's figures are cached
  until its tier's next bucket closes, and states are judged on every read.
  Per path it carries the state and reason, method, check id, p50, p95,
  jitter, loss, samples beside expected, the same window one period earlier
  (`prev`, its p50 and loss), the newest run's stamp and, for a degraded
  path, the evidence; `degraded_at` says when the evaluator last ran.
- `GET /api/monitors/series` returns one path's buckets, addressed by
  `source` and `target_node` (generated paths, joined across methods) or by
  `monitor` and `source`. The step is the smallest multiple of the covering
  tier's resolution that keeps the series within 720 points and is no
  shorter than the check's interval: one minute for `1h`, five for `6h` and
  `24h`, ten for `3d`, fifteen for `7d`, and thirty for `14d` when fine retention is
  14 days. A window longer than fine retention, or a fine tier still filling,
  reads hourly buckets. Every step is present, and a gap has `n` 0 with
  `expected` above 0. `baseline` carries the degraded rule's 7-day figures
  and triggers, and `compare=previous` adds the p50 of the window one span
  earlier, aligned to the buckets.
- The older `GET /api/monitors/latency/rollups` and
  `GET /api/monitors/latency/series` remain, with their own shapes and the
  `1h`, `24h` and `7d` windows; the console falls back to them only on a
  server that predates the paths routes.

Every history read runs in a bolt read transaction outside the store lock,
so a 7-day matrix cannot stall ingest. A path is visible only to a caller
with `monitor:read` on its source and its target node (and on the check, for
an operator's check).

### States

A path is `up`, `degraded`, `down` or `unknown`; a paused path is unknown
with `source_paused`. The server judges in this order: the target does not
resolve (`not_probeable`); the method's gate (`agent_too_old`, the agent's
refusal, or a beacon reason such as `beacon_not_enabled`, `firewall_pending`
or `refused_by_node`); the source is paused; there is no check (`no_data`);
the source's agent is missing, disabled or offline (`agent_offline`); there
is no result (`no_data`); the newest outcome is older than three intervals or two
minutes, whichever is longer (`no_data`); the newest result carries a
reason; an icmp or beacon path that has never had a reply and whose newest
run lost everything (`icmp_filtered`, `beacon_filtered`); the source's last
`alert_after` runs all failed (default 2; the path set's for generated
checks), which reads `down` whatever the alert policy; otherwise
`up`, shown as `degraded` while the evaluator holds a degraded or clearing
record. Down and unknown always win over degraded.

**Degraded.** An evaluator runs every minute on a server ticker, never on a
console read, starting one minute after start. It judges every enabled tcp,
http, icmp and beacon path whose source is assigned, not paused, runs the
kind, and whose target resolves; tls is never judged. The baseline is the
hourly buckets of the seven days before the current hour, and a path is
judged only once at least 24 of them hold a countable run. The loss arm
holds when the last hour has at least 30 probes and its loss is strictly
above both `loss_percent` / 100 and `loss_factor` times the 7-day loss; the
latency arm holds when the last 15 minutes have at least 5 successful runs
and their p50 is strictly above both `latency_factor` times the 7-day p50 and
the 7-day p50 plus `latency_margin_ms`. Defaults are 2 percent, 2, 2 and
30 ms; bounds are 0.5 to 50, 1.2 to 10, 1.2 to 10 and 5 to 1000. A path
enters degraded on the second consecutive evaluation that finds either arm
and leaves once the condition has been absent for ten minutes (`degraded_loss`,
`degraded_latency` or `degraded_loss_latency` names the arms). Operator
checks carry their own thresholds (`degraded`); generated checks read the
path set's. State is judged on the check a path uses now, so a method switch
starts a new 24-hour gate. Records are written only at transitions, so a
restart keeps `since` and a clearing path's clock, and a pending record is
not written. The baseline follows the path: a degradation that lasts for days
slowly becomes its own baseline.

### Alerts

`alert` is `off`, `down` or `down_and_degraded`; empty reads as `down` on an
operator check and as `off` on the path set and its generated checks, so a
path set pages nothing until an operator sets a policy. `alert_after` is 1 to
20, default 2. Under `down` or `down_and_degraded` a path opens `monitor.down`
on its `alert_after`-th failure in a row and its next success sends
`monitor.recovered`, but only if the open was sent. Under
`down_and_degraded` a path whose degraded record entered while the path read
up opens `path.degraded`, and the record's end sends `path.recovered`; a
record that entered while the path read down or unknown stays quiet for its
whole episode, so the loss an outage leaves behind does not page twice.
Results that measure nothing, icmp and beacon paths that have never had a
reply, and beacon reachability checks never page. The incident machinery
keeps one incident per key, counts a reopening within 30 minutes as a flap
and sends at most one message an hour from the third flap, joins opens that
fall due together into one message, holds these warning-severity messages
through quiet hours, and never escalates them. An incident closes without
reporting a recovery when its check is disabled, its source is unassigned or
paused, the policy stops paging degraded, or the evaluator drops the record;
if its open was sent, a closing notice that says why ("Path paused: ...",
"Degraded alerts off for ...") goes out in place of the recovery.

| Type | Category | Severity | Recovery | Icon |
|---|---|---|---|---|
| `monitor.down` | `monitors` | `warning` | no | `activity` |
| `monitor.recovered` | `monitors` | `info` | yes | `heart-pulse` |
| `path.degraded` | `monitors` | `warning` | no | `trending-down` |
| `path.recovered` | `monitors` | `info` | yes | `trending-up` |

### Checks API and scopes

`POST /api/monitors` creates a check (`monitor:admin`, admin on every source,
and `monitor:read` on `target_node`; audited as `monitor.create`). A new
check is enabled at version 1. `POST /api/monitors/update` edits one with the
`version` it was read at (409 when stale) and changes only the fields it
sends: name, interval, timeout, packets, status set, headers, tls threshold,
alert policy, `alert_after`, degraded thresholds, enabled, sources and paused
sources. Changing the kind, the target or `target_node` answers 400, because
that is a new check; the console then creates the new check and pauses the
old one, so one series never mixes two methods. A paused source keeps its
history, is not handed the check, and has its results refused. Edits are
audited as `monitor.update` with the fields that changed. `GET /api/monitors`
lists checks with each assigned source's newest result, and
`GET /api/monitors/results` returns raw results (500 by default, at most
2000). These reads need `monitor:read` and are narrowed to what the caller
may see; the settings read and the path set save refuse a token with a node
allowlist instead.

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
iter-046 usage-reporting baseline, the iter-047 subscription-format slice, the
iter-048 focused dashboard apply-review slice, the iter-049 loopback
HTTP/V2Ray-stats collector foundation, the iter-050 proxy notification slice,
the iter-051 subscription import-helper slice, the iter-052 collector-health
slice, the iter-053 xray renderer/apply slice, the iter-054 dependency-free
xray stats transport (`xray api statsquery` per ADR-003), and the iter-055
config-drift detection slice (scheduler-computed `config_stale` signal +
one-click Review & Apply; plan→approve→apply preserved, no auto-apply):

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
  refresh. After an explicit token rotation, it derives copy-ready base64,
  plain, sing-box JSON, and Clash.Meta/Mihomo import URLs by changing only the
  public `format` query parameter. It does not add an existing-token reveal API
  or auto-open bearer links.
- `POST /api/agent/proxy-usage` lets an authenticated node report a
  `ProxyUsageSnapshot`. The server forces the node id from the authenticated
  request, filters counters to users eligible for that node profile, rejects
  malformed/negative input, applies deltas under a dedicated mutex, and audits
  aggregate counts only.
- `GET /api/proxy/usage` returns secret-free per-node snapshots and per-user
  usage views for the dashboard. The first report is baseline-only; later
  reports advance `ProxyUser.UsedBytes` monotonically, treat `core_uptime_sec`
  decreases as resets, and never subtract usage on counter rollback.
- Quota/expiry notifications are server-owned. `ProxyUser` carries
  server-managed notification cursors for quota and expiry; clients cannot set
  them. The server emits audited `proxy.user.notify` events through
  `internal/notify` when usage crosses 80%/100% of `traffic_limit_bytes`, or
  when `expires_at` reaches 7d/1d/expired thresholds. The existing hourly
  reminder scheduler also evaluates proxy users, so expiry alerts do not depend
  on a fresh node usage report.
- `lattice-node-agent` supports three mutually-exclusive usage sources:
  `-proxy-usage-file` / `LATTICE_PROXY_USAGE_FILE` (bounded JSON snapshot bridge),
  `-proxy-usage-url` / `LATTICE_PROXY_USAGE_URL` (loopback-only HTTP JSON source),
  and `-proxy-usage-xray-api` / `LATTICE_PROXY_USAGE_XRAY_API` (runs the on-node
  `xray api statsquery` against a loopback API address per ADR-003 — no
  `grpc-go`; sing-box's own HTTP API is consumed via the URL source). The URL and
  xray sources accept direct `ProxyUsageSnapshot`, `{"snapshot": ...}`, or
  V2Ray-style `user>>>...>>>traffic>>>uplink/downlink` stats, reject remote/
  non-loopback hosts, cap output, refuse HTTP redirects, and post the same
  normalized snapshot to `/api/agent/proxy-usage`.
- Proxy usage collector health is surfaced through the same authenticated agent
  route. Successful reports set `collector_status=ok`; local file/HTTP
  collector failures post health-only `collector_status=error` snapshots. The
  server stores bounded health metadata on `ProxyNodeProfile`, exposes it in
  profile views, and deliberately does not create or overwrite an accounting
  baseline for health-only error reports.
- Xray now shares the same typed proxy model for the VLESS+REALITY+TCP MVP.
  The server renders dependency-free xray JSON, redacts `privateKey` and VLESS
  client `id` in review plans, binds the real artifact SHA-256 to approval, and
  queues an apply script that runs `xray test -c "$CANDIDATE"` before atomic
  swap and service reload/restart. Profiles and inbounds must use the same
  core, so a mixed sing-box/xray profile fails before plan/apply.

True sing-box/xray API transports (for example direct V2Ray stats gRPC),
optional xray install/version pinning, and live over-quota/expiry reconcile
enforcement remain pending.
The subscription route deliberately does not persist raw subscription tokens as
map keys; keep that property if a future SHA-256 token index replaces the MVP
full scan.

## Storage

The bootstrap build uses a JSON state file plus an append-only hash-chained
audit WAL and local sidecar head anchor. Reversible secrets are
envelope-encrypted at the store persistence boundary with AES-256-GCM; one-way
password/token/recovery-code hashes remain hashes. The server `internal/store`
package is intentionally isolated so a bbolt implementation can replace
whole-file JSON rewrites without changing handlers or agents while preserving
the pure-Go / zero-CGo constraint.

The bbolt path currently supports full import/export, JSON migration, JSON
rollback export, and record-level APIs for nodes, KV, audit, static objects,
Worker scripts, plugin lifecycle records, approvals, tasks, task results,
monitors, monitor results, tunnels, users, tokens, sessions, TOTP challenges,
DDNS profiles, notification channels, OIDC providers, OIDC identities, and OIDC
auth states, plus proxy inbounds/users/node profiles/usage snapshots. Session
IDs, TOTP challenge IDs, and OIDC auth-state keys use
opaque SHA-256 storage keys when encryption is enabled. Server startup still
uses the JSON store by default. Runtime cutover is blocked on backup/restore
drills, remote audit-head shipping/retention, and an explicit operator opt-in.
