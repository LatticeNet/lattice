# ADR-003 — Proxy usage stats transport (no new dependency)

- **Status:** Accepted
- **Date:** 2026-06-14
- **Supersedes/Refines:** the "true sing-box/xray API transport" residual from
  iter-049/iter-053
- **Related:** [design-01-proxy-cores-and-subscriptions](designs/design-01-proxy-cores-and-subscriptions.md),
  iter-046 (usage baseline), iter-049 (loopback HTTP/V2Ray collector foundation),
  iter-052 (collector health)

## Context

Lattice needs accurate per-user traffic accounting from each proxy node to drive
quota/expiry enforcement, subscription `Subscription-Userinfo`, and operator
dashboards. The accounting model is already low-trust and server-owned: the agent
reports **cumulative per-user byte counters**, and the server does monotonic
diffing, eligibility filtering, reset detection, and audit (`applyProxyUsageSnapshot`).

What was missing was a *real* runtime source for those counters. iter-046/049
shipped a file source and a loopback HTTP source that can read a snapshot or a
V2Ray-style `{"stat":[...]}` body, but nothing yet drove the two cores' native
stats APIs directly.

The open question — explicitly flagged as a residual in iter-053 — was whether
collecting xray stats forces a new Go dependency. Xray's `StatsService` is a
gRPC service; the obvious client is `google.golang.org/grpc` (`grpc-go`). Adding
it would be a large dependency-surface increase and would trip the project rule
that **every new dependency needs an ADR** (pure Go, zero CGo, tiny dep surface,
security-first).

## Decision

**Do not add `grpc-go` (or any new module). Collect stats through each core's own
on-node tooling.**

1. **Xray → invoke the on-node `xray` binary's `api statsquery` subcommand.**
   The agent shells out (exec arg-vector, no shell) to:

   ```
   xray api statsquery --server=<loopback host:port> -pattern user>>> -reset=false
   ```

   The gRPC dial to `StatsService.QueryStats` happens **inside the xray
   process**. The agent only parses the JSON the CLI prints
   (`{"stat":[{"name":"user>>>ID>>>traffic>>>uplink","value":...}]}`). xray's
   protojson encodes int64 as a string; the existing `int64String` /
   `v2rayUserFromStatName` parser already tolerates both numbers and strings, so
   no new parsing code is needed either.

2. **sing-box → its HTTP Clash/v2 API**, which is plain HTTP+JSON and is already
   covered by the existing loopback HTTP source (`-proxy-usage-url`). No new
   transport code is required for sing-box; operators point the HTTP source at
   the core's local API.

Both transports are **loopback-only**, **read-only** (xray is queried with
`-reset=false`; the server owns diffing), **bounded** (output is size-capped),
and **fail-closed** (errors surface as collector-health reports, never as a
silent zero that would corrupt the monotonic baseline — see iter-052).

The xray `email` rendered into each VLESS client is the stable `ProxyUser.ID`
(iter-053), so `user>>>ID>>>traffic>>>...` maps cleanly back to a server-owned
user; non-eligible / unknown IDs are ignored server-side.

## Why not grpc-go

- **Dependency surface.** `grpc-go` pulls a large transitive tree
  (`golang.org/x/net/http2`, protobuf runtime, etc.) into the *agent*, the most
  trust-sensitive binary. The CLI path keeps the agent's module graph tiny.
- **Same trust boundary, less code.** The CLI returns exactly the data the
  existing parser consumes. A gRPC client would re-implement what the xray
  binary already does, with more attack surface.
- **Operational parity.** The node already has the `xray` binary installed (it
  is what we deploy configs to). Reusing it needs no extra artifact.
- **Reversibility.** If a future need (e.g. high-frequency online-user stats)
  genuinely requires the gRPC API, this ADR can be revisited with a new ADR that
  scopes `grpc-go` to an optional build tag — but that is explicitly **not**
  needed for byte-counter accounting.

## Consequences

- The node-agent gains a third usage source kind, `xray-cli`, alongside `file`
  and `http`. The three remain mutually exclusive per node.
- Operators must enable xray's API inbound + `StatsService` and bind it to
  loopback (e.g. `127.0.0.1:10085`), and ensure each user has an `email`
  (Lattice always renders one). Without `email`, xray emits no per-user stats —
  documented as an operator prerequisite.
- No change to the server contract: the agent still POSTs a
  `model.ProxyUsageSnapshot` to `/api/agent/proxy-usage`.
- `go.work`/`go.mod` dependency sets are unchanged. CI's dependency-surface
  expectations hold.

## Status of implementation

- `xray-cli` collector + 3-way source selection + fail-fast config validation:
  **iter-054**.
- sing-box HTTP API: already usable via the existing `-proxy-usage-url` source;
  no code change required.
- Live over-quota/expired reconcile (removing disabled users from applied node
  configs via a reviewed apply) remains a separate, later slice.
