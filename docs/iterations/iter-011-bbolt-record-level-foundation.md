# Iteration 011 - bbolt Record-Level Foundation

- **Date:** 2026-06-12
- **Phase:** C1 storage foundation
- **Repos:** `lattice-server`, `lattice`
- **Status:** Verified first record-level APIs / default store not switched

## Goal

Move Phase C beyond full-state import/export by proving the first bbolt
record-level transactions. This slice adds focused node, KV, and audit APIs to
`BoltStateStore` without wiring bbolt into server startup yet.

## Scope

- Add record-level node writes and reads:
  - `UpsertNode`
  - `Node`
  - `Nodes`
- Add record-level KV writes and bucket reads:
  - `PutKV`
  - `KV`
- Add record-level audit append and read:
  - `AppendAudit`
  - `AuditEvents`
- Preserve current JSON-store ordering semantics:
  - nodes sorted by id
  - KV entries sorted by key
  - audit events sorted newest first
- Keep writes local to their bbolt buckets; record-level writes must not reset
  unrelated imported buckets.

## Non-Goals

- Do not switch `cmd/lattice-server` to bbolt.
- Do not add `-data-engine=bolt` yet.
- Do not replace the JSON `Store` methods yet.
- Do not cover every bucket yet. Users, auth sessions, tasks, monitor results,
  plugin lifecycle, DDNS, notifications, tunnels, OIDC, and static objects still
  need record-level coverage.
- Do not anchor or migrate the audit WAL into bbolt yet.

## Security Notes

- This slice intentionally starts with nodes, KV, and audit events because they
  do not introduce new reversible secret write paths.
- Secret-bearing records remain protected by the existing full-state
  import/export encryption boundary until their record-level methods are added
  with field-specific encryption tests.
- The current runtime server path remains encrypted JSON + audit WAL.

## Verification

Targeted tests added in `lattice-server/internal/store/bolt_state_test.go`:

- node/KV/audit record-level writes work after a full import.
- record-level writes do not reset unrelated buckets.
- nodes, KV entries, and audit events keep JSON-store ordering semantics.
- node/KV/audit records persist across close/reopen.

Commands run:

```sh
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go test ./internal/store -run TestBoltState -count=1
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go test ./internal/store -count=1
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go test ./... -count=1
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go vet ./...
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go test -race ./... -count=1
```

## Residuals

- Expand record-level coverage for the remaining buckets.
- Add secret-bearing record-level write tests before DDNS, notification, OIDC,
  TOTP, or token-like material moves to per-record bbolt writes.
- Add an opt-in `-data-engine=bolt` only after the runtime path has enough
  record-level coverage and backup/restore drills.
