# Iteration 046 — Proxy Usage Reporting Baseline

- **Status:** Implemented and verified (2026-06-14)
- **Design:** [`designs/design-01-proxy-cores-and-subscriptions.md`](../designs/design-01-proxy-cores-and-subscriptions.md)
- **Builds on:** [`iter-045-proxy-dashboard-token-workflow.md`](./iter-045-proxy-dashboard-token-workflow.md)
- **Repos:** `lattice-server`, `lattice-node-agent`, `lattice-dashboard`, `lattice`

## Goal

Close the first accounting gap in the proxy-core product path: nodes can report
per-user cumulative traffic counters, the server rolls them forward
monotonically into central `ProxyUser.UsedBytes` / `Status`, and the dashboard
shows usage, last-seen, and per-node snapshot freshness without exposing any
proxy credentials.

This is intentionally a **baseline accounting slice**, not the final sing-box
stats collector. It defines the stable server contract and low-trust rollup
rules first, then leaves the direct core-specific collectors for later.

## Scope Delivered

- Server route `POST /api/agent/proxy-usage`.
  - Authenticates with the existing node-token `Authorization: Bearer` path.
  - Rejects body-token auth through the existing agent credential hardening
    tests.
  - Forces the snapshot `node_id` from the authenticated request instead of
    trusting the nested payload.
  - Requires the reporting node to have a `ProxyNodeProfile`.
  - Filters reported users to the users eligible for that node profile; unknown
    or ineligible user ids are ignored and not persisted in the stored snapshot.
  - Rejects malformed user ids, negative counters, and oversized user maps.
  - Serializes usage apply with a server-side mutex so the read-diff-update
    sequence cannot double-count concurrent reports.
  - Records `proxy.usage.report` audit events with only aggregate deltas/counts.

- Server route `GET /api/proxy/usage`.
  - Requires `proxy:read`.
  - Returns secret-free per-node snapshots and per-user usage views.
  - Includes only `used_bytes`, `traffic_limit_bytes`, `last_seen_at`, and
    derived `status`; it does not serialize UUID, password, subscription token,
    REALITY private key, or rendered config.

- Server monotonic rollup semantics.
  - First snapshot is a baseline only: it marks seen users and stores the
    counter state, but does **not** import historical bytes.
  - Later snapshots add `current - previous` when counters increase.
  - If `core_uptime_sec` decreases, the core is treated as restarted and the
    current counter is counted as post-reset traffic.
  - If a counter decreases without an uptime reset, the new value becomes the
    baseline but no bytes are added.
  - Over-quota/expired/disabled state reuses the existing derived
    `ProxyUser.Status` logic used by subscription output.

- Agent bridge `-proxy-usage-file` / `LATTICE_PROXY_USAGE_FILE`.
  - Reads a local JSON `ProxyUsageSnapshot` each loop and posts it to
    `/api/agent/proxy-usage`.
  - Overrides `node_id` with the configured agent node id.
  - Defaults `at` when absent.
  - Rejects empty user ids, negative counters, and files over 1 MiB.
  - Leaves monotonic diffing, eligibility filtering, quota state, and audit to
    the server.

- Dashboard display.
  - Proxy users now show `used / limit (percent)` or `used` for unlimited users.
  - Usage badges warn at 80% and use the danger style at 100%.
  - User cards show `last_seen_at` when present.
  - Profile cards show last usage snapshot time and core uptime, or
    `usage not reported`.

## Out of Scope

- Direct sing-box Clash API / gRPC stats collection. **Partially advanced in
  iter-049:** the agent now has a loopback HTTP/V2Ray-stats collector
  foundation; true sing-box/xray API transport remains pending.
- Direct xray stats collection.
- Usage anomaly alerts, quota notification hooks, and scheduled over-quota
  enforcement.
- Richer subscription output formats (`sing-box` client JSON, Clash YAML,
  v2ray-style format negotiation). **sing-box JSON and Clash/Mihomo YAML were
  resolved in iter-047 for VLESS+REALITY+TCP; v2ray-style negotiation remains
  future work.**
- A focused proxy plan/apply dashboard. **Resolved in iter-048:** pending
  `proxycore/apply-config` reviews now render in the Proxy Core panel.

## Security Decisions

- **Node reports are low-trust.** A compromised node can inflate or suppress
  usage for users assigned to that node. The server limits blast radius by
  accepting only eligible users for the node's profile and by ignoring unknown
  users, but quota counters are still advisory/soft-gating data.
- **No raw credentials in the accounting path.** Usage APIs expose counters and
  status only. Subscription tokens, UUIDs, passwords, and REALITY private keys
  remain encrypted at rest and absent from list/read views.
- **First snapshot is baseline-only.** This avoids counting historical traffic
  when the feature is enabled on an already-running node.
- **Monotonic by construction.** Counter decreases do not subtract traffic;
  uptime decreases are the explicit reset signal.
- **Agent file bridge is bounded.** The interim collector interface is local and
  size-limited; it is a compatibility seam for sidecar collectors, not an
  unbounded log/metrics ingestion path.

## Verification

Run from the workspace with `GOWORK` pointing at `lattice/go.work`.

```sh
GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache \
go test -count=1 ./...
```

Result in `lattice-server`: pass across all packages. Existing DDNS/notify/OIDC
tests were also made robust in restricted sandboxes by using explicit
`127.0.0.1` listeners and skipping when local bind is unavailable instead of
panicking through `httptest.NewServer`.

```sh
GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache \
go test -race -count=1 ./internal/server \
  -run 'TestProxyUsage|TestAgentPostEndpointsRejectBodyTokenWithoutBearer'
```

Result: pass. This specifically covers the new usage apply path and the
agent-token rejection regression guard under the race detector.

```sh
GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache \
go test -count=1 ./...
```

Result in `lattice-node-agent`: pass across `cmd/lattice-agent`,
`internal/hostfacts`, `internal/metrics`, `internal/prober`,
`internal/proxyusage`, `internal/sshwatch`, and `internal/taskexec`.

```sh
node --test assets/*.test.mjs
node --check assets/app.js
node --check assets/proxy.js
```

Result in `lattice-dashboard`: 74 tests pass; syntax checks pass.

```sh
GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache \
GOPROXY=off \
go build -o /private/tmp/lattice-server-iter046 ./cmd/lattice-server

GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache \
GOPROXY=off \
go build -o /private/tmp/lattice-agent-iter046 ./cmd/lattice-agent
```

Result: both builds exit 0. The Go tool printed non-fatal stat-cache warnings
because this sandbox cannot write the user-level module cache under
`/Users/cdcd/go/pkg/mod/cache`.

## Review Outcome

Manual security/code review focused on the new trust boundary:

- **Fixed before landing:** usage apply now has a dedicated mutex; without it,
  concurrent reports for the same node could race between previous-snapshot
  read and snapshot write and double-count deltas.
- **Fixed before landing:** the agent file bridge now rejects files over 1 MiB,
  preventing local misconfiguration from turning the bridge into an unbounded
  memory input.
- **Fixed before landing:** existing server tests that use local `httptest`
  listeners now skip cleanly when this sandbox forbids binding instead of
  panicking, so `go test ./...` can be used as completion evidence.
- **Accepted residual:** true direct core API transport is deliberately deferred
  until a specific supported sing-box/xray stats interface is pinned and tested.
  Iter-049 landed the stdlib-only loopback HTTP/V2Ray-stats collector
  foundation behind the same server ingest contract.
  The current file bridge lets a sidecar collector integrate without freezing
  Lattice to an uncertain core API shape.

## Residuals & Next

1. Iter-049 added a loopback HTTP/V2Ray-stats usage collector foundation behind
   the same `ProxyUsageSnapshot` contract. Add true sing-box/xray API transport
   after pinning the supported API/version behavior.
2. Add usage anomaly/over-quota notification hooks through `internal/notify`.
3. Add subscription import helpers and optional User-Agent/v2ray-style format
   negotiation. The first richer formats landed in iter-047 using a fixed-shape
   dependency-free YAML emitter.
4. Focused proxy plan/apply dashboard landed in iter-048.
5. Add xray renderer and xray usage collector behind the same core abstraction.
