# Iteration 024 — NetPolicy Ingress Guard Composition

- **Status:** Plan -> Execute (2026-06-14)
- **Builds on:** `iter-019-shared-nft-inputs.md`, `iter-020-netpolicy-state-and-graph.md`, `iter-021-netpolicy-egress-apply.md`, `iter-023-netpolicy-graph-svg.md`
- **Repos:** `lattice-server`, `lattice`

## Goal

Make ingress `NetPolicy` rules enforceable without adding a second default-drop
`input` hook. Ingress must be folded into the existing single
`table inet lattice_guard` render used by Network Guard.

## Scope

- Add typed input-rule support to `internal/network.GenerateNFTPlan`.
- Add an `internal/netpolicy` compiler helper that converts enabled ingress
  `NetPolicy` rules into those typed `lattice_guard` input rules.
- Compose stored ingress policy into `POST /api/network/nft/plan`.
- Upgrade `nft` approvals from syntax-check-only to rollback-protected guard
  apply: `/etc/lattice/guard.nft.new` -> `nft -c` -> rollback snapshot ->
  watchdog -> `nft -f` -> optional control-plane selfcheck.
- Add regression tests for rule ordering: ingress denies must appear before the
  broad public/WireGuard service allows.
- Keep `POST /api/netpolicy/plan` egress-only for now; it still owns
  `table inet lattice_policy` and the rollback-protected `nftpolicy` apply path.

## Non-Goals

- No domain/DDNS-backed nft named sets.
- No IPv6 rules.
- No second `input` chain/table.
- No dashboard redesign in this slice; the existing NetPolicy form can already
  author ingress rules, and Network Guard creates the composed guard plan.

## Safety Invariants

- Operator text never enters nft syntax raw. Source CIDRs/IPs, protocols, ports
  and actions are validated and canonicalized before rendering; comments are
  quoted.
- The `lattice_guard` chain still begins with established/related and loopback
  accepts.
- Ingress policy rules are rendered before broad service-port allows so a
  targeted deny can constrain a saved WireGuard/public port.
- If a node has an ingress policy and the caller lacks `netpolicy:read` on that
  node, the guard plan is rejected rather than silently omitting policy.

## Test Plan

- `go test ./internal/network ./internal/netpolicy ./internal/server -count=1`
- Targeted tests:
  - `internal/network`: input rules render before broad allows and reject bad
    source/action/protocol combinations.
  - `internal/netpolicy`: node refs resolve to canonical IPv4 sources.
  - `internal/server`: `/api/network/nft/plan` includes ingress policy in
    `lattice_guard`, while `/api/netpolicy/plan` remains egress-only.

## Exit Bar

The server can produce and queue a single human-reviewable `lattice_guard` plan
that contains the persisted Network Guard baseline plus enabled ingress rules
for the target node, with tests proving ordering, injection boundaries, and
rollback apply script shape. Documentation must clearly state that egress apply
and ingress guard composition are still two separate planning surfaces.

## Execution Log

- Added `network.NFTInputRule` as a typed, JSON-hidden input-rule channel for
  server-owned compilers. `NormalizeNFTPlan` now validates source IPv4/CIDR,
  protocol, ports, action, and comments before render.
- `GenerateNFTPlan` now emits `destroy table inet lattice_guard` followed by the
  full `table inet lattice_guard` document, so committed guard applies replace
  the single table atomically instead of colliding with an existing table.
- Added `netpolicy.CompileIngressInputRules`: enabled ingress rules become typed
  guard input rules; egress and disabled rules are ignored for this path; node
  refs expand to current WireGuard/Public IPv4s.
- `handleNFTPlan` composes enabled ingress policy into the target node's guard
  plan. If ingress policy exists and the caller lacks `netpolicy:read` on that
  node, the server returns 403 rather than producing an incomplete plan.
- `applyScriptFor("nft")` now uses a rollback-protected guard apply script.
  `nftpolicy` remains the egress policy apply script and continues to own
  `/etc/lattice/policy.nft`.
- Updated roadmap, design index, Design 05, Network Guard tutorial, product
  vision, and the development report.

## Review Outcome

- Manual security/code review focused on nft syntax injection, table ownership,
  rule ordering, RBAC omission risk, and apply rollback semantics.
- Must-fix found and fixed: committed guard apply requires replacement semantics,
  so `GenerateNFTPlan` now starts with `destroy table inet lattice_guard`.
- Accepted residual at iter-024 close: `approve` still treated `plan_sha256` as
  optional for non-`nftpolicy` approvals because the dashboard did not yet
  compute hashes. Iter-025 closes this residual by requiring plan hashes for
  pending high-risk approvals and computing them in the dashboard before apply.

## Residuals

- `POST /api/netpolicy/plan` remains egress-only and IPv4-literal-public-url
  only.
- Domain/DDNS-backed nft named sets, IPv6 policy, bulk geo import, and map
  overlays remain next Design 05 work.
- Guard apply selfcheck is skipped when server `public_url` is unset; production
  deployments should set it.
