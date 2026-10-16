# Design 29: Monitoring paths, operator-defined checks between nodes with a week of history

Status: proposed 2026-10-16; the operator asked for this work and granted release authority the same day (`PROGRAM.md` Decisions 2026-10-16). Slices M1 to M4 below.
Date: 2026-10-16.
Reference: lattice-server `integration` at a6caff4 (alpha-0.2.2a124), lattice-dashboard `integration` at 2ce7dd2, lattice-node-agent `integration` at c8c3a8f, lattice-sdk `integration`, umbrella at 4608e85.

## Summary

Monitoring today answers one question well (is something down right now) and the rest poorly. Latency checks run from one node, `cd-hs-sh`, and can only dial a node's sing-box TCP line port, so a node without a TCP line cannot be a target and a NAT node, whose public port differs from its listen port, shows as unreachable when it is fine. Five of 33 targets read "failed" on production on 2026-10-16 for that reason. History exists in the hot store but the console shows at most a single-source matrix and a per-pair column chart with p50, p95 and loss; operator monitors have no history view and cannot be edited.

This design makes a **path** (one source probing one target with one method) the unit of monitoring, lets the operator define the sources, the targets and the method, keeps a week of five-minute history by default (settable from 3 to 30 days), and shows fluctuation: median, spread, jitter and loss on one time axis, with gaps drawn as unknown. Every node can carry a **beacon**, a small authenticated UDP responder inside the agent that answers only probes signed for it, at a port and public address the operator sets per node. Because the beacon is the first thing an agent ever listens on, the doctrine sentence "nodes run an outbound-only agent" is amended in this design, and the beacon is off until an approved plan turns it on for a node.

## What the operator asked (2026-10-16)

The Monitoring pages work, but the presentation and the history of fluctuation are missing. The operator wants to define a set of probes: every agent has a port or path that can be probed, which may differ per node, possibly with authentication, convenient to reach but safe from attack; the operator can have agent A probe agent B and define the source and target combinations; at least the last three days of data are kept, extendable to seven; the framework that added the `cd-hs-sh` latency probes should be the basis. Optimise the Monitoring pages end to end: UI, UX, logic and the data framework.

## Facts this design rests on

Read from the `integration` checkouts on 2026-10-16; file and line references are in the survey recorded in the vault ledger of that date.

1. **Checks.** `model.Monitor` kinds are `tcp` and `http` (run on agents) and `tls` (run on the server). `icmp` is a constant the server refuses to create. POST always mints a new id; there is no edit route. Defaults 30 s interval, 5 s timeout. HTTP counts any status under 400 as up and carries no headers.
2. **Latency probes.** `LatencyProbeConfig` in `state.json` lists source node ids (default `cd-hs-sh`), an "overseas" auto-target rule, include and exclude lists and disabled pairs. A planner every 2 minutes turns it into one generated `tcp` monitor per target, shared by every source, dialing that target's sing-box TCP line port on its public IPv4 and never port 22, an sshd port or a knock-gated port. A node with no TCP line is "not probeable".
3. **Agent.** The agent never listens. Each cycle (10 s) it pulls `/api/agent/monitors`, runs one goroutine per monitor (TCP dial, HTTP GET), and posts batched results; the queue is in memory, 2000 results. It has no `CAP_NET_RAW`. No node-side veto covers monitors.
4. **Storage.** With the hot store on (production), results live in `state-hot.db` (bbolt): raw rows capped at 1440 per pair, histogram rollups at 5 minutes for 48 hours and 1 hour for 8 days, one latest record and fail streak per pair. A result stamped more than 24 hours old is refused. metricsdb holds no monitor data.
5. **Already pair-shaped.** Rows, rollups and the latest record are keyed by (monitor, source node). What is missing is first-class configuration of pairs, per-pair targets and a history API for anything but generated latency monitors.
6. **Console.** `MonitoringView.vue` has four layers (Incidents, Topology, Monitors, Latency). Charts are hand-written SVG; `uplot` is in `package.json` and imported nowhere. Latency windows are 1 h, 24 h and 7 d. Polling is 8 to 30 s.
7. **NetGuard** can allow a port from a `node` remote (pinned to that node's WireGuard and public /32s) or a zone of CIDRs; ICMP is already accepted by the fixed scaffold. Applying a ruleset is a plan with approval.

## Decisions

### D1. The unit is a path; checks own their paths

A **check** is the existing `Monitor`, extended: one method, one target, one or more sources, expectations, interval and an alert policy. Each (check, source) is a **path** with its own series, state and history, which is what the store already keys by. A **path set** is the existing latency configuration, renamed and generalised: a rule (sources times targets, with include, exclude and disabled pairs) that the planner expands into generated checks. Operators can still create a single check by hand. Rejected: a new `Check` type beside `Monitor`, which would mean migrating stored rows and two result paths for one concept.

Changes to `model.Monitor`:

- `kind` gains `icmp` (agent, unprivileged echo) and `beacon` (agent, UDP to a node's beacon).
- `target` may be a node reference `{ "node": "<id>" }` instead of an address; the server resolves it per method (beacon endpoint, public address for `icmp`, line port for `tcp`) every planner pass, so a moved IP or a new NAT mapping follows without editing checks.
- `sources` is an explicit list of node ids plus the literal `control-plane` (the server process dials; used for `tls` today and allowed for `tcp`, `http` and `icmp` from hkg).
- HTTP expectations: status set or ranges (default 200 to 399), optional body needle (at most 256 bytes, first 64 KiB, reported as true or false), optional request headers whose values are write-only secrets (stored like channel secrets, never returned).
- `packets` for `icmp` and `beacon` (1 to 10, default 5, 200 ms apart), so one run yields loss and jitter, not just one RTT.
- `alert`: `off`, `down` (after N failed runs, default 2, as today) or `down_and_degraded` (adds a degraded state, D6).
- An edit route (`PUT /api/monitors/{id}` with an optimistic version), which also covers pausing a single path.

### D2. Methods, in order of preference for node targets

1. **beacon** when the target has an enabled beacon: measures the network path to the node itself, works for every node whatever lines it serves, and works through NAT because the advertised endpoint is configured per node.
2. **icmp** when it has none: kernel-answered, so nothing new listens; may be filtered by providers, in which case the path reads unknown with that reason rather than down.
3. **tcp** to a line port, today's behaviour, kept so existing paths and their history continue.

A path set picks the first method its target supports unless the operator pins one. Existing generated checks keep their ids; when a target gains a beacon, the planner adds a beacon check beside the tcp one and pauses the tcp one, so the history of both survives and the console labels the switch on the chart.

### D3. The beacon: an authenticated, silent UDP responder

The operator asked for a probe-able port per agent that is convenient but safe. The strongest case against is the doctrine: Lattice's agent only dials out, and a listener is new attack surface on every node, a fingerprint that says "this host runs Lattice", and a new parser exposed to the internet. The strongest case for is that no other method measures the path to every node: line ports exist only where sing-box serves TCP, ICMP is often filtered, and NAT breaks both. The design takes the beacon, opt-in, with these properties:

- **Silence.** A datagram that is not a well-formed, correctly signed, fresh request for this node gets no reply and no log line. To a scanner the port looks filtered. There is no TCP listener and no banner.
- **No amplification.** A reply is never larger than its request (requests are padded to a fixed 96 bytes; replies are 64).
- **Keys.** The server mints a 32-byte beacon key per target node, stored encrypted like other secrets, and hands it to that node through its authenticated config pull. Each source receives only per-path keys `K_path = HMAC-SHA256(K_target, "lattice-beacon/v1" | source_id | key_epoch)`, so a compromised source can probe only its own paths and cannot forge another source. Rotating `key_epoch` invalidates every path key; rotation runs weekly and on demand.
- **Request.** `magic "LTB1" | version | key_epoch | source_id hash | seq | sent_unix_ns | nonce(16) | padding | tag = HMAC(K_path, all prior bytes)[:16]`. The responder accepts a request only if the tag verifies, the timestamp is within 60 s of its clock and the nonce has not been seen in the last 120 s (a fixed-size cache per source). The reply echoes seq and sent time with its own tag, so the source drops forged replies.
- **Rate limits.** Per source address 20 requests per second, global 200 per second, beyond which the responder drops without computing a tag. CPU per datagram is one HMAC; the responder runs in its own goroutine with no access to the exec or task paths.
- **Port and address.** Per node, the operator sets the listen port (default UDP 47100) and the advertised endpoint (default public IPv4 and the listen port; for a NAT node the mapped public host and port). The advertised endpoint is what sources dial; the console shows both.
- **Enabling is a plan.** Turning a beacon on or off, or changing its port, is a privileged node change: a plan of kind `node.beacon`, approved like other plans, that the agent applies on its next pull. If NetGuard manages the node, the same approval carries a companion NetGuard plan that allows the UDP port from exactly the path sources (node remotes), so the port is closed to everyone else at the firewall too. Without NetGuard, silence and keys are the protection, and the console says so.
- **Node veto.** A new agent flag `-no-beacon` makes the agent refuse to listen whatever the server says, and report the refusal; the beacon then reads "refused by node" in the console.

Doctrine change, applied to `docs/PRODUCT-VISION.md` with this design: the agent's control channel stays outbound-only; the one inbound socket an agent may open is the measurement beacon, which is off by default, enabled per node by an approved plan, authenticated, silent and vetoable on the node.

Rejected alternatives: an HTTP or TLS endpoint on the agent (a TCP listener answers SYNs to everyone and invites a protocol stack's worth of parsing); reusing sshd or sing-box ports (the existing rule never probes sshd, and sing-box ports exist only on some nodes); ICMP only (filtered on several providers in this fleet); a raw-socket ping (needs `CAP_NET_RAW` for a root-capable agent).

The operator's "path, possibly with authentication" is covered separately by D1's HTTP expectations and secret headers: any node service with a health URL can be a target from any source.

### D4. Retention: a week of five-minute history by default

| Tier | Resolution | Default | Setting |
|---|---|---|---|
| Raw results | every run | 48 hours, at most 5760 rows per path | 24 to 72 hours |
| Fine rollups | 5 minutes | 7 days | 3 to 30 days |
| Coarse rollups | 1 hour | 90 days | 30 to 365 days |

Each rollup bucket keeps count, failures, min, max, a latency histogram (so p05, p50, p95 and p99 are derivable), the sum of absolute successive differences (jitter, defined as the mean absolute change between consecutive successful samples in the bucket) and lost packets out of sent for multi-packet methods. The ingest window for stamped results stays at 24 hours.

The settings live in Platform, Monitoring, with a live storage estimate computed from the current path count and interval (paths times buckets per day times days times the measured record size). Lowering a retention prunes on the next compaction pass and says so before saving; raising it starts keeping more from that moment, it cannot recover what was already pruned.

Rough size, to be replaced by a measurement in M1: at 30 s intervals and about 150 bytes per bucket, 100 paths cost about 3 MB per day of fine rollups and 100 MB per day of raw rows at the cap. A full mesh of 25 nodes is 600 paths; at the defaults that is about 130 MB of fine rollups and 1.2 GB of raw rows, which is why raw rows are capped by time and count and the console warns above 300 paths at intervals under 30 s.

Rejected: moving monitor history into metricsdb (its buckets keep min, max and average, which cannot answer p95 or jitter, and it would split one concept across two stores); one-minute rollups for the whole week (four times the size for detail the raw tier already covers for 48 hours).

### D5. One series API for every path

- `GET /api/monitoring/paths?window=` returns the matrix: sources, targets, and per path the current state, p50, p95, jitter, loss, samples and expected for the window, the delta against the same window one period earlier, and the reason when unknown. Windows: 1h, 6h, 24h, 3d, 7d, and 30d when fine retention allows.
- `GET /api/monitoring/series?monitor=&source=&window=&step=` returns buckets `{t, n, fail, sent, lost, min, p05, p50, p95, p99, max, jitter}` from the finest tier that covers the window in at most about 720 points, with missing buckets explicit. It serves every check, operator or generated, replacing the latency-only series route (kept as an alias for one release).
- `GET /api/monitoring/settings` and `PUT` (versioned) for retention, with the estimate.
- Beacon: `GET /api/nodes/{id}/beacon` (state, port, advertised endpoint, key epoch, last request seen, refusal) and plan creation for `node.beacon`.

Scopes stay `monitor:read` and `monitor:admin`; a path is visible only if the caller can read both its source and its target node, as latency data is today. Beacon plans need the node's admin scope in addition, because they open a port.

### D6. States, triangulation and alerts

A path is **up**, **degraded**, **down** or **unknown**. Down follows the alert policy (N failed runs). Degraded means loss above 2 percent, or a p50 over the last 15 minutes above both twice its 7-day p50 and its 7-day p50 plus 30 ms; both thresholds are per check settings with those defaults. Unknown means no result when one was expected, with the reason (agent offline, source paused, method refused by the node, ICMP filtered, beacon not enabled); unknown is never drawn green.

With more than one source, the console **triangulates**: a target down from every source it is probed from reads as "the target is unreachable"; a source failing most of its targets reads as "this source's network"; a single failing path reads as "this path". The verdict is a label computed from current path states, shown in the attention list with the evidence (which sources, which targets); it is a hint, never an alert by itself.

Alerts reuse the notification catalogue (design notify section 13): `monitor.down` and `monitor.recovered` as today for operator checks; new types `path.degraded` and `path.recovered` (category monitoring, severity warning and recovered) for path sets whose policy is `down_and_degraded`. Path sets default to `off` for alerts, matching today's behaviour of not paging on latency checks, so turning this on is the operator's choice. The known gap where `pendingIncidents` and `adoptLegacyAlerts` do not skip latency monitors (survey item, unverified at runtime) is checked and fixed in M1.

### D7. Console: structure

Layers of Monitoring, in this order, with Overview as the default:

1. **Overview.** Proof line (observed time, path sets, paths, and counts of degraded, down and unknown). Attention list, worst first, carrying the triangulation verdicts. A compact "fleet reach" strip: for each source, how many of its targets are up, degraded, down, unknown. Links into Paths filtered to the item.
2. **Paths.** The matrix, targets as rows grouped by region (as the Latency layer groups today), sources as columns. Each cell shows the window p50 as a number, toned by state; loss above zero adds a small loss figure under it; unknown is hatched with the reason on hover and focus. Window control (1h, 6h, 24h, 3d, 7d, 30d) shared by the whole page through `?window=`. A filter field using the console's list query syntax (`target:jp state:degraded source:cd-hs-sh`). Selecting a cell opens the path sheet.
3. **Checks.** Every check in one list: operator checks and, grouped under each path set, its generated checks. Create and edit in an object sheet (D8). Path sets are created and edited here too; this replaces the "Probe settings" sheet of the Latency layer.
4. **Topology.** Kept, fed by the same matrix data; with several sources it draws one fan per source and lets the operator pick which sources to show.
5. **Incidents.** Unchanged.

The old Latency layer becomes Paths; `?view=latency` redirects to `?view=paths` for one release. The node page gains a Paths card with two lists, "reaches" (paths from this node) and "reached by" (paths to it), each row with the window p50 and state, and a Beacon card (state, port, advertised endpoint, last seen request, enable or change through a plan).

### D8. The path sheet and the chart

The path sheet is the place the operator reads fluctuation, so it carries the page's one strong visual: the **path chart**.

- One time axis, two lanes sharing it. The upper lane plots latency: the p05 to p95 band as a light fill in the state tone, the p50 as a line in the foreground ink, min and max as faint ticks only when zoomed to raw or 5-minute buckets. The lower, short lane plots loss per bucket as bars (zero draws nothing). Missing buckets are hatched across both lanes and labelled "no data" with the reason; they never interpolate.
- Threshold guides for the degraded rule (the 7-day p50 and the trigger level) as dashed lines, labelled once.
- A crosshair with the exact bucket values (time, p50, p95, jitter, loss, samples of expected) that follows pointer and keyboard (left and right arrows step buckets); drag selects a range and zooms; double-click or Escape resets.
- "Compare with the previous period" overlays the previous window's p50 as a thin dotted line.
- Above the chart, a stats row for the window: p50, p95, jitter, loss, availability (successful runs of expected), samples of expected. Below, the latest raw runs (time, RTT per packet, error) and the method, target endpoint and source.
- Actions: pause this path, edit the check, open the source or target node.

The chart uses uPlot (already a dependency, canvas, handles 10,000 points with a cursor) wrapped in one console component with the console's tokens; sparklines elsewhere stay SVG. The colour rule is the console's: state tones are the only saturated colour; the band is the state tone at low opacity; p50 is foreground ink so it reads in every state. Below 768 px the sheet is full screen, the chart spans the width with fewer ticks, and the crosshair values sit in a fixed row above the chart so the finger does not cover them.

### D9. Console: checks editor

An object sheet with the form in task order: what to measure (method, with one sentence each: "Beacon: the path to the node itself; needs the node's beacon", "ICMP: ping; some providers filter it", "TCP: connect to a port", "HTTP: request a URL and check the answer", "TLS: certificate expiry, from the control plane"), from where (sources: node picker with region groups and `control-plane`), to where (a node, resolved per method and shown resolved, or an address or URL), expectations (per method), how often (interval, timeout, packets) and what to do when it fails (alert policy). The sheet shows the resolved endpoint for every source before saving, and refuses with the reason when a node target cannot be resolved for the chosen method (no beacon, no TCP line, no public address). Path sets use the same sheet with a target rule instead of a single target, and preview the paths they will create.

Saving a check or path set is an audited configuration change, as monitor configuration is today; enabling a beacon is the only part that goes through a plan, because it opens a port.

### D10. Agent changes

- `icmp` prober using unprivileged datagram echo (`udp4` ICMP sockets); if the kernel's `net.ipv4.ping_group_range` excludes the agent's group, the result is unknown with reason `icmp_not_permitted`, never down, and the agent reports the capability once in its facts.
- `beacon` prober (client) and responder (server side of D3), both in a new package with a fuzz test for the request parser, a test that replies are never larger than requests, and a test that wrong tags, stale timestamps and replayed nonces get no reply.
- Multi-packet runs for both, reporting per-packet RTTs, lost count and the run's jitter.
- Result queue kept in memory, unchanged; the server already refuses stale results.
- The `-no-beacon` flag and a capability line in `-compat-json`.
- A node-agent prerelease (`v0.3.10-alpha.N` series continues, or `v0.3.11-alpha.1` if the compat floor moves), rolled out through the normal approved update path.

## Slices

| Slice | Contents | Repos | Ships as |
|---|---|---|---|
| M1 | Retention tiers and settings with estimate; percentiles, jitter and loss in buckets; series API for every check; paths matrix API with multiple sources and the previous-period delta; monitor edit route; latency incident gap fixed; console Overview and Paths layers, path sheet and chart, Checks layer with edit, windows to 30d | sdk, server, dashboard | next server image |
| M2 | Beacon (D3) and icmp (D10) in the agent; server beacon keys, `node.beacon` plan, NetGuard companion plan, node endpoint resolution per method; path sets prefer beacon; node page Beacon and Paths cards; HTTP expectations and secret headers | sdk, agent, server, dashboard | agent prerelease, then server image |
| M3 | Triangulation verdicts; degraded state and `path.degraded` and `path.recovered` catalogue types; Topology with several sources; previous-period overlay | server, dashboard | server image |
| M4 | `docs/architecture.md` monitoring section rewritten (it still says "500 per monitor"), handbook page, design status | umbrella | docs |

M1 needs no agent change and gives the operator a week of history, fluctuation and editable checks on the paths that already exist. M2 is where node-to-node paths become complete. Each slice ships behind the usual precheck, backup, health gates and rollback.

## Verification

- Server: table tests for retention pruning at each tier boundary, bucket math (percentiles from the histogram against a reference computation, jitter, loss), the matrix API with gaps and unknown reasons, scope filtering of paths by node visibility, the edit route's version conflict, and a migration test that existing latency rows, rollups and generated checks keep their ids and history. A benchmark for ingest at 600 paths and 30 s.
- Agent: the beacon parser fuzz test, amplification and replay tests, rate-limit test, icmp permission fallback, `check-release-workflow.sh` and `test-install-integrity.sh`.
- Console: model tests for state, triangulation, window to step selection, gap rendering and the delta; the path chart driven at 1440 and 375 in light and dark with real-shaped data (one-week series with gaps, a degraded episode, loss bursts, a method switch); keyboard crosshair; empty, loading, error, permission-denied and "beacon refused by node" states; design review.
- Production: after M1, the operator's existing 33 paths show a week of history once a week has passed (the fine tier starts filling at the switch); after M2, the NAT nodes that read failed today read up through their beacons.

## Risks

- **Beacon surface.** Mitigated by silence, signed requests, no amplification, rate limits, the per-node plan, NetGuard companion rules and the node veto; a security review of the responder is part of M2's acceptance.
- **Storage growth** with large meshes; mitigated by time and count caps, the estimate on the settings page and the 300-path warning.
- **Store lock contention** at ingest, since one bolt update per request runs under the store lock today; the M1 benchmark decides whether ingest moves to its own lock.
- **Doctrine drift.** The amendment is narrow and written down; any second inbound socket on the agent needs its own design.
