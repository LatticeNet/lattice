# Iteration 023 — NetPolicy Graph SVG

- **Status:** Verified / Ready to commit (2026-06-14)
- **Design link:** `docs/designs/design-05-network-acl-and-map.md`
- **Builds on:** `iter-020-netpolicy-state-and-graph.md`, `iter-021-netpolicy-egress-apply.md`, `iter-022-node-geo-map.md`
- **Repos:** `lattice-dashboard`, `lattice`

## Goal

Upgrade the dashboard Network Policy visualization from text lists into a
dependency-free inline SVG graph driven by the existing server-derived
`GET /api/netpolicy/graph` response. The dashboard still makes no security
decisions: it only renders the graph the server already computed.

## Scope

- Add pure dashboard helpers for policy graph layout/render inputs:
  - deterministic circular node layout;
  - deterministic edge paths between nodes;
  - external rule grouping/labels;
  - compact node/edge labels;
  - defensive filtering of malformed graph entries.
- Update the Network Policy panel to render:
  - inline SVG nodes;
  - directional allow/deny edges;
  - online/offline node state;
  - edge tooltips;
  - external rule summary beside the SVG.
- Keep the existing list view as a textual fallback/detail view.
- Add unit tests for layout, malformed data filtering, and labels.
- Update docs to mark policy-graph SVG as landed and narrow the next Design 05
  work to ingress/domain sets/IPv6/bulk geo import/overlays.

## Explicit Non-Scope

- No server API changes.
- No client-side policy evaluation.
- No graph force simulation, canvas, WebGL, d3, map library, or new dependency.
- No ingress compiler or firewall apply changes.
- No latency/map edge overlay in this slice.

## Security Notes

- The SVG is display-only and must never determine authorization, planability,
  or apply behavior.
- All graph/node/edge labels must be escaped before HTML/SVG interpolation.
- Malformed graph entries are ignored in the renderer rather than widened into
  misleading edges.
- The server remains the source of truth for graph semantics.

## Verification Plan

- `assets/policygraph.test.mjs`:
  - stable circular layout;
  - invalid edges dropped;
  - external refs grouped safely;
  - labels and class names are bounded/known.
- Dashboard:
  - `npm run check`;
  - `npm test`;
  - `git diff --check`.
- Docs:
  - `git diff --check`;
  - grep for stale "policy graph SVG pending" wording.

## Exit Bar

Operators can see a first-class visual reachability graph in the dashboard,
backed by server graph JSON, while retaining the existing textual rule detail.

## Implementation Log

- `lattice-dashboard`:
  - added `assets/policygraph.js` pure helpers for graph normalization,
    circular layout, SVG path/arrow geometry, external grouping, and bounded node
    labels;
  - added `assets/policygraph.test.mjs`;
  - updated `renderNetPolicyGraph()` to render an inline SVG graph from the
    server-derived graph response;
  - kept the existing node/external textual lists as detail/fallback;
  - added CSS for graph shell, edges, arrows, nodes, and external summaries;
  - updated dashboard README.
- `lattice` docs:
  - updated Design 05, design index, roadmap, product vision, development
    report, program review, and iter-022 residual notes so policy-graph SVG is
    no longer marked pending.

## Review Outcome

- Local review found one UI stability issue before close: long node labels could
  overflow the SVG. Fixed by adding `compactPolicyNodeLabel`; SVG text is
  bounded while `<title>` keeps the full node name.
- Security/architecture review:
  - all server graph strings are escaped before HTML/SVG interpolation;
  - SVG class names for edge action are constrained to `allow` / `deny`;
  - malformed edges pointing to unknown nodes are dropped by the renderer;
  - the dashboard still performs no policy evaluation and cannot affect
    planning/apply semantics.

## Residuals / Next

- Ingress composition was the next high-risk Design 05 backend slice and is now
  closed by iter-024: ingress folds into `lattice_guard` rather than adding a
  second default-drop input table.
- Domain/DDNS-backed nft named sets and IPv6 policy remain pending.
- Bulk geo import and map overlays (latency, ASN, renewal/cost) remain pending.
- Once ingress compilation lands, add compiler-vs-graph parity tests so
  visualization and enforcement cannot drift.

## Verification

- `npm run check`
- `npm test` (57/57 dashboard tests)
- `git diff --check` in `lattice-dashboard`
- `git diff --check` in `lattice`
- stale-doc search for policy-graph SVG pending wording

Known verification limits:
- Browser smoke through Playwright was attempted without binding a local port,
  but the current Node environment does not have `playwright` installed.
- Localhost HTTP smoke remains unavailable in this sandbox because previous
  server runs failed with `bind/connect operation not permitted`.
