# Design 13 — WireGuard + NetGuard as first-class plugins (security-group-grade network control)

> Status: draft for review · Author: design pass · Date: 2026-07-08
> Builds on: ADR-001 (plugin foundation), design-05 (network ACL), design-08
> (real runners), design-09/10/11 (vpn-core plugin migration pattern),
> `internal/network/nft.go`, `internal/netpolicy`, `internal/wireguard`,
> the `plan → approve → apply` spine, and the 2026-07-07/08 fleet security
> audit of `dmit-eb-wee`.
> Constraints inherited: pure Go, zero CGo, new dep ⇒ ADR, security-first,
> fail-closed, audit everything, no plugin JS in the browser (strict CSP).

---

## 0. The operator ask (verbatim intent)

Split WireGuard and nftables out of the current inventory-adjacent forms into
**two independent plugin capabilities**, each with **cloud-provider
security-group-grade graphical control**: accurate, easy to operate, and
feature-complete. In real use they must be able to take a **blank machine from
zero** — automatic prerequisite preparation, well-defined parsing/loading of
existing on-box configuration, and support for as much of the WireGuard and
nftables feature surface as practical.

The motivating incident (2026-07-08, node `dmit-eb-wee`) is the requirements
spec in miniature. The dashboard baseline said `eth0 / 10.66.0.0/24` with 15
public TCP+UDP ports; the machine actually had **no WireGuard at all**, a
default-accept nft state, SSH tcp/22 *missing* from the baseline, ports with no
listener (115), Tailscale-only listeners recorded as public ports
(42622/48358), needed UDP ports absent (17892/17894/41641), and a hard
dependency on `tailscale0` that the guard render would have dropped. Applying
that baseline would have produced a policy-drop lockout. Every one of those
failure modes maps to a feature below.

---

## 1. Decision summary

| # | Decision area | Call made | Why (one line) |
|---|---|---|---|
| D1 | Packaging | Two official signed **system plugins**: `latticenet.netguard` and `latticenet.wireguard`, following the vpn-core pattern (design-09/10/11) | Independent lifecycles, plugin-owned IA, engine stays core |
| D2 | ADR-001 D5 compatibility | **Engine = core, providers = plugin**, reinterpreted: the safety spine (approvals, plan-hash, task dispatch, watchdog/rollback scaffolding, broker) stays CORE; WG topology + firewall authoring/rendering become plugin-owned domains | Same split that made vpn-core safe; trust base does not grow |
| D3 | NetGuard model | Evolve `NFTInputs` + `NetPolicy` + `Group*` into **Zones + SecurityGroups + NodeBindings**; do not invent a parallel model | `NetRefGroup`/`GroupNetPolicy` already exist; migration beats reinvention |
| D4 | Authoring ground truth | **Reality-first**: agents report listeners + `nft -j` ruleset + interfaces; the UI diffs intent vs reality and generates suggestions; drift is a first-class signal | Fixes the exact dmit-eb-wee baseline-vs-reality failure |
| D5 | Blank-machine bootstrap | Server-rendered **preflight → capability facts → bootstrap plan** through the existing bounded task executor; no new agent daemons | Agent stays a generic sandboxed executor (taskexec.go) |
| D6 | Existing-config adoption | Read-only **discovery bridges** (like `singboxdiscover`): parse `wg show all dump` + `/etc/wireguard/*.conf` + `nft -j list ruleset`; explicit operator "adopt" action, never silent takeover | Proven pattern; foreign state stays visible but unmanaged |
| D7 | nftables coverage | Three-tier ladder: **L1** security groups (filter), **L2** advanced objects (NAT/port-forward, rate-limit, logging, forward chain), **L3** linted raw-snippet escape hatch | Graphical ceiling acknowledged; full nft power reachable without giving up review |
| D8 | WireGuard coverage | Full interface+peer option surface (MTU/DNS/Table/FwMark/keepalive/PSK), **topology modes** (mesh, hub-and-spoke, custom), **external peers** (laptops/phones) with one-time config/QR export | "Cloud VPN console" parity, not just fleet mesh |
| D9 | WG apply safety parity | WireGuard apply gains the same **snapshot → watchdog → selfcheck** dead-man protection nft already has (today it has none: server.go:4810-4821) | A bad wg0.conf must not strand a node |
| D10 | Scopes | New narrow scopes `netguard:read/admin`, `wireguard:read/admin`; plugins declare capabilities `node:read`, `network:plan`, `network:apply`, `task:run` | design-11 flagged broad `proxy:*` scopes as a defect; don't repeat it |
| D11 | Fleet rollout | Group-wide changes apply through **canary → health-gate → continue** batches, never fleet-parallel | Blast-radius control for the highest-risk mutation in the product |
| D12 | Browser code | Plugin UI = manifest `ui.nav` + `builtin` component keys mounting dashboard-owned Vue pages; **zero plugin JS**, strict CSP preserved | design-10/11 contract; rich UX needs first-party pages |

New external Go dependencies required: **none**. nft JSON parsing is
`encoding/json` over `nft -j` output produced on-node; WG dump parsing is
tab-split text. (If a future slice wants server-side *semantic* validation of
foreign rulesets beyond JSON well-formedness, that is an ADR conversation —
not needed for anything in this design.)

---

## 2. Why this is compatible with ADR-001 D5 and design-05 §2

Design-05 §2 ruled "CORE server-owned provider, **not a plugin**" for netpolicy,
and ADR-001's matrix pins "Network plan/apply, WireGuard, tunnels" as CORE.
Those decisions were about **trust**, and they still hold where it matters:

- The **approval flow** (`handleApprove`, plan_sha256 binding, TOCTOU defense,
  per-plugin staleness checks — server.go:5224-5382) stays core.
- The **apply-script scaffolding** (validate → snapshot → watchdog → commit →
  selfcheck; `nftGuardApplyScript` server.go:4990, `nftRollbackWatchdogScript`
  server.go:5054) stays core, exposed to plugins only as a **template the core
  fills**, never as free-form shell authored by plugin code.
- The **task executor** and its sandbox (taskexec.go) stay core.
- **RBAC, store, audit, broker** stay core.

What moves to plugin ownership is what moved for vpn-core: the domain model,
the renderers/compilers as registered providers, the RPC interface surface,
and the dashboard information architecture. vpn-core proved this shape works
for a crown-jewel domain (proxy credentials + reviewed host mutations) without
weakening the trust base. The same argument transfers: a signed first-party
plugin with `network:plan`/`network:apply`/`task:run` host-risk capabilities is
exactly what the ADR-001 capability table was built for.

Practically, "plugin" here means, per plugin:

1. A repo (`lattice-plugin-netguard`, `lattice-plugin-wireguard`) with a signed
   manifest declaring capabilities, `ui` contributions, and `interfaces`.
2. In-core engine packages (`internal/netguard`, evolved `internal/wireguard`)
   registered on the RPC bus under the plugin's namespace, callable only
   through `/api/plugins/call` + the legacy `/api/network/*` routes during
   migration.
3. Dashboard-owned Vue pages mounted through allow-listed `builtin` component
   keys bound to the official plugin ids (design-11 phase-2 mechanism).
4. Plugin activation controls visibility: deactivate netguard and the firewall
   IA disappears; the applied node state remains untouched (deactivation is an
   IA/authoring change, never an implicit firewall mutation).

---

## 3. Current state (grounded, 2026-07-08)

What exists — reuse it, don't rebuild it:

| Asset | Where | State |
|---|---|---|
| Baseline model `NFTInputs` (iface, wg CIDR, 4 port lists) | `lattice-sdk/model/model.go:330-348` | Thin; no zones, no port ranges, no apply-state, no version field |
| Per-node ACL `NetPolicy`/`NetRule`/`NetEndpoint` (+`LastPlanSHA/LastAppliedAt/LastError`) | `model.go:452-516` | Live; ingress folds into guard, egress separate |
| Group layer `Group`/`GroupSelector`/`GroupNetPolicy`/`GroupNetRule`, `NetRefGroup` | `model.go:524-589` | Live; groups expand server-side pre-compile |
| Guard renderer (single `table inet lattice_guard`, policy drop, `iifname` public rules, `wg_peers4` set) | `internal/network/nft.go:51-84` | Live; injection-defended (`NormalizeNFTPlan` :88) |
| ACL compilers (egress ruleset/plan, ingress input-rules) | `internal/netpolicy/compile.go:39,49,209` | Live; domain remotes via agent-refreshed named sets |
| nft apply safety chain (plan_sha256 → `nft -c` → snapshot → 60s setsid watchdog → commit → selfcheck → `assert_watchdog_clean`) | server.go:4990-5082 | Live for `nft` + `nftpolicy` |
| WG mesh brain (`BuildMesh`, `GenerateConfig`, `/32` AllowedIPs pinning, private-key placeholder) | `internal/wireguard/wireguard.go:24,61,105,184` | Live; **apply has no rollback/watchdog** (server.go:4810-4821) |
| Agent = generic sandboxed executor (`sh|bash|python3|node`, `-allow-exec`/`-allow-root-exec`, rlimits/cgroup) + nft helpers (`--selfcheck-controlplane`, `--update-nft-domain-set`) | `taskexec.go:19-24,286-434`; agent `main.go:196-202,1254` | Live; **no firewall/WG logic on the agent** — by design |
| Dashboard: `GuardView.vue` (baseline editor), `WireGuardView.vue` (mesh plan), `PlanReviewDialog.vue`, `usePlanDigest.ts` | `lattice-dashboard/src/views/networking/*` | Live; forms are port-CSV level, no SG UX |
| Plugin foundation: signed manifests + `ui.nav/views` (`builtin` keys) + `interfaces` + `/api/plugins/call` gateway + `/api/plugin-contributions` | design-10/11, vpn-core v0.7.1 manifest | Live and proven by vpn-core/sub-store |

Known gaps this design must close (from the code audit):

1. **WireGuard apply has no dead-man protection** while both nft paths do.
2. **No drift visibility**: `/etc/lattice/guard.nft` is never read back;
   `NFTInputs` lacks `LastPlanSHA/LastAppliedAt/LastError` (NetPolicy has them).
3. **No reality input**: nothing reports listening sockets or the live ruleset,
   so baselines are authored blind (the dmit-eb-wee failure).
4. **No trusted-interface concept**: guard renders only `iifname "<public>"` +
   `wg_peers4`; a Tailscale-dependent node cannot be safely guarded.
5. **Selfcheck silently skipped** when `public_url` is unset (server.go:4992-4998).
6. **Watchdog window hardcoded 60s** (server.go:5070-5072).
7. **No optimistic concurrency** on baseline upserts (server_nft.go:65-74).
8. No bootstrap story: nft/wg presence is assumed, never prepared.

---

## 4. Plugin 1 — `latticenet.netguard` (firewall / security groups)

### 4.1 Product shape

Think "AWS security groups + the parts they got wrong fixed":

- **Zones** — named trust surfaces built from interfaces and/or CIDRs.
  Built-ins: `public` (the node's default-route interface), `loopback`
  (always-accept, non-editable), and auto-registered overlay zones
  (`wireguard`, `tailscale`) when those interfaces are discovered or managed.
  Zone rules render as `iifname` / `ip saddr` matches. This is the fix for
  gap 4: "trust everything arriving on `tailscale0`" becomes one checkbox,
  reviewed in the plan like everything else.
- **Security groups** — named, reusable, ordered rule sets attached to any
  number of nodes. A rule is
  `{direction, action, protocol, port_ranges, remote, comment, disabled}` where
  `remote ∈ {cidr, node, group, zone, domain(egress-only), any}`.
  Group-as-remote resolves to member nodes' current mesh+public IPs at compile
  time (cloud "source: sg-xxx" semantics, using the existing `NetRefGroup`
  expansion).
- **Node bindings** — a node's effective firewall =
  `base scaffold (ct established/related, lo, control-plane allows)`
  + attached groups in priority order + per-node override rules. Every
  effective rule carries provenance (which group/rule produced it).
- **Reality panel** — per node: live listeners, live ruleset (managed table +
  foreign tables), diff vs intent, one-click suggestions.

### 4.2 Data model (SDK additions; existing types stay for migration)

```go
// GuardZone is a named trust surface on a node or fleet-wide.
type GuardZone struct {
    ID          string   `json:"id"`
    Name        string   `json:"name"`            // "public", "wireguard", "tailscale", custom
    Builtin     bool     `json:"builtin,omitempty"`
    Interfaces  []string `json:"interfaces,omitempty"` // iface-name charset-validated
    CIDRs       []string `json:"cidrs,omitempty"`      // canonicalized v4/v6
    Description string   `json:"description,omitempty"`
    CreatedAt   time.Time `json:"created_at"`
    UpdatedAt   time.Time `json:"updated_at"`
}

// GuardPortRange replaces bare []int ports. "80", "80,443", "1000-2000".
type GuardPortRange struct {
    From int `json:"from"`
    To   int `json:"to"` // == From for single ports
}

// GuardRule is one security-group rule.
type GuardRule struct {
    ID         string           `json:"id"`
    Action     string           `json:"action"`     // allow | deny
    Direction  string           `json:"direction"`  // ingress | egress | forward(v2)
    Protocol   string           `json:"protocol"`   // tcp | udp | icmp | icmpv6 | any
    Ports      []GuardPortRange `json:"ports,omitempty"`
    Remote     NetEndpoint      `json:"remote"`     // reuse; add Kind "zone"
    RateLimit  string           `json:"rate_limit,omitempty"` // v2: "10/second", validated grammar
    Log        bool             `json:"log,omitempty"`        // v2: log prefix on match
    Comment    string           `json:"comment,omitempty"`
    Disabled   bool             `json:"disabled,omitempty"`
}

// SecurityGroup is a reusable named rule set.
type SecurityGroup struct {
    ID          string      `json:"id"`
    Name        string      `json:"name"`
    Description string      `json:"description,omitempty"`
    Rules       []GuardRule `json:"rules"`
    Version     int64       `json:"version"` // optimistic concurrency (gap 7)
    CreatedAt   time.Time   `json:"created_at"`
    UpdatedAt   time.Time   `json:"updated_at"`
}

// NodeGuardBinding is the per-node composition + apply state (gap 2).
type NodeGuardBinding struct {
    NodeID        string      `json:"node_id"`
    GroupIDs      []string    `json:"group_ids"`          // ordered
    Overrides     []GuardRule `json:"overrides,omitempty"` // rendered before groups
    ZoneIDs       []string    `json:"zone_ids,omitempty"`  // trusted zones on this node
    Managed       bool        `json:"managed"`             // false = observe-only, never plan
    Version       int64       `json:"version"`
    LastPlanSHA   string      `json:"last_plan_sha,omitempty"`
    LastAppliedAt time.Time   `json:"last_applied_at,omitempty"`
    LastError     string      `json:"last_error,omitempty"`
    AppliedTableSHA string    `json:"applied_table_sha,omitempty"` // drift anchor
    CreatedAt     time.Time   `json:"created_at"`
    UpdatedAt     time.Time   `json:"updated_at"`
}

// GuardNodeReality is agent-reported ground truth (low-trust, display+diff only).
type GuardNodeReality struct {
    NodeID       string             `json:"node_id"`
    Listeners    []GuardListener    `json:"listeners,omitempty"`     // proto, port, bind addr, process
    Interfaces   []GuardInterface   `json:"interfaces,omitempty"`    // name, addrs, up
    ManagedSHA   string             `json:"managed_sha,omitempty"`   // sha256(nft list table inet lattice_guard)
    ForeignTables []string          `json:"foreign_tables,omitempty"`// e.g. "ip filter (docker)", "inet ts-input"
    NFTVersion   string             `json:"nft_version,omitempty"`
    CollectedAt  time.Time          `json:"collected_at"`
}
```

Non-secret throughout — nothing here touches `crypto.go`.

### 4.3 Reality-first authoring (D4 — the dmit-eb-wee fix)

New bounded discovery task (reviewed like any task, read-only script):
`ss -tulpnH` (fallback `netstat`), `ip -j addr`, `nft -j list ruleset`,
`nft --version`. The agent gains one helper subcommand,
`--report-guard-reality`, mirroring `--update-nft-domain-set`'s shape: run the
collectors, normalize to `GuardNodeReality` JSON, POST to
`/api/agent/guard-reality` (bearer-authed, node-forced like proxy-usage).
Server stores the latest snapshot per node (bounded).

The UI then renders, per node:

- **Suggestions** (server-computed, operator-confirmed, never auto-applied):
  - listener with no matching allow → "add tcp/22 (sshd) to ingress?"
  - allow with no listener → "no listener on udp/115 — remove?"
  - listener bound to an overlay address only → "42622 binds tailscale0 only —
    this belongs in the `tailscale` zone, not `public`."
  - overlay interface present but unzoned → "tailscale0 detected; add the
    `tailscale` zone to this node's binding?" (the lockout preventer)
- **Drift badge**: `ManagedSHA != AppliedTableSHA` → `drift` state with a
  one-click **Review & Re-apply** (reuses the iter-055 proxy `config_stale`
  pattern). Heartbeat-cheap: the agent recomputes the managed-table hash on its
  existing poll cadence; full reality snapshots stay on-demand + daily.
- **Foreign tables** listed read-only (docker-managed iptables-nft, Tailscale
  chains) with an explicit "coexisting, unmanaged" label. NetGuard never
  flushes the ruleset — the renderer keeps today's
  `destroy table inet lattice_guard` idempotent-replace scope.

### 4.4 Compile pipeline

One compiler, three outputs, all deterministic and byte-stable for
`plan_sha256`:

```
Zones + SecurityGroups + NodeGuardBinding + NetPolicy(legacy) + control-plane opts
        │ resolve: groups→member IPs, nodes→IPs, zones→iface/CIDR matches,
        │          domains→named sets (existing lattice_dom_* mechanism)
        ▼
  []NFTInputRule-superset (typed, canonicalized)
        ├─ ingress → table inet lattice_guard   (existing single-table contract)
        ├─ egress  → table inet lattice_policy  (existing)
        └─ v2: nat → table inet lattice_nat     (new, same plan/approve/apply)
```

Invariant order inside `lattice_guard` (unchanged, now with zones):
`ct state established,related accept` → `iif lo accept` → **zone accepts**
(`iifname "tailscale0" accept` etc.) → per-node overrides → group rules in
binding order → legacy broad public/WG port allows (until migrated) →
`counter drop`. Deny rules keep beating broad allows by position, exactly as
today.

**Plan linting** (compile-time, fail-closed, each with an explicit
operator-visible override where sane):

- Control-plane allow present (existing invariant, kept red-if-removed).
- **Management-port lockout check**: if reality shows an sshd listener and the
  composed ingress would drop it from every non-overlay zone, the plan is
  refused with `lockout_risk: ssh` unless the operator sets
  `accept_lockout_risk` (audited). This turns the dmit-eb-wee scenario from a
  post-apply rollback into a pre-plan refusal.
- Selfcheck required: plans for nodes without a configured `public_url` render
  a prominent "unverified apply" warning in the plan text and require the same
  explicit acknowledgement (gap 5 → loud, no longer silent).
- Zone/interface references must exist in the node's last reality snapshot
  (warn) — you cannot trust `wg0` before `wg0` exists.

### 4.5 Blank-machine bootstrap (D5)

`POST latticenet.netguard/nodes.preflight` queues the read-only discovery task
above plus capability probes (`command -v nft`, distro/package-manager sniff
from `/etc/os-release`, systemd presence). Results persist as capability facts
on the reality snapshot. If nftables is missing, the UI offers a **bootstrap
plan**: a server-rendered install script from a small distro matrix
(`apt-get install -y nftables` / `dnf install -y` / `apk add`), plus
`systemctl enable nftables` where applicable — reviewed and applied through
the standard approval path (`task:run`, root gate `-allow-root-exec` already
exists for exactly this: taskexec.go:151). Kernels without nft (`nft -c`
failing on a trivial table) fail the preflight with a clear "unsupported node"
state rather than a broken plan later.

First guard enablement on a fresh node always goes through:
preflight → suggested baseline from listeners → operator edits → plan
(linted) → approve → canary-style apply with watchdog + selfcheck.

### 4.6 nftables feature ladder (D7)

| Tier | Features | Surface |
|---|---|---|
| **L1 (this design's core)** | inet filter ingress/egress; tcp/udp/icmp/icmpv6/any; port ranges; remotes cidr/node/group/zone/domain/any; ct scaffold; comments; counter drop; named sets (domains, wg peers, control-plane) | Full graphical CRUD |
| **L2** | NAT: masquerade (WG/router nodes) + DNAT port-forwards in `table inet lattice_nat`; per-rule `limit rate` (validated grammar, never free text); `log prefix "lattice-guard "` on flagged rules; forward chain for router-role nodes; MSS clamp toggle | Graphical, behind per-feature panels |
| **L3** | Operator-authored **raw nft snippets**: verbatim blocks pinned into a dedicated `chain operator_raw` inside the managed tables. Linted fail-closed: parseable under `nft -c` in context; forbidden verbs (`flush ruleset`, `destroy`/`delete table` of anything non-lattice, `insert` into foreign chains); rendered verbatim in the plan diff | Escape hatch with review, not a bypass |
| **Out of graphical scope** | arp/bridge/netdev families, flowtables, quotas/meters, custom hook priorities | Visible read-only in the adopted-ruleset viewer; L3 snippets if truly needed |

### 4.7 UI contributions (manifest)

Section `network-guard` (plugin-owned, design-11 dynamic-section mechanism):

| Nav | builtin component key | Content |
|---|---|---|
| Overview | `netguard.overview` | Fleet posture: managed/unmanaged/drifted/lockout-risk counts, last applies |
| Security Groups | `netguard.groups` | SG list + rule editor (the AWS-console analog: inline rule rows, port-range syntax, remote picker with CIDR/node/group/zone autocomplete, live validation, dirty-state diff) |
| Zones | `netguard.zones` | Zone CRUD + per-node zone presence from reality |
| Nodes | `netguard.nodes` | Binding list: attached groups, drift badge, managed toggle, plan/apply state |
| Node Firewall | `netguard.node-detail` | Effective rules with provenance; reality panel (listeners/foreign tables); suggestions; Review & Re-apply |
| Raw & NAT (v2/v3) | `netguard.advanced` | Port-forwards, rate limits, raw snippets |

`interfaces` (RPC, namespaced `latticenet.netguard/…`, all through
`/api/plugins/call`): `groups.list/get/upsert/delete`, `zones.*`,
`bindings.list/get/upsert`, `nodes.reality/preflight/suggestions`,
`plan.render` (returns the approval like `/api/network/nft/plan` does),
`drift.list`. Scopes: reads `netguard:read`, mutations `netguard:admin`,
plan/approve keep requiring `network:plan`/`network:apply` (unchanged high bar).

---

## 5. Plugin 2 — `latticenet.wireguard` (VPN networks)

### 5.1 Product shape

From "one implicit fleet mesh" to "networks as objects":

- **WGNetwork** — named network with CIDR, topology (`mesh` |
  `hub-and-spoke` | `custom`), default listen port, default keepalive, DNS,
  MTU. Multiple networks per fleet; multiple interfaces per node
  (`wg0`, `wg1`, one per network membership).
- **WGMembership** — node ⇄ network: address (server-allocated from the
  network CIDR, `/32`-pinned as today), role (`hub` | `spoke` | `peer`),
  listen port, endpoint override, per-membership keepalive/MTU override,
  extra `AllowedIPs` (gateway routes a hub advertises, e.g. `0.0.0.0/0` for an
  exit node or a LAN CIDR), fwmark/table for policy-routing setups.
- **WGExternalPeer** — non-node devices (laptop/phone): name, address
  allocation, allowed-ips. Server generates the device config **once**
  (private key included, rendered one-time exactly like recovery codes /
  subscription-token rotation), displays conf + QR (server-rendered data-URI
  PNG — the ADR-001 D12 CSP-safe QR path already designed for TOTP), stores
  only the public key + metadata afterwards.
- **Status** — per-peer last-handshake age, rx/tx, current endpoint from
  `wg show all dump`, rendered as a topology graph (inline SVG, CSP-safe,
  same discipline as the netpolicy graph) with handshake-health coloring.

### 5.2 Keys and secrets (explicit stance)

- **Node private keys never reach the server** — unchanged. The existing
  `__LATTICE_WG_PRIVATE_KEY__` placeholder + node-local key file mechanism
  (`wireguard.go:24`, apply script server.go:4810) is kept; bootstrap
  generates the key on-node (`wg genkey` in the reviewed script, key file
  0600, pubkey reported back via the existing `-wg-pubkey` report path or a
  task result).
- **External-peer private keys**: generated server-side (device can't run an
  agent), shown once, never persisted. Regeneration = new key, old config
  invalid. Audited as `wireguard.peer.issued`.
- **Preshared keys (v2, optional per network)**: pairwise PSKs generated
  server-side, envelope-encrypted at rest via the existing `crypto.go`
  boundary, delivered inside apply-task scripts — which are **already
  encrypted at rest** for exactly this reason (proxycore precedent,
  iter-043). Redacted from plan text (`<psk redacted, sha256:…>`), hash-bound
  into `plan_sha256`.

### 5.3 Topology compilation

`BuildMesh` (`wireguard.go:61`) generalizes to `BuildTopology(network,
memberships, target)`:

- `mesh`: today's behavior — every keyed member peers with every other;
  `Endpoint` only for directly-reachable peers; keepalive 25 default.
- `hub-and-spoke`: spokes peer only with hubs; hubs carry
  spoke `/32`s (+ their extra AllowedIPs); spokes' AllowedIPs toward hubs
  include the network CIDR (and any hub-advertised routes). Hub nodes get
  `sysctl net.ipv4.ip_forward=1` (+v6 counterpart) in their bootstrap plan and
  a suggested masquerade/forward rule **surfaced through netguard** (§6).
- `custom`: explicit edge list in the network object; compiler validates
  connectivity of the declared graph and refuses unreachable members.

`/32`(v4) / `/128`(v6) AllowedIPs pinning for member addresses stays a hard
invariant (`hostCIDR`, `wireguard.go:184`) — extra routes are additive,
reviewed, and may never widen another member's claimed address.

### 5.4 Adoption of existing configs (D6)

Discovery task (read-only): `wg show all dump` (machine-readable: iface,
pubkey, psk-set, endpoint, allowed-ips, handshake, rx/tx, keepalive per line) +
`ls /etc/wireguard/*.conf` + a **structure-only** conf parse (Interface/Peer
sections, keys **redacted at source**: the parser emits `has_private_key:
true`, never the value; PostUp/PostDown captured verbatim for display only).
Results land in a `wireguard.discovered` view exactly like `singboxdiscover`
did for sing-box: read-only first; an explicit **Adopt** action maps a live
interface onto a new/existing `WGNetwork` + memberships, marking fields the
operator must resolve (address collisions, unknown peers → proposed external
peers). Foreign interfaces never silently become managed.

### 5.5 Full option surface (D8)

| Option | Tier | Notes |
|---|---|---|
| Address, ListenPort, PrivateKey(placeholder), PublicKey | v1 | today |
| PersistentKeepalive, Endpoint, AllowedIPs(+extra routes) | v1 | today + extras |
| MTU, DNS | v1 | per network + per membership override |
| Table, FwMark | v2 | policy routing; rendered only when set |
| PresharedKey | v2 | §5.2 stance |
| PreUp/PostUp/PreDown/PostDown | v2 | **templated allowlist only** (named templates: "enable forwarding", "add masquerade via netguard", "custom → L3-style linted snippet"); never free text straight into root shell |
| SaveConfig | never | conflicts with server-owned rendering |

### 5.6 Apply safety parity (D9 — closes gap 1)

New WG apply script template (core-owned, same shape as nft):

```
render candidate → wg-quick strip/parse sanity (wg-quick doesn't dry-run;
use `wg syncconf` semantics where possible) → snapshot current conf +
`wg show <if> dump` → arm dead-man watchdog (restore snapshot conf,
wg-quick down/up) → swap + wg-quick up (or syncconf for live reload without
tunnel drop when only peers changed) → `lattice-agent
--selfcheck-controlplane` → assert watchdog clean → disarm → mark active
```

Peer-only changes prefer `wg syncconf <if> <(wg-quick strip <conf>)` so
established tunnels don't flap — full `down/up` reserved for
interface-level changes (address/port/MTU). Watchdog window becomes a
per-plugin constant fed from config rather than an inline literal (fixes
gap 6 for both plugins).

### 5.7 Blank-machine bootstrap

Preflight: kernel module (`modprobe -n wireguard` / in-tree ≥5.6 check via
`uname -r`), `command -v wg wg-quick`, package manager sniff. Bootstrap plan
(reviewed): install `wireguard-tools` (matrix per distro), generate node key
(0600), enable `wg-quick@<if>` systemd unit for boot persistence (with
non-systemd fallback documented as manual), optional forwarding sysctls for
hub role. Exit state: node shows "ready (keyed, no interface)" and its pubkey
is registered — from there, membership + plan + apply is the normal path.

### 5.8 UI contributions

Section `vpn-networks` (or fold under a shared `network` section — final IA
choice at implementation):

| Nav | builtin key | Content |
|---|---|---|
| Networks | `wireguard.networks` | Network CRUD, topology mode, CIDR/allocation table |
| Topology | `wireguard.topology` | Inline-SVG graph: members, edges, handshake-age coloring, rx/tx on hover |
| Members | `wireguard.members` | Node memberships, roles, addresses, per-node apply state + drift |
| Devices | `wireguard.devices` | External peers, one-time config/QR issuance, revocation |
| Discovered | `wireguard.discovered` | Adoption bridge for existing on-box configs |

`interfaces`: `networks.*`, `members.*`, `devices.issue/revoke/list`,
`discovered.list/adopt`, `status.query`, `plan.render`. Scopes:
`wireguard:read` / `wireguard:admin` + the same `network:plan/apply` gates.

---

## 6. Cross-plugin contract (deliberately loose)

WireGuard and NetGuard must compose without hard-coupling:

- The wireguard plugin **publishes facts** (server-owned, not RPC-to-RPC): per
  node, its managed interfaces (`wg0`, address, listen port, network CIDR).
- NetGuard **consumes facts**: auto-maintains the built-in `wireguard` zone
  membership per node; when a membership's listen port is created/changed, it
  raises a suggestion on the node's binding ("allow udp/51820 in `public`?")
  — a suggestion, never an auto-rule.
- Hub masquerade/forward needs render as **netguard suggestions** attached to
  the WG bootstrap flow ("this hub needs: forward chain accept for wg0 ↔
  eth0, masquerade on eth0 — review in NetGuard").
- Either plugin fully works with the other disabled: netguard's `wireguard`
  zone just goes empty/manual; wireguard's port suggestions surface in its own
  UI with "NetGuard not active — open port manually."

The same fact mechanism covers Tailscale today (reality-reported interface →
`tailscale` zone availability) without a Tailscale plugin existing yet.

---

## 7. Migration & compatibility

1. **`NFTInputs` → legacy baseline group.** A one-time converter renders each
   node's `NFTInputs` into a node-private SecurityGroup
   (`legacy-baseline-<node>`) + binding (public zone = `InterfaceName`,
   `wireguard` zone = `WireGuardCIDR`). Byte-compatibility gate: the new
   compiler over the converted state must reproduce today's
   `GenerateNFTPlan` output **byte-identically** for every existing baseline
   (table-driven test over real store fixtures) before the old path is
   retired. `/api/network/nft/inputs` stays as a compatibility shim writing
   through to the converted objects for one release, then read-only, then
   removed.
2. **`NetPolicy`/`Group*` → GuardRules.** Ingress/egress `NetRule`s map 1:1
   into `GuardRule` (ports list → single-port ranges). `GroupNetPolicy`
   becomes a SecurityGroup bound via the existing group selector. The three
   compilers in `internal/netpolicy` become the netguard compiler's backend
   and keep their tests.
3. **Dashboard**: `GuardView.vue` / `WireGuardView.vue` routes gain redirects
   to the plugin routes (`/plugins/latticenet.netguard/...`), same pattern as
   `/proxy/*` → vpn-manage. Static nav entries removed only after parity
   checks (design-11 test-matrix discipline).
4. **Approvals**: new plans use `Approval.Plugin == "netguard" | "wireguard"`;
   the approve handler treats them with the same plan-hash requirement; old
   `nft`/`nftpolicy`/`wireguard` approvals continue to verify during the
   transition window.
5. **Agent**: zero breaking changes. New helper `--report-guard-reality` ships
   in a normal prerelease agent train; all new behavior is server-rendered
   scripts + one reporting endpoint. Old agents simply don't report reality
   (UI shows "reality unknown — agent ≥ vX.Y needed").

---

## 8. Security

- **Trust base unchanged** (D2): plugins are signed system-tier artifacts;
  `network:plan`/`network:apply`/`task:run` stay host-risk, signature-required,
  fail-closed (`VerifyInstallManifest` path). The broker/gateway checks scopes
  server-side per design-11 fixes.
- **Injection**: all new operator strings ride the existing
  parse-and-re-emit discipline (`NormalizeNFTPlan`, `ValidatePublicKey`,
  `ifaceNameRe`, sanitized comments). New grammars (rate-limit, port-range,
  zone names) are closed grammars with table-driven tests, never
  interpolated free text. L3 raw snippets are the sole exception and are
  linted + fenced + fully visible in plan diffs.
- **Secrets**: node WG private keys never leave nodes; external-peer privkeys
  shown once, never stored; PSKs encrypted at rest + redacted-but-hash-bound
  in plans; discovery parsers redact key material at the source (§5.4).
- **Lockout defense in depth**: pre-plan linting (lockout_risk, zone-exists,
  selfcheck-required) → `nft -c` → snapshot → watchdog (now configurable) →
  selfcheck → `assert_watchdog_clean` → drift detection after the fact. WG
  gains the same chain (D9). Canary batches for group-wide changes (D11):
  server queues node 1, waits for task success + fresh heartbeat + (when
  available) reality hash match, then continues; any failure freezes the
  batch and notifies.
- **Compromised node**: can lie in `GuardNodeReality` — which only feeds
  *suggestions and display*, never silent policy; plans remain
  operator-reviewed. Same containment argument as design-05 §7 geo facts.
- **Audit**: `netguard.group.*`, `netguard.binding.*`, `netguard.reality.*`,
  `netguard.lockout_risk.accepted`, `wireguard.network.*`,
  `wireguard.peer.issued/revoked`, plus the existing `network.*` apply events,
  all hash-chained.

---

## 9. Phasing (each slice = one `iter-NNN`, tested + reviewed + shippable)

**Track G (netguard)**
- **G1 — model + read (no behavior change).** SDK types (§4.2), store
  collections + versioning, RPC read interfaces, `netguard.overview/groups`
  views read-only over converted legacy data. Exit: converted view of every
  existing `NFTInputs` visible; zero apply-path changes.
- **G2 — compile parity + plan.** Netguard compiler over
  zones/groups/bindings folding into `lattice_guard`/`lattice_policy`;
  byte-identical legacy gate (§7.1); plan linting (control-plane, lockout,
  selfcheck-ack); `Approval.Plugin="netguard"`. Exit: converted fixture parity
  test green; lockout lint has a red-if-removed test.
- **G3 — reality + drift.** `--report-guard-reality`, `/api/agent/guard-reality`,
  suggestions engine, drift badge + Review & Re-apply, binding apply-state
  fields live. Exit: dmit-eb-wee scenario reproduced in a test fixture yields
  the exact expected suggestion set; drift flips within one poll interval.
- **G4 — SG editor UX + zones.** Full `netguard.groups` editor, zone CRUD,
  node-detail provenance view, GuardView redirect. Exit: an operator can
  express today's dmit-eb-wee corrected baseline entirely in the UI in one
  sitting, plan shows zone accepts, apply is canary-gated.
- **G5 — bootstrap + fleet ops.** Preflight, nft install plans, canary batch
  apply, configurable watchdog. Exit: blank Debian/Alpine VM to guarded node
  through the UI only.
- **G6 — L2.** NAT/port-forward, rate limit, logging, forward chain, MSS.
- **G7 — L3.** Raw snippets + linter; plugin repo + signed manifest packaging
  if not already cut in G4.

**Track W (wireguard)**
- **W1 — model + discovery.** `WGNetwork/WGMembership` (converter from
  today's implicit mesh: one `default` mesh network from `Node.WireGuard*`
  fields), `wg show all dump` discovery + `wireguard.discovered` view. Exit:
  existing mesh renders identically through `BuildTopology(mesh)` (parity
  test); live interfaces visible read-only.
- **W2 — apply parity.** Watchdog/rollback/selfcheck WG apply template,
  `syncconf` fast path. Exit: a deliberately broken wg0.conf on a test node
  auto-restores within the watchdog window (evidence in the iter doc).
- **W3 — topologies + status.** hub-and-spoke + custom, topology SVG with
  handshake coloring, membership apply states. Exit: 3-node hub-spoke E2E,
  spoke↔spoke via hub verified.
- **W4 — devices + options.** External peers with one-time conf/QR, MTU/DNS,
  Table/FwMark, templated PostUp. Exit: phone onboarded via QR against a hub
  node; key shown exactly once (test asserts non-persistence).
- **W5 — bootstrap + PSK.** Blank-machine preflight/install/keygen/unit
  enablement; optional pairwise PSK. Exit: blank VM to meshed member through
  the UI only.

Ordering note: G1-G3 and W1-W2 are independent and can interleave; G4 (zones)
should land before W3 hub suggestions so §6 has a consumer. The two plugin
repos + signed manifests + index entries follow the vpn-core release
mechanics (prerelease tags per AGENTS.md discipline).

---

## 10. Risks & open questions

1. **Byte-parity gate scope.** If any existing store has malformed legacy
   baselines the converter can't reproduce, decide: refuse conversion (manual
   fix) vs normalize-with-diff-report. Leaning refuse + report — silent
   normalization of a firewall is exactly what this design exists to prevent.
2. **`wg syncconf` availability** varies with wg-tools version; fallback is
   full down/up under watchdog. Preflight records the version so the plan
   states which path it will take.
3. **Suggestion trust.** Reality is agent-reported; a compromised node could
   suggest opening ports. Mitigation is UI provenance ("suggested from node
   report") + operator review + audit; consider requiring `netguard:admin` to
   even view suggestions? (Leaning no — read is fine, accepting is the gate.)
4. **Section IA**: one `network` section for both plugins vs two sections —
   decide at G4/W3 when both navs exist; manifest change is cheap (re-sign).
5. **Watchdog window default** once configurable: keep 60s default; is a
   per-node override warranted for very slow control-plane paths? Open.
6. **Egress default posture** stays "no policy = no egress table" (baseline
   only). A future "default-deny egress" fleet posture is L2+ material and
   needs its own canary story.
7. **Astra**: both plugins are dashboard-first; mobile surfaces remain
   read-only status views until the review/rollback flows have a mobile
   design (architecture.md mobile stance).

---

## Appendix A — plugin-host integration points (code-audited 2026-07-08)

Exact seams the G/W implementation slices touch; verified against source, not
docs (the template README's capability list is stale — the code table is
authoritative):

| Integration | Where | Note for this design |
|---|---|---|
| Capability→risk table | `lattice-server/internal/plugin/plugin.go:57-93` | Add `netguard:read` (read), `netguard:admin` (host), `wireguard:read` (read), `wireguard:admin` (host) here — same move iter-020 made for `netpolicy:*` |
| Manifest validation | `plugin.go:27-42`, `DisallowUnknownFields` at `:199` | No schema changes needed; both manifests use existing fields (`ui`, `interfaces`) |
| Signing payload | `plugin.go:244-268` | `ui`/`interfaces` are already covered by the conditional signed tail |
| Runtime reality | `server.go:405` (only `system` runner registered); `runtime.go:283-305` (worker/wasm fall to noop, fail closed) | Both plugins are `system` tier — the only implemented tier; nothing here blocks us |
| Artifact contract | `system_runner.go:250-373` — one fresh process per invocation, stdio JSON + fd-3 host responses, 1 MiB output caps, 64 host-calls, circuit breaker `:525-536` | Plugin subprocesses stay thin (describe/health/plan), engines in-core — same as vpn-core (`lattice-plugin-vpn-core/system-go/main.go:87-101`) |
| RPC service registration | `server_vpncore.go:43-70` is the pattern | Register `latticenet.netguard/*`, `latticenet.wireguard/*` in-core services the same way; interface names MUST be namespaced under the plugin id (`contributions.go` enforcement) |
| Gateway scope union | `server_plugin_invoke.go:257-288` | Interface scopes ∪ matching `ViewAction.Scopes` are enforced server-side — declare both accurately |
| Builtin views: double registration + ownership pinning | server `contributions.go:33-46` (`pluginBuiltinViews`, pins owner plugin id, `:176-178`) + dashboard `PluginView.vue:58-71` (`BUILTIN_COMPONENTS`) | Every `netguard.*` / `wireguard.*` component key lands in BOTH registries, owner-bound, in the same slice as its Vue page |
| Contributions discovery | `GET /api/plugin-contributions` (no scope, active-only, RBAC-filtered) | Nav appears only while the plugin is active — deactivation is IA-only by construction (§2.4) |
| Cross-plugin RPC | `rpc.go:160-181` directed allow-list; only existing grant is sub-store→vpn-core (`server_vpncore.go:69`) | §6 deliberately avoids plugin→plugin RPC (server-owned facts instead); if a future slice wants it, it is one explicit `Allow` edge |
| Marketplace | index is discovery-only; install = bundle on disk; revocation is a hard prerequisite for remote install (`lattice-plugin-index/docs/SECURITY.md`) | Ship both plugins via the vpn-core release mechanics (signed prerelease bundles); remote install is out of scope here |
