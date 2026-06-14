# Iteration 022 — NodeGeo and Fleet Map

- **Status:** Verified / Ready to commit (2026-06-13)
- **Design link:** `docs/designs/design-05-network-acl-and-map.md`
- **Builds on:** `iter-020-netpolicy-state-and-graph.md`, `iter-021-netpolicy-egress-apply.md`
- **Repos:** `lattice-server`, `lattice-dashboard`, `lattice`, optionally `lattice-sdk`

## Goal

Ship the first real Nezha-style fleet map surface: operators can attach
authoritative geo metadata to nodes, and the dashboard renders those nodes on a
CSP-safe, dependency-free inline SVG world map. The server never performs live
geo-IP lookup and never treats geo facts as authorization input.

## Scope

- Add server-owned NodeGeo API:
  - `GET /api/nodes/geo`: node-readable, allowlist-filtered map data;
  - `POST /api/nodes/geo`: node-admin, update or clear operator geo for one
    node;
  - validate latitude/longitude ranges, country code, ASN, and printable text;
  - audit `node.geo.update` / `node.geo.clear`.
- Add store helpers:
  - update `model.Node.Geo` without affecting token, metrics, HostFacts, or
    agent-reported network metadata;
  - keep JSON store and bbolt record-level foundation aligned.
- Extend node views to include `geo` for API/proto parity.
- Add dashboard:
  - `Fleet Map` panel with inline SVG basemap and equirectangular pins;
  - online/offline pin state and tooltips;
  - geo edit/clear form;
  - pure `assets/geomap.js` helpers with node tests.
- Update docs/README to mark map MVP landed and list residuals.

## Explicit Non-Scope

- No external map tiles, live geo-IP APIs, or third-party JS map libraries.
- No agent-reported geo ingestion in this slice. Operator-entered geo is the
  only authoritative source.
- No latency/ASN edge overlay beyond static pin metadata.
- No Cloudflare `*.dns.roobli.org` map-pin publishing.
- No ingress/domain-set firewall work.

## Security Notes

- Geo is display-only and must never feed RBAC, nft policy compilation, or node
  identity.
- Agent tokens cannot update geo. Only operator principals with `node:admin` on
  the target node can write.
- The dashboard must escape all node/geo text before SVG/HTML interpolation.
- Coordinates are stored only after range validation; malformed values fail
  closed with 400.

## Verification Plan

- Server tests:
  - update/list/clear geo;
  - list is filtered by PAT server allowlist;
  - invalid lat/lon/country/asn rejected;
  - `/api/nodes` includes geo after update;
  - audit event recorded.
- Dashboard tests:
  - payload validation;
  - equirectangular projection;
  - node filtering and tooltip labels.
- Run targeted Go tests/vet/race, dashboard `node --check` and `node --test`,
  and `git diff --check`.

## Exit Bar

An operator can set a node's geo facts, see the node appear on the dashboard map
without any external map dependency, and clear or edit the facts later. Scoped
tokens see only allowed nodes, and bad geo input cannot be stored.

## Implementation Log

- `lattice-server`:
  - added `GET/POST /api/nodes/geo` in `server_geo.go`;
  - writes require `node:admin` on the target node and reads are filtered by
    `node:read` + per-node allowlist;
  - validates lat/lon, ISO-style 2-letter country code, non-negative ASN, and
    clamps printable text fields;
  - records `node.geo.update` / `node.geo.clear`;
  - exposes `geo` on the existing `/api/nodes` node view;
  - added JSON-store and bbolt record-level `UpdateNodeGeo` helpers.
- `lattice-dashboard`:
  - added `assets/geomap.js` pure helpers and node tests;
  - added `Fleet Map` panel, inline SVG basemap, equirectangular pins, node list,
    and geo edit/clear form;
  - kept all node/geo interpolation behind `escapeHtml` and avoided external map
    tiles, live geo-IP, inline handlers, or new dependencies.
- `lattice` docs:
  - updated Design 05, design index, roadmap, product vision, development report,
    and historical iteration notes so "geo-map pending" is no longer the current
    state.

## Review Outcome

- Local security/quality review found and fixed one maintainability issue:
  adding `*NodeGeo` made JSON-store `Node()` / `Nodes()` shallow copies capable
  of exposing mutable internal pointers. `cloneNode` now copies `Geo` on
  upsert/read/list, with `TestNodeGeoIsCopiedOnStoreBoundaries` covering the
  boundary.
- No blocking security issues remain after the fix.
- Security boundary confirmed:
  - geo is operator-owned display metadata only;
  - agent tokens cannot write geo;
  - scoped PATs can only read/write allowed nodes;
  - geo is not used by RBAC, node identity, or nft compilation;
  - dashboard SVG/list rendering escapes all server-supplied strings.
- Delegated code-reviewer was not spawned because the available subagent tool in
  this session explicitly permits spawning only when the user asks for
  subagents/parallel delegation. The main-thread review followed the same
  checklist instead.

## Residuals / Next

- Ingress ACL composition is still pending and must be folded into the single
  `lattice_guard` input render; do not add a second default-drop input table.
- Domain/DDNS-backed nft named sets, IPv6 policy, and policy-graph SVG remain
  Design 05 work.
- Bulk import from the operator ASN/latency report is still needed for faster
  geo seeding.
- Map overlays remain future work: latency edges, ASN labels, renewal/cost
  badges, and optional DNS names.
- Browser/server smoke could not run in this sandbox because local bind/connect
  to `127.0.0.1:8099` failed with `operation not permitted`; re-run on a normal
  local machine before a tagged release.

## Verification

- `gofmt -w internal/server/server.go internal/server/server_geo.go internal/server/server_geo_test.go internal/store/store.go internal/store/bolt_state.go internal/store/bolt_state_test.go`
- `GOCACHE=/private/tmp/lattice-gocache GOWORK=... go test ./internal/server -run 'TestNodeGeo|TestNetPolicy|TestAgentHostFacts'`
- `GOCACHE=/private/tmp/lattice-gocache GOWORK=... go test ./internal/store -run 'TestNodeGeoIsCopied|TestBoltStateRecordLevelNodeKVAndAudit'`
- `GOCACHE=/private/tmp/lattice-gocache GOWORK=... go vet ./internal/server ./internal/store`
- `GOCACHE=/private/tmp/lattice-gocache GOWORK=... go test -race ./internal/server -run 'TestNodeGeo'`
- `GOCACHE=/private/tmp/lattice-gocache GOWORK=... go test -race ./internal/store -run 'TestNodeGeoIsCopied|TestBoltStateRecordLevelNodeKVAndAudit'`
- `npm run check`
- `npm test` (51/51 dashboard tests)
- `git diff --check` in `lattice`, `lattice-server`, and `lattice-dashboard`

Known verification limits:
- `go test ./internal/server ./internal/store` passed `internal/store` but the
  server package hit the existing OIDC `httptest.NewServer` sandbox limitation:
  `listen tcp6 [::1]:0: bind: operation not permitted`.
- The real HTTP smoke test was attempted with a built server binary, but this
  sandbox rejected local bind/connect on `127.0.0.1:8099`; no application-level
  failure was observed before the network denial.
