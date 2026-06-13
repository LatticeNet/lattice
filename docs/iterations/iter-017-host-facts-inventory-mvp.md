# Iteration 017 — HostFacts Inventory MVP

- **Status:** Implemented (2026-06-13)
- **Design source:** `docs/designs/design-04-machine-inventory-and-cost.md`
- **Repos:** `lattice-sdk`, `lattice-node-agent`, `lattice-server`, `lattice-dashboard`
- **Follow-up:** Design 04 Half B was implemented in `iter-018-machine-profile-renewals.md`.

## Goal

Land the low-risk first half of machine inventory: node-agent auto-detects slow-changing host facts (OS, arch, CPU cores/model, RAM/swap, platform/kernel, hostname, boot time, virtualization hint), server stores them as advisory low-trust telemetry on `model.Node`, and dashboard shows them in the fleet table.

This iteration did **not** implement cost/vendor/renewal metadata; that
server-only Half B work landed immediately afterward in iter-018 with its own
encrypted-at-rest fields, RBAC scopes, reminder scheduler, and dashboard edit
flow.

## Scope

- Add `model.HostFacts` and `Node.HostFacts` to the shared SDK model and proto drafts.
- Add `lattice-node-agent/internal/hostfacts` with stdlib-only best-effort collection.
- Include `host_facts` in `/api/agent/hello` and `/api/agent/metrics` payloads.
- Add server-side `agentAuthRequest.HostFacts`, sanitize/clamp facts, stamp `reported_at` with server receive time, and persist on node records.
- Include `host_facts` in `/api/nodes` via `nodeView`.
- Show compact host summary in the dashboard node table: arch/platform, cores/RAM, uptime.
- While touching request decoding, finish C10 with explicit route-class semantics:
  - `decodeClientJSON`: strict unknown-field/trailing-value rejection for client/operator/public JSON APIs.
  - `decodeAgentJSON`: forward-compatible unknown-field tolerance for agent ingestion, still rejecting malformed/trailing bodies.

## Security Notes

- Host facts are node-reported and **must never be used for authorization, scheduling trust, or policy decisions**. They are display/inventory hints only.
- Server clamps control characters and string lengths and drops absurd CPU/RAM values before storing.
- `reported_at` is stamped server-side so freshness does not trust the node clock.
- Agent endpoints remain bearer-only; node tokens are still forbidden in request bodies.
- Client/operator JSON APIs are now stricter without breaking agent forward compatibility.

## Verification

- `lattice-sdk`: `go test ./... -count=1`, `go vet ./...`
- `lattice-node-agent`: `go test ./... -count=1`, `go vet ./...`
- `lattice-server`: `go test ./internal/server -count=1`, `go test ./... -count=1`, `go vet ./...`
- `lattice-dashboard`: `node --check assets/app.js`, `node --test assets/*.test.mjs`

## Residuals

- Design 04 Half B is now complete in iter-018: `MachineProfile`,
  `inventory:read/admin`, encrypted console/detail links, renewal reminders,
  and dashboard edit/renewal UI.
- HostFacts currently update on every metrics report. If payload churn matters later, agent can cache and send facts hourly without changing the server contract.
- Geo-map still needs Design 05: policy-aware per-node ACL state,
  coordinates/region normalization, and a map view using `HostFacts` +
  `MachineProfile.Region`.

## Next

Follow-up landed: `iter-018-machine-profile-renewals.md` implements the cost
metadata/reminder slice. The next recommended design slice is shared nft input
persistence, then Design 05's per-node ACL + network map.
