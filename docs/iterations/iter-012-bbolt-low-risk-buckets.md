# Iteration 012 - bbolt Low-Risk Bucket Coverage

- **Date:** 2026-06-13
- **Phase:** C1 storage foundation
- **Repos:** `lattice-server`, `lattice`
- **Status:** Verified low-risk bucket record APIs / default store not switched

## Goal

Extend the bbolt record-level foundation beyond nodes/KV/audit while avoiding
secret-bearing buckets. This slice adds record-level APIs for static objects,
Worker scripts, plugin lifecycle records, and approvals.

## Scope

- Add record-level static object writes and bucket reads:
  - `PutStatic`
  - `Static`
- Add record-level Worker writes and reads:
  - `UpsertWorker`
  - `Workers`
- Add record-level plugin lifecycle writes and reads:
  - `UpsertPluginInstallation`
  - `PluginInstallation`
  - `PluginInstallations`
  - `SetPluginStatus`
- Add record-level approval writes and reads:
  - `UpsertApproval`
  - `Approval`
  - `Approvals`
- Preserve current JSON-store behavior:
  - static objects sorted by path
  - Workers sorted by name
  - plugin lifecycle sorted by id
  - approvals sorted newest first
  - plugin status transition validation reused
- Keep writes local to their bbolt buckets; record-level writes must not reset
  unrelated imported buckets.

## Non-Goals

- Do not switch `cmd/lattice-server` to bbolt.
- Do not add `-data-engine=bolt` yet.
- Do not add record-level writes for DDNS, notification channels, OIDC providers,
  TOTP challenges, users, tokens, or sessions yet.
- Do not migrate or anchor the audit WAL into bbolt yet.

## Security Notes

- This slice still avoids reversible secret fields. Static content and Worker
  source can contain operator-provided sensitive text, but the current JSON store
  already persists those fields as ordinary state; this change does not widen
  their exposure or route runtime traffic to bbolt.
- Secret-bearing per-record methods must be added with field-specific encryption
  tests before they are considered ready.
- Plugin lifecycle reads clone capability slices so callers cannot mutate a
  returned slice and accidentally affect future in-memory state assumptions.

## Verification

Targeted tests added in `lattice-server/internal/store/bolt_state_test.go`:

- static, Worker, plugin lifecycle, and approval record-level writes work after
  a full import.
- plugin lifecycle transition validation is preserved.
- plugin capability slices are cloned on read.
- records keep JSON-store ordering semantics.
- record-level writes do not reset unrelated buckets.
- records persist across close/reopen.

Commands run:

```sh
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go test ./internal/store -run TestBoltState -count=1
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go test ./internal/store -count=1
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go test ./... -count=1
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go vet ./...
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go test -race ./... -count=1
```

## Residuals

- Remaining low/medium-risk buckets: tasks, task results, monitors, monitor
  results, tunnels.
- Secret-bearing buckets need field-specific encryption tests before per-record
  methods: users, tokens, sessions, TOTP challenges, DDNS profiles, notification
  channels, OIDC providers/auth states.
- Runtime store switching remains blocked until record-level coverage is broad
  enough and backup/restore drills are complete.
