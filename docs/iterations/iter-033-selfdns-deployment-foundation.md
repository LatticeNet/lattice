# Iteration 033 — Self-host DNS Deployment Foundation

- **Date:** 2026-06-14
- **Status:** Complete
- **Design reference:** `docs/designs/design-02-self-host-dns.md`
- **Repos:** `lattice-sdk`, `lattice-server`, `lattice-dashboard`, `lattice`

## Goal

Start Design 02 with the durable, security-sensitive foundation: a server-owned
`DNSDeployment` intent model, encrypted credential storage, scoped CRUD API,
secret-free dashboard/API views, and a small dashboard admin panel. This makes
DNS topology manageable before any privileged CoreDNS/nft apply path exists.

## Scope

- Add shared `model.DNSDeployment`, `DNSZone`, and `DNSRecord` types with
  CoreDNS/mesh/public/status constants.
- Add `DNSDeploymentView` to the proto contract as a redacted read model.
- Persist `DNSDeployments` in the JSON state store and the experimental bbolt
  bucketized store.
- Encrypt `DNSDeployment.CFAPIToken` at rest and extend lost-master-key
  detection.
- Add `GET/POST /api/dns/deployments` and
  `POST /api/dns/deployments/delete`.
- Enforce `dns:admin` plus per-node PAT allowlists against the deployment
  `node_id`.
- Validate and normalize engine, exposure, listen port, hostname, record TTL,
  forward upstreams, and static A/AAAA/CNAME records.
- Preserve the inline Cloudflare token as a write-only field on update; list and
  create responses expose only `has_credential`.
- Add a dependency-free dashboard Self-host DNS panel for listing, editing,
  deleting, and creating a single-zone deployment intent.

## Explicit Non-goals

- No CoreDNS config renderer yet.
- No `/api/dns/plan`, `/api/dns/publish`, or agent apply script yet.
- No automatic mutation of `NFTInputs` yet.
- No Cloudflare record publication yet; the stored credential and hostname are
  only intent state until the next Design 02 slice.
- No multi-zone dashboard editor yet. The API model supports multiple zones; the
  current UI is a safe single-zone MVP.

## Security Notes

- `cf_api_token` never appears in dashboard read views, proto views, tests, or
  JSON API list responses.
- The store encrypts the DNS Cloudflare token through the same AES-256-GCM
  boundary used for DDNS/OIDC/notify/MachineProfile secrets.
- If a deployment references an existing `DDNSProfile`, the inline token is
  cleared and credential ownership stays with DDNS.
- Hostname publishing requires either `cf_api_token` or `ddns_profile_id`.
- DNS config-shaped values are validated before persistence to avoid later
  CoreDNS config injection: names reject control characters/braces/slashes;
  upstreams must be IP/IP:port/tls://IP forms; static records require typed
  value validation.
- Operators cannot create or move a deployment to a node outside their PAT
  server allowlist.

## Verification

- `GOCACHE=/private/tmp/lattice-gocache go test ./...`
- `GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work GOCACHE=/private/tmp/lattice-gocache go test ./internal/store`
- `GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work GOCACHE=/private/tmp/lattice-gocache go test ./internal/server -run 'TestDNSDeployment'`
- `GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work GOCACHE=/private/tmp/lattice-gocache go build ./cmd/lattice-server`
- `node --check assets/app.js`
- `node --check assets/dns.js`
- `node --test assets/*.test.mjs`

Broader `go test ./internal/store ./internal/server` was also attempted:
`internal/store` passed, while `internal/server` is currently constrained by
the sandbox because `TestOIDCEndToEndLogin` uses `httptest.NewServer` and the
environment rejects local TCP binds (`bind: operation not permitted`). Server
build exits successfully; Go still prints a user-module stat-cache warning in
this sandbox because `/Users/cdcd/go/pkg/mod/cache` is not writable.

## Review Outcome

- **Blocking findings:** none after local review.
- One validation edge was tightened during review: a forward zone whose upstream
  list normalizes to empty is rejected instead of being stored as an empty
  forwarder.
- The deployment API is deliberately CRUD-only in this slice. That avoids a
  false sense that DNS apply, nft opening, or Cloudflare publication are already
  operational.

## Residuals

- Implement `internal/selfdns` renderer: CoreDNS Corefile generation, strict
  config grammar validation, and pinned binary metadata.
- Add `/api/dns/plan` that renders CoreDNS config plus the composed
  `lattice_guard` nft delta into one reviewed approval.
- Extend the high-risk apply path with `Plugin: "selfdns"` while preserving
  plan-hash binding and rollback/selfcheck behavior.
- Reuse `internal/ddns` for Cloudflare record publication and the node IP-change
  trigger.
- Compose DNS port exposure into the single persisted `NFTInputs`/Network Guard
  render.
- Add dashboard plan/publish controls only after those backend paths are real.
