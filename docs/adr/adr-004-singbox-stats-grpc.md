# ADR-004: sing-box per-user stats via a vendored gRPC client in the node-agent

> Status: accepted 2026-07-19 (operator decision in the design-15 program).
> Context: design-15 §8, ADR-003 (xray stats transport).

## Context

design-15 §8 requires per-user traffic accounting for adopted sing-box nodes.
sing-box exposes per-user counters (`user>>><name>>>>traffic>>>uplink/downlink`)
only through its **experimental V2Ray Stats API**, which is gRPC
(`experimental.v2rayapi.StatsService`). There is no HTTP alternative on adopted
nodes: the Clash API reports live connections and global traffic only, the SSM
API covers Shadowsocks alone, and s-ui-style connection tracking requires
embedding the core.

The project's standing constraint is "pure Go, zero CGo, every new dep needs an
ADR". The node-agent previously needed no gRPC: ADR-003 chose the `xray api
statsquery` CLI for xray. sing-box has no equivalent CLI stats subcommand.

## Decision

1. The node-agent gains a sing-box stats collector using **gRPC over loopback**
   against the core's experimental API. Two new module dependencies:
   `google.golang.org/grpc` and `google.golang.org/protobuf`. No CGo is
   involved; both are pure Go.
2. The proto is **vendored**: `internal/proxyusage/singboxstats/stats.proto` is
   the sing-box upstream definition (service/messages byte-identical, only
   `go_package` adjusted), with generated code produced by
   `protoc-gen-go`/`protoc-gen-go-grpc` at development time — never at build
   or install time. Regeneration is a documented one-liner.
3. The collector is **off by default**, enabled per node with
   `LATTICE_SINGBOX_STATS_API=127.0.0.1:8080` (loopback only in this design;
   the server-rendered config fragment binds the API to loopback). It issues
   read-only `QueryStats(patterns:["user>>>"], reset:false)` calls — counters
   stay monotonic; the server keeps its successive-snapshot diffing, exactly
   like the xray path.
4. Name reversal stays server-side: the agent reports counters keyed by the
   on-box `users[].name` (design-15 §5 `u_<sha256(user|line_uuid)[:16]>`); the
   server recomputes the same names from its VpnUser×line index and folds them
   into the existing `line_user_bytes` accounting. Unmatched names are counted
   as ignored — never reported as zero traffic.

## Consequences

- The agent's dependency tree grows by gRPC+protobuf (pure Go, no CGo). The
  attack surface added is a loopback, read-only, optional client.
- If sing-box upstream changes the experimental API, the vendored proto and
  the collector fail closed (collector reports an error status; accounting
  baselines are never overwritten — same discipline as ADR-003).
- Alternatives rejected: embedding sing-box as a library (largest blast
  radius), Clash-API sampling (not cumulative per user), a separate node-side
  exporter process (another component to deploy and secure).
