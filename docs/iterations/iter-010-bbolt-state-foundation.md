# Iteration 010 - bbolt State Foundation

- **Date:** 2026-06-12
- **Phase:** C1 storage foundation
- **Repos:** `lattice-server`, `lattice`
- **Status:** In progress / first slice verified

## Goal

Start the Phase C storage migration without destabilizing the current JSON
store. The first slice introduces a bbolt-backed state import/export boundary
that preserves the existing encryption semantics and stores each top-level
collection in its own bucket.

## Scope

- Add `internal/store.BoltStateStore` in `lattice-server`.
- Open bbolt with private file mode (`0600`) and a bounded file-lock timeout.
- Create one bucket per current `State` collection rather than storing the
  entire state as a single JSON blob.
- Import a full in-memory `State` into bbolt atomically.
- Export a full initialized `State` from bbolt.
- Reuse the existing AES-256-GCM `encryptedState` / `decryptState` boundary so
  reversible secrets are still encrypted at rest.

## Non-Goals

- Do not switch `cmd/lattice-server` or `store.OpenWithCipher` to bbolt yet.
- Do not rewrite every Store method to record-level bbolt transactions yet.
- Do not remove the JSON state file or audit WAL.
- Do not add retention/migration CLI yet.

## Security Notes

- The bbolt file must not leak TOTP secrets, DDNS tokens, notification secrets,
  or OIDC client secrets in plaintext.
- Non-secret fields remain inspectable enough for operational recovery.
- Existing one-way hashes stay hashes; the bbolt layer does not reinterpret
  password/token/recovery-code material.
- The current server path remains JSON + audit WAL until the migration path and
  record-level APIs are separately tested.

## Verification

Targeted tests added in `lattice-server/internal/store/bolt_state_test.go`:

- bbolt round-trip preserves users, nodes, KV, task results, audit events,
  monitor results, TOTP challenges, DDNS, notification channels, and OIDC
  providers.
- secret-bearing fields are encrypted in the bbolt file and decrypted on export.
- non-secret fields stay visible.
- the store is bucketized and does not persist the full `State` as one JSON
  blob.
- exporting an empty database returns initialized maps.

Commands run:

```sh
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go test ./internal/store -run TestBoltState -count=1
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go test ./internal/store -count=1
```

## Residuals

- JSON remains the default server store.
- Next slice should add a migration/export CLI or an opt-in `-data-engine=bolt`
  path with JSON import and rollback/export tests.
- Record-level bbolt writes are still pending; `BoltStateStore.ImportState` is a
  migration bridge, not the final hot-path API.
