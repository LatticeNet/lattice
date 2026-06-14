# Iteration 032 — nftpolicy Domain Refresh cron.d Fallback

- **Date:** 2026-06-14
- **Status:** Complete
- **Design reference:** `docs/designs/design-05-network-acl-and-map.md`
- **Repo:** `lattice-server`

## Goal

Keep domain-backed `nftpolicy` named sets refreshed on Linux nodes that do not
run systemd, without adding another on-node daemon or changing the agent
protocol.

## Scope

- Preserve the existing systemd timer path as the preferred scheduler when
  `/run/systemd/system` is present.
- Add a non-systemd fallback that writes
  `/etc/cron.d/lattice-nftpolicy-domain-refresh` when `/etc/cron.d` exists.
- Keep the same root-owned refresh script:
  `/etc/lattice/nftpolicy-domain-refresh.sh`.
- Remove stale cron/systemd refresh artifacts when a later approved plan no
  longer contains any domain-backed control-plane or operator remote sets.

## Design

The approved apply script now follows this order:

1. Apply the candidate `table inet lattice_policy` with the existing
   rollback-protected flow.
2. Update all domain-backed named sets through
   `lattice-agent --update-nft-domain-set`.
3. Run the control-plane selfcheck.
4. Install periodic refresh:
   - if systemd is available, install/enable
     `lattice-nftpolicy-domain-refresh.timer`;
   - otherwise, if `/etc/cron.d` exists, write a root cron entry:

     ```cron
     * * * * * root /etc/lattice/nftpolicy-domain-refresh.sh >/dev/null 2>&1
     ```

   - otherwise, keep the refresh script and print an explicit warning that no
     scheduler was installed.

Systemd remains preferred because it has explicit unit state and `Persistent=`,
but cron.d is a useful lowest-common-denominator fallback for non-systemd Linux
hosts that still run nftables.

## Security Notes

- The cron file contains no secrets: only the root-owned refresh script path.
- The refresh script contains no node bearer token; it calls the local
  `lattice-agent` helper in one-shot DNS/nft mode.
- If writing the refresh script or cron/systemd artifacts fails while the apply
  task is running, `set -e` and the existing rollback trap keep failure visible.
- If neither scheduler exists, Lattice does not claim success for periodic
  refresh; it logs an explicit warning while leaving the script for manual or
  external scheduling.

## Verification

- `GOCACHE=/private/tmp/lattice-gocache GOWORK=... go test ./internal/server -run 'TestNetPolicyPlanApproveAndResultUpdatesPolicy|TestNetPolicyPlanRejectsIngressAndAcceptsHTTPSDomainPublicURL|TestNetPolicyPlanBindsOperatorDomainRemoteSets'`
- `GOCACHE=/private/tmp/lattice-gocache GOWORK=... go test ./internal/netpolicy`

Broader `go test ./...` remains limited by the current sandbox for packages that
bind local TCP/httptest listeners.

## Review Outcome

- **Blocking findings:** none.
- The fallback is intentionally conservative: only `/etc/cron.d` is supported in
  this slice. No user crontab editing, no shell DNS parsing, and no background
  daemon were introduced.

## Residuals

- OpenRC/launchd/native agent scheduling can be considered later, but is not
  required for the Linux nftables target path.
- Bulk geo import and map latency/renewal overlays remain the next Design 05
  usability slices.
