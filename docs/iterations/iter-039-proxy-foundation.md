# Iteration 039 — Proxy-Core Foundation

- **Status:** Implemented locally (2026-06-14)
- **Design link:** [`designs/design-01-proxy-cores-and-subscriptions.md`](../designs/design-01-proxy-cores-and-subscriptions.md)
- **Repos:** `lattice-sdk`, `lattice-server`, `lattice`

## Goal

Start Design 01 with the smallest safe foundation: shared proxy-core domain
models, redacted proto views, JSON-store collections, record-level bbolt bucket
parity, and encryption-at-rest for all reversible proxy credentials.

This iteration intentionally does **not** add the public `/sub/{token}` route,
config rendering, agent apply scripts, dashboard CRUD, or sing-box/xray
deployment. Those paths move real traffic or expose public bearer URLs and must
land in later reviewed slices on top of this storage contract.

## Delivered

- Added SDK models for:
  - `ProxyInbound` — central sing-box/xray inbound template.
  - `ProxyUser` — central subscriber identity and quota/expiry state.
  - `ProxyNodeProfile` — per-node render/apply profile.
  - `ProxyUsageSnapshot` — last accounting snapshot per node.
- Added proxy constants for core, protocol, transport, security mode, and user
  status.
- Added proto contract views:
  - `ProxyInboundView`
  - `ProxyUserView`
  - `ProxyNodeProfileView`
  - `ProxyUsageSnapshot`
- Extended proto contract tests so proxy list/read views cannot expose
  `reality_private_key`, `uuid`, `password`, or `sub_token`; views expose only
  `has_*` booleans for secret presence.
- Added JSON-store state collections and CRUD methods:
  - `ProxyInbounds`
  - `ProxyUsers`
  - `ProxyProfiles`
  - `ProxyUsage`
- Added record-level bbolt buckets and methods for the same collections.
- Routed proxy credentials through `internal/store/crypto.go`:
  - `ProxyInbound.RealityPrivateKey`
  - `ProxyUser.UUID`
  - `ProxyUser.Password`
  - `ProxyUser.SubToken`
- Extended lost-key detection so a disabled/missing master key refuses to open
  persisted proxy secrets instead of corrupting them.

## Security Decisions

- The persistent source-of-truth structs are secret-bearing, but proto/API view
  contracts are secret-free. Future handlers must use dedicated view structs or
  the proto shape; they must not serialize `model.ProxyInbound` or
  `model.ProxyUser` directly.
- `ProxyUser.SubToken` is encrypted at rest in this foundation. The future
  public subscription endpoint must add either an opaque SHA-256 token index or
  a constant-time full scan with clear rate limits. It must not make the raw
  subscription token a store key.
- The current slice stores no rendered sing-box/xray config, queues no apply
  task, and opens no public endpoint. Risk is limited to schema/persistence.
- Agent-side configs will necessarily contain per-user credentials in a later
  apply task. That future slice must keep the current plan→approve→apply
  boundary, bind the reviewed plan hash, run `sing-box check`, write atomically,
  and roll back on failure.

## Verification

- `GOCACHE=/private/tmp/lattice-gocache go test ./model`
- `GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work GOCACHE=/private/tmp/lattice-gocache go test -count=1 ./internal/store`
- Targeted store regression run covering proxy, encryption, prefix-colliding
  secrets, bbolt import/export, and record-level proxy collections.

## Review Outcome

Self-review completed before commit. Key checks:

- No proxy secret fields were added to proto views.
- JSON and bbolt persistence both encrypt proxy credentials before writing.
- bbolt import/export includes the new buckets, so Phase C migration cannot
  silently drop proxy state.
- CRUD semantics mirror existing DNS/NetPolicy patterns: timestamps are set on
  upsert, per-node profile keys normalize to `NodeID`, list ordering is stable,
  empty `ProxyUser.InboundIDs` means all inbounds.

## Residuals / Next

1. Add `internal/proxycore` renderer for a minimal sing-box
   `vless+reality+tcp` config, with golden tests and `sing-box check` script
   generation.
2. Add scoped server CRUD APIs and secret-free JSON views:
   `proxy:read`, `proxy:admin`, and per-node allowlist filtering.
3. Add `/api/proxy/nodes/{node_id}/plan` producing a `proxycore` approval,
   then extend the shared apply switch for reviewed proxy apply tasks.
4. Add the public `/sub/{token}` route only after the token lookup design is
   explicit (opaque SHA-256 token index or constant-time scan + rate limit).
5. Add dashboard CRUD after backend API review; do not let the dashboard handle
   raw UUID/password/sub-token except in one-time create/rotate responses.
