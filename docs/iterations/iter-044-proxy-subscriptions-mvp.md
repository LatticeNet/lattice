# Iteration 044 — Proxy Subscription MVP

- **Status:** Implemented + reviewed (2026-06-14)
- **Design:** [`designs/design-01-proxy-cores-and-subscriptions.md`](../designs/design-01-proxy-cores-and-subscriptions.md)
- **Builds on:** [`iter-043-proxy-apply-secret-safe.md`](./iter-043-proxy-apply-secret-safe.md)
- **Repos:** `lattice-server`, `lattice`

## Goal

Expose the first public proxy subscription endpoint for the sing-box
`vless`+TCP+REALITY MVP:

- `GET /sub/{token}` serves a user's active VLESS links across all applied
  proxy node profiles.
- `?format=plain` returns newline-separated links.
- `?format=base64` returns the whole plain body as base64, the default because
  many clients expect it.
- `Subscription-Userinfo` reports upload/download/total/expire so clients can
  display quota and expiry.
- Subscription fetches are rate-limited, audited, and do not require sessions or
  cookies.

## Scope

In scope:

- Dependency-free link encoder in `internal/proxycore`.
- Public `/sub/{token}` handler in `lattice-server`.
- Constant-time subscription-token scan over decrypted `ProxyUser.SubToken`.
- Secret-safe audit metadata: user id, hashed token id, source IP, format, link
  count; never the raw token.
- Tests for link shape, base64/plain formats, inactive users, token miss,
  malformed method, and control-plane secret boundaries.

Out of scope:

- Clash YAML, sing-box client JSON, UA sniffing, and cache. **sing-box JSON and
  Clash/Mihomo YAML were resolved in iter-047 for VLESS+REALITY+TCP; UA sniffing
  and cache remain future work.**
- `/api/proxy/usage` and agent usage reporting.
- Dashboard proxy UI.
- xray renderer.

## Key Decision

Use **constant-time full scan** for the MVP instead of a persisted token index.
The public endpoint is now possible without making raw subscription tokens map
keys or adding another at-rest credential field. This is acceptable for the
current single-operator fleet scale and easy to replace later with an opaque
SHA-256 token index if subscription volume requires it.

The handler deliberately keeps the same response shape for unknown, expired,
disabled, and over-quota users: `404` or empty subscriptions where appropriate,
with no token oracle beyond possession of the unguessable path token.

## Security Notes

- The endpoint is public but token-authenticated; it uses per-source rate
  limiting before scanning credentials.
- No session, cookie, CSRF, or bearer-token path is accepted or required.
- Raw `SubToken`, passwords, and REALITY private keys are never serialized in
  API responses or audit metadata.
- Links necessarily include the user's VLESS UUID and the inbound REALITY public
  material. That is the subscription product, not a control-plane leak.
- A node appears in a subscription only when its profile has a hostname,
  includes the inbound, and has a non-empty `AppliedSHA256`.

## Test Plan

Run from `lattice-server`:

```sh
GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache \
go test ./internal/proxycore ./internal/server -run 'TestVLESSReality|TestProxySubscription|TestProxy' -count=1

GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache \
go test -race ./internal/server -run 'TestProxySubscription|TestProxy' -count=1

GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache \
go build ./cmd/lattice-server
```

## Exit Bar

- A valid token returns importable VLESS subscription data.
- `format=plain` and `format=base64` both work; unsupported formats fail with
  `400`.
- Disabled/expired/over-quota users receive no active links.
- Unknown tokens do not reveal whether any user exists.
- Audit events record successful and failed fetches without raw tokens.
- Docs and roadmap identify dashboard proxy UI, drift detection, usage, and xray
  as remaining work. Dashboard proxy UI and subscription-token rotation were
  resolved in iter-045. Baseline usage reporting was resolved in iter-046; drift
  detection, direct core stats collectors, richer formats, and xray remain
  future work.

## Execution Log

- Added `internal/proxycore/links.go` in `lattice-server`:
  - renders VLESS+TCP+REALITY links from active `ProxyUser`, applied
    `ProxyNodeProfile`, and sing-box `ProxyInbound` state;
  - emits deterministic plain and base64 subscription bodies;
  - emits `Subscription-Userinfo` from server-owned quota/expiry fields;
  - skips inactive users and unapplied/failed profiles without producing stale
    links.
- Added public `GET /sub/{token}` in `internal/server`:
  - no session, cookie, CSRF, or bearer path;
  - dedicated per-source rate limiter before credential scan;
  - constant-time full scan over stored `ProxyUser.SubToken`;
  - raw-token-free `proxy.subscription.fetch` audit events;
  - `Cache-Control: no-store`;
  - `format=base64` default and `format=plain` supported.
- Hardened proxy-user admin upserts:
  - manual `sub_token` duplicates are rejected;
  - generated tokens retry until unique;
  - legacy dirty duplicate tokens make `/sub/{token}` fail closed with `404`.
- Synced long-lived docs:
  - `docs/designs/README.md`
  - `docs/designs/design-01-proxy-cores-and-subscriptions.md`
  - `docs/roadmap.md`
  - `docs/PRODUCT-VISION.md`
  - root `README.md`

## Review Outcome

- **Security posture:** acceptable for MVP. The public surface is token-only,
  rate-limited before token scanning, does not accept cookies/sessions, avoids
  raw-token audit metadata, and fails closed on duplicate stored tokens.
- **Secret boundaries:** subscription responses necessarily include the VLESS
  UUID and REALITY public parameters; tests assert they do not include
  subscription tokens, proxy passwords, or REALITY private keys. Admin list views
  remain secret-free.
- **Forward compatibility:** no new dependency, no persisted raw-token index,
  and no node-agent API change. Future hash-index optimization can be added
  later without changing the public URL shape.
- **Tradeoff recorded:** constant-time full scan is simpler and safer than an
  at-rest index at current fleet scale. If subscription QPS grows, replace it
  with a stored SHA-256 token index, never a raw token key.

Verification:

```sh
GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache \
go test -count=1 ./internal/proxycore ./internal/server \
  -run 'TestVLESSReality|TestProxySubscription|TestProxy'

# ok github.com/LatticeNet/lattice-server/internal/proxycore
# ok github.com/LatticeNet/lattice-server/internal/server

GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache \
go test -race -count=1 ./internal/server -run 'TestProxySubscription|TestProxy'

# ok github.com/LatticeNet/lattice-server/internal/server

GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache \
GOPROXY=off \
go build ./cmd/lattice-server

# exit 0; sandbox prints a non-fatal Go module stat-cache write warning under
# /Users/cdcd/go/pkg/mod/cache because that cache is read-only in this session.
```

The broader `go test ./internal/server` run still cannot complete in this
sandbox because `TestOIDCEndToEndLogin` uses `httptest.NewServer`, and local
port bind is denied (`bind: operation not permitted`). This is an environment
limit unrelated to the subscription code; targeted server tests above cover the
new surface.

## Residual Risks / Next

- Dashboard proxy UI is still missing, so operators must create/read proxy
  inbounds/users/profiles via API for now. **Resolved in iter-045** with the
  first dashboard Proxy Core panel.
- No token rotation endpoint yet; add `/api/proxy/users/rotate-sub-token`
  before treating public subscription URLs as long-lived production secrets.
  **Resolved in iter-045** with an explicit, audited rotate response that
  returns the new URL once and invalidates the old token.
- Usage reporting is not live; `Subscription-Userinfo` reflects stored
  `ProxyUser.UsedBytes`, but no agent proxy-usage reporter updates it yet.
  **Resolved in iter-046** with `/api/agent/proxy-usage`, monotonic rollup, an
  agent file bridge, and dashboard usage display.
- No Clash YAML or sing-box client JSON output yet; plain/base64 VLESS links
  are the MVP only. **Resolved in iter-047** for the supported
  VLESS+REALITY+TCP shape with `format=sing-box`, `format=clash`, and
  `format=clash-meta`.
- At the time of this slice, xray rendering was still out of scope.
  **Resolved in iter-053** for the shared VLESS+REALITY+TCP shape, with xray
  render/plan/apply and subscription inclusion for applied xray profiles.
- Optional future optimization: stored SHA-256 subscription-token index keyed by
  token hash, with an ADR if it adds a new secret-at-rest class.
