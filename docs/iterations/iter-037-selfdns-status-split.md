# Iteration 037 — Self-host DNS Status Split

- **Date:** 2026-06-14
- **Status:** Complete
- **Design reference:** `docs/designs/design-02-self-host-dns.md`
- **Repos:** `lattice-sdk`, `lattice-server`, `lattice-dashboard`, `lattice`

## Goal

Close the model/UX sharp edge left by iter-036: DNS service apply status and
Cloudflare hostname publication status must be separate so operators can tell
whether CoreDNS/nft failed or whether the A/AAAA record publish failed.

## Scope

- Add explicit publication status fields to `model.DNSDeployment`:
  - `LastPublishedAt`
  - `LastPublishError`
- Append the same fields to `DNSDeploymentView` in the proto contract without
  renumbering existing fields.
- Change server publish bookkeeping so:
  - `/api/dns/publish` records `LastIPv4` / `LastIPv6` and
    `LastPublishedAt` / `LastPublishError`;
  - publish success/failure does **not** mutate `LastAppliedAt` / `LastError`;
  - CoreDNS/nft apply continues to own `LastAppliedAt` / `LastError`.
- Preserve the new fields across DNS deployment edits.
- Update the dashboard DNS card to label service errors and publish errors
  separately, and show the publication timestamp beside the last published
  A/AAAA values.
- Refresh public maintenance docs so future work builds on the split.

## Explicit Non-goals

- No CoreDNS binary download/provenance implementation.
- No real Linux-node E2E.
- No Cloudflare network call in tests.
- No protobuf code generation step; the repo still checks in proto contracts
  ahead of generated clients.

## Security Notes

- The change is additive and secret-free. It does not expose `CFAPIToken`.
- Publication provider errors still stay out of audit metadata; they are stored
  on `LastPublishError` for operator troubleshooting.
- Distinguishing service apply failures from publication failures reduces the
  chance that an operator re-applies privileged nft/CoreDNS changes when only a
  Cloudflare write failed.

## Verification

- `go test ./model` in `lattice-sdk`
- `GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work GOCACHE=/private/tmp/lattice-gocache go test -count=1 ./internal/server -run 'TestDNS'`
- `node --check assets/app.js`
- `node --check assets/dns.js`
- `node --test assets/*.test.mjs`

## Review Outcome

- API compatibility is preserved by appending proto fields at 26/27.
- The server tests prove publish does not mutate service apply status on either
  success or failure.
- Dashboard copy now makes the failure layer explicit (`service error` vs
  `publish error`).

## Residuals

- CoreDNS binary provenance/install support remains the next self-host DNS
  implementation slice.
- A real Linux-node E2E still needs to prove CoreDNS + nft apply + Cloudflare
  publish together outside this sandbox.
