# Iteration 020 — NetPolicy State + Graph MVP

- **Status:** Complete (2026-06-13)
- **Design link:** `docs/designs/design-05-network-acl-and-map.md`
- **Builds on:** `iter-019-shared-nft-inputs.md`
- **Repos:** `lattice-sdk`, `lattice-server`, `lattice-dashboard`, `lattice`

## Goal

Land the safe first slice of Design 05: model and persist per-node network
policy, validate every rule server-side, expose a reachability graph, and show
it in the dashboard. This lets operators express and review intent such as
"node A denies egress to node B tcp/1234" without yet committing nft changes on
the host.

## Scope

- Add shared SDK model types:
  - `NetEndpoint`, `NetRule`, `NetPolicy`
  - constants for action/direction/protocol/reference kind
  - `NodeGeo` placeholder on `Node` for later map work
- Add JSON store and bbolt foundation coverage for `NetPolicy`.
- Add `internal/netpolicy` validation + graph builder:
  - reject unknown actions/directions/protocols/ref kinds
  - reject invalid ports and IPv6/CIDR inputs for MVP
  - require node refs to resolve to existing nodes
  - canonicalize CIDR/IP and sorted unique ports
- Add server APIs:
  - `GET /api/netpolicy` (`netpolicy:read`)
  - `POST /api/netpolicy` (`netpolicy:admin`)
  - `POST /api/netpolicy/delete` (`netpolicy:admin`)
  - `GET /api/netpolicy/graph` (`netpolicy:read`)
- Add dashboard policy panel:
  - simple form for one rule at a time
  - saved policy list
  - node-to-node edges + external rules list

## Explicit Non-Scope

- No `POST /api/netpolicy/plan` yet.
- No `nftpolicy` apply branch.
- No `nft -f` commit, no rollback script, no agent selfcheck subcommand.
- No ingress merge with `lattice_guard` until the double-drop interaction is
  tested.

Those pieces must land together in a later iteration because a real firewall
commit without dead-man rollback can lock an operator out.

## Security Notes

- `NetPolicy` is non-secret and should remain plaintext for review/diffability.
- Policy writes require `netpolicy:admin`; graph/list require `netpolicy:read`.
- Per-node allowlists apply to the target node, and graph output is filtered to
  visible policies.
- A malformed rule fails closed at write time and is not stored.
- A compromised node cannot author policy; this is operator-only control-plane
  state.

## Verification Plan

- SDK: `go test ./... -count=1`, `go vet ./...`
- Server: `go test ./internal/netpolicy ./internal/store ./internal/server -count=1`,
  `go vet ./...`
- Dashboard: `node --check assets/app.js`, `node --check assets/netpolicy.js`,
  `node --test assets/*.test.mjs`
- Review: inspect authz, validation, XSS escaping, and bbolt parity before
  commit.

## Exit Bar

An operator can create a deny/allow rule for a target node, see it listed,
fetch a graph derived from server-side validation, and delete it. No host
firewall state changes occur in this iteration.

## Residuals / Next

- Add the real `nftpolicy` apply path as a separate iteration:
  `/api/netpolicy/plan`, nft compiler, approval plan, `applyScriptFor`
  branch, agent `--selfcheck-controlplane`, 60s dead-man rollback, task-result
  status consumption, and notify/audit fan-out. Do not commit nft without those
  pieces.
- Upgrade the dashboard graph from list form to inline SVG once compiler parity
  tests exist, so visualization and enforcement cannot drift.
- Add operator-managed `NodeGeo` CRUD and the zero-dep geo-map panel. (Closed
  by iter-022.)
- Revisit IPv6 only after IPv4 policy apply is tested end to end.

## Implementation Notes

- SDK: `model.NetEndpoint`, `model.NetRule`, `model.NetPolicy`, `model.NodeGeo`,
  and proto-facing `NetPolicyView`/`NetPolicyGraph` contracts.
- Server: JSON store and bbolt bucket/API coverage for `NetPolicies`;
  `internal/netpolicy` validation and graph builder; `netpolicy:read` /
  `netpolicy:admin` risk classification; CRUD + graph handlers.
- Dashboard: strict NetPolicy port parser, policy form/list, server-derived
  node/external graph list, and hidden-on-403 admin panel behavior.
- Intentional safety boundary: this iteration stores and renders control-plane
  intent only. It never queues a host task and never runs `nft`.

## Verification Evidence

- SDK: `go test ./... -count=1`; `go vet ./...`.
- Server: `go test ./internal/netpolicy ./internal/store -count=1`;
  `go test ./internal/server -run 'TestNetPolicy|TestNFT|TestApprovePlanHashBinding' -count=1`.
- Server race: `go test -race ./internal/netpolicy ./internal/store -count=1`;
  `go test -race ./internal/server -run 'TestNetPolicy|TestNFT|TestApprovePlanHashBinding' -count=1`.
- Dashboard: `node --check assets/app.js`; `node --check assets/netpolicy.js`;
  `node --test assets/*.test.mjs` (43 pass).
- Server full `go test ./...` was attempted and reached unrelated
  `httptest.NewServer` cases in `internal/ddns`, `internal/notify`, and
  OIDC/server tests, but the sandbox rejected local port binds
  (`bind: operation not permitted`). Focused impacted tests and `go vet ./...`
  passed.

## Review Outcome

Review focus areas: authz, node allowlist filtering, XSS escaping, strict
client-side port parsing, server validation, JSON/bbolt parity, and the explicit
no-apply boundary.

Findings fixed before commit:
- NetPolicy port parsing in the dashboard now rejects invalid or non-decimal
  tokens (`abc`, `1e3`, `0`, `65536`) instead of silently dropping them and
  risking an accidental all-port rule.
- Server normalization now rejects duplicate rule IDs so future plan/audit/graph
  references are unambiguous.
- The dashboard graph list now displays direction (`ingress`/`egress`) so
  operator review cannot confuse the edge semantics.

No blocking findings remain for the scoped state/graph MVP. The known
non-scope remains blocking for real firewall mutation: do not add host nft apply
without the planned compiler, approval hash binding, agent selfcheck, and
dead-man rollback.
