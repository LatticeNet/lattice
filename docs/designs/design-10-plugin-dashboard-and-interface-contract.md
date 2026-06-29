# Design 10 — Plugin dashboard injection + interface registration

## Status

Draft for review. Extends design-08 (real runners), design-09 (vpn-core/sub-store
plugins). Motivated by a direct operator question: *if vpn-core / sub-store are
plugins, how do they show up in the dashboard, and shouldn't a plugin have (a) a
dashboard UI-injection spec and (b) a way to register the functional interfaces
it exposes?* Yes to both — this is the contract for it.

## TL;DR

Today a plugin can be loaded, signed, verified, and (now) executed by the system
runner — but it is **invisible to the operator beyond the Platform → Plugins
lifecycle screen**, and the actual vpn-core/sub-store UI (Inbounds, Users,
Discovered, Sub-Store …) is **baked into the core dashboard**, not contributed by
the plugin. There is also **no way for the dashboard to call a plugin's exposed
interface** (the RPC bus is in-server only).

This design adds two declarative, CSP-safe contracts:

1. **UI contributions** — the manifest declares nav entries + view descriptors;
   the server exposes them; the dashboard renders them from a fixed set of view
   primitives (no plugin-supplied code/HTML). 
2. **Interface registration + gateway** — the manifest declares the interfaces
   the plugin exposes (rpc services/methods + schemas); a scoped server gateway
   (`/api/plugins/{id}/call/...`) bridges dashboard → broker RPC → plugin, so a
   contributed view can fetch live data from the plugin.

Both are **data, not code** — the dashboard never executes plugin-supplied
JavaScript or HTML (strict CSP is a hard constraint), so the attack surface stays
the manifest + the broker, which are already signed + capability-gated.

## A. Current state (grounded)

- **Manifest** (`internal/plugin/plugin.go`): `{id,name,type,version,publisher,
  entrypoint,capabilities,digest_sha256,signature_ed25519}`. Decoded with
  `DisallowUnknownFields` — so any new field must be added to the `Manifest`
  struct AND the index/signing payload, or verification fails.
- **Dashboard nav** (`lattice-dashboard/src/router/nav.ts`): a STATIC array of
  sections → items `{name,title,path,icon,scopes}`; the router builds routes from
  it; each view is a hand-written `.vue` under `src/views/`. Plugins contribute
  nothing here.
- **Plugins screen**: `PluginsView.vue` shows only lifecycle (Registered /
  Lifecycle / Verify) via `GET /api/plugins`, `POST /api/plugins/lifecycle`,
  `POST /api/plugins/verify`. No plugin can inject a view.
- **RPC bus** (design-09 §F, shipped): `plugin.RPCRegistry` + `rpc:expose` /
  `rpc:call` + `Broker.RPCCall`. In-server only — there is no HTTP path for the
  dashboard to invoke a plugin service.
- **System runner** (design-08, now wired via `LATTICE_PLUGIN_RUNTIME_DIR`):
  executes the artifact's `{action,payload}`→`{ok,result,…}` protocol.
- **vpn-core / sub-store**: real registered+signed plugins, but their actual UI
  (the Proxy section) and engine are in core. The plugin artifacts only answer
  describe/health/plan today.

## B. UI contribution contract (manifest-declared, CSP-safe)

Add an optional `ui` object to the manifest:

```json
"ui": {
  "nav": [
    { "section": "proxy", "title": "vpn-core", "route": "vpn-core/nodes",
      "icon": "Radar", "scopes": ["proxy:read"] }
  ],
  "views": [
    { "route": "vpn-core/nodes", "title": "vpn-core nodes",
      "kind": "table",
      "source": { "interface": "latticenet.vpn-core/nodes", "method": "list" },
      "columns": [
        { "key": "name", "label": "Name" },
        { "key": "protocol", "label": "Protocol" },
        { "key": "share_url", "label": "Link", "render": "copy-secret" }
      ],
      "actions": [
        { "label": "Add node", "interface": "latticenet.vpn-core/nodes",
          "method": "add", "form": [ { "key": "protocol", "kind": "select",
          "options": ["reality","vmess","trojan","hysteria2"] },
          { "key": "port", "kind": "int" } ], "scopes": ["proxy:admin"] }
      ]
    }
  ]
}
```

Rules:

- `kind` ∈ a FIXED set of dashboard-provided primitives: `table`, `detail`,
  `form`, `kv`, `markdown` (a server-sanitized subset). The dashboard renders
  ONLY these; a plugin can never ship HTML/JS. New primitives are added to the
  dashboard, not the plugin.
- `route` is namespaced under the plugin id → mounted at `/plugins/<id>/<route>`;
  nav `section` may target an existing section (e.g. `proxy`) or `plugins`.
- `scopes` reuse core RBAC; the nav/action is hidden/denied without them. A UI
  contribution can NOT grant itself capability — it only declares intent.
- `render` hints (`copy-secret`, `bytes`, `relative-time`, `badge`) map to the
  dashboard's existing safe formatters (share links stay copy-only).

Server: `Manifest.UI` field (validated: known kinds, namespaced routes, known
icons allow-list, scopes ⊆ recognized RBAC scopes). `GET /api/plugins` already
returns the manifest set; include `ui` so the dashboard can build nav/views.
Only **active** plugins contribute (lifecycle gates visibility).

Dashboard: a `usePluginContributions()` composable fetches `/api/plugins`,
merges active plugins' `ui.nav` into the sidebar, and registers a single dynamic
route `/plugins/:id/:view*` → a `PluginView.vue` that renders the declared
primitive, pulling data through the gateway (§C). Zero plugin code runs in the
browser.

## C. Interface registration + dashboard→plugin gateway

Add an optional `interfaces` array to the manifest (what the plugin EXPOSES):

```json
"interfaces": [
  { "service": "latticenet.vpn-core/nodes", "methods": ["list","add","delete","export"],
    "scopes": ["proxy:read"] }
]
```

- A plugin with `rpc:expose` registers these in the `RPCRegistry` at activation
  (the server reads the manifest `interfaces` and binds them to the running
  plugin via the runner's Invoke). The manifest declaration is the *contract*;
  the registry is the *runtime*.
- **Gateway** (new): `POST /api/plugins/{id}/call` `{service,method,payload}`
  (scoped per the interface's declared scopes; CSRF; audited). The server: checks
  the caller's scopes → looks up the service in `RPCRegistry` → if the service is
  in-core (e.g. the current `latticenet.vpn-core/nodes`), calls the in-core
  handler; if it's a runner-backed plugin, the registry handler bridges to
  `pluginRuntime.Invoke(id, action, payload)`. Either way the dashboard calls one
  uniform endpoint.
- This is the missing **dashboard ↔ plugin** path. It reuses the RPC bus +
  capability/audit machinery; it does NOT expose raw broker handles.

## D. How vpn-core / sub-store use it (migration)

This makes the two existing plugins *do* something visible, incrementally,
without breaking the shipped core views:

1. **Register interfaces** for the in-core services on the bus (vpn-core already
   exposes `nodes/export`; add `list/add/delete` wrappers around the existing
   `/api/proxy/discovered` + `/api/proxy/managed/*` handlers as RPC methods).
2. **Declare `ui` + `interfaces`** in the two plugins' manifests (v0.2.0).
3. The dashboard renders the contributed nav/views from the active plugins →
   the Proxy section's "Discovered"/"Sub-Store" entries become *plugin
   contributions* instead of hard-coded nav, fed through the gateway.
4. Core keeps the engine (ADR D5/D6); the plugin is the official front AND now
   owns its dashboard surface declaratively.

End state for the operator's complaint: activating vpn-core makes the VPN UI
appear *because the plugin contributes it*; deactivating it removes the UI. The
plugin is no longer invisible.

## E. Phases

| Phase | Deliverable | Repos |
|---|---|---|
| **1** | `Manifest.UI` + `Manifest.Interfaces` fields + validation; `GET /api/plugins` returns them; index/signing payload updated | lattice-server, lattice-plugin-index |
| **2** | Dashboard `usePluginContributions` + dynamic nav merge + `PluginView.vue` primitives (table/detail/form/kv/markdown) | lattice-dashboard |
| **3** | Gateway `POST /api/plugins/{id}/call` (scoped, audited) bridging to RPC/Invoke | lattice-server |
| **4** | vpn-core/sub-store v0.2.0 manifests declare `ui`+`interfaces`; in-core services registered; migrate the Proxy nav entries to contributions | plugin repos + both |

Each phase is independently shippable and non-breaking (the static nav stays
until phase 4 migrates entries one at a time).

## F. Security (the hard constraints)

- **No plugin code in the browser.** UI contributions are declarative data
  rendered by fixed dashboard primitives. Strict CSP stays intact (no inline
  scripts, no plugin-served assets).
- **No new trust surface.** The manifest is already signed; `ui`/`interfaces`
  are covered by the same signature (added to `SigningPayload`). A tampered
  contribution fails verification.
- **Gateway is capability-gated + audited.** Every `/api/plugins/{id}/call`
  checks the interface's declared scopes against the principal, records an audit
  event, and routes through the RPC registry's directed allow-list — never a raw
  handle.
- **Icons/kinds/render hints are allow-listed**, so a contribution can't smuggle
  an unknown renderer or asset reference.

## G. Open questions

1. Whether contributed views may target arbitrary existing sections (e.g.
   inject into `fleet`) or only `plugins`/their own section — start restrictive
   (own section + an allow-list like `proxy`).
2. Schema language for action forms — start with the small `{key,kind,options}`
   shape above; consider JSON-Schema later.
3. Versioning a contribution vs the plugin version — tie to plugin version for
   now (a manifest change is a new signed release).
