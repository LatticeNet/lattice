# Iteration 057 - Geo-routing MVP (Design 06, Path B): configure + render + preview

- **Date:** 2026-06-15
- **Repos:** `lattice-sdk`, `lattice-server`, `lattice-dashboard`, `lattice`
- **Design:** [design-06-cf-dns-geo-routing](../designs/design-06-cf-dns-geo-routing.md) (Path B)
- **Status:** Implemented, reviewed, verified (configure + preview; apply + NS delegation are the next slice)

## Goal

Build the Lattice-native GeoDNS path the operator chose over paid Cloudflare
Load Balancing (rejected on cost — see design-06 §3). This slice delivers the
**deterministic geo render + the operator control surface**: name a shared apex,
pick participating + DNS nodes, and preview the exact nearest-healthy-node
CoreDNS zone. Shipping that zone to the node and delegating the subdomain are the
next slice.

## What landed

1. **Render core** (`lattice-server/internal/georouting`, pure Go, no new dep):
   `Render(Input) Result` takes participating nodes (operator-owned `NodeGeo`
   coords + public IP + health) and emits a geo-aware CoreDNS zone — per-continent
   **nearest healthy node by haversine** distance to continent centroids, grouped
   into `geoip`+`view` blocks, plus an `all-healthy` round-robin default for
   unknown clients. Unhealthy / no-IP / no-geo nodes are omitted with warnings; a
   no-coordinates set degrades to `all-healthy` (failover without geo).
   Deterministic output + SHA (minimal apply churn). `-race` tested.
2. **SDK** `model.GeoRouting` — carries **no secrets** (the NS-delegation token is
   reused from the referenced `DDNSProfile`), so no `crypto.go` wiring.
3. **Store** — `GeoRouting` state map + Upsert/Get/List/ForNode/Delete; `geo_routing`
   bbolt bucket in import/export. `GeoRoutingsForNode` matches participating *and*
   authoritative DNS nodes for the future re-render trigger.
4. **Server API** (`server_georouting.go`, `geo:read`/`geo:admin`): CRUD +
   `/api/geo-routing/plan` (render preview — projects the record + live node state
   into the render core, returns the CoreDNS zone + SHA + per-continent choices +
   warnings, secret-free). Validation: hostname, strategy, node existence, TTL
   bounds, absolute/clean `geoip_db_path`.
5. **Dashboard** — a self-revealing Geo-Routing panel: list, add/edit form, and a
   Preview that renders the exact zone (via `textContent`, XSS-safe under CSP).

## Architecture (recap)

`dns.roobli.org` is **delegated** (NS) from the CF parent zone to Lattice DNS
nodes (Design 02 CoreDNS), which answer with the nearest healthy node via stock
`geoip`+`view` reading a GeoLite2 DB. Lattice **adds no Go dependency** — it
renders config; the GeoIP DB is an operator-provisioned runtime file where
CoreDNS already runs. `NodeGeo` (operator-owned) is the trustworthy coordinate
source, not auto-geoip.

## Verification

```sh
GOWORK=…/lattice/go.work go test -race ./internal/georouting/ ./internal/store/ ./internal/server/
npm test && npm run check   # dashboard 86/86, node --check clean
gofmt -l <changed files>    # empty
```

Coverage: render selection/determinism/health-shift/fallback/IPv6/validation/
haversine; store CRUD + bolt round-trip; server create/list/plan/delete +
validation; dashboard payload helpers.

## Residuals & Next (to reach the design-06 exit bar)

1. **Apply** (the foundational remaining piece — deliberately scoped as its own
   focused slice, not rushed, because it touches the security-critical approval
   dispatch at multiple points + CoreDNS config-import mechanics). Precise
   blueprint (mirror the `selfdns`/`proxycore` approval pattern):
   - `/api/geo-routing/apply` renders the zone and creates an `Approval{Plugin:
     "georouting", Action: "geo-apply:<sha>", Plan: <rendered geo Corefile>}` —
     mirroring `handleProxyNodePlan` / `handleDNSPlan`.
   - Add a `"georouting"` case alongside `proxyCorePlugin`/`"selfdns"` at the
     approval→task dispatch points in `server.go`: `applyScriptFor` (~2971), the
     approve→queue-apply flow (~3437-3471), and status (~3515/3720). Generate the
     apply script from the plan (a `georouting.ApplyScriptFromPlan` mirroring
     `selfdns.ApplyScriptFromPlan`).
   - Apply-script mechanics: write the rendered config to a **standalone**
     `/etc/coredns/geo.d/<id>.conf` (heredoc, atomic swap) that the main self-host
     DNS Corefile includes via `import geo.d/*.conf`; validate by re-running
     `coredns -conf <main Corefile> -plugins` (the import resolves so the geo
     blocks validate in context, and the GeoLite2 DB must be present); reload
     CoreDNS. Keeps `selfdns.GenerateConfig` untouched (decoupled).
   - A task-result handler (mirror `handleProxyCoreTaskResult`) sets
     `LastRenderedSHA`/`LastAppliedAt`/`Status` on the `GeoRouting`.
2. **NS delegation publish** (do **after** apply — a node must serve the geo zone
   before it is delegated, or resolution breaks): extend the `internal/ddns`
   Cloudflare client to NS records + a `/api/geo-routing/publish-ns` endpoint that
   publishes `dns.roobli.org NS <dns-node-hostname>` into the CF parent zone using
   the referenced `DDNSProfile`'s token (the DNS nodes' existing
   `gmami-jp1.dns.roobli.org` A records serve as the NS targets — no separate glue).
3. ~~**Re-render trigger**~~ — **done (this slice)**: `maybeTriggerDDNS` now calls
   `touchGeoRoutingsForNode`, flagging dependent geo-routings `node-changed` on a
   node IP change so the dashboard prompts a re-plan/apply (idempotent; tested).
4. **Operator runtime** — GeoLite2 DB provisioning on the DNS node (or pinned
   install with the operator's MaxMind key) + the one-time NS delegation; a real
   Linux-node E2E (EU vs AS client resolves to the nearest node).
