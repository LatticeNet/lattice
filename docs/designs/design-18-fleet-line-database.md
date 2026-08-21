# Design 18 - The fleet is a line database: platform spine from adoption to subscription

> Status: proposed 2026-08-12, from the operator directive: the sing-box fleet
> scattered across many VPS machines is one abstract database. Lattice does not
> register that database anywhere else — it reads and writes it, through
> Lattice-owned metadata that sing-box itself never sees. On top of the base
> connect/monitor/manage framework, extensions (netguard, wireguard, vpn-core,
> sub-store) grow with declared dependencies, version requirements, and
> pre-apply checks; on top of the fleet database, the chain graph and then the
> subscription layer follow as natural consequences.
> Builds on: design-01 (cores & subscriptions), design-07 (agent lifecycle),
> design-08 (plugin runners), design-09 (vpn-core/sub-store split), design-12
> (lines read model), design-13 (netguard/wireguard), design-15 (line_uuid,
> sidecar identity, chain model), design-17 (managed line overlay), the
> 2026-08-11 serve-path work (content-addressed caches).

## 1. Intent

Restate the vision as architecture. Every sing-box config on every node is a
row in a database the platform owns. Reads come from a server-side projection;
writes go through planned, approved, audited tasks. Identity travels with each
node in a metadata sidecar, so line bindings and cross-node edges survive tag,
port, and even config-layout edits. Every layer above the projection — the
chain graph, the topology map, subscriptions — is a view or a join over those
rows, never a parallel system with its own truth.

The named endpoint of this arc: the operator composes fleet lines, external
feeds, and handwritten configs, applies filters/renames/scripts, and publishes
a subscription. That is exactly the sub-store layer — it becomes
"顺理成章" precisely because the layers below it are the same data.

## 2. The spine

```
L5  subscription composition   sub-store: subs, collections, files, scripts, shares
L4  chain graph                declared edges (sidecar chain) + discovered route
                               rules → jump_edges → topology views
L3  line database              per-node projection: lines, users, line_uuid,
                               port map, REALITY material, content hashes
L2  node capability lifecycle  enrolled → sing-box-managed (install from our
                               fork) → line-managed (design-17 overlay)
L1  extensions                 vpn-core, netguard, wireguard, sub-store —
                               manifest v2 + dependency + preflight contract
L0  framework                  agent channel, tasks, plan→approve→apply, audit,
                               inventory, content-addressed caches
```

One discipline binds all layers: **no layer reaches around the projection to
scrape a node synchronously.** L0's single gate (plan→approve→apply) is what
makes the operator's "audit records, interception, and everything else"
possible — every mutation flows through one chokepoint that can observe,
refuse, or record it.

## 3. What already exists (evidence, not aspiration)

| Capability | Where | State |
|---|---|---|
| Agent channel, tasks, self-update | lattice-node-agent (taskexec, hostfacts, singboxdiscover, prober, proxyusage, metrics); design-07 | shipped; fleet at agent v0.3.3 pending operator approval |
| One-gate mutations, batch approvals, audit | lattice-server approvals (event grouping, bounded-concurrency batch runner, typed columns) | shipped 2026-08-10 |
| Durable line identity | `internal/server/linemeta.go` — line_uuid allocated by the control plane, fail-closed render | shipped (design-15 D1) |
| Identity carrier on the node | `lattice.singbox-metadata.v2` sidecar, deterministic per-node render (`renderLineMetadataJSON`); `_lattice` in-config key reserved but never emitted (design-15 §4.4) | shipped |
| Our sing-box deploy/manage tool | lr00rl/sing-box fork (`src/core.sh`): stamps identity when Lattice invokes it, exposes secret-free line metadata + `outbound_ref` in `--json list/inspect` | merged on fork main |
| Lines read model + cache | `lines.go`, `lines_cache.go`, `lineusers.go`, `server_inventory.go` | shipped |
| Chain model | sidecar `inbounds[].chain.downstream_line_uuid` (nullable, key required); design-15 declares the upgrade from inferred (host,port) to declared edges | schema frozen; producer missing |
| vpn-core extension | describe/health/plan; capabilities node:read, network:plan, network:apply, task:run | shipped |
| sub-store extension | Go plugin + embedded QuickJS; fetch covers all record kinds; snapshot render ≡ live render (byte-parity tests) | shipped 2026-08-11 |
| Serve path | content-addressed share cache: 30-min revalidation, hash-match extend, stale-if-error, event-driven invalidation | shipped (server a13) |
| Manifest versioning | manifest v2 `compatibility`: server / dashboard_host / runtime_protocol ranges | shipped; plugin↔plugin deps absent |

## 4. Decision registry

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | **The fleet is the database; the projection is the only read path.** UI and API reads join projection rows; node contact happens only in planned tasks (apply) and scheduled collectors (discovery, usage, probes). Nothing in a request path SSHes, scrapes, or blocks on a node. | This is the operator's model stated as a hard rule, and it is what makes "非常多的节点" cheap: the hot path is a join over small rows, not N node round trips. |
| D2 | **Identity lives in the sidecar, not in-config `_lattice` fields.** The underscore-field instinct is right — metadata must ride with the node's own installation and be invisible to sing-box — but sing-box strict-parses unknown config keys, so design-15 §4.4 froze the carrier as the sidecar doc. `_lattice` stays reserved; no writer emits it, no reader requires it. | Established by the fork's own history: in-config stamping landed (ab0b349), then moved outside strict configs (8b54016). The sidecar survives config rewrites and keeps stock sing-box binaries usable. |
| D3 | **Extension contract v2.1: dependencies + preflight.** Manifest gains `dependencies[]` (plugin id, version range, optional flag); the loader refuses enable on unmet deps. Every mutating plan compiles with a typed `checks` section (agent ≥ v, sing-box present, port free per the inventory map, REALITY material known, required extension healthy); apply refuses failed checks and re-validates stale ones. | Today only host-side version ranges exist (manifest `compatibility`). Sub-store already soft-depends on vpn-core for fleet sources; wireguard applies already assume netguard zones (design-13). Dependencies and pre-apply conditions are real — write them into the contract instead of rediscovering them as 2am failures. |
| D4 | **Greenfield lifecycle: enrolled → sing-box-managed → line-managed.** "Enable sing-box management" on an enrolled node compiles one plan: fetch our pinned fork release (checksum-verified), install sing-box core + the `sb` tool, write a zero-inbound base config, start, discover. From that moment the node is read only through its projection; lines arrive via the design-17 overlay. | The fleet today is 100% adopted (233boy hand-built). Growth means bare nodes; the fork exists precisely so the deploy/manage tool is ours to shape. One approved plan per node keeps the L0 gate intact. |
| D5 | **Chain builder: a line is a portable reference; an edge is a declared fact.** The server compiles a consumer node's outbound fragment from the producer line's projection record (address, port, protocol, user credential, REALITY material) — secrets exist only server-side and in the point-to-point fragment. Apply uses the design-17 S2 atomic channel. The edge is declared in the producer's sidecar `chain` block; the server joins declared edges with discovered `outbound_ref`/route-rule evidence into `jump_edges`. | "Another node wants to outbound to this line — pull the info and apply it" is a compile+apply over the projection, not a new subsystem. Declared edges end the (host,port) inference era that design-15 flagged for upgrade. |
| D6 | **Runtime doctrine: platform paths are pure Go; QuickJS is for user scripts only; there is no Node.** Projection joins, plan compilers, fragment renderers, and platform-shaped subscription assembly are Go (proxycore contract, design-17 §4). The embedded QuickJS engine runs exactly one thing: user-authored operator scripts, for sub-store ecosystem compatibility. The dashboard is a static SPA — there is no Node runtime to borrow — and a Node sidecar stays rejected: per-invocation process isolation and host-call budget accounting are the runner's contract, and a shared sidecar breaks both (olympus record). A capability that truly needs Node semantics arrives as a versioned, optional system service with its own isolation design, in its own design doc. | Measured on prod (2026-08-11): 13.5s of WASM-QuickJS script work per render vs milliseconds for the Go render of the same fleet shape. Go is also simply the answer to "极致的性能". |
| D7 | **Performance doctrine for many small nodes.** (a) Projection-first reads — never fan out to nodes in a request path. (b) Diff sync: collectors report content-hash-addressed snapshots; unchanged bytes cost nothing (the a13 serve-cache pattern, generalized). (c) One task channel per agent; fleet operations compile to per-node plans inside ONE approval event (shipped 2026-08-10). (d) Render/serve paths are Go-only and content-addressed with stale-if-error. (e) Every host-call budget is pinned by a counting test, never estimated (the 2026-08-11 incident rule). Scale target: 10³–10⁴ nodes × tens-of-KB configs = a projection measured in MB; the design question is never "can the store hold it" but "did anything touch a node synchronously". | The operator's constraint: very many nodes, very small configs, extreme efficiency. Small configs mean whole-node snapshots are cheap enough that diffing — not sampling — is the sync model. |
| D8 | **Subscriptions are a view over the database.** Fleet lines flow to sub-store through the vpn-core source (rpc:call → export); external feeds and pasted configs enter as ordinary records; operators/scripts transform both identically; shares ride the content-addressed serve cache. L5 adds no new truth — it selects, transforms, and publishes L3/L4 data. | This is the directive's "这不是顺理成章的吗" made literal: sub-store on Lattice is the moment the fleet database becomes composable and publishable. |

## 5. Gaps → slices

| # | Slice | Depends | Done when |
|---|-------|---------|-----------|
| E1 | Extension contract v2.1: `dependencies[]` in the manifest, loader enforcement, plan `checks` section + apply-time revalidation. vpn-core, netguard, wireguard, sub-store manifests updated to declare what they actually need. | — | **Landed 2026-08-12 (server a18, lattice-server#39)**: manifest `dependencies[]` with comparator-set ranges; load gate (absent/out-of-range required dep rejects, chains to a fixpoint) + activation gate (installed-but-inactive refuses with 409, boot arm skips with audit). Plan checks landed as the per-plugin typed revalidation discipline (lineusers/managedline). Remaining: each plugin's next signed release declares its real deps and bumps `compatibility.server` (strict decode requires a18+). |
| E2 | Greenfield install: agent task that fetches the pinned fork release (checksum-verified), installs sing-box + `sb`, writes the zero-inbound base, starts, discovers. | E1 (preflight carries the checks) | A bare enrolled node becomes a projected, zero-line, sing-box-managed node through one approved plan. |
| E3 | Chain builder: line descriptor compile → outbound fragment on the consumer node via the design-17 S2 channel → sidecar `chain` declaration on the producer. | design-17 S2, E1 | Node B gains a working outbound to node A's line through one plan; the edge is visible in both projections. |
| E4 | `jump_edges` producer + topology: join declared edges with discovered `outbound_ref`/route-rule evidence; the relay graph view upgrades from (host,port) inference to declared-first. | none for discovered-only; E3 for declared | The topology view renders the fleet's real chains from projection data alone. |
| E5 | Fleet subscription flow: vpn-core-sourced records for the operator's line groups, share publishing, the daily compose→preview→publish loop — UI per the design-intelligence Product path. | E3/E4 for chain-aware sources; usable today for flat groups | The operator builds, previews, and publishes a fleet subscription without leaving the platform. |

Ordering note: design-17 S1/S2 (managed line overlay) is already in flight and
is the first citizen of the line database — E3 builds directly on its apply
channel. E1 precedes E2/E3 because preflight is how applies stay safe at fleet
scale. E5 is the arc's named endpoint but needs nothing new for flat groups;
it can start in parallel and gain chain-aware sources as E3/E4 land.

## 6. Explicitly not here

Multi-protocol managed rendering (still design-15 D6 / design-17 §6), in-config
`_lattice` emission (D2), any Node.js runtime in the platform (D6), quota/expiry
enforcement, a generic plugin event bus / cron, and external database imports —
the fleet is the database; nothing else gets registered.
