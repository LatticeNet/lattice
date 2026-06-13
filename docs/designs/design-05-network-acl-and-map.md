# Design 05 — Per-Node nft Access Control + Network-Policy Visualization + Global Geo-Map

> Status: proposed; shared `NFTInputs` prerequisite landed in iter-019 · Author: design pass · Date: 2026-06-13
> Builds on: `architecture.md` (Safety Model, WireGuard Mesh, DDNS), `internal/network/nft.go`,
> `internal/wireguard`, `internal/cftunnel`, `internal/ddns`, the `plan → approve → apply` flow.
> Constraints inherited: pure Go, zero CGo, tiny dep surface (new dep ⇒ ADR), security-first,
> fail-closed, audit everything, zero-dep vanilla-JS dashboard under strict CSP.

---

## 1. Goal & scope

### What it does
Three capabilities, one cohesive slice:

1. **Per-node nft access control.** Let the operator express egress/ingress access rules in
   *cluster terms* — "node `gmami-jp1` may NOT reach `dmit-eb`'s IP on TCP/1234", "node A may reach
   node B on the mesh", "deny node X all external egress except 443" — and compile them to validated
   nftables rules rendered onto the **target** node through the existing `plan → approve → apply`
   flow. Rules reference **nodes** (resolved to their current IPs server-side), **CIDRs**, **ports**,
   **protocol**, and **direction**. This is a strict superset of today's `internal/network/nft.go`,
   which now also has persisted per-node `NFTInputs` for the baseline public/WG
   port matrix.

2. **Network-policy visualization.** A dashboard panel that renders the *effective reachability graph*
   ("which node can reach what") from the compiled policy — a node-to-node adjacency view plus a
   per-node rule list — so the operator can see and review policy before approving it.

3. **Global geo-map.** A nezha-style world map of node locations rendered from node facts
   (lat/lon/country/ASN), overlaid with online/offline status and (optionally) the policy edges and
   the operator's existing ASN/latency matrix. Pure inline SVG, CSP-safe, no map library.

### Non-goals (v1)
- **No stateful L7 / DPI / app-aware filtering.** L3/L4 only (IP, CIDR, protocol, port, ct state).
- **No automatic conflict resolution between operators.** Last-write-wins on the policy document,
  guarded by the existing optimistic plan-hash check at approve time.
- **No live IP geolocation lookups from the server.** Geo facts are operator-supplied or agent-
  reported, *never* fetched from a third-party geo-IP API (new dep + egress + privacy). The server
  may *derive* nothing it cannot already see.
- **No new on-node daemon.** Reuse the poll-only agent and the bounded apply task. No inbound ports.
- **No nftables NAT / mangle / routing changes.** Filtering (`filter` hook) only.
- **No IPv6 policy in the first MVP slice** (the data model is v6-ready; rendering lands in v2).
- **Not a plugin.** This is a CORE server-owned provider (see §2).
- **Map tiles / basemap detail:** a single static low-poly world outline, not a real GIS basemap.

---

## 2. System fit

| Lattice element | Role for this feature |
|---|---|
| **lattice-server (policy point)** | Owns the policy document, resolves node→IP, **compiles** policy to per-node nft rulesets, renders the approval plan, stores geo facts, serves the reachability graph + map data. The *only* place policy lives. |
| **lattice-node-agent (executor)** | Pure executor. Pulls the bounded apply task, writes the ruleset, runs `nft -c` (validate) then `nft -f` (commit) **with a timed auto-rollback**, reports status. Optionally reports its own geo facts at `hello`. Never decides policy. |
| **plan → approve → apply** | The spine. `POST …/policy/plan` compiles + diffs + records a pending `Approval` (Plugin `nftpolicy`); operator approves with optional `plan_sha256`; `queue_apply` dispatches the bounded apply task. Identical shape to nft/wg/cftunnel. |
| **store** | Two new collections: `NetPolicy` (the rule document) and geo facts on `Node`. Reuses the JSON-file store today; record-level bbolt buckets when Phase C lands. Policy is **not secret**; CF token for the optional DNS step already lives in `DDNSProfile` (secret-at-rest). |
| **RBAC** | New scopes `netpolicy:read` / `netpolicy:admin`, plus reuse of `network:apply` for the apply step, all honoring the existing per-node `ServerAllowlist`. |
| **notify** | Reuse `internal/notify` fan-out for "policy applied / apply failed / auto-rolled-back" alerts. No new channel code. |
| **ddns** | Reuse `ddns.Cloudflare.SetRecord` (already a clean `SetRecord(ctx, Record)` provider) if the operator wants `*.dns.roobli.org` map pins published — optional, off by default. |
| **audit** | Every plan/approve/apply/rollback emits a hash-chained `network.policy.*` event with the approval id and a hash of the compiled ruleset. |

### CORE-provider vs plugin — decision
**CORE server-owned provider, like `ddns`/`notify`/`wireguard`.** Rationale:
- It is a **policy point that mutates the host firewall** — the highest-blast-radius node operation in
  the fleet. The plugin trust model (capability/risk tiers, `network:apply` is `RiskHost`) exists to
  *contain* third-party code; firewall authorship is the server's own job, not something to broker out.
- It must resolve **cluster-wide node state** (every node's current IP) to compile — that is core
  topology knowledge already held by the server (cf. `wireguard.BuildMesh` reading `s.store.Nodes()`).
- The existing peers (nft, wg, cftunnel) are all core `system`-tier renderers wired straight into
  `applyScriptFor`. This feature is the natural fourth sibling, not a marketplace artifact.
- A future *community* plugin could **read** the policy/graph via the host-API broker (`kv:read`-style),
  but **authoring/compiling/applying** stays core. Say so in the ADR if one is filed.

No new external dependency is required (nft rendering is string-building like the existing code, SVG is
hand-emitted). Therefore **no ADR is strictly required**; file a short ADR only if the optional CF-DNS
map-pin publishing is turned on by default (it won't be).

---

## 3. Data model

All shared wire types go in `lattice-sdk/model/model.go` (the single source of truth, already carries
`Node`, `Approval`, `DDNSProfile`, etc.). Compilation-only helper types stay server-side in a new
`internal/netpolicy` package (mirroring how `internal/wireguard` keeps `Interface`/`Peer` out of the SDK).

### 3.1 SDK model additions (`lattice-sdk/model/model.go`)

```go
const (
    NetRuleAllow = "allow"
    NetRuleDeny  = "deny"

    NetDirEgress  = "egress"  // traffic the target node originates (output hook)
    NetDirIngress = "ingress" // traffic arriving at the target node (input hook)

    NetProtoTCP = "tcp"
    NetProtoUDP = "udp"
    NetProtoAny = "any"

    // Endpoint reference kinds for the "other side" of a rule.
    NetRefNode = "node" // resolve to a node's current IPs at compile time
    NetRefCIDR = "cidr" // a literal CIDR / IP the operator typed
    NetRefAny  = "any"  // 0.0.0.0/0 (and ::/0 when v6 lands)
)

// NetEndpoint is the non-target side of a rule. Exactly one of NodeID / CIDR is
// set per Kind; Any needs neither. Node refs are resolved server-side at compile
// time, so a rule survives a peer's IP change without operator edits.
type NetEndpoint struct {
    Kind   string `json:"kind"`              // node | cidr | any
    NodeID string `json:"node_id,omitempty"` // when Kind == node
    CIDR   string `json:"cidr,omitempty"`    // when Kind == cidr (IP or CIDR)
}

// NetRule is one operator-authored access rule, evaluated on TargetNodeID.
// Semantics: rules are ordered; first match wins; the chain has a default-drop
// baseline the compiler always appends (fail-closed). Direction picks the hook.
type NetRule struct {
    ID         string      `json:"id"`
    Comment    string      `json:"comment,omitempty"`
    Action     string      `json:"action"`    // allow | deny
    Direction  string      `json:"direction"` // egress | ingress
    Protocol   string      `json:"protocol"`  // tcp | udp | any
    Ports      []int       `json:"ports,omitempty"` // empty => all ports
    Remote     NetEndpoint `json:"remote"`    // the other side
    Disabled   bool        `json:"disabled,omitempty"`
}

// NetPolicy is the full per-node access-control document for one target node.
// One NetPolicy per node; absence of a policy means "baseline only" (the
// established/lo/default-drop scaffold), never "allow all".
type NetPolicy struct {
    ID            string    `json:"id"`
    TargetNodeID  string    `json:"target_node_id"`
    Rules         []NetRule `json:"rules"`
    Enabled       bool      `json:"enabled"`
    // Compiled metadata (server-maintained; read-only to clients).
    LastPlanSHA   string    `json:"last_plan_sha,omitempty"`
    LastAppliedAt time.Time `json:"last_applied_at,omitempty"`
    LastError     string    `json:"last_error,omitempty"`
    CreatedAt     time.Time `json:"created_at"`
    UpdatedAt     time.Time `json:"updated_at"`
}

// NodeGeo holds map/geo facts for a node. Operator-supplied or agent-reported;
// never fetched from a third-party geo-IP service by the server. ASN/latency are
// the data the operator already has from the cluster ASN/latency report.
type NodeGeo struct {
    Country   string  `json:"country,omitempty"`    // ISO-3166-1 alpha-2, e.g. "JP"
    City      string  `json:"city,omitempty"`
    Lat       float64 `json:"lat,omitempty"`        // WGS84
    Lon       float64 `json:"lon,omitempty"`
    ASN       int     `json:"asn,omitempty"`        // e.g. 4837
    ASOrg     string  `json:"as_org,omitempty"`     // e.g. "China Telecom"
    Provider  string  `json:"provider,omitempty"`   // cloud vendor, operator label
    UpdatedAt time.Time `json:"updated_at,omitempty"`
}
```

`model.Node` gains one optional embedded field (additive, JSON-compatible with existing agents):

```go
type Node struct {
    // ... existing fields ...
    Geo *NodeGeo `json:"geo,omitempty"`
}
```

### 3.2 Store collections

- `NetPolicies` — keyed by `TargetNodeID` (1:1 with node). CRUD: `UpsertNetPolicy`, `NetPolicy(nodeID)`,
  `NetPolicies()`, `DeleteNetPolicy(nodeID)`. Mirror the `DDNSProfile`/`TunnelProfile` store methods and
  add a matching bbolt bucket in the Phase-C foundation (`netpolicies`).
- Geo lives **on the node record** (`Node.Geo`), so it rides existing node persistence; no new bucket.
  A small `UpdateNodeGeo(nodeID, NodeGeo)` mutator keeps it off the agent-driven node-upsert path.

### 3.3 Secret-at-rest classification
- `NetPolicy`, `NetRule`, `NetEndpoint`, `NodeGeo`: **not secret.** Plain in the state file. Policy must
  be diffable in an approval and renderable in the graph; it carries no credentials. **Do not** route
  through `internal/store/crypto.go`.
- The only secret in the whole feature is the **Cloudflare API token** used by the *optional* map-pin
  DNS publishing — and that already exists as `DDNSProfile.CFAPIToken`, already encrypted by
  `encryptDDNSRecord` in `crypto.go`. Reuse it; add nothing.

---

## 4. Server API

New handlers go in **`internal/server/server_netpolicy.go`** (server.go is 3.5k lines; follow the
`server_oidc.go` / `server_views.go` split convention). Register the routes in the existing `routes()`
block next to the other `/api/network/*` lines.

| Method | Path | Scope | Request | Response |
|---|---|---|---|---|
| `GET` | `/api/netpolicy` | `netpolicy:read` | — | `[]NetPolicy` (only nodes the principal's allowlist permits) |
| `POST` | `/api/netpolicy` | `netpolicy:admin` | `NetPolicy` (CRUD upsert, validated, **not** applied) | stored `NetPolicy` |
| `POST` | `/api/netpolicy/delete` | `netpolicy:admin` | `{node_id}` | `{ok:true}` |
| `POST` | `/api/netpolicy/plan` | `netpolicy:admin` | `{node_id}` | `Approval` (Plugin `nftpolicy`, `Plan` = compiled ruleset; **diffable, no secret**) |
| `POST` | `/api/network/approvals/approve` | `network:apply` | `{approval_id, queue_apply, plan_sha256?}` | `ApprovalView` — **reuse the existing handler unchanged** |
| `GET` | `/api/netpolicy/graph` | `netpolicy:read` | — | reachability graph JSON (see below) |
| `GET` | `/api/nodes/geo` | `node:read` | — | `[]{node_id,name,online,geo}` for the map |
| `POST` | `/api/nodes/geo` | `node:admin` | `{node_id, geo:NodeGeo}` | updated node view |

**Plan response** = `model.Approval` exactly as nft/wg/cftunnel return today, so the existing approvals
list UI and the existing approve endpoint work with zero change. `Approval.Plugin = "nftpolicy"`,
`Approval.Action = "apply-ruleset"`, `Approval.Plan` = the full `nft -f` document (operator reads it
verbatim in the diff).

**Graph response shape** (computed server-side from compiled policy, never trusts the client):
```json
{
  "nodes": [{"id":"gmami-jp1","name":"gmami-jp1","online":true}],
  "edges": [
    {"from":"gmami-jp1","to":"dmit-eb","action":"deny",
     "protocol":"tcp","ports":[1234],"direction":"egress","via":"node"}
  ],
  "externals": [
    {"target_node_id":"node-x","action":"deny","remote":"0.0.0.0/0",
     "protocol":"any","ports":[],"direction":"egress"}
  ]
}
```
Edges are derived by resolving `NetRef==node` rules to node↔node pairs; `cidr`/`any` rules land in
`externals` keyed to their target node. The graph is *advisory visualization of the compiled policy*,
computed by the same `internal/netpolicy` compiler that emits nft, so the picture and the rules can
never drift.

**Validation at CRUD time** (fail-closed, before anything is stored): every rule's action/direction/
protocol is in the allowed set; ports in `1..65535`; `NetEndpoint.Kind` valid and the matching field
present; `CIDR` parses via `net.ParseCIDR`/`net.ParseIP`; `NodeID` references an existing node (or the
rule is rejected, not silently dropped). Same parse-and-re-emit canonicalization as `nft.go` uses for
the WG CIDR, so attacker-influenced strings can never inject nft syntax.

---

## 5. Agent responsibilities

The agent stays a poll-only executor. The policy apply is a **new branch in `applyScriptFor`** plus one
agent-side safety mechanism (auto-rollback), not new agent endpoints.

### 5.1 Apply-task contract
`handleApprove` already builds the bounded task. For `approval.Plugin == "nftpolicy"`, `applyScriptFor`
returns a script that **commits** (unlike the current nft case, which only validates):

```sh
set -e
umask 077
mkdir -p /etc/lattice
# 1. write the candidate ruleset
cat > /etc/lattice/policy.nft.new <<'<HEREDOC>'
<compiled ruleset>
<HEREDOC>
# 2. validate first (fail-closed: bad ruleset never reaches the kernel)
nft -c -f /etc/lattice/policy.nft.new
# 3. snapshot current ruleset for rollback
nft list ruleset > /etc/lattice/policy.rollback || true
# 4. arm a dead-man timer: if we don't disarm within 60s, restore the snapshot.
#    Protects against a policy that locks out the agent's own poll path.
( sleep 60; nft -f /etc/lattice/policy.rollback 2>/dev/null ) &
WATCHDOG=$!
# 5. commit
nft -f /etc/lattice/policy.nft.new
mv /etc/lattice/policy.nft.new /etc/lattice/policy.nft
# 6. confirm we can still reach the control plane, THEN disarm the watchdog
if lattice-agent --selfcheck-controlplane; then
  kill "$WATCHDOG" 2>/dev/null || true
  echo "policy applied and confirmed"
else
  echo "control-plane unreachable after apply; watchdog will roll back" >&2
  exit 1
fi
```

The dead-man timer is the critical addition: a per-node firewall change can sever the agent's own
dial-out path to the server. Because the agent *polls* (no inbound channel for the server to push a
fix), a self-lockout is otherwise unrecoverable without console access. The 60s auto-restore makes a
bad apply self-healing. `--selfcheck-controlplane` is a tiny new agent subcommand that does one
authenticated `GET /api/health`-class probe and exits 0/1; if you prefer zero new subcommands, inline a
`curl`/Go one-shot equivalent the agent ships, but a subcommand keeps the egress allowlist tight.

### 5.2 Status reporting
No new reporting path. The apply task's stdout/stderr/exit-code flow back through the **existing**
`POST /api/agent/task-result` → `model.TaskResult`. The server, on receiving the result for an
`nftpolicy` apply task, updates `NetPolicy.LastAppliedAt` / `LastError` / `LastPlanSHA`, flips the
`Approval` to `applied`, emits `network.policy.applied` (or `…failed`), and fans out a notify alert.
Correlation is by the approval id already carried in audit metadata.

### 5.3 Geo reporting (optional)
At `hello`, an agent *may* include a `geo` object (country/ASN it can cheaply self-determine, e.g. from
a local file the operator drops). The server treats agent-reported geo as **low-trust**: it fills only
empty fields and never overwrites operator-set geo. The authoritative path is the operator `POST
/api/nodes/geo`, seeded in bulk from the existing ASN/latency report.

---

## 6. Config rendering / external integration

### 6.1 The nft compiler (`internal/netpolicy/compile.go`)
Input: a `NetPolicy` + a resolver `func(nodeID string) ([]net.IP, bool)` over current node IPs
(public + mesh, mirroring how the server already knows `WireGuardIP`/`PublicIP`). Output: a single
`table inet lattice_policy { … }` document, structured like `nft.go` today:

- One `table inet lattice_policy` (distinct table from `lattice_guard` so the two coexist; the existing
  inbound-services ruleset is untouched).
- `chain output { type filter hook output priority 0; policy drop; … }` for egress rules.
- `chain input  { type filter hook input  priority 0; policy drop; … }` for ingress rules.
- Both chains always begin with `ct state established,related accept` and `oif/iif lo accept`, and
  **always end with `counter drop`** — the fail-closed baseline appended by the compiler, never the
  operator. **Critical:** because `output` is default-drop, the compiler must *always* emit an allow for
  the node's dial-out path to the control plane and DNS, or every node bricks itself. Encode this as a
  non-removable, compiler-injected "control-plane reachability" allow (the server's address/port + 53),
  ordered first. This is the single most important safety invariant in the feature.
- Node refs expand to their resolved IPs as `nft` set elements (`ip daddr { … }` for egress,
  `ip saddr { … }` for ingress). CIDR refs are parsed/re-emitted canonically. `any` ⇒ omit the address
  match. Ports ⇒ `tcp dport { … }` / `udp dport { … }`; empty ports ⇒ no port match. `protocol==any` ⇒
  emit both or omit the L4 match as appropriate.
- Every operator rule carries a `comment "<sanitized comment / rule id>"` so `nft list ruleset` and the
  graph stay legible.
- Deterministic ordering (stable sort by rule index) so the same policy always yields byte-identical
  output — required for the `plan_sha256` binding and clean diffs.

Validation: reuse the `nft -c -f` agent-side validate (already proven in the current nft flow) **plus**
a server-side dry compile at CRUD time. The server never emits a ruleset it didn't first build from
validated structs.

### 6.2 Generated artifacts
- On node: `/etc/lattice/policy.nft` (committed ruleset), `/etc/lattice/policy.rollback` (snapshot).
- No systemd unit change required; `nft -f` is atomic. (Optional v2: a tiny
  `lattice-policy.service` that re-applies `/etc/lattice/policy.nft` on boot so policy survives reboot —
  otherwise the operator re-applies, or the agent re-applies on its first poll after restart.)

### 6.3 Cloudflare DNS (optional, off by default)
If `map_pin_dns` is enabled for a node, reuse `ddns.Cloudflare.SetRecord` to publish/refresh
`<node>.dns.roobli.org` so the map can deep-link to a stable name. This is *purely cosmetic* for the
map and must not be coupled to policy apply. Reuses the existing SSRF-guarded outbound client and the
already-encrypted CF token. Default off — the map works entirely from stored geo facts.

---

## 7. Security

- **Authz.** `netpolicy:read` (view policy/graph/map), `netpolicy:admin` (author/plan/delete),
  `network:apply` (approve+queue apply — reused so the firewall-commit gate is the *same* high bar as
  every other node mutation). All checks go through `rbac.Allows(... , nodeID)` so the per-node
  `ServerAllowlist` is honored — an operator scoped to a subset of nodes can only touch those nodes'
  policy. Add the three new scopes to the plugin risk map (`network:apply` is already `RiskHost`;
  `netpolicy:admin` ⇒ `RiskHost`, `netpolicy:read` ⇒ `RiskRead`).
- **Fail-closed everywhere.** No policy ⇒ baseline scaffold (established/lo/default-drop), never
  allow-all. Bad ruleset ⇒ `nft -c` rejects before commit. Unreachable control plane after commit ⇒
  dead-man timer auto-restores. Invalid rule at CRUD ⇒ stored-nothing, 400. Unknown `NetRef` node ⇒
  rule rejected, not silently widened.
- **Self-lockout containment.** The compiler-injected control-plane + DNS egress allow, plus the agent
  watchdog rollback, are mandatory and must have direct regression tests. This is the feature's defining
  risk; treat both as non-optional invariants, not configuration.
- **Injection.** All node/operator strings (interface names, CIDRs, comments) are parse-and-re-emitted
  or charset-bounded exactly as `nft.go` / `wireguard.go` already do; nothing operator-typed reaches the
  ruleset uncanonicalized. Comments are newline-stripped (`sanitizeComment` pattern).
- **Secret handling.** Policy carries no secrets ⇒ nothing new in `crypto.go`. Only the optional CF
  token is secret, already encrypted, never returned by the list API.
- **Blast radius / compromised node.** A compromised node can only *report* facts (geo, its own IP) —
  it cannot author policy (no `netpolicy:admin` on an agent token) nor approve applies (`network:apply`
  is an operator scope). It can report a hostile geo or IP; the server pins node IPs the same way
  `wireguard.BuildMesh` already pins `AllowedIPs` to a `/32`, and agent-reported geo only fills empty
  fields. Worst case a compromised node lies about its location on the map — cosmetic, audited.
  A compromised *operator credential* with `network:apply` is already the existing top-of-threat-model
  actor for nft/wg/cftunnel; this feature does not widen it.
- **Audit.** `network.policy.crud`, `network.policy.plan`, `network.policy.approve`,
  `network.policy.applied`, `network.policy.failed`, `network.policy.rolledback` — each with
  `node_id`, `approval_id`, and `metadata["plan_sha"]` (hash of compiled ruleset), hash-chained in the
  existing WAL. The `plan_sha256` approve-time binding (already implemented in `handleApprove`) defends
  the TOCTOU plan-swap between review and approval — reuse it verbatim.

---

## 8. Phasing

Each phase is a shippable iteration logged as `iterations/iter-NNN-<slug>.md`, green on
`go test -race ./...` + gofmt + dashboard, with an independent adversarial review pass.

### MVP (iter A — "deny node A → node B:port")
Smallest end-to-end slice that delivers the operator's exact ask.
- `model`: `NetEndpoint`, `NetRule`, `NetPolicy` (egress-only, `node`/`cidr`/`any` refs, tcp/udp).
- `internal/netpolicy`: compiler emitting the `output` chain with the **mandatory control-plane allow**
  + default drop; table-driven tests including the self-lockout-prevention case.
- store CRUD for `NetPolicies`; `server_netpolicy.go` with `GET/POST /api/netpolicy`, `…/delete`,
  `…/plan`; reuse `handleApprove`.
- `applyScriptFor` `nftpolicy` branch **with the dead-man rollback** + agent `--selfcheck-controlplane`.
- Server consumes the apply `TaskResult` to update `NetPolicy` status + audit + notify.
- **Exit bar:** operator can create "deny `gmami-jp1` egress to `dmit-eb` TCP/1234", plan → see the
  diff → approve+apply, the rule is live on the node verified by `nft list ruleset`, a deliberately
  self-locking policy auto-rolls-back within 60s (tested), and the control-plane-allow invariant has a
  red-if-removed test. No UI required yet (API + curl acceptable).

### v2 — visualization + ingress + map
- `GET /api/netpolicy/graph`; dashboard **policy panel** (adjacency list + inline-SVG node-link graph).
- Ingress (`input` chain) rules; `protocol==any`.
- `NodeGeo` model + `GET/POST /api/nodes/geo` + bulk seed from the operator's ASN/latency report.
- Dashboard **geo-map panel**: inline-SVG world outline + node pins from geo facts, online/offline
  color, hover for name/ASN/latency. CSP-safe (no lib, no inline script).
- **Exit bar:** operator sees the reachability graph and the global map, both driven by real fleet data,
  matching the compiled policy; ingress rules apply via the same flow.

### Later — polish & durability
- IPv6 policy (`ip6 saddr/daddr`), edge overlay of latency matrix on the map, map-pin CF-DNS publishing
  (opt-in, ADR if default-on), boot-persistence `lattice-policy.service`, bbolt `netpolicies` bucket
  cutover with the rest of Phase C, optional renewal-reminder cross-link (per-node vendor/cost/renewal
  is a sibling design but the map panel is the natural place to surface a "renews in N days" badge via
  `internal/notify`).
- **Exit bar:** v6 parity, reboot-durable policy, map enriched with latency/renewal, all on the scaled
  store.

---

## 9. Risks & open questions

1. **Self-lockout is the headline risk.** Mitigated by the compiler-injected control-plane/DNS allow +
   agent dead-man rollback. *Open:* the agent's dial-out destination (server host:port) must be known
   at compile time — it is (the agent is configured with the server URL; the server knows its own
   advertised address). Confirm the server's public address is resolvable into the allow rule even
   behind a proxy/CDN; if the operator fronts the server with Cloudflare, allow the egress by the
   *resolved edge IPs or by DNS-name-driven set refresh*, not a single static IP.
2. **Node IP churn.** Node refs resolve at compile time; if a peer's IP changes after apply, the rule
   is stale until re-planned. *Decision:* surface "policy stale — peer IP changed" in the graph/list
   (the server already detects IP changes for DDNS) and let the operator re-plan; do **not** auto-apply
   firewall changes without approval. Optional later: a "re-plan needed" notify.
3. **nft table coexistence.** `lattice_policy` (this feature) vs `lattice_guard` (existing inbound
   services) vs any operator-hand-written rules. Separate tables avoid clobbering, but two default-drop
   `input` hooks compose by *both* needing to accept — verify the interaction so the inbound-services
   ruleset and the ingress-policy ruleset don't silently deny each other. *Open:* do we merge ingress
   policy into `lattice_guard`'s input chain instead of a second input hook? Leaning yes for ingress in
   v2 to avoid double-drop confusion; egress is unambiguous (one output hook).
4. **Geo data provenance.** Operator-supplied is authoritative; agent-reported is low-trust fill-only.
   *Open:* exact bulk-import format for the ASN/latency report (CSV vs JSON) — define when seeding.
5. **Graph scale.** Node-link SVG is fine to ~50 nodes; beyond that the adjacency *list* stays the
   primary view and the graph degrades to a matrix. The operator's ~30 nodes are well within SVG range.

---

## 10. Borrow vs avoid (from the nezha geo-map reference)

**Borrow:**
- **Server-side geo, static basemap.** nezha-style maps render a fixed world outline and place pins from
  stored lat/lon — no live tile fetches. Adopt exactly: a single inline-SVG world path + computed
  `<circle>`/`<g>` pins. This is the one approach that satisfies strict CSP (no external tiles, no
  `connect-src` to a map host, no inline script).
- **Status-colored pins + hover tooltip** for online/offline and node identity — cheap, high-signal,
  matches nezha's at-a-glance fleet read.
- **Equirectangular (plate carrée) projection** for pin placement: `x = (lon+180)/360 * W`,
  `y = (90-lat)/180 * H`. Trivial, dependency-free, good enough for a fleet map; lets us hand-pick a
  matching world-outline SVG path.
- **Latency/ASN overlay** — the operator already has the ASN/latency matrix; surface it on hover and as
  optional great-circle-ish edges, which is the genuinely useful part of a fleet map (nezha shows raw
  pins; we can show *relationships*).

**Avoid:**
- **Any JS mapping library** (Leaflet/MapLibre/d3-geo) — all violate the zero-dep + strict-CSP
  (`script-src 'self'`) constraint and dwarf the rest of the dashboard. Hand-emit SVG instead.
- **External tile servers / geo-IP APIs** — break `connect-src 'self'`, add network egress + a privacy
  surface, and need a new dep/credential. Geo is local fact data only.
- **Canvas/WebGL globes** — overkill, accessibility-hostile, and inline-shader/script-heavy. A flat SVG
  map is legible, diffable, screen-readable, and CSP-clean.
- **Client-side policy evaluation** for the graph — the *server* compiles the authoritative picture;
  the client only renders the JSON it's given, so the map/graph can never disagree with the nft the
  node actually runs.

---

## 11. Dev guide — ordered build checklist

Follow `development-workflow.md`: **plan → design (this doc) → TDD build → verify (`-race`, gofmt,
dashboard) → independent review → commit**. Build with `GOWORK` set (multi-repo `go.work`). Conventional
commits; small coherent slices.

**Phase MVP**
1. **Plan** — write `lattice/docs/iterations/iter-0NN-netpolicy-mvp.md` (goal, scope, design ref to this
   doc, risks, test plan, exit bar) *before* code.
2. **`lattice-sdk/model/model.go`** — add `NetRule*`/`NetDir*`/`NetProto*`/`NetRef*` consts,
   `NetEndpoint`, `NetRule`, `NetPolicy`, `NodeGeo`, and `Node.Geo *NodeGeo`. Update
   `proto_contract_test.go` so the wire contract is locked.
3. **`lattice-server/internal/netpolicy/compile.go`** (new pkg) + `compile_test.go` — the compiler.
   *Write tests first*: (a) deny egress node→node:port renders the expected `output` chain; (b) the
   control-plane allow is always present and ordered first; (c) removing it makes a node unreachable
   (the red-if-removed lockout test); (d) CIDR/any refs; (e) byte-stability for `plan_sha256`. Then
   implement until green. Reuse `nft.go`'s parse-and-re-emit + `validatePorts`/`joinPorts` patterns.
4. **`lattice-server/internal/store`** — `UpsertNetPolicy`, `NetPolicy(nodeID)`, `NetPolicies()`,
   `DeleteNetPolicy`, `UpdateNodeGeo`; add the `netpolicies` bbolt bucket in the foundation
   (kept JSON-default until Phase C cutover). No `crypto.go` changes (non-secret).
5. **`lattice-server/internal/rbac`** — confirm `Allows` handles the new scopes (it's generic; just use
   the strings). Add `netpolicy:read`/`netpolicy:admin` to the plugin risk map in
   `internal/plugin/plugin.go`.
6. **`lattice-server/internal/server/server_netpolicy.go`** (new) — `handleNetPolicy` (GET list / POST
   upsert with full validation), `handleDeleteNetPolicy`, `handleNetPolicyPlan` (compile → build
   `Approval{Plugin:"nftpolicy"}` → store → audit). Mirror `handleTunnelPlan` / `handleNFTPlan`.
7. **`server.go`** — register routes in `routes()` beside the other `/api/network/*` lines:
   `/api/netpolicy`, `/api/netpolicy/delete`, `/api/netpolicy/plan` (no new approve route — reuse
   `/api/network/approvals/approve`).
8. **`server.go` `applyScriptFor`** — add the `case "nftpolicy"` branch (validate → snapshot → dead-man
   timer → commit → selfcheck → disarm), using the existing `heredocWrite` helper.
9. **Apply-result consumption** — in the task-result handler, when the finished task corresponds to an
   `nftpolicy` approval, update `NetPolicy.LastAppliedAt`/`LastError`/`LastPlanSHA`, flip the approval to
   `applied`, emit `network.policy.applied|failed`, fan out via `internal/notify`.
10. **`lattice-node-agent`** — add `--selfcheck-controlplane` subcommand (one authenticated health
    probe, exit 0/1) in `cmd/lattice-agent/main.go`; no other agent change (the apply runs via the
    existing `sh` interpreter + bounded task; note it requires `-allow-root-exec=true` since nft needs
    root — document this for the operator).
11. **Verify** — `GOWORK=… go test -race ./...` across server/sdk/agent, gofmt, and a manual end-to-end
    on a scratch node: plan → approve → apply → `nft list ruleset`; then a deliberate self-lock policy →
    confirm 60s auto-rollback. Capture evidence in the iteration doc.
12. **Review** — independent adversarial pass (workflow/subagent): focus the compiler injection-safety,
    the control-plane-allow invariant, and the rollback. Fix must-fixes with regression tests.
13. **Commit** — `feat(netpolicy): per-node nft access control via plan→approve→apply` (+ separate
    commits for model, compiler, server, agent). Update `architecture.md`'s "Safety Model" note that
    said nft apply was future work — it now exists for policy.

**Phase v2 (after MVP merges)**
14. `internal/netpolicy/graph.go` + `handleNetPolicyGraph` (`GET /api/netpolicy/graph`) — derive the
    graph from the *same* compiler internals; tests that graph edges match emitted nft.
15. Ingress (`input` chain) in the compiler + resolve the `lattice_guard` coexistence question (open
    item §9.3) with a test that both rulesets compose without double-drop.
16. `handleNodesGeo` (`GET/POST /api/nodes/geo`) + bulk seed importer from the ASN/latency report.
17. **Dashboard** (`lattice-dashboard/assets/`): new ES module `netpolicy.js` (graph: build inline SVG
    `<line>`/`<circle>` from the graph JSON; list view) and `geomap.js` (inline world-outline SVG +
    equirectangular pin placement + hover tooltip). Wire into `app.js` `state` + a new panel in
    `index.html`. **No inline `<script>`, no inline styles** — SVG built via DOM APIs, classes from
    `styles.css`, to stay inside `script-src 'self'` / `style-src 'self'`. The world-outline SVG path is
    a static asset shipped under `assets/` (served as `'self'`).
18. Verify (add a dashboard render smoke check), review, commit per slice.

**Phase Later** — IPv6 parity, boot-persistence unit, optional CF map-pin DNS (ADR if default-on),
latency/renewal overlay, bbolt cutover — each its own iter with the same gate.
