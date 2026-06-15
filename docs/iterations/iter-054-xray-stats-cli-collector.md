# Iteration 054 - Dependency-free xray stats collector + collector hardening

- **Date:** 2026-06-14
- **Repos:** `lattice-node-agent`, `lattice-server`, `lattice`
- **Builds on:** iter-046 usage baseline, iter-049 loopback HTTP/V2Ray collector,
  iter-052 collector health, iter-053 xray renderer/apply
- **Decision record:** [ADR-003 — proxy usage stats transport](../adr-003-proxy-stats-transport.md)
- **Status:** Implemented, reviewed, verified

## Goal

Give the node-agent a *real* runtime usage source for xray nodes — the residual
left open by iter-053 — without adding `grpc-go` or any new dependency, and fix
two low-severity hardening gaps found while reviewing the iter-053 proxy code.

## What landed

### ADR-003 (the gating decision)

Collect stats through each core's own on-node tooling instead of linking a gRPC
client:

- **xray** → the agent runs the on-node `xray api statsquery` subcommand; the
  gRPC dial to `StatsService` stays inside the xray process.
- **sing-box** → its HTTP Clash/v2 API, already served by the existing
  `-proxy-usage-url` loopback HTTP source (no new code).

Result: **zero new Go dependencies**, agent stays pure-Go / zero-CGo.

### `lattice-node-agent`

- New `internal/proxyusage/xraycli.go`:
  - `LoadXrayCLI` runs `xray api statsquery --server=<addr> -pattern user>>>
    -reset=false` via an **exec arg-vector (no shell)**.
  - Validates the binary (bare name or absolute path; rejects shell
    metacharacters/control chars), the **loopback-only** `host:port` API address,
    and the optional stat pattern.
  - **Read-only**: never passes `-reset`; the server keeps monotonic diffing.
  - `runBoundedCommand` caps stdout at 1 MiB via a `cappedBuffer` and surfaces a
    bounded stderr snippet on failure.
  - Reuses the existing `int64String` / `v2rayUserFromStatName` parser (xray
    protojson emits int64 as strings). An empty stat set (idle core) is a valid
    empty snapshot, not an error.
  - `ValidateXrayCLISource` allows fail-fast startup validation.
- `cmd/lattice-agent/main.go`:
  - New flags/env: `-proxy-usage-xray-api` (`LATTICE_PROXY_USAGE_XRAY_API`),
    `-proxy-usage-xray-bin`, `-proxy-usage-xray-pattern`.
  - `reportProxyUsage` now selects among **three mutually-exclusive** sources
    (`file`, `http`, `xray-cli`); the xray path reports collector health exactly
    like the others (source label `xray-cli`).
  - `validateProxyUsageConfig` enforces single-source selection and validates the
    xray inputs at startup.

### Review fixes (found while reviewing iter-053)

1. **Collector redirect refusal** (`internal/proxyusage/http.go`): the production
   HTTP client now sets `CheckRedirect` to refuse redirects, so a compromised
   local core cannot 30x-bounce the agent off-loopback. The loopback check only
   validated the initial URL. *Severity: low (operator-configured loopback
   source; counters re-validated server-side), defense-in-depth matching the
   file's stated invariant.*
2. **`config_path` `..` rejection** (`lattice-server` `validateProxyConfigPath`):
   reject any `..` path segment so an approved proxy plan cannot traverse out of
   the intended config directory. Already gated by `proxy:admin` + plan→approve
   review + shell-quoting; this closes the residual traversal vector. *Severity:
   low / hardening.*

## Review verdict on the inherited proxy core (iter-039→053)

Reviewed firsthand: xray renderer, subscription link/format generation, the
reviewed apply-script generator, redaction, plan-hash binding, and the low-trust
usage path. Findings:

- **No injection in the apply script.** All interpolated paths go through
  `shellQuote`; `binary`/`service`/`marker`/`checkCmd` are hardcoded constants;
  the heredoc delimiter is sha256-derived and collision-checked. The
  `heredocWrite(shellQuote(candidate), ...)` call is correct (the server-package
  helper does not re-quote its target).
- **Crown-jewel binding intact.** Apply re-renders the artifact and fails closed
  unless its SHA-256 still matches the approved `apply-config:<sha>` action.
- **Subscription endpoint is secret-free and well-validated** (control-char +
  shell-metachar host checks, URL-encoded output, constant-time token compare,
  duplicate-token fail-closed).
- **Usage path is low-trust** (node id pinned, non-negative, eligible-only,
  monotonic with reset detection, error reports cannot mutate the baseline).

Only the two low-severity gaps above warranted a change.

## Verification

`lattice-node-agent` and `lattice-server`, with the workspace:

```sh
GOWORK=…/lattice/go.work go vet ./...   # both repos
GOWORK=…/lattice/go.work go test ./...  # both repos — all green
gofmt -l <changed files>                # empty
```

Focused coverage:

- xray statsquery arg-vector shape, uplink+downlink summing, empty-stats
  tolerance, loopback/binary/pattern rejection, runner-error surfacing,
  negative-counter rejection, `cappedBuffer` overflow;
- HTTP collector refuses real redirects from a loopback `httptest` server;
- agent config validation: xray loopback ok, remote refused, source conflicts,
  dependent-flag-without-api refused, unsafe binary refused;
- server `validateProxyConfigPath` accepts sane absolute paths and rejects
  `..` traversal, non-absolute, control chars, shell metacharacters, whitespace.

## Residuals & Next

1. **sing-box native stats doc/UX**: confirm the exact Clash/v2 API path and add
   a dashboard hint, even though no new code is needed.
2. **Live enforcement**: remove expired/over-quota users from applied node
   configs through a reviewed apply (today they are hidden from subscriptions
   and alerted on, but remain in the node config until the next plan).
3. **Optional xray binary install/version pinning**, mirroring the CoreDNS
   pinned-install pattern (iter-038).
4. Browser-level dashboard smoke once the sandbox permits localhost listeners.
