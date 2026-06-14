# Iteration 047 - Proxy Subscription Formats

- **Status:** Implemented, verified, reviewed (2026-06-14)
- **Builds on:** [`iter-046-proxy-usage-reporting.md`](./iter-046-proxy-usage-reporting.md)
- **Design link:** [`design-01-proxy-cores-and-subscriptions.md`](../designs/design-01-proxy-cores-and-subscriptions.md)
- **Repos touched:** `lattice-server`, `lattice`

## 1. Goal

Make the proxy subscription endpoint useful for more real clients without
expanding the trust boundary: keep the iter-044 public `/sub/{token}` route,
but add structured subscription output for sing-box and Clash/Mihomo clients.

This closes the "richer subscription formats" residual from iter-044 through
iter-046 for the currently supported protocol shape: **sing-box-managed
VLESS + TCP + REALITY**.

## 2. Scope

Implemented:

- `GET /sub/{token}?format=sing-box`
  - returns `application/json; charset=utf-8`;
  - emits a minimal sing-box client `outbounds` document;
  - includes VLESS fields, `tls.utls`, and `tls.reality.public_key/short_id`.
- `GET /sub/{token}?format=clash`
  - returns `text/yaml; charset=utf-8`;
  - emits a Clash/Mihomo `proxies:` list;
  - includes `client-fingerprint`, `reality-opts`, `packet-encoding: xudp`,
    and `encryption: ""`.
- `GET /sub/{token}?format=clash-meta`
  - same Clash/Mihomo YAML body.
- Aliases: `clash.meta` and `clashmeta`.
- A shared `VLESSRealityEndpoint` projection in `internal/proxycore` so every
  format is derived from one validated, secret-free endpoint model.
- API-level support for `ProxyInbound.Fingerprint` now that client subscription
  output can consume it; it is validated as a conservative safe token.

Kept as-is:

- `format=base64` remains the default.
- `format=plain` remains newline-joined VLESS links.
- `Subscription-Userinfo`, rate limiting, constant-time token scan,
  duplicate-token fail-closed behavior, and hashed-token audit metadata are
  unchanged.

Out of scope:

- xray renderer/subscription output.
- VMess/Trojan/Shadowsocks/Hysteria2 links.
- User-Agent sniffing.
- Subscription body cache.
- Direct sing-box or xray stats collection.
- End-to-end import tests against real GUI clients.

## 3. Design

The important design decision is that subscription formats do **not** each parse
control-plane structs directly. The server first renders:

```go
type VLESSRealityEndpoint struct {
    Label       string
    Tag         string
    NodeID      string
    InboundID   string
    Server      string
    ServerPort  int
    UUID        string
    Flow        string
    Network     string
    SNI         string
    Fingerprint string
    ALPN        []string
    PublicKey   string
    ShortID     string
}
```

This view intentionally contains only client subscription material. It does not
carry `SubToken`, user password, or REALITY private key. Plain/base64 links,
sing-box JSON, and Clash/Mihomo YAML are all emitted from this one view.

The YAML output is hand-written because the shape is fixed and Lattice keeps a
strict minimal-dependency policy. Strings are quoted with `strconv.Quote`, which
is valid for YAML double-quoted scalars and prevents injection through labels,
hosts, SNI, ALPN, UUIDs, or public keys.

## 4. Security Notes

- The public route still authenticates only by the unguessable subscription
  token. No session or CSRF path was added.
- Raw subscription tokens remain absent from audit metadata and storage keys.
- Newly added formats are covered by leak tests for:
  - REALITY private key;
  - proxy password;
  - raw subscription token;
  - `sub_token` JSON field name.
- `ProxyInbound.Fingerprint` is now accepted by the API, but only when it
  matches `^[A-Za-z0-9_.-]{1,64}$`.
- The subscription endpoint still uses `Cache-Control: no-store`.
- sing-box JSON is marshaled through typed structs, not string templates.
- Clash/Mihomo YAML is generated from validated fields and quoted scalars, not
  free-form YAML fragments.

## 5. Verification

Run from `Lattice/lattice-server` with:

```sh
GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work
GOCACHE=/private/tmp/lattice-gocache
```

Verified:

```sh
go test -count=1 ./internal/proxycore ./internal/server -run 'TestVLESSReality|TestProxySubscription|TestProxyInboundAndUserViewsHideSecrets|TestProxyUpdatePreservesWriteOnlySecrets'
go test -count=1 ./...
go test -race -count=1 ./internal/proxycore ./internal/server -run 'TestVLESSReality|TestProxySubscription'
GOPROXY=off go build -o /private/tmp/lattice-server-iter047 ./cmd/lattice-server
git diff --check
```

Notes:

- The offline build exits 0 in this sandbox but prints a non-fatal Go stat-cache
  warning because the toolchain tries to write under `/Users/cdcd/go/pkg/mod`.
- Direct client import validation against actual sing-box/Mihomo binaries is
  still pending. The emitted field names were checked against the official
  sing-box and Mihomo documentation before implementation.

## 6. Review Outcome

Local security/code review found no blocker after implementation. One
correctness issue was fixed during review: the server API still rejected
`fingerprint` with an old "future subscription slice" error. Since this slice
now consumes `fingerprint`, the API now accepts a constrained safe token and
tests cover both normal preservation and unsafe rejection.

The key invariant to preserve in future edits:

> Do not render any public subscription format directly from secret-bearing
> control-plane structs. Add fields to `VLESSRealityEndpoint` or a future
> protocol-specific endpoint projection first, then render from that projection.

## 7. Residuals & Next

Recommended next proxy slices:

1. Focused dashboard proxy apply UI so operators do not have to use the generic
   approvals panel for proxycore diffs.
2. Direct sing-box stats collector in the node-agent, behind the existing
   `ProxyUsageSnapshot` contract.
3. Usage threshold/expiry notifications through `internal/notify`.
4. Subscription format import helpers and optional User-Agent sniffing.
5. xray renderer and `xray test -c` apply path behind the same model.

