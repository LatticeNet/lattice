# Iteration 050 - Proxy Usage and Expiry Notifications

- **Date:** 2026-06-14
- **Repos:** `lattice-sdk`, `lattice-server`, `lattice`
- **Builds on:** iter-046 proxy usage rollup, iter-049 loopback HTTP collector
- **Status:** Implemented, reviewed, verified

## Goal

Turn proxy accounting into actionable operator alerts without trusting the node
to decide policy. Quota and expiry notifications must be server-owned,
de-duplicated, auditable, and delivered through the existing `internal/notify`
fan-out.

## Scope

- Add server-managed notification cursors to `model.ProxyUser`:
  - `last_quota_notified_key`
  - `last_expiry_notified_key`
- Reject client attempts to set those cursors through `/api/proxy/users`.
- Emit quota alerts when server-side monotonic usage crosses:
  - 80% of `traffic_limit_bytes`
  - 100% / over-quota
- Emit expiry alerts when a user is:
  - within 7 days of `expires_at`
  - within 1 day of `expires_at`
  - expired
- Use the existing reminder scheduler as a coarse hourly backstop so expiry
  alerts do not depend on a fresh node usage report.
- Record `proxy.user.notify` audit events with kind/key metadata.
- Keep notifications out of agent authority: agents still only report
  cumulative counters.

## Security Decisions

- **Server-owned thresholding.** The node reports cumulative counters, but the
  server performs eligibility filtering, monotonic diffing, status derivation,
  threshold checks, cursor persistence, audit, and notify.
- **Persistent de-duplication.** Notification cursors live on `ProxyUser`, so a
  server restart does not resend the same quota/expiry alert.
- **Client cursors rejected.** API clients cannot pre-mark notifications as
  sent or force cursor rewinds.
- **No new delivery path.** Alerts reuse `internal/notify` and the existing
  enabled channel set; no proxy-specific webhook config or dependency was
  introduced.
- **No hard enforcement change.** This slice alerts only. Over-quota/expired
  users are already omitted from newly rendered subscriptions/configs according
  to existing server-side status, but live data-plane disable/re-apply remains a
  later reconcile/enforcement slice.

## Verification

From `lattice-server`:

```sh
GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache-server \
go test ./internal/server ./internal/store ./cmd/lattice-server

GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache-server \
go test ./...

GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache-server \
go test -race ./internal/server -run 'TestProxy(UsageNotifications|ExpiryNotifications|UserRejects|UsageReport)' -count=1
```

From `lattice-sdk`:

```sh
GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache-sdk \
go test ./...
```

Result: focused proxy notification tests, server/store/cmd tests, full server
tests, SDK tests, and whitespace checks passed. The server race run covered the
new proxy notification tests and the existing proxy usage rollup test.

Focused tests cover:

- baseline usage reports do not send historical quota alerts;
- 80% quota alert fires once;
- 100% quota alert fires after the 80% alert and does not repeat;
- expiry alerts advance from 7d to 1d to expired and do not repeat;
- server-managed notification cursors are rejected from client JSON;
- audit records are emitted for proxy notifications.

## Residuals & Next

1. Add true sing-box/xray API transport after pinning the stats API and writing
   an ADR if `grpc-go` is introduced.
2. Add dashboard import-helper UX for `plain`, `base64`, `sing-box`, and
   `clash-meta`.
3. Surface collector health/error state in server/dashboard.
4. Add xray renderer and `xray test -c` apply path.
5. Add an auto-reconcile/apply policy so over-quota/expired users can be
   removed from live node configs without a manual re-apply.
6. Add notification delivery status if alerts need retry/ack semantics. This
   slice persists threshold cursors before asynchronous channel fan-out, which
   prevents repeated alert storms across restarts but does not replay a
   threshold if an enabled notification channel is temporarily failing.
