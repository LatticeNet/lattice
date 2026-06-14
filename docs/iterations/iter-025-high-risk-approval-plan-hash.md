# Iteration 025 — Require Plan Hashes for High-Risk Approvals

- **Status:** Plan -> Execute (2026-06-14)
- **Builds on:** `iter-016-audit-remediation.md`, `iter-021-netpolicy-egress-apply.md`, `iter-024-netpolicy-ingress-guard-composition.md`
- **Repos:** `lattice-server`, `lattice-dashboard`, `lattice`

## Goal

Close the remaining approval TOCTOU gap: pending host-mutating approvals must be
bound to the exact plan the operator reviewed. A missing `plan_sha256` should no
longer be accepted for high-risk apply paths.

## Scope

- Server:
  - Require `plan_sha256` on pending high-risk approvals.
  - Keep already-decided approvals idempotent: repeated approve calls return the
    current view and do not require another hash.
  - Preserve mismatch rejection with `409 Conflict`.
  - Add/adjust regression tests for `nft`, `nftpolicy`, `wireguard`, and
    `cftunnel` approvals.
- Dashboard:
  - Compute `sha256(plan)` using WebCrypto over the visible approval plan before
    calling `/api/network/approvals/approve`.
  - Send `{approval_id, queue_apply:true, plan_sha256}`.
  - Surface hashing/API failures in the Network Guard approval area.
- Docs:
  - Update the approval/security docs to say plan hashes are required for
    pending high-risk apply approvals, not merely optional.

## Non-Goals

- No re-authentication prompt for `network:apply` yet.
- No two-person approval workflow.
- No browser E2E in this sandbox; unit coverage locks the dashboard hashing
  helper.

## Safety Invariants

- A pending approval with a plan cannot be queued without a hash.
- The hash is computed by the client from the plan text it received, not trusted
  from a server-provided digest.
- Repeated approve clicks on an already approved/applied approval do not create
  extra tasks.
- Future unknown approval plugins fail closed when they carry a plan.

## Test Plan

- `go test ./internal/server -run 'TestApprove|TestNFT|TestNetPolicy|TestWireGuard|TestTunnel' -count=1`
- `npm run check`
- `npm test`
- `git diff --check` for touched repos.

## Exit Bar

The dashboard can still approve queued Network Guard/NetPolicy/WireGuard/Tunnel
plans, but the server rejects pending approvals missing `plan_sha256`. Tests
prove missing, mismatched, and correct hashes.

## Execution Log

- `handleApprove` now trims `plan_sha256`, returns already-decided approvals
  idempotently before hash validation, and requires hashes for pending
  host-mutating approvals.
- `approvalRequiresPlanHash` is fail-closed: known host-risk plugins (`nft`,
  `nftpolicy`, `wireguard`, `cftunnel`, future `selfdns`/`proxycore`) require a
  hash, and unknown plugins with a non-empty plan also require one.
- Server tests now cover missing hash (400), mismatched hash (409), correct hash
  (200), and retrying an already approved approval without a hash.
- Updated existing WireGuard, Tunnel, Network Guard, NetPolicy, and request-audit
  tests so they submit `plan_sha256` for pending approvals.
- Added `assets/approval.js` in the dashboard: `sha256Hex`, `approvalById`, and
  `approvalPayload`.
- Dashboard approval now finds the visible approval by id, computes
  `sha256(plan)` with WebCrypto, and submits `{approval_id, queue_apply:true,
  plan_sha256}`.
- Approval failures now surface in the Network Guard panel error line.
- Updated architecture, roadmap, product vision, Design 01/02/05, Network Guard
  tutorial, development report, program review, and dashboard README.

## Review Outcome

- Manual review focused on fail-closed plugin coverage, idempotency, dashboard
  hashing semantics, and stale doc wording.
- The important ordering choice is deliberate: already-decided approvals return
  before hash validation, so repeated clicks cannot fail after a successful
  approval and cannot queue duplicate tasks.
- No blocking findings after targeted verification.

## Residuals

- `network:apply` re-authentication remains pending.
- The dashboard computes hashes with WebCrypto; very old browsers without
  `crypto.subtle` will show an approval error instead of sending an unbound
  apply request.
- No browser E2E was run in this sandbox.
