# Self-Contained Plugin Bundles

**Status:** Approved for alpha implementation  
**Date:** 2026-07-13  
**Scope:** `lattice-server`, `lattice-dashboard`, `lattice-plugin-index`,
`lattice-plugin-template`, `lattice-plugin-sub-store`,
`lattice-plugin-netguard`, `lattice-plugin-wireguard`, and
`lattice-plugin-vpn-core`

## 1. Decision

Lattice plugins become self-contained product units. A plugin repository owns
its domain backend, rich UI, schemas, migrations, build pipeline, tests, and
release artifact. The server and dashboard own only generic hosting,
authorization, approval, task, audit, storage, and isolation facilities.

The alpha implementation uses a signed deterministic bundle with a sandboxed
iframe UI. Plugin JavaScript never executes in the dashboard's origin context
and cannot access dashboard state, cookies, CSRF tokens, native DOM, or arbitrary
core APIs. The parent dashboard exposes a narrow, versioned message bridge that
can call only active, manifest-declared plugin interfaces.

During this alpha, plugins may contribute pages only inside the Extensions
navigation workspace. Plugins cannot modify Map, Nodes, Tasks, Node Detail, or
other native pages. Cross-page extensions are deferred until a separate generic
extension-slot contract exists.

## 2. Problem

The current official plugins are not uniformly self-contained:

- `vpn-core`, `netguard`, and `wireguard` ship a signed manifest and a thin
  process that implements only `describe`, `health`, and `plan`; their rich UI
  and most business logic remain compiled into the dashboard and server.
- `sub-store` implements meaningful runtime `call` behavior, but its UI remains
  a dashboard builtin and still has a legacy core REST fallback.
- The loader accepts exactly `manifest.json` plus one executable `artifact`.
- The manifest can request a dashboard-owned `builtin` component key but cannot
  carry signed UI assets.
- Disabling a plugin gates visibility and calls, but plugin-specific source code,
  in-core RPC handlers, redirects, and some background requests remain present.

This produces activation isolation, not package, source, release, or failure
isolation. It also means a plugin UI or business change still requires a full
dashboard/server release.

## 3. Goals

1. A plugin release contains everything required for its own pages and domain
   behavior.
2. Installing or upgrading a plugin does not require rebuilding the dashboard.
3. Disabling or uninstalling a plugin leaves the base dashboard and server fully
   functional, with no plugin-specific failed polling or placeholders.
4. Plugin UI cannot access the dashboard DOM, authentication material, or an
   undeclared server operation.
5. Host-risk operations retain deterministic plan, explicit approval, immutable
   plan binding, audit, task confinement, and rollback behavior.
6. Official and third-party publishers use the same contract after their signing
   key is explicitly trusted by the operator.
7. Existing v1 plugins continue to load during migration, but no new builtin
   component keys are accepted for v2 bundles.

## 4. Non-Goals

- Plugins do not inject controls into native pages in this alpha.
- Plugins do not receive arbitrary HTTP routes, raw database access, shell
  handles, server memory access, or browser credentials.
- The plugin index does not become an automatic, unattended marketplace in this
  slice. Remote download/install remains a separate reviewed operation.
- Core domain data is not deleted as part of migration. It remains a rollback
  snapshot until an explicit destructive purge.
- Stable releases and GitHub Latest pointers do not move during this work.

## 5. Alternatives

### 5.1 Selected: signed bundle plus sandboxed iframe

This provides plugin-owned code while preserving a hard browser trust boundary.
The additional bridge and asset-host complexity is justified by independent
release and uninstall behavior.

### 5.2 Rejected: same-origin ESM or Module Federation

This would offer direct Vue component integration, but loaded plugin JavaScript
would execute with dashboard privileges and could reach the DOM, stores, cookies,
and same-origin APIs. Publisher signatures establish identity, not correctness.

### 5.3 Rejected as the only model: declarative views

Declarative tables and forms remain useful for simple plugins, but they cannot
express nftables rule editors, WireGuard peer/network management, VPN Lines, or
other rich workflows. They cannot satisfy self-contained complex plugins alone.

## 6. Bundle V2

### 6.1 Release layout

The release continues to publish a human-reviewable `manifest.json` and one
opaque file named `artifact`. For v2, `artifact` is a deterministic `tar.gz`, not
a directly executable file.

```text
manifest.json
artifact
  bin/linux-amd64/plugin
  bin/linux-arm64/plugin
  ui/index.html
  ui/assets/app.<hash>.js
  ui/assets/app.<hash>.css
  schemas/*.json
  migrations/*
```

Every path is relative, slash-separated, and normalized. The archive may contain
regular files and directories only. Symlinks, hardlinks, devices, FIFOs, sockets,
absolute paths, empty components, `.`/`..`, backslashes, control characters, and
duplicate normalized paths are rejected.

### 6.2 Deterministic build

The official packer must:

- sort entries bytewise by normalized path;
- set gzip mtime and tar timestamps to Unix epoch;
- set uid/gid to zero and omit user/group names;
- normalize directories to `0700`, runtime binaries to `0700`, and all other
  files to `0600` in the staged copy;
- omit extended attributes and host-specific metadata;
- produce identical bytes from identical source inputs.

CI builds the bundle twice in clean directories and compares SHA-256 digests.

### 6.3 Manifest v2

```json
{
  "schema": "lattice.plugin.manifest.v2",
  "id": "latticenet.example",
  "name": "Example",
  "version": "0.2.1-alpha.1",
  "publisher": "latticenet",
  "type": "system",
  "capabilities": ["kv:read"],
  "bundle": {
    "format": "tar+gzip",
    "digest_sha256": "..."
  },
  "runtime": {
    "protocol": "stdio-json-v1",
    "entrypoints": {
      "linux/amd64": "bin/linux-amd64/plugin",
      "linux/arm64": "bin/linux-arm64/plugin"
    }
  },
  "ui_runtime": {
    "mode": "sandbox",
    "entrypoint": "ui/index.html",
    "bridge_version": "1"
  },
  "compatibility": {
    "server": ">=0.2.1",
    "dashboard_host": ">=1",
    "runtime_protocol": ">=1"
  },
  "ui": {
    "nav": [],
    "views": []
  },
  "interfaces": [],
  "signature_ed25519": "..."
}
```

For v2, the legacy top-level `entrypoint`, `digest_sha256`, and builtin
`component_key` fields are rejected. `ui.views[].kind` may be `sandbox` or an
existing safe declarative primitive. A sandbox view references the one signed
`ui_runtime`; it never names a dashboard component.

The v2 signing payload is a versioned, typed manifest serialization with
`signature_ed25519` omitted, prefixed by
`LATTICE-PLUGIN-MANIFEST-V2\n`. Publishers sign only through the repository's
`pluginsign` command, which is the canonical serializer. The payload includes
bundle digest, runtime entrypoints, UI runtime, compatibility, nav, views,
interfaces, and capabilities. V1 verification remains unchanged.

### 6.4 Loader bounds

The server verifies the compressed artifact digest and publisher signature
before decompression. Alpha defaults:

- compressed artifact: 64 MiB;
- total expanded bytes: 256 MiB;
- one expanded file: 32 MiB;
- file count: 2048;
- normalized path length: 240 bytes;
- nesting depth: 16.

Extraction writes to a new `0700` staging directory, verifies every bound while
streaming, fsyncs files and directories, then atomically renames to a
content-addressed location keyed by plugin ID, version, and artifact digest.
Partial extraction is removed on failure. An existing content-addressed bundle
is reused only after its recorded digest and metadata are revalidated.

The system runner selects the exact `GOOS/GOARCH` entrypoint, copies or opens only
that verified regular file, and never executes a manifest path outside the
staged root.

## 7. Plugin UI Host

### 7.1 Navigation and route ownership

Active plugins contribute nav items under the Extensions workspace. The generic
dashboard route remains:

```text
/plugins/:pluginId/:route
```

It resolves to a generic `PluginFrameHost`; the dashboard contains no
plugin-ID-to-component registry. Nav and view declarations are returned only for
active plugins and are filtered by the current principal's scopes.

### 7.2 Asset serving

Verified UI assets are served through a dedicated authenticated route derived
from server-owned values:

```text
/api/plugins/assets/<plugin-id>/<artifact-digest>/<path>
```

The handler serves only files from an active, currently loaded v2 bundle. It
does not accept filesystem paths from requests, does not reuse mutable static
storage, sets `X-Content-Type-Options: nosniff`, uses an explicit MIME allowlist,
and returns `404` for inactive, unknown, stale-digest, or undeclared assets.

HTML receives a route-specific policy that permits framing only by the same
dashboard origin and permits only signed local scripts/styles/assets:

```text
default-src 'none';
script-src 'self';
style-src 'self';
img-src 'self' data:;
font-src 'self';
connect-src 'none';
form-action 'none';
base-uri 'none';
object-src 'none';
frame-src 'none';
frame-ancestors 'self'
```

The generic global `X-Frame-Options: DENY` is replaced only on this authenticated
HTML route with `SAMEORIGIN`. No general CSP relaxation is made.

### 7.3 Iframe sandbox

The dashboard mounts:

```html
<iframe sandbox="allow-scripts" referrerpolicy="no-referrer"></iframe>
```

It does not grant `allow-same-origin`, forms, popups, downloads, modals, pointer
lock, top navigation, storage access, or presentation privileges. The resulting
opaque-origin plugin cannot read cookies or dashboard state. `connect-src 'none'`
prevents direct network/API access even when an asset URL is same-origin.

### 7.4 Bridge protocol v1

Each frame mount receives a random 256-bit channel nonce in the URL fragment.
Because sandboxed frame messages have origin `null`, the host validates both
`event.source === iframe.contentWindow` and the nonce on every message.

Plugin to host messages:

- `lattice.plugin.ready`
- `lattice.plugin.call`
- `lattice.plugin.cancel`
- `lattice.plugin.resize`

Host to plugin messages:

- `lattice.host.init`
- `lattice.host.result`
- `lattice.host.error`
- `lattice.host.theme`
- `lattice.host.dispose`

`init` contains only bridge version, plugin ID/version, current plugin route,
locale, color scheme, and approved design tokens. It does not expose principal,
cookies, CSRF values, raw scope sets, server URLs, or dashboard stores.

For `call`, the host validates:

- source window and channel nonce;
- active plugin ID and exact loaded artifact digest;
- declared service and method ownership;
- principal scopes;
- request ID uniqueness;
- payload size no greater than 256 KiB;
- at most eight in-flight requests per frame;
- 15-second request timeout;
- a default ceiling of 120 calls per minute per frame.

The parent then calls the existing authenticated and audited
`/api/plugins/call` endpoint. Results are capped at 1 MiB before they cross the
bridge. Lifecycle disable or route disposal aborts in-flight calls, sends
`dispose`, invalidates the nonce, and removes the frame.

## 8. Plugin UI Toolkit

`lattice-plugin-template` owns the reference UI host client and starter UI. It
uses the existing Vue 3 ecosystem, Lucide icons, and mature accessible component
patterns, but compiles all runtime dependencies into the plugin bundle. A plugin
must not import dashboard source files or depend on dashboard chunk names.

The toolkit provides:

- typed bridge client with cancellation and structured errors;
- theme-token application;
- compact page shell, toolbar, tabs, table, form, dialog, empty/error/loading
  states, and confirmation patterns;
- test host for component and browser tests;
- deterministic Vite build configuration with no inline scripts, styles, data
  JavaScript, remote fonts, or external asset URLs.

Each plugin repository owns and tests its page code. Shared toolkit upgrades are
normal source dependencies and become part of that plugin's bundle at build
time; no shared browser runtime is assumed.

## 9. Backend Contract

### 9.1 Runtime ownership

Every self-contained system plugin implements `describe`, `health`, `plan`, and
`call`. A plugin with persistent state also implements `migrate`; a plugin with
host-risk operations implements `execute`, which only the approval executor can
invoke. All manifest-declared plugin services resolve to the plugin runtime. A
v2 service cannot fall back to an in-core handler with the same plugin namespace.

The server may expose only generic host services through the broker:

- namespaced KV;
- encrypted namespaced secret storage;
- node inventory and generic reported observations;
- operation plan submission and approval status;
- capability-bound task enqueue;
- notifications and logs;
- guarded HTTP egress;
- explicitly allowed inter-plugin RPC.

Plugin code never receives a raw store, task queue, process handle, node token,
master key, or unrestricted server callback.

Encrypted secret host calls require explicit `secret:read` or `secret:write`
capabilities. Both are host-risk, system-plugin-only capabilities covered by the
trusted-publisher signature requirement. Secret reads are available only to the
plugin backend, never to the browser bridge.

### 9.2 Interface effects

V2 interface methods are typed declarations rather than unqualified strings:

```json
{
  "service": "latticenet.netguard/policies",
  "methods": [
    {"name": "list", "effect": "read", "scopes": ["netguard:read"]},
    {"name": "save", "effect": "write", "scopes": ["netguard:admin"]},
    {"name": "plan", "effect": "plan", "scopes": ["netguard:admin"]}
  ]
}
```

Allowed effects are `read`, `write`, and `plan`. Direct browser-callable
`apply` is not an effect. Scopes are attached to each method and are enforced by
the server; a service-level scope may exist only as an explicit default for
methods that omit one. Host mutation requires a plan and approval.

### 9.3 High-risk operation protocol

1. The plugin receives desired state and live generic observations and returns a
   deterministic `PluginOperationPlan` with target nodes, summary, redacted
   preview, ordered steps, rollback intent, and plugin-defined opaque plan data.
2. The server validates bounds, canonicalizes the plan, and stores an approval
   bound to plugin ID, plugin version, artifact digest, service, method, request
   payload hash, plan hash, targets, and principal.
3. Approval execution rechecks active state, compatibility, artifact digest,
   target authorization, and plan hash. Any mismatch invalidates the approval.
4. The server invokes the exact approved plugin artifact with the non-browser
   `execute` action, immutable approved plan, and a short-lived, one-time
   operation capability.
5. The plugin can enqueue bounded agent work only by presenting that capability.
   The broker checks target, interpreter, expiry, use count, plan hash, and task
   payload hash before enqueue.
6. Task results and rollback outcomes are audited and exposed generically. The
   plugin reconciles its own desired state only after confirmed results.

This keeps domain compilation in the plugin while retaining host-controlled
authorization and preventing approval bypass.

### 9.4 State and secrets

Plugin state is keyed by plugin ID and schema version. Ordinary state uses
namespaced KV. Reversible credentials, private keys, tokens, and generated
secrets use a separate encrypted secret host service and are write-only to UI
contracts. Secret values must not appear in plans, bridge errors, audit metadata,
logs, health responses, or plugin index data.

State migrations are plugin-owned, explicit, ordered, idempotent, and bounded.
Activation fails closed if a migration fails. The server records the prior
schema version and preserves the previous state snapshot for rollback.

## 10. Lifecycle and Uninstall

- `verified`: bundle is trusted and available but contributes no UI and has no
  running backend.
- `installed`: compatibility and migrations have passed, but UI/backend remain
  inactive.
- `active`: runtime is armed, contributions are visible, assets are served, and
  declared calls are allowed.
- `disabled`: runtime and UI are stopped; data and installed bundle remain.
- logical uninstall returns the plugin to `verified`, removes active mounts and
  installed runtime state, and preserves namespaced data by default.
- `purge data` is a separate destructive, explicitly confirmed, audited action.

Disable and uninstall must be idempotent. They invalidate contribution caches,
asset URLs, bridge nonces, in-flight calls, operation capabilities, and runtime
state. Base dashboard routes cannot depend on plugin calls and must not poll a
plugin that is absent or inactive.

## 11. Native UI Purity

Before a plugin migration is complete, core compatibility code may coexist
behind the existing production path. The new alpha plugin is not activated as
self-contained until its vertical slice passes parity.

After parity, the migration removes:

- dashboard builtin component registrations;
- plugin-specific Vue views and API wrappers;
- native-page plugin-ID checks and background calls;
- legacy redirects that target undeclared plugin routes;
- server in-core RPC handlers under the plugin namespace;
- server domain handlers, stores, and renderers now owned by the plugin.

Generic host services and generic extension infrastructure remain. No dormant
plugin-specific fallback is retained after the rollback window closes.

## 12. Migration Order

### Phase 1: host foundation

Repositories: `lattice-server`, `lattice-dashboard`, `lattice-plugin-template`,
and `lattice-plugin-index`.

Deliver Bundle v2 verification/extraction, compatibility checks, authenticated
asset serving, sandbox frame host, bridge v1, v2 interface declarations, generic
host services, deterministic pack/sign tooling, and index validation.

### Phase 2: Sub-Store pilot

Move `SubStoreView` into `lattice-plugin-sub-store/ui`, remove its legacy REST
fallback, strengthen runtime call tests, package it as v2, and verify install,
activate, call, disable, uninstall, and rollback end to end. This is the pilot
because its backend call logic is already plugin-owned.

### Phase 3: NetGuard

Move firewall UI, zones, groups, bindings, compiler, nft rendering, reality and
drift interpretation, bootstrap preparation, plan, rollback, and apply behavior
into `lattice-plugin-netguard`. Preserve byte-parity tests against the current
renderer before removing core ownership.

### Phase 4: WireGuard

Move network, device, peer, key, routing, bootstrap, configuration parsing,
reality, drift, plan, rollback, and apply behavior into
`lattice-plugin-wireguard`. Private keys use encrypted plugin secret storage and
never cross the UI bridge after creation.

### Phase 5: VPN Core

Move Lines, users, credentials, bindings, profiles, subscriptions, usage,
sing-box discovery/adoption, config rendering, and managed operations into
`lattice-plugin-vpn-core`. Replace native Map/Nodes/Tasks coupling with no
enhancement during this alpha; generic cross-page slots require a later design.

Each phase is a complete vertical slice and leaves a clean checkpoint. Security-
critical plugins are migrated one at a time, not through a shared big-bang
rewrite.

## 13. Test and Acceptance Gates

### Host tests

- v1 compatibility and v2 schema validation;
- manifest signing payload mutation tests for every v2 field;
- digest-before-decompress behavior;
- traversal, symlink, duplicate path, decompression bomb, size, file-count, and
  permission tests;
- incompatible host/runtime rejection;
- active-only asset access and MIME/nosniff/cache behavior;
- route-specific CSP and global CSP non-regression;
- bridge source/nonce/method/scope/size/rate/timeout/result-limit tests;
- disable/uninstall races and in-flight cancellation;
- plan/version/digest/payload/target binding and one-time capability tests;
- secret redaction across API, audit, log, and UI paths.

### Plugin tests

- backend unit and race tests;
- deterministic plan tests and mutation-sensitive parity gates;
- UI unit tests against the reference bridge host;
- deterministic double-build bundle digest;
- manifest/runtime/UI version parity;
- no external URL or inline-code scan in built UI;
- empty-state, error, permission-denied, timeout, and stale-runtime behavior;
- migration and rollback tests with representative production-state fixtures.

### End-to-end acceptance

For every migrated plugin:

1. Base dashboard starts with the plugin absent and produces no plugin calls.
2. Verified and installed states produce no Extensions page.
3. Activation adds only the plugin's declared Extensions pages.
4. UI loads from the signed artifact and completes real read/write/plan flows.
5. Host-risk apply requires approval and exact plan/artifact binding.
6. Disable removes UI and denies calls without affecting native pages.
7. Logical uninstall leaves no route, frame, polling, runtime, or server handler
   dependency; reinstall recovers preserved plugin state.
8. Purge requires explicit confirmation and is audited.
9. Desktop and mobile browser screenshots show no overflow, overlap, blank frame,
   or unstyled content.
10. Server, dashboard, plugin, and bundle versions are visible in diagnostics.

## 14. Alpha Release Matrix

| Repository | Alpha version |
| --- | --- |
| `lattice-dashboard` | `v0.2.2-alpha.2` |
| `lattice-server` image | `alpha-0.2.1a31` |
| `lattice-plugin-index` | `v0.2.1-alpha.1` |
| `lattice-plugin-template` | `v0.2.1-alpha.1` |
| `lattice-plugin-sub-store` | `v0.3.2-alpha.1` |
| `lattice-plugin-netguard` | `v0.1.0-alpha.6` |
| `lattice-plugin-wireguard` | `v0.1.0-alpha.6` |
| `lattice-plugin-vpn-core` | `v0.7.3-alpha.1` |

All GitHub releases are prereleases with `make_latest=false`. Stable tags and
Latest pointers remain unchanged. Plugin alpha releases declare the minimum
Bundle v2 host/bridge compatibility and are never auto-selected by stable
resolvers.

## 15. Rollout and Rollback

The first deploy contains the v2 host plus the Sub-Store pilot while continuing
to accept existing v1 plugins. Production plugin state and compose configuration
are backed up before deployment. Sub-Store is activated only after its bundle,
runtime, asset, bridge, and call checks pass.

Rollback restores the prior server image and plugin bundle directory. Because
v2 state migrations preserve a pre-migration snapshot and v1 loading remains
supported, rollback does not require deleting plugin state. NetGuard, WireGuard,
and VPN Core keep their existing production path until their own parity gate and
explicit alpha activation.

## 16. Completion Definition

The program is complete only when all four official feature plugins own their
UI and domain backend, Dashboard has no official-plugin builtin component keys,
Server has no plugin-namespace in-core RPC handlers, native pages contain no
plugin-specific calls, each plugin independently builds/releases/activates, and
absence/disable/uninstall tests prove that base Lattice behavior is unchanged.
