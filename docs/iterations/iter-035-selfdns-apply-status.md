# Iteration 035 — Self-host DNS Apply + Status Reconciliation

- **Date:** 2026-06-14
- **Status:** Complete
- **Design reference:** `docs/designs/design-02-self-host-dns.md`
- **Repos:** `lattice-server`, `lattice-dashboard`, `lattice`

## Goal

Turn iter-034's review-only selfdns plan into an approval-gated apply path
without adding Cloudflare publication yet. The approved plan remains the source
of truth: the agent script extracts the exact CoreDNS, zone-file, and nftables
artifacts the operator reviewed and hash-bound.

## Scope

- Add `selfdns.ParseApprovalPlan` and `selfdns.ApplyScriptFromPlan`.
  - Extracts CoreDNS Corefile, static zone files, and the `lattice_guard`
    candidate from the reviewed plan.
  - Validates zone file paths stay under `/etc/lattice/selfdns/zones`.
  - Generates a shell script that:
    - requires `coredns`, `nft`, and `systemctl`;
    - backs up `/etc/lattice/selfdns`;
    - writes Corefile/zone files;
    - writes and checks `/etc/lattice/guard.nft.new`;
    - saves current nft ruleset for rollback;
    - commits nft;
    - installs/restarts `lattice-selfdns.service`;
    - verifies the service is active;
    - rolls back config and firewall on `ERR`, `INT`, `TERM`, or `HUP`.
- Encode `dns_id` into the `selfdns` approval action.
- Allow `queue_apply` for `selfdns` after plan-hash verification, reviewed-plan
  parsing, and deployment/node ownership checks.
- Mark the deployment `applying` after the apply task is queued.
- On agent task result:
  - success → `DNSDeployment.Status=running`, set `LastAppliedAt`, clear
    `LastError`, mark approval `applied`, audit `dns.apply.applied`;
  - failure → `DNSDeployment.Status=failed`, set `LastError`, audit
    `dns.apply.failed`.
- Dashboard approval payloads now queue selfdns apply like other high-risk
  reviewed approvals.

## Explicit Non-goals

- No CoreDNS binary download/installation.
- No `/api/dns/publish`.
- No Cloudflare mutation or DDNS IP-change publication.
- No browser E2E due current sandbox local-bind restriction.

## Security Notes

- The apply script is derived from the reviewed plan text, not from current
  mutable store state. That preserves the plan-hash boundary.
- The script does not contain Cloudflare tokens or any server-side secret.
- nft commit is rollback-protected and coupled to `systemctl is-active`; a
  failed service activation triggers firewall/config rollback.
- `selfdns` still requires the normal high-risk approval path:
  `plan_sha256` + `network:apply` + node allowlist.

## Verification

- `GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work GOCACHE=/private/tmp/lattice-gocache go test ./internal/selfdns ./internal/server -run 'Test(DNS|Generate|Compose|Render|Parse|Approve|Apply)'`
- `node --check assets/app.js`
- `node --check assets/approval.js`
- `node --test assets/*.test.mjs`

## Review Outcome

- **Blocking findings fixed during review:** the first script draft only trapped
  signals, so `set -e` failures such as `systemctl restart` could exit without
  rollback. The script now traps `ERR` as well and disables `set -e` inside the
  rollback function.
- **Follow-up noted, not blocking:** host-mutation tasks are executed
  sequentially by the normal node-agent loop after lease, but the control plane
  does not yet have a first-class per-node host-mutation mutex. This matters if
  an operator accidentally runs multiple agent processes for the same node ID.
  Track as a later task-system hardening item before allowing more concurrent
  host-level providers.

## Residuals

- Add CoreDNS binary provenance/install support or document supported packaging
  per distro.
- Add `/api/dns/publish` through `internal/ddns`.
- Add continuous Cloudflare publication on node IP changes.
- Add dashboard publish/status controls after publish exists.
