# Iteration 049 - Proxy Usage Loopback HTTP Collector

- **Date:** 2026-06-14
- **Repos:** `lattice-node-agent`, `lattice`
- **Builds on:** iter-046 proxy usage reporting baseline, iter-048 focused proxy apply UI
- **Status:** Implemented, reviewed, verified

## Goal

Move proxy usage collection beyond the manual file bridge without widening the
agent trust boundary or adding a gRPC dependency. The node-agent should be able
to fetch a local JSON usage source each loop, normalize it into the existing
`ProxyUsageSnapshot` contract, and post it to `/api/agent/proxy-usage`, while
the server remains the authority for monotonic diffing, eligibility filtering,
quota status, and audit.

This is a **collector foundation**, not the final direct sing-box/xray gRPC
adapter. It keeps the transport stdlib-only and loopback-only, but the parser
already accepts V2Ray-style stats names so a later sing-box/xray API adapter can
reuse the conversion logic.

## Scope

`lattice-node-agent`:

- Add `internal/proxyusage.NormalizeSnapshot` shared by file and HTTP sources.
- Add `internal/proxyusage.LoadHTTP` with:
  - loopback-only `http://` / `https://` URL validation;
  - userinfo rejection;
  - optional `Authorization: Bearer <secret>` to the local source;
  - request timeout (default `3s`);
  - 1 MiB response cap;
  - support for direct `ProxyUsageSnapshot`, `{"snapshot": ...}`, and
    V2Ray-style `{"stat":[...]}` JSON.
- Add agent flags/env:
  - `-proxy-usage-url` / `LATTICE_PROXY_USAGE_URL`
  - `-proxy-usage-secret` / `LATTICE_PROXY_USAGE_SECRET`
  - `-proxy-usage-secret-file` / `LATTICE_PROXY_USAGE_SECRET_FILE`
  - `-proxy-usage-timeout` / `LATTICE_PROXY_USAGE_TIMEOUT`
- Keep `-proxy-usage-file` as the stable file bridge.
- Make file and URL sources mutually exclusive to avoid double-counting or
  ambiguous cumulative-counter semantics.
- Update node-agent README with both source modes and accepted response shapes.

## Security Decisions

- **Loopback only.** A node-agent may fetch only `localhost`, `127.0.0.0/8`, or
  `::1`; remote hosts are rejected before any request is sent. This prevents the
  feature from becoming an SSRF primitive or leaking a local API secret off-host.
- **No URL userinfo.** Secrets must not be embedded in URLs. Persistent service
  deployments should use `-proxy-usage-secret-file` or a service-manager secret
  path instead of command-line `-proxy-usage-secret`, because process arguments
  and shell history are not an acceptable place for long-lived local API
  secrets.
- **Bounded I/O.** The collector has a default `3s` timeout and 1 MiB body cap.
- **Server remains authoritative.** The agent only reports cumulative counters.
  The server still overrides node identity from the authenticated request,
  filters eligible users per node profile, diffs monotonically, updates quota
  state, and audits aggregate usage.
- **No new dependency.** The slice intentionally avoids `grpc-go`. sing-box/xray
  V2Ray API transport is deferred until a supported version/API surface is
  pinned and an ADR can justify any dependency.

## Supported Input Shapes

Lattice snapshot:

```json
{
  "core_uptime_sec": 12345,
  "user_bytes": {
    "alice": 1048576,
    "bob": 2097152
  }
}
```

Envelope:

```json
{
  "snapshot": {
    "core_uptime_sec": 12345,
    "user_bytes": {
      "alice": 1048576
    }
  }
}
```

V2Ray-style stats:

```json
{
  "stat": [
    {"name": "user>>>alice>>>traffic>>>uplink", "value": 1048576},
    {"name": "user>>>alice>>>traffic>>>downlink", "value": 2097152}
  ]
}
```

The V2Ray-style parser sums `uplink` and `downlink` per `user>>>...>>>traffic`
record and ignores unrelated inbound/outbound stats.

## Verification

From `lattice-node-agent`:

```sh
GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache-agent \
go test ./...

GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache-agent \
go build ./cmd/lattice-agent

git diff --check
```

Result: all node-agent tests passed, the agent binary built, and whitespace
check passed. The Go tool printed a non-fatal module stat-cache warning when it
tried to write under `/Users/cdcd/go/pkg/mod/cache`; command exit code was 0.

Focused tests cover:

- local URL allow/deny rules;
- remote URL rejection before transport runs;
- Bearer header handling;
- secret-file loading and conflict validation;
- response size cap;
- direct/enveloped Lattice snapshot decoding;
- V2Ray-style stats decoding;
- negative and malformed counter rejection;
- file/url source conflict validation.

## Residuals & Next

1. Add a true sing-box/xray API transport after pinning the supported API:
   likely V2Ray stats gRPC for per-user counters. This probably needs an ADR
   if it introduces `grpc-go`.
2. Collector health/error state landed in iter-052. The agent now reports local
   collector failures to the server without mutating the accounting baseline.
3. Quota/expiry/usage notifications landed in iter-050 through
   `internal/notify`.
4. Subscription import-helper UX for `plain`, `base64`, `sing-box`, and
   `clash-meta` landed in iter-051.
5. Add xray renderer and `xray test -c` apply path behind the same model.
