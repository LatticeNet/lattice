# Iteration 067 — Audit WAL Local Head Anchor

## Context

The audit WAL already chained every file-backed audit event and detected edits,
reorders, sequence gaps, and middle-record deletion. It could not distinguish a
valid shorter prefix from a legitimate WAL, so deleting records from the end of
`state.json.audit-wal` still verified unless an operator compared the head hash
against an independently saved value.

## Decision

Add a local sidecar anchor file beside the JSON state and WAL:

- `state.json`
- `state.json.audit-wal`
- `state.json.audit-anchor`

The anchor stores the last committed `{count, head}` and is checked on store open
and `/api/audit/verify`. Existing deployments without an anchor bootstrap the
anchor from the current verified WAL on first open. After that, the anchor is
authoritative for local end-truncation detection.

## Crash Safety

Anchor updates use a pending/committed protocol:

1. Write `{committed: old head, pending: new head}` and fsync it.
2. Append the new WAL entry and fsync the WAL.
3. Write `{committed: new head}` and fsync it.

On restart, a pending anchor is reconciled only when the WAL matches either the
committed or pending checkpoint. A shorter WAL fails closed with an anchor
mismatch instead of being silently extended.

## Operator Impact

Backups must include `state.json.audit-anchor` together with `state.json`,
`state.json.audit-wal`, `logs.db`, and `master.key`. Losing the anchor does not
destroy data, but it weakens end-truncation evidence until a new anchor is
bootstrapped from the current WAL.

## Remaining Work

- Remote/off-box audit head shipping, so a host-level attacker cannot delete both
  the WAL tail and the local anchor.
- Retention policy and backup/restore drills for realistic long-running audit
  history.
- bbolt runtime cutover remains separate from the JSON + WAL + anchor runtime
  path.

## Verification

- `go test ./internal/audit ./internal/store -run 'Test.*WAL|TestStoreAuditWAL'`
- `go test ./internal/audit ./internal/store ./internal/server -run 'Test.*WAL|TestStoreAuditWAL|TestAuditVerifyReportsAnchorStatus'`
