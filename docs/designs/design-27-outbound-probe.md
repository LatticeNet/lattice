# Design 27: outbound probe, a long-lived test engine for pasted outbounds

Status: proposed, nothing built. Written 2026-10-08 as a read-only design for the operator's decision; the engine choice was settled the same day by a side-by-side benchmark (section "Engine benchmark").
Date: 2026-10-08.
Reference: lattice-server `integration` at 90c0eeb (alpha-0.2.2a121), lattice-plugin-vpn-core `integration` at 382be4f (0.11.0-alpha.3), upstream SagerNet/sing-box tag `v1.13.19` (the tag `LatticeNet/sing-box-core` builds for the fleet), MetaCubeX/mihomo branch `Meta` as of 2026-10-08.

## Summary

The operator wants to paste a valid sing-box outbound into vpn-core and learn whether it works and how fast it is, without touching the sing-box that serves users on the control-plane host and without paying a process start for every test.

The proposal is a separate, long-lived program, `lattice-probe`, that embeds sing-box as a Go library. It runs one sing-box instance with no inbounds and creates each pasted outbound inside that instance at runtime, measures it, and removes it. No config file is written, nothing reloads, and the production sing-box on hkg is never involved. lattice-server talks to it over a unix socket and exposes one vpn-core route; vpn-core gets a Probe page and, later, a Test action on every line.

The operator accepts either config syntax and asked for the engine that tests correctly with the least time and resources. Both cores were embedded and measured side by side. They are equally correct and equally fast per test, but sing-box is 40 percent smaller, peaks at less than half the memory under 32 concurrent tests, and leaks nothing, while mihomo strands one QUIC connection on every TUIC test because its TUIC adapter has no `Close`. The probe is built on sing-box alone; a mihomo engine is added only if a protocol sing-box lacks is actually needed. Copying protocol code out of either project is not recommended.

## What the operator asked (2026-10-08)

Paste a legal sing-box outbound, test whether the link is usable and the latency to test URLs; do not share a runtime with the sing-box on hkg, because restarting it often is a nuisance; aim for the best performance; evaluate mihomo; find the easiest way to embed a test that covers every protocol, or lift the core code from either project.

## Facts this design rests on

1. **The plugin backend cannot host an engine.** vpn-core declares `runtime.protocol: stdio-json-v1`. The server's tier-2 runner (`internal/plugin/system_runner.go`, header comment) starts a fresh subprocess per action, bounded by a deadline, and hands it no raw host handles. An engine inside vpn-core would initialise sing-box on every click.
2. **The fleet runs upstream sing-box `v1.13.19`.** `LatticeNet/sing-box-core` is a build recipe, not a source fork: it archives an upstream tag and builds it with a fixed tag set (`with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_acme,with_clash_api,with_tailscale,with_ccm,with_ocm,with_naive_outbound,…,with_v2ray_api`). The local `sing-box` checkout is the `sb` management script, unrelated to the core.
3. **sing-box `v1.13.19` can add and remove outbounds while running.** `adapter/outbound/manager.go` has `(*Manager).Create(ctx, router, logger, tag, type, options)` at line 261 and `Remove(tag)` at 217; `box.Box.Outbound()` returns that manager. `common/urltest/urltest.go:76` has `URLTest(ctx, link, detour N.Dialer) (uint16, error)`, the function behind the Clash API's delay test. `include.Context(ctx)` installs the protocol registries that the JSON decoder needs.
4. **mihomo builds a single proxy from a map.** `adapter/parser.go:11` `ParseProxy(mapping map[string]any)` covers ss, ssr, socks5, http, vmess, vless, snell, trojan, hysteria, hysteria2, wireguard, tuic, shadowquic, ssh, mieru, anytls, sudoku, masque, trusttunnel, openvpn, tailscale and more; `adapter/adapter.go:166` `(*Proxy).URLTest(ctx, url, expectedStatus)`. It depends on MetaCubeX forks of the sing libraries (`metacubex/sing`, `sing-quic`, `sing-vmess`, …), not on sagernet's.
5. **Licences.** sing-box and mihomo are GPL-3.0. lattice-server, lattice-node-agent and lattice-plugin-vpn-core are MIT. Linking either core into an MIT binary would make that binary a GPL work.
6. **Clients.** Sub-Store's client formats are led by sing-box and Clash Meta (mihomo); Surge, Stash, Loon and Shadowrocket follow. A test that passes in one core does not prove the other accepts the same link.
7. **Neither core's built-in URL test fits.** The benchmark found both `urltest.URLTest` (sing-box) and `Proxy.URLTest` (mihomo) send HEAD and return whole milliseconds, and they time different spans (sing-box leaves the dial out for vmess and vless). The probe uses its own `httptrace` timing for cold and warm delay.
8. **Go version.** A module declaring `go 1.24` keeps the pre-1.25 default and ignores the container's CPU limit (GOMAXPROCS came out as 4 under `--cpus 2`). `lattice-probe` declares `go 1.26`.

## Options

| Option | Start cost per test | Touches production sing-box | Fidelity to sing-box JSON | Verdict |
|---|---|---|---|---|
| A. Engine inside vpn-core's backend | full sing-box init per action (fact 1) | no | exact | rejected: no long-lived process, and GPL into an MIT plugin |
| B. Second stock sing-box process, rewrite config and reload per test | reload of every outbound, plus a file write | no | exact | rejected: slow, and concurrent tests fight over one config |
| C. `lattice-probe`: sing-box as a library, outbounds created and removed at runtime | one `Create` and one `Remove` in a running instance | no | exact | **proposed** |
| D. Agent task running a probe binary on a node | one process start per test | no | exact | kept for vantage points (slice P3), not as the default |
| E. Use the production sing-box on hkg through its Clash API | none | **yes** | exact | rejected by the operator's requirement; it also cannot add outbounds without a reload |

Option C is also the only one where the GPL code stays in its own program: `lattice-probe` is a separate repository under GPL-3.0, and the MIT components talk to it over a socket, the same relationship the fleet already has with the sing-box binary.

## Design

### Shape

```
operator ── vpn-core Probe page (iframe) ──► lattice-server  POST /api/vpncore/probe
                                                 │  scope, limits, audit, no secrets stored
                                                 ▼  unix socket /run/lattice-probe/probe.sock
                                           lattice-probe (container, GPL-3.0)
                                             engine "sing-box"  (one box.Box, no inbounds)
                                               Create(outbound) → measure → Remove
                                             engine "mihomo"    (slice P4)
                                                 │
                                                 ▼  egress straight from hkg (or a node, P3)
```

### lattice-probe

A Go module in a new repository `LatticeNet/lattice-probe`, GPL-3.0. It pins `github.com/sagernet/sing-box` at the fleet's tag (`v1.13.19` today) and builds with the client-relevant subset of the fleet's tag set (`with_quic,with_wireguard,with_utls,with_naive_outbound,with_gvisor`; the server-only tags are dropped). Bumping the fleet core and bumping the probe are the same one-line change, so a probe result describes the core the fleet runs.

At start it builds one `box.Box` through `include.Context` with no inbounds, one `direct` outbound as the default, and its own DNS servers with a cache. It then serves a small JSON API on a unix socket. For each request it:

1. decodes the outbounds with the sing-box option registry, exactly as `sing-box check` would, and returns decode errors with their JSON path;
2. creates them in the running box under fresh tags (`probe-<id>-<n>`), in dependency order, so a request may carry a relay and its exit and test the chain;
3. runs the measurements below, all through the created outbound as an `N.Dialer`;
4. removes every outbound it created, on success, error, timeout or cancel.

A semaphore bounds concurrent tests (default 32); each test has an overall deadline (default 15 s) and each sample its own (default 5 s). Requests can be batched; a batch answers as NDJSON, one line per finished test, so a "test all 136 lines" view fills in as results arrive.

### What a test measures

| Measure | How | Why it is separate |
|---|---|---|
| Valid | option decode plus outbound `Create` | a config sing-box refuses never reaches the network |
| Server reachable | plain TCP connect, or a QUIC handshake for QUIC protocols, to `server:server_port` outside the proxy protocol | tells "the host is down or blocked" apart from "the credentials or transport are wrong" |
| Cold delay | HTTP GET of a 204 target through a new proxied connection, timed with `httptrace` from dial start to first response byte | what a user feels on the first request; includes the protocol handshake |
| Warm delay | a second request on the same proxied connection | round trip from the probe through the server to the target, without handshake |
| Samples | N cold and N warm (default 5): min, median, p90, success count | one number hides jitter and loss |
| Exit | GET `https://www.cloudflare.com/cdn-cgi/trace` through the outbound: exit IP, `loc`, `colo` | proves the chain leaves where the operator expects, which matters for relay lines |
| UDP | a DNS query over UDP to `1.1.1.1:53` through `ListenPacket`, for protocols that relay UDP | a line can pass HTTP and still fail every game and QUIC client |
| Throughput (off by default) | download a fixed size from `speed.cloudflare.com` | costs real traffic, so the operator opts in per test |

Many protocols return a connection before talking to the server (vless and vmess send the handshake with the first write), so a bare "dial time" means different things per protocol. Cold and warm delay measured on the HTTP request are comparable across all of them, and the server-reachable probe covers the transport level.

Targets come from a fixed list the operator can extend in settings: `https://www.gstatic.com/generate_204`, `https://cp.cloudflare.com/generate_204`, `https://www.apple.com/library/test/success.html`. A request names targets from that list; it cannot supply a free URL (see Security).

### API between lattice-server and lattice-probe

```json
POST /v1/probe
{
  "engine": "sing-box",
  "outbounds": [ { "type": "vless", "tag": "exit", "server": "…", "server_port": 34656, "…": "…" } ],
  "test": "exit",
  "targets": ["gstatic-204", "cloudflare-204"],
  "samples": 5,
  "udp": true,
  "throughput": false
}
```

```json
{
  "valid": true,
  "server": {"reachable": true, "rtt_ms": 41},
  "targets": [
    {"id": "gstatic-204", "ok": 5, "of": 5,
     "cold_ms": {"min": 212, "p50": 230, "p90": 268},
     "warm_ms": {"min": 74, "p50": 78, "p90": 90}}
  ],
  "exit": {"ip": "162.196.9.138", "loc": "US", "colo": "LAX"},
  "udp": {"ok": true, "rtt_ms": 80},
  "engine": {"name": "sing-box", "version": "1.13.19"},
  "took_ms": 1840
}
```

Errors say which stage failed (`decode`, `create`, `server`, `handshake`, `target`, `timeout`) with the core's own message, cut to one line.

### Deployment on hkg

A container `lattice-probe` beside `lattice-server` in the same compose file, sharing only the socket directory, a small tmpfs volume the compose file creates owned by `65532:65532` with mode `0770` so neither start order nor image content decides its ownership. Limits: 256 MiB memory with `GOMEMLIMIT=192MiB`, 0.5 CPU, `pids` 256, read-only root, no capabilities. The benchmark peaked at 34 MiB with 32 tests in flight; with all 32 also downloading 25 MB each, the probe peaked at 50 MiB RSS on a loopback lab at 0.5 CPU and ran inside a 64 MiB limit. The headroom is for QUIC flow-control windows on long paths, which a loopback lab cannot reproduce. It runs on its own network, not the compose network that reaches lattice-server's port, so a pasted outbound cannot be aimed at the control plane. The image is built in the probe repository's CI and pinned by digest in the compose file, the way lattice-server's image is. The server reads `/v1/health` (engine name, core version, uptime) and shows it on Platform > System.

### lattice-server and vpn-core

lattice-server gains one route, `POST /api/vpncore/probe`, beside the existing vpn-core handlers, with a new scope `vpn:probe`. It checks the request, forwards it over the socket, streams the answer back, and audits `vpncore.probe` with the engine, protocol type, server host and port, a SHA-256 of the canonical outbound JSON, the targets and the outcome. It never stores or logs the outbound itself.

vpn-core gets a Probe layer: a JSON editor that validates against the sing-box option schema, a target picker, samples, UDP and throughput switches, and a result card with the table above. The same request runs from a Test action on a Lines row (slice P2), where vpn-core builds the client outbound from the line's share link, so the test sees what a subscribed client sees.

## Security

- **Credentials.** A pasted outbound carries passwords and UUIDs. It travels only in the request body over TLS to the server and over the local socket to the probe; it is never written to the store, the audit WAL, task records or logs. Results are kept by config hash (slice P2), so a repeated test can be compared without keeping the secret.
- **SSRF.** The probe refuses outbound types that are not proxies (`direct`, `block`, `dns`, `selector`, `urltest`), refuses `detour` to any tag the request did not define, and refuses a `server` that is or resolves to loopback, private, link-local, CGNAT or the hkg host's own addresses, unless the operator sets an explicit allowlist. The engine knows the non-global ranges itself; the host's own public addresses are global, so they reach it through `LATTICE_PROBE_DENY_PREFIXES`, which the compose file sets to the control plane's public addresses. The deny list is checked before the allowlist and also matches an IPv4 address embedded in an IPv4-mapped, NAT64 or 6to4 IPv6 address, so an allowlist can never reopen it. Without it, a run from the probe's bridge network could reach ports the host firewall hides only from outside. Targets come only from the configured list. The container network keeps it away from lattice-server's port even if a check is wrong.
- **Who can reach the socket.** The socket is mode `0660` for uid and gid 65532, and lattice-server's process carries 65532 as a supplementary group. Plugin processes are lattice-server's children and inherit that uid, mount namespace and group, so a plugin process can open the socket directly and skip the `vpn:probe` scope check, the per-operator limits and the audit. The probe's own address policy and in-flight ceiling still apply, and a plugin process already reads everything lattice-server's uid reads, so this adds no reach; it closes when plugin processes get their own uid or a mount namespace without the socket directory.
- **Abuse.** Per principal: at most 4 concurrent tests and 120 per hour by default; throughput tests off unless asked, capped at 25 MB each.
- **Scope.** `vpn:probe` is separate from the scopes that change nodes, because a probe changes nothing but does spend the host's bandwidth and reveals reachability.

## Engine benchmark (2026-10-08)

Both cores were embedded the way the probe would use them and driven by one shared harness against an upstream sing-box `v1.13.19` server in the same container: shadowsocks `2022-blake3-aes-128-gcm`, vmess over websocket, vless with Reality, trojan with TLS, hysteria2 and TUIC v5, with a local 204 target. Container `golang:1.26.4-bookworm`, `--cpus 2 --memory 4g` to resemble hkg, GOMAXPROCS 2, loopback only, generated credentials. sing-box `v1.13.19` with tags `with_quic,with_utls,with_wireguard`; mihomo `v1.19.32`, the latest release tag (2026-09-30), no build tags. Measured on arm64 (Apple M3 under Colima); hkg may be amd64, so absolute numbers will differ there, the comparison should not.

| Measure | sing-box | mihomo |
|---|---|---|
| Stripped binary | 26.1 MB | 43.3 MB |
| Process start to ready (median of 10) | 47 ms | 55 ms |
| Idle RSS after start | 18.7 MiB | 20.3 MiB |
| Create and remove one outbound | tens of microseconds | tens of microseconds |
| Cold and warm delay, 200 runs per protocol | tie on 5 of 6 protocols (p50 within about 0.1 ms) | tie |
| CPU per test | about 0.5 ms; lower than mihomo on vmess, vless/Reality and trojan in all 3 runs (by up to 0.12 ms) | about 0.5 ms |
| 32 workers x 50 mixed tests, 7 runs | 1689 to 2520 tests/s, all 1600 ok | 1828 to 2188 tests/s, all 1600 ok |
| Peak RSS under that load | 34 MiB | 84 to 86 MiB (45 to 47 without TUIC) |
| Goroutines left afterwards | 8 | 1333 |
| After 2000 full tests | flat: 8 goroutines, 10 fds, heap under 0.8 MB | 1718 goroutines, 350 fds, 29 MB heap |

The mihomo growth comes from TUIC alone: `adapter/outbound/tuic.go` at `v1.19.32` defines no `Close`, so `Close()` falls through to `Base.Close`, which returns nil. Each test leaves one QUIC connection behind (one UDP fd, five goroutines, about 82 KiB of heap), and 45 s with a GC every 5 s reclaimed none of it. The other five protocols were flat in both cores. A long-lived probe that creates an outbound per test would grow without bound on TUIC lines.

Correctness was identical. Both passed every valid config in every suite and failed fast on every wrong credential, with no timeouts: shadowsocks and vmess with a connection reset in about 1 ms; vless with a wrong UUID, trojan and TUIC with a bare EOF in 1 to 11 ms (the probe can only say "handshake failed" for these, whichever core); hysteria2 with "authentication failed, status code: 404"; a wrong Reality short_id against a public handshake site in 64 to 96 ms in both, worded differently.

Not measured yet: UDP relay, throughput, the server-reachable check, real network round trips, amd64, and behaviour under the container's 0.5 CPU limit. Slice P0 measures these on hkg's architecture.

The benchmark programs, raw JSON and full tables are kept with the operator's workspace (`~/.cache/lattice-probe-bench/RESULTS.md`) and move into `lattice-probe` with P0.

## mihomo, re-evaluated on performance and resources

The operator accepts Clash syntax, so the input format no longer counts against mihomo; the comparison is speed, correctness and resources. On speed and correctness the two are equal. On resources sing-box wins on every measure that matters for a program that stays running: smaller binary, less than half the peak memory under load, and no leak, against mihomo's unbounded growth on TUIC. mihomo's remaining advantage is protocol breadth (ssr, snell, mieru, sudoku, masque, trusttunnel, openvpn and others sing-box does not have) and being the exact code inside Clash Meta clients.

So the probe ships with the sing-box engine only. A mihomo engine is added, as a second binary behind the same socket API, only when the operator needs to test a protocol sing-box lacks or to reproduce a Clash Meta client's behaviour; before that the TUIC leak must be fixed upstream (a `Close` that closes the QUIC client) or contained by recycling that engine's process after a bounded number of tests. Linking both into one binary would put 43 MB of mostly duplicated protocol code into every probe for the sake of a few protocols, against the operator's resource goal. Lifting protocol code out of either project would freeze it at the day of the copy, while Reality, uTLS and QUIC transports change often, and the copy would still be GPL; importing the module at a pinned tag gives the same code with a one-line upgrade.

## Slices

- **P0, engine (about a day).** `lattice-probe` with the sing-box engine and the socket API, a CLI that tests one outbound file, and the measurements the benchmark left open (UDP, throughput, the server-reachable check, amd64, the 0.5 CPU limit, real round trips to a fleet node). No server or UI change.
- **P1, control-plane probe.** The container on hkg, the server route and scope, the audit event, the vpn-core Probe layer, and System showing probe health. Deploys as a server release plus a vpn-core plugin release.
- **P2, lines.** A Test action on every Lines row using the client outbound from the line's share link, batch "test these lines" with NDJSON results, and a results history keyed by config hash with the last result shown on the row. Design 28 reads this history: every Lines-row result also records the line's `line_uuid` and its template digest, and a scheduled sweep under a system principal tests every line, so the Sub-Store line catalogue's probe block can be filled per line without keeping any credential.
- **P3, vantage points.** The same binary run by the agent on a chosen node, started on demand and stopped after ten idle minutes, so a line meant for China can be tested from `cd-hs-sh`, the node the latency probes already use. The request gains `from: "control-plane" | "node:<id>"`.
- **P4, mihomo engine, only on demand.** A second binary behind the same API, taking Clash proxy maps, built only when a protocol sing-box lacks is needed, and only after its TUIC leak is fixed or its process is recycled after a bounded number of tests.

## Decisions for the operator

1. Create `LatticeNet/lattice-probe` as a GPL-3.0 repository with the sing-box engine only, keeping GPL code out of the MIT repositories. Recommended.
2. Default vantage point for P1 is the control plane (hkg); node vantage arrives in P3. Recommended, with the caveat that a pass from Hong Kong does not prove a line works from mainland China.
3. Results history in P2 keeps the last 30 results per config hash for 90 days and never the config. Recommended.
4. Throughput tests stay off by default and are capped at 25 MB. Recommended.
