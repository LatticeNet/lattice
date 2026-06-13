# Iteration 018 — MachineProfile Cost / Renewal MVP

- **Status:** Implemented and verified (2026-06-13)
- **Design link:** `docs/designs/design-04-machine-inventory-and-cost.md`
- **Repos:** `lattice-sdk`, `lattice-server`, `lattice-dashboard`, `lattice`

## Goal

Finish Design 04 Half B's MVP: server-only machine cost/vendor/renewal metadata,
encrypted console/detail links, renewal reminder evaluation, and a dashboard
Machines panel. This builds on iter-017 HostFacts, so the fleet view now answers
both "what is this box?" and "what contract/cost/renewal belongs to it?"

## Scope Landed

- `lattice-sdk`
  - Added `model.MachineProfile` and `RenewalCycle*` constants.
  - Added proto `MachineView` as a redacted view shape.
  - Updated proto contract tests so raw `console_url` / `detail_url` are
    forbidden in proto responses while `has_console_url` / `has_detail_url`
    badges remain allowed.

- `lattice-server`
  - Added `MachineProfiles` to JSON `State` and bbolt buckets/record APIs.
  - Added at-rest encryption for `MachineProfile.ConsoleURL` and `DetailURL`,
    including `stateHasEnvelope` lost-key detection.
  - Added inventory API:
    - `GET /api/machines` (`inventory:read`, per-node filtered)
    - `POST /api/machines` (`inventory:admin`, create)
    - `POST /api/machines/update`
    - `POST /api/machines/delete`
    - `POST /api/machines/renew`
    - `POST /api/machines/reminders/run`
  - Added server-side validation: node exists, 1:1 profile per node, integer
    money, currency normalization, renewal cycle validation, custom-days bounds,
    reminder offsets, and write-only link update semantics.
  - Added renewal reminder evaluator and coarse scheduler. Reminders fire once
    per `(renewal date, offset)` via persisted `LastRemindedKey`; if the server
    misses an earlier threshold, it fires the closest current threshold instead
    of replaying stale larger offsets.
  - Added audit events: `inventory.create`, `inventory.update`,
    `inventory.delete`, `inventory.renew`, `inventory.reminder`, and
    `inventory.reminder.manual`.

- `lattice-dashboard`
  - Added a Machines panel with list, add/edit form, write-only console/detail
    link fields, redacted link badges, renewal status, mark-renewed action, and
    manual reminder run.
  - Added `assets/machines.js` pure helpers with tests for payload normalization,
    money formatting, date inputs, and renewal state.

## Security Notes

- Half B stays **server-only**. MachineProfile data is never sent to agents and
  cannot influence agent behavior.
- `ConsoleURL` and `DetailURL` are encrypted at rest and are never returned by
  list/read APIs. The MVP intentionally does **not** add a reveal endpoint.
- `GET /api/machines` is authenticated first, then checks `inventory:read` and
  filters by node allowlist. Create/update/delete/renew/reminder operations
  require `inventory:admin` and re-check node allowlists against the actual
  profile/node.
- Client JSON is strict through `decodeClientJSON`; unknown fields are rejected.
- Reminder notifications reuse the existing notify dispatcher; no new outbound
  network surface was added.

## Verification Evidence

- SDK: `go test ./... -count=1`, `go vet ./...`
- Server: `go test ./internal/store -count=1`,
  `go test ./internal/server -count=1`, `go test ./... -count=1`,
  `go vet ./...`, `go test -race ./... -count=1`
- Dashboard: `node --check assets/app.js`, `node --check assets/machines.js`,
  `node --test assets/*.test.mjs`
- Integration smoke: created a node + machine profile through HTTP, confirmed
  the API view never leaked raw links or write-only field names, and manually
  fired the due renewal reminder once.

## Review Focus

- Crypto wiring includes JSON store, bbolt store, and `stateHasEnvelope`.
- No API response leaks raw console/detail URLs.
- Reminder idempotency survives repeated evaluation and server restarts.
- Node allowlists are checked against actual `node_id`, not only query params.
- The dashboard does not insert unescaped node/operator strings into HTML.

## Residuals / Next

- No audited reveal endpoint yet; MVP keeps links write-only and badge-only.
- No per-currency dashboard totals yet.
- No `inventory.facts_changed` alert yet.
- No browser screenshot pass yet for narrow viewport table layout.
- Shared nft input persistence was completed in iter-019. Next recommended
  slice is Design 05 per-node ACL + map, unless runtime bbolt cutover is
  prioritized first.
