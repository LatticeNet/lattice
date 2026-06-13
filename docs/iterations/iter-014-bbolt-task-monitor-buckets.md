# Iteration 014 - bbolt Task, Monitor, and Tunnel Buckets

- **Date:** 2026-06-13
- **Phase:** C1 storage foundation
- **Repos:** `lattice-server`, `lattice`
- **Status:** Verified medium-risk bucket record APIs / default store not switched

## Goal

Extend the bbolt record-level storage foundation from low-risk metadata buckets
into the next medium-risk/high-churn buckets: task lifecycle, task results,
monitor definitions, monitor result history, and Cloudflare Tunnel topology.

This moves Phase C closer to a real runtime cutover while keeping the current
encrypted JSON store as the default server store.

## Scope

- Add record-level task lifecycle APIs:
  - `CreateTask`
  - `Task`
  - `Tasks`
  - `LeaseTasks`
- Add task-result append/read APIs:
  - `AddTaskResult`
  - `Results`
- Add monitor definition/result APIs:
  - `UpsertMonitor`
  - `Monitor`
  - `Monitors`
  - `MonitorsForNode`
  - `DeleteMonitor`
  - `AddMonitorResult`
  - `MonitorResults`
  - `LastMonitorResultForNode`
- Add tunnel topology APIs:
  - `UpsertTunnel`
  - `Tunnel`
  - `Tunnels`
  - `DeleteTunnel`
- Preserve current JSON-store behavior where it is defined:
  - task creation stamps `CreatedAt` and defaults blank status to `queued`
  - task list is newest first
  - leased tasks are marked `leased`, stamped `StartedAt`, assigned a lease id,
    and written atomically with the returned lease view
  - task results append to history and move the task to `finished`/`failed`
  - monitor list is oldest first
  - node monitor assignment returns only enabled assigned monitors, sorted by id
  - monitor result history is capped at `maxMonitorResults`
  - deleting a monitor removes its result history
  - tunnels are timestamped and listed oldest first

## Non-Goals

- Do not switch `cmd/lattice-server` or `store.OpenWithCipher` to bbolt.
- Do not add secret-bearing per-record writes for users, tokens, sessions, TOTP,
  DDNS profiles, notification channels, OIDC providers, or OIDC auth states.
- Do not migrate or anchor the audit WAL into bbolt yet.
- Do not change agent/server handlers to call `BoltStateStore` at runtime.

## Security Notes

- Task scripts and task stdout/stderr are sensitive operational data. They are
  not reversible credentials, and the current JSON store already persists them
  as ordinary state, but this slice still treats them as medium-risk and does
  not expose the bbolt runtime path.
- `TunnelProfile` stores topology and the node-local credentials-file path. The
  tunnel credential material itself is intentionally node-local and is not moved
  through this bucket.
- Secret-bearing buckets remain blocked until field-specific encryption tests
  prove no plaintext secret leakage and wrong-key behavior fails closed.

## Verification Plan

- Unit tests in `lattice-server/internal/store/bolt_state_test.go`:
  - task create/list/lookup/lease/result lifecycle
  - task result ordering and persistence across reopen
  - monitor upsert/list/assignment/result cap/latest/delete behavior
  - tunnel upsert/list/delete behavior
  - record-level writes do not reset unrelated imported buckets
- Commands:

```sh
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go test ./internal/store -run TestBoltState -count=1
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go test ./internal/store -count=1
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go test ./... -count=1
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go vet ./...
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go test -race ./... -count=1
```

## Verification Result

All planned checks passed:

- `go test ./internal/store -run TestBoltState -count=1`
- `go test ./internal/store -count=1`
- `go test ./... -count=1`
- `go vet ./...`
- `go test -race ./... -count=1`
- `git diff --check` in both `lattice-server` and `lattice`

The race suite completed with `internal/server` as the long pole
(`94.497s`) and no race failures.

## Residuals

- Secret-bearing bbolt buckets remain pending.
- Runtime cutover remains pending.
- Retention/index design for high-volume audit/monitor history remains pending
  beyond the existing per-monitor result cap.
