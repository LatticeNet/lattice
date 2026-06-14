# Iteration 036 — Self-host DNS Cloudflare Publish

- **Date:** 2026-06-14
- **Status:** Complete
- **Design reference:** `docs/designs/design-02-self-host-dns.md`
- **Repos:** `lattice-server`, `lattice-dashboard`, `lattice`

## Goal

Finish the DNS hostname publication slice promised after iter-035: a saved
`DNSDeployment` can publish its configured hostname through the existing
Cloudflare DDNS provider, and the publication can also run automatically when
the bound node's public IP changes.

## Scope

- Add `POST /api/dns/publish` behind `dns:admin` and same-node allowlist.
- Reuse `internal/ddns` instead of adding another Cloudflare client.
- Build a temporary Cloudflare `DDNSProfile` from the deployment:
  - domain = `DNSDeployment.Hostname`;
  - A/AAAA toggles = `PublishIPv4` / `PublishIPv6`;
  - TTL = `RecordTTL`;
  - credential = inline encrypted `CFAPIToken` or a same-node Cloudflare
    `DDNSProfileID`.
- Reject unsafe or incomplete publish inputs:
  - disabled deployment;
  - missing hostname;
  - missing node;
  - missing credential;
  - non-Cloudflare referenced DDNS profile;
  - enabled IP family with no valid node public IP.
- Persist publish status on `DNSDeployment`:
  - `LastIPv4` / `LastIPv6`;
  - `LastAppliedAt` as the latest server-side DNS action timestamp;
  - `LastError` on failure.
- Emit `dns.publish` audit events with `dns_id`, `hostname`, and success flag.
- Extend `maybeTriggerDDNS` so node public IP changes also publish matching
  DNS deployments.
- Add dashboard `Publish` button and last-published IP summary.

## Explicit Non-goals

- No CoreDNS binary download/installation.
- No Cloudflare load balancer / geo-routing / anycast apex automation.
- No separate `LastPublishedAt` field yet in iter-036; iter-037 supersedes this
  by splitting service apply status from DNS publication status.
- No real Cloudflare network call in tests; provider injection covers the
  server contract.

## Security Notes

- Cloudflare credentials remain server-side only. Publish responses and
  dashboard views remain secret-free.
- `DDNSProfileID` reuse is restricted to same-node Cloudflare profiles with a
  stored Cloudflare credential.
- DNS publish does not mutate the reusable DDNS profile's status fields; the
  DNS deployment owns its own last-published state.
- Automatic publication on node IP change skips disabled deployments and
  deployments without a hostname.

## Verification

- `GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work GOCACHE=/private/tmp/lattice-gocache go test ./internal/server -run 'TestDNS'`
- `node --check assets/app.js`
- `node --check assets/dns.js`
- `node --test assets/dns.test.mjs`

## Review Outcome

- Publish stays in the control plane, not the agent, so the least-trust agent
  never receives Cloudflare credentials.
- The implementation deliberately reuses the DDNS provider injection point,
  allowing tests to prove publish behavior without calling Cloudflare.
- Residual model sharp edge: `LastAppliedAt` currently records both service
  apply and DNS publish actions. Add `LastPublishedAt` / `LastPublishError` if
  status UI needs to distinguish them.

## Residuals

- CoreDNS binary provenance/install support was completed in iter-038 with a
  plan-bound HTTPS direct executable URL + SHA-256 mechanism.
- Run a Linux-node E2E proving CoreDNS + nft apply + Cloudflare publish together.
- Richer status grouping for "service running" vs "hostname published" was
  completed in iter-037 by adding separate publish status fields and dashboard
  labels.
