# Design 11 - VPN Manage plugin migration review

## Status

Implemented migration note after the 2026-06-29 framework/security pass. This
extends design-09 and design-10.

## Executive decision

The dashboard no longer exposes a static `Proxy` sidebar section. vpn-core and
Sub-Store now contribute their entries under a shared plugin-owned `vpn-manage`
section. The implementation uses a first-party `builtin` view primitive: signed
official plugin manifests declare which dashboard-owned Vue page to mount, while
the dashboard still executes no plugin JavaScript.

The business engine remains in `lattice-server` core. That is intentional: these
pages still carry rich first-party workflows that would be unsafe and wasteful to
rebuild as third-party declarative table/form primitives:

- Inbounds CRUD with generated REALITY keys and masked secret state.
- Users CRUD, subscription-token rotation, quotas, expiry, and status.
- Node Profiles with plan -> approval -> apply.
- Usage accounting and collector-health status.
- Discovered sing-box inventories with add/delete task queueing.
- Sub-Store management beyond the current one-shot import helper.

Old `/proxy/*` deep links are retained as redirects to the new plugin-owned
routes. The next parity milestone is a fuller Sub-Store embedded service rather
than the current managed-import companion page.

## What was fixed in this pass

Framework fixes now landed in `lattice-server` and `lattice-dashboard`:

- Added `/api/plugin-contributions`, a low-sensitivity discovery endpoint for
  active plugin UI only. The full plugin registry remains behind `audit:read`.
- Plugin UI actions are no longer frontend-only security. `ViewAction.scopes`
  are enforced server-side by `/api/plugins/call` and audited on allow and deny.
- Manifest contribution scopes are validated against the real RBAC catalog, not
  just a token-shaped regex.
- Manifest views/actions must reference declared interface methods.
- Manifest interface services must be namespaced under the plugin id
  (`<plugin-id>/...`), preventing a plugin from declaring another plugin's
  service name and routing through the operator gateway.
- Manifest interface methods now reject unsafe or duplicate names.
- Contributions endpoint filters hidden actions and returns only the interface
  methods needed by the currently visible UI.
- Dashboard plugin routes support nested paths such as
  `/plugins/latticenet.vpn-core/nodes`.
- Dashboard plugin nav can create/merge safe custom sections. For example,
  both vpn-core and Sub-Store can contribute to `vpn-manage`; existing sections
  are merged and unknown safe sections are created dynamically.
- Dashboard contribution gating now requires all declared scopes for a nav item,
  view source, or action, matching backend behavior.
- Added a first-party `builtin` plugin view primitive. Each component key is
  allow-listed and bound to a specific official plugin id, so another plugin
  cannot claim `proxy.users` or `proxy.substore`.
- Removed the static `Proxy` section from sidebar IA and added legacy redirects
  from `/proxy/*` to `/plugins/latticenet.vpn-core/*` or
  `/plugins/latticenet.sub-store/sub-store`.
- Re-signed `lattice-plugin-vpn-core` v0.3.0 and `lattice-plugin-sub-store`
  v0.2.0 manifests with updated UI contributions under `vpn-manage`.

## Current product state

### Static Proxy surface

The static `Proxy` group has been removed from `lattice-dashboard/src/router/nav.ts`.
The same pages are now mounted through plugin-owned routes:

- Inbounds
- Users
- Node Profiles
- Subscriptions
- Usage
- Sub-Store
- Discovered

These still map to hand-written Vue pages under `src/views/proxy/` and to core
server APIs under `/api/proxy/*` and `/api/substore/*`. They are now owned in IA
by official plugins, while the stateful engine stays in core.

### vpn-core plugin

`lattice-plugin-vpn-core` v0.3.0 is signed and contributes the VPN Manage
sidebar entries for Inbounds, Users, Node Profiles, Subscriptions, Usage,
Discovered, and VPN Core Nodes. The rich pages use `builtin` component keys; the
data interface still exposes:

- `latticenet.vpn-core/nodes.list`
- `latticenet.vpn-core/nodes.export`

It does not yet expose inbounds/users/profiles/subscriptions/usage/batch user
management as plugin interfaces.

### Sub-Store plugin

`lattice-plugin-sub-store` v0.2.0 is signed and contributes the Sub-Store entry
under VPN Manage via the `proxy.substore` builtin component. The shipped server
helper at `/api/substore/*` still only imports vpn-core node links into an
operator-supplied Sub-Store backend URL; a full embedded service lifecycle is
still the next stage.

### sing-box local tool

The local `sing-box` repo already has useful machine-output paths:

- `sb --json list`
- `sb --json info <name>`
- `sb --json sub`
- `sb --json provision`
- `sb --json backup`
- `sb --json add ...`
- `sb --json change ...`
- `sb --json del <name>`

The `ask()` guard fails structured in `--json` mode, which is good for
headless dashboard use. Remaining hardening needed before deeper automation:

- JSON `info/change/del` still use regex file matching internally; change them
  to exact literal matching (`grep -F` or direct filename resolution).
- Dashboard-triggered calls must always pass `--json`, `--addr`, and every
  required argument so no path can reach `ask()` or `select`.
- Management must use discovered names or a server-owned alias map, not raw
  arbitrary filename filters.
- For batch user/node operations, require dry-run/plan output before enqueueing
  host mutation tasks.

### Sub-Store local source

The local Sub-Store backend is a full Node/Express service:

- Entry: `backend/src/main.js` -> migration -> REST server.
- Routes: `/api/*`, `/download/*`, `/share/*`.
- Storage: local JSON files under `SUB_STORE_DATA_BASE_PATH`.
- Runtime features: cron jobs, remote subscription fetches, Gist sync,
  remote data restore, optional frontend merge/proxy, proxy-aware HTTP fetches.
- License files are not fully consistent: `backend/package.json` says
  `GPL-3.0`, while repository `LICENSE` is AGPL-3.0 text. Treat this as a
  copyleft/legal boundary and avoid copying code into Lattice until clarified.

Recommended integration is supervised internal service isolation, not rewriting
or linking Sub-Store into the Go server.

## Security review findings

### Fixed

- Backend now enforces plugin UI action scopes.
- Backend now audits plugin gateway denies, not only successful calls.
- Low-permission sidebar discovery no longer requires `audit:read`.
- Low-permission discovery no longer returns unrelated plugin interface methods.
- Plugin interfaces are now scoped to the declaring plugin's namespace.
- Manifest contribution scopes/methods/routes are stricter.

### Still open

- Static Proxy routes remain core-owned and visible until plugin parity exists.
- `proxy:read` / `proxy:admin` remain broad domain scopes. Node profiles have
  per-node restrictions, but global objects like inbounds/users intentionally
  require an unrestricted allowlist. A future plugin split should introduce
  narrower scopes such as `vpncore:read`, `vpncore:admin`, `substore:read`,
  and `substore:admin`.
- `/api/substore/status` and `/api/substore/import` still accept per-request
  `base_url`. That was acceptable for an authenticated admin-only helper, but a
  full embedded Sub-Store feature should move to server-side persisted,
  reviewed configuration with loopback/private binding and no arbitrary
  per-request target.
- Sub-Store has powerful remote-fetch and remote-restore features. When embedded
  behind Lattice, disable or gate:
  - `SUB_STORE_DATA_URL`
  - `SUB_STORE_DATA_URL_POST`
  - public management API exposure
  - frontend merge mode unless intentionally proxied by Lattice
  - cron jobs until an operator explicitly enables them
- sing-box JSON mutation paths need literal filename matching before they are
  treated as a safe CRUD substrate for arbitrary dashboard operations.

## Target sidebar architecture

Plugins may contribute:

```json
{
  "section": "vpn-manage",
  "section_title": "VPN Manage",
  "title": "VPN Core",
  "route": "vpn-core/overview",
  "icon": "Radar",
  "scopes": ["proxy:read"]
}
```

Dashboard behavior:

- If `vpn-manage` does not exist, create it.
- If another active plugin already contributed `vpn-manage`, append to it.
- Existing built-in sections may still be targeted through explicit aliases,
  but unknown safe section ids are plugin-owned sections.
- The old `Proxy` section should be hidden only when every static item has a
  plugin-owned replacement and parity checks pass.

Expected end state:

```text
VPN Manage
  VPN Core
    Inbounds
    Users
    Node Profiles
    Subscriptions
    Usage
    Discovered Nodes
  Sub-Store
    Dashboard
    Subscriptions
    Collections
    Artifacts
    Settings
```

The current declarative table/form primitives are enough for read-only lists and
simple actions. They are not enough for the full VPN Core and Sub-Store UX. Two
implementation paths are viable:

1. Add a first-party "core-backed plugin page" primitive that maps signed
   plugin contributions to bundled Vue pages already shipped with the dashboard.
   This keeps CSP intact because no plugin code runs in the browser.
2. Extend the declarative primitive system substantially: tabs, dialogs,
   multi-step forms, batch actions, plan previews, approval links, download
   links, and server-provided option loaders.

For first-party vpn-core/Sub-Store, path 1 is faster and safer.

## Recommended migration plan

### Phase 1 - Framework hardening

Done in this pass:

- Dynamic plugin sections.
- Nested plugin routes.
- Contributions endpoint.
- Server-enforced action scopes.
- Interface namespace/method validation.

### Phase 2 - First-party page contribution primitive

Add a dashboard-owned `kind: "builtin"` or `view.component_key` contribution:

- Allowed keys are hardcoded in dashboard, for example:
  - `vpn-core.inbounds`
  - `vpn-core.users`
  - `vpn-core.profiles`
  - `vpn-core.subscriptions`
  - `vpn-core.usage`
  - `vpn-core.discovered`
  - `sub-store.dashboard`
- Server validates allowed keys and scopes.
- Dashboard lazy-loads existing bundled Vue pages through those keys.
- Plugin activation controls visibility and information architecture, but the
  trusted dashboard bundle still owns all code.

This enables moving static Proxy pages under plugin-owned `vpn-manage` without
rewriting every page into the current table/form schema.

### Phase 3 - vpn-core interface expansion

Register in-core RPC services under `latticenet.vpn-core/...`:

- `inbounds.list/upsert/delete`
- `users.list/upsert/delete/rotate-sub-token/batch-upsert`
- `profiles.list/upsert/delete/plan`
- `subscriptions.list/render`
- `usage.list`
- `discovered.list/provision/add/change/delete/backup`
- `nodes.export`

All methods must use the existing core handlers or shared service functions so
the security model remains identical to current `/api/proxy/*`.

### Phase 4 - sing-box management hardening

Before richer CRUD:

- Patch the local sing-box script JSON lookup paths to exact matching.
- Add `sb --json change <name> ...` tests for non-interactive behavior.
- Add `sb --json provision --install` or a separate install action with
  explicit dry-run output.
- Add alias metadata support in Lattice, not in filename parsing. Suggested
  model: `{node_id, discovered_name, alias, tags, last_seen_at}`.
- Add batch user/node apply as a reviewed Lattice task plan, never as a silent
  direct mutation.

### Phase 5 - Sub-Store embedded service

Run Sub-Store as an internal supervised service:

- Bind to `127.0.0.1:<allocated>` or a Unix socket where practical.
- Set `SUB_STORE_DATA_BASE_PATH` under a Lattice-owned data dir.
- Disable public frontend merge and remote restore by default.
- Lattice server owns service lifecycle, health, logs, backup, and upgrades.
- Lattice exposes `/api/substore/internal/*` or `/plugins/latticenet.sub-store/*`
  as an authenticated reverse proxy.
- Lattice injects vpn-core imports through Sub-Store's local subscription API,
  not by exporting to an unrelated external service.
- Public `/download` or `/share` exposure is opt-in and should be a separate
  review because it creates a public subscription delivery surface.

### Phase 6 - Remove static Proxy section

Only after:

- Every current static item has a plugin-owned replacement.
- The old routes redirect to plugin routes for one release.
- Tests cover sidebar grouping, RBAC visibility, route deep links, and each
  CRUD/plan/approval path.
- The plugin manifests are rebuilt, re-signed, and index metadata updated.

## Test matrix required before hiding Proxy

- `proxy:read` user sees read-only vpn-core and Sub-Store views but no admin
  actions.
- `proxy:admin` user sees mutation actions.
- Node-restricted principal can list only allowed node profiles/discovered nodes
  and cannot mutate global inbounds/users.
- Plugin inactive means no vpn-core/Sub-Store nav.
- Both vpn-core and Sub-Store active means both appear under one `vpn-manage`
  section.
- Deep links under `/plugins/<id>/vpn-core/...` survive refresh.
- Inbounds/users/profile CRUD parity against current static pages.
- Plan -> approval -> apply still uses existing approval safeguards.
- Sub-Store internal service cannot be reached without Lattice auth.
- Sub-Store service health failure is visible and does not look like a successful
  import/sync.
- sing-box JSON commands fail structured, never prompt, for incomplete input.

## Rejected options

- Reimplement all of Sub-Store in Go now: too large, feature-rich, and legally
  risky given the license ambiguity/copyleft boundary.
- Directly copy Sub-Store source into Lattice server: unnecessary coupling and
  unclear AGPL/GPL implications.
- Hide `Proxy` immediately: breaks production workflows before plugin parity.
- Let plugins ship dashboard JavaScript: violates CSP and increases the trusted
  browser attack surface.
- Allow arbitrary per-request Sub-Store backend URLs for the final embedded
  service: acceptable for the current admin helper, not for a first-class
  managed service.
