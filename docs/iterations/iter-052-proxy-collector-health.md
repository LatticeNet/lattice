# Iteration 052 - Proxy Collector Health Surfacing

- **Date:** 2026-06-14
- **Repos:** `lattice-sdk`, `lattice-node-agent`, `lattice-server`,
  `lattice-dashboard`, `lattice`
- **Builds on:** iter-046 usage rollup, iter-049 loopback HTTP collector,
  iter-051 dashboard subscription import helpers
- **Status:** Implemented, reviewed, verified

## Goal

Make proxy usage collection debuggable before adding true sing-box/xray API
transports. Operators should be able to see whether the local collector is
working, which source is being used (`file` or `http` today), when it was last
checked, and the latest error without trusting that error path for accounting.

## Scope

- Add agent-reported collector fields to `model.ProxyUsageSnapshot`:
  - `collector_source`;
  - `collector_status`;
  - `collector_error`;
  - `collector_checked_at`.
- Add server-persisted profile health fields to `model.ProxyNodeProfile`:
  - `usage_collector_source`;
  - `usage_collector_status`;
  - `usage_collector_checked_at`;
  - `usage_collector_last_ok_at`;
  - `usage_collector_last_error`;
  - `usage_collector_last_error_at`.
- Update `lattice-node-agent`:
  - successful file/HTTP collection marks snapshots as `collector_status=ok`;
  - failed local collection posts a health-only error snapshot to
    `/api/agent/proxy-usage`, then still returns the local error so node logs
    remain explicit.
- Update `lattice-server`:
  - validates collector source/status;
  - sanitizes and bounds collector errors;
  - persists health to `ProxyNodeProfile`;
  - rejects mixed `collector_status=error` + `user_bytes`;
  - does **not** create or overwrite the accounting baseline for health-only
    error reports.
- Update `lattice-dashboard`:
  - profile cards show `collector ok`, `collector error`, or `collector not
    reported`;
  - error text is escaped and rendered as status text, not policy.

## Security Decisions

- **Health is not accounting.** Error reports update profile health only. They
  do not call the monotonic diff path and do not mutate `ProxyUser.UsedBytes`.
- **Agent is still low-trust.** Collector status is visibility metadata. It is
  not used for authorization, quota, subscription eligibility, or apply policy.
- **Error text is bounded.** The server strips control characters and caps the
  stored error text so a noisy local collector cannot bloat API responses or
  audit payloads.
- **No new endpoint.** The existing authenticated agent proxy-usage route
  carries both usage snapshots and collector health, preserving the outbound-only
  agent model and current rate limiting.

## Verification

From `lattice-sdk`:

```sh
GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache-sdk \
go test ./...

GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache-sdk \
go vet ./...
```

From `lattice-node-agent`:

```sh
GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache-agent \
go test ./...

GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache-agent \
go vet ./...
```

From `lattice-server`:

```sh
GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache-server \
go test ./...

GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache-server \
go vet ./...
```

From `lattice-dashboard`:

```sh
npm test
npm run check
```

Diff hygiene:

```sh
git diff --check
```

Focused tests cover:

- agent success snapshots include collector health;
- agent local collector failures still post a health-only error report;
- server error health updates profile view but does not create an accounting
  baseline;
- first success after a health-only error remains a baseline-only usage report;
- dashboard collector labels distinguish `ok`, `error`, and unreported states.

## Residuals & Next

1. Add true sing-box/xray API transport after pinning the stats API and writing
   an ADR if `grpc-go` is introduced.
2. Add xray renderer and `xray test -c` apply path.
3. Add an auto-reconcile/apply policy so over-quota/expired users can be
   removed from live node configs without a manual re-apply.
4. Consider dashboard visual polish: collector freshness thresholds, filters,
   and grouped profile health summaries.
