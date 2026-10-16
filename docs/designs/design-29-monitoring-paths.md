# Design 29: Monitoring paths, operator-defined checks between nodes with a week of history

Status: accepted 2026-10-16 after an architecture review and a security review the same day (their findings are folded into D1 to D6, D10, Slices and Risks); the operator asked for this work and granted release authority the same day (`PROGRAM.md` Decisions 2026-10-16). Slices M1 to M4 below; none built.
Date: 2026-10-16.
Reference: lattice-server `integration` at a6caff4 (alpha-0.2.2a124), lattice-dashboard `integration` at 2ce7dd2, lattice-node-agent `integration` at c8c3a8f, lattice-sdk `integration`, umbrella at 4608e85.

## Summary

Monitoring today answers one question well (is something down right now) and the rest poorly. Latency checks run from one node, `cd-hs-sh`, and can only dial a node's sing-box TCP line port, so a node without a TCP line cannot be a target and a NAT node, whose public port differs from its listen port, shows as unreachable when it is fine. Five of 33 targets read "failed" on production on 2026-10-16 for that reason. History exists in the hot store but the console shows at most a single-source matrix and a per-pair column chart with p50, p95 and loss; operator monitors have no history view and cannot be edited.

This design makes a **path** (one source probing one target with one method) the unit of monitoring, lets the operator define the sources, the targets and the method, keeps a week of five-minute history by default (settable from 3 to 14 days), and shows fluctuation: median, spread, jitter and loss on one time axis, with gaps drawn as unknown. Every node can carry a **beacon**, a small authenticated UDP responder inside the agent that answers only probes signed for it by the server's keys, at a port and public address the operator sets per node. Because the beacon is the first thing an agent ever listens on, the doctrine sentence "nodes run an outbound-only agent" is amended in this design, and the beacon is off until an approved plan turns it on for a node.

## What the operator asked (2026-10-16)

The Monitoring pages work, but the presentation and the history of fluctuation are missing. The operator wants to define a set of probes: every agent has a port or path that can be probed, which may differ per node, possibly with authentication, convenient to reach but safe from attack; the operator can have agent A probe agent B and define the source and target combinations; at least the last three days of data are kept, extendable to seven; the framework that added the `cd-hs-sh` latency probes should be the basis. Optimise the Monitoring pages end to end: UI, UX, logic and the data framework.

## Facts this design rests on

Read from the `integration` checkouts on 2026-10-16; file and line references are in the survey recorded in the vault ledger of that date.

1. **Checks.** `model.Monitor` kinds are `tcp` and `http` (run on agents) and `tls` (run on the server). `icmp` is a constant the server refuses to create. POST always mints a new id; there is no edit route. Defaults 30 s interval, 5 s timeout. HTTP counts any status under 400 as up and carries no headers.
2. **Latency probes.** `LatencyProbeConfig` in `state.json` lists source node ids (default `cd-hs-sh`), an "overseas" auto-target rule, include and exclude lists and disabled pairs. A planner every 2 minutes turns it into one generated `tcp` monitor per target, shared by every source, dialing that target's sing-box TCP line port on its public IPv4 and never port 22, an sshd port or a knock-gated port. A node with no TCP line is "not probeable".
3. **Agent.** The agent never listens. Each cycle (10 s) it pulls `/api/agent/monitors`, runs one goroutine per monitor (TCP dial, HTTP GET), and posts batched results; the queue is in memory, 2000 results. It holds no `CAP_NET_RAW` when installed with a run user; a default install runs it as root without a capability bound. No node-side veto covers monitors.
4. **Storage.** With the hot store on (production), results live in `state-hot.db` (bbolt): raw rows capped at 1440 per pair, histogram rollups at 5 minutes for 48 hours and 1 hour for 8 days, one latest record and fail streak per pair. A result stamped more than 24 hours old is refused. metricsdb holds no monitor data.
5. **Already pair-shaped.** Rows, rollups and the latest record are keyed by (monitor, source node). What is missing is first-class configuration of pairs, per-pair targets and a history API for anything but generated latency monitors.
6. **Console.** `MonitoringView.vue` has four layers (Incidents, Topology, Monitors, Latency). Charts are hand-written SVG; `uplot` is in `package.json` and imported nowhere. Latency windows are 1 h, 24 h and 7 d. Polling is 8 to 30 s.
7. **NetGuard** can allow a port from a `node` remote (pinned to that node's WireGuard and public /32s) or a zone of CIDRs; ICMP is already accepted by the fixed scaffold. Applying a ruleset is a plan with approval.

## Decisions

### D1. The unit is a path; checks own their paths

A **check** is the existing `Monitor`, extended: one method, one target, one or more sources, expectations, interval and an alert policy. Each (check, source) is a **path** with its own series, state and history, which is what the store already keys by. The **path set** is the existing latency configuration, renamed and generalised: one rule (sources times targets, with include, exclude and disabled pairs) that the planner expands into generated checks; there is one path set, as there is one latency configuration today. Operators can still create single checks by hand. Rejected: a new `Check` type beside `Monitor`, which would mean migrating stored rows and two result paths for one concept.

Changes to `model.Monitor` (revised after the architecture and security reviews of 2026-10-16):

- `kind` gains `icmp` (agent, unprivileged echo) and `beacon` (agent, UDP to a node's beacon).
- `target` stays a resolved string on the wire, because every deployed agent decodes it as a string and one object would fail the whole monitor list. A new optional `target_node` field names the node a target was resolved from. The server resolves it per method (beacon endpoint, public address for `icmp`, line port for `tcp`) in `MonitorsForNode` and `handleAgentMonitors` for operator checks and in the planner for generated ones, so a moved IP or a new NAT mapping follows without editing checks. Path visibility uses `target_node` instead of the `mon_lat_` id prefix.
- Sources stay the existing per-check node assignment. `control-plane` remains the source of `tls` checks only (their results keep the empty node id they have today); tcp, http and icmp from the server are not offered, because nobody asked for them and they would let a monitor admin probe the control plane's own network.
- **Capability gating.** Each agent reports the probe methods it supports in its facts. A method is assigned to a source only if that source supports it; an older agent that would report an unknown kind as a failure never receives one, and the path reads unknown with reason "agent too old for this method" instead of down.
- HTTP expectations: a status set or ranges (default 200 to 399). Optional request headers whose values are write-only secrets (stored like channel secrets, never returned), with these rules from the security review: a check with secrets must use https without skipping verification; secrets are bound to the scheme, host and port they were saved with, and changing any of those clears them; redirects are never followed on such a check (a 3xx is the answer); an edit names each header as keep, set or delete so an edit that echoes the secret-less read cannot wipe or leak them; secrets go only to the check's assigned sources, are redacted in audit diffs and are never copied into generated checks. A response body is never matched or stored; the body match of the first draft is dropped, because it turned a check into a one-bit reader of whatever the target returns.
- Destinations. Every agent check resolves its target at dial time and dials the address it checked (no second lookup). Loopback, link-local, metadata (169.254.0.0/16 and fd00:ec2::254), multicast and private ranges are refused unless the target is a node reference resolved by the server. Errors stored with results have the URL query and user info removed.
- Who may configure. Creating or editing a check or the path set needs `monitor:admin` and read access to every source and target node it names, not only to see the resulting paths.
- `packets` for `icmp` and `beacon` (1 to 10, default 5, 200 ms apart), so one run yields loss and jitter, not just one RTT. A save enforces an interval floor (10 s) and a packets-per-second budget per (source, target).
- `alert`: `off`, `down` (after N failed runs, default 2, as today) or `down_and_degraded` (adds the degraded state of D6, from M3).
- Editing. `POST /api/monitors/update` with an optimistic version, following the server's action-route style. An edit may change interval, timeout, packets, expectations, alert policy, name and sources; changing kind or target mints a new check and pauses the old one, so one series never mixes two methods. Generated checks refuse edits with 409, as delete already does; their paths are paused through the path set's disabled pairs. Pausing one source of an operator check is a new per-source paused list that both `MonitorsForNode` and result admission honour.

### D2. Methods, in order of preference for node targets

1. **beacon** when the target has an enabled beacon and the source supports it: measures the network path to the node itself, works for every node whatever lines it serves, and works through NAT because the advertised endpoint is configured per node.
2. **icmp** when it has none: kernel-answered, so nothing new listens; may be filtered by providers (D10 says when that reads unknown and when down).
3. **tcp** to a line port, today's behaviour, kept so existing paths and their history continue.

The path set picks, per source, the first method both ends support unless the operator pins one. Generated ids stay one per (target, method): `mon_lat_<target>` keeps tcp and its history, and new ids `mon_latb_<target>` and `mon_lati_<target>` carry beacon and icmp. Each generated check's node assignment is the set of sources using that method for that target, so sources can differ in method while the target is the same. The pair state gains `method` and the check id actually used.

A **path series** is addressed by (source, target node) and joins the series of every generated check for that pair by time, so the chart shows one continuous line across a method switch, marked where the method changed. No generated check with history is ever deleted except when its target node is deleted; a test pins that, because `SyncManagedMonitors` deletes history along with a monitor.

### D3. The beacon: an authenticated UDP responder that answers nothing unsigned

The operator asked for a probe-able port per agent that is convenient but safe. The strongest case against is the doctrine: Lattice's agent only dials out, and a listener is new attack surface on every node, a fingerprint that says "this host runs Lattice", and a new parser exposed to the internet. The strongest case for is that no other method measures the path to every node: line ports exist only where sing-box serves TCP, ICMP is often filtered, and NAT breaks both. The design takes the beacon, opt-in, with these properties (revised after the security review of 2026-10-16):

- **No reply to anything unsigned.** A datagram that is not exactly 96 bytes, not for a known source id, not correctly signed, not fresh, or a replay gets no reply and no log line. There is no TCP listener and no banner. An open beacon port therefore reads as open-or-filtered to a scanner, like WireGuard; it does not read as closed, because a closed UDP port draws ICMP port-unreachable from the kernel. The beacon makes no stronger claim than that.
- **No amplification.** A reply (64 bytes) is never larger than its request (96 bytes, padded); the responder reads into a 128-byte buffer and drops any datagram whose length is not exactly 96, so a longer packet with a valid prefix cannot pass.
- **Keys stay on the server.** The server mints a 32-byte key per target node and keeps it. Per epoch it derives `K_path = HMAC-SHA256(K_target, len-prefixed("lattice-beacon/v1", source_id, epoch))` for every source bound to that target, and sends the target only its table of (source id, epoch, `K_path`) and each source only its own `K_path` per target, through the authenticated config pull. Nodes hold path keys in memory only, never on disk. A stolen node config therefore yields keys for one node's paths and one epoch, and rotation (on demand as an audited action, and automatically when a source is removed from a target) ends it. Epochs N and N-1 are both accepted for two pull cycles so a rotation does not open gaps. Source ids are short exact ids assigned by the server, not hashes, so an unknown id is dropped before any HMAC is computed.
- **Request and reply.** Request: `magic "LTB1" | version | epoch | source_id | seq | sent_unix_ns | nonce(16) | padding | tag = HMAC(K_path, "req" | all prior bytes)[:16]`. The responder compares tags with a constant-time equality, accepts a request only if the timestamp is within 60 s of its clock, is not older than the responder's own start, and the nonce is not in the source's cache. Reply: `magic "LTB1" | version | status | seq | request nonce | responder_unix_ns | tag = HMAC(K_path, "rep" | all prior bytes)[:16]`; the status is ok, stale (clock), unknown epoch or rate limited, which turns silent failures into named reasons for the operator without telling an outsider anything. The source computes RTT from its own monotonic clock and drops a reply whose nonce is not one it sent.
- **Nonce cache.** Per source, at least rate times window entries (20 per second times 120 s, so 2400), inserted only after the tag verifies; when full it refuses new requests rather than evicting a nonce still inside the window, so an unauthenticated flood cannot evict anything and a compromised source can only fill its own cache.
- **Rate limits in the right order.** Before authentication the only budget is a CPU guard sized in tens of thousands of datagrams per second, kept in a fixed-size counter array (never a map keyed by attacker-chosen addresses). The tag is verified next. After authentication each source id is limited to 20 requests per second. The server also enforces, when a check is saved, a minimum interval and a packets-per-second budget per (source, target), so one operator cannot saturate a source's own budget.
- **Isolation inside the agent.** The receive loop recovers from panics (an index error on a short datagram must not kill the agent), allocates nothing on the drop path, and has a circuit breaker: if drops stay above a threshold for 60 s, the socket closes for a cooldown and the agent reports it, so the pull loop and task execution keep their CPU. A separate unprivileged process is the follow-up if the responder ever needs more than this.
- **Port and address.** Per node, the server assigns a random listen port in 40000 to 59999 (not a fixed well-known default that would land on scan lists), and the operator may override it; the save lints it against known listeners (sing-box inbounds, sshd, knock ports) and the agent reports a bind failure instead of taking a port that is in use. The agent binds the node's advertised public IPv4 only (never the wildcard, so WireGuard and private interfaces stay closed) and replies from the address a request arrived on. The advertised endpoint is an IPv4 literal and port (for a NAT node, the mapped public address and port); hostnames are refused so sources cannot be pointed at third parties or rebound to internal addresses, and sources refuse loopback, link-local and multicast endpoints. Beacon checks may only target node references, never arbitrary addresses. IPv6 is out of scope for the first version.
- **Enabling is a plan.** Turning a beacon on or off or changing its port is a plan of kind `node.beacon`, approved like other plans; the plan's hash covers the port, bind address, advertised endpoint, the source set and the limits, so what was approved is what runs. If NetGuard manages the node, the same approval carries a companion NetGuard rule set that allows the UDP port from exactly the current beacon sources (node remotes, plus each NAT source's egress address when it differs from its pinned /32) and marks the port `notrack` in both directions so spoofed datagrams cannot fill the connection-tracking table that sing-box traffic on the same node needs. Adding or removing a source later re-plans the allow set; until that plan is applied the console shows "firewall pending" for the affected paths. After enabling, one source runs a reachability check and the console shows reachable, filtered or not listening (a connected UDP socket's `ECONNREFUSED` is the "not listening" signal). Without NetGuard the port is open to the internet and protected only by the properties above; the console says so on the node page.
- **Node veto.** A new agent flag `-no-beacon`, checked before any bind and not overridable by server configuration, makes the agent refuse to listen whatever the server says and report the refusal; the beacon then reads "refused by node".

Doctrine change, applied to `docs/PRODUCT-VISION.md` with this design: the agent's control channel stays outbound-only; the one inbound socket an agent may open is the measurement beacon, which is off by default, enabled per node by an approved plan, authenticated, silent to anything unsigned and vetoable on the node.

Rejected alternatives: an HTTP or TLS endpoint on the agent (a TCP listener answers SYNs to everyone and invites a protocol stack's worth of parsing); reusing sshd or sing-box ports (the existing rule never probes sshd, and sing-box ports exist only on some nodes); ICMP only (filtered on several providers in this fleet); a raw-socket ping (needs `CAP_NET_RAW` for a root-capable agent).

The operator's "path, possibly with authentication" is covered separately by D1's HTTP checks with secret headers: any node service with a health URL can be a target from any source, under the destination rules in D1.

### D4. Retention: a week of five-minute history by default

| Tier | Resolution | Default | Setting |
|---|---|---|---|
| Raw results | every run | 1440 rows per path (24 hours at 60 s), as today | none |
| Fine rollups | 5 minutes | 7 days | 3 to 14 days |
| Coarse rollups | 1 hour | 35 days | none |

The operator asked for at least three days, extendable to seven; the fine tier covers that at five-minute resolution, which is about 2000 points per path over a week, more than a chart can draw. Rejected: one-minute rollups (four times the size for detail the raw tier already holds for a day), a 90-day coarse tier and a 30-day fine setting (nobody asked, and they dominate the size), and moving monitor history into metricsdb (its buckets keep min, max and average, which cannot answer p95 or jitter).

Bucket contents. The existing rollup already keeps count, failures, min, max and a latency histogram from which p50 and p95 are derived, so percentiles need no new work. M1 adds, as additive JSON fields with no migration: the sum and count of absolute differences between consecutive successful samples (jitter, computed at ingest from the last successful latency kept in the path's latest record, so merged buckets stay exact) and, from M2a, packets sent and lost. The histogram counts runs; a multi-packet run contributes its median RTT. Loss is lost over sent when packets were sent, otherwise failed runs over runs.

Pruning. No compaction pass exists today: rollups are trimmed only when a pair opens a new bucket and raw rows only when a row is inserted, so paused paths, sources removed from a check and paused generated checks never trim. M1 adds an hourly sweep that deletes buckets and rows below each tier's cutoff for every pair, in bounded transactions. bbolt reuses freed pages but never shrinks its file, so lowering retention frees space for reuse, not disk; the settings page says so before saving.

Size, measured from the encoding (key 84 bytes, fine value about 85 to 110 bytes with the new fields, about 200 bytes logical and 260 to 400 on disk after page splits): 100 paths cost about 6 MB of fine rollups per day of retention, so about 40 MB at the 7-day default, plus about 7 MB of coarse rollups and about 26 MB of raw rows. A full mesh of 25 nodes (600 paths) is about 250 MB fine at 7 days, 45 MB coarse and 160 MB raw. The settings page shows the measured size from bucket statistics and the projected size for the chosen retention, and warns above 300 paths at intervals under 30 s.

### D5. One series API for every path

Routes stay under `/api/monitors/` in the server's action-route style.

- `GET /api/monitors/paths?window=` returns the matrix: sources, targets, and per path the current state, method, p50, p95, jitter, loss, samples and expected for the window, the delta against the same window one period earlier, and the reason when unknown. Windows: 1h, 6h, 24h, 3d, 7d, and 14d when fine retention allows. Windows of 3 days and longer read coarse buckets for the matrix; each window's result is cached until its next bucket closes.
- `GET /api/monitors/series?source=&target_node=&window=` (or `monitor=&source=` for an operator check) returns buckets `{t, n, fail, sent, lost, min, p50, p95, max, jitter, method}`. The step is the smallest multiple of the finest covering tier's resolution that gives at most 720 points, merged on the server: 1h raw, 24h 5-minute (288), 3d 10-minute (432), 7d 15-minute (672), 14d 30-minute (672). Missing buckets are explicit. It replaces the latency-only series route, which stays as an alias for one release.
- `GET /api/monitors/settings` and `POST /api/monitors/settings/update` (versioned) for retention, with measured and projected size.
- Beacon: `GET /api/nodes/beacon?node_id=` (state, port, advertised endpoint, key epoch, last authenticated request seen, refusal) and plan creation for `node.beacon`.

History reads run in a bolt read transaction outside the store's global mutex, as a note in `store/monitor_results.go` already proposes, so a 7-day matrix cannot stall ingest or the rest of the store.

Scopes stay `monitor:read` and `monitor:admin`; a path is visible only if the caller can read both its source and its target node, as latency data is today. Beacon plans need the node's admin scope in addition, because they open a port.

### D6. States, triangulation and alerts

A path is **up**, **degraded** (from M3), **down** or **unknown**. Down follows the alert policy (N failed runs). Unknown means no result when one was expected, with the reason (agent offline, source paused, agent too old for the method, method refused by the node, ICMP filtered, beacon not enabled, firewall pending); unknown is never drawn green.

Degraded, evaluated on a server schedule every minute, not on console polls, and only once a path has 24 hours of baseline: loss over the last hour, with at least 30 samples, above both 2 percent and twice the path's 7-day loss; or p50 over the last 15 minutes above both twice its 7-day p50 and its 7-day p50 plus 30 ms. Entering needs the condition on two consecutive evaluations and leaving needs it absent for ten minutes, so a single dropped probe on a China path does not flap. The 7-day baselines are cached and refreshed hourly. Thresholds are per check settings with those defaults.

With more than one source, the console **triangulates**: a target down from at least two fresh sources and from every fresh source reads as "the target is unreachable"; a source failing at least three targets and most of its targets reads as "this source's network"; anything else reads as "this path". With today's single source the verdict is always "this path", which is honest. The verdict is a label in the attention list with its evidence; it is never an alert by itself.

Alerts reuse the notification catalogue (design notify section 13): `monitor.down` and `monitor.recovered` as today for operator checks; new types `path.degraded` and `path.recovered` (category monitoring, severity warning and recovered) for a path set whose policy is `down_and_degraded`. The path set defaults to `off` for alerts, matching today's behaviour of not paging on latency checks, so turning this on is the operator's choice. `pendingIncidents` (`server_incidents.go`) does not skip managed latency monitors the way the pager does; M1 adds that skip and a test.

### D7. Console: structure

Layers of Monitoring, in this order, with Overview as the default:

1. **Overview.** Proof line (observed time, paths, and counts of down and unknown, plus degraded from M3; a state the server does not compute yet is not shown). Attention list, worst first, carrying the triangulation verdicts. A compact "fleet reach" strip: for each source, how many of its targets are up, degraded, down, unknown. Links into Paths filtered to the item.
2. **Paths.** The matrix, targets as rows grouped by region (as the Latency layer groups today), sources as columns. Each cell shows the window p50 as a number, toned by state; loss above zero adds a small loss figure under it; unknown is hatched with the reason on hover and focus. Window control (1h, 6h, 24h, 3d, 7d, and 14d when retention allows) shared by the whole page through `?window=`. A filter field using the console's list query syntax (`target:jp state:degraded source:cd-hs-sh`). Selecting a cell opens the path sheet.
3. **Checks.** Every check in one list: operator checks and, grouped under the path set, its generated checks. Create and edit in an object sheet (D9). The path set is edited here too; this replaces the "Probe settings" sheet of the Latency layer.
4. **Topology.** Kept, fed by the same matrix data; with several sources it draws one fan per source and lets the operator pick which sources to show.
5. **Incidents.** Unchanged.

The old Latency layer becomes Paths; `?view=latency` redirects to `?view=paths` for one release. The node page gains a Paths card with two lists, "reaches" (paths from this node) and "reached by" (paths to it), each row with the window p50 and state, and a Beacon card (state, port, advertised endpoint, last seen request, enable or change through a plan).

### D8. The path sheet and the chart

The path sheet is the place the operator reads fluctuation, so it carries the page's one strong visual: the **path chart**.

- One time axis, two lanes sharing it. The upper lane plots latency: the band from min to p95 as a light fill (the histogram yields p50 and p95; a lower percentile would add storage for little reading value) in the state tone, the p50 as a line in the foreground ink, min and max as faint ticks only when zoomed to raw or 5-minute buckets. The lower, short lane plots loss per bucket as bars (zero draws nothing). Missing buckets are hatched across both lanes and labelled "no data" with the reason; they never interpolate.
- Threshold guides for the degraded rule (the 7-day p50 and the trigger level) as dashed lines, labelled once.
- A crosshair with the exact bucket values (time, p50, p95, jitter, loss, samples of expected, method) that follows pointer and keyboard (left and right arrows step buckets); drag selects a range and zooms; double-click or Escape resets.
- "Compare with the previous period" overlays the previous window's p50 as a thin dotted line.
- Above the chart, a stats row for the window: p50, p95, jitter, loss, availability (successful runs of expected), samples of expected. Below, the latest raw runs (time, RTT per packet, error) and the method, target endpoint and source.
- Actions: pause this path, edit the check, open the source or target node.

The chart uses uPlot (already a dependency, canvas, handles 10,000 points with a cursor) wrapped in one console component with the console's tokens; sparklines elsewhere stay SVG. The colour rule is the console's: state tones are the only saturated colour; the band is the state tone at low opacity; p50 is foreground ink so it reads in every state. Below 768 px the sheet is full screen, the chart spans the width with fewer ticks, and the crosshair values sit in a fixed row above the chart so the finger does not cover them.

### D9. Console: checks editor

An object sheet with the form in task order: what to measure (method, with one sentence each: "Beacon: the path to the node itself; needs the node's beacon", "ICMP: ping; some providers filter it", "TCP: connect to a port", "HTTP: request a URL and check the answer", "TLS: certificate expiry, from the control plane"), from where (sources: node picker with region groups, each node showing the methods its agent supports; `control-plane` only for TLS), to where (a node, resolved per method and shown resolved, or an address or URL), expectations (per method), how often (interval, timeout, packets) and what to do when it fails (alert policy). The sheet shows the resolved endpoint for every source before saving, and refuses with the reason when a node target cannot be resolved for the chosen method (no beacon, no TCP line, no public address). The path set uses the same sheet with a target rule instead of a single target, and previews the paths and the method each source will use.

Saving a check or the path set is an audited configuration change, as monitor configuration is today; enabling a beacon is the only part that goes through a plan, because it opens a port.

### D10. Agent changes

- `icmp` prober using unprivileged datagram echo (`udp4` ICMP sockets) with a fixed 32-byte payload carrying 16 random bytes per echo; a reply counts only if its payload and source address match, so an off-path host cannot forge "up" by guessing the kernel's id and sequence. If the kernel's `net.ipv4.ping_group_range` excludes the agent's group, the result is unknown with reason `icmp_not_permitted` and the agent reports the capability once in its facts. All-loss on a path that has never succeeded reads unknown ("may be filtered"); all-loss for the alert policy's run count on a path that has succeeded before reads down, so a node that really dies still alerts. The same interval floor and per-target packet budget as beacons apply.
- `beacon` prober (client) and responder (server side of D3), both in a new package with: a fuzz test of the request parser that fails on any panic; a test that replies are never larger than requests and that a 97-byte datagram with a valid 96-byte prefix gets no reply; tests that wrong tags, stale timestamps, timestamps before the responder started, unknown source ids, unknown epochs and replayed nonces get no reply; an `AllocsPerRun == 0` test on the drop path; and a circuit-breaker test.
- The server keeps refusing results for checks not assigned to the authenticated node and results that claim another source (verify the existing ingest does this; add a test either way).
- Multi-packet runs for both, reporting per-packet RTTs, lost count and the run's jitter.
- Result queue kept in memory, unchanged; the server already refuses stale results.
- The `-no-beacon` flag and a capability line in `-compat-json`.
- Each agent reports the probe methods it supports in its facts (D1 capability gating).
- The SDK `MonitorResult` and the stored row gain sent, lost and a bounded per-packet RTT list (at most 10).
- A node-agent prerelease, rolled out through the normal approved update path.

## Slices

| Slice | Contents | Repos | Ships as |
|---|---|---|---|
| M1 | Fine retention setting (3 to 14 days, default 7) and coarse tier at 35 days; the hourly pruning sweep; jitter in buckets; history reads outside the store mutex; series API for every path and the path series join; paths matrix API with multiple sources, cached per window, and the previous-period delta; the edit route and per-source pause; the incident skip for managed monitors; console Overview (no degraded yet), Paths, path sheet and chart, Checks with edit, windows to 14d | sdk, server, dashboard | next server image |
| M2a | Agent capability facts and per-source method gating; `target_node` resolution; icmp; HTTP expectations and secret headers with the destination rules; multi-packet results | sdk, agent, server, dashboard | agent prerelease, then server image |
| M2b | The beacon (D3): agent responder and client, server keys and per-epoch tables, `node.beacon` plan, NetGuard companion rules, reachability check, node page Beacon and Paths cards; the doctrine amendment follows the operator's explicit request of 2026-10-16 and is restated in the M2b release report; security review of the responder as acceptance | sdk, agent, server, dashboard, umbrella | agent prerelease, then server image |
| M3 | Degraded state on a server schedule, triangulation verdicts, `path.degraded` and `path.recovered`, Topology with several sources, previous-period overlay | server, dashboard | server image |
| M4 | `docs/architecture.md` monitoring section rewritten (it still says "500 per monitor"), handbook page, design status | umbrella | docs |

M1 needs no agent change, because several sources per tcp check already work, and gives the operator a week of history, fluctuation and editable checks on the paths that exist. M2a and M2b are where node-to-node paths become complete. Each slice ships behind the usual precheck, backup, health gates and rollback.

## Verification

- Server: table tests for the pruning sweep at each tier boundary (including paused paths and removed sources), bucket math (percentiles against a reference computation, jitter across merged buckets, loss both ways), the matrix API with gaps and unknown reasons, the 720-point step rule, scope filtering of paths by node visibility, the edit route's version conflict and the 409 on generated checks, a test that no generated check with history is deleted unless its target node is, and a migration test that existing latency rows, rollups and generated checks keep their ids and history. A benchmark of matrix reads at 600 paths while ingest runs.
- Agent: icmp payload verification and permission fallback; from M2b the beacon parser fuzz test, amplification, length, replay, epoch, allocation and circuit-breaker tests; `check-release-workflow.sh` and `test-install-integrity.sh`.
- Console: model tests for state, triangulation, window to step selection, gap rendering and the delta; the path chart driven at 1440 and 375 in light and dark with real-shaped data (one-week series with gaps, a loss burst, a method switch); keyboard crosshair; empty, loading, error, permission-denied, "agent too old for this method" and "beacon refused by node" states; design review.
- Production: after M1, the existing 33 paths keep their history and the fine tier fills toward a week from the switch; after M2b, the NAT nodes that read failed today read up through their beacons.

## Risks

- **Beacon surface.** Mitigated by D3: no reply to anything unsigned, exact-length requests, no amplification, keys held by the server, rate limits after authentication, panic recovery and a circuit breaker, the per-node plan, NetGuard companion rules with `notrack`, and the node veto. A security review of the responder is part of M2b's acceptance.
- **Storage growth** with large meshes; mitigated by the fixed raw and coarse tiers, the 14-day ceiling, the pruning sweep, measured size on the settings page and the 300-path warning. bbolt does not shrink its file; that is stated, not hidden.
- **Read contention.** The 7-day matrix is the expensive read, not ingest; it reads coarse buckets, is cached per window and runs outside the store mutex. The M1 benchmark checks it under ingest.
- **Doctrine drift.** The amendment is narrow and written down; any second inbound socket on the agent needs its own design.
- **Older agents.** Capability gating keeps an agent that predates M2a on tcp, reading unknown for methods it cannot run instead of down.
