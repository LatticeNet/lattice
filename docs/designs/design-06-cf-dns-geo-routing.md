# Design 06 — Geo-routing `dns.roobli.org` to the nearest node

> Status: proposed (framework design + dev guide). Researched 2026-06-15.
> **Decision (2026-06-15): build Path B — free, fully self-hosted GeoDNS.**
> Goal: a client resolving `dns.roobli.org` (or any shared apex) is sent to the
> geographically **nearest healthy node**, on top of the per-node
> `gmami-jp1.dns.roobli.org` records Design 02 already publishes via DDNS.

This is the "CF dns.roobli.org 根据请求位置自动选择最好的节点" capability. The
research below explains why the obvious cloud answer (Cloudflare Load Balancing)
was rejected, and specs the chosen self-hosted path that reuses Lattice's
existing CoreDNS deployment + operator-owned `NodeGeo`.

---

## 1. Goal & scope

**Goal.** Resolve one shared hostname to the best node by client location, with
health-aware failover, reusing what Lattice already owns: operator-set `NodeGeo`
(lat/lon/country), per-node public IPs, node online/health state, the Design 02
self-host DNS (CoreDNS) deployments, and the existing Cloudflare DNS-edit token
(for delegating the subdomain only).

**In scope:** a server-owned `GeoRouting` intent; a deterministic geo-zone
**render** (nearest-healthy-node per region) shipped to the Lattice DNS node(s)
via the existing Design 02 apply path; NS delegation of the geo subdomain into
the CF parent zone; operator API + dashboard; audit.

**Non-goals (v1):** no anycast/BGP (needs an ASN — out); no CF Load Balancing
(paid, see §3); no real-time per-request latency/capacity steering; no building a
CDN; Lattice adds **no new Go dependency** (the GeoIP data is a runtime file CoreDNS
reads, not a code dep).

---

## 2. System fit

| Lattice axis | How geo-routing maps |
|---|---|
| **Server = sole policy point** | Server owns the `GeoRouting` record, renders the geo zone, and ships it; nodes run the same CoreDNS they already run (Design 02). |
| **Reuse, don't reinvent** | `NodeGeo` (lat/lon, operator-set via `/api/nodes/geo`) → per-node coordinates. `model.Node.PublicIP/PublicIPv6` + online state → answers. Design 02 `selfdns` render+apply (`coredns -validate` → atomic swap → reload). `internal/ddns` CF client (extended to NS records) + encrypted DNS-edit token for delegation. The publish-on-IP-change trigger (server.go:2531) re-renders. |
| **plan → approve → apply** | Geo answering writes a **node config**, so it rides the Design 02 reviewed apply (plan→approve→apply) — this *is* node mutation, unlike CF Load Balancing's external call. NS delegation is a DNS-publish (DDNS-tier), not an apply. |
| **Store/crypto** | New `GeoRouting` state map + record CRUD mirroring `DDNSProfile`; the optional inline CF token encrypted at rest via `crypto.go` like `DNSDeployment.CFAPIToken`. |
| **Audit** | `geo.routing.{create,update,delete,plan,apply,delegate}` via `recordPrincipalAudit`. |

### CORE provider vs plugin

**Core server-owned provider** (`internal/georouting`), same call as
`ddns`/`selfdns`. Never a third-party plugin.

---

## 3. Why not Cloudflare Load Balancing (the rejected paid path)

CF could program `dns.roobli.org` directly: a **pool per node** (origin = node
IP, coordinates from `NodeGeo`), a **monitor**, and a **load balancer** on the
apex with **proximity** steering. It is the smallest-code answer and fully
managed. It was **rejected on cost**:

- Load Balancing is a **paid add-on**: **$5/mo** (2 origins + 5 checks),
  **+$5/mo per extra origin**; first 500k queries free then $0.50/500k.
- **Country geo-steering requires a Business plan (~$200+/mo)**; **proximity**
  steering needs the **Traffic Steering add-on**. A 6-node setup ≈ **$60/mo**.
- It needs an **account+zone LB-scoped token** (the DDNS DNS-edit token is
  insufficient).
- Prior-art consensus: CF LB / GSLB / anycast are **overkill for a <50-node
  fleet**; GeoDNS via DNS records is the sweet spot.

So Lattice does GeoDNS itself, keeping CF only as the parent-zone authority that
**delegates** the geo subdomain — using the *existing* DNS-edit token, no LB
add-on, no new cost.

---

## 4. Path B architecture — delegate + render

```
roobli.org  (CF-hosted parent zone)
   └── dns.roobli.org   NS → ns nodes   (Lattice publishes NS + glue via the
                                         existing CF DNS-edit token)
                         ▼
   Lattice DNS nodes (Design 02 CoreDNS) are authoritative for dns.roobli.org and
   answer A/AAAA with the NEAREST HEALTHY participating node, by client geo.
```

Two pieces Lattice owns:
1. **Delegation** — publish `dns.roobli.org NS ns1.dns.roobli.org …` + glue
   A/AAAA into the parent CF zone, reusing the `internal/ddns` Cloudflare client
   (extend `SetRecord` to NS) and the already-encrypted DNS-edit token. The
   Lattice DNS nodes' existing `gmami-jp1.dns.roobli.org` records (Design 02
   DDNS) double as the NS targets.
2. **Geo answer** — the server **renders** a geo-aware CoreDNS zone for the apex
   from `GeoRouting` intent + each participating node's `NodeGeo` + live
   health/online state, and ships it to the DNS node(s) via the **existing
   Design 02 self-host DNS apply path**. Geo classification uses CoreDNS's stock
   **`geoip`** plugin (MaxMind GeoLite2) feeding **`view`** blocks.

---

## 5. Data model

```go
// GeoRouting answers one apex hostname with the nearest healthy participating
// node, served by Lattice's own DNS nodes.
type GeoRouting struct {
    ID         string   `json:"id"`
    Name       string   `json:"name"`
    Hostname   string   `json:"hostname"`     // the geo apex, e.g. dns.roobli.org
    NodeIDs    []string `json:"node_ids"`     // participating targets (need NodeGeo + IP)
    DNSNodeIDs []string `json:"dns_node_ids"` // authoritative DNS nodes (run Design 02 CoreDNS)
    TTL        int      `json:"ttl,omitempty"`        // default 60
    Strategy   string   `json:"strategy"`     // "geoip" (MVP) | "all-healthy" (no-MaxMind fallback)
    // Parent-zone NS delegation (reuses the DNS-edit token; no LB add-on):
    PublishNS     bool   `json:"publish_ns"`
    DDNSProfileID string `json:"ddns_profile_id,omitempty"`
    CFAPIToken    string `json:"cf_api_token,omitempty"` // ENCRYPTED; optional inline token
    // Reconciled state:
    LastRenderedSHA string    `json:"last_rendered_sha,omitempty"`
    Status          string    `json:"status"`
    LastAppliedAt   time.Time `json:"last_applied_at,omitempty"`
    LastDelegatedAt time.Time `json:"last_delegated_at,omitempty"`
    LastError       string    `json:"last_error,omitempty"`
    CreatedAt       time.Time `json:"created_at"`
    UpdatedAt       time.Time `json:"updated_at"`
}
```

`CFAPIToken` joins the `crypto.go` encrypted set (mirror `DNSDeployment.CFAPIToken`).
State gets a `GeoRouting` map + CRUD (mirror `DDNSProfile`, store.go:1057–1110) +
bbolt bucket + import/export wiring. `geoRoutingView` is secret-free
(`has_cf_api_token` only).

---

## 6. The geo render (the pure-Go, testable core — `internal/georouting`)

Deterministic, no network, no new Go dep:

1. Gather participating nodes that have a valid `NodeGeo` (lat/lon) **and** a
   public IP **and** are currently healthy (server online state). Omit + warn
   otherwise.
2. For each of the 7 **continents**, compute the **nearest** healthy node by
   great-circle distance (haversine) from the node's `NodeGeo` to that
   continent's centroid; keep an ordered fallback list (next-nearest …).
3. Emit a CoreDNS zone/Corefile fragment: a `geoip` block (DB path) + one
   **`view`** per continent (`expr` on `geoip` metadata, e.g.
   `metadata('geoip/continent/code') == 'EU'`) answering the apex A/AAAA with the
   continent's nearest healthy node; a default `view` (all-healthy round-robin)
   for unmatched/unknown clients. Short TTL (default 60s).
4. Hash the rendered text → `LastRenderedSHA`; ship via the Design 02 apply path
   (validate + atomic swap + reload). The render is unit-tested against fixtures
   (node sets, health subsets, missing geo, single-node, all-down) for exact,
   stable output.

**`all-healthy` fallback strategy** (no MaxMind): emit a single round-robin A/AAAA
of all healthy nodes — *not* true geo, but a zero-dependency degrade that still
gives failover. The render supports both; operator picks per `GeoRouting`.

---

## 7. GeoIP data dependency (decision)

True geo needs client→location mapping. The stock CoreDNS **`geoip`** plugin reads
MaxMind **GeoLite2** (free account + license key); the Design 02 pinned-CoreDNS
binary already includes `geoip` + `view`. **Lattice adds ZERO Go dependency** — it
only renders config; the DB is operator-provisioned on the DNS node (or fetched by
the existing pinned-install pattern with the operator's MaxMind key). Document the
DB path + the CoreDNS-version requirement (`geoip` + `view`, stock ≥ 1.11). With no
DB, the operator uses `strategy: "all-healthy"` (failover without geo). This keeps
the "pure Go, zero CGo, tiny dep surface" invariant — GeoIP is a *runtime data
file*, not a code dependency, living where CoreDNS already runs.

---

## 8. Server API, security, phasing, risks

**API** (new scope `geo:read`/`geo:admin`, node-visibility filtered like DNS):
`GET/POST /api/geo-routing`, `POST /api/geo-routing/delete`,
`POST /api/geo-routing/plan` (render + show the zone, secret-free, reusing the
Design 02 reviewed-plan/approval shape since this writes a node config),
`POST /api/geo-routing/publish-ns` (delegate via CF), `GET` for status. Re-render +
re-ship on node IP/geo/health change via the existing trigger (server.go:2531).

**Security.** Reuse the DNS-edit token (encrypted, never returned); validate
`Hostname` (host-token rules) and that `DNSNodeIDs` actually run a DNS deployment;
fail-closed omission of nodes missing geo/IP/health; CF calls through
`internal/outbound`; rendering writes a node config so it rides the **reviewed
apply** (plan→approve→apply) like the rest of self-host DNS. Audit
`geo.routing.{create,update,delete,plan,apply,delegate}`.

**Phasing.**
- **MVP:** SDK `GeoRouting`; state+crypto+bbolt+CRUD; `internal/georouting` render
  core (haversine nearest-healthy per continent + `all-healthy`) **with exhaustive
  unit tests**; `/api/geo-routing` CRUD/plan/apply (reusing the DNS apply path) +
  NS-delegation publish; dashboard Geo-Routing panel (pick participating + DNS
  nodes, strategy, plan/apply, NS publish, status; warn on missing geo). **Exit
  bar:** operator sets `NodeGeo`, plans a geo zone, applies to a DNS node,
  delegates `dns.roobli.org`, and a client in EU vs AS resolves to the nearest
  node; a node going offline drops out on the next render.
- **v2:** EDNS Client Subnet awareness; per-country (not just continent) views;
  latency tiebreak; automatic GeoLite2 refresh; "all nodes down" backup answer;
  health hysteresis to avoid flapping.

**Risks.** GeoIP accuracy for VPS ranges is coarse — operator-set `NodeGeo` is the
trustworthy input (good, it's operator-owned). Failover is eventual (TTL + render
cadence + resolver caching). The render must be deterministic (tested) so apply
churn is minimal. NS delegation is a one-time operator step (Lattice publishes it;
the operator confirms the parent zone). CoreDNS plugin/version drift — pin +
`coredns -validate` before swap.

## Sources
- [CF Load Balancing pricing/steering (community + GeeksforGeeks)](https://community.cloudflare.com/t/deep-understanding-of-cloudflare-load-balancer-pricing/542666) — base $5/mo + $5/origin; geo steering needs Business; proximity via Traffic Steering add-on.
- [CF proximity steering](https://developers.cloudflare.com/load-balancing/understand-basics/traffic-steering/steering-policies/proximity-steering/) — pool GPS coordinates.
- [CF geo steering](https://developers.cloudflare.com/load-balancing/understand-basics/traffic-steering/steering-policies/geo-steering/) — country/region pools.
- [PowerDNS Lua records `pickclosest`/`ifportup`](https://docs.powerdns.com/authoritative/lua-records/index.html) — the self-hosted GeoDNS pattern this design follows.
- [CoreDNS `geoip` plugin](https://coredns.io/plugins/geoip/) + [`view` plugin](https://coredns.io/plugins/view/) — the render targets.
- [Anycast vs GeoDNS for small fleets](https://webhosting.de/en/anycast-vs-geodns-smart-dns-routing-comparison-2025/).
