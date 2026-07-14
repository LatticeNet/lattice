# Design 14 - Plugin-owned vpn-core control surface

> Status: accepted for alpha implementation on 2026-07-13.
> Builds on: design-08, design-09, design-10, design-11, design-12.

## 1. Intent

`latticenet.vpn-core` owns its navigation, pages, field semantics, forms, and
sing-box workflows. The base dashboard remains useful without the plugin and
must not contain hidden vpn-core pages or sing-box-specific form controls.
Installing or activating the plugin adds capability; disabling it removes that
UI without breaking console routes.

The dashboard is a generic host. It provides the sandbox, design tokens,
manifest-filtered navigation, an audited bridge, and host-owned security
ceremonies such as step-up. It does not embed plugin business logic or expose
session credentials to an iframe.

## 2. Ownership boundary

| Layer | Owns | Must not own |
| --- | --- | --- |
| Dashboard | sandbox, navigation, responsive shell, bridge limits, step-up UX | sing-box models, routes, field precedence, mutation workflows |
| vpn-core plugin | Lines, Users, Node Profiles, Usage UI; validation; workflow intent | raw host handles, unrestricted HTTP, direct filesystem access |
| Server | RBAC, exact node confinement, plan hash, approval, audit, plugin KV, task dispatch | plugin-specific visual presentation |
| Node agent | bounded execution after explicit opt-in | product UI, authorization policy, unreviewed downloads |

The base node UI keeps only generic execution prerequisites such as
`allow_exec` and `allow_root_exec`. Discovery target, sing-box binary, usage
source, and related settings are exposed only through vpn-core interfaces.

## 3. Immediate alpha contract

1. Navigation contains exactly `Lines`, `Users`, `Node Profiles`, and `Usage`.
   `Subscriptions` is removed.
2. Plugin data loads on entry, explicit operator refresh, and after the
   plugin's own successful mutation. There is no interval polling.
3. Line address fields remain distinct:
   - Endpoint: public transport address (`public_host:port`).
   - Listen: local bind (`listen_host:port`).
   - Reality SNI/server name: `domain`.
   A camouflage SNI such as `aws.amazon.com` is never labeled as the endpoint.
4. The extension sidebar is resizable on desktop and always exposes full plugin
   name and ID through an accessible tooltip.
5. Plugin breadcrumbs use `<plugin display name> / <destination>`.
6. Profile configuration writes only vpn-core-owned fields, preserves generic
   agent settings, is exact-node authorized and audited, and returns a
   reconfigure command rather than executing it automatically.

## 4. Mutation safety

Host mutation remains fail-closed. The plugin creates or requests a reviewable
plan; the server binds approval to the plan digest and target node; the agent
executes only when task and root execution are explicitly enabled. Destructive
actions require host-owned step-up and never receive authentication secrets in
the iframe.

The existing sing-box auto-provision path that follows an unpinned `latest`
download without a reviewed SHA-256 is not eligible for the plugin write
surface. It must be replaced by an explicit version, URL, and digest in the
approval plan before automatic installation can be enabled.

## 5. Lifecycle and compatibility

Activation is the UI and host-access gate. Disable stops the runtime, revokes
method grants, and removes contributions immediately. A later uninstall slice
must additionally purge or tombstone plugin-owned KV, approvals, and pending
tasks without modifying already-applied node configuration implicitly.

All releases for this work remain prereleases. Dashboard/server deployment uses
the `alpha-0.2.1aN` train; vpn-core uses a SemVer prerelease and must be signed
with the trusted `latticenet` Ed25519 publisher key before production loading.

## 6. Verification

- Unit tests for sidebar width clamping/persistence and plugin breadcrumb data.
- Plugin tests for route allowlists, manual refresh behavior, address semantics,
  and user/profile payload validation.
- Server tests for exact-node authorization, generic-field preservation, input
  rejection, audit, and absence of automatic task execution.
- Browser verification at desktop and narrow widths with the production
  sandbox/CORS path.
