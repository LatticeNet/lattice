# Design 12 — VPN Core: Lines, Users-as-Identity, and 3-D Usage

## Status

Proposed 2026-06-29. Builds on **design-09** (vpn-core/sub-store plugins),
**design-10** (declarative dashboard contributions + scope-gated gateway), and
**design-11** (VPN Manage IA/security migration). Where design-11 migrated the
*existing* page set under plugin ownership, design-12 is the **product redesign**
of the vpn-core domain: it replaces "Inbounds + Discovered" with a unified
**Lines** model, turns **Users** into an identity + credential-set, and makes
**Usage** a `(node, line, user)` accounting surface. design-12 supersedes
design-11's vpn-core page list (Lines replaces Inbounds and Discovered).

## Locked decisions (operator, via interview 2026-06-29)

1. **Ownership = plugin-owned boundary, core-hosted serving.** Lines/Users/Usage
   are the vpn-core plugin's *domain* (it owns the schema, the write/apply
   authority, persistence, and declarative UI ownership). The **server core hosts
   the fast read path and the agent-ingestion transport**, exposed *only* through
   `latticenet.vpn-core/*` in-core RPC (design-11 Phase 3). This is chosen because
   the plugin runtime is a **per-action subprocess** (`system_runner.go`), not a
   live server, and the dashboard gateway (`/api/plugins/call → CallOperator`,
   `rpc.go:140`) only reaches in-core handlers — a runner-backed plugin cannot
   serve live dashboard reads today. A truly autonomous long-lived plugin process
   (socket transport + event subscriptions + agent routing) is explicitly deferred
   as out of scope; it would be weeks of runtime work for no extra user value now.
2. **Lines ships as a unified READ model first.** Merge discovered + managed into
   one node-grouped view; no write/adopt/apply actions in the first slice.
3. **Usage: design the `(node, line, user)` model now; build the collector after
   Lines + Users land.** Degrade gracefully to "stats unavailable" where the core
   has no stats API or where users lack stable identifiers (common on discovered,
   unmanaged configs).
4. **Subscriptions ↔ Sub-Store: set the producer/publisher boundary now, converge
   later.** vpn-core PRODUCES sources (lines, users, credentials, usage); Sub-Store
   COMBINES + publishes. Keep a thin per-user Subscriptions view under vpn-core
   until Sub-Store can deliver per-user (design-11 Phase 5).

## Architecture

```
agents ── push (sing-box inventory, usage snapshots) ──▶ server core (ingestion transport)
                                                              │ writes
                                                              ▼
                                              vpn-core DOMAIN STORE (BoltDB, core-hosted)
                                              Lines · VpnUsers · LineUserBindings · UsageRows
                                                              │ read
dashboard ──▶ /api/plugins/call ──▶ CallOperator ──▶ latticenet.vpn-core/{lines,users,usage,nodes}
                                                       (in-core handlers; vpn-core-namespaced)
host mutation (probe / adopt / apply / add-user) ──▶ Task plan ▶ agent ▶ `sb --json ...`
```

- **Ownership is declarative**: retire the hardcoded UI-ownership switches at
  `internal/plugin/contributions.go:33-40`; the signed manifest is the source of
  truth for which plugin owns which view (design-11 already added `builtin` keys).
- **All vpn-core reads** go through `latticenet.vpn-core/*` RPC, never new
  `/api/proxy/*` HTTP routes. New scopes `vpncore:read` / `vpncore:admin` replace
  the broad `proxy:read` / `proxy:admin` for these services (design-11 open item).
- **Writes are always a reviewed Task plan** (plan → approval → apply), never a
  silent host mutation (design-11 Phase 4 rule).

## Data models (new, in `lattice-sdk/model`)

### Line — the unit replacing Inbound + Discovered
```
Line {
  id              string   // "line_" + stable id
  line_hash_id    string   // STABLE hash; see below. Survives restarts & re-probes.
  node_id         string
  core            string   // sing-box | xray | mihomo  (xray/mihomo TBD)
  source          string   // managed | discovered | imported
  managed         bool     // is the config under Lattice management (editable)?
  name            string
  tag             string   // inbound tag / config name
  type            string   // protocol: vless|vmess|trojan|shadowsocks|hysteria2|...
  listen_host     string   // 0.0.0.0 | 127.0.0.1 | ...
  public_host     string   // node public IP (authoritative = agent-discovered)
  domain          string   // bound TLS/SNI domain if any
  listen_port     int
  outbound_ref    string   // tag of the outbound this line routes to (direct | <host>)
  jump_edges      []string // line_hash_ids this line forwards/relays to (relay graph)
  user_count      int      // computed: bound enabled users
  status          string   // ok | error | stale
  last_error      string
  first_seen_at   time.Time
  last_seen_at    time.Time
  metadata        map[string]string // from sing-box `_lattice` block (see tool §)
}
```
`line_hash_id = sha256(node_id | core | type | listen_host | listen_port | tag |
outbound_fingerprint)`. Stable across re-probes so the relay graph, dedup, and the
future node-line map are deterministic. NOT a DB autoincrement.

### VpnUser — identity + credential set (borrowed from 3x-ui email-identity + s-ui Config map)
```
VpnUser {
  id            string
  email         string  // primary human identity (unique)
  name          string  // display
  enabled       bool
  credentials   []VpnCredential   // one per protocol family
  quota_bytes   int64
  expires_at    time.Time         // <0 / sentinel = "start after first use"
  used_up, used_down int64
  auto_reset    bool; reset_days int; next_reset_at time.Time
  sub_id        string            // subscription token (16-36 chars)
  group, comment string
}
VpnCredential { protocol string; uuid string; password string; auth string; flow string; method string; security string }
LineUserBinding { user_id string; line_hash_id string; enabled bool; flow_override string } // m:n
```
Migration: existing `model.ProxyUser` → `VpnUser` (uuid/password/sub_token map onto a
single credential + `sub_id`; `InboundIDs` → `LineUserBinding`).

### UsageRow — `(node, line, user)` accounting (deeper than today's per-user snapshot)
```
UsageRow {
  ts            time.Time   // interval end
  node_id       string
  line_hash_id  string
  user_id       string
  up_bytes      int64       // delta this interval
  down_bytes    int64
  collector     string      // singbox-clash | singbox-v2ray | xray-grpc | file | http
}
```
Persisted historically (rolled up by period for the Usage page). Reset logic mirrors
3x-ui (`never|hourly|daily|weekly|monthly`). Query keys mirror
`user>>>email>>>traffic>>>up/downlink` and `inbound>>>tag>>>...`.

## sing-box tool additions (`/Probe-Dashboards/sing-box`, the `sb` fork)

Existing JSON surface (already present, `core.sh:1752-1898`): `list info sub
provision backup add change del` with `--json`. New work:

1. **`sb inspect <name> --json`** — normalize one config into the Line shape:
   `{core, tag, type, listen_host, listen_port, users[], outbound{tag,protocol},
   domain, metadata}`. Reads the `.json` config + `.addr` sidecar.
2. **`sb stats [name] --json`** — per-`(line,user)` counters from the sing-box
   Clash API / V2Ray stats service if enabled; else `{ok:false,error:"stats_unavailable"}`.
   Requires the managed config to enable the stats experimental block + stable
   `users[].name` identifiers.
3. **`_lattice` metadata block** inside the inbound JSON
   (`{tag, labels{}, notes, owner}`) — chosen over `comment_xxx` (structured,
   tooling-stable, round-trips through `add/change`). Still *read* legacy
   `comment_xxx` if present.
4. **design-11 Phase 4 hardening (prereq for any write CRUD):** literal filename
   matching (`grep -F` / direct resolution, not regex) in `info/change/del`;
   dashboard calls always pass `--json --addr` + all args so no path reaches
   `ask()`/`select`; alias metadata lives in Lattice, not filename parsing.

## Slice plan

- **S0 — Probe & inventory groundwork (decision-independent).**
  NOTE (2026-06-29): re-checking codex's shipped code against the recovered code
  review found the **server** MEDIUMs were false positives against a stale read —
  the probe already uses `singBoxProbeOutputLimit = maxTaskOutputLimit` (no
  truncation), already de-dups in-flight probes per node
  (`pendingSingboxProbeNodeIDs` + stale eviction + 409), and already has error-path
  tests (`TestSingBoxProbeTaskResultErrorPaths`, `...Deduplicates`,
  `...EvictsStaleEntry`). **Genuinely real and done in S0:** server `nodeSBAddr`
  now validates `PublicIP` with `net.ParseIP` before `sb --addr`; dashboard M1
  (`findPlugin` searched all plugins → scoped to `activePlugins`), M2 (guard the
  VPN-Discovery cross-link + distinct `Radar` icon), M3 (`?node=` array coercion).
  All built green (server `go build` + sing-box tests; dashboard `pnpm build`).
  **Deferred to S1** (belongs with the Line persistence model): persist the
  inventory + `first_seen_at`, and a first-class `Task.Action` field (codex's
  script-marker fingerprint works + is tested, so no rush).
- **S1 — Lines read-model.** `sb inspect --json` + `_lattice`; `Line` model +
  `line_hash_id`; merge discovered + managed-rendered into node-grouped Lines;
  `latticenet.vpn-core/lines` RPC (`list`, `get`); Vue **Lines** view (rename
  Inbounds → Lines, fold Discovered in) with outbound detail drawer + relay edges.
- **S2 — VpnUser identity + credential set.** Model + `LineUserBinding`; migrate
  `ProxyUser`; `latticenet.vpn-core/users` RPC; Users view rework (add user once,
  bind to many lines).
- **S3 — Usage 3-D.** `sb stats --json` collector + agent reporting; `UsageRow`
  history; `latticenet.vpn-core/usage` RPC; Usage page (user × node dimensions),
  graceful "stats unavailable".
- **S4 — Node Profiles → vpn-core runtime.** Per-node: core type/version, config
  path, service status, last probe/apply, recent logs, supported capabilities.
- **S5 — Subscriptions ↔ Sub-Store convergence.** Boundary + thin Subscriptions
  view; plan toward Sub-Store per-user delivery (design-11 Phase 5).
- **Map-prep** (through all slices): stable `line_hash_id` + `jump_edges` so the
  future node-location / node-line map is a pure presentation layer.

## Security

- New narrow scopes `vpncore:read|admin`, `substore:read|admin` replace broad
  `proxy:*` on the new RPC (design-11 open item). Node-restricted principals see
  only their nodes' lines/usage.
- Gateway enforces declared interface scopes server-side + audits allow/deny
  (already true, design-11). Every new method is added to the manifest interface
  contract and re-signed via `cmd/pluginsign`.
- Host mutations (adopt/apply/add-user) are reviewed Task plans only.
- sing-box CRUD is gated behind the Phase-4 literal-matching hardening.

## Test matrix (per slice, before deploy)

- RBAC: `vpncore:read` sees Lines/Users/Usage read-only; `vpncore:admin` sees
  mutations; node-restricted principal scoped to owned nodes.
- Lines: discovered + managed merge with correct `source`; stable `line_hash_id`
  across re-probe; outbound + relay edges render; restart preserves inventory.
- Users: one identity binds to many lines; subscription reflects bindings.
- Usage: `(node,line,user)` rows accumulate; reset by period; "stats unavailable"
  on cores without a stats API never looks like zero traffic.
- Plugin inactive ⇒ no vpn-core nav; gateway `list`/`get` reachable only when active.

## Deferred / rejected

- Autonomous long-lived plugin process (socket RPC + event subscriptions) — out
  of scope; revisit only if a real need outgrows core-hosted serving.
- Reimplementing Sub-Store in Go / copying its source — rejected (AGPL/GPL
  boundary, design-11).
- `comment_xxx` as the primary annotation model — rejected in favor of `_lattice`.
