# Iteration 034 — Self-host DNS Render + Review Plan

- **Date:** 2026-06-14
- **Status:** Complete
- **Design reference:** `docs/designs/design-02-self-host-dns.md`
- **Repos:** `lattice-server`, `lattice-dashboard`, `lattice`

## Goal

Advance Design 02 from durable DNS intent CRUD to a safe review boundary: render
CoreDNS artifacts, compose the DNS listener into the single `lattice_guard`
nftables candidate, and create a pending approval that operators can inspect and
hash-bind before any future apply path exists.

## Scope

- Add `internal/selfdns`, a dependency-free renderer for:
  - CoreDNS Corefile generation.
  - Static-zone file generation for `A`/`AAAA`/`CNAME` records.
  - Block-zone NXDOMAIN template rendering.
  - DNS listener port composition into `network.NFTPlan`.
  - Secret-free approval plan text containing CoreDNS artifacts, firewall
    summary, nft candidate, and Cloudflare action summary.
- Add `POST /api/dns/plan`.
  - Requires `dns:admin` on the deployment node.
  - Also requires same-node `network:plan` because the response includes the
    firewall candidate.
  - Reuses `composeNFTIngressPolicy`; if enabled ingress policy exists, callers
    must also have `netpolicy:read`.
  - Creates a pending `selfdns` approval with plan-hash binding through the
    existing approval flow.
- Keep selfdns apply disabled in this slice.
  - `queue_apply` for `selfdns` returns a clear `400`.
  - `applyScriptFor("selfdns")` also fails closed for stale/manual tasks.
- Add dashboard `Plan review` on DNS cards.
  - Generates the pending plan and refreshes approvals.
  - Approval helper treats `selfdns` as review-only (`queue_apply:false`) until
    apply exists.

## Explicit Non-goals

- No CoreDNS install/reload script.
- No nft commit for DNS plans.
- No `/api/dns/publish` or Cloudflare mutation.
- No task-result reconciliation into `DNSStatusRunning/Failed`.
- No multi-zone dashboard editor.

## Security Notes

- Mesh exposure requires the node's `WireGuardIP` so CoreDNS can include a
  defensive `bind <wg-ip>` line; nft confinement is not the only boundary.
- DNS plan generation is stricter than CRUD: `dns:admin` alone is not enough
  because the plan exposes a full firewall candidate.
- Approval plan text never includes `cf_api_token`; it only shows whether a
  credential is present.
- Queueing apply is blocked explicitly. A reviewable plan must not create an
  impression that resolver deployment is already operational.
- Renderer tests cover unsafe suffix/upstream input rejection and secret-free
  approval plans.

## Verification

- `GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work GOCACHE=/private/tmp/lattice-gocache go test ./internal/selfdns ./internal/server -run 'Test(Generate|Compose|Render|DNS|Approval)'`
- `GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work GOCACHE=/private/tmp/lattice-gocache go build ./cmd/lattice-server`
- `node --check assets/app.js`
- `node --check assets/approval.js`
- `node --test assets/*.test.mjs`

Server build exits successfully; Go still prints a user-module stat-cache
warning in this sandbox because `/Users/cdcd/go/pkg/mod/cache` is not writable.

## Review Outcome

- **Blocking findings:** none in local adversarial review.
- A deliberate hard boundary remains: selfdns plans are review-only. The next
  iteration must remove the `queue_apply` block only after the apply script,
  rollback/selfcheck behavior, and status reconciliation are implemented and
  tested.

## Residuals

- Implement `selfdns.ApplyScript`: atomic Corefile/zone writes, `coredns`
  validation, `nft -c` then rollback-protected commit, reload/restart, and
  bounded output.
- Add `POST /api/dns/publish` through `internal/ddns`.
- Add task-result reconciliation for `DNSStatusRunning/Failed`.
- Add dashboard publish/apply status controls only after backend support is real.
